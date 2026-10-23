// PinnedModelDownloader.swift
// Dictari — fetches model files from their reviewed revision and admits only matching bytes.
//
// Why not the upstream downloaders: FluidAudio's `ModelHub.download` and WhisperKit's Hub
// downloader both resolve the repository's moving default branch. The day upstream pushes new
// weights, every fresh install would receive bytes that fail the manifest, and Retry would
// fetch the same wrong bytes again, forever. Every file here comes from
// `resolve/<manifest revision>/<path>` instead, so what is downloaded is what was reviewed.
// The upstream libraries are still used to *load* models, from folders this file filled.
//
// Admission is streaming: bytes are hashed as they are written to a partial file in the model
// folder, and the partial file is atomically renamed into place only when size and SHA-256
// match. A failed or cancelled transfer never replaces an existing file.

import CryptoKit
import Darwin
import Foundation

// MARK: - Byte source

/// Supplies the body of a pinned URL. Production uses `URLSessionModelFetcher`; tests inject
/// an in-memory fetcher, so the admission logic is exercised without any network access.
protocol ModelFileFetching: Sendable {
    /// Body bytes in arrival order. Must finish by throwing for any final status other than 200.
    func chunks(from url: URL) -> AsyncThrowingStream<Data, any Error>
}

/// Streams a response body chunk by chunk as URLSession receives it, so a 1.6 GB model never
/// sits in memory and its hash is computed on the way to disk.
struct URLSessionModelFetcher: ModelFileFetching {
    func chunks(from url: URL) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let delegate = StreamingFetchDelegate(continuation: continuation)
            // Ephemeral with no URLCache: model bodies must not be duplicated into a disk cache.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(
                configuration: configuration, delegate: delegate, delegateQueue: nil
            )
            // A session retains its delegate until invalidated; ending the stream for any
            // reason (finish, error, consumer cancellation) tears both down.
            continuation.onTermination = { _ in session.invalidateAndCancel() }
            session.dataTask(with: url).resume()
        }
    }
}

private final class StreamingFetchDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        // Redirects (Hugging Face → CDN) are followed before this point; only the final
        // response is judged. An error page must never be streamed into a model file.
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            continuation.finish(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

/// Reads a local file in fixed chunks; used to seed from FluidAudio's shared cache through the
/// same hashing admission path as a network download.
struct LocalFileChunks: AsyncSequence {
    typealias Element = Data
    let url: URL
    var chunkSize = 1_048_576

    final class AsyncIterator: AsyncIteratorProtocol {
        private let handle: FileHandle
        private let chunkSize: Int

        init(handle: FileHandle, chunkSize: Int) {
            self.handle = handle
            self.chunkSize = chunkSize
        }

        func next() async throws -> Data? {
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else {
                return nil
            }
            return data
        }

        deinit { try? handle.close() }
    }

    func makeAsyncIterator() -> AsyncIterator {
        // An unreadable seed yields an empty sequence, which the size check then rejects.
        let handle = (try? FileHandle(forReadingFrom: url)) ?? FileHandle.nullDevice
        return AsyncIterator(handle: handle, chunkSize: chunkSize)
    }
}

// MARK: - Installation

extension ModelFiles {

    /// Partial downloads live at the model folder's root (never inside a `.mlmodelc`, where the
    /// unlisted-file check would reject them) so the final rename stays on one volume.
    static let partialFilePrefix = ".dictari-partial-"

    /// Make `directory` hold every manifest-listed file for `modelID`, byte-identical to the
    /// reviewed revision. Files that already match are kept (a stamp makes that check cheap);
    /// anything missing or mismatching is copied from `seedDirectory` when that holds matching
    /// bytes, and otherwise fetched from the pinned URL.
    ///
    /// `progress` reports admitted bytes over the bytes that had to be installed, and is only
    /// called when something is actually installed. Returns that byte total (0 = nothing to do).
    @discardableResult
    static func ensurePinnedModel(
        modelID: String,
        directory: URL,
        manifestData: Data,
        fetcher: any ModelFileFetching = URLSessionModelFetcher(),
        seedDirectory: URL? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Int64 {
        let model = try validatedModel(modelID: modelID, manifestData: manifestData)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        removeStalePartialFiles(in: directory)

        let stamps = IntegrityStampCache(directory: directory)
        var needed: [IntegrityFile] = []
        for file in model.files {
            do {
                try verify(file: file, in: directory, stamps: stamps)
            } catch ModelIntegrityError.symbolicLink(let path) {
                // Never write through, or replace, a link someone else planted.
                throw ModelIntegrityError.symbolicLink(path: path)
            } catch {
                needed.append(file)
            }
        }
        stamps.saveIfNeeded()
        guard !needed.isEmpty else { return 0 }

        let total = needed.reduce(Int64(0)) { $0 + $1.size }
        let denominator = Double(max(total, 1))
        var completed: Int64 = 0
        progress?(0)
        for file in needed {
            try Task.checkCancellation()
            let base = completed
            let report: (Int64) -> Void = { bytes in
                progress?(min(Double(base + bytes) / denominator, 1))
            }

            var admitted = false
            if let seedDirectory,
               let seed = seedCandidate(for: file, in: seedDirectory) {
                do {
                    try await admit(LocalFileChunks(url: seed), file: file, into: directory,
                                    stamps: stamps, onBytes: report)
                    admitted = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A seed that differs from the manifest is simply not used; the pinned
                    // download below replaces it. The shared folder itself is never touched.
                }
            }
            if !admitted {
                let url = try pinnedDownloadURL(
                    modelID: modelID, path: file.path, manifestData: manifestData
                )
                try await admit(fetcher.chunks(from: url), file: file, into: directory,
                                stamps: stamps, onBytes: report)
            }
            completed += file.size
            stamps.saveIfNeeded()
            progress?(min(Double(completed) / denominator, 1))
        }
        return total
    }

    /// Bundled-manifest convenience used by the engines.
    @discardableResult
    static func ensureBundledModel(
        modelID: String,
        directory: URL,
        seedDirectory: URL? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Int64 {
        try await ensurePinnedModel(
            modelID: modelID, directory: directory, manifestData: bundledManifestData(),
            seedDirectory: seedDirectory, progress: progress
        )
    }

    /// Stream `chunks` into a partial file while hashing, then atomically move it into place
    /// only if size and SHA-256 match the manifest. Oversized bodies abort as soon as they
    /// exceed the expected size; on any failure the partial file is removed and whatever was
    /// at the destination before is left untouched.
    static func admit<Chunks: AsyncSequence>(
        _ chunks: Chunks,
        file: IntegrityFile,
        into directory: URL,
        stamps: IntegrityStampCache? = nil,
        onBytes: (Int64) -> Void = { _ in }
    ) async throws where Chunks.Element == Data {
        let fileManager = FileManager.default
        let partial = directory.appendingPathComponent(
            partialFilePrefix + UUID().uuidString, isDirectory: false
        )
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
        }
        defer { try? fileManager.removeItem(at: partial) }

        let handle = try FileHandle(forWritingTo: partial)
        var handleOpen = true
        defer { if handleOpen { try? handle.close() } }

        var hasher = SHA256()
        var written: Int64 = 0
        for try await chunk in chunks {
            try Task.checkCancellation()
            written += Int64(chunk.count)
            guard written <= file.size else {
                throw ModelIntegrityError.sizeMismatch(
                    path: file.path, expected: file.size, actual: written
                )
            }
            hasher.update(data: chunk)
            try handle.write(contentsOf: chunk)
            onBytes(written)
        }
        // A cancelled AsyncThrowingStream ends quietly; report it as cancellation rather
        // than as a short (corrupt) file.
        try Task.checkCancellation()
        guard written == file.size else {
            throw ModelIntegrityError.sizeMismatch(path: file.path, expected: file.size, actual: written)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else {
            throw ModelIntegrityError.checksumMismatch(
                path: file.path, expected: file.sha256, actual: digest
            )
        }
        // Durable before visible: a stamp must never vouch for bytes still in the page cache.
        try handle.synchronize()
        try handle.close()
        handleOpen = false

        _ = try resolveWithoutSymlinks(file.path, in: directory)
        let destination = directory.appendingPathComponent(file.path, isDirectory: false)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Re-check after creating parents: nothing may have been swapped for a link meanwhile.
        _ = try resolveWithoutSymlinks(file.path, in: directory)
        // rename(2) replaces an existing regular file atomically: a loader sees the old bytes
        // or the new ones, never a half-written file.
        guard rename(partial.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let identity = FileIdentity(of: destination) {
            stamps?.record(file, identity: identity)
        }
    }

    /// A seed is worth trying only if it is a regular file of the expected size; the hash is
    /// then checked on the copy itself, so a seed changing mid-copy cannot slip through.
    private static func seedCandidate(for file: IntegrityFile, in seedDirectory: URL) -> URL? {
        let url = seedDirectory.appendingPathComponent(file.path, isDirectory: false)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              Int64(values.fileSize ?? -1) == file.size else {
            return nil
        }
        return url
    }

    /// Partial files left by a crash or force-quit are ours by name and never loadable.
    private static func removeStalePartialFiles(in directory: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in entries where name.hasPrefix(partialFilePrefix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

// MARK: - Verification stamps

/// What must stay identical for a previously hashed file to be trusted without re-hashing.
/// ctime cannot be set from user space: any write, truncate, chmod, rename-over or `touch`
/// moves it, so a file that still matches its stamp still holds the bytes that were hashed.
struct FileIdentity: Codable, Equatable {
    let size: Int64
    let device: Int64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init?(of url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        size = Int64(info.st_size)
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }
}

/// Per-folder record of files whose SHA-256 was verified, keyed by manifest path. It lives in
/// the model folder as a hidden top-level JSON (inert to both loaders and to the unlisted-bundle
/// check) and is deleted with the model. A stamp also carries the digest it vouches for, so a
/// manifest update invalidates it. Unreadable or foreign content is treated as "no stamps":
/// the worst case is always a full re-hash, never a skipped one.
final class IntegrityStampCache {
    static let fileName = ".dictari-integrity-stamps.json"

    private struct Stamp: Codable, Equatable {
        let sha256: String
        let identity: FileIdentity
    }

    private struct Stored: Codable {
        var schemaVersion: Int
        var stamps: [String: Stamp]
    }

    private let url: URL
    private var stamps: [String: Stamp]
    private var dirty = false

    init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           stored.schemaVersion == 1 {
            stamps = stored.stamps
        } else {
            stamps = [:]
        }
    }

    func matches(_ file: ModelFiles.IntegrityFile, identity: FileIdentity) -> Bool {
        guard let stamp = stamps[file.path] else { return false }
        return stamp.sha256 == file.sha256 && identity.size == file.size && stamp.identity == identity
    }

    func record(_ file: ModelFiles.IntegrityFile, identity: FileIdentity) {
        let stamp = Stamp(sha256: file.sha256, identity: identity)
        guard stamps[file.path] != stamp else { return }
        stamps[file.path] = stamp
        dirty = true
    }

    /// Best effort: failing to persist only costs a re-hash next time.
    func saveIfNeeded() {
        guard dirty,
              let data = try? JSONEncoder().encode(Stored(schemaVersion: 1, stamps: stamps))
        else { return }
        if (try? data.write(to: url, options: .atomic)) != nil {
            dirty = false
        }
    }
}

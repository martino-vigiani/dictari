// ModelFiles.swift
// Dictari — on-disk inspection of downloaded models.
//
// Every model lives in a folder Dictari owns under AppPaths.models, filled only with bytes
// fetched from the manifest's pinned revision (PinnedModelDownloader.swift):
//   • WhisperKit variants keep the Hub layout models/argmaxinc/whisperkit-coreml/<variant>
//     so caches from earlier releases, and WhisperKit's own local loader, still line up.
//   • Parakeet lives in <Models>/parakeet-tdt-0.6b-v3. FluidAudio's shared cache in
//     ~/Library/Application Support/FluidAudio/Models is only ever *read* (a one-time seed).

import CryptoKit
import Foundation
import FluidAudio

enum ModelFiles {

    private static let integrityManifestName = "ModelIntegrityManifest"
    private static let hashReadSize = 1_048_576

    private struct IntegrityManifest: Decodable {
        let schemaVersion: Int
        let models: [String: IntegrityModel]
    }

    struct IntegrityModel: Decodable {
        let repository: String
        let revision: String
        let remotePathPrefix: String?
        let files: [IntegrityFile]
    }

    struct IntegrityFile: Decodable {
        let path: String
        let size: Int64
        let sha256: String
    }

    /// Verifies every executable/data artifact listed for `modelID` before Core ML or a
    /// vocabulary parser sees it. The manifest carries both the immutable upstream revision
    /// (every byte is fetched from it, see `ensurePinnedModel`) and byte-level SHA-256 values,
    /// so nothing but the reviewed bytes can ever be loaded.
    ///
    /// Hashing is skipped for a file whose on-disk identity still matches the stamp recorded
    /// the last time its bytes were hashed (see `IntegrityStampCache`); any write, replacement
    /// or metadata change moves its ctime and forces a full re-hash.
    static func verifyIntegrity(modelID: String, directory: URL, manifestData: Data) throws {
        let model = try validatedModel(modelID: modelID, manifestData: manifestData)
        let stamps = IntegrityStampCache(directory: directory)
        for file in model.files {
            try verify(file: file, in: directory, stamps: stamps)
        }
        try verifyOnlyListedCoreMLBundles(model.files, in: directory)
        stamps.saveIfNeeded()
    }

    /// A valid hash for the listed files is not enough when a backend conditionally opens
    /// additional bundles (WhisperKit's optional TextDecoderContextPrefill is one example).
    /// Reject any unlisted compiled/source model and any extra byte inside a listed bundle.
    /// Unlisted top-level metadata remains inert: our loaders use explicit verified JSON bytes,
    /// while existing FluidAudio/WhisperKit caches can contain old config/vocabulary sidecars.
    private static func verifyOnlyListedCoreMLBundles(
        _ files: [IntegrityFile], in directory: URL
    ) throws {
        let expected = Set(files.map(\.path))
        let manager = FileManager.default
        let expectedBundles = Set(files.compactMap { file -> String? in
            guard let root = file.path.split(separator: "/").first else { return nil }
            return root.hasSuffix(".mlmodelc") || root.hasSuffix(".mlpackage")
                ? String(root) : nil
        })
        let rootEntries = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
        )

        // Default APFS is case-insensitive: WhisperKit's lowercase lookup can resolve an
        // uppercase-suffixed neighbor, so compare the extension case-insensitively too.
        for entry in rootEntries where ["mlmodelc", "mlpackage"].contains(entry.pathExtension.lowercased()) {
            let name = entry.lastPathComponent
            guard expectedBundles.contains(name) else {
                throw ModelIntegrityError.unexpectedFile(path: name)
            }
            let rootValues = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if rootValues.isSymbolicLink == true {
                throw ModelIntegrityError.symbolicLink(path: name)
            }
            guard rootValues.isDirectory == true else {
                throw ModelIntegrityError.unexpectedFile(path: name)
            }

            // Build relative paths from directory entries, not absolute URL strings: macOS
            // may canonicalize /var to /private/var while traversing a temporary fixture.
            var pending = [(folder: entry, relativePrefix: name)]
            while let (folder, relativePrefix) = pending.popLast() {
                let children = try manager.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                    options: []
                )
                for child in children {
                    let relativePath = relativePrefix + "/" + child.lastPathComponent
                    let values = try child.resourceValues(
                        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                    )
                    if values.isSymbolicLink == true {
                        throw ModelIntegrityError.symbolicLink(path: relativePath)
                    }
                    if values.isDirectory == true {
                        pending.append((folder: child, relativePrefix: relativePath))
                    } else if values.isRegularFile != true || !expected.contains(relativePath) {
                        throw ModelIntegrityError.unexpectedFile(path: relativePath)
                    }
                }
            }
        }
    }

    static func validatedModel(modelID: String, manifestData: Data) throws -> IntegrityModel {
        let manifest: IntegrityManifest
        do {
            manifest = try JSONDecoder().decode(IntegrityManifest.self, from: manifestData)
        } catch {
            throw ModelIntegrityError.malformedManifest
        }

        guard manifest.schemaVersion == 1 else {
            throw ModelIntegrityError.malformedManifest
        }
        guard let model = manifest.models[modelID] else {
            throw ModelIntegrityError.missingModel(modelID)
        }
        guard isValidRepository(model.repository),
              isLowercaseHex(model.revision, count: 40),
              model.remotePathPrefix.map({ $0.isEmpty || isValidRelativePath($0) }) ?? true,
              !model.files.isEmpty else {
            throw ModelIntegrityError.malformedManifest
        }

        var seenPaths = Set<String>()
        for file in model.files {
            guard isValidRelativePath(file.path), file.size >= 0,
                  seenPaths.insert(file.path).inserted else {
                throw ModelIntegrityError.malformedManifest
            }
            guard isLowercaseHex(file.sha256, count: 64) else {
                throw ModelIntegrityError.malformedDigest(path: file.path)
            }
        }
        return model
    }

    /// Resolve a manifest path under `directory`, refusing any symbolic link along the way so
    /// neither a read nor a write can be redirected outside the model folder.
    static func resolveWithoutSymlinks(_ path: String, in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        var candidate = directory
        for component in path.split(separator: "/").map(String.init) {
            candidate.appendPathComponent(component, isDirectory: false)
            if (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                throw ModelIntegrityError.symbolicLink(path: path)
            }
        }
        return candidate
    }

    static func verify(
        file: IntegrityFile, in directory: URL, stamps: IntegrityStampCache? = nil
    ) throws {
        let candidate = try resolveWithoutSymlinks(file.path, in: directory)

        let values: URLResourceValues
        do {
            values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw ModelIntegrityError.missingFile(path: file.path)
        }
        guard values.isRegularFile == true else {
            throw ModelIntegrityError.missingFile(path: file.path)
        }

        let actualSize = Int64(values.fileSize ?? -1)
        guard actualSize == file.size else {
            throw ModelIntegrityError.sizeMismatch(
                path: file.path,
                expected: file.size,
                actual: actualSize
            )
        }

        let before = FileIdentity(of: candidate)
        if let before, stamps?.matches(file, identity: before) == true {
            return
        }

        let actualDigest: String
        do {
            actualDigest = try sha256(of: candidate)
        } catch {
            throw ModelIntegrityError.missingFile(path: file.path)
        }
        guard actualDigest == file.sha256 else {
            throw ModelIntegrityError.checksumMismatch(
                path: file.path,
                expected: file.sha256,
                actual: actualDigest
            )
        }
        // Stamp only when nothing changed while hashing: otherwise the stamp could vouch for
        // metadata that belongs to bytes this pass never read.
        if let before, FileIdentity(of: candidate) == before {
            stamps?.record(file, identity: before)
        }
    }

    /// Construct a download URL only for a file listed in the signed app's manifest. The
    /// revision is an immutable upstream commit, never `main` or another moving ref.
    static func pinnedDownloadURL(modelID: String, path: String, manifestData: Data) throws -> URL {
        let model = try validatedModel(modelID: modelID, manifestData: manifestData)
        guard model.files.contains(where: { $0.path == path }) else {
            throw ModelIntegrityError.missingFile(path: path)
        }
        var url = URL(string: "https://huggingface.co")!
        for component in model.repository.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        url.appendPathComponent("resolve")
        url.appendPathComponent(model.revision)
        if let prefix = model.remotePathPrefix {
            for component in prefix.split(separator: "/") {
                url.appendPathComponent(String(component))
            }
        }
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    /// Return the exact verified bytes, not merely a URL that could later be reparsed with
    /// optional unreviewed neighbor files (as WhisperKit's Hub tokenizer loader does).
    static func verifiedPinnedData(modelID: String, path: String, directory: URL) throws -> Data {
        let model = try validatedModel(modelID: modelID, manifestData: bundledManifestData())
        guard let file = model.files.first(where: { $0.path == path }) else {
            throw ModelIntegrityError.missingFile(path: path)
        }
        try verify(file: file, in: directory)
        let data = try Data(contentsOf: directory.appendingPathComponent(path))
        guard Int64(data.count) == file.size else {
            throw ModelIntegrityError.sizeMismatch(path: path, expected: file.size, actual: Int64(data.count))
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else {
            throw ModelIntegrityError.checksumMismatch(path: path, expected: file.sha256, actual: digest)
        }
        return data
    }

    /// The verified-load gate is shared by both backends. A failed check must never call
    /// the closure, which is responsible only for opening files already on local disk.
    static func withVerifiedModel<T>(
        modelID: String,
        directory: URL,
        manifestData: Data,
        loadLocal: () async throws -> T
    ) async throws -> T {
        try verifyIntegrity(modelID: modelID, directory: directory, manifestData: manifestData)
        try Task.checkCancellation()
        return try await loadLocal()
    }

    /// Dictari admits downloaded weights only when their bytes match the
    /// reviewed manifest bundled with that specific app build. Checking during warm-up
    /// avoids re-hashing hundreds of megabytes for every dictation.
    static func verifyBundledIntegrity(
        modelID: String,
        directory: URL,
        bundle: Bundle = ModelFiles.manifestBundle
    ) throws {
        let manifestData = try bundledManifestData(bundle: bundle)
        try verifyIntegrity(modelID: modelID, directory: directory, manifestData: manifestData)
    }

    static func withBundledVerification<T>(
        modelID: String,
        directory: URL,
        bundle: Bundle = ModelFiles.manifestBundle,
        loadLocal: () async throws -> T
    ) async throws -> T {
        let manifestData = try bundledManifestData(bundle: bundle)
        return try await withVerifiedModel(
            modelID: modelID, directory: directory, manifestData: manifestData,
            loadLocal: loadLocal
        )
    }

    /// The bundle that compiled this file, which also carries the manifest resource.
    /// `Bundle.main` is wrong in the host-less test target: there it is the xctest runner,
    /// while `Bundle(for:)` resolves to Dictari.app in the app and DictariTests.xctest in tests.
    static var manifestBundle: Bundle { Bundle(for: ManifestBundleToken.self) }

    static func bundledManifestData(bundle: Bundle = ModelFiles.manifestBundle) throws -> Data {
        guard let manifestURL = bundle.url(forResource: integrityManifestName, withExtension: "json"),
              let manifestData = try? Data(contentsOf: manifestURL, options: [.mappedIfSafe]) else {
            throw ModelIntegrityError.malformedManifest
        }
        return manifestData
    }

    private static func isValidRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    private static func isValidRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        guard value.utf8.count == count else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: hashReadSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Dictari's own Parakeet folder. It used to be FluidAudio's shared cache, but other apps write there too: an extra `.mlmodelc` from a
    /// neighbour tripped the unlisted-bundle check, and the corrupt-files recovery then deleted
    /// a folder Dictari does not own. Nothing here ever mutates the shared cache.
    static var parakeetDirectory: URL { parakeetDirectory(for: .v3) }

    /// Each variant gets its own folder, named like FluidAudio's cache folder for its repo.
    static func parakeetDirectory(for variant: ParakeetVariant) -> URL {
        let repo: Repo
        switch variant {
        case .v3: repo = .parakeetV3
        case .ultra: repo = .parakeetUltra
        }
        return AppPaths.models.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    /// FluidAudio's model version for a variant: it selects the repo folder and v3-family decoding.
    static func parakeetVersion(for variant: ParakeetVariant) -> AsrModelVersion {
        switch variant {
        case .v3: return .v3
        case .ultra: return .ultra
        }
    }

    /// FluidAudio's shared cache, read once to seed a variant's folder without a re-download
    /// for users upgrading from builds that used it.
    static func sharedFluidAudioParakeetDirectory(for variant: ParakeetVariant) -> URL? {
        AsrModels.defaultCacheDirectory(for: parakeetVersion(for: variant))
    }

    // MARK: - Cached status (what SwiftUI bodies should read)

    /// `isDownloaded`/`sizeBytes` below walk the whole models tree — milliseconds of
    /// synchronous filesystem I/O. Views read them from `body`, and during a download every
    /// progress tick invalidates those views, so the uncached reads turned a progress bar
    /// into ~12 full directory walks per tick on the main thread. Disk state only changes on
    /// download/delete, which is exactly where the views bump their `rev` counter — the same
    /// places that must call `invalidateStatusCache()`.
    @MainActor private static var statusCache: [String: (downloaded: Bool, bytes: Int64)] = [:]

    @MainActor
    static func cachedStatus(_ desc: ModelDescriptor) -> (downloaded: Bool, bytes: Int64) {
        if let hit = statusCache[desc.id] { return hit }
        let fresh = (downloaded: isDownloaded(desc), bytes: sizeBytes(desc))
        statusCache[desc.id] = fresh
        return fresh
    }

    @MainActor
    static func invalidateStatusCache() {
        statusCache.removeAll()
    }

    // MARK: - Backend-aware API (use this from the UI)

    /// Whether the model backing `desc` is present on disk.
    static func isDownloaded(_ desc: ModelDescriptor) -> Bool {
        switch desc.backend {
        case .whisperKit:
            return isDownloaded(desc.whisperKitName)
        case .parakeet:
            let variant = desc.parakeetVariant ?? .v3
            return AsrModels.modelsExist(
                at: parakeetDirectory(for: variant), version: parakeetVersion(for: variant)
            )
        }
    }

    /// Bytes occupied on disk by the model backing `desc`; 0 when absent.
    static func sizeBytes(_ desc: ModelDescriptor) -> Int64 {
        switch desc.backend {
        case .whisperKit:
            return sizeBytes(desc.whisperKitName)
        case .parakeet:
            return directorySize(parakeetDirectory(for: desc.parakeetVariant ?? .v3))
        }
    }

    /// True when files for this model are present but the download never finished. The Models
    /// screen treats this as "not downloaded"; the download path uses it to clear the remains
    /// before retrying.
    static func hasIncompleteFiles(_ desc: ModelDescriptor) -> Bool {
        switch desc.backend {
        case .whisperKit:
            guard let url = location(forVariant: desc.whisperKitName) else { return false }
            return !isComplete(url)
        case .parakeet:
            // A partial Parakeet folder is resumed, not discarded: warm-up keeps every file
            // that already matches the manifest and fetches only the rest.
            return false
        }
    }

    /// Remove the model's files to reclaim space.
    static func delete(_ desc: ModelDescriptor) {
        switch desc.backend {
        case .whisperKit:
            delete(desc.whisperKitName)
        case .parakeet:
            try? FileManager.default.removeItem(at: parakeetDirectory(for: desc.parakeetVariant ?? .v3))
        }
    }

    // MARK: - WhisperKit variant lookup

    /// Where a WhisperKit variant is installed: the same Hub layout WhisperKit's own downloader
    /// used (`<downloadBase>/models/<repo>/<variant>`), so existing caches are reused and only
    /// their missing or mismatching files are fetched again.
    static func whisperKitDirectory(forVariant variant: String, modelsRoot: URL = AppPaths.models) -> URL {
        modelsRoot
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    /// The on-disk folder for a WhisperKit variant (e.g. "openai_whisper-small"), or nil.
    /// Searches the models directory since WhisperKit nests under models/<repo>/<variant>.
    static func location(forVariant variant: String, in root: URL = AppPaths.models) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == variant {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return url
            }
        }
        return nil
    }

    /// A WhisperKit variant counts as downloaded only when its compiled models are *complete*.
    ///
    /// The folder appearing is not the same as the download finishing: an interrupted transfer
    /// leaves the variant directory in place with the `.mlmodelc` bundles half written — the
    /// `.mil` graph present, the weights and `coremldata.bin` missing. Existence alone reported
    /// that as ready, so the Models screen offered a 1.5 GB model as downloaded, said it took
    /// 8 MB on disk, and handed the user a "Use" button that could only fail at load time.
    /// CoreML cannot open an `.mlmodelc` without its `coremldata.bin`, which makes that file
    /// the honest completion marker.
    static func isDownloaded(_ variant: String) -> Bool {
        guard let url = location(forVariant: variant) else { return false }
        return isComplete(url)
    }

    /// True when every compiled sub-model under `url` carries its `coremldata.bin`.
    private static func isComplete(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        else { return false }

        let compiled = entries.filter { $0.pathExtension == "mlmodelc" }
        guard !compiled.isEmpty else { return false }
        return compiled.allSatisfy {
            fm.fileExists(atPath: $0.appendingPathComponent("coremldata.bin").path)
        }
    }

    static func sizeBytes(_ variant: String) -> Int64 {
        guard let url = location(forVariant: variant) else { return 0 }
        return directorySize(url)
    }

    /// Recursive byte total of the regular files under `url`; 0 if unreadable.
    private static func directorySize(_ url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        if let walker = FileManager.default.enumerator(at: url,
                                                       includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in walker {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
            }
        }
        return total
    }

    static func delete(_ variant: String) {
        if let url = location(forVariant: variant) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Human-readable size: "810 MB" / "1.5 GB".
    static func formatted(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1000 {
            let gigabytes = (mb / 1000).formatted(.number.precision(.fractionLength(1)))
            return String(localized: "\(gigabytes) GB", comment: "File size in gigabytes; the argument is a formatted number")
        }
        return String(localized: "\(Int(mb.rounded())) MB", comment: "File size in megabytes")
    }
}

/// Class anchor for `Bundle(for:)`; enums have no bundle identity of their own.
private final class ManifestBundleToken {}

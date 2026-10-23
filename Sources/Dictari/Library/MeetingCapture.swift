import Foundation
import AVFoundation
import ScreenCaptureKit

/// Every mutable audio field is confined to queue. Main actor owns stream lifecycle only.
@available(macOS 15.0, *)
final class MeetingCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Dictari.meeting.capture", qos: .userInitiated)
    private var stream: SCStream?
    private let archive: MediaArchive
    private let documentID: UUID
    private let onSegment: @Sendable (MediaSegment) -> Void
    private let onError: @Sendable (String) -> Void
    private var lanes: [String: Lane] = [:]
    private var sealed: [MediaSegment] = []
    private var origin = 0.0
    private var stopped = false
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private final class Lane {
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var handle: FileHandle?
        var segment: MediaSegment?
        var count = 0
        var hasSignal = false
        var lastEnd: Double?
        var inputBuffer: AVAudioPCMBuffer?
        var outputBuffer: AVAudioPCMBuffer?
    }

    init(archive: MediaArchive, documentID: UUID,
         onSegment: @escaping @Sendable (MediaSegment) -> Void,
         onError: @escaping @Sendable (String) -> Void) {
        self.archive = archive
        self.documentID = documentID
        self.onSegment = onSegment
        self.onError = onError
    }

    @MainActor
    func start(application: SCRunningApplication, microphone: Bool) async throws {
        if microphone {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw NSError(domain: "Dictari", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Microphone permission is required to include your voice.")])
            }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw MediaArchiveError.noAudio }
        let filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.captureMicrophone = microphone
        // No screen output is attached: the archive contains audio only.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if microphone { try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        queue.sync { origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds }
        stream = newStream
        try await newStream.startCapture()
    }

    @MainActor
    func stop() async -> [MediaSegment] {
        do { try await stream?.stopCapture() }
        catch { onError(String(localized: "Capture stopped with an error: \(error.localizedDescription)")) }
        stream = nil
        return finishSegments()
    }

    func finishSegments() -> [MediaSegment] {
        queue.sync {
            stopped = true
            for (source, lane) in lanes {
                do { try seal(lane, source: source) } catch { onError(error.localizedDescription) }
            }
            return sealed
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error.localizedDescription)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        consume(sample, source: type == .microphone ? "Microphone" : "App audio")
    }

    // Called on the capture queue; standalone fixtures can exercise this path without
    // starting a stream or requesting microphone/screen-recording access.
    func consume(_ sample: CMSampleBuffer, source: String) {
        guard !stopped, sample.isValid else { return }
        do {
            guard let description = sample.formatDescription,
                  let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: pointer) else { return }
            let lane = lanes[source] ?? Lane()
            lanes[source] = lane
            if lane.inputFormat != format {
                lane.inputFormat = format
                lane.converter = AVAudioConverter(from: format, to: outputFormat)
                lane.inputBuffer = nil
                lane.outputBuffer = nil
            }
            if lane.inputBuffer == nil || lane.inputBuffer!.frameCapacity < AVAudioFrameCount(sample.numSamples) {
                lane.inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples))
            }
            guard let input = lane.inputBuffer else { throw MediaArchiveError.decodeFailed }
            input.frameLength = AVAudioFrameCount(sample.numSamples)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples), into: input.mutableAudioBufferList) == noErr else {
                throw MediaArchiveError.decodeFailed
            }
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / format.sampleRate)) + 32
            if lane.outputBuffer == nil || lane.outputBuffer!.frameCapacity < capacity {
                lane.outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
            }
            guard let converter = lane.converter, let output = lane.outputBuffer else { throw MediaArchiveError.decodeFailed }
            output.frameLength = 0
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error { throw error ?? MediaArchiveError.decodeFailed as NSError }
            guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
            let timestamp = sample.presentationTimeStamp.seconds
            guard timestamp.isFinite else { throw MediaArchiveError.decodeFailed }
            let start = max(0, timestamp - origin)
            guard start < 4 * 3600 else { throw MediaArchiveError.tooLong }
            if let lastEnd = lane.lastEnd {
                guard start >= lastEnd - 0.1 else {
                    throw NSError(domain: "Dictari.MeetingCapture", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: String(localized: "Audio timing changed unexpectedly. Recording stopped; captured audio is saved.")])
                }
                // Browsers can stop delivering buffers during pauses. Preserve that gap
                // in the segment clock rather than concatenating the next voice early.
                if start > lastEnd + 0.1 { try seal(lane, source: source) }
            }
            let sampleCount = Int(output.frameLength)
            if lane.handle == nil, MediaAudioActivity.isDigitalSilence(UnsafeBufferPointer(start: channel, count: sampleCount)) {
                // No open speech segment needs padding: avoid creating/deleting an empty
                // PCM file and metadata sidecar on every five seconds of browser silence.
                lane.lastEnd = start + Double(sampleCount) / 16000
                return
            }
            var offset = 0
            while offset < sampleCount {
                if lane.handle == nil {
                    let segment = MediaSegment(start: start + Double(offset) / 16000, duration: 0, source: source)
                    let file = archive.directory(documentID).appendingPathComponent(segment.audioFile)
                    guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                    lane.handle = try FileHandle(forWritingTo: file)
                    lane.segment = segment
                    lane.count = 0
                    lane.hasSignal = false
                    try JSONEncoder().encode(segment).write(to: archive.directory(documentID).appendingPathComponent(segment.id.uuidString + ".json"), options: .atomic)
                }
                let amount = min(sampleCount - offset, 5 * 16000 - lane.count)
                let values = UnsafeBufferPointer(start: channel.advanced(by: offset), count: amount)
                if MediaAudioActivity.isDigitalSilence(values) {
                    // A sparse gap preserves timing without copying/writing zero PCM.
                    try lane.handle?.seek(toOffset: UInt64((lane.count + amount) * 4))
                } else {
                    lane.hasSignal = true
                    try lane.handle?.write(contentsOf: Data(bytes: values.baseAddress!, count: amount * 4))
                }
                lane.count += amount
                lane.lastEnd = lane.segment!.start + Double(lane.count) / 16000
                offset += amount
                if lane.count == 5 * 16000 { try seal(lane, source: source) }
            }
        } catch {
            stopped = true
            onError(error.localizedDescription)
        }
    }

    private func seal(_ lane: Lane, source: String) throws {
        guard let segment = lane.segment else { return }
        if lane.hasSignal {
            // A final silent buffer may have advanced the offset beyond EOF.
            try lane.handle?.truncate(atOffset: UInt64(lane.count * 4))
            try lane.handle?.synchronize()
        }
        try lane.handle?.close()
        lane.handle = nil
        lane.segment = nil
        guard lane.count > 0 else { return }
        if !lane.hasSignal {
            let folder = archive.directory(documentID)
            try FileManager.default.removeItem(at: folder.appendingPathComponent(segment.audioFile))
            try FileManager.default.removeItem(at: folder.appendingPathComponent(segment.id.uuidString + ".json"))
            return
        }
        var completed = MediaSegment(start: segment.start, duration: Double(lane.count) / 16000, source: source)
        completed.id = segment.id
        try JSONEncoder().encode(completed).write(to: archive.directory(documentID).appendingPathComponent(completed.id.uuidString + ".json"), options: .atomic)
        sealed.append(completed)
        onSegment(completed)
    }
}

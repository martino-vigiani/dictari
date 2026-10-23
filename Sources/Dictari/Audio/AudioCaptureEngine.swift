import AVFoundation
import Foundation
import os

/// Captures microphone audio via `AVAudioEngine`, downsamples to 16 kHz mono
/// Float32, and exposes a normalized level stream plus optional VAD auto-stop.
///
/// ## Concurrency design
/// The class itself is `@MainActor`: `onLevel` / `onAutoStop` are delivered on
/// the main actor, and `configure` / `start` / `stop` / `cancel` are all called
/// from the coordinator on the main actor.
///
/// The audio tap closure, however, runs on a **realtime audio thread** that is
/// `nonisolated` — it must never touch `@MainActor` state directly and must not
/// allocate or block. All realtime-mutated state therefore lives in a single
/// `RealtimeState` reference type that is `@unchecked Sendable` and guards every
/// field with an `os_unfair_lock`. The lock is held only for tiny, bounded
/// critical sections (appending a frame, reading/clearing the buffer), never
/// across a callback hop, so it is safe on the realtime thread.
@MainActor
final class AudioCaptureEngine {

    // MARK: Public callbacks (delivered on the main actor)

    /// Normalized 0...1 input level, ~40–60 callbacks/sec while running.
    var onLevel: ((Float) -> Void)?

    /// Fired once when VAD detects `silenceSeconds` of sub-threshold energy.
    var onAutoStop: (() -> Void)?

    /// New 16 kHz mono samples since the previous callback, ~50×/sec, for live transcription.
    /// Set it before `start()`; leaving it nil keeps the session's cost exactly as it was.
    /// The samples are *also* kept for the final transcript — this is a tee, not a drain.
    var onSamples: (([Float], Int) -> Void)?

    /// Set by the caller before `start()` when a live session is going to consume `onSamples`.
    /// Kept separate from `onSamples` being non-nil so the coordinator can leave the callback
    /// installed and still run a session without streaming (unsupported engine, or the user
    /// turned it off) without paying for the copies.
    var streamsSamples = false

    // MARK: Configuration (applied on next `start()`)

    private var vadEnabled: Bool = false
    private var silenceSeconds: Double = 1.5
    private var sensitivity: Int = 3
    private var inputDeviceUID: String?

    // MARK: AVAudioEngine

    /// Replaced, never reused, after a hardware route change: see `handleConfigurationChange`.
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning = false

    // MARK: Route-change state (main actor)

    /// Token for this engine's `AVAudioEngineConfigurationChange` observer.
    private var configurationObserver: NSObjectProtocol?
    /// Set when the hardware route changed under the current graph; the next `prearm()` or
    /// `start()` builds a fresh `AVAudioEngine` before touching the input node.
    private var graphIsStale = false
    /// Latched once a route change has asked the running session to finish, so a burst of
    /// notifications produces exactly one `onAutoStop`. Cleared when the session ends.
    private var routeChangeFinishRequested = false
    /// Debounces idle rebuilds: route changes arrive in bursts (AirPods post several while
    /// they switch profile), and only the settled route is worth preparing for.
    private var idleRebuildTask: Task<Void, Never>?
    /// Automatic idle rebuilds since the last successful `start()`. Capped so a device that
    /// keeps flapping (or a rebuild that itself provoked a notification) cannot turn into a
    /// rebuild loop; the lazy rebuild in `start()` still covers anything the cap skips.
    private var automaticRebuildsSinceStart = 0
    private static let maximumAutomaticRebuilds = 3

    /// Target output format: 16 kHz mono Float32, non-interleaved.
    private let targetFormat: AVAudioFormat = {
        // Force-unwrap is safe: these are always-valid standard PCM parameters.
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }()

    /// Realtime-thread-owned accumulator + VAD state. See class doc.
    private let realtime = RealtimeState()

    /// Polls realtime state on the main actor to deliver level / auto-stop
    /// callbacks. Created only while running; torn down on stop/cancel so idle
    /// cost is exactly zero (no spinning timer when not dictating).
    private var pump: DispatchSourceTimer?

    init() {
        observeConfigurationChanges(of: engine)
    }

    isolated deinit {
        idleRebuildTask?.cancel()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    // MARK: - Configuration

    func configure(
        vadEnabled: Bool,
        silenceSeconds: Double,
        sensitivity: Int,
        inputDeviceUID: String?
    ) {
        self.vadEnabled = vadEnabled
        self.silenceSeconds = max(0.2, silenceSeconds)
        self.sensitivity = min(5, max(1, sensitivity))
        self.inputDeviceUID = inputDeviceUID
    }

    // MARK: - Permission

    /// Synchronous check for the already-granted case, so the start-dictation path can skip
    /// the async hop entirely: an `await` there parks the whole start behind whatever the main
    /// actor is doing, which is exactly when the user's first syllable gets clipped.
    var permissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Bridges `AVCaptureDevice.requestAccess` to async. Returns the current
    /// status immediately if already determined.
    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Pre-arm

    /// Build the audio graph ahead of time without opening the microphone.
    ///
    /// A cold `start()` measured 103 ms on this machine, and the user has already begun
    /// speaking by the time they finish pressing the shortcut — so that cost is paid in lost
    /// syllables, not in waiting. `prepare()` allocates the render resources up front while
    /// leaving the device closed, so the microphone indicator stays off until dictation
    /// actually starts. Safe to call repeatedly.
    func prearm() {
        guard !isRunning else { return }
        if graphIsStale { rebuildEngine() }
        applyInputDevice(uid: inputDeviceUID)
        _ = engine.inputNode          // instantiating the node is part of the cost
        engine.prepare()
    }

    // MARK: - Start

    /// - Parameter autoStopAfterSilence: forces VAD on for this session only, with this quiet
    ///   period, whatever `configure` said. Conversation mode needs auto-stop even for users who
    ///   leave "Stop After Silence" off; passing it here rather than through `configure` means
    ///   the user's own setting is never overwritten and needs no restoring afterwards.
    func start(autoStopAfterSilence: Double? = nil) throws {
        guard !isRunning else { return }
        sessionVADEnabled = autoStopAfterSilence != nil || vadEnabled
        sessionSilenceSeconds = autoStopAfterSilence.map { max(0.2, $0) } ?? silenceSeconds
        routeChangeFinishRequested = false
        idleRebuildTask?.cancel()
        idleRebuildTask = nil
        // A route changed since the graph was prepared: the prepared engine still describes the
        // old device, and starting it either fails or taps with the wrong rate. Rebuilding here
        // costs the cold-start time once, which is better than a failed dictation.
        if graphIsStale { rebuildEngine() }

        // Decide once per session, before any audio arrives, whether the incremental feed runs.
        realtime.setIncremental(streamsSamples && onSamples != nil)

        // Reset accumulator + VAD before configuring thresholds.
        realtime.reset()
        realtime.configureVAD(
            enabled: sessionVADEnabled,
            silenceSeconds: sessionSilenceSeconds,
            // Scale: sensitivity 1 (relaxed) -> low threshold floor multiplier,
            // 5 (strict) -> high. Mapped inside RealtimeState.
            sensitivity: sensitivity,
            outputSampleRate: targetFormat.sampleRate
        )

        do {
            try startCapture()
        } catch AudioCaptureError.engineFailedToStart {
            // A route change the notification did not reach us for (or one that landed between
            // the check above and `engine.start()`) leaves a graph that refuses to start. One
            // retry on a brand-new engine recovers it; this costs time only on the failure path.
            rebuildEngine()
            try startCapture()
        }

        automaticRebuildsSinceStart = 0
        isRunning = true
        startPump()
    }

    /// Builds the converter, installs the tap and starts the engine on the current graph.
    /// On failure it leaves no tap installed, so it can be retried on a fresh engine.
    private func startCapture() throws {
        // Select the requested input device (best-effort) before touching the
        // input node so AVAudioEngine picks it up.
        applyInputDevice(uid: inputDeviceUID)

        // Apple's voice processor is deliberately never enabled here. Measured on this
        // hardware it delivers pure silence: with the input node connected to the mixer the
        // engine refuses to start (-10875), and without it the tap receives 75,000 samples
        // with a peak of exactly 0.0000. It is what turned fourteen real dictations into
        // empty transcripts. The plain path measures a peak of 0.31 on the same utterance.
        try? engine.inputNode.setVoiceProcessingEnabled(false)

        // Resolve the tap format at install time, validated against the hardware side of the
        // node. May rebuild the engine once, so read `engine.inputNode` only afterwards.
        let inputFormat = try resolveTapFormat()
        let input = engine.inputNode

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.unsupportedInputFormat
        }
        self.converter = converter

        // The tap delivers buffers in `inputFormat`; we convert each to 16 kHz
        // mono inside the realtime closure. Buffer size ~ small to keep latency
        // low and feed many RMS frames per second.
        let tapBufferSize: AVAudioFrameCount = 1024
        let target = targetFormat
        let rt = realtime

        // One output buffer for the whole session, reused by every callback: allocating an
        // AVAudioPCMBuffer per tap invocation was a heap allocation ~47×/s on the realtime
        // thread, which this file's own contract forbids. Sized to 4× the requested tap size
        // because `bufferSize` is only a preference — AVFAudio may deliver larger buffers —
        // with a per-call capacity check (and a slow-path alloc) in `process` as the backstop.
        let pooledCapacity = AVAudioFrameCount(
            Double(tapBufferSize * 4) * (target.sampleRate / inputFormat.sampleRate)
        ) + 16
        let pooled = PooledConversionBuffer(format: target, capacity: pooledCapacity)

        // `installTap`'s block is `@Sendable` and runs on the realtime thread.
        // It captures only `Sendable` references (`rt`, `converter`, `target`, `pooled`)
        // and never touches `@MainActor` state. All mutation goes through the
        // lock inside `RealtimeState`.
        // `@Sendable` keeps this NON-isolated so AVFAudio can run it on the realtime audio
        // thread without tripping the main-actor executor assertion (the class is @MainActor).
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { @Sendable buffer, _ in
            AudioCaptureEngine.process(
                buffer: buffer,
                converter: converter,
                targetFormat: target,
                pooled: pooled,
                into: rt
            )
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            throw AudioCaptureError.engineFailedToStart(error.localizedDescription)
        }
    }

    /// The format to install the tap with, checked against the hardware format right now.
    ///
    /// Voice processing is never enabled (see `startCapture`), so the node's output format
    /// normally equals its hardware input format and is what we tap with. After a route change
    /// the output side can still describe the previous device, and tapping with its rate raises
    /// the uncatchable `format.sampleRate == hwFormat.sampleRate` exception. A zero rate means
    /// no device at all, which becomes a user-facing error instead of a crash.
    private func resolveTapFormat() throws -> AVAudioFormat {
        var rebuilt = false
        while true {
            let input = engine.inputNode
            let hardware = input.inputFormat(forBus: 0)
            let output = input.outputFormat(forBus: 0)
            switch TapFormatDecision.decide(
                hardwareSampleRate: hardware.sampleRate,
                hardwareChannels: hardware.channelCount,
                outputSampleRate: output.sampleRate,
                outputChannels: output.channelCount,
                alreadyRebuilt: rebuilt
            ) {
            case .noInputDevice:
                throw AudioCaptureError.noInputDevice
            case .useOutputFormat:
                return output
            case .useHardwareFormat:
                return hardware
            case .rebuildGraph:
                rebuildEngine()
                applyInputDevice(uid: inputDeviceUID)
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                rebuilt = true
            }
        }
    }

    // MARK: - Segments

    /// VAD parameters in force for the running session (see `start(autoStopAfterSilence:)`).
    private var sessionVADEnabled = false
    private var sessionSilenceSeconds: Double = 1.5

    /// Whether the running capture can hand over a segment and keep going. False once a route
    /// change stopped the engine underneath us: that session must end through `stop()`.
    var canCutSegment: Bool {
        isRunning && !graphIsStale && !routeChangeFinishRequested && engine.isRunning
    }

    /// Returns everything captured since `start()` or the previous cut, and keeps capturing.
    ///
    /// Conversation mode's pause → deliver → keep listening. The tap, converter and engine stay
    /// exactly as they are, so there is no gap in which the next sentence's first syllable could
    /// be lost, no microphone-indicator flicker, and none of `start()`'s graph cost between
    /// turns. The accumulator and VAD restart from zero under the realtime lock, and VAD is
    /// re-armed (the pump disarms it after delivering an auto-stop). `lastSpeechLevel` then
    /// describes the returned segment, as it does after `stop()`.
    func cutSegment() -> [Float] {
        guard isRunning else { return [] }
        let cut = realtime.cutSegment(vadEnabled: sessionVADEnabled)
        lastSpeechLevel = cut.speechLevel
        return cut.samples
    }

    // MARK: - Stop / Cancel

    /// Loudness of the speech in the session that just ended (90th percentile of frame
    /// levels, normalized). Read after `stop()`; used to reject far-away voices.
    private(set) var lastSpeechLevel: Float = 0

    /// Stops capture and returns the accumulated 16 kHz mono samples.
    func stop() -> [Float] {
        guard isRunning else { return [] }
        teardownEngine()
        routeChangeFinishRequested = false
        lastSpeechLevel = realtime.speechLevel()
        let samples = realtime.drainSamples()
        realtime.reset()
        return samples
    }

    /// Stops capture and discards everything.
    func cancel() {
        guard isRunning else { return }
        teardownEngine()
        routeChangeFinishRequested = false
        realtime.reset()
    }

    // MARK: - Teardown helpers

    private func teardownEngine() {
        stopPump()
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        // Leave voice processing as configured; resetting it here can stall the
        // node. It is re-evaluated on the next `start()`.
        converter = nil
        isRunning = false
    }

    // MARK: - Route changes

    /// Registers for route changes on `engine` only. The observer is re-registered on every
    /// rebuild so a notification from a discarded engine can never act on the current one.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        // `queue: .main` makes the block run on the main thread, which is what lets it enter
        // the main actor synchronously instead of hopping through a Task.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }
    }

    /// AVAudioEngine has already stopped itself when this runs: the tap is silent, VAD will
    /// never fire, and the prepared graph describes a device that may be gone.
    ///
    /// While recording, the session ends through `onAutoStop` rather than re-tapping the new
    /// device and carrying on. Re-tapping mid-session looks simple but is not: AirPods post
    /// several changes while switching to their headset profile, the new input can report a
    /// zero format for a moment, and restarting into that fails or catches half a word from a
    /// different microphone at a different gain. Ending is deterministic, keeps every sample
    /// already captured (the accumulator is untouched until `stop()`), and reuses the exact
    /// path VAD auto-stop already exercises, so the coordinator transcribes what was said.
    private func handleConfigurationChange() {
        graphIsStale = true
        switch AudioRouteChangeAction.decide(
            isRecording: isRunning,
            finishAlreadyRequested: routeChangeFinishRequested
        ) {
        case .finishRecording:
            routeChangeFinishRequested = true
            onAutoStop?()
        case .rebuildIdleGraph:
            scheduleIdleRebuild()
        case .ignore:
            break
        }
    }

    /// Prepares a fresh graph for the new route once the burst of notifications settles, so
    /// the next dictation starts as cheaply as one after launch.
    private func scheduleIdleRebuild() {
        idleRebuildTask?.cancel()
        guard automaticRebuildsSinceStart < Self.maximumAutomaticRebuilds else { return }
        idleRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, !self.isRunning, self.graphIsStale else { return }
            self.idleRebuildTask = nil
            self.automaticRebuildsSinceStart += 1
            self.prearm()
        }
    }

    /// Replaces the engine with a new one. A route change leaves the old graph's nodes with
    /// cached formats for the previous device; a new engine re-reads the hardware from scratch.
    /// The old engine is not asked for its input node here — with no device present that
    /// access is exactly what we are trying to avoid.
    private func rebuildEngine() {
        if engine.isRunning { engine.stop() }
        let fresh = AVAudioEngine()
        engine = fresh
        converter = nil
        graphIsStale = false
        observeConfigurationChanges(of: fresh)
    }

    // MARK: - Level / VAD pump (main actor)

    private var pumpGeneration: UInt = 0

    /// Drives `onLevel` and `onAutoStop` from realtime state at ~50 Hz. Runs on
    /// a dedicated DispatchSource but always hops to the main actor to invoke
    /// the user callbacks, so callers observe them on `@MainActor`.

    private func startPump() {
        pumpGeneration &+= 1
        let generation = pumpGeneration
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        // ~50 Hz -> 20 ms interval, 5 ms leeway. Comfortably inside the
        // 40–60 callbacks/sec target.
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        let rt = realtime
        // `@Sendable` makes this handler NON-isolated so it can run on the timer's global
        // queue without tripping the main-actor executor assertion (the enclosing class is
        // @MainActor, so without this the closure is inferred @MainActor and crashes here).
        // We only touch the lock-protected realtime snapshot here, then hop to main.
        timer.setEventHandler { @Sendable [weak self] in
            let snapshot = rt.takeSnapshot()
            // Copying the new samples happens here, on the timer queue, not on the realtime
            // thread — and only when a live session asked for them.
            let newSamples = rt.takeNewSamples()
            guard snapshot.level != nil || snapshot.didAutoStop || newSamples != nil else { return }
            Task { @MainActor in
                guard let self, self.isRunning, self.pumpGeneration == generation else { return }
                if let level = snapshot.level {
                    self.onLevel?(level)
                }
                if let newSamples {
                    self.onSamples?(newSamples.samples, newSamples.offset)
                }
                if snapshot.didAutoStop {
                    self.onAutoStop?()
                }
            }
        }
        pump = timer
        timer.resume()
    }

    private func stopPump() {
        pump?.cancel()
        pump = nil
    }

    // MARK: - Input device selection

    /// Selects the Core Audio input device matching `uid` (or system default
    /// when nil) on the engine's audio unit. Best-effort: failures fall back to
    /// the current/default device silently.
    private func applyInputDevice(uid: String?) {
        // Only override the device when the user explicitly picked a non-default one that
        // resolves. Otherwise leave AVAudioEngine on its native system default — forcing the
        // device (even the default) via AudioUnitSetProperty can break capture (silent input).
        guard let uid, let deviceID = Self.audioDeviceID(forUID: uid),
              let audioUnit = engine.inputNode.audioUnit else { return }

        var mutableID = deviceID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    /// Resolves a device UID string to its `AudioDeviceID` by scanning all
    /// hardware devices.
    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var size = UInt32(0)
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            0,
            nil,
            &size
        ) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            0,
            nil,
            &size,
            &devices
        ) == noErr else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for device in devices {
            var cfUID: CFString? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            let status = withUnsafeMutablePointer(to: &cfUID) { ptr -> OSStatus in
                AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, ptr)
            }
            if status == noErr, let cfUID, (cfUID as String) == uid {
                return device
            }
        }
        return nil
    }

    // MARK: - Realtime processing (nonisolated; runs on the audio thread)

    /// Converts an input buffer to 16 kHz mono and pushes its samples + RMS
    /// frames into the lock-guarded accumulator. Static + nonisolated so it
    /// cannot accidentally capture `@MainActor` state.
    nonisolated private static func process(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        pooled: PooledConversionBuffer,
        into rt: RealtimeState
    ) {
        let inputFrames = buffer.frameLength
        guard inputFrames > 0 else { return }

        // Estimate output capacity from the sample-rate ratio (round up).
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inputFrames) * ratio) + 16

        // Reuse the session's pooled buffer; fall back to a one-off allocation only if the
        // system hands us a buffer larger than the pool was sized for (rare, and better a
        // slow callback than dropped audio).
        let outBuffer: AVAudioPCMBuffer
        if let reusable = pooled.buffer, reusable.frameCapacity >= outCapacity {
            reusable.frameLength = 0
            outBuffer = reusable
        } else if let fresh = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) {
            outBuffer = fresh
        } else {
            return
        }

        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, convError == nil else { return }

        let frames = Int(outBuffer.frameLength)
        guard frames > 0, let channel = outBuffer.floatChannelData?[0] else { return }

        // Hand the raw 16 kHz mono frames to the accumulator. RMS/VAD are
        // computed inside under the lock to keep one critical section.
        rt.append(samples: channel, count: frames)
    }
}

// MARK: - PooledConversionBuffer

/// The tap's reusable 16 kHz output buffer. `@unchecked Sendable` is justified the same way
/// `RealtimeState`'s is: the buffer is touched only inside the tap callback, and AVFAudio
/// serialises those — one callback at a time, one thread at a time.
private final class PooledConversionBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer?
    init(format: AVAudioFormat, capacity: AVAudioFrameCount) {
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
    }
}

// MARK: - Energy VAD

/// Allocation-free energy VAD used by the realtime accumulator.
///
/// Speech start is deliberately independent of the user's end-silence sensitivity. Coupling the
/// two made sensitivity 4–5 unable to arm at the measured 0.10–0.15 normal dictation level. Once
/// armed, the reference may rise only after three sustained stronger frames. It must not stay
/// pinned to a quiet onset, nor ratchet down into room noise at the end of an utterance.
///
/// The 30-frame window is exactly 300 ms because production feeds exact 160-sample frames. Its
/// minimum is the trailing energy floor and its range identifies stationary fan/air-conditioner
/// steps. A stationary source counts as silence only after a clearly higher speech peak; energy
/// alone cannot distinguish a perfectly constant voice from an equally loud fan, so valid speech
/// always wins that ambiguous case.
struct EnergyVoiceActivityDetector: Sendable {
    private static let speechStartFrames = 3
    private static let trailingFrameCount = 30
    private static let speechStartThreshold: Float = 0.04

    private let silenceThreshold: Float
    private let continuationRatio: Float
    private let backgroundRatio: Float
    private let neededSilenceSamples: Int

    private var trailingLevels = [Float](repeating: 0, count: Self.trailingFrameCount)
    private var trailingCount = 0
    private var trailingIndex = 0
    private var stationaryNoiseCeiling: Float?
    private var isRebasingStationaryNoise = false
    private var rebasePreviousSawSpeech = false
    private var rebasePreviousSpeechReference: Float?
    private var rebasePreviousOnsetReference: Float?
    private var rebasePreviousSpeechPeak: Float?
    private var rebasePreviousSilentSampleRun = 0
    private var consecutiveSpeechFrames = 0
    private var candidateSpeechFloor: Float?
    private var candidateSpeechPeak: Float?
    private var speechReference: Float?
    // Keep the onset's permissive continuation cap even when sustained volume rises. Raising
    // that cap too would misclassify a later, quieter sentence as background noise.
    private var onsetSpeechReference: Float?
    private var speechPeak: Float?
    private var strongerSpeechFrames = 0
    private var strongerSpeechFloor: Float?
    private var weakContinuationFrames = 0
    private var weakContinuationSamples = 0
    private var silentSampleRun = 0
    private var sawSpeech = false
    private var stopped = false

    init(silenceSeconds: Double = 1.5, sensitivity: Int = 3, sampleRate: Double = 16_000) {
        // 1 (relaxed) only calls genuinely quiet input silence; 5 (strict) is more eager.
        let s = Float(min(5, max(1, sensitivity)))
        silenceThreshold = 0.02 + (s - 1) / 4 * (0.12 - 0.02)
        continuationRatio = 0.65 + (s - 1) / 4 * (0.90 - 0.65)
        // Input well below sustained voice is background even when it fluctuates too much for
        // the stationary-noise detector. Keep relaxed settings more tolerant of quiet speech.
        backgroundRatio = 0.125 + (s - 1) / 4 * (0.225 - 0.125)
        neededSilenceSamples = max(1, Int((max(0, silenceSeconds) * max(1, sampleRate)).rounded(.up)))
    }

    mutating func reset() {
        trailingCount = 0
        trailingIndex = 0
        stationaryNoiseCeiling = nil
        isRebasingStationaryNoise = false
        rebasePreviousSawSpeech = false
        rebasePreviousSpeechReference = nil
        rebasePreviousOnsetReference = nil
        rebasePreviousSpeechPeak = nil
        rebasePreviousSilentSampleRun = 0
        consecutiveSpeechFrames = 0
        candidateSpeechFloor = nil
        candidateSpeechPeak = nil
        speechReference = nil
        onsetSpeechReference = nil
        speechPeak = nil
        strongerSpeechFrames = 0
        strongerSpeechFloor = nil
        weakContinuationFrames = 0
        weakContinuationSamples = 0
        silentSampleRun = 0
        sawSpeech = false
        stopped = false
    }

    /// Returns `true` exactly once, when post-speech silence reaches the configured duration.
    mutating func consume(level rawLevel: Float, sampleCount: Int) -> Bool {
        guard !stopped, sampleCount > 0 else { return false }
        let level = min(1, max(0, rawLevel))
        updateTrailingWindow(with: level)

        if let ceiling = stationaryNoiseCeiling,
           level > max(Self.speechStartThreshold, ceiling * 1.6) {
            // A real voice rose clearly above an established stationary source.
            if !isRebasingStationaryNoise, (speechPeak ?? 0) <= ceiling * 1.25 {
                // The stationary source had previously satisfied the cheap three-frame gate.
                // Rebase now that an unambiguous voice onset exists; do not let the source's
                // lower level cap this utterance's continuation threshold. The old state is
                // kept transactionally until all three new speech frames validate.
                rebasePreviousSawSpeech = sawSpeech
                rebasePreviousSpeechReference = speechReference
                rebasePreviousOnsetReference = onsetSpeechReference
                rebasePreviousSpeechPeak = speechPeak
                rebasePreviousSilentSampleRun = silentSampleRun + weakContinuationSamples
                sawSpeech = false
                consecutiveSpeechFrames = 0
                candidateSpeechFloor = nil
                candidateSpeechPeak = nil
                speechReference = nil
                onsetSpeechReference = nil
                speechPeak = nil
                strongerSpeechFrames = 0
                strongerSpeechFloor = nil
                weakContinuationFrames = 0
                weakContinuationSamples = 0
                silentSampleRun = 0
                isRebasingStationaryNoise = true
            }
        }

        if let ceiling = stationaryNoiseCeiling,
           let speechPeak,
           speechPeak > ceiling * 1.25,
           level <= ceiling * 1.25 {
            consecutiveSpeechFrames = 0
            candidateSpeechFloor = nil
            candidateSpeechPeak = nil
            return countSilence(sampleCount)
        }

        if !sawSpeech {
            let stationaryMultiplier: Float = consecutiveSpeechFrames == 0 ? 1.6 : 1.25
            let threshold = max(
                Self.speechStartThreshold,
                (stationaryNoiseCeiling ?? 0) * stationaryMultiplier
            )
            updateSpeechStart(level: level, threshold: threshold)
            if sawSpeech {
                stationaryNoiseCeiling = nil
                clearRebaseBackup()
            } else if isRebasingStationaryNoise, consecutiveSpeechFrames == 0 {
                sawSpeech = rebasePreviousSawSpeech
                speechReference = rebasePreviousSpeechReference
                onsetSpeechReference = rebasePreviousOnsetReference
                speechPeak = rebasePreviousSpeechPeak
                silentSampleRun = rebasePreviousSilentSampleRun
                clearRebaseBackup()
            }
            return false
        }

        updateSustainedSpeechReference(level: level)
        let floorThreshold = max(silenceThreshold, trailingNoiseFloor * 1.6)
        let speechBound = (onsetSpeechReference ?? floorThreshold) * continuationRatio
        let continuationThreshold = max(
            min(floorThreshold, speechBound),
            (speechReference ?? 0) * backgroundRatio
        )
        if level >= continuationThreshold {
            // A strong onset stays immediate, including a short consonant. Only weak energy
            // during a pause needs the same three-frame proof as speech start; one or two
            // noise frames must not restart the user's entire silence timeout.
            if silentSampleRun > 0, level < (speechReference ?? level) {
                weakContinuationFrames += 1
                weakContinuationSamples += sampleCount
                guard weakContinuationFrames >= Self.speechStartFrames else { return false }
            }
            silentSampleRun = 0
            weakContinuationFrames = 0
            weakContinuationSamples = 0
            speechPeak = max(speechPeak ?? level, level)
            return false
        }
        return countSilence(sampleCount)
    }

    private var trailingNoiseFloor: Float {
        guard trailingCount > 0 else { return 0 }
        var floor = trailingLevels[0]
        for index in 1..<trailingCount {
            floor = min(floor, trailingLevels[index])
        }
        return floor
    }

    private mutating func updateSpeechStart(level: Float, threshold: Float) {
        guard !sawSpeech else { return }
        if level >= threshold {
            consecutiveSpeechFrames += 1
            if let floor = candidateSpeechFloor {
                candidateSpeechFloor = min(floor, level)
            } else {
                candidateSpeechFloor = level
            }
            candidateSpeechPeak = max(candidateSpeechPeak ?? level, level)
            if consecutiveSpeechFrames >= Self.speechStartFrames {
                sawSpeech = true
                speechReference = candidateSpeechFloor
                onsetSpeechReference = candidateSpeechFloor
                speechPeak = candidateSpeechPeak
                silentSampleRun = 0
            }
        } else {
            consecutiveSpeechFrames = 0
            candidateSpeechFloor = nil
            candidateSpeechPeak = nil
        }
    }

    private mutating func countSilence(_ sampleCount: Int) -> Bool {
        // Unvalidated continuation frames belong to this same pause, not to a new timeout.
        silentSampleRun += weakContinuationSamples + sampleCount
        weakContinuationFrames = 0
        weakContinuationSamples = 0
        strongerSpeechFrames = 0
        strongerSpeechFloor = nil
        if silentSampleRun >= neededSilenceSamples {
            stopped = true
            return true
        }
        return false
    }

    private mutating func updateSustainedSpeechReference(level: Float) {
        guard let reference = speechReference, level > reference * 1.1 else {
            strongerSpeechFrames = 0
            strongerSpeechFloor = nil
            return
        }
        strongerSpeechFrames += 1
        strongerSpeechFloor = min(strongerSpeechFloor ?? level, level)
        guard strongerSpeechFrames >= Self.speechStartFrames,
              let validatedReference = strongerSpeechFloor,
              validatedReference > reference else { return }
        speechReference = validatedReference
        // A ceiling at or above this new reference came from the previous speech, not a
        // quieter established fan. Preserve real room-noise estimates below the reference.
        if let ceiling = stationaryNoiseCeiling, ceiling >= validatedReference {
            stationaryNoiseCeiling = nil
        }
        strongerSpeechFrames = 0
        strongerSpeechFloor = nil
    }

    private mutating func clearRebaseBackup() {
        isRebasingStationaryNoise = false
        rebasePreviousSawSpeech = false
        rebasePreviousSpeechReference = nil
        rebasePreviousOnsetReference = nil
        rebasePreviousSpeechPeak = nil
        rebasePreviousSilentSampleRun = 0
    }

    private mutating func updateTrailingWindow(with level: Float) {
        trailingLevels[trailingIndex] = level
        trailingIndex = (trailingIndex + 1) % Self.trailingFrameCount
        trailingCount = min(Self.trailingFrameCount, trailingCount + 1)

        guard trailingCount == Self.trailingFrameCount else { return }
        var low = trailingLevels[0]
        var high = trailingLevels[0]
        for index in 1..<Self.trailingFrameCount {
            low = min(low, trailingLevels[index])
            high = max(high, trailingLevels[index])
        }
        let allowedSpread = max(0.008, high * 0.25)
        if high - low <= allowedSpread {
            stationaryNoiseCeiling = high
        }
    }
}

/// Turns arbitrarily-sized converted callbacks into the 160-sample / 10 ms RMS frames the VAD
/// contract specifies. All storage is scalar; a callback can end midway through a frame and the
/// carry is completed by the next callback without allocating or rounding time. The detector's
/// fixed 30-frame window is allocated during configuration, never in this realtime method.
struct EnergyVoiceActivityPipeline: Sendable {
    static let referenceRMS: Float = 0.0316
    private static let frameSampleCount = 160

    private var detector: EnergyVoiceActivityDetector
    private var pendingSumSquares: Float = 0
    private var pendingSampleCount = 0

    init(silenceSeconds: Double = 1.5, sensitivity: Int = 3, sampleRate: Double = 16_000) {
        detector = EnergyVoiceActivityDetector(
            silenceSeconds: silenceSeconds,
            sensitivity: sensitivity,
            sampleRate: sampleRate
        )
    }

    mutating func reset() {
        detector.reset()
        pendingSumSquares = 0
        pendingSampleCount = 0
    }

    mutating func consume(samples: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return false }
        var offset = 0
        while offset < count {
            let take = min(Self.frameSampleCount - pendingSampleCount, count - offset)
            for index in 0..<take {
                let value = samples[offset + index]
                pendingSumSquares += value * value
            }
            pendingSampleCount += take
            offset += take

            if pendingSampleCount == Self.frameSampleCount {
                let rms = (pendingSumSquares / Float(Self.frameSampleCount)).squareRoot()
                let level = min(1, max(0, rms / Self.referenceRMS))
                pendingSumSquares = 0
                pendingSampleCount = 0
                if detector.consume(level: level, sampleCount: Self.frameSampleCount) {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - RealtimeState

/// Thread-safe accumulator + VAD tracker shared between the realtime audio
/// thread (writes via `append`) and the main-actor pump (reads via
/// `takeSnapshot` / `drainSamples`).
///
/// `@unchecked Sendable` is justified: every stored property is accessed only
/// while holding `lock`. The lock is an `os_unfair_lock` (cheap, non-reentrant)
/// held for tiny bounded sections — safe to take briefly on a realtime thread.
final class RealtimeState: @unchecked Sendable {

    /// A five-minute recording is 19.2 MB at the fixed 16 kHz Float32 output rate. The hard cap
    /// auto-stops before either array can grow under `lock`, while preserving a 3–4 minute
    /// utterance in full.
    private static let preallocatedRecordingSeconds = 5 * 60
    private static let outputSamplesPerSecond = 16_000
    private static let maximumTapCallbacksPerSecond = 100

    private let lock = OSAllocatedUnfairLock()

    // All fields below are protected by `lock`.
    private var samples: [Float] = []
    /// Normalized level of every frame in the session, used after the fact to judge how
    /// close the speaker was. A minute of dictation is a few thousand floats.
    private var frameLevels: [Float] = []

    // Level metering: peak RMS-derived level accumulated since last snapshot.
    private var pendingLevel: Float = 0
    private var hasPendingLevel = false

    // VAD configuration / running state.
    private var vadEnabled = false
    private var voiceActivityPipeline = EnergyVoiceActivityPipeline()
    private var didAutoStop = false

    // Incremental feed for live transcription. `streamCursor` is how far a streaming consumer
    // has read into `samples`; the array itself is never trimmed by it.
    private var incremental = false
    private var streamCursor = 0

    // Reference level for normalization: ~ -30 dBFS RMS maps to 1.0.
    // 10^(-30/20) ≈ 0.0316.
    private let referenceRMS = EnergyVoiceActivityPipeline.referenceRMS
    private let sampleCapacity: Int
    private let frameLevelCapacity: Int

    init(
        sampleCapacity: Int = RealtimeState.outputSamplesPerSecond * RealtimeState.preallocatedRecordingSeconds,
        frameLevelCapacity: Int = RealtimeState.maximumTapCallbacksPerSecond * RealtimeState.preallocatedRecordingSeconds
    ) {
        self.sampleCapacity = max(1, sampleCapacity)
        self.frameLevelCapacity = max(1, frameLevelCapacity)
        samples.reserveCapacity(self.sampleCapacity)
        frameLevels.reserveCapacity(self.frameLevelCapacity)
    }

    func configureVAD(enabled: Bool, silenceSeconds: Double, sensitivity: Int, outputSampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        vadEnabled = enabled
        voiceActivityPipeline = EnergyVoiceActivityPipeline(
            silenceSeconds: silenceSeconds,
            sensitivity: sensitivity,
            sampleRate: outputSampleRate
        )
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        frameLevels.removeAll(keepingCapacity: true)
        pendingLevel = 0
        hasPendingLevel = false
        voiceActivityPipeline.reset()
        didAutoStop = false
    }

    /// Realtime path: append converted samples and update level + VAD.
    /// `ptr` is valid only for the duration of this call.
    func append(samples ptr: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }

        // Compute sum-of-squares outside the lock (pure local math, no shared
        // state) to minimize the critical section.
        var sumSquares: Float = 0
        for i in 0..<count {
            let v = ptr[i]
            sumSquares += v * v
        }
        let rms = (sumSquares / Float(count)).squareRoot()

        // Normalize to 0...1 against the speech reference, clamp.
        var level = rms / referenceRMS
        if level > 1 { level = 1 }
        if level < 0 { level = 0 }

        lock.lock()
        defer { lock.unlock() }
        guard count <= sampleCapacity - samples.count, frameLevels.count < frameLevelCapacity else {
            // Do not permit Array's geometric growth in the render callback. The pump delivers
            // this through the ordinary auto-stop route, so all prior audio remains available.
            didAutoStop = true
            return
        }
        // Append raw samples for transcription.
        samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
        frameLevels.append(level)

        // Track the peak level since the last snapshot (so the waveform shows
        // responsive transients even when the pump samples slower than buffers).
        if !hasPendingLevel || level > pendingLevel {
            pendingLevel = level
            hasPendingLevel = true
        }

        // VAD evaluation.
        if vadEnabled, !didAutoStop,
           voiceActivityPipeline.consume(samples: ptr, count: count) {
            didAutoStop = true
        }
    }

    /// How loud the speech in this session actually was, as the 90th percentile of frame
    /// levels — robust against both the silent gaps between words and a single door slam.
    ///
    /// This is the number that separates the user dictating from a conversation across the
    /// room: distance costs roughly 6 dB per doubling, so someone three metres away lands far
    /// below someone speaking at a laptop.
    func speechLevel() -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard !frameLevels.isEmpty else { return 0 }
        var sorted = frameLevels
        sorted.sort()
        let index = Int(Double(sorted.count - 1) * 0.9)
        return sorted[index]
    }

    /// Turn the incremental feed on or off, and rebase its cursor to "now".
    ///
    /// Off by default so a session with no streaming consumer never pays for the copy below.
    func setIncremental(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        incremental = on
        streamCursor = samples.count
    }

    /// Samples captured since the last call, or nil when there is nothing new.
    ///
    /// Called from the pump's timer queue, never from the realtime thread — so the copy here
    /// cannot stall audio. It also never removes anything: `drainSamples()` at the end of the
    /// session still returns the complete utterance, because a partial transcript must never
    /// be able to degrade the final one.
    func takeNewSamples() -> (samples: [Float], offset: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard incremental, streamCursor < samples.count else { return nil }
        let offset = streamCursor
        let out = Array(samples[offset...])
        streamCursor = samples.count
        return (out, offset)
    }

    /// Snapshot for the main-actor pump: returns the latest level (if any) and
    /// whether an auto-stop fired, clearing the level so each is delivered once.
    func takeSnapshot() -> (level: Float?, didAutoStop: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let level: Float? = hasPendingLevel ? pendingLevel : nil
        hasPendingLevel = false
        pendingLevel = 0
        let stop = didAutoStop
        // Latch: deliver auto-stop exactly once.
        if didAutoStop {
            didAutoStop = false
            // Disable further VAD so we don't fire again before teardown.
            vadEnabled = false
        }
        return (level, stop)
    }

    /// Hands over the segment captured so far while the tap keeps appending: the samples, the
    /// segment's speech level, and a fresh accumulator + VAD for the next segment.
    ///
    /// Unlike `drainSamples` this runs while the realtime thread is live, so the lock must not
    /// be held across anything unbounded. The copies below are forced (`withUnsafeBufferPointer`)
    /// so `removeAll(keepingCapacity:)` then finds uniquely referenced storage and does not
    /// allocate a fresh five-minute buffer inside the critical section. The percentile sort
    /// happens after the lock is released.
    func cutSegment(vadEnabled: Bool) -> (samples: [Float], speechLevel: Float) {
        lock.lock()
        let out = samples.withUnsafeBufferPointer { Array($0) }
        let levels = frameLevels.withUnsafeBufferPointer { Array($0) }
        samples.removeAll(keepingCapacity: true)
        frameLevels.removeAll(keepingCapacity: true)
        streamCursor = 0
        voiceActivityPipeline.reset()
        didAutoStop = false
        self.vadEnabled = vadEnabled
        lock.unlock()

        guard !levels.isEmpty else { return (out, 0) }
        let sorted = levels.sorted()
        return (out, sorted[Int(Double(sorted.count - 1) * 0.9)])
    }

    /// Returns and removes the accumulated samples (called on `stop()`).
    func drainSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let out = samples
        samples.removeAll(keepingCapacity: true)
        return out
    }
}

import Foundation

/// Errors `AudioCaptureEngine.start()` raises for capture problems the user can act on.
enum AudioCaptureError: LocalizedError, Equatable {
    /// The input node reports a zero sample rate or no channels: no microphone is connected,
    /// or the one just selected is still switching (AirPods moving to their headset profile).
    case noInputDevice
    /// The audio converter to 16 kHz mono could not be built for the device's format.
    case unsupportedInputFormat
    /// `AVAudioEngine.start()` failed even on a freshly built graph.
    case engineFailedToStart(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return String(localized: "No microphone available. Connect one or choose another input in Settings.",
                          comment: "Microphone error")
        case .unsupportedInputFormat:
            return String(localized: "This microphone's audio format isn't supported.", comment: "Microphone error")
        case .engineFailedToStart(let reason):
            return String(localized: "The microphone couldn't start: \(reason)",
                          comment: "Microphone error; the argument is the system reason")
        }
    }
}

/// What `AudioCaptureEngine` does when `AVAudioEngineConfigurationChange` arrives.
///
/// The notification means the hardware route changed (AirPods or a USB microphone connected or
/// disconnected, the default input switched, a sample-rate change). AVAudioEngine has already
/// stopped itself by then, so a running session's tap is silent from that moment on, and a
/// prepared-but-idle graph still carries the old device's format.
enum AudioRouteChangeAction: Equatable, Sendable {
    /// A session is recording: keep everything captured so far and end the session through
    /// the ordinary auto-stop path, so the coordinator transcribes what the user already said.
    case finishRecording
    /// Nothing is recording: throw the stale graph away and prepare a fresh one for the new
    /// route, so the next `start()` neither fails nor trips the tap's format assertion.
    case rebuildIdleGraph
    /// Already handled: the session was told to finish and is waiting for `stop()`. Route
    /// changes arrive in bursts, and the coordinator must see exactly one stop request.
    case ignore

    static func decide(isRecording: Bool, finishAlreadyRequested: Bool) -> AudioRouteChangeAction {
        guard isRecording else { return .rebuildIdleGraph }
        return finishAlreadyRequested ? .ignore : .finishRecording
    }
}

/// Picks the format to install the input tap with, from the two formats the input node reports.
///
/// `installTap` raises an Objective-C exception (`format.sampleRate == hwFormat.sampleRate`),
/// which Swift cannot catch, whenever the tap format's rate differs from the hardware's. After a
/// route change the node's *output* format can still describe the previous device while its
/// *input* format (the hardware side) already describes the new one, so the output format alone
/// is not safe to trust.
enum TapFormatDecision: Equatable, Sendable {
    /// No usable input: surface `AudioCaptureError.noInputDevice` instead of crashing.
    case noInputDevice
    /// The output format agrees with the hardware; tap with it (the normal case).
    case useOutputFormat
    /// The output format is stale. Rebuild the graph once, then decide again.
    case rebuildGraph
    /// Still mismatched after a rebuild: tap with the hardware format, the one the assertion
    /// checks against.
    case useHardwareFormat

    static func decide(
        hardwareSampleRate: Double,
        hardwareChannels: UInt32,
        outputSampleRate: Double,
        outputChannels: UInt32,
        alreadyRebuilt: Bool
    ) -> TapFormatDecision {
        guard hardwareSampleRate > 0, hardwareChannels > 0 else { return .noInputDevice }
        if outputSampleRate == hardwareSampleRate, outputChannels > 0 { return .useOutputFormat }
        return alreadyRebuilt ? .useHardwareFormat : .rebuildGraph
    }
}

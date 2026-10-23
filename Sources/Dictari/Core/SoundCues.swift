// SoundCues.swift
// Dictari — the start/stop earcons, and the reason they are not one `NSSound` each.
//
// The cues used to be `NSSound(named:)?.play()` called inline on the coordinator. Two
// measurements killed that:
//
// 1. `NSSound(named:)` hands back the *same cached instance* every time (verified: two
//    lookups of "Tink" return one identical object), and `play()` on an instance that is
//    already playing returns `false` and does nothing. The system cues are long — "Tink"
//    runs 0.564 s and "Pop" runs 1.627 s — while a dictation only has to last
//    `AccidentalSession.misTapSeconds` (0.35 s) to count. So any two dictations closer
//    together than the cue's own length silently dropped the second cue. That is exactly the
//    reported "the sounds break when you go fast": they were not glitching, they were missing.
//
// 2. `play()` blocks its caller for ~10 ms warm (~40–90 ms on the very first call, which
//    spins up the process's audio output), because it is a synchronous round trip to
//    coreaudiod. Both cues sit directly on the start-dictation and stop→inject paths, where
//    latency is a product requirement — so that cost may not be paid on the main actor.
//
// Hence: a small pool of pre-loaded, pre-prepared players per cue, driven from a dedicated
// serial queue. Nothing is ever dropped (a fresh slot is always available), cues overlap
// instead of cutting each other off, and the main actor only pays a dispatch hop.
//
// `AVAudioPlayer` rather than `NSSound` for three reasons, in order of weight:
//   - `NSSound` is AppKit, so it is main-thread-only, which forbids the one thing we need
//     most: getting that ~10 ms off the main actor. `AVAudioPlayer` is AVFAudio and is fine
//     to drive from our own serial queue.
//   - `prepareToPlay()` is the documented way to pre-allocate the hardware buffers, so the
//     pool can absorb the expensive part at launch.
//   - `NSSound.isPlaying` only settles via the runloop, so a busy main actor — precisely the
//     moment a dictation starts — makes it lie about which instances are free.
// The trade-off accepted: `NSSound` routes to the system *alert* device and honours the alert
// volume slider; `AVAudioPlayer` plays through the default output at the app's own volume.

import AVFoundation
import Foundation

// MARK: - SoundCues

/// The two earcons that bracket a dictation. Owned by `AppCoordinator`; call
/// `playStart()` / `playStop()` freely, including faster than the cues themselves last.
@MainActor
final class SoundCues {

    /// Mirrors `SettingsData.soundCues`. Pushed in by the coordinator's `configureComponents()`;
    /// checked on the main actor so a disabled cue costs nothing at all.
    var enabled: Bool = true

    private let pool = CuePool()

    init() {
        // Decoding and preparing eight players costs tens of milliseconds. Do it now, off the
        // main actor, so the first dictation of the session is as cheap as the tenth.
        pool.preload()
    }

    // MARK: Playback

    func playStart() {
        guard enabled else { return }
        pool.play(.start)
    }

    func playStop() {
        guard enabled else { return }
        pool.play(.stop)
    }
}

// MARK: - Cue

/// Which earcon. The raw values are `NSSound`-style names resolved through the standard
/// sound search path, so a future bundled `Start.aiff` would take precedence over the system
/// one without any code change here.
private enum Cue: String, CaseIterable, Sendable {
    case start = "Tink"
    case stop = "Pop"
}

// MARK: - CuePool

/// The players themselves, and the queue that owns them.
///
/// `@unchecked Sendable` is justified the same way `AudioCaptureEngine.RealtimeState` is:
/// every stored property is touched only from `queue`, which is serial. Nothing here is ever
/// read from the main actor, so there is no shared state to synchronise beyond that.
private final class CuePool: @unchecked Sendable {

    /// Serial on purpose: it is what makes the queue-confinement claim above true, and cue
    /// playback is a strictly ordered, once-in-a-while event. `.userInitiated` rather than
    /// `.userInteractive` so a cue never contends with the capture engine's realtime thread —
    /// the audible delay lives inside `play()`'s coreaudiod round trip either way.
    private let queue = DispatchQueue(label: "com.subralabs.Dictari.sound-cues", qos: .userInitiated)

    /// Ready-to-play instances per cue. Queue-confined.
    private var players: [Cue: [AVAudioPlayer]] = [:]
    /// Next slot to steal per cue when every instance is still ringing. Queue-confined.
    private var nextSlot: [Cue: Int] = [:]

    /// Four instances per cue. The longest cue is "Pop" at 1.627 s and the shortest dictation
    /// that counts is 0.35 s, so back-to-back sessions can put roughly four copies of the stop
    /// cue in the air at once. Four slots covers that; beyond it the oldest is restarted, which
    /// is both inaudible in practice and better than dropping the cue.
    private static let slotsPerCue = 4

    // MARK: Preload

    func preload() {
        queue.async { [self] in
            for cue in Cue.allCases where players[cue] == nil {
                players[cue] = Self.makePlayers(for: cue)
            }
        }
    }

    // MARK: Play

    func play(_ cue: Cue) {
        queue.async { [self] in
            // Load on demand if a cue fires before `preload()` got there. This costs the first
            // cue a few milliseconds on *this* queue, never on the main actor, and it is the
            // reason a cue can be late but never silently missing.
            let pool: [AVAudioPlayer]
            if let existing = players[cue] {
                pool = existing
            } else {
                pool = Self.makePlayers(for: cue)
                players[cue] = pool
            }
            guard !pool.isEmpty else { return }

            // Prefer a genuinely idle instance so the still-ringing one is left to finish.
            if let free = pool.first(where: { !$0.isPlaying }) {
                Self.restart(free)
                return
            }

            // Every instance is still sounding: recycle round-robin. Not strictly the oldest,
            // but this branch only happens past four simultaneous cues, where the difference
            // is not audible.
            let index = nextSlot[cue] ?? 0
            nextSlot[cue] = (index + 1) % pool.count
            Self.restart(pool[index])
        }
    }

    private static func restart(_ player: AVAudioPlayer) {
        // Rewinding rather than allocating keeps the prepared hardware buffers; a player that
        // has never played is already at zero, so this is safe for a fresh slot too.
        player.currentTime = 0
        player.play()
    }

    // MARK: Loading

    private static func makePlayers(for cue: Cue) -> [AVAudioPlayer] {
        guard let url = soundURL(named: cue.rawValue),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }

        // One copy of the bytes shared by every player — `AVAudioPlayer(data:)` retains it
        // rather than duplicating the file per slot.
        return (0..<slotsPerCue).compactMap { _ in
            guard let player = try? AVAudioPlayer(data: data) else { return nil }
            // The whole point of the pool: pay for the output buffers here, not at cue time.
            player.prepareToPlay()
            return player
        }
    }

    /// Resolves a sound name the way `NSSound(named:)` documents it — app bundle first, then
    /// the user's, the local and finally the system sound folders — so behaviour does not
    /// regress now that we no longer go through AppKit, and a user-installed override in
    /// `~/Library/Sounds` keeps working.
    private static func soundURL(named name: String) -> URL? {
        let extensions = ["aiff", "aif", "caf", "wav", "m4a", "aac", "mp3"]

        for ext in extensions {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        }

        let library = FileManager.default.urls(for: .libraryDirectory, in: [.userDomainMask, .localDomainMask, .systemDomainMask])
        for directory in library {
            let sounds = directory.appendingPathComponent("Sounds", isDirectory: true)
            for ext in extensions {
                let candidate = sounds.appendingPathComponent(name).appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}

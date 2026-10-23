// LevelBuffer.swift
// Dictari — the microphone level history the pill draws from.
//
// Deliberately NOT an @Observable property on the coordinator. Levels arrive ~50 times a
// second while dictating, and every mutation of an observed property invalidates each view
// that reads it. The pill's meters are driven by TimelineView at display rate and re-read the
// newest value on every frame anyway, so those fifty invalidations per second bought nothing
// and cost a full SwiftUI diff each. Passing this reference lets the Canvas read current data
// with no view graph involvement at all.
//
// Fixed-capacity ring buffer: writing never allocates and never shifts elements. The previous
// implementation appended to an Array and then called `removeFirst`, which is O(n) and ran on
// every sample.

import Foundation

/// Rolling window of normalized input levels (0...1), newest last.
///
/// Main-actor isolated: written by the coordinator's audio pump and read by the pill's
/// drawing code, both of which run on the main actor.
@MainActor
final class LevelBuffer {

    /// Enough history to fill the waveform with room to spare.
    static let capacity = 64

    private var storage = [Float](repeating: 0, count: LevelBuffer.capacity)
    /// Index the next sample will be written to.
    private var head = 0
    /// How many samples have been written, capped at `capacity`.
    private(set) var count = 0

    /// Newest sample, or 0 when nothing has been recorded yet.
    private(set) var latest: Float = 0

    func append(_ level: Float) {
        let clamped = max(0, min(1, level))
        storage[head] = clamped
        head = (head + 1) % Self.capacity
        if count < Self.capacity { count += 1 }
        latest = clamped
    }

    func reset() {
        for index in storage.indices { storage[index] = 0 }
        head = 0
        count = 0
        latest = 0
    }

    /// Sample `offset` positions back from the newest (0 = newest). Returns 0 when the
    /// requested position predates what we hold.
    func sample(fromNewest offset: Int) -> Float {
        guard offset >= 0, offset < count else { return 0 }
        let index = (head - 1 - offset + Self.capacity * 2) % Self.capacity
        return storage[index]
    }

    /// True when any retained sample carries meaningful energy.
    func hasSignal(threshold: Float = 0.02) -> Bool {
        guard count > 0 else { return false }
        for offset in 0..<count where sample(fromNewest: offset) > threshold { return true }
        return false
    }
}

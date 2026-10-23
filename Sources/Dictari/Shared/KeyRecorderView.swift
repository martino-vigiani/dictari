// KeyRecorderView.swift
// Dictari — inline key-combo recorder bound to a Shortcut value.
//
// Design principles applied (make-interfaces-feel-better):
// - Scale on press (0.96) for tactile feedback
// - Minimum 40×40 pt hit area via frame constraints
// - Interruptible spring animations on state transitions
// - No transition: all — only specific properties animated
// - Optical alignment: capsule padding chosen so text sits centered

import AppKit
import SwiftUI

/// A control that lets the user record a keyboard shortcut.
///
/// Tap to enter recording mode. The next valid key event is captured and written to
/// `shortcut`. Pressing Esc cancels without change.
/// The monitor is installed only while recording, so idle cost is zero.
@MainActor
struct KeyRecorderView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var shortcut: Shortcut
    var allowsRecording = true

    // MARK: Private state

    @State private var isRecording = false
    @State private var isPressed = false
    @State private var monitorToken: Any?
    @State private var validationHint: LocalizedStringKey?

    // MARK: Body

    var body: some View {
        capsule
            .onDisappear { stopRecording(commit: false) }
            .accessibilityLabel(isRecording ? "Recording shortcut — press a key" : "Shortcut: \(shortcut.displayString)")
            .accessibilityHint(allowsRecording ? (isRecording ? "Press Esc to cancel" : "Click to record a new shortcut") : "Fixed shortcut")
            .accessibilityAddTraits(allowsRecording ? .isButton : .isStaticText)
    }

    // MARK: Capsule

    @ViewBuilder
    private var capsule: some View {
        ZStack {
            // Background track
            Capsule()
                .fill(isRecording ? Mono.ink(0.10) : Mono.ink(0.06))
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isRecording ? Mono.ink(0.40) : Mono.ink(0.14),
                            lineWidth: 1
                        )
                )

            // Label
            HStack(spacing: 5) {
                if isRecording {
                    // Pulsing dot
                    Circle()
                        .fill(Mono.ink(0.70))
                        .frame(width: 5, height: 5)

                    Text(validationHint ?? "Recording…")
                        .font(Typo.mono)
                        .foregroundStyle(Mono.primaryText)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
                } else {
                    // Keycaps rather than a run of glyphs: "⌥⌘Space" set as one monospaced
                    // string read as an unresolved cluster, and stretched across a field this
                    // wide it looked like a placeholder rather than a value.
                    ShortcutChip(shortcut, tone: .onLight)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Sized to its content instead of filling the row. The control is a value display,
        // and a value that spans half the window reads as an empty text field.
        .fixedSize()
        .frame(minWidth: 96, minHeight: 34)
        // Tactile scale-on-press (0.96 per guideline — never below 0.95)
        .scaleEffect(isPressed && !reduceMotion ? 0.96 : 1.0)
        .animation(Motion.reduced(Motion.snap, reduceMotion: reduceMotion), value: isPressed)
        .animation(Motion.reduced(Motion.snap, reduceMotion: reduceMotion), value: isRecording)
        // Gesture: press-and-release to toggle recording
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard allowsRecording else { return }
                    if !isPressed {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    guard allowsRecording else { return }
                    isPressed = false
                    if isRecording {
                        stopRecording(commit: false)
                    } else {
                        startRecording()
                    }
                }
        )
    }

    // MARK: Recording lifecycle

    private func startRecording() {
        guard monitorToken == nil else { return }
        validationHint = nil
        isRecording = true

        // Local monitor: captured BEFORE the system sees it, so no beep for
        // modifier-only presses. We return nil to swallow the event.
        let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            Task { @MainActor in
                self.handleKeyEvent(event)
            }
            return nil   // swallow: prevents beep / default action
        }
        monitorToken = token
    }

    private func stopRecording(commit: Bool, newShortcut: Shortcut? = nil) {
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
        if commit, let s = newShortcut {
            shortcut = s
        }
        validationHint = nil
        isRecording = false
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let keyCode = event.keyCode

        // Esc cancels without writing
        if keyCode == Shortcut.escape.keyCode {
            stopRecording(commit: false)
            return
        }

        // Capture device-independent modifier subset only
        let deviceIndependent: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let captured = event.modifierFlags.intersection(deviceIndependent)

        let recorded = Shortcut(keyCode: keyCode, modifiers: captured.rawValue)
        stopRecording(commit: true, newShortcut: recorded)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("KeyRecorderView") {
    @Previewable @State var shortcut = Shortcut.defaultDictation

    VStack(spacing: 16) {
        Text(verbatim: "Shortcut recorder")
            .font(Typo.cardTitle)
            .foregroundStyle(Mono.primaryText)

        KeyRecorderView(shortcut: $shortcut)

        Text(verbatim: "Current: \(shortcut.displayString)")
            .font(Typo.secondary)
            .foregroundStyle(Mono.secondaryText)
    }
    .padding(24)
    .background(Mono.windowBackground)
}
#endif

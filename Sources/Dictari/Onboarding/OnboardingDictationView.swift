// OnboardingDictationView.swift
// Dictari — step four: the payoff. The user says something and watches their own words land.
//
// Everything before this was setup; this is the first time the app does its job. The pill the
// user has been looking at since the welcome screen is the same view instance, now driven by
// the real microphone, and the recognised text appears inside it rather than in some separate
// results panel — because that is exactly what will happen every day from here on.
//
// A click-to-record button sits alongside the shortcut on purpose: if Accessibility was
// skipped on step two, the global shortcut cannot fire, and a screen that only says "hold
// the shortcut alone would be a dead end.

import SwiftUI

struct OnboardingDictationView: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Owned by `OnboardingView` so the transcript can appear inside the shared pill.
    @Binding var transcript: String?
    var onFinish: () -> Void

    @State private var celebrating = false

    private var isListening: Bool { app.state == .listening }
    private var isTranscribing: Bool { app.state == .transcribing }
    private var errorMessage: String? {
        if case .error(let message) = app.state { return message }
        return nil
    }

    var body: some View {
        OnboardingScaffold(
            eyebrow: Strings.eyebrow,
            title: transcript == nil ? Strings.title : Strings.titleDone,
            subtitle: transcript == nil ? initialSubtitle : Strings.subtitleDone
        ) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                caption
                if transcript != nil {
                    Text("Optional: set per-app correction in Settings → Writing.")
                        .font(Typo.secondary).foregroundStyle(Mono.secondaryText)
                        .multilineTextAlignment(.center).padding(.top, 12)
                }
                // The caption belongs to the pill, so it sits just under it rather than being
                // pushed to the floor of the pane — a full-height Spacer left a dead band
                // between the two and the step read as half-finished.
                Spacer(minLength: 0)
                    .frame(maxHeight: 66)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } actions: {
            if transcript == nil {
                OnboardingButton(title: Strings.skip, kind: .quiet, action: onFinish)
                OnboardingButton(title: isListening ? Strings.stop : Strings.record,
                                 kind: .secondary) {
                    if isListening { app.stopDictation() } else { app.startDictation() }
                }
            } else {
                OnboardingButton(title: Strings.finish, action: onFinish)
            }
        }
        .onChange(of: app.lastTranscript) { _, new in reveal(new) }
        .onChange(of: app.state) { _, new in
            if case .success = new { reveal(app.lastTranscript) }
        }
    }

    // MARK: - Caption under the pill

    @ViewBuilder
    private var caption: some View {
        Group {
            if transcript != nil {
                // No tick here: the pill already shows one next to the words. Saying it twice
                // reads as the interface congratulating itself.
                Text(Strings.landed)
                    .font(Typo.body)
                    .foregroundStyle(Mono.secondaryText)
                    .scaleEffect(celebrating ? 1 : 0.94)
                    .opacity(celebrating ? 1 : 0)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(Typo.body)
                    .foregroundStyle(Mono.secondaryText)
            } else if isTranscribing {
                Text(Strings.writing)
                    .font(Typo.body)
                    .foregroundStyle(Mono.secondaryText)
            } else if isListening {
                Text(Strings.listening)
                    .font(Typo.body)
                    .foregroundStyle(Mono.primaryText)
            } else {
                HStack(spacing: 8) {
                    Text(app.settings.data.interactionMode == .toggle ? "Press" : "Hold")
                        .font(Typo.body)
                        .foregroundStyle(Mono.secondaryText)
                    ShortcutChip(app.settings.data.dictationShortcut)
                    Text(app.settings.data.interactionMode == .toggle ? "to start" : "and speak")
                        .font(Typo.body)
                        .foregroundStyle(Mono.secondaryText)
                }
            }
        }
        .frame(height: 26)
        .animation(Motion.reduced(Motion.appear, reduceMotion: reduceMotion), value: app.state)
        .animation(Motion.reduced(Motion.appear, reduceMotion: reduceMotion), value: celebrating)
        .staged(4)
    }

    // MARK: - Result

    private func reveal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, transcript == nil else { return }
        withAnimation(Motion.reduced(Motion.morph, reduceMotion: reduceMotion)) {
            transcript = trimmed
        }
        // A beat after the pill has finished growing, so the two do not compete.
        withAnimation(Motion.reduced(Motion.appear, reduceMotion: reduceMotion).delay(0.18)) {
            celebrating = true
        }
    }

    // MARK: - Strings

    private var initialSubtitle: String {
        // Whole sentences rather than concatenated halves, so translations can reorder them.
        let toggle = app.settings.data.interactionMode == .toggle
        return toggle
            ? String(localized: "Press the shortcut once to start and again to stop. Whatever you say will appear below — and, from now on, wherever your cursor is.",
                     comment: "Onboarding, first dictation step")
            : String(localized: "Hold the shortcut, speak a sentence, then let go. Whatever you say will appear below — and, from now on, wherever your cursor is.",
                     comment: "Onboarding, first dictation step")
    }

    private enum Strings {
        static let eyebrow = String(localized: "First dictation", comment: "Onboarding, first dictation step")
        static let title = String(localized: "Say something", comment: "Onboarding, first dictation step")
        static let titleDone = String(localized: "You're ready", comment: "Onboarding, first dictation step")
        static let subtitleDone = String(localized: "Your words go to the selected text field, or to the clipboard when there is none. Dictari stays in the menu bar.", comment: "Onboarding, first dictation step")
        static let listening = String(localized: "Listening…", comment: "Onboarding, first dictation step")
        static let writing = String(localized: "Writing it down…", comment: "Onboarding, first dictation step")
        static let landed = String(localized: "Heard you.", comment: "Onboarding, first dictation step")
        static let record = String(localized: "Record", comment: "Onboarding, first dictation step")
        static let stop = String(localized: "Stop", comment: "Onboarding, first dictation step")
        static let skip = String(localized: "Skip for now", comment: "Onboarding, first dictation step")
        static let finish = String(localized: "Start using Dictari", comment: "Onboarding, first dictation step")
    }
}

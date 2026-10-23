// OnboardingView.swift
// Dictari — the paged root of the first-run flow.
//
// The window is one object with one moving part. The four steps swap underneath, but the
// dark pill is a single view instance that travels between them: hero on the welcome step,
// a small mark at the top while the user grants permissions and picks a model, then back to
// full size for the first real dictation, where it fills with their own words.
//
// The travel is done with `matchedGeometryEffect` against invisible anchors. All four anchors
// are always in the tree, with exactly one marked `isSource` — the current step — so there is
// never an ambiguous source, which is the usual way this effect breaks when it is attached to
// views inside a `switch`.

import SwiftUI

struct OnboardingView: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Called when the user reaches the end (or skips out of) the flow.
    var onFinish: () -> Void

    @State private var step: OnboardingStepID = .welcome
    /// The recognised text from the first dictation, shown inside the pill.
    @State private var transcript: String?
    @State private var synthetic = SyntheticLevelSource()
    @Namespace private var pillSpace

    /// The pill reads real microphone levels only on the last step; everywhere else it runs
    /// on the synthetic envelope so it is alive before the mic has been granted.
    private var usesSyntheticLevels: Bool { step != .dictation }

    var body: some View {
        VStack(spacing: 0) {
            stage
            footer
        }
        .frame(width: OnboardingLayout.window.width, height: OnboardingLayout.window.height)
        .background(Mono.windowBackground)
        // One driver for the synthetic envelope; it stops the moment real levels take over.
        .task(id: usesSyntheticLevels) {
            guard usesSyntheticLevels else { return }
            await synthetic.run()
        }
    }

    // MARK: - Stage (steps + the travelling pill)

    private var stage: some View {
        ZStack(alignment: .topLeading) {
            // Anchors first: they define where the pill is for each step. Invisible, and only
            // the current step's anchor is the geometry source.
            ForEach(OnboardingStepID.allCases) { candidate in
                Color.clear
                    .frame(width: pillSize(for: candidate).width,
                           height: pillSize(for: candidate).height)
                    .matchedGeometryEffect(id: OnboardingLayout.pillID, in: pillSpace,
                                           isSource: candidate == step)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: pillAlignment(for: candidate))
                    .padding(.top, pillTopPadding(for: candidate))
                    .offset(y: pillOffset(for: candidate))
                    // Color.clear does hit-test in SwiftUI; these are pure geometry.
                    .allowsHitTesting(false)
            }

            stepContent
                .id(step)

            OnboardingPill(levels: usesSyntheticLevels ? synthetic.buffer : app.levels,
                           isActive: pillIsActive,
                           transcript: transcript)
                .matchedGeometryEffect(id: OnboardingLayout.pillID, in: pillSpace, isSource: false)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            OnboardingWelcomeView(onContinue: advance)
                .transition(stepTransition)
        case .permissions:
            OnboardingPermissionsView(onContinue: advance)
                .transition(stepTransition)
        case .model:
            OnboardingModelView(onContinue: advance)
                .transition(stepTransition)
        case .dictation:
            OnboardingDictationView(transcript: $transcript, onFinish: finish)
                .transition(stepTransition)
        }
    }

    /// Steps arrive from the right and leave to the left: the flow has a direction, and the
    /// motion should say so. Removal is shorter than insertion so the two never overlap into
    /// a muddle.
    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.1)) }
        return .asymmetric(
            insertion: .offset(x: 26).combined(with: .opacity).animation(Motion.morph),
            removal: .offset(x: -18).combined(with: .opacity).animation(.easeOut(duration: 0.16))
        )
    }

    // MARK: - Pill geometry per step

    /// Every step shows the same object: a slim capsule at roughly the real pill's 8:1
    /// proportion (`Metrics.pillRecordingSize`, 360×44). Only the scale changes. A wider,
    /// squatter lozenge would read as a placeholder rather than as the thing the user is
    /// about to live with.
    private func pillSize(for step: OnboardingStepID) -> CGSize {
        switch step {
        case .welcome:                 return OnboardingLayout.heroPill
        case .permissions, .model:     return OnboardingLayout.markPill
        // Grow it in width when the transcript lands, never in height — a capsule that gets
        // taller stops being the pill and becomes a black slab.
        case .dictation:   return transcript == nil
            ? CGSize(width: 320, height: 46)
            : CGSize(width: 430, height: 52)
        }
    }

    private func pillAlignment(for step: OnboardingStepID) -> Alignment {
        switch step {
        case .welcome, .dictation: return .center
        case .permissions, .model: return .top
        }
    }

    private func pillTopPadding(for step: OnboardingStepID) -> CGFloat {
        switch step {
        case .permissions, .model: return 30
        default: return 0
        }
    }

    /// Welcome lifts the pill above its title block; the dictation step sits it below centre.
    private func pillOffset(for step: OnboardingStepID) -> CGFloat {
        switch step {
        // Derived from the footprint the welcome step reserves above its title block, so the
        // reserved space and the travelling pill cannot drift apart when either changes.
        case .welcome:
            return OnboardingLayout.heroTop + pillSize(for: .welcome).height / 2
                - OnboardingLayout.stage.height / 2
        // Below centre on purpose: it pulls the pill and the caption under it down towards the
        // action row, which is what was leaving the bottom of this step empty.
        case .dictation: return 38
        default:         return 0
        }
    }

    private var pillIsActive: Bool {
        if usesSyntheticLevels { return true }
        return app.state == .listening
    }

    // MARK: - Footer

    /// Counter left, caption right, step indicator dead centre. The indicator is centred in a
    /// ZStack rather than between two Spacers so it sits on the window's axis regardless of
    /// how long the caption on either side happens to be.
    private var footer: some View {
        ZStack {
            OnboardingStepIndicator(current: step)

            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(step.number)
                        .foregroundStyle(Mono.primaryText)
                    Text(verbatim: "/")
                        .foregroundStyle(Mono.ink(0.20))
                    Text(String(format: "%02d", OnboardingStepID.allCases.count))
                        .foregroundStyle(Mono.tertiaryText)
                }
                .font(Typo.mono)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.reduced(Motion.snap, reduceMotion: reduceMotion), value: step)

                Spacer(minLength: 0)

                Text(stepCaption)
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.tertiaryText)
                    .id(step)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, OnboardingLayout.margin)
        .frame(height: OnboardingLayout.footerHeight)
    }

    /// A quiet word about where the user is. Every user-facing string in this file lives here
    /// or in `Strings` below, so extraction for localisation is mechanical.
    private var stepCaption: String {
        switch step {
        case .welcome:     return Strings.captionWelcome
        case .permissions: return Strings.captionPermissions
        case .model:       return Strings.captionModel
        case .dictation:   return Strings.captionDictation
        }
    }

    // MARK: - Navigation

    private func advance() {
        guard let next = step.next else { return finish() }
        withAnimation(Motion.reduced(Motion.morph, reduceMotion: reduceMotion)) {
            step = next
        }
    }

    private func finish() { onFinish() }

    private enum Strings {
        static let captionWelcome = String(localized: "Setup takes about a minute", comment: "Onboarding footer caption")
        static var captionPermissions: String {
            String(localized: "Two permissions, both local", comment: "Onboarding footer caption")
        }
        static let captionModel = String(localized: "Downloaded once, then dictation stays offline", comment: "Onboarding footer caption")
        static let captionDictation = String(localized: "Last step", comment: "Onboarding footer caption")
    }
}

#if DEBUG
#Preview {
    OnboardingView(onFinish: {})
        .environment(AppCoordinator())
}
#endif

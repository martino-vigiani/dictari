// OnboardingWelcomeView.swift
// Dictari — step one: the promise, and the pill already alive.
//
// Deliberately not a feature list. The only argument this screen makes is that the thing in
// the middle of it responds to a voice, which is the whole product. The levels driving it are
// synthetic (see `SyntheticLevelSource`) because the microphone has not been granted yet.

import SwiftUI

struct OnboardingWelcomeView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The pill itself is drawn by OnboardingView in the overlay; this reserves its
            // footprint so the copy below sits at the right optical distance from it.
            //
            // The block is anchored to the top rather than centred, and its inset comes from
            // the same constants the pill anchor is derived from: centring made the whole
            // composition float on the copy's measured height, which drifts with wrapping,
            // and left the bottom third of the window empty while the pill crept upward.
            Color.clear.frame(height: OnboardingLayout.heroTop
                + OnboardingLayout.heroPill.height
                + OnboardingLayout.heroTitleGap)

            Text(Strings.title)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Mono.primaryText)
                .staged(1)

            Text(Strings.subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Mono.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 420)
                .padding(.top, 10)
                .staged(2)

            OnboardingButton(title: Strings.action, action: onContinue)
                .padding(.top, 32)
                .staged(3)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, OnboardingLayout.margin)
    }

    private enum Strings {
        static let title = String(localized: "Speak. Dictari types.", comment: "Onboarding, welcome step")
        static let subtitle = String(localized: "Hold the shortcut, speak, and Dictari types in the selected text field.", comment: "Onboarding, welcome step")
        static let action = String(localized: "Get started", comment: "Onboarding, welcome step")
    }
}

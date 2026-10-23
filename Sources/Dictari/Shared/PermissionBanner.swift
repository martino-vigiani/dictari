// PermissionBanner.swift
// Dictari — the one piece of UI that appears only when the app cannot work.
//
// Kept deliberately plain: a rule, a line of text, one button that opens the exact System
// Settings pane. No colour, no icon soup — it has to read as a statement of fact, and it
// disappears the moment the permission is granted.
//
// It is the only block on Home with a stronger outline than a card: everything else on the
// page is optional, this is not. The opening button is the page's single primary action for
// the same reason.

import SwiftUI

struct PermissionBanner: View {
    let issues: [PermissionIssue]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(issues) { issue in
                    if issue != issues.first {
                        Rectangle()
                            .fill(Mono.cardBorder)
                            .frame(height: 0.5)
                            .padding(.vertical, 12)
                    }
                    row(issue)
                        // A granted permission leaves its row on a fade; the other row stays.
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
            .padding(Metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(Mono.fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Mono.ink(0.18), lineWidth: 1)
            )
            .monoAnimation(Motion.reveal, value: issues)
            .transition(.monoReveal(reduceMotion: reduceMotion))
        }
    }

    private func row(_ issue: PermissionIssue) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(Typo.cardTitle)
                    .foregroundStyle(Mono.primaryText)
                Text(issue.detail)
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Settings") { issue.openSystemSettings() }
                .buttonStyle(MonoActionButtonStyle(.primary, size: .small))
        }
        .accessibilityElement(children: .contain)
    }
}

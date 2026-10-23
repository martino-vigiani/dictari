// AppearancePicker.swift
// Dictari — Appearance chosen by looking at it: three miniature windows (System, Light, Dark)
// instead of a pop-up of words.
//
// The thumbnails draw from `AppearancePreview`, fixed light and dark palettes, rather than the
// adaptive `Mono` tokens: an adaptive colour resolves against the *current* appearance, so the
// "Light" thumbnail would turn dark the moment the user picked Dark — the one thing a preview of
// an appearance must never do.

import SwiftUI

struct AppearancePicker: View {
    @Binding var selection: AppearanceMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(AppearanceMode.allCases) { mode in
                AppearanceOption(mode: mode, isSelected: selection == mode) {
                    withAnimation(Motion.reduced(Motion.select, reduceMotion: reduceMotion)) {
                        selection = mode
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Appearance")
    }
}

// MARK: - Option

private struct AppearanceOption: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    /// Thumbnail radius; the selection ring sits 3 pt outside it, concentric.
    private static let radius = Metrics.controlRadius
    private static let ringInset: CGFloat = 3

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                AppearanceThumbnail(mode: mode)
                    .frame(width: 76, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .strokeBorder(Mono.cardBorder, lineWidth: 1)
                    )
                    .padding(Self.ringInset)
                    .overlay(
                        // Selection is a ring of ink, never an accent colour (monochrome rule).
                        RoundedRectangle(cornerRadius: Self.radius + Self.ringInset, style: .continuous)
                            .strokeBorder(
                                isSelected ? Mono.ink() : (isHovered ? Mono.ink(0.25) : .clear),
                                lineWidth: 2
                            )
                    )
                // A caption under each window: the thumbnails alone left "System" to be
                // guessed from a split picture.
                Text(mode.label)
                    .font(Typo.secondary.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected || isHovered ? Mono.primaryText : Mono.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MonoPlainButtonStyle(scales: true, pressedScale: 0.97))
        .onHover { isHovered = $0 }
        .monoAnimation(Motion.hover, value: isHovered)
        .help(mode.label)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Thumbnail

/// A miniature Dictari window: sidebar with the mark, a few lines of content and a text field.
/// System shows both halves, light on the left and dark on the right.
private struct AppearanceThumbnail: View {
    let mode: AppearanceMode

    var body: some View {
        switch mode {
        case .light:
            MiniWindow(palette: AppearancePreview.light)
        case .dark:
            MiniWindow(palette: AppearancePreview.dark)
        case .system:
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    MiniWindow(palette: AppearancePreview.light)
                    // The dark window slid halfway in over the light one; the option's own
                    // clip trims what overhangs, as in macOS's own appearance picker.
                    MiniWindow(palette: AppearancePreview.dark)
                        .offset(x: proxy.size.width / 2)
                }
            }
        }
    }
}

private struct MiniWindow: View {
    let palette: AppearancePreview.Palette

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar with the app mark.
            ZStack(alignment: .top) {
                palette.sidebar
                Circle()
                    .strokeBorder(palette.ink.opacity(0.45), lineWidth: 1)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                line(width: 20, opacity: 0.85).frame(maxWidth: .infinity, alignment: .trailing)
                line(width: 26, opacity: 0.18)
                line(width: 32, opacity: 0.18)
                line(width: 22, opacity: 0.18)
                Spacer(minLength: 0)
                line(width: 24, opacity: 0.85).frame(maxWidth: .infinity, alignment: .trailing)
                // The dictation field, with its send dot.
                Capsule()
                    .strokeBorder(palette.ink.opacity(0.22), lineWidth: 0.75)
                    .background(Capsule().fill(palette.card))
                    .frame(height: 7)
                    .overlay(alignment: .trailing) {
                        Circle().fill(palette.ink.opacity(0.85))
                            .frame(width: 3.5, height: 3.5)
                            .padding(.trailing, 2)
                    }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.window)
        }
    }

    private func line(width: CGFloat, opacity: Double) -> some View {
        Capsule()
            .fill(palette.ink.opacity(opacity))
            .frame(width: width, height: 2)
    }
}

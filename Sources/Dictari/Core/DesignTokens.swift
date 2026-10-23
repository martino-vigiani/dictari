// DesignTokens.swift
// Dictari — single source of truth for the strictly black & white visual system.
// Every view MUST use these tokens. No raw colors, no system tints, no accent color.

import AppKit
import SwiftUI

extension Color {
    /// A colour that resolves to `light` in light appearance and `dark` in dark appearance,
    /// honouring any `NSApp.appearance` override.
    static func adaptive(_ light: Color, _ dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

// MARK: - Monochrome palette (adaptive to light / dark)

/// Fixed light and dark surfaces for the appearance thumbnails in Settings. Deliberately NOT
/// adaptive: a preview of "Light" must stay light while the app itself is dark. Values mirror
/// the matching `Mono` surfaces so a thumbnail looks like the real window.
enum AppearancePreview {
    struct Palette {
        let window: Color
        let sidebar: Color
        let card: Color
        let ink: Color
    }

    static let light = Palette(window: Color(white: 0.96), sidebar: Color(white: 0.90),
                               card: .white, ink: .black)
    static let dark = Palette(window: Color(white: 0.12), sidebar: Color(white: 0.20),
                              card: Color(white: 0.18), ink: .white)
}

/// Strictly monochrome, but appearance-aware: ink/surfaces flip between light and dark.
/// The PILL is the one exception — it is always a dark capsule (like the Dynamic Island).
enum Mono {
    /// Primary content colour (black in light, white in dark) at a given opacity.
    static func ink(_ opacity: Double = 1) -> Color { Color.primary.opacity(opacity) }
    /// Inverse of ink (white in light, black in dark).
    static func paper(_ opacity: Double = 1) -> Color { Color.adaptive(.white, .black).opacity(opacity) }

    // The pill is ALWAYS dark, in both modes.
    static let pillFill = Color.black
    static func pillOn(_ opacity: Double = 1) -> Color { Color.white.opacity(opacity) }

    // Adaptive surfaces
    static let windowBackground = Color.adaptive(Color(white: 0.96), Color(white: 0.12))
    static let sidebarBackground = Color.adaptive(Color(white: 0.94), Color(white: 0.15))
    static let card = Color.adaptive(.white, Color(white: 0.18))
    static let cardBorder = Color.adaptive(.black.opacity(0.06), .white.opacity(0.10))
    static let cardShadow = Color.adaptive(.black.opacity(0.07), .black.opacity(0.40))
    static let fieldFill = Color.adaptive(.black.opacity(0.05), .white.opacity(0.09))
    static let hover = Color.adaptive(.black.opacity(0.08), .white.opacity(0.10))
    /// The brief wash over a settings row reached from search. A touch stronger than hover so
    /// it reads on a card, still ink-only.
    static let searchHighlight = Color.adaptive(.black.opacity(0.10), .white.opacity(0.14))
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.adaptive(.black.opacity(0.40), .white.opacity(0.40))
    static let selection = Color.primary                       // selected row fill (adapts)
    static let selectionText = Color.adaptive(.white, .black)  // text on selection (inverse)
}

// MARK: - Geometry

enum Metrics {
    // Pill
    static let pillIdleSize = CGSize(width: 120, height: 28)
    static let pillRecordingSize = CGSize(width: 360, height: 44)
    static let pillCornerRadius: CGFloat = 22
    static let pillBottomInset: CGFloat = 48

    // Waveform — compact, sized for the small dark pill (only the lines show while speaking).
    static let waveformBarCount = 22
    static let waveformBarWidth: CGFloat = 2.5
    static let waveformBarGap: CGFloat = 2
    static let waveformMaxHeight: CGFloat = 20
    static let waveformMinHeight: CGFloat = 2
    static let waveformBarRadius: CGFloat = 1.25

    // Settings
    static let settingsWindow = CGSize(width: 820, height: 540)
    /// Smallest size the settings layout still reads at.
    static let settingsWindowMinimum = CGSize(width: 620, height: 420)
    static let sidebarWidth: CGFloat = 200
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let rowHeight: CGFloat = 36

    // Settings rhythm — one scale for every page so phase-by-phase redesigns stay aligned.
    /// Horizontal gutter of a settings page.
    static let pageGutter: CGFloat = 28
    /// Vertical gap between the blocks of a page (title, cards, footnotes).
    static let sectionSpacing: CGFloat = 22
    /// Gap between a card's uppercase label and the card itself.
    static let cardLabelGap: CGFloat = 8
    /// Corner radius of buttons, fields and hover washes inside a card. Concentric with
    /// `cardRadius` at a few points of inset, so nested shapes don't look pinched.
    static let controlRadius: CGFloat = 7
    /// Button heights for `MonoActionButtonStyle`.
    static let controlHeight: CGFloat = 28
    static let controlHeightSmall: CGFloat = 22
    /// Inner padding of a sheet presented from a settings page.
    static let sheetPadding: CGFloat = 24
}

// MARK: - Motion

enum Motion {
    /// Short interaction curves shared by SwiftUI and native AppKit controls.
    static let pressDuration: Double = 0.12
    static let hoverDuration: Double = 0.14
    static let press = Animation.easeOut(duration: pressDuration)
    static let hover = Animation.easeInOut(duration: hoverDuration)
    static let snap = Animation.spring(response: 0.22, dampingFraction: 0.82)
    static let appear = Animation.spring(response: 0.32, dampingFraction: 0.76)
    static let morph = Animation.spring(response: 0.38, dampingFraction: 0.72)

    // Settings window. Rule of thumb: springs for anything the user drives (selection,
    // toggles, reveals) because they retarget cleanly when clicked again; short ease-outs
    // for things that leave. Nothing in Settings bounces: every damping here is >= 0.82.

    /// Sidebar selection pill sliding between rows, segmented thumb, tab-like switches.
    static let select = Animation.spring(response: 0.30, dampingFraction: 0.86)
    /// The selected row's label and icon switching colour while the `select` capsule slides
    /// under them. Short and eased so it crosses its midpoint about when the capsule does,
    /// and stops re-rendering text after a handful of frames instead of the spring's ~30.
    static let selectLabel = Animation.easeInOut(duration: 0.16)
    /// A new settings page arriving: fade + 6 pt rise, no overshoot.
    static let page = Animation.spring(response: 0.34, dampingFraction: 0.92)
    /// The old page leaving: quicker than `page` so two pages never read as overlapping.
    static let pageExit = Animation.easeOut(duration: 0.12)
    /// Disclosures, inline notices, rows inserted into a card.
    static let reveal = Animation.spring(response: 0.30, dampingFraction: 0.88)
    /// Label swaps ("Copy" → "Copied"), compact header fading in.
    static let swap = Animation.easeInOut(duration: 0.18)
    /// How long transient confirmation ("Copied", "Saved") stays before reverting.
    static let feedbackHold: Duration = .seconds(1.5)
    /// Vertical travel of `page` / `reveal` transitions, in points. Small on purpose: the
    /// eye should register "this arrived", not follow it.
    static let travel: CGFloat = 6

    /// Pill enter/exit durations (seconds).
    static let pillEnter: Double = 0.30
    static let pillExit: Double = 0.22
    /// The window must not be ordered out before the content has finished leaving. Derived
    /// from `pillExit` so the two can never drift apart.
    static var pillExitMilliseconds: Double { pillExit * 1000 + 40 }

    /// The pill's own dismissal: a short, firm ease-out. Springs overshoot, and an element
    /// that bounces on its way out reads as indecisive.
    static let pillDismiss = Animation.easeOut(duration: pillExit)

    /// Returns an animation that collapses to a quick cross-fade under Reduce Motion.
    static func reduced(_ base: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.1) : base
    }
}

// MARK: - Typography

enum Typo {
    static let screenTitle = Font.system(size: 26, weight: .semibold)              // page titles
    static let pageSubtitle = Font.system(size: 13, weight: .regular)              // one line under a page title
    static let sheetTitle = Font.system(size: 20, weight: .semibold)               // sheet / modal titles
    static let button = Font.system(size: 13, weight: .medium)                     // regular action buttons
    static let buttonSmall = Font.system(size: 11, weight: .medium)                // small / in-row buttons
    static let sectionLabel = Font.system(size: 11, weight: .semibold)             // shown UPPERCASE + tracked
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let secondary = Font.system(size: 11, weight: .regular)
    static let tileLabel = Font.system(size: 10, weight: .semibold)                // tile caption, uppercased
    static let metricValue = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let pillControl = Font.system(size: 11, weight: .medium)
    static let micLabel = Font.system(size: 10, weight: .medium, design: .rounded)
    static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
    // Signature: an elegant serif for the single big "Time Saved" figure.
    static let heroMetric = Font.system(size: 46, weight: .semibold, design: .serif)
}

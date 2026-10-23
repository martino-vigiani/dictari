// SettingsCard.swift
// Dictari — reusable card container for settings panels.
// Named with "Settings" prefix to avoid collision with any future shared MonoControls.

import SwiftUI

// MARK: - Localization contract
//
// Every component here takes its words the way `Text` does:
// - a string literal is a `LocalizedStringKey`, so Xcode extracts it into
//   `Localizable.xcstrings` and it is shown translated;
// - a `String` value is shown exactly as it is (`Text(verbatim:)`). Use that for user data
//   (a profile name, an error from the system) or for text already localized at its source
//   with `String(localized:)`. A runtime `String` is never looked up in the catalog, so a
//   profile called "Default" cannot be "translated" by accident.
// Components with two texts accept a literal or a `String` in each slot independently. When
// both are `String`s the call must say so with `verbatim:`. The `String` overloads are
// `@_disfavoredOverload`, so a literal always picks the localized one — the same rule
// SwiftUI's own `Text` uses.

// MARK: - Card container

/// Wraps a group of settings rows in a rounded card with B/W styling.
///
/// `title` is the small uppercase label above the card; `footer` is an optional line of
/// explanation under it (use it instead of a loose `Text` after the card, so the spacing is
/// always the same).
struct SettingsCard<Content: View>: View {
    private let title: Text?
    private let footer: Text?
    @ViewBuilder let content: () -> Content

    init(title: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(titleText: title.map { Text($0) }, footerText: footer.map { Text($0) }, content: content)
    }

    /// A title computed at runtime, shown as is.
    @_disfavoredOverload
    init(title: String?, footer: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(titleText: title.map { Text(verbatim: $0) }, footerText: footer.map { Text($0) }, content: content)
    }

    /// A footer computed at runtime, shown as is.
    @_disfavoredOverload
    init(title: LocalizedStringKey? = nil, footer: String?, @ViewBuilder content: @escaping () -> Content) {
        self.init(titleText: title.map { Text($0) }, footerText: footer.map { Text(verbatim: $0) }, content: content)
    }

    /// Title and footer both computed at runtime, shown as is.
    init(verbatimTitle title: String?, footer: String?, @ViewBuilder content: @escaping () -> Content) {
        self.init(titleText: title.map { Text(verbatim: $0) }, footerText: footer.map { Text(verbatim: $0) },
                  content: content)
    }

    private init(titleText: Text?, footerText: Text?, @ViewBuilder content: @escaping () -> Content) {
        self.title = titleText
        self.footer = footerText
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                SettingsSectionLabel(title)
                    .padding(.leading, 4)
                    .padding(.bottom, Metrics.cardLabelGap)
            }
            VStack(spacing: 0) {
                content()
            }
            // Keep child content inside the same rounded surface; otherwise a full-width
            // row/control can square off a card corner even though its background is rounded.
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            // The shadow belongs to the surface shape, not to the card's content. A `.shadow`
            // on the whole card shadows every glyph and control inside it, which renders the
            // card off-screen on every frame it moves (scrolling, the page transition). On a
            // plain filled shape it is one cheap blurred path, and looks the same because the
            // fill is opaque and covers the content's footprint.
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(Mono.card)
                    .shadow(color: Mono.cardShadow, radius: 4, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Mono.cardBorder, lineWidth: 0.5)
            )

            if let footer {
                SettingsFootnote(footer)
                    .padding(.top, Metrics.cardLabelGap)
            }
        }
    }
}

/// The small uppercase, tracked label used above cards and sidebar groups. Exposed so a
/// page that groups something other than a `SettingsCard` (a chart, a grid of tiles) uses
/// the identical label.
struct SettingsSectionLabel: View {
    private let text: Text
    init(_ key: LocalizedStringKey) { text = Text(key) }
    /// Runtime text (user data, or already localized), shown as is.
    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S) { self.text = Text(verbatim: String(text)) }
    init(_ text: Text) { self.text = text }

    var body: some View {
        // `textCase` rather than `uppercased()` on the string: the key stays the sentence-case
        // wording translators see, and the uppercasing follows the display language's rules.
        text
            .textCase(.uppercase)
            .font(Typo.sectionLabel)
            .tracking(0.8)
            .foregroundStyle(Mono.tertiaryText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Secondary explanation that belongs to the block above it: under a card, under a row
/// group, below a control. Wraps, never truncates.
struct SettingsFootnote: View {
    private let text: Text
    init(_ key: LocalizedStringKey) { text = Text(key) }
    /// Runtime text (user data, or already localized), shown as is.
    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S) { self.text = Text(verbatim: String(text)) }
    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(Typo.secondary)
            .foregroundStyle(Mono.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

// MARK: - Card row

/// A single labeled row inside a SettingsCard.
struct SettingsRow<Control: View>: View {
    private let label: Text
    private let sublabel: Text?
    @ViewBuilder let control: () -> Control

    init(
        _ label: LocalizedStringKey,
        sublabel: LocalizedStringKey? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.init(labelText: Text(label), sublabelText: sublabel.map { Text($0) }, control: control)
    }

    /// A sublabel computed at runtime (a selected option's description), shown as is.
    @_disfavoredOverload
    init(_ label: LocalizedStringKey, sublabel: String?, @ViewBuilder control: @escaping () -> Control) {
        self.init(labelText: Text(label), sublabelText: sublabel.map { Text(verbatim: $0) }, control: control)
    }

    /// A label computed at runtime, shown as is.
    @_disfavoredOverload
    init(_ label: String, sublabel: LocalizedStringKey? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.init(labelText: Text(verbatim: label), sublabelText: sublabel.map { Text($0) }, control: control)
    }

    /// Label and sublabel both computed at runtime, shown as is.
    init(verbatim label: String, sublabel: String?, @ViewBuilder control: @escaping () -> Control) {
        self.init(labelText: Text(verbatim: label), sublabelText: sublabel.map { Text(verbatim: $0) },
                  control: control)
    }

    private init(labelText: Text, sublabelText: Text?, @ViewBuilder control: @escaping () -> Control) {
        self.label = labelText
        self.sublabel = sublabelText
        self.control = control
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                label
                    .font(Typo.body)
                    .foregroundStyle(Mono.primaryText)
                if let sublabel {
                    sublabel
                        .font(Typo.secondary)
                        .foregroundStyle(Mono.secondaryText)
                        // A long explanation wraps under the label instead of truncating.
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control()
        }
        .padding(Metrics.cardPadding)
    }
}

// MARK: - Card divider

struct SettingsCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Mono.cardBorder)
            .frame(height: 0.5)
            .padding(.leading, Metrics.cardPadding)
    }
}

// MARK: - Advanced disclosure

/// Tucks rarely needed controls behind a quiet "Advanced" line so a page opens on the few
/// choices most people make. Search still reaches the hidden rows: the page expands the
/// disclosure from `onSettingsSearchReveal` before scrolling to them.
struct SettingsAdvancedDisclosure<Content: View>: View {
    var title: LocalizedStringKey = "Advanced"
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            Button {
                withAnimation(Motion.reduced(Motion.reveal, reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .font(Typo.body)
                    // A hairline that runs to the edge makes the line read as a divider you can
                    // open, not a stray label.
                    Rectangle()
                        .fill(Mono.cardBorder)
                        .frame(height: 0.5)
                        .padding(.leading, 6)
                }
                .foregroundStyle(hovered || isExpanded ? Mono.primaryText : Mono.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(MonoPlainButtonStyle(scales: false))
            .onHover { hovered = $0 }
            .monoAnimation(Motion.hover, value: hovered)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded
                ? Text("Expanded", comment: "Accessibility value of a disclosure that is open")
                : Text("Collapsed", comment: "Accessibility value of a disclosure that is closed"))

            if isExpanded {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    content()
                }
                .transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
    }
}

// MARK: - Inline notice

/// A quiet, inline message with an icon: a warning that a shortcut clashes, a load error,
/// "not listening yet". Field-grey surface, never a colour. Insert/remove it with
/// `.transition(.monoReveal(reduceMotion:))` inside an animated change.
struct SettingsNotice: View {
    private let text: Text
    var systemImage: String = "info.circle"

    init(_ key: LocalizedStringKey, systemImage: String = "info.circle") {
        self.text = Text(key)
        self.systemImage = systemImage
    }

    /// Runtime text (an error from the system, a message built elsewhere), shown as is.
    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S, systemImage: String = "info.circle") {
        self.text = Text(verbatim: String(text))
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Mono.secondaryText)
                .accessibilityHidden(true)
            text
                .font(Typo.secondary)
                .foregroundStyle(Mono.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Metrics.controlRadius + 1, style: .continuous)
                .fill(Mono.fieldFill)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty state

/// What a card shows when it has nothing to list yet. Centered glyph, one-line title, one
/// line of guidance, and optionally the one action that fills it.
///
/// ```swift
/// SettingsCard(title: "Your profiles") {
///     SettingsEmptyState(systemImage: "slider.horizontal.3", title: "No profiles yet",
///                        message: "Create one to switch language and style per app.") {
///         Button("New Profile") { … }.buttonStyle(MonoActionButtonStyle(.primary))
///     }
/// }
/// ```
struct SettingsEmptyState<Action: View>: View {
    let systemImage: String
    private let title: Text
    private let message: Text?
    @ViewBuilder let action: () -> Action

    init(systemImage: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil,
         @ViewBuilder action: @escaping () -> Action) {
        self.init(systemImage: systemImage, titleText: Text(title), messageText: message.map { Text($0) },
                  action: action)
    }

    /// A message computed at runtime, shown as is.
    @_disfavoredOverload
    init(systemImage: String, title: LocalizedStringKey, message: String?,
         @ViewBuilder action: @escaping () -> Action) {
        self.init(systemImage: systemImage, titleText: Text(title), messageText: message.map { Text(verbatim: $0) },
                  action: action)
    }

    /// A title computed at runtime, shown as is.
    @_disfavoredOverload
    init(systemImage: String, title: String, message: LocalizedStringKey? = nil,
         @ViewBuilder action: @escaping () -> Action) {
        self.init(systemImage: systemImage, titleText: Text(verbatim: title), messageText: message.map { Text($0) },
                  action: action)
    }

    fileprivate init(systemImage: String, titleText: Text, messageText: Text?,
                     @ViewBuilder action: @escaping () -> Action) {
        self.systemImage = systemImage
        self.title = titleText
        self.message = messageText
        self.action = action
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Mono.tertiaryText)
                .padding(.bottom, 2)
                .accessibilityHidden(true)
            title
                .font(Typo.cardTitle)
                .foregroundStyle(Mono.primaryText)
            if let message {
                message
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
            }
            action()
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, Metrics.cardPadding)
        .accessibilityElement(children: .contain)
    }
}

extension SettingsEmptyState where Action == EmptyView {
    init(systemImage: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil) {
        self.init(systemImage: systemImage, titleText: Text(title), messageText: message.map { Text($0) }) {
            EmptyView()
        }
    }

    @_disfavoredOverload
    init(systemImage: String, title: LocalizedStringKey, message: String?) {
        self.init(systemImage: systemImage, titleText: Text(title), messageText: message.map { Text(verbatim: $0) }) {
            EmptyView()
        }
    }

    @_disfavoredOverload
    init(systemImage: String, title: String, message: LocalizedStringKey? = nil) {
        self.init(systemImage: systemImage, titleText: Text(verbatim: title), messageText: message.map { Text($0) }) {
            EmptyView()
        }
    }
}

// MARK: - Sheet chrome

/// Standard frame for a sheet opened from a settings page: title (+ optional subtitle) on
/// the left, actions on the right, content below, window-grey surface. Put the dismissing
/// button last in `actions` and give it `.keyboardShortcut(.cancelAction)` or
/// `.defaultAction`.
///
/// ```swift
/// SettingsSheet("Transcript", subtitle: document.title, width: 540, height: 440) {
///     ScrollView { … }
/// } actions: {
///     MonoCopyButton { … }
///     Button("Done") { dismiss() }
///         .keyboardShortcut(.cancelAction)
///         .buttonStyle(MonoActionButtonStyle(.primary))
/// }
/// ```
struct SettingsSheet<Content: View, Actions: View>: View {
    private let title: Text
    private let subtitle: Text?
    var width: CGFloat? = 540
    var height: CGFloat? = nil
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, width: CGFloat? = 540,
         height: CGFloat? = nil,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(titleText: Text(title), subtitleText: subtitle.map { Text($0) }, width: width, height: height,
                  content: content, actions: actions)
    }

    /// A subtitle computed at runtime (a document's name), shown as is.
    @_disfavoredOverload
    init(_ title: LocalizedStringKey, subtitle: String?, width: CGFloat? = 540, height: CGFloat? = nil,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(titleText: Text(title), subtitleText: subtitle.map { Text(verbatim: $0) }, width: width,
                  height: height, content: content, actions: actions)
    }

    /// A title computed at runtime, shown as is.
    @_disfavoredOverload
    init(_ title: String, subtitle: LocalizedStringKey? = nil, width: CGFloat? = 540, height: CGFloat? = nil,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(titleText: Text(verbatim: title), subtitleText: subtitle.map { Text($0) }, width: width,
                  height: height, content: content, actions: actions)
    }

    fileprivate init(titleText: Text, subtitleText: Text?, width: CGFloat?, height: CGFloat?,
                     @ViewBuilder content: @escaping () -> Content,
                     @ViewBuilder actions: @escaping () -> Actions) {
        self.title = titleText
        self.subtitle = subtitleText
        self.width = width
        self.height = height
        self.content = content
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    title
                        .font(Typo.sheetTitle)
                        .foregroundStyle(Mono.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        subtitle
                            .font(Typo.secondary)
                            .foregroundStyle(Mono.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) { actions() }
            }
            content()
        }
        .padding(Metrics.sheetPadding)
        .frame(width: width, height: height, alignment: .topLeading)
        .foregroundStyle(Mono.primaryText)
        .background(Mono.windowBackground)
    }
}

extension SettingsSheet where Actions == EmptyView {
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, width: CGFloat? = 540,
         height: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(titleText: Text(title), subtitleText: subtitle.map { Text($0) }, width: width, height: height,
                  content: content, actions: { EmptyView() })
    }

    @_disfavoredOverload
    init(_ title: LocalizedStringKey, subtitle: String?, width: CGFloat? = 540, height: CGFloat? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(titleText: Text(title), subtitleText: subtitle.map { Text(verbatim: $0) }, width: width,
                  height: height, content: content, actions: { EmptyView() })
    }

    @_disfavoredOverload
    init(_ title: String, subtitle: LocalizedStringKey? = nil, width: CGFloat? = 540, height: CGFloat? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(titleText: Text(verbatim: title), subtitleText: subtitle.map { Text($0) }, width: width,
                  height: height, content: content, actions: { EmptyView() })
    }
}

// MARK: - Scroll wrapper for detail panes

/// Standard scrollable container used by every settings detail view.
///
/// Draws the page title (and optional one-line `subtitle`), lays blocks out on the shared
/// rhythm (`Metrics.pageGutter`, `Metrics.sectionSpacing`), and once the big title has
/// scrolled away fades in a compact title bar with a hairline, so the page always says
/// where you are.
struct SettingsScrollPane<Content: View>: View {
    private let title: Text?
    private let subtitle: Text?
    @ViewBuilder let content: () -> Content
    /// Held in a reference the pane never reads, so crossing the threshold re-renders only
    /// the compact bar. As plain `@State` here, each crossing re-ran this body and with it
    /// `content()`: the whole page rebuilt twice per scroll, mid-scroll.
    @State private var compactTitle = SettingsCompactTitleState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: LocalizedStringKey? = nil, subtitle: LocalizedStringKey? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(titleText: title.map { Text($0) }, subtitleText: subtitle.map { Text($0) }, content: content)
    }

    /// A title computed at runtime — typically `SettingsSection.x.label`, already localized.
    @_disfavoredOverload
    init(title: String?, subtitle: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(titleText: title.map { Text(verbatim: $0) }, subtitleText: subtitle.map { Text($0) },
                  content: content)
    }

    /// A subtitle computed at runtime, shown as is.
    @_disfavoredOverload
    init(title: LocalizedStringKey? = nil, subtitle: String?, @ViewBuilder content: @escaping () -> Content) {
        self.init(titleText: title.map { Text($0) }, subtitleText: subtitle.map { Text(verbatim: $0) },
                  content: content)
    }

    /// Title and subtitle both computed at runtime, shown as is.
    init(verbatimTitle title: String?, subtitle: String?, @ViewBuilder content: @escaping () -> Content) {
        self.init(titleText: title.map { Text(verbatim: $0) }, subtitleText: subtitle.map { Text(verbatim: $0) },
                  content: content)
    }

    private init(titleText: Text?, subtitleText: Text?, @ViewBuilder content: @escaping () -> Content) {
        self.title = titleText
        self.subtitle = subtitleText
        self.content = content
    }

    /// Scroll distance at which the big title has mostly left the viewport.
    private static var compactThreshold: CGFloat { 44 }

    var body: some View {
        // The reader lets a settings search result scroll straight to its row: rows carry
        // `.settingsSearchAnchor(id)`, and every page is built on this pane.
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    if let title {
                        VStack(alignment: .leading, spacing: 4) {
                            title
                                .font(Typo.screenTitle)
                                .foregroundStyle(Mono.primaryText)
                                .accessibilityAddTraits(.isHeader)
                            if let subtitle {
                                subtitle
                                    .font(Typo.pageSubtitle)
                                    .foregroundStyle(Mono.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 4)
                    }
                    content()
                }
                .padding(.horizontal, Metrics.pageGutter)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .modifier(SettingsSearchScrollTarget(proxy: proxy))
            // Only a Bool crosses the closure, so the action runs twice per page scroll
            // (in and out), not on every frame.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > Self.compactThreshold
            } action: { _, isPast in
                guard title != nil, compactTitle.isShown != isPast else { return }
                withAnimation(Motion.reduced(Motion.swap, reduceMotion: reduceMotion)) {
                    compactTitle.isShown = isPast
                }
            }
        }
        .overlay(alignment: .top) {
            if let title {
                SettingsCompactTitleOverlay(title: title, state: compactTitle)
            }
        }
        .background(Mono.windowBackground)
    }
}

/// Whether the compact title bar is showing. A reference type so the pane can write it
/// without observing it; only `SettingsCompactTitleOverlay` reads it.
@MainActor @Observable
private final class SettingsCompactTitleState {
    var isShown = false
}

/// The only view that observes `SettingsCompactTitleState`.
private struct SettingsCompactTitleOverlay: View {
    let title: Text
    let state: SettingsCompactTitleState

    var body: some View {
        if state.isShown {
            SettingsCompactTitleBar(title: title)
                .transition(.opacity)
        }
    }
}

/// The slim title that replaces the big one once it scrolls away. Decorative for
/// VoiceOver: the real heading is still in the page.
private struct SettingsCompactTitleBar: View {
    let title: Text

    var body: some View {
        title
            .font(Typo.cardTitle)
            .foregroundStyle(Mono.primaryText)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(Mono.windowBackground.opacity(0.94))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Mono.cardBorder).frame(height: 0.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

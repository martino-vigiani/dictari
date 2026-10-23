// SettingsRootView.swift
// Dictari — top-level NavigationSplitView for the settings window.

import SwiftUI

// MARK: - Root view

struct SettingsRootView: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: SettingsSection
    /// Carries a search result's row from the sidebar to whichever page shows it.
    @State private var searchNavigator = SettingsSearchNavigator()

    init(initialSection: SettingsSection = .home) {
        _selection = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $selection) { entry in
                selection = entry.section
                searchNavigator.reveal(entry.anchor)
            }
                .navigationSplitViewColumnWidth(Metrics.sidebarWidth)
        } detail: {
            VStack(spacing: 0) {
                ForEach([app.settings.loadWarning, app.history.loadWarning, app.vocabulary.loadWarning].compactMap { $0 }, id: \.self) { warning in
                    SettingsNotice(warning, systemImage: "exclamationmark.triangle")
                        .padding(.horizontal, Metrics.pageGutter)
                        .padding(.top, 12)
                }
                // Each page is its own identity, so switching sections is a transition: the
                // new page rises in on `Motion.page` while the old one fades out on the
                // quicker `Motion.pageExit`. The ZStack keeps both in the same slot for the
                // few frames they overlap.
                ZStack(alignment: .topLeading) {
                    detailView(for: selection)
                        .id(selection)
                        .transition(.monoPage(reduceMotion: reduceMotion))
                }
                // `minHeight: 0` makes the column's height the window's, never the page's. The
                // split view turns the detail's minimum height into a constraint, and SwiftUI
                // measures it at a near-zero width: History has no outer ScrollView, so its
                // wrapping texts claimed ~1,450 pt, the window grew to the screen and the
                // overflow pushed the sidebar's search and first rows under the traffic lights.
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .animation(Motion.reduced(Motion.page, reduceMotion: reduceMotion), value: selection)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Mono.windowBackground)
        }
        .background(Mono.windowBackground)
        .environment(searchNavigator)
        // Lets a page link to another one (Home's "Your setup" rows) without owning the
        // selection, which stays here with the sidebar.
        .environment(\.openSettingsSection, OpenSettingsSectionAction { section, anchor in
            selection = section
            searchNavigator.reveal(anchor)
        })
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: SettingsPerfProbe.selectNotification)) { note in
            if let raw = note.object as? String, let section = SettingsSection(rawValue: raw) { selection = section }
        }
        #endif
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .home:        DashboardView()
        case .dictation:   DictationSettingsView()
        case .sound:       SoundSettingsView()
        case .profiles:    ProfilesSettingsView()
        case .vocabulary:  VocabularySettingsView(store: app.vocabulary, history: app.history.entries)
        case .writing:     WritingView()
        case .history:     HistorySettingsView()
        case .library:     MediaLibraryView()
        case .appearance:  AppearanceSettingsView()
        case .models:      ModelsSettingsView()
        case .agents:      AIAgentsSettingsView()
        case .team:        TeamSettingsView()
        case .diagnostics: DiagnosticsSettingsView()
        case .updates:     UpdatesSettingsView()
        }
    }
}

// MARK: - Cross-page navigation

/// Opens another settings page, optionally scrolling to one of its search anchors.
struct OpenSettingsSectionAction {
    let action: @MainActor (SettingsSection, String?) -> Void

    @MainActor
    func callAsFunction(_ section: SettingsSection, anchor: String? = nil) {
        action(section, anchor)
    }
}

extension EnvironmentValues {
    @Entry var openSettingsSection = OpenSettingsSectionAction { _, _ in }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    let onChooseResult: (SettingsSearchEntry) -> Void

    @State private var query = ""
    @State private var highlightedIndex = 0
    @State private var searchFocusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // Computed per render: the index is prebuilt and a search costs microseconds, so there
        // is no debounce and no cached copy that could drift from the text field.
        let results = isSearching ? SettingsSearchIndex.shared.search(query) : []
        VStack(spacing: 0) {
            SettingsSearchField(
                query: $query,
                focusRequest: searchFocusRequest,
                onMove: { step in
                    guard !results.isEmpty else { return }
                    highlightedIndex = min(max(highlightedIndex + step, 0), results.count - 1)
                },
                onSubmit: { choose(highlightedIndex, in: results) }
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if isSearching {
                SettingsSearchResultsList(
                    query: query,
                    results: results,
                    highlightedIndex: highlightedIndex,
                    onChoose: { choose($0, in: results) }
                )
                .transition(.opacity)
            } else {
                sections
                    .transition(.opacity)
            }
        }
        // Results and the section list cross-fade rather than snap when typing starts/ends.
        .animation(Motion.reduced(Motion.swap, reduceMotion: reduceMotion), value: isSearching)
        .background(Mono.sidebarBackground)
        // ⌘F from anywhere in the window. A zero-size button is the SwiftUI way to own a key
        // equivalent without a visible control; the hand-built main menu has no Find item.
        .background {
            Button("Search Settings") { searchFocusRequest &+= 1 }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onChange(of: query) { highlightedIndex = 0 }
    }

    private var sections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(SettingsSection.groups, id: \.sections) { group in
                    SidebarGroup(title: group.title, sections: group.sections, selection: $selection)
                }
            }
            // One capsule for the whole sidebar, drawn behind the rows at the selected row's
            // frame, with its own spring. It is separate from the rows so the labels can
            // change colour on a much shorter animation (see `SidebarRow`): when the whole
            // sidebar animated on the capsule's spring, re-rendering the labels was most of
            // the frames a page switch dropped (DEBUG SettingsPerfProbe, ~330 → ~100 hitches
            // over 42 switches). Moving the capsule itself costs next to nothing.
            .backgroundPreferenceValue(SidebarRowFrameKey.self) { anchors in
                GeometryReader { proxy in
                    if !reduceMotion, let anchor = anchors[selection] {
                        let rect = proxy[anchor]
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Mono.selection)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            // Animates on the value, not inside the button action, so a page
                            // opened from search or from a Home link slides the capsule
                            // exactly like a click does.
                            .animation(Motion.select, value: selection)
                    }
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    /// Results stay listed after a choice, like System Settings, so a user unsure which row
    /// they meant can step through the neighbours with the arrow keys and Return.
    private func choose(_ index: Int, in results: [SettingsSearchResult]) {
        guard results.indices.contains(index) else { return }
        highlightedIndex = index
        onChooseResult(results[index].entry)
    }
}

private struct SidebarGroup: View {
    let title: String
    let sections: [SettingsSection]
    @Binding var selection: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsSectionLabel(title)
                .padding(.horizontal, 20)
                .padding(.bottom, 2)

            ForEach(sections) { section in
                let isSelected = selection == section
                Button { selection = section } label: {
                    SidebarRow(section: section, isSelected: isSelected)
                }
                .buttonStyle(MonoPlainButtonStyle(scales: true, pressedScale: 0.985))
                .accessibilityLabel(section.label)
                .accessibilityValue(isSelected ? "Selected" : "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

// MARK: - Sidebar row

/// One sidebar entry. The ink selection capsule is a single shape that slides from row to
/// row (drawn once behind the rows, see `SidebarRowFrameKey`) on `Motion.select`; under Reduce Motion each
/// row draws its own capsule and the change is a short cross-fade. The selected icon takes
/// its filled variant, which reads as "here" without any colour.
private struct SidebarRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let section: SettingsSection
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: section.systemImage)
                .symbolRenderingMode(.monochrome)
                .symbolVariant(isSelected ? .fill : .none)
                .foregroundStyle(isSelected ? Mono.selectionText : Mono.primaryText)
                .frame(width: 16)

            // One line always: the row has a fixed height, and a wrapped label overflowed it.
            Text(section.label)
                .font(Typo.body)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(isSelected ? Mono.selectionText : Mono.primaryText)

            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.rowHeight)
        .background {
            // The sliding capsule lives in the sidebar's background (`SidebarRowFrameKey`);
            // under Reduce Motion each row draws its own and the change is a cross-fade.
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            if isSelected {
                if reduceMotion { shape.fill(Mono.selection) }
            } else if isHovered {
                shape.fill(Mono.hover)
            }
        }
        .anchorPreference(key: SidebarRowFrameKey.self, value: .bounds) { [section: $0] }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(Motion.reduced(Motion.hover, reduceMotion: reduceMotion), value: isHovered)
        // The label's colour and icon change on the short `Motion.selectLabel`, not on the
        // capsule's spring: animating text re-renders the whole sidebar layer on every frame,
        // and over a 0.3 s spring that was most of the frames a page switch dropped.
        .animation(reduceMotion ? Motion.reduced(Motion.select, reduceMotion: true) : Motion.selectLabel,
                   value: isSelected)
    }
}

/// Each sidebar row's frame, so the selection capsule can be drawn once behind all rows.
private struct SidebarRowFrameKey: PreferenceKey {
    static let defaultValue: [SettingsSection: Anchor<CGRect>] = [:]
    static func reduce(value: inout [SettingsSection: Anchor<CGRect>],
                       nextValue: () -> [SettingsSection: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

#Preview {
    SettingsRootView()
        .environment(AppCoordinator())
        .frame(width: Metrics.settingsWindow.width, height: Metrics.settingsWindow.height)
}



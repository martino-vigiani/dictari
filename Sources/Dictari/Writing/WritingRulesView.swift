import AppKit
import SwiftUI

struct WritingRulesView: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var error: String?
    var body: some View {
        let ids = (app.settings.data.applicationWritingRules ?? [:]).keys.sorted()
        SettingsCard(title: "App rules",
                     footer: ids.isEmpty ? nil : "Profiles can override app rules. Fix Mistakes always works.") {
            SettingsRow("With your usual dictation shortcut",
                        sublabel: "Fix text automatically, or offer a revision, in the apps you choose.") {
                Button("Add App…", action: addApplication)
                    .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                    .accessibilityLabel("Add application").help("Add application")
            }
            if let error {
                SettingsNotice(error, systemImage: "exclamationmark.triangle")
                    .padding([.horizontal, .bottom], Metrics.cardPadding)
                    .transition(.monoReveal(reduceMotion: reduceMotion))
            }
            if ids.isEmpty {
                SettingsCardDivider()
                SettingsEmptyState(systemImage: "square.grid.2x2",
                                   title: "No app rules yet",
                                   message: "Each app can keep your words, offer a revision after pasting, or fix them automatically.")
                    .transition(.monoReveal(reduceMotion: reduceMotion))
            }
            ForEach(ids, id: \.self) { id in
                VStack(spacing: 0) {
                    SettingsCardDivider()
                    WritingApplicationRow(bundleID: id)
                }
                .transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
        .monoAnimation(Motion.reveal, value: ids)
        .monoAnimation(Motion.reveal, value: error)
    }
    private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else {
                error = String(localized: "Choose a macOS application.", comment: "Writing app rules: the chosen item is not an app")
                return
            }
            var rules = app.settings.data.applicationWritingRules ?? [:]
            if rules[id] == nil { rules[id] = AppWritingRule(name: FileManager.default.displayName(atPath: url.path)) }
            app.settings.data.applicationWritingRules = rules
            error = nil
        }
    }
}

private struct WritingApplicationRow: View {
    @Environment(AppCoordinator.self) private var app
    let bundleID: String
    @State private var editing = false
    @State private var icon: NSImage?
    @State private var hovered = false
    private var rule: AppWritingRule? { app.settings.data.applicationWritingRules?[bundleID] }
    private var summary: String {
        guard let rule else { return "" }
        let mode = switch rule.mode {
        case .never: String(localized: "Off", comment: "Writing app rule summary: never offer a revision")
        case .ask: String(localized: "Ask", comment: "Writing app rule summary: offer a revision after pasting")
        case .automatic: String(localized: "Automatic", comment: "Writing app rule summary: fix before inserting")
        }
        return "\(mode) · \(rule.writingAction.label)"
    }
    private func modeDescription(_ mode: WritingTrigger) -> String {
        switch mode {
        case .never: String(localized: "Inserts your original words.", comment: "Writing app rule: Off")
        case .ask: String(localized: "Inserts your words, then offers a revision.", comment: "Writing app rule: Ask after pasting")
        case .automatic: String(localized: "Edits before inserting, with no preview. Failures keep the original in History.",
                                comment: "Writing app rule: Automatic")
        }
    }
    var body: some View {
        if let rule {
            Button { editing = true } label: {
                HStack(spacing: 12) {
                    Group {
                        if let icon { Image(nsImage: icon).resizable().interpolation(.high).scaledToFit() }
                        else {
                            Image(systemName: "app").symbolRenderingMode(.monochrome)
                                .foregroundStyle(Mono.tertiaryText)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                    Text(rule.name).font(Typo.body).foregroundStyle(Mono.primaryText)
                    Spacer()
                    Text(summary).font(Typo.secondary).foregroundStyle(Mono.secondaryText)
                        .contentTransition(.opacity)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovered || editing ? Mono.secondaryText : Mono.tertiaryText)
                }
                .padding(.horizontal, Metrics.cardPadding).padding(.vertical, 10)
                .background(hovered || editing ? Mono.hover.opacity(0.5) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(MonoPlainButtonStyle(scales: false))
            .onHover { hovered = $0 }
            .monoAnimation(Motion.hover, value: hovered || editing)
            .monoAnimation(Motion.swap, value: summary)
            .accessibilityLabel("Edit \(rule.name), \(summary)")
            .popover(isPresented: $editing, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(rule.name).font(Typo.cardTitle)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Text("When").font(Typo.body).foregroundStyle(Mono.secondaryText)
                                .frame(width: 56, alignment: .leading)
                            WritingRulePicker(label: String(localized: "When", comment: "Writing app rule: when to revise"),
                                              titles: [
                                                String(localized: "Off", comment: "Writing app rule summary: never offer a revision"),
                                                String(localized: "Ask after pasting", comment: "Writing rule: offer Fix Mistakes after the text is pasted"),
                                                String(localized: "Automatic", comment: "Writing app rule summary: fix before inserting"),
                                              ],
                                selected: WritingTrigger.allCases.firstIndex(of: rule.mode) ?? 0) { index in
                                    app.settings.data.applicationWritingRules?[bundleID]?.trigger = WritingTrigger.allCases[index].rawValue
                                }.frame(width: 192, height: 26)
                        }
                        HStack(spacing: 12) {
                            Text("Action").font(Typo.body).foregroundStyle(Mono.secondaryText)
                                .frame(width: 56, alignment: .leading)
                            WritingRulePicker(label: String(localized: "Action", comment: "Writing app rule: which revision to apply"),
                                              titles: WritingAction.allCases.map(\.label),
                                selected: WritingAction.allCases.firstIndex(of: rule.writingAction) ?? 0) { index in
                                    app.settings.data.applicationWritingRules?[bundleID]?.action = WritingAction.allCases[index].rawValue
                                }.frame(width: 192, height: 26)
                        }
                    }
                    Text(modeDescription(rule.mode))
                        .font(Typo.secondary).foregroundStyle(Mono.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .monoAnimation(Motion.swap, value: rule.mode)
                    HStack {
                        Button("Remove") {
                            editing = false
                            app.settings.data.applicationWritingRules?.removeValue(forKey: bundleID)
                        }
                        .buttonStyle(MonoActionButtonStyle(.outline, size: .small))
                        Spacer()
                        Button("Done") { editing = false }
                            .buttonStyle(MonoActionButtonStyle(.primary, size: .small))
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 2)
                }.padding(20).frame(width: 300).foregroundStyle(Mono.primaryText)
            }
            .task {
                // Off the main actor, so a list of rules doesn't decode icons mid-transition.
                if let loaded = await AppIconLoader.icon(forBundleID: bundleID) { icon = loaded }
            }
        }
    }
}

/// Native popups opt into the shared column width instead of hugging their selected title.
private struct WritingRulePicker: NSViewRepresentable {
    let label: String
    let titles: [String]
    let selected: Int
    let onSelect: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let view = NSPopUpButton(frame: .zero, pullsDown: false)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.target = context.coordinator
        view.action = #selector(Coordinator.select(_:))
        return view
    }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        if view.itemTitles != titles { view.removeAllItems(); view.addItems(withTitles: titles) }
        view.selectItem(at: selected)
        view.setAccessibilityLabel(label)
    }
    @MainActor final class Coordinator: NSObject {
        var onSelect: (Int) -> Void
        init(onSelect: @escaping (Int) -> Void) { self.onSelect = onSelect }
        @objc func select(_ sender: NSPopUpButton) {
            guard sender.indexOfSelectedItem >= 0 else { return }
            onSelect(sender.indexOfSelectedItem)
        }
    }
}

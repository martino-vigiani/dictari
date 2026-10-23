import AppKit

/// Native presentation only. The coordinator's snapshot supplies availability and actions;
/// this component can also render in an isolated preview without services or user stores.
@MainActor
final class MenuBarMenu: NSObject, NSMenuDelegate {
    enum Action {
        case dictation, settings, updates, quit
        case profile(String)
        case copy(String)
    }

    let menu = NSMenu(title: "Dictari")
    var onAction: ((Action) -> Void)?
    private var presentation: MenuBarPresentation
    private var isOpen = false
    private var statusItem: NSMenuItem?
    private var primaryItem: NSMenuItem?
    private var copyItem: NSMenuItem?
    private var profileItem: NSMenuItem?
    private var updateItem: NSMenuItem?

    init(presentation: MenuBarPresentation) {
        self.presentation = presentation
        super.init()
        // A standard NSMenu automatically receives the system's Liquid Glass treatment on
        // macOS 26 and keeps the native menu material on macOS 14. Avoid custom backdrops here:
        // AppKit also owns keyboard navigation, VoiceOver, positioning and dismissal.
        menu.autoenablesItems = false
        menu.minimumWidth = 260
        menu.delegate = self
        rebuild()
    }

    func update(_ presentation: MenuBarPresentation) {
        self.presentation = presentation
        if isOpen { refreshItems() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuild()
    }

    // AppKit owns tracking; these callbacks must not change the menu structure.
    func menuWillOpen(_ menu: NSMenu) { isOpen = true }
    func menuDidClose(_ menu: NSMenu) { isOpen = false }

    private func rebuild() {
        menu.removeAllItems()
        statusItem = add("", to: menu)
        primaryItem = add("", to: menu, action: .dictation)
        copyItem = add(String(localized: "Copy Last Dictation", comment: "Menu bar item"), to: menu, symbol: "doc.on.clipboard", action: .copy(""))
        menu.addItem(.separator())

        profileItem = add("", to: menu, symbol: "slider.horizontal.3")
        let profiles = NSMenu(title: String(localized: "Profile", comment: "Menu bar submenu: dictation profiles"))
        profiles.autoenablesItems = false
        for (index, profile) in presentation.profiles.enumerated() {
            if index == presentation.builtInProfileCount, index > 0 { profiles.addItem(.separator()) }
            let item = add(profile.title, to: profiles, action: .profile(profile.id))
            item.state = profile.isSelected ? .on : .off
        }
        profileItem?.submenu = profiles
        profileItem?.isEnabled = true
        add(String(localized: "Settings…", comment: "Menu item: open the settings window"), to: menu, symbol: "gearshape", action: .settings, key: ",")
        updateItem = nil
        if presentation.updatesVisible {
            updateItem = add(
                String(localized: "Check for Updates…", comment: "Menu item"),
                to: menu,
                symbol: "arrow.triangle.2.circlepath",
                action: .updates
            )
        }
        menu.addItem(.separator())
        add(String(localized: "Quit Dictari", comment: "Menu item"), to: menu, action: .quit, key: "q")
        refreshItems()
    }

    private func refreshItems() {
        statusItem?.isHidden = presentation.status == nil
        statusItem?.title = MenuBarPresentation.compactPreview(presentation.status ?? "", limit: 52)
        statusItem?.toolTip = presentation.status.map {
            MenuBarPresentation.compactPreview($0, limit: 240)
        }
        statusItem?.image = Self.symbol("exclamationmark.circle")
        primaryItem?.title = presentation.primary.title
        primaryItem?.image = Self.symbol(presentation.primary.symbolName)
        primaryItem?.isEnabled = presentation.primary.isEnabled
        primaryItem?.toolTip = presentation.primary.shortcut
        if #available(macOS 14.4, *) { primaryItem?.subtitle = presentation.primary.shortcut }

        copyItem?.isEnabled = presentation.copy.isEnabled
        copyItem?.representedObject = Action.copy(presentation.copy.fullText)
        copyItem?.toolTip = presentation.copy.isEnabled
            ? MenuBarPresentation.compactPreview(presentation.copy.fullText, limit: 240)
            : String(localized: "Your next dictation appears here", comment: "Menu bar tooltip when there is no dictation yet")
        if #available(macOS 14.4, *) {
            copyItem?.subtitle = presentation.copy.preview
                ?? String(localized: "No dictation yet", comment: "Menu bar subtitle when there is no dictation yet")
        }

        profileItem?.title = presentation.profileTitle
        for item in profileItem?.submenu?.items ?? [] {
            if let action = item.representedObject as? Action, case .profile(let id) = action {
                item.state = presentation.profiles.first(where: { $0.id == id })?.isSelected == true ? .on : .off
            }
        }
        updateItem?.isEnabled = presentation.updatesEnabled
    }

    @discardableResult
    private func add(_ title: String, to menu: NSMenu, symbol: String? = nil,
                     action: Action? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action == nil ? nil : #selector(activateItem(_:)), keyEquivalent: key)
        item.target = self
        item.isEnabled = action != nil
        item.representedObject = action
        if let symbol { item.image = Self.symbol(symbol) }
        menu.addItem(item)
        return item
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    @objc private func activateItem(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? Action else { return }
        onAction?(action)
    }
}

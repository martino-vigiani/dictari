/// A service-free snapshot of the native menu. Keeping policy here makes the compact hierarchy
/// testable without launching the LSUIElement app or constructing AppKit objects.
struct MenuBarPresentation: Equatable, Sendable {
    enum ItemID: Equatable, Sendable {
        case status
        case primary
        case copy
        case profile
        case settings
        case updates
        case quit
    }

    struct ProfileInput: Equatable, Sendable {
        let id: String
        let name: String
    }

    struct Input: Equatable, Sendable {
        var dictationState: DictationState
        var feedback: AppFeedbackPresentation
        var isMediaBusy: Bool
        var shortcut: String?
        var profiles: [ProfileInput]
        var builtInProfileCount: Int
        var activeProfileID: String
        var activeProfileName: String
        var transcript: String
        var updatesVisible: Bool
        var updatesEnabled: Bool
    }

    struct Primary: Equatable, Sendable {
        let action: PrimaryDictationAction
        let title: String
        let symbolName: String
        let isEnabled: Bool
        let shortcut: String?
    }

    struct Copy: Equatable, Sendable {
        let fullText: String
        let preview: String?
        let isEnabled: Bool
    }

    struct Profile: Equatable, Sendable {
        let id: String
        let title: String
        let isSelected: Bool
    }

    let status: String?
    let primary: Primary
    let copy: Copy
    let profileTitle: String
    let profiles: [Profile]
    let builtInProfileCount: Int
    let updatesVisible: Bool
    let updatesEnabled: Bool

    var visibleItemOrder: [ItemID] {
        var items: [ItemID] = []
        if status != nil { items.append(.status) }
        items += [.primary, .copy, .profile, .settings]
        if updatesVisible { items.append(.updates) }
        items.append(.quit)
        return items
    }

    static func resolve(_ input: Input) -> MenuBarPresentation {
        let action = PrimaryDictationAction.resolve(for: input.dictationState)
        let primary: Primary
        switch action {
        case .start:
            primary = Primary(
                action: action,
                title: String(localized: "Start Dictation", comment: "Menu bar item"),
                symbolName: "waveform",
                isEnabled: !input.isMediaBusy,
                shortcut: input.shortcut
            )
        case .stop:
            primary = Primary(
                action: action,
                title: String(localized: "Finish Dictation", comment: "Menu bar item: stop recording and transcribe"),
                symbolName: "stop.fill",
                isEnabled: !input.isMediaBusy,
                shortcut: nil
            )
        case .cancel:
            primary = Primary(
                action: action,
                title: String(localized: "Cancel Transcription", comment: "Menu button"),
                symbolName: "xmark",
                isEnabled: !input.isMediaBusy,
                shortcut: nil
            )
        }

        let hasTranscript = input.transcript.contains { !$0.isWhitespace }
        let copy = Copy(
            fullText: input.transcript,
            preview: hasTranscript ? compactPreview(input.transcript, limit: 46) : nil,
            isEnabled: hasTranscript
        )
        let profiles = input.profiles.map { profile in
            Profile(
                id: profile.id,
                title: compactPreview(profile.name, limit: 42),
                isSelected: profile.id == input.activeProfileID
            )
        }
        return MenuBarPresentation(
            status: actionableStatus(for: input),
            primary: primary,
            copy: copy,
            profileTitle: String(localized: "Profile: \(compactPreview(input.activeProfileName, limit: 28))",
                                  comment: "Menu bar item; the argument is the active dictation profile name"),
            profiles: profiles,
            builtInProfileCount: min(max(input.builtInProfileCount, 0), profiles.count),
            updatesVisible: input.updatesVisible,
            updatesEnabled: input.updatesEnabled
        )
    }

    /// Routine lifecycle feedback is already expressed by the primary action and status-bar icon.
    /// Reserve a menu row for blockers or failures that change what the user can do next.
    private static func actionableStatus(for input: Input) -> String? {
        if input.isMediaBusy {
            return String(localized: "Files & Meetings is busy", comment: "Menu bar status; Files & Meetings is a section of the app")
        }
        switch input.feedback {
        case .loading, .attention, .error:
            return input.feedback.statusLabel
        case .ready, .listening, .transcribing, .success, .cancelled:
            return nil
        }
    }

    static func compactPreview(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return text.isEmpty ? "" : "…" }
        let singleLine = text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…"
    }
}

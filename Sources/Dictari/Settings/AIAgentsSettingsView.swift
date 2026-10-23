import AppKit
import SwiftUI

struct AIAgentsSettingsView: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var proposals = AgentProposalStore()
    @State private var confirmingDelete: AgentVocabularyProposal?
    /// Which client's setup snippet is showing. Nine stacked code blocks read as a wall; one
    /// picked from a menu reads as an instruction.
    @State private var selectedClient = AgentClient.claudeCode.rawValue

    private var accessEnabled: Bool { app.settings.data.mcpEnabled ?? false }

    var body: some View {
        @Bindable var settings = app.settings
        SettingsScrollPane(
            title: "AI Agents",
            subtitle: "Let AI agents on this Mac search the Dictari data you choose."
        ) {
            SettingsCard(title: "Data access") {
                SettingsRow("Allow AI agent access", sublabel: "Agents can read only the categories turned on below.") {
                    Toggle("", isOn: optionalBinding($settings.data.mcpEnabled)).labelsHidden().toggleStyle(MonoToggleStyle())
                }
                .settingsSearchAnchor("agents.allow")
                SettingsCardDivider()
                permissionRow("Dictation history", detail: "Text, date, language, duration, latency and app.", binding: $settings.data.mcpHistoryAccess)
                    .settingsSearchAnchor("agents.history")
                SettingsCardDivider()
                permissionRow("Statistics", detail: "Words, sessions, apps and average latency.", binding: $settings.data.mcpStatisticsAccess)
                    .settingsSearchAnchor("agents.statistics")
                SettingsCardDivider()
                permissionRow("Files & meetings", detail: "File and meeting transcripts.", binding: $settings.data.mcpMediaAccess)
                    .settingsSearchAnchor("agents.media")
                SettingsCardDivider()
                permissionRow("Vocabulary", detail: "Your custom words and their known alternatives.", binding: $settings.data.mcpVocabularyAccess)
                    .settingsSearchAnchor("agents.vocabulary")
                SettingsCardDivider()
                permissionRow("Vocabulary proposals", detail: "Agents can suggest changes. You approve them here.", binding: $settings.data.mcpAllowProposals)
                    .settingsSearchAnchor("agents.proposals")
            }

            privacyNotice.settingsSearchAnchor("agents.privacy")
            proposalsCard.settingsSearchAnchor("agents.pending")
            connectionCard.settingsSearchAnchor("agents.connect")
        }
        .onAppear { proposals.refresh() }
        // The coordinator opens or closes the loopback listener on this push.
        .onChange(of: LocalMCPServer.shouldListen(settings.data)) { app.applySettings() }
        .confirmationDialog(
            "Delete \u{201C}\(confirmingDelete?.word ?? "")\u{201D} from Vocabulary?",
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Vocabulary Entry", role: .destructive) {
                guard let proposal = confirmingDelete else { return }
                confirmingDelete = nil
                Task { await proposals.approve(proposal, vocabulary: app.vocabulary) }
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("The entry will be removed from Vocabulary.")
        }
    }

    private func optionalBinding(_ binding: Binding<Bool?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue ?? false }, set: { binding.wrappedValue = $0 })
    }

    @ViewBuilder
    private func permissionRow(_ title: LocalizedStringKey, detail: LocalizedStringKey,
                               binding: Binding<Bool?>) -> some View {
        SettingsRow(title, sublabel: detail) {
            Toggle("", isOn: optionalBinding(binding))
                .labelsHidden()
                .toggleStyle(MonoToggleStyle())
                .disabled(!accessEnabled)
        }
        // The categories dim with the master switch; fade it so the link between them is seen.
        .opacity(accessEnabled ? 1 : 0.55)
        .monoAnimation(Motion.snap, value: accessEnabled)
    }

    // MARK: Privacy

    private var privacyNotice: some View {
        SettingsCard(title: "Privacy") {
            VStack(alignment: .leading, spacing: 10) {
                AgentInfoLine(systemImage: "lock.shield",
                              text: "Agents can reach Dictari only while it is open, and only from this Mac.")
                AgentInfoLine(systemImage: "arrow.up.forward.square",
                              text: "Text an agent reads is shared with the AI service behind it.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.cardPadding)
        }
    }

    // MARK: Proposals

    private var proposalsCard: some View {
        let pending = proposals.pending
        return SettingsCard(title: "Agent proposals") {
            VStack(alignment: .leading, spacing: 0) {
                if pending.isEmpty {
                    SettingsEmptyState(
                        systemImage: "tray",
                        title: "No pending proposals",
                        message: app.settings.data.mcpAllowProposals ?? false
                            ? "When an agent suggests a vocabulary change, it waits here for you."
                            : "Turn on Vocabulary proposals above to let agents suggest words."
                    ) {
                        refreshButton
                    }
                    .transition(.opacity)
                } else {
                    HStack {
                        Text("\(pending.count) pending", comment: "Number of agent proposals waiting for review")
                            .font(Typo.cardTitle)
                            .foregroundStyle(Mono.primaryText)
                            .contentTransition(.numericText())
                        Spacer()
                        refreshButton
                    }
                    .padding(Metrics.cardPadding)
                    .transition(.opacity)

                    ForEach(pending) { proposal in
                        VStack(spacing: 0) {
                            SettingsCardDivider()
                            proposalRow(proposal)
                        }
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                    }
                }

                if let error = proposals.error {
                    SettingsNotice(error, systemImage: "exclamationmark.triangle")
                        .padding([.horizontal, .bottom], Metrics.cardPadding)
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
            .monoAnimation(Motion.reveal, value: pending.map(\.id))
            .monoAnimation(Motion.reveal, value: proposals.error)
        }
    }

    private var refreshButton: some View {
        Button {
            proposals.refresh()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
        .help("Check for new proposals")
    }

    private func proposalRow(_ proposal: AgentVocabularyProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Text(actionLabel(proposal.action)).foregroundStyle(Mono.secondaryText)) \(Text(verbatim: "\u{201C}" + proposal.word + "\u{201D}").fontWeight(.semibold))",
                         comment: "Agent proposal: the action (Add, Update, Delete), then the quoted word")
                        .font(Typo.body)
                        .foregroundStyle(Mono.primaryText)
                        .textSelection(.enabled)
                    if !proposal.alternatives.isEmpty {
                        Text("Alternatives: \(proposal.alternatives.joined(separator: ", "))",
                             comment: "Agent proposal: alternative spellings of the word")
                            .font(Typo.secondary)
                            .foregroundStyle(Mono.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !proposal.reason.isEmpty {
                        Text(proposal.reason)
                            .font(Typo.secondary)
                            .foregroundStyle(Mono.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    Button("Reject") { proposals.reject(proposal) }
                        .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                    Button(proposal.action == "delete" ? "Approve\u{2026}" : "Approve") {
                        if proposal.action == "delete" {
                            confirmingDelete = proposal
                        } else {
                            Task { await proposals.approve(proposal, vocabulary: app.vocabulary) }
                        }
                    }
                    .buttonStyle(MonoActionButtonStyle(.primary, size: .small))
                }
            }

            let entries = Array(evidence(for: proposal).prefix(3))
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(entry.appName ?? String(localized: "Unknown app")) \u{00B7} \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(Mono.tertiaryText)
                            Text(String(entry.text.prefix(140)))
                                .foregroundStyle(Mono.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(Typo.secondary)
                        .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius + 1, style: .continuous)
                        .fill(Mono.fieldFill)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Evidence from your dictations")
            }
        }
        .padding(Metrics.cardPadding)
    }

    // MARK: Connection

    private var connectionCard: some View {
        SettingsCard(
            title: "Connect a client",
            footer: app.localMCPToken == nil ? nil
                : "Every request must send this token. Treat it like a password: anyone holding it can read what the switches above allow. Start a new agent chat to load Dictari. For Codex, add the snippet to ~/.codex/config.toml; for OpenCode, use the config for your installed major version."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                listeningStatus
                    .padding(Metrics.cardPadding)

                if let token = app.localMCPToken {
                    let url = LocalMCPServer.endpoint.absoluteString
                    let client = AgentClient(rawValue: selectedClient) ?? .claudeCode
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsCardDivider()
                        snippetRow(name: String(localized: "Access token", comment: "Local MCP bearer token"),
                                   logo: nil, command: token, picker: false)
                        SettingsCardDivider()
                        snippetRow(
                            name: client.title,
                            logo: client.logo,
                            command: client.command(url: url, auth: "Bearer \(token)"),
                            picker: true
                        )
                    }
                    .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
            .monoAnimation(Motion.reveal, value: app.localMCPToken != nil)
            .monoAnimation(Motion.swap, value: app.localMCPListening)
        }
    }

    @ViewBuilder
    private var listeningStatus: some View {
        if app.localMCPListening {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Mono.primaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listening")
                        .font(Typo.body)
                        .foregroundStyle(Mono.primaryText)
                    Text(LocalMCPServer.endpoint.absoluteString)
                        .font(Typo.mono)
                        .foregroundStyle(Mono.secondaryText)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Local MCP address: \(LocalMCPServer.endpoint.absoluteString)")
            .transition(.opacity)
        } else {
            SettingsNotice(
                "Not listening. Allow AI agent access and at least one category to open the local address.",
                systemImage: "antenna.radiowaves.left.and.right.slash"
            )
            .transition(.opacity)
        }
    }

    private func snippetRow(name: String, logo: String?, command: String, picker: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let logo {
                    Image(logo)
                        .resizable()
                        .renderingMode(.original)
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .opacity(0.86)
                        .accessibilityHidden(true)
                }
                if picker {
                    Picker("Client", selection: $selectedClient) {
                        ForEach(AgentClient.allCases) { client in
                            Text(client.title).tag(client.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Choose the app you want to connect")
                } else {
                    Text(name).font(Typo.body).foregroundStyle(Mono.primaryText)
                }
                Spacer()
                MonoCopyButton("Copy", size: .small) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .accessibilityHint("Copies the \(name) setup to the clipboard")
            }
            Text(command)
                .font(Typo.mono)
                .foregroundStyle(Mono.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                        .fill(Mono.fieldFill)
                )
                .id(command)
                .transition(.opacity)
        }
        .padding(Metrics.cardPadding)
        .monoAnimation(Motion.swap, value: command)
    }

    /// `action` is the stored protocol value ("add", "update", "delete"): only its label is
    /// translated. An unknown value from a newer agent is shown as it arrived.
    private func actionLabel(_ action: String) -> String {
        switch action {
        case "add": String(localized: "Add", comment: "Agent proposal action: add a word to Vocabulary")
        case "update": String(localized: "Update", comment: "Agent proposal action: change a Vocabulary word")
        case "delete": String(localized: "Delete", comment: "Agent proposal action: remove a Vocabulary word")
        default: action.capitalized
        }
    }

    private func evidence(for proposal: AgentVocabularyProposal) -> [HistoryEntry] {
        let ids = Set(proposal.evidenceTranscriptIDs.compactMap(UUID.init(uuidString:)))
        return app.history.entries.filter { ids.contains($0.id) }
    }
}

// MARK: - Clients

/// The clients Dictari ships a setup snippet for. The snippets are the same strings the page
/// has always offered; only the presentation moved from a stacked list to a menu.
private enum AgentClient: String, CaseIterable, Identifiable {
    case codex, claudeCode, claudeDesktop, gemini, openCode1, openCode2, cursor, vsCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .gemini: "Gemini CLI"
        case .openCode1: "OpenCode 1.x"
        case .openCode2: "OpenCode 2.x"
        case .cursor: "Cursor"
        case .vsCode: "VS Code"
        }
    }

    var logo: String {
        switch self {
        case .codex: "AgentCodex"
        case .claudeCode, .claudeDesktop: "AgentClaude"
        case .gemini: "AgentGemini"
        case .openCode1, .openCode2: "AgentOpenCode"
        case .cursor: "AgentCursor"
        case .vsCode: "AgentVSCode"
        }
    }

    func command(url: String, auth: String) -> String {
        switch self {
        case .codex:
            "[mcp_servers.dictari]\nurl = \"\(url)\"\nhttp_headers = { Authorization = \"\(auth)\" }"
        case .claudeCode:
            "claude mcp add --transport http --scope user dictari \(url) --header \"Authorization: \(auth)\""
        case .claudeDesktop:
            "{\"mcpServers\":{\"dictari\":{\"type\":\"http\",\"url\":\"\(url)\",\"headers\":{\"Authorization\":\"\(auth)\"}}}}"
        case .gemini:
            "gemini mcp add --transport http --header \"Authorization: \(auth)\" dictari \(url)"
        case .openCode1:
            "{\"mcp\":{\"dictari\":{\"type\":\"remote\",\"url\":\"\(url)\",\"headers\":{\"Authorization\":\"\(auth)\"},\"enabled\":true}}}"
        case .openCode2:
            "{\"mcp\":{\"servers\":{\"dictari\":{\"type\":\"remote\",\"url\":\"\(url)\",\"headers\":{\"Authorization\":\"\(auth)\"},\"disabled\":false}}}}"
        case .cursor:
            "{\"mcpServers\":{\"dictari\":{\"type\":\"http\",\"url\":\"\(url)\",\"headers\":{\"Authorization\":\"\(auth)\"}}}}"
        case .vsCode:
            "code --add-mcp '{\"name\":\"dictari\",\"type\":\"http\",\"url\":\"\(url)\",\"headers\":{\"Authorization\":\"\(auth)\"}}'"
        }
    }
}

/// One line of explanation with a leading glyph, for cards that state facts rather than
/// hold controls.
private struct AgentInfoLine: View {
    let systemImage: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Mono.tertiaryText)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text)
                .font(Typo.secondary)
                .foregroundStyle(Mono.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

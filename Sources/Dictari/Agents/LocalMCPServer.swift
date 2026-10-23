import CryptoKit
import Foundation
import Network
import os
import Security

/// Native, loopback-only MCP server owned by the Dictari process.
///
/// The listener exists only while the AI-agent switches grant some access (`shouldListen`); with
/// everything off Dictari opens no socket at all, which is what "no network" means to a user. The
/// coordinator owns that decision. While listening, every request must carry the per-install
/// bearer token: loopback is shared by every process and every user session on the Mac, so the
/// Host/Origin checks alone only stop browsers. Data access stays fail-closed on top of that:
/// every tool re-reads the persisted switches before touching user content. Keeping the transport
/// native avoids shipping an interpreter or executing mutable scripts from outside the signed app
/// bundle.
final class LocalMCPServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 54_876
    static let endpoint = URL(string: "http://127.0.0.1:\(defaultPort)/mcp")!

    /// Listen only when the master switch is on and at least one data scope is granted. With the
    /// master off, or no scope granted, every tool would refuse anyway, so an open port would be
    /// pure attack surface. Scope values persist while the master is off, hence the master gate.
    static func shouldListen(_ settings: SettingsData) -> Bool {
        guard settings.mcpEnabled == true else { return false }
        return [
            settings.mcpHistoryAccess, settings.mcpStatisticsAccess, settings.mcpMediaAccess,
            settings.mcpVocabularyAccess, settings.mcpAllowProposals,
        ].contains { $0 == true }
    }

    private static let log = Logger(subsystem: "com.dictari.app", category: "mcp")
    private let queue = DispatchQueue(label: "com.dictari.mcp.listener", qos: .utility)
    private let service: LocalMCPService
    private let port: UInt16
    private var listener: NWListener?
    /// Only touched on `queue`, like `listener`, so connections always see a consistent value.
    private var token = ""

    init(root: URL = AppPaths.support, port: UInt16 = defaultPort) {
        service = LocalMCPService(root: root)
        self.port = port
    }

    func start(token: String) {
        queue.async { [self] in
            self.token = token
            guard listener == nil else { return }
            do {
                let tcp = NWProtocolTCP.Options()
                let parameters = NWParameters(tls: nil, tcp: tcp)
                // Toggling access off and straight back on rebinds the port just cancelled.
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: NWEndpoint.Port(rawValue: port)!
                )
                let listener = try NWListener(using: parameters)
                listener.stateUpdateHandler = { [weak listener] state in
                    switch state {
                    case .ready:
                        Self.log.notice("local MCP ready port=\(self.port, privacy: .public)")
                    case let .failed(error):
                        Self.log.error("local MCP failed: \(error.localizedDescription, privacy: .public)")
                        // Drop the dead listener so the next settings push can retry the bind
                        // instead of being short-circuited by `listener == nil`. The handler
                        // already runs on `queue`, the only place `self.listener` is touched.
                        guard let listener, self.listener === listener else { return }
                        listener.cancel()
                        self.listener = nil
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                Self.log.error("could not create local MCP listener: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if next.count > MCPHTTPRequest.maximumBytes {
                self.send(.payloadTooLarge, on: connection)
                return
            }
            switch MCPHTTPRequest.parse(next) {
            case .incomplete where !isComplete && error == nil:
                self.receive(on: connection, buffer: next)
            case let .complete(request):
                self.send(
                    LocalMCPHTTP.route(request, service: self.service, port: self.port, token: self.token),
                    on: connection
                )
            case .incomplete, .invalid:
                self.send(.badRequest, on: connection)
            }
        }
    }

    private func send(_ response: MCPHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.encoded, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

struct MCPHTTPRequest: Sendable {
    static let maximumBytes = 1_048_576

    enum ParseResult {
        case incomplete
        case invalid
        case complete(MCPHTTPRequest)
    }

    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) -> ParseResult {
        let marker = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: marker) else { return .incomplete }
        guard let head = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid }
            headers[name] = value
        }
        let contentLength: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0, parsed <= maximumBytes else { return .invalid }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return .incomplete }
        return .complete(MCPHTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        ))
    }
}

struct MCPHTTPResponse: Sendable {
    let status: Int
    let reason: String
    let body: Data
    var contentType = "application/json"
    var allow: String? = nil
    var wwwAuthenticate: String? = nil

    static let badRequest = MCPHTTPResponse(status: 400, reason: "Bad Request", body: Data())
    static let unauthorized = MCPHTTPResponse(
        status: 401, reason: "Unauthorized", body: Data(), wwwAuthenticate: "Bearer realm=\"dictari\""
    )
    static let forbidden = MCPHTTPResponse(status: 403, reason: "Forbidden", body: Data())
    static let notFound = MCPHTTPResponse(status: 404, reason: "Not Found", body: Data())
    static let methodNotAllowed = MCPHTTPResponse(
        status: 405, reason: "Method Not Allowed", body: Data(), allow: "POST"
    )
    static let payloadTooLarge = MCPHTTPResponse(status: 413, reason: "Payload Too Large", body: Data())
    static let unsupportedMedia = MCPHTTPResponse(status: 415, reason: "Unsupported Media Type", body: Data())
    static let accepted = MCPHTTPResponse(status: 202, reason: "Accepted", body: Data())

    var encoded: Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if let allow { head += "Allow: \(allow)\r\n" }
        if let wwwAuthenticate { head += "WWW-Authenticate: \(wwwAuthenticate)\r\n" }
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

enum LocalMCPHTTP {
    static func route(
        _ request: MCPHTTPRequest, service: LocalMCPService, port: UInt16, token: String
    ) -> MCPHTTPResponse {
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
        guard request.headers["origin"] == nil,
              let host = request.headers["host"], allowedHosts.contains(host.lowercased()) else {
            return .forbidden
        }
        // Before any route, /health included: an unauthenticated caller should not even learn
        // which paths exist.
        guard LocalMCPToken.authorizes(request.headers["authorization"], token: token) else {
            return .unauthorized
        }
        if request.method == "GET", request.path == "/health" {
            return MCPHTTPResponse(
                status: 200,
                reason: "OK",
                body: Data("{\"status\":\"ok\",\"transport\":\"local-http\"}".utf8)
            )
        }
        guard request.path == "/mcp" else { return .notFound }
        if let version = request.headers["mcp-protocol-version"],
           !LocalMCPService.supportedProtocolVersions.contains(version) {
            return .badRequest
        }
        // Clients probe GET for an optional SSE stream; 405 means POST-only, not a missing endpoint.
        guard request.method == "POST" else { return .methodNotAllowed }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return .unsupportedMedia
        }
        guard let body = service.handle(request.body) else { return .accepted }
        return MCPHTTPResponse(status: 200, reason: "OK", body: body)
    }
}

/// Per-install bearer token for the local MCP listener.
///
/// Stored as a 0600 file next to settings.json rather than in the Keychain. The token has to be
/// pasted in plaintext into client configs (~/.claude.json, Cursor, VS Code…), and the transcripts
/// it guards already sit as plain JSON in this same folder, so the Keychain would add nothing
/// against a same-user process — while its ACL is keyed to the code signature and would prompt
/// after unsigned or re-signed Debug builds. What the token has to stop is other user accounts
/// and sandboxed apps reaching the shared loopback port, and neither can read this file.
enum LocalMCPToken {
    static let fileName = "mcp-token"
    static let byteCount = 32

    static func loadOrCreate(in root: URL = AppPaths.support) throws -> String {
        let url = root.appendingPathComponent(fileName)
        let fm = FileManager.default
        if let data = try? Data(contentsOf: url),
           let stored = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           isWellFormed(stored) {
            // Repair permissions a restore or a copy may have widened.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return stored
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Hex keeps the token inert in shells, JSON and TOML snippets alike.
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Created 0600 from the first byte, then swapped in, so the token is never readable by
        // anyone else, not even between a write and a later chmod.
        let temp = root.appendingPathComponent(".\(fileName)-\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: Data(token.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fm.fileExists(atPath: url.path) {
                // New metadata only: the default would carry a corrupt file's wider mode over.
                _ = try fm.replaceItemAt(url, withItemAt: temp, options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        return token
    }

    static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == byteCount * 2
            && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Accepts only `Authorization: Bearer <token>`. The comparison visits every byte whatever
    /// the mismatch position, so response timing cannot be used to recover the token piecewise.
    static func authorizes(_ header: String?, token: String) -> Bool {
        guard !token.isEmpty, let header else { return false }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        let presented = parts[1].trimmingCharacters(in: .whitespaces)
        return constantTimeEquals(Array(presented.utf8), Array(token.utf8))
    }

    static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        // The length is not secret (always 64 hex characters), so exiting early on it leaks nothing.
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}

/// File-backed MCP tool service. It reads immutable snapshots and writes only approval-pending
/// proposal files, so it cannot race the app's in-memory stores into destructive mutations.
final class LocalMCPService: @unchecked Sendable {
    static let protocolVersion = "2025-11-25"
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let maximumLimit = 100
    static let maximumTextCharacters = 20_000

    private let root: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(root: URL) {
        self.root = root
        encoder.outputFormatting = [.sortedKeys]
    }

    func handle(_ data: Data) -> Data? {
        let requestID: Any
        do {
            guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return encode(errorResponse(id: NSNull(), code: -32600, message: "Invalid Request"))
            }
            requestID = message["id"] ?? NSNull()
            guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
                return encode(errorResponse(id: requestID, code: -32600, message: "Invalid Request"))
            }
            if message["id"] == nil { return nil }
            switch method {
            case "initialize":
                let parameters = message["params"] as? [String: Any]
                let requested = parameters?["protocolVersion"] as? String
                let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
                    ?? Self.protocolVersion
                return encode(successResponse(id: requestID, result: [
                    "protocolVersion": version,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "dictari", "version": "0.2.0"],
                ]))
            case "ping":
                return encode(successResponse(id: requestID, result: [:]))
            case "tools/list":
                return encode(successResponse(id: requestID, result: ["tools": toolDefinitions]))
            case "tools/call":
                guard let parameters = message["params"] as? [String: Any],
                      let name = parameters["name"] as? String,
                      let arguments = (parameters["arguments"] as? [String: Any]) ?? (parameters["arguments"] == nil ? [:] : nil)
                else {
                    return encode(errorResponse(id: requestID, code: -32602, message: "Invalid params"))
                }
                do {
                    let payload = try call(name: name, arguments: arguments)
                    return encode(successResponse(id: requestID, result: toolResult(payload)))
                } catch {
                    return encode(successResponse(
                        id: requestID,
                        result: toolResult(["error": error.localizedDescription], isError: true)
                    ))
                }
            default:
                return encode(errorResponse(id: requestID, code: -32601, message: "Method not found"))
            }
        } catch {
            return encode(errorResponse(id: NSNull(), code: -32700, message: "Parse error"))
        }
    }

    private func call(name: String, arguments: [String: Any]) throws -> [String: Any] {
        switch name {
        case "get_capabilities": try capabilities()
        case "search_transcripts": try searchTranscripts(arguments)
        case "get_transcript": try getTranscript(arguments)
        case "get_statistics": try getStatistics(arguments)
        case "list_media": try listMedia(arguments)
        case "get_media_transcript": try getMediaTranscript(arguments)
        case "list_vocabulary": try listVocabulary(arguments)
        case "propose_vocabulary_change": try proposeVocabularyChange(arguments)
        case "list_proposals": try listProposals(arguments)
        default: throw MCPServiceError.invalid("Unknown tool: \(name)")
        }
    }

    private var permissions: [String: Bool] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return [
            "enabled": value["mcpEnabled"] as? Bool ?? false,
            "history": value["mcpHistoryAccess"] as? Bool ?? false,
            "statistics": value["mcpStatisticsAccess"] as? Bool ?? false,
            "media": value["mcpMediaAccess"] as? Bool ?? false,
            "vocabulary": value["mcpVocabularyAccess"] as? Bool ?? false,
            "proposals": value["mcpAllowProposals"] as? Bool ?? false,
        ]
    }

    private func require(_ scope: String) throws {
        let permissions = permissions
        guard permissions["enabled"] == true, permissions[scope] == true else {
            throw MCPServiceError.permission("Dictari access to \(scope) is disabled. Enable it in Settings > AI Agents.")
        }
    }

    private func capabilities() throws -> [String: Any] {
        let permissions = permissions
        return [
            "server_version": "0.2.0",
            "transport": "local-http",
            "endpoint": LocalMCPServer.endpoint.absoluteString,
            "enabled": permissions["enabled"] ?? false,
            "scopes": Dictionary(uniqueKeysWithValues: ["history", "statistics", "media", "vocabulary", "proposals"].map {
                ($0, (permissions["enabled"] ?? false) && (permissions[$0] ?? false))
            }),
            "privacy": "Loopback-only server. Returned content becomes visible to the connected AI provider.",
            "limits": ["max_page_size": Self.maximumLimit, "max_text_chars": Self.maximumTextCharacters],
        ]
    }

    private func history(scope: String = "history") throws -> [HistoryEntry] {
        try require(scope)
        let url = root.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try boundedData(at: url, maximumBytes: 64 * 1024 * 1024)
        return try decoder.decode([HistoryEntry].self, from: data)
    }

    private func filteredHistory(_ arguments: [String: Any], scope: String = "history") throws -> [HistoryEntry] {
        let query = string(arguments["query"]).folded
        let app = string(arguments["app"]).folded
        let language = string(arguments["language"]).folded
        let status = string(arguments["status"], default: "all").lowercased()
        let since = dateArgument(arguments["since"])
        let until = dateArgument(arguments["until"])
        return try history(scope: scope).filter { entry in
            if !query.isEmpty, !entry.displayText.folded.contains(query) { return false }
            let application = [entry.appName, entry.appBundleID].compactMap { $0 }.joined(separator: " ").folded
            if !app.isEmpty, !application.contains(app) { return false }
            if !language.isEmpty, entry.language?.folded != language { return false }
            if status == "success", entry.isFailure { return false }
            if status == "failure", !entry.isFailure { return false }
            if let since, entry.date < since { return false }
            if let until, entry.date > until { return false }
            return true
        }.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.id.uuidString > rhs.id.uuidString : lhs.date > rhs.date
        }
    }

    private func searchTranscripts(_ arguments: [String: Any]) throws -> [String: Any] {
        let filtered = try filteredHistory(arguments)
        let page = historyPage(filtered, arguments: arguments)
        let snippetCharacters = boundedInt(arguments["snippet_chars"], default: 180, minimum: 0, maximum: 500)
        let fields = Set(arguments["fields"] as? [String] ?? ["id", "date", "app", "language", "word_count", "status", "snippet"])
        let query = string(arguments["query"])
        return [
            "items": page.items.map { compactHistory($0, snippetCharacters: snippetCharacters, fields: fields, query: query) },
            "next_cursor": page.cursor ?? NSNull(),
            "total": filtered.count,
        ]
    }

    private func getTranscript(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let identifier = UUID(uuidString: string(arguments["id"])),
              let entry = try history().first(where: { $0.id == identifier }) else {
            throw MCPServiceError.notFound("Transcript not found")
        }
        let offset = boundedInt(arguments["offset"], default: 0, minimum: 0, maximum: 10_000_000)
        let maximum = boundedInt(arguments["max_chars"], default: 4_000, minimum: 1, maximum: Self.maximumTextCharacters)
        let chunk = characterSlice(entry.displayText, offset: offset, limit: maximum)
        var result = compactHistory(entry, snippetCharacters: 0, fields: ["id", "date", "app", "bundle_id", "language", "duration_seconds", "word_count", "latency_ms", "status", "tag"], query: "")
        result["text"] = chunk.text
        result["offset"] = offset
        result["next_offset"] = chunk.hasMore ? offset + chunk.count : NSNull()
        result["text_length"] = entry.displayText.count
        return result
    }

    private func getStatistics(_ arguments: [String: Any]) throws -> [String: Any] {
        let entries = try filteredHistory(arguments, scope: "statistics")
        let successful = entries.filter { !$0.isFailure }
        var appWords: [String: Int] = [:]
        var languageWords: [String: Int] = [:]
        var dailyWords: [String: Int] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        for entry in successful {
            appWords[entry.appName ?? "Unknown", default: 0] += entry.wordCount
            languageWords[entry.language ?? "unknown", default: 0] += entry.wordCount
            dailyWords[dayFormatter.string(from: entry.date), default: 0] += entry.wordCount
        }
        let topCount = boundedInt(arguments["top_n"], default: 5, minimum: 1, maximum: 20)
        let days = boundedInt(arguments["days"], default: 30, minimum: 1, maximum: 366)
        let latency = successful.map(\.latencyMs)
        return [
            "sessions": entries.count,
            "successful_sessions": successful.count,
            "failed_sessions": entries.count - successful.count,
            "words": successful.reduce(0) { $0 + $1.wordCount },
            "speech_seconds": successful.reduce(0) { $0 + $1.durationSeconds },
            "average_latency_ms": latency.isEmpty ? NSNull() : Int((Double(latency.reduce(0, +)) / Double(latency.count)).rounded()),
            "top_apps": ranked(appWords, limit: topCount),
            "languages": ranked(languageWords, limit: topCount),
            "daily_words": dailyWords.sorted { $0.key > $1.key }.prefix(days).map { [$0.key, $0.value] },
        ]
    }

    private func mediaDocuments() throws -> [MediaDocument] {
        try require("media")
        let directory = root.appendingPathComponent("Transcripts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .prefix(10_000)
            .compactMap { folder in
                let url = folder.appendingPathComponent("document.json")
                guard let data = try? boundedData(at: url, maximumBytes: 16 * 1024 * 1024),
                      let document = try? decoder.decode(MediaDocument.self, from: data),
                      document.id.uuidString == folder.lastPathComponent else { return nil }
                return document
            }.sorted { $0.created > $1.created }
    }

    private func listMedia(_ arguments: [String: Any]) throws -> [String: Any] {
        let query = string(arguments["query"]).folded
        let documents = try mediaDocuments().filter { query.isEmpty || $0.title.folded.contains(query) }
        let page = offsetPage(documents, arguments: arguments)
        return [
            "items": page.items.map { document in [
                "id": document.id.uuidString,
                "title": document.title,
                "created": isoString(document.created),
                "language": document.language,
                "status": document.status,
                "segment_count": document.segments.count,
                "has_transcript": document.hasTranscript,
            ] as [String: Any] },
            "next_cursor": page.cursor ?? NSNull(),
            "total": documents.count,
        ]
    }

    private func getMediaTranscript(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let identifier = UUID(uuidString: string(arguments["id"])),
              let document = try mediaDocuments().first(where: { $0.id == identifier }) else {
            throw MCPServiceError.notFound("Media transcript not found")
        }
        let offset = boundedInt(arguments["offset"], default: 0, minimum: 0, maximum: 10_000_000)
        let maximum = boundedInt(arguments["max_chars"], default: 6_000, minimum: 1, maximum: Self.maximumTextCharacters)
        let chunk = characterSlice(document.transcript, offset: offset, limit: maximum)
        return [
            "id": document.id.uuidString,
            "title": document.title,
            "created": isoString(document.created),
            "language": document.language,
            "status": document.status,
            "text": chunk.text,
            "offset": offset,
            "next_offset": chunk.hasMore ? offset + chunk.count : NSNull(),
            "text_length": document.transcript.count,
        ]
    }

    private func vocabulary() throws -> [VocabularyTerm] {
        try require("vocabulary")
        let url = root.appendingPathComponent("vocabulary.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([VocabularyTerm].self, from: boundedData(at: url, maximumBytes: 16 * 1024 * 1024))
    }

    private func listVocabulary(_ arguments: [String: Any]) throws -> [String: Any] {
        let query = string(arguments["query"]).folded
        let terms = try vocabulary().filter { term in
            query.isEmpty || term.text.folded.contains(query) || term.alternatives.contains { $0.folded.contains(query) }
        }
        let page = offsetPage(terms, arguments: arguments)
        return [
            "items": page.items.map { [
                "id": $0.id.uuidString, "text": $0.text, "enabled": $0.enabled, "alternatives": $0.alternatives,
            ] as [String: Any] },
            "next_cursor": page.cursor ?? NSNull(),
            "total": terms.count,
        ]
    }

    private func proposeVocabularyChange(_ arguments: [String: Any]) throws -> [String: Any] {
        try require("proposals")
        let action = string(arguments["action"], default: "add")
        guard ["add", "update", "delete"].contains(action) else {
            throw MCPServiceError.invalid("action must be add, update, or delete")
        }
        let word = string(arguments["word"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 200 else {
            throw MCPServiceError.invalid("word must contain 1-200 characters")
        }
        let alternatives = (arguments["alternatives"] as? [Any] ?? [])
            .map { string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(20)
        let targetIdentifier = UUID(uuidString: string(arguments["target_term_id"]))
        if ["update", "delete"].contains(action), targetIdentifier == nil {
            throw MCPServiceError.invalid("target_term_id is required for update and delete")
        }
        let reason = String(string(arguments["reason"]).prefix(1_000))
        let evidence = (arguments["evidence_transcript_ids"] as? [Any] ?? []).map { string($0) }.prefix(20)
        let canonical: [String: Any] = [
            "action": action,
            "word": word,
            "alternatives": Array(alternatives),
            "targetTermID": targetIdentifier?.uuidString ?? "",
            "reason": reason,
            "evidenceTranscriptIDs": Array(evidence),
        ]
        let callerKey = string(arguments["idempotency_key"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalData = try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])
        let rawKey = callerKey.isEmpty ? SHA256.hash(data: canonicalData).map { String(format: "%02x", $0) }.joined() : String(callerKey.prefix(200))
        let idempotencyIdentifier = UUID(uuidString: rawKey) ?? stableUUID(seed: "dictari:idempotency:\(rawKey)")
        let proposalIdentifier = stableUUID(seed: "dictari:vocabulary:\(rawKey)")
        let folder = root.appendingPathComponent("Agent Proposals", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(proposalIdentifier.uuidString.lowercased()).appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: destination.path),
           let existing = try? decoder.decode(AgentVocabularyProposal.self, from: Data(contentsOf: destination)) {
            return ["proposal_id": proposalIdentifier.uuidString, "status": existing.status,
                    "message": "This proposal already exists; no duplicate was created."]
        }
        let pending = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.prefix(500)
            .compactMap { try? decoder.decode(AgentVocabularyProposal.self, from: Data(contentsOf: $0)) }
            .filter { ["pending", "applying"].contains($0.status) }.count
        guard pending < 200 else {
            throw MCPServiceError.invalid("Too many pending proposals; review them in Dictari before adding more")
        }
        let proposal = AgentVocabularyProposal(
            id: proposalIdentifier,
            created: isoString(Date()),
            status: "pending",
            action: action,
            word: word,
            alternatives: Array(alternatives),
            reason: reason,
            evidenceTranscriptIDs: Array(evidence),
            targetTermID: targetIdentifier,
            idempotencyKey: idempotencyIdentifier
        )
        try encoder.encode(proposal).write(to: destination, options: .atomic)
        return ["proposal_id": proposalIdentifier.uuidString, "status": "pending",
                "message": "Pending approval in Dictari > AI Agents."]
    }

    private func listProposals(_ arguments: [String: Any]) throws -> [String: Any] {
        try require("proposals")
        let folder = root.appendingPathComponent("Agent Proposals", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return ["items": [], "next_cursor": NSNull(), "total": 0]
        }
        let status = string(arguments["status"], default: "all")
        let proposals = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.prefix(500)
            .compactMap { try? decoder.decode(AgentVocabularyProposal.self, from: Data(contentsOf: $0)) }
            .filter { status == "all" || $0.status == status }
            .sorted { $0.created > $1.created }
        let page = offsetPage(proposals, arguments: arguments)
        return [
            "items": page.items.compactMap { proposal -> Any? in
                guard let data = try? encoder.encode(proposal) else { return nil }
                return try? JSONSerialization.jsonObject(with: data)
            },
            "next_cursor": page.cursor ?? NSNull(),
            "total": proposals.count,
        ]
    }

    private var toolDefinitions: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ schema: [String: Any], readOnly: Bool = true) -> [String: Any] {
            [
                "name": name,
                "description": description,
                "inputSchema": schema,
                "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false],
            ]
        }
        let empty: [String: Any] = ["type": "object", "properties": [:]]
        let searchProperties: [String: Any] = [
            "query": ["type": "string"],
            "app": ["type": "string"],
            "language": ["type": "string"],
            "status": ["enum": ["all", "success", "failure"]],
            "since": ["type": ["string", "number"]],
            "until": ["type": ["string", "number"]],
            "limit": ["type": "integer"],
            "cursor": ["type": ["string", "integer"]],
            "snippet_chars": ["type": "integer"],
        ]
        let transcriptProperties: [String: Any] = [
            "id": ["type": "string"],
            "offset": ["type": "integer"],
            "max_chars": ["type": "integer"],
        ]
        let statisticsProperties: [String: Any] = [
            "app": ["type": "string"],
            "language": ["type": "string"],
            "since": ["type": ["string", "number"]],
            "until": ["type": ["string", "number"]],
            "top_n": ["type": "integer"],
            "days": ["type": "integer"],
        ]
        let listProperties: [String: Any] = [
            "query": ["type": "string"],
            "limit": ["type": "integer"],
            "cursor": ["type": ["string", "integer"]],
        ]
        let proposalProperties: [String: Any] = [
            "action": ["enum": ["add", "update", "delete"]],
            "word": ["type": "string"],
            "alternatives": ["type": "array", "items": ["type": "string"]],
            "target_term_id": ["type": "string", "format": "uuid"],
            "idempotency_key": ["type": "string"],
            "reason": ["type": "string"],
            "evidence_transcript_ids": ["type": "array", "items": ["type": "string"]],
        ]
        let proposalListProperties: [String: Any] = [
            "status": ["enum": ["all", "pending", "approved", "rejected"]],
            "limit": ["type": "integer"],
            "cursor": ["type": ["string", "integer"]],
        ]
        return [
            tool("get_capabilities", "Show enabled local scopes and result limits.", empty),
            tool("search_transcripts", "Search dictation metadata and bounded snippets; full text is opt-in by ID.", ["type": "object", "properties": searchProperties]),
            tool("get_transcript", "Fetch one transcript by ID with character pagination.", ["type": "object", "required": ["id"], "properties": transcriptProperties]),
            tool("get_statistics", "Compute aggregate dictation statistics without returning transcript text.", ["type": "object", "properties": statisticsProperties]),
            tool("list_media", "List imported files and meeting transcripts without content.", ["type": "object", "properties": listProperties]),
            tool("get_media_transcript", "Fetch one file or meeting transcript with character pagination.", ["type": "object", "required": ["id"], "properties": transcriptProperties]),
            tool("list_vocabulary", "List or search the custom vocabulary.", ["type": "object", "properties": listProperties]),
            tool("propose_vocabulary_change", "Create an approval-pending vocabulary proposal; never edits vocabulary directly.", ["type": "object", "required": ["action", "word", "reason"], "properties": proposalProperties], readOnly: false),
            tool("list_proposals", "List vocabulary proposals and their approval status.", ["type": "object", "properties": proposalListProperties]),
        ]
    }

    private func compactHistory(_ entry: HistoryEntry, snippetCharacters: Int, fields: Set<String>, query: String) -> [String: Any] {
        var start = 0
        // Agents read what the user reads: the History correction when there is one.
        let text = entry.displayText
        if !query.isEmpty, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            start = max(0, text.distance(from: text.startIndex, to: range.lowerBound) - snippetCharacters / 3)
        }
        let chunk = characterSlice(text, offset: start, limit: snippetCharacters)
        let snippet = (start > 0 ? "…" : "") + chunk.text + (chunk.hasMore ? "…" : "")
        let available: [String: Any] = [
            "id": entry.id.uuidString,
            "date": isoString(entry.date),
            "app": entry.appName ?? NSNull(),
            "bundle_id": entry.appBundleID ?? NSNull(),
            "language": entry.language ?? NSNull(),
            "duration_seconds": entry.durationSeconds,
            "word_count": entry.wordCount,
            "latency_ms": entry.latencyMs,
            "status": entry.isFailure ? "failure" : "success",
            "tag": entry.tag ?? NSNull(),
            "snippet": snippet,
        ]
        var requested = fields
        requested.insert("id")
        return available.filter { requested.contains($0.key) }
    }

    private func historyPage(_ entries: [HistoryEntry], arguments: [String: Any]) -> (items: [HistoryEntry], cursor: String?) {
        let limit = boundedInt(arguments["limit"], default: 20, minimum: 1, maximum: Self.maximumLimit)
        var remaining = entries
        if let raw = arguments["cursor"] as? String,
           let data = Data(base64Encoded: paddedBase64(raw)),
           let cursor = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let timestamp = cursor["date"] as? Double,
           let identifier = cursor["id"] as? String {
            let boundaryDate = Date(timeIntervalSinceReferenceDate: timestamp)
            remaining = entries.filter { $0.date < boundaryDate || ($0.date == boundaryDate && $0.id.uuidString < identifier) }
        }
        let items = Array(remaining.prefix(limit))
        guard remaining.count > limit, let last = items.last else { return (items, nil) }
        let cursorData = try? JSONSerialization.data(withJSONObject: [
            "date": last.date.timeIntervalSinceReferenceDate, "id": last.id.uuidString,
        ], options: [.sortedKeys])
        return (items, cursorData?.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "=")))
    }

    private func offsetPage<T>(_ items: [T], arguments: [String: Any]) -> (items: [T], cursor: String?) {
        let offset = boundedInt(arguments["cursor"], default: 0, minimum: 0, maximum: 10_000_000)
        let limit = boundedInt(arguments["limit"], default: 20, minimum: 1, maximum: Self.maximumLimit)
        guard offset < items.count else { return ([], nil) }
        let end = min(items.count, offset + limit)
        return (Array(items[offset..<end]), end < items.count ? String(end) : nil)
    }

    private func toolResult(_ payload: [String: Any], isError: Bool = false) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        var result: [String: Any] = ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
        if isError { result["isError"] = true }
        return result
    }

    private func successResponse(id: Any, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}".utf8)
    }

    private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= maximumBytes else {
            throw MCPServiceError.invalid("\(url.lastPathComponent) exceeds the safety limit")
        }
        return try Data(contentsOf: url)
    }

    private func boundedInt(_ rawValue: Any?, default defaultValue: Int, minimum: Int, maximum: Int) -> Int {
        let resolved: Int
        if let number = rawValue as? NSNumber { resolved = number.intValue }
        else if let string = rawValue as? String, let parsed = Int(string) { resolved = parsed }
        else { resolved = defaultValue }
        return min(maximum, max(minimum, resolved))
    }

    private func string(_ value: Any?, default defaultValue: String = "") -> String {
        value as? String ?? defaultValue
    }

    private func dateArgument(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    private func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func ranked(_ values: [String: Int], limit: Int) -> [[Any]] {
        values.sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value }
            .prefix(limit).map { [$0.key, $0.value] }
    }

    private func characterSlice(_ text: String, offset: Int, limit: Int) -> (text: String, count: Int, hasMore: Bool) {
        guard offset < text.count, limit > 0 else { return ("", 0, offset < text.count) }
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: min(limit, text.distance(from: start, to: text.endIndex)))
        let chunk = String(text[start..<end])
        return (chunk, chunk.count, end < text.endIndex)
    }

    private func paddedBase64(_ value: String) -> String {
        value + String(repeating: "=", count: (4 - value.count % 4) % 4)
    }

    private func stableUUID(seed: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        return UUID(uuidString: value)!
    }
}

private enum MCPServiceError: LocalizedError {
    case permission(String)
    case invalid(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case let .permission(message), let .invalid(message), let .notFound(message): message
        }
    }
}

private extension String {
    var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }
}

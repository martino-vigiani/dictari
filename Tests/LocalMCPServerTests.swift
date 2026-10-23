import XCTest
import Testing

final class LocalMCPServerTests: XCTestCase {
    static let token = String(repeating: "ab", count: 32)
    private var root: URL!
    private var service: LocalMCPService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictari-native-mcp-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeSettings(enabled: true)
        try JSONEncoder().encode([
            HistoryEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                date: Date(timeIntervalSinceReferenceDate: 800_000_000),
                text: "Ship Dictari on Friday",
                durationSeconds: 5,
                wordCount: 4,
                latencyMs: 220,
                appName: "Slack",
                appBundleID: "com.tinyspeck.slackmacgap",
                language: "en"
            ),
            HistoryEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                date: Date(timeIntervalSinceReferenceDate: 799_000_000),
                text: "Errore riconoscimento",
                durationSeconds: 3,
                wordCount: 2,
                latencyMs: 300,
                appName: "Notes",
                language: "it",
                tag: "failed"
            ),
        ]).write(to: root.appendingPathComponent("history.json"), options: .atomic)
        try JSONEncoder().encode([
            VocabularyTerm(text: "Dictari", alternatives: ["Kittari"]),
        ]).write(to: root.appendingPathComponent("vocabulary.json"), options: .atomic)
        service = LocalMCPService(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testInitializeAndToolListExposeNativeServer() throws {
        let initialized = try request(method: "initialize", parameters: ["protocolVersion": "2025-06-18"])
        let result = try XCTUnwrap(initialized["result"] as? [String: Any])
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "dictari")
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")

        let listed = try request(method: "tools/list")
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 9)
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }).count, 9)
    }

    func testDisabledScopesFailClosedWhileCapabilitiesRemainReadable() throws {
        try writeSettings(enabled: false)
        let capabilities = try call("get_capabilities")
        XCTAssertEqual(capabilities["enabled"] as? Bool, false)

        let response = try request(method: "tools/call", parameters: [
            "name": "search_transcripts", "arguments": [:],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let message = try XCTUnwrap(toolPayload(from: result)["error"] as? String)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("disabled"))
    }

    func testSearchAndStatisticsStayCompact() throws {
        let search = try call("search_transcripts", arguments: [
            "app": "Slack", "limit": 1, "snippet_chars": 4,
        ])
        XCTAssertEqual(search["total"] as? Int, 1)
        let items = try XCTUnwrap(search["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["snippet"] as? String, "Ship…")

        let statistics = try call("get_statistics")
        XCTAssertEqual(statistics["words"] as? Int, 4)
        XCTAssertEqual(statistics["failed_sessions"] as? Int, 1)
        let encoded = try JSONSerialization.data(withJSONObject: statistics)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("Ship Dictari"))
    }

    func testVocabularyProposalIsDecodableAndIdempotent() throws {
        let arguments: [String: Any] = [
            "action": "add", "word": "Martino", "reason": "Repeated correction",
            "idempotency_key": "same-request",
        ]
        let first = try call("propose_vocabulary_change", arguments: arguments)
        let second = try call("propose_vocabulary_change", arguments: arguments)
        XCTAssertEqual(first["proposal_id"] as? String, second["proposal_id"] as? String)

        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Agent Proposals"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, 1)
        let proposal = try JSONDecoder().decode(AgentVocabularyProposal.self, from: Data(contentsOf: files[0]))
        XCTAssertEqual(proposal.word, "Martino")
        XCTAssertEqual(proposal.status, "pending")
        XCTAssertNotNil(proposal.idempotencyKey)
    }

    func testHTTPRouteAllowsLoopbackClientsAndRejectsBrowserOrigins() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "ping",
        ])
        let allowed = MCPHTTPRequest(
            method: "POST", path: "/mcp",
            headers: [
                "host": "127.0.0.1:54876", "content-type": "application/json",
                "authorization": "Bearer \(Self.token)",
            ],
            body: body
        )
        XCTAssertEqual(LocalMCPHTTP.route(allowed, service: service, port: 54_876, token: Self.token).status, 200)

        let browser = MCPHTTPRequest(
            method: "POST", path: "/mcp",
            headers: [
                "host": "127.0.0.1:54876", "content-type": "application/json",
                "origin": "https://attacker.example", "authorization": "Bearer \(Self.token)",
            ],
            body: body
        )
        XCTAssertEqual(LocalMCPHTTP.route(browser, service: service, port: 54_876, token: Self.token).status, 403)
    }

    func testHTTPRequestParserWaitsForTheWholeBody() throws {
        let body = Data("{\"jsonrpc\":\"2.0\"}".utf8)
        let header = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:54876\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        if case .incomplete = MCPHTTPRequest.parse(header + Data(body.dropLast())) {} else {
            XCTFail("A partial body must not be dispatched")
        }
        guard case let .complete(request) = MCPHTTPRequest.parse(header + body) else {
            return XCTFail("A complete request should parse")
        }
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.body, body)
    }

    private func writeSettings(enabled: Bool) throws {
        let value: [String: Any] = [
            "mcpEnabled": enabled,
            "mcpHistoryAccess": true,
            "mcpStatisticsAccess": true,
            "mcpMediaAccess": true,
            "mcpVocabularyAccess": true,
            "mcpAllowProposals": true,
        ]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("settings.json"), options: .atomic)
    }

    private func request(method: String, parameters: [String: Any]? = nil) throws -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
        if let parameters { message["params"] = parameters }
        let response = try XCTUnwrap(service.handle(JSONSerialization.data(withJSONObject: message)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }

    private func call(_ name: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        let response = try request(method: "tools/call", parameters: ["name": name, "arguments": arguments])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        return try toolPayload(from: result)
    }

    private func toolPayload(from result: [String: Any]) throws -> [String: Any] {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

struct LocalMCPHTTPRegressionTests {
    private let fixture: LocalMCPHTTPFixture

    init() throws {
        fixture = try LocalMCPHTTPFixture()
    }

    @Test("Unsupported MCP methods return 405 and advertise POST", arguments: ["GET", "DELETE", "PUT"])
    func unsupportedMCPMethodsReturn405AndAdvertisePOST(method: String) throws {
        // Regression: GET /mcp reported 404 when no notification stream was available.
        // https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#listening-for-messages-from-the-server
        let request = try fixture.request(method: method, headers: ["accept": "text/event-stream"])

        let response = LocalMCPHTTP.route(request, service: fixture.service, port: fixture.port, token: fixture.token)

        #expect(response.status == 405)
        let header = String(decoding: response.encoded, as: UTF8.self).components(separatedBy: "\r\n\r\n")[0]
        let lines = header.components(separatedBy: "\r\n")
        #expect(lines.first == "HTTP/1.1 405 Method Not Allowed")
        let allow = lines.first { $0.lowercased().hasPrefix("allow:") }
        #expect(allow?.dropFirst("Allow:".count).trimmingCharacters(in: .whitespaces) == "POST")
    }

    @Test("Explicit invalid or unsupported protocol versions return 400", arguments: ["", "not-a-version", "2099-01-01"])
    func invalidProtocolVersionsAreRejected(version: String) throws {
        // Regression: the transport ignored explicit version headers and dispatched these requests.
        // https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#protocol-version-header
        let request = try fixture.request(headers: ["mcp-protocol-version": version])

        let response = LocalMCPHTTP.route(request, service: fixture.service, port: fixture.port, token: fixture.token)

        #expect(response.status == 400, "An explicit invalid header must not behave like an omitted header")
    }

    @Test("An invalid protocol version cannot create a vocabulary proposal")
    func invalidProtocolVersionCannotCreateVocabularyProposal() throws {
        // Regression: rejecting a version after service dispatch would still persist a proposal.
        let folder = fixture.root.appendingPathComponent("Agent Proposals", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let request = try fixture.request(
            headers: ["mcp-protocol-version": "not-a-version"],
            rpcMethod: "tools/call",
            parameters: [
                "name": "propose_vocabulary_change",
                "arguments": [
                    "action": "add", "word": "Martino", "reason": "Repeated correction",
                    "idempotency_key": "invalid-protocol-proposal",
                ],
            ]
        )

        let response = LocalMCPHTTP.route(request, service: fixture.service, port: fixture.port, token: fixture.token)

        #expect(response.status == 400)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.filter { $0.pathExtension == "json" }.count == 0, "Protocol rejection must happen before proposal persistence")
    }

    @Test("Supported and omitted protocol versions preserve successful RPC dispatch", arguments: [
        nil, "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
    ] as [String?])
    func supportedOrOmittedProtocolVersionsAreAccepted(version: String?) throws {
        var headers: [String: String] = [:]
        headers["mcp-protocol-version"] = version
        let request = try fixture.request(headers: headers)

        let response = LocalMCPHTTP.route(request, service: fixture.service, port: fixture.port, token: fixture.token)

        #expect(response.status == 200)
        let message = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(message["id"] as? Int == 1)
        let result = try #require(message["result"] as? [String: Any])
        #expect(result.count == 0)
    }

    @Test("Headerless initialization negotiates compatibility and fallback versions", arguments: [
        ("2025-03-26", "2025-03-26"),
        ("2099-01-01", "2025-11-25"),
    ])
    func initializationWithoutVersionHeaderNegotiatesSupportedVersion(requested: String, expected: String) throws {
        // Regression: the HTTP compatibility version must also be accepted during initialization.
        let request = try fixture.request(rpcMethod: "initialize", parameters: ["protocolVersion": requested])

        let response = LocalMCPHTTP.route(request, service: fixture.service, port: fixture.port, token: fixture.token)

        #expect(response.status == 200)
        let message = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let result = try #require(message["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == expected)
    }

    @Test("Health remains available independently of the MCP version header")
    func healthRemainsAvailableWithUnrecognizedProtocolVersion() throws {
        let request = try fixture.request(method: "GET", path: "/health", headers: ["mcp-protocol-version": "not-a-version"])

        let response = LocalMCPHTTP.route(request, service: fixture.service, port: fixture.port, token: fixture.token)

        #expect(response.status == 200)
        let payload = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: String])
        #expect(payload == ["status": "ok", "transport": "local-http"])
    }

    @Test("Unknown paths remain 404 independently of the MCP version header")
    func unknownPathRemainsNotFoundWithUnrecognizedProtocolVersion() throws {
        let request = try fixture.request(path: "/missing", headers: ["mcp-protocol-version": "not-a-version"])

        let response = LocalMCPHTTP.route(request, service: fixture.service, port: fixture.port, token: fixture.token)

        #expect(response.status == 404)
    }

    @Test("Missing or untrusted hosts are rejected before route selection", arguments: [
        ("POST", "/mcp", nil as String?),
        ("POST", "/mcp", "attacker.example"),
        ("GET", "/mcp", "attacker.example"),
        ("GET", "/health", "attacker.example"),
        ("GET", "/missing", "attacker.example"),
    ])
    func hostValidationPrecedesRouting(method: String, path: String, host: String?) throws {
        let request = try fixture.request(method: method, path: path, host: host, headers: ["mcp-protocol-version": "not-a-version"])

        let response = LocalMCPHTTP.route(request, service: fixture.service, port: fixture.port, token: fixture.token)

        #expect(response.status == 403)
    }

    @Test("Browser origins are rejected before route selection", arguments: [
        ("POST", "/mcp"), ("GET", "/mcp"), ("GET", "/health"), ("GET", "/missing"),
    ])
    func originValidationPrecedesRouting(method: String, path: String) throws {
        let request = try fixture.request(method: method, path: path, headers: [
            "origin": "https://attacker.example", "mcp-protocol-version": "not-a-version",
        ])

        let response = LocalMCPHTTP.route(request, service: fixture.service, port: fixture.port, token: fixture.token)

        #expect(response.status == 403)
    }

    @Test("A supported protocol version does not bypass the JSON content-type requirement")
    func supportedProtocolVersionStillRequiresJSONContentType() throws {
        let request = try fixture.request(headers: [
            "content-type": "text/plain", "mcp-protocol-version": "2025-11-25",
        ])

        let response = LocalMCPHTTP.route(request, service: fixture.service, port: fixture.port, token: fixture.token)

        #expect(response.status == 415)
    }
}

private final class LocalMCPHTTPFixture {
    // Requests are routed directly; this documented port is never opened by the tests.
    let port: UInt16 = 54_876
    let token = String(repeating: "cd", count: 32)
    let root: URL
    let service: LocalMCPService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictari-mcp-http-regression-" + UUID().uuidString, isDirectory: true)
        service = LocalMCPService(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings: [String: Bool] = [
            "mcpEnabled": true,
            "mcpHistoryAccess": true,
            "mcpStatisticsAccess": true,
            "mcpMediaAccess": true,
            "mcpVocabularyAccess": true,
            "mcpAllowProposals": true,
        ]
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func request(
        method: String = "POST",
        path: String = "/mcp",
        host: String? = "127.0.0.1:54876",
        headers: [String: String] = [:],
        rpcMethod: String = "ping",
        parameters: [String: Any]? = nil
    ) throws -> MCPHTTPRequest {
        var requestHeaders = ["content-type": "application/json", "authorization": "Bearer \(token)"]
        requestHeaders["host"] = host
        requestHeaders.merge(headers) { _, supplied in supplied }
        var message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": rpcMethod]
        if let parameters { message["params"] = parameters }
        return MCPHTTPRequest(
            method: method,
            path: path,
            headers: requestHeaders,
            body: method == "POST" ? try JSONSerialization.data(withJSONObject: message) : Data()
        )
    }
}

import XCTest

/// The loopback MCP listener is the only socket Dictari opens after the model download, so both
/// when it exists and who it answers are pinned here without ever binding the port.
final class LocalMCPAuthPolicyTests: XCTestCase {
    private let token = String(repeating: "0f", count: 32)

    // MARK: Start/stop policy

    func testDefaultSettingsNeverListen() {
        XCTAssertFalse(LocalMCPServer.shouldListen(SettingsData()))
    }

    func testMasterSwitchAloneDoesNotListen() {
        var settings = SettingsData()
        settings.mcpEnabled = true
        XCTAssertFalse(LocalMCPServer.shouldListen(settings), "No scope granted: every tool would refuse")
    }

    func testScopesWithoutMasterSwitchDoNotListen() {
        var settings = SettingsData()
        settings.mcpEnabled = false
        settings.mcpHistoryAccess = true
        settings.mcpAllowProposals = true
        XCTAssertFalse(LocalMCPServer.shouldListen(settings))
    }

    func testMasterPlusAnySingleScopeListens() {
        let scopes: [WritableKeyPath<SettingsData, Bool?>] = [
            \.mcpHistoryAccess, \.mcpStatisticsAccess, \.mcpMediaAccess,
            \.mcpVocabularyAccess, \.mcpAllowProposals,
        ]
        for scope in scopes {
            var settings = SettingsData()
            settings.mcpEnabled = true
            settings[keyPath: scope] = true
            XCTAssertTrue(LocalMCPServer.shouldListen(settings), "\(scope)")
            settings[keyPath: scope] = false
            XCTAssertFalse(LocalMCPServer.shouldListen(settings), "turning the last scope off stops it: \(scope)")
        }
    }

    // MARK: Bearer check

    func testAcceptsExactBearerToken() {
        XCTAssertTrue(LocalMCPToken.authorizes("Bearer \(token)", token: token))
        XCTAssertTrue(LocalMCPToken.authorizes("bearer \(token)", token: token), "Scheme is case-insensitive")
    }

    func testRejectsMissingMalformedOrWrongCredentials() {
        let wrongLastByte = String(token.dropLast()) + "e"
        for header in [
            nil, "", "Bearer", "Bearer ", token, "Basic \(token)", "Bearer \(wrongLastByte)",
            "Bearer \(token)x", "Bearer \(token.dropLast())", "Bearer \(token.uppercased())",
        ] as [String?] {
            XCTAssertFalse(LocalMCPToken.authorizes(header, token: token), String(describing: header))
        }
    }

    func testEmptyServerTokenRejectsEverything() {
        // A listener started before a token exists must fail closed, not match an empty bearer.
        XCTAssertFalse(LocalMCPToken.authorizes("Bearer ", token: ""))
        XCTAssertFalse(LocalMCPToken.authorizes("Bearer x", token: ""))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(LocalMCPToken.constantTimeEquals([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(LocalMCPToken.constantTimeEquals([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(LocalMCPToken.constantTimeEquals([9, 2, 3], [1, 2, 3]))
        XCTAssertFalse(LocalMCPToken.constantTimeEquals([1, 2], [1, 2, 3]))
        XCTAssertTrue(LocalMCPToken.constantTimeEquals([], []))
    }

    func testRouteRequiresTokenOnEveryPathAfterHostCheck() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictari-mcp-auth-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LocalMCPService(root: root)
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "ping"])
        func route(_ method: String, _ path: String, host: String = "127.0.0.1:54876",
                   authorization: String?) -> MCPHTTPResponse {
            var headers = ["host": host, "content-type": "application/json"]
            headers["authorization"] = authorization
            return LocalMCPHTTP.route(
                MCPHTTPRequest(method: method, path: path, headers: headers, body: method == "POST" ? body : Data()),
                service: service, port: 54_876, token: token
            )
        }

        for (method, path) in [("POST", "/mcp"), ("GET", "/health"), ("GET", "/missing")] {
            let denied = route(method, path, authorization: nil)
            XCTAssertEqual(denied.status, 401, "\(method) \(path)")
            XCTAssertTrue(String(decoding: denied.encoded, as: UTF8.self).contains("WWW-Authenticate: Bearer"))
            XCTAssertEqual(route(method, path, authorization: "Bearer wrong").status, 401)
        }
        XCTAssertEqual(route("POST", "/mcp", authorization: "Bearer \(token)").status, 200)
        XCTAssertEqual(route("GET", "/health", authorization: "Bearer \(token)").status, 200)
        // A foreign Host is still refused as such, token or not (DNS-rebinding defence first).
        XCTAssertEqual(route("POST", "/mcp", host: "attacker.example", authorization: "Bearer \(token)").status, 403)
    }

    // MARK: Token storage

    func testTokenIsCreatedOncePrivateAndStable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictari-mcp-token-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try LocalMCPToken.loadOrCreate(in: root)
        XCTAssertTrue(LocalMCPToken.isWellFormed(first))
        XCTAssertEqual(first.count, 64, "32 random bytes, hex encoded")
        let url = root.appendingPathComponent(LocalMCPToken.fileName)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try LocalMCPToken.loadOrCreate(in: root), first, "Per-install: reused, not rotated")

        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        XCTAssertNotEqual(try LocalMCPToken.loadOrCreate(in: otherRoot), first)
    }

    func testCorruptTokenFileIsReplaced() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictari-mcp-token-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("short".utf8).write(to: root.appendingPathComponent(LocalMCPToken.fileName))

        let token = try LocalMCPToken.loadOrCreate(in: root)
        XCTAssertTrue(LocalMCPToken.isWellFormed(token))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(LocalMCPToken.fileName).path
        )[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
}

#!/usr/bin/xcrun swift

import CryptoKit
import Foundation

private struct Resolution: Codable {
    var originHash: String
    var pins: [Pin]
    var version: Int
}

private struct Pin: Codable {
    var identity: String
    var kind: String
    var location: String
    var state: PinState
}

private struct PinState: Codable {
    var revision: String
    var version: String
}

private struct DirectPackage {
    var name: String
    var url: String?
    var exactVersion: String?
    var unsupportedRequirement: String?

    var identity: String {
        guard let url else { return name.lowercased() }
        return url
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)?
            .replacingOccurrences(of: ".git", with: "", options: [.anchored, .backwards])
            .lowercased() ?? name.lowercased()
    }
}

private enum Command: String {
    case install
    case verify
    case freeze
}

private enum FreezeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}

private let fileManager = FileManager.default
private let root = URL(fileURLWithPath: #filePath)
    .standardizedFileURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let projectManifest = root.appendingPathComponent("project.yml")
private let canonicalLock = root.appendingPathComponent("Dependencies/Package.resolved")
private let canonicalSBOM = root.appendingPathComponent("Dependencies/swiftpm-sbom.cdx.json")
private let generatedLock = root.appendingPathComponent(
    "Dictari.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("swiftpm-freeze: error: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

private func read(_ url: URL) throws -> Data {
    guard fileManager.fileExists(atPath: url.path) else {
        throw FreezeError.message("missing \(url.path.replacingOccurrences(of: root.path + "/", with: ""))")
    }
    return try Data(contentsOf: url)
}

private func decodeResolution(_ data: Data, source: URL) throws -> Resolution {
    do {
        return try JSONDecoder().decode(Resolution.self, from: data)
    } catch {
        throw FreezeError.message("invalid Package.resolved at \(source.path): \(error)")
    }
}

private func canonicalResolutionData(_ resolution: Resolution) throws -> Data {
    var canonical = resolution
    canonical.pins.sort { $0.identity < $1.identity }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(canonical)
    data.append(0x0A)
    return data
}

private func normalizedLocation(_ value: String) -> String {
    var result = value
    while result.hasSuffix("/") { result.removeLast() }
    if result.hasSuffix(".git") { result.removeLast(4) }
    return result.lowercased()
}

private func directPackages() throws -> [DirectPackage] {
    let contents = try String(contentsOf: projectManifest, encoding: .utf8)
    var inPackages = false
    var current: DirectPackage?
    var result: [DirectPackage] = []

    func finishCurrent() {
        if let current { result.append(current) }
        current = nil
    }

    for line in contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if line == "packages:" {
            inPackages = true
            continue
        }
        guard inPackages else { continue }
        if !line.isEmpty, !line.hasPrefix(" ") {
            finishCurrent()
            break
        }
        if line.hasPrefix("  "), !line.hasPrefix("    "), line.hasSuffix(":") {
            finishCurrent()
            current = DirectPackage(name: String(line.dropFirst(2).dropLast()))
            continue
        }
        guard line.hasPrefix("    "), var package = current else { continue }
        let field = String(line.dropFirst(4))
        if field.hasPrefix("url: ") {
            package.url = String(field.dropFirst("url: ".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        } else if field.hasPrefix("exactVersion: ") {
            package.exactVersion = String(field.dropFirst("exactVersion: ".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        } else if ["from:", "minVersion:", "minorVersion:", "majorVersion:", "maxVersion:", "branch:", "revision:"].contains(where: field.hasPrefix) {
            package.unsupportedRequirement = field
        }
        current = package
    }

    guard !result.isEmpty else {
        throw FreezeError.message("project.yml has no top-level Swift packages")
    }
    return result
}

private func validate(_ resolution: Resolution, direct: [DirectPackage]) throws {
    guard resolution.version == 3 else {
        throw FreezeError.message("unsupported Package.resolved format \(resolution.version); review the tool before freezing")
    }
    guard resolution.originHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
        throw FreezeError.message("Package.resolved originHash is missing or not a lowercase SHA-256 value")
    }
    guard !resolution.pins.isEmpty else {
        throw FreezeError.message("Package.resolved contains no pins")
    }

    let identities = resolution.pins.map(\.identity)
    guard identities == identities.sorted() else {
        throw FreezeError.message("Package.resolved pins are not sorted by identity; run the explicit freeze command")
    }
    guard Set(identities).count == identities.count else {
        throw FreezeError.message("Package.resolved contains duplicate package identities")
    }

    for pin in resolution.pins {
        guard pin.kind == "remoteSourceControl" else {
            throw FreezeError.message("\(pin.identity) is not an immutable remote source-control pin")
        }
        guard pin.location.hasPrefix("https://") else {
            throw FreezeError.message("\(pin.identity) does not use an HTTPS source location")
        }
        guard pin.state.revision.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else {
            throw FreezeError.message("\(pin.identity) has no immutable lowercase Git revision")
        }
        guard !pin.state.version.isEmpty else {
            throw FreezeError.message("\(pin.identity) is not pinned to a version")
        }
    }

    let pinsByIdentity = Dictionary(uniqueKeysWithValues: resolution.pins.map { ($0.identity, $0) })
    for package in direct {
        if let unsupportedRequirement = package.unsupportedRequirement {
            throw FreezeError.message("\(package.name) uses '\(unsupportedRequirement)'; release dependencies must use exactVersion")
        }
        guard let url = package.url, let exactVersion = package.exactVersion else {
            throw FreezeError.message("\(package.name) must declare both url and exactVersion in project.yml")
        }
        guard let pin = pinsByIdentity[package.identity] else {
            throw FreezeError.message("direct package \(package.name) is absent from Package.resolved")
        }
        guard pin.state.version == exactVersion else {
            throw FreezeError.message("\(package.name) exactVersion \(exactVersion) differs from resolved \(pin.state.version)")
        }
        guard normalizedLocation(pin.location) == normalizedLocation(url) else {
            throw FreezeError.message("\(package.name) URL differs between project.yml and Package.resolved")
        }
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sbomData(for resolution: Resolution, lockData: Data, direct: [DirectPackage]) throws -> Data {
    let directIdentities = Set(direct.map(\.identity))
    let components: [[String: Any]] = resolution.pins.map { pin in
        let scope = directIdentities.contains(pin.identity) ? "direct" : "transitive"
        return [
            "bom-ref": "swiftpm:\(pin.identity)@\(pin.state.version)#\(pin.state.revision)",
            "externalReferences": [[
                "type": "vcs",
                "url": "\(pin.location)#\(pin.state.revision)"
            ]],
            "name": pin.identity,
            "properties": [
                ["name": "dictari:dependency-scope", "value": scope],
                ["name": "dictari:git-revision", "value": pin.state.revision],
                ["name": "dictari:source-location", "value": pin.location]
            ],
            "type": "library",
            "version": pin.state.version
        ]
    }
    let rootRef = "application:com.subralabs.Dictari"
    let document: [String: Any] = [
        "bomFormat": "CycloneDX",
        "components": components,
        "dependencies": [[
            "ref": rootRef,
            "dependsOn": resolution.pins.filter { directIdentities.contains($0.identity) }.map {
                "swiftpm:\($0.identity)@\($0.state.version)#\($0.state.revision)"
            }
        ]],
        "metadata": [
            "component": [
                "bom-ref": rootRef,
                "name": "Dictari",
                "type": "application"
            ],
            "properties": [
                ["name": "dictari:swiftpm-lock-sha256", "value": sha256(lockData)],
                ["name": "dictari:swiftpm-resolved-format", "value": String(resolution.version)]
            ]
        ],
        "specVersion": "1.6",
        "version": 1
    ]
    var data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    return data
}

private func writeAtomically(_ data: Data, to url: URL) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

private func verifiedCanonicalInputs(requireGeneratedLock: Bool) throws -> (Resolution, Data, [DirectPackage]) {
    let lockData = try read(canonicalLock)
    let resolution = try decodeResolution(lockData, source: canonicalLock)
    let direct = try directPackages()
    try validate(resolution, direct: direct)

    let normalized = try canonicalResolutionData(resolution)
    guard normalized == lockData else {
        throw FreezeError.message("Dependencies/Package.resolved is not canonical; run the explicit freeze command")
    }
    let expectedSBOM = try sbomData(for: resolution, lockData: lockData, direct: direct)
    guard try read(canonicalSBOM) == expectedSBOM else {
        throw FreezeError.message("Dependencies/swiftpm-sbom.cdx.json drifted from Package.resolved")
    }
    if requireGeneratedLock {
        guard try read(generatedLock) == lockData else {
            throw FreezeError.message("generated Package.resolved drifted; do not freeze until the dependency change is reviewed")
        }
    }
    return (resolution, lockData, direct)
}

do {
    guard CommandLine.arguments.count == 2, let command = Command(rawValue: CommandLine.arguments[1]) else {
        fail("usage: scripts/swiftpm-freeze.swift install|verify|freeze")
    }

    switch command {
    case .install:
        let (_, lockData, _) = try verifiedCanonicalInputs(requireGeneratedLock: false)
        try writeAtomically(lockData, to: generatedLock)
        print("Installed tracked SwiftPM resolution into generated Xcode project.")

    case .verify:
        let (resolution, lockData, direct) = try verifiedCanonicalInputs(requireGeneratedLock: true)
        let directCount = direct.count
        print("Verified SwiftPM freeze: \(resolution.pins.count) packages (\(directCount) direct, \(resolution.pins.count - directCount) transitive), lock SHA-256 \(sha256(lockData)).")

    case .freeze:
        let generatedData = try read(generatedLock)
        var resolution = try decodeResolution(generatedData, source: generatedLock)
        resolution.pins.sort { $0.identity < $1.identity }
        let direct = try directPackages()
        try validate(resolution, direct: direct)
        let lockData = try canonicalResolutionData(resolution)
        let sbom = try sbomData(for: resolution, lockData: lockData, direct: direct)
        try writeAtomically(lockData, to: canonicalLock)
        try writeAtomically(lockData, to: generatedLock)
        try writeAtomically(sbom, to: canonicalSBOM)
        print("Froze \(resolution.pins.count) SwiftPM packages; review and commit both dependency artifacts.")
    }
} catch {
    fail(error.localizedDescription)
}

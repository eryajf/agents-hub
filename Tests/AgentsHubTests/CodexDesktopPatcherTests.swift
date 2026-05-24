import CryptoKit
import Foundation
import Testing
@testable import AgentsHub

@Suite("Codex Desktop patcher")
struct CodexDesktopPatcherTests {
    @Test("Asar replacement updates integrity metadata")
    func asarReplacementUpdatesIntegrity() throws {
        let fixture = try CodexDesktopFixture(
            files: [
                "webview/assets/feature.js": "const enabled = authMethod === \"chatgpt\";\n"
            ]
        )

        let archive = ElectronAsarArchive(url: fixture.asarURL)
        let originalHeaderHash = try archive.headerSHA256Hex()
        try archive.apply([
            AsarReplacement(
                path: "webview/assets/feature.js",
                search: "authMethod === \"chatgpt\"",
                replacement: "/* Agents Hub patched */"
            )
        ])

        let patched = ElectronAsarArchive(url: fixture.asarURL)
        let content = try patched.string(at: "webview/assets/feature.js")
        #expect(content.contains("/* Agents Hub patched */"))
        #expect(!content.contains("authMethod === \"chatgpt\""))
        #expect(try patched.integrityHash(at: "webview/assets/feature.js") == sha256Hex(Data(content.utf8)))
        #expect(try patched.headerSHA256Hex() != originalHeaderHash)
    }

    @Test("Patcher detects supported Codex Desktop installation")
    func detectInstallation() throws {
        let fixture = try CodexDesktopFixture(
            shortVersion: "26.519.41501",
            files: [
                "webview/assets/use-is-fast-mode-enabled-CwUgvZ2O.js": "d?.authMethod!==`chatgpt`||g",
                "webview/assets/skills-page-C8PW4EqX.js": "s&&!m)"
            ]
        )
        let patcher = CodexDesktopPatcher(
            appSearchURLs: [fixture.appURL],
            backupDirectory: fixture.backupURL,
            codeSigner: NoOpCodexDesktopCodeSigner()
        )

        let status = try patcher.status()

        #expect(status.installation?.appURL == fixture.appURL)
        #expect(status.installation?.shortVersion == "26.519.41501")
        #expect(status.installation?.asarSHA256 == sha256Hex(Data(contentsOf: fixture.asarURL)))
        #expect(status.availableCapabilities.contains(.fastMode))
        #expect(status.availableCapabilities.contains(.plugins))
        #expect(status.patchState == .unpatched)
    }

    @Test("Patcher refuses unsupported manifests without modifying app files")
    func refusesUnsupportedManifestWithoutModifyingAppFiles() throws {
        let fixture = try CodexDesktopFixture(
            shortVersion: "1.0.0",
            files: [
                "webview/assets/feature.js": "no supported patterns here"
            ]
        )
        let originalAsar = try Data(contentsOf: fixture.asarURL)
        let patcher = CodexDesktopPatcher(
            appSearchURLs: [fixture.appURL],
            backupDirectory: fixture.backupURL,
            manifests: [],
            codeSigner: NoOpCodexDesktopCodeSigner()
        )

        #expect(throws: CodexDesktopPatchError.self) {
            try patcher.apply(options: CodexDesktopPatchOptions(enableFastMode: true, enablePlugins: true))
        }
        #expect(try Data(contentsOf: fixture.asarURL) == originalAsar)
    }

    @Test("Patcher backs up, applies selected options, and restores originals")
    func applyAndRestore() throws {
        let fastOriginal = "d?.authMethod!==`chatgpt`||g"
        let fastPatched = "false                    ||g"
        #expect(fastOriginal.utf8.count == fastPatched.utf8.count)

        let pluginOriginal = "s&&!m)"
        let pluginPatched = "s&&!1)"
        #expect(pluginOriginal.utf8.count == pluginPatched.utf8.count)

        let fixture = try CodexDesktopFixture(
            shortVersion: "26.519.41501",
            files: [
                "webview/assets/use-is-fast-mode-enabled-CwUgvZ2O.js": "if(\(fastOriginal)){return disabled}",
                "webview/assets/skills-page-C8PW4EqX.js": "if(\(pluginOriginal)){return blocked}"
            ]
        )
        let originalAsar = try Data(contentsOf: fixture.asarURL)
        let originalPlist = try Data(contentsOf: fixture.infoPlistURL)
        let originalHash = sha256Hex(originalAsar)
        let manifest = CodexDesktopPatchManifest(
            shortVersion: "26.519.41501",
            originalAsarSHA256: originalHash,
            replacements: [
                .init(
                    option: .fastMode,
                    path: "webview/assets/use-is-fast-mode-enabled-CwUgvZ2O.js",
                    search: fastOriginal,
                    replacement: fastPatched
                ),
                .init(
                    option: .plugins,
                    path: "webview/assets/skills-page-C8PW4EqX.js",
                    search: pluginOriginal,
                    replacement: pluginPatched
                )
            ]
        )
        let patcher = CodexDesktopPatcher(
            appSearchURLs: [fixture.appURL],
            backupDirectory: fixture.backupURL,
            manifests: [manifest],
            codeSigner: NoOpCodexDesktopCodeSigner()
        )

        try patcher.apply(options: CodexDesktopPatchOptions(enableFastMode: true, enablePlugins: true))

        let patchedAsar = try Data(contentsOf: fixture.asarURL)
        #expect(patchedAsar != originalAsar)
        #expect(try ElectronAsarArchive(url: fixture.asarURL)
            .string(at: "webview/assets/use-is-fast-mode-enabled-CwUgvZ2O.js")
            .contains(fastPatched))
        #expect(try plistAsarHash(fixture.infoPlistURL) == ElectronAsarArchive(url: fixture.asarURL).headerSHA256Hex())
        #expect(try patcher.status().patchState == .patched([.fastMode, .plugins]))

        try patcher.restore()

        #expect(try Data(contentsOf: fixture.asarURL) == originalAsar)
        #expect(try Data(contentsOf: fixture.infoPlistURL) == originalPlist)
        #expect(try patcher.status().patchState == .unpatched)
    }

    @Test("Patcher can apply another option after one option is already patched")
    func applyAdditionalOptionAfterPartialPatch() throws {
        let fastOriginal = "d?.authMethod!==`chatgpt`||g"
        let fastPatched = "false                    ||g"
        let pluginOriginal = "s&&!m)"
        let pluginPatched = "s&&!1)"
        let fixture = try CodexDesktopFixture(
            shortVersion: "26.519.41501",
            files: [
                "webview/assets/use-is-fast-mode-enabled-CwUgvZ2O.js": "if(\(fastOriginal)){return disabled}",
                "webview/assets/skills-page-C8PW4EqX.js": "if(\(pluginOriginal)){return blocked}"
            ]
        )
        let originalHash = sha256Hex(Data(contentsOf: fixture.asarURL))
        let manifest = CodexDesktopPatchManifest(
            shortVersion: "26.519.41501",
            originalAsarSHA256: originalHash,
            replacements: [
                .init(
                    option: .fastMode,
                    path: "webview/assets/use-is-fast-mode-enabled-CwUgvZ2O.js",
                    search: fastOriginal,
                    replacement: fastPatched
                ),
                .init(
                    option: .plugins,
                    path: "webview/assets/skills-page-C8PW4EqX.js",
                    search: pluginOriginal,
                    replacement: pluginPatched
                )
            ]
        )
        let patcher = CodexDesktopPatcher(
            appSearchURLs: [fixture.appURL],
            backupDirectory: fixture.backupURL,
            manifests: [manifest],
            codeSigner: NoOpCodexDesktopCodeSigner()
        )

        try patcher.apply(options: [.fastMode])
        #expect(try patcher.status().patchState == .patched(.fastMode))

        try patcher.apply(options: [.fastMode, .plugins])

        #expect(try patcher.status().patchState == .patched([.fastMode, .plugins]))
        #expect(try ElectronAsarArchive(url: fixture.asarURL)
            .string(at: "webview/assets/skills-page-C8PW4EqX.js")
            .contains(pluginPatched))
    }

    @Test("Patcher reports damaged install and restores when app.asar is missing")
    func restoreWhenAsarIsMissing() throws {
        let fixture = try CodexDesktopFixture(
            shortVersion: "26.519.41501",
            files: [
                "webview/assets/use-is-fast-mode-enabled-CwUgvZ2O.js": "d?.authMethod!==`chatgpt`||g",
                "webview/assets/skills-page-C8PW4EqX.js": "s&&!m)"
            ]
        )
        let originalAsar = try Data(contentsOf: fixture.asarURL)
        let originalPlist = try Data(contentsOf: fixture.infoPlistURL)
        let patcher = CodexDesktopPatcher(
            appSearchURLs: [fixture.appURL],
            backupDirectory: fixture.backupURL,
            codeSigner: NoOpCodexDesktopCodeSigner()
        )

        try patcher.apply(options: [.fastMode])
        try FileManager.default.removeItem(at: fixture.asarURL)

        let damagedStatus = try patcher.status()
        #expect(damagedStatus.patchState == .damaged("Codex Desktop app.asar is missing."))
        #expect(damagedStatus.backupURL != nil)

        try patcher.restore()

        #expect(try Data(contentsOf: fixture.asarURL) == originalAsar)
        #expect(try Data(contentsOf: fixture.infoPlistURL) == originalPlist)
        #expect(try patcher.status().patchState == .unpatched)
    }
}

private struct NoOpCodexDesktopCodeSigner: CodexDesktopCodeSigner {
    func sign(appURL: URL) throws {}
}

private struct CodexDesktopFixture {
    let rootURL: URL
    let appURL: URL
    let asarURL: URL
    let infoPlistURL: URL
    let backupURL: URL

    init(shortVersion: String = "26.519.41501", files: [String: String]) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentsHubCodexPatchTests-\(UUID().uuidString)", isDirectory: true)
        appURL = rootURL.appendingPathComponent("Codex.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        asarURL = resourcesURL.appendingPathComponent("app.asar")
        infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        backupURL = rootURL.appendingPathComponent("Backups", isDirectory: true)

        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try makeAsar(files: files).write(to: asarURL)
        try writeInfoPlist(shortVersion: shortVersion, asarHash: sha256Hex(Data(contentsOf: asarURL)))
    }

    private func writeInfoPlist(shortVersion: String, asarHash: String) throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.openai.codex",
            "CFBundleShortVersionString": shortVersion,
            "CFBundleVersion": "1",
            "ElectronAsarIntegrity": [
                "Resources/app.asar": [
                    "algorithm": "SHA256",
                    "hash": asarHash
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: infoPlistURL)
    }
}

private func makeAsar(files: [String: String]) throws -> Data {
    var offset = 0
    var fileData = Data()
    var root: [String: Any] = ["files": [String: Any]()]

    for path in files.keys.sorted() {
        let data = Data(files[path]!.utf8)
        insertAsarEntry(
            pathComponents: path.split(separator: "/").map(String.init),
            entry: [
                "size": data.count,
                "offset": String(offset),
                "integrity": [
                    "algorithm": "SHA256",
                    "hash": sha256Hex(data),
                    "blockSize": 4_194_304,
                    "blocks": [sha256Hex(data)]
                ]
            ],
            into: &root
        )
        fileData.append(data)
        offset += data.count
    }

    let jsonData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    var headerSize = jsonData.count + 8
    while (8 + headerSize) % 4 != 0 {
        headerSize += 1
    }

    var result = Data()
    result.appendUInt32LE(4)
    result.appendUInt32LE(UInt32(headerSize))
    result.appendUInt32LE(UInt32(jsonData.count + 4))
    result.appendUInt32LE(UInt32(jsonData.count))
    result.append(jsonData)
    result.append(Data(repeating: 0, count: headerSize - jsonData.count - 8))
    result.append(fileData)
    return result
}

private func insertAsarEntry(pathComponents: [String], entry: [String: Any], into node: inout [String: Any]) {
    guard let first = pathComponents.first else { return }
    var files = node["files"] as? [String: Any] ?? [:]

    if pathComponents.count == 1 {
        files[first] = entry
    } else {
        var child = files[first] as? [String: Any] ?? ["files": [String: Any]()]
        insertAsarEntry(pathComponents: Array(pathComponents.dropFirst()), entry: entry, into: &child)
        files[first] = child
    }

    node["files"] = files
}

private func plistAsarHash(_ url: URL) throws -> String? {
    let data = try Data(contentsOf: url)
    let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    let plist = object as? [String: Any]
    let integrity = plist?["ElectronAsarIntegrity"] as? [String: Any]
    let appAsar = integrity?["Resources/app.asar"] as? [String: Any]
    return appAsar?["hash"] as? String
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}

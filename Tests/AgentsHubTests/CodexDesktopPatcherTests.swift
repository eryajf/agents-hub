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
        #expect(
            try patched.integrityHash(at: "webview/assets/feature.js")
                == sha256Hex(Data(content.utf8)))
        #expect(try patched.headerSHA256Hex() != originalHeaderHash)
    }

    @Test("Patcher detects supported Codex Desktop installation")
    func detectInstallation() throws {
        let fixture = try CodexDesktopFixture(
            shortVersion: "26.519.41501",
            files: [
                "webview/assets/use-is-fast-mode-enabled-CwUgvZ2O.js":
                    "d?.authMethod!==`chatgpt`||g",
                "webview/assets/skills-page-C8PW4EqX.js": "s&&!m)",
                "webview/assets/use-is-appshot-available-D0PV8qeY.js": "return n===`macOS`&&r",
                "webview/assets/app-main-DG-Mf4Wj.js": "appshotsEnabled:r,artifactsPane:!0",
            ]
        )
        let patcher = CodexDesktopPatcher(
            appSearchURLs: [fixture.appURL]
        )

        let status = try patcher.status()

        #expect(status.installation?.appURL == fixture.appURL)
        #expect(status.installation?.shortVersion == "26.519.41501")
        #expect(status.installation?.asarSHA256 == sha256Hex(Data(contentsOf: fixture.asarURL)))
        #expect(status.availableCapabilities.contains(.fastMode))
        #expect(status.availableCapabilities.contains(.plugins))
        #expect(status.availableCapabilities.contains(.appshot))
        #expect(status.patchState == .unpatched)
    }

    @Test("Patcher detects supported Codex Desktop 26.527 installation")
    func detectInstallation527() throws {
        let fixture = try codexDesktop527Fixture()
        let patcher = CodexDesktopPatcher(
            appSearchURLs: [fixture.appURL]
        )

        let status = try patcher.status()

        #expect(status.installation?.shortVersion == "26.527.31326")
        #expect(status.availableCapabilities.contains(.fastMode))
        #expect(status.availableCapabilities.contains(.plugins))
        #expect(status.availableCapabilities.contains(.appshot))
        #expect(status.patchState == .unpatched)
    }

    @Test("Patcher detects supported Codex Desktop 26.527.60818 installation")
    func detectInstallation52760818() throws {
        let fixture = try codexDesktop52760818Fixture()
        let patcher = CodexDesktopPatcher(
            appSearchURLs: [fixture.appURL]
        )

        let status = try patcher.status()

        #expect(status.installation?.shortVersion == "26.527.60818")
        #expect(status.availableCapabilities.contains(.fastMode))
        #expect(status.availableCapabilities.contains(.plugins))
        #expect(status.availableCapabilities.contains(.appshot))
        #expect(status.patchState == .unpatched)
    }

    @Test("Patcher detects already patched plugin markers")
    func detectsAlreadyPatchedPluginMarkers() throws {
        let fixture = try CodexDesktopFixture(
            shortVersion: "26.519.41501",
            files: [
                "webview/assets/app-main-DG-Mf4Wj.js": CodexDesktopPatcher.pluginsSidebarReplacement
                    .replacement,
                "webview/assets/skills-page-C8PW4EqX.js": CodexDesktopPatcher
                    .pluginsPageContentGateReplacement.replacement,
                "webview/assets/plugin-detail-page-jAJa26RM.js": CodexDesktopPatcher
                    .pluginDetailAccessReplacement.replacement,
                "webview/assets/check-plugin-availability-6p9UsIaB.js": CodexDesktopPatcher
                    .pluginInstallAvailabilityReplacement.replacement,
                "webview/assets/use-plugin-install-flow-IT_xMrDV.js": CodexDesktopPatcher
                    .pluginInstallModalContentReplacement.replacement,
            ]
        )
        let patcher = CodexDesktopPatcher(
            appSearchURLs: [fixture.appURL]
        )

        #expect(try patcher.status().patchState == .patched(.plugins))
    }

    @Test("Patcher detects already patched Codex Desktop 26.527 plugin markers")
    func detectsAlreadyPatched527PluginMarkers() throws {
        let fixture = try CodexDesktopFixture(
            shortVersion: "26.527.31326",
            files: [
                "webview/assets/app-main-BxvNtdQT.js":
                    CodexDesktopPatcher.pluginsSidebarReplacement527.replacement,
                "webview/assets/skills-page-Cqn6vECJ.js":
                    CodexDesktopPatcher.pluginsPageContentGateReplacement527.replacement,
                "webview/assets/plugin-detail-page-CETDWYs4.js":
                    CodexDesktopPatcher.pluginDetailAccessReplacement527.replacement
                    + CodexDesktopPatcher.pluginAuthFlowReplacement527.replacement,
                "webview/assets/check-plugin-availability-fTZpqnCL.js":
                    CodexDesktopPatcher.pluginInstallAvailabilityReplacement527.replacement,
                "webview/assets/use-plugin-install-flow-BXFieYft.js":
                    CodexDesktopPatcher.pluginInstallModalContentReplacement527.replacement,
            ]
        )
        let patcher = CodexDesktopPatcher(
            appSearchURLs: [fixture.appURL]
        )

        #expect(try patcher.status().patchState == .patched(.plugins))
    }

    @Test("Patcher detects already patched Appshot marker")
    func detectsAlreadyPatchedAppshotMarker() throws {
        let fixture = try CodexDesktopFixture(
            shortVersion: "26.519.41501",
            files: [
                "webview/assets/use-is-appshot-available-D0PV8qeY.js":
                    CodexDesktopPatcher.appshotAvailabilityReplacement.replacement,
                "webview/assets/app-main-DG-Mf4Wj.js":
                    CodexDesktopPatcher.appshotServiceEnablementReplacement.replacement,
                ".vite/build/main-DVEWN1ng.js":
                    CodexDesktopPatcher.appshotCaptureWorkerReplacement519.replacement,
            ]
        )
        let patcher = CodexDesktopPatcher(
            appSearchURLs: [fixture.appURL]
        )

        #expect(try patcher.status().patchState == .patched(.appshot))
    }

    @Test("Appshot patch updates menu and service enablement gates")
    func appshotPatchUpdatesMenuAndServiceEnablementGates() throws {
        let fixture = try CodexDesktopFixture(
            shortVersion: "26.519.41501",
            files: [
                "webview/assets/use-is-appshot-available-D0PV8qeY.js":
                    CodexDesktopPatcher.appshotAvailabilityReplacement.search,
                "webview/assets/app-main-DG-Mf4Wj.js":
                    CodexDesktopPatcher.appshotServiceEnablementReplacement.search,
                ".vite/build/main-DVEWN1ng.js":
                    CodexDesktopPatcher.appshotCaptureWorkerReplacement519.search,
            ]
        )
        let archive = ElectronAsarArchive(url: fixture.asarURL)

        try archive.apply(
            CodexDesktopPatcher.builtInManifests[0].replacements(for: .appshot)
        )

        #expect(
            try archive.string(at: CodexDesktopPatcher.appshotAvailabilityReplacement.path)
                .contains(CodexDesktopPatcher.appshotAvailabilityReplacement.replacement)
        )
        #expect(
            try archive.string(at: CodexDesktopPatcher.appshotServiceEnablementReplacement.path)
                .contains(CodexDesktopPatcher.appshotServiceEnablementReplacement.replacement)
        )
        #expect(
            try archive.string(at: CodexDesktopPatcher.appshotCaptureWorkerReplacement519.path)
                .contains(CodexDesktopPatcher.appshotCaptureWorkerReplacement519.replacement)
        )
    }

    @Test("Codex Desktop 26.527 manifest applies selected patches")
    func applies527ManifestPatches() throws {
        let fixture = try codexDesktop527Fixture()
        let archive = ElectronAsarArchive(url: fixture.asarURL)
        let manifest = try #require(
            CodexDesktopPatcher.builtInManifests.first { $0.shortVersion == "26.527.31326" }
        )

        try archive.apply(manifest.replacements(for: [.fastMode, .plugins, .appshot]))

        for replacement in manifest.replacements {
            #expect(
                try archive.string(at: replacement.path).contains(replacement.replacement)
            )
        }
    }

    @Test("Codex Desktop 26.527.60818 manifest applies selected patches")
    func applies52760818ManifestPatches() throws {
        let fixture = try codexDesktop52760818Fixture()
        let archive = ElectronAsarArchive(url: fixture.asarURL)
        let manifest = try #require(
            CodexDesktopPatcher.builtInManifests.first { $0.shortVersion == "26.527.60818" }
        )

        try archive.apply(manifest.replacements(for: [.fastMode, .plugins, .appshot]))

        for replacement in manifest.replacements {
            #expect(
                try archive.string(at: replacement.path).contains(replacement.replacement)
            )
        }
    }
}

private func codexDesktop527Fixture() throws -> CodexDesktopFixture {
    try CodexDesktopFixture(
        shortVersion: "26.527.31326",
        files: [
            "webview/assets/use-is-fast-mode-enabled-BCZ3vDoA.js":
                CodexDesktopPatcher.fastModeReplacement527.search
                + CodexDesktopPatcher.fastModeDetailReplacement527.search
                + CodexDesktopPatcher.fastModeModelTiersReplacement527.search,
            "webview/assets/app-server-manager-signals-Bpaj8VHp.js":
                CodexDesktopPatcher.fastModeServiceTiersReplacement527.search,
            "webview/assets/app-main-BxvNtdQT.js":
                CodexDesktopPatcher.pluginsSidebarReplacement527.search
                + CodexDesktopPatcher.appshotServiceEnablementReplacement527.search,
            ".vite/build/main-B260eRdI.js":
                CodexDesktopPatcher.appshotCaptureWorkerReplacement527.search,
            "webview/assets/skills-page-Cqn6vECJ.js":
                CodexDesktopPatcher.pluginsPageContentGateReplacement527.search,
            "webview/assets/plugin-detail-page-CETDWYs4.js":
                CodexDesktopPatcher.pluginDetailAccessReplacement527.search
                + CodexDesktopPatcher.pluginAuthFlowReplacement527.search,
            "webview/assets/check-plugin-availability-fTZpqnCL.js":
                CodexDesktopPatcher.pluginInstallAvailabilityReplacement527.search,
            "webview/assets/use-plugin-install-flow-BXFieYft.js":
                CodexDesktopPatcher.pluginInstallModalContentReplacement527.search,
            "webview/assets/use-is-appshot-available-BuzGfUqU.js":
                CodexDesktopPatcher.appshotAvailabilityReplacement527.search,
        ]
    )
}

private func codexDesktop52760818Fixture() throws -> CodexDesktopFixture {
    try CodexDesktopFixture(
        shortVersion: "26.527.60818",
        files: [
            "webview/assets/use-is-fast-mode-enabled-CnM6Q1N9.js":
                CodexDesktopPatcher.fastModeReplacement52760818.search
                + CodexDesktopPatcher.fastModeDetailReplacement52760818.search
                + CodexDesktopPatcher.fastModeModelTiersReplacement52760818.search,
            "webview/assets/app-server-manager-signals-Bpaj8VHp.js":
                CodexDesktopPatcher.fastModeServiceTiersReplacement527.search,
            "webview/assets/app-main-BwpsB7rB.js":
                CodexDesktopPatcher.pluginsSidebarReplacement52760818.search
                + CodexDesktopPatcher.appshotServiceEnablementReplacement52760818.search,
            ".vite/build/main-DowL6vN4.js":
                CodexDesktopPatcher.appshotCaptureWorkerReplacement52760818.search,
            "webview/assets/skills-page-BIZqKbZI.js":
                CodexDesktopPatcher.pluginsPageContentGateReplacement52760818.search,
            "webview/assets/plugin-detail-page-uf22h4TJ.js":
                CodexDesktopPatcher.pluginDetailAccessReplacement52760818.search
                + CodexDesktopPatcher.pluginAuthFlowReplacement52760818.search,
            "webview/assets/check-plugin-availability-CDJyCxkN.js":
                CodexDesktopPatcher.pluginInstallAvailabilityReplacement52760818.search,
            "webview/assets/use-plugin-install-flow-DpUQcozA.js":
                CodexDesktopPatcher.pluginInstallModalContentReplacement52760818.search,
            "webview/assets/use-is-appshot-available-B6eTO-q8.js":
                CodexDesktopPatcher.appshotAvailabilityReplacement52760818.search,
        ]
    )
}

private struct CodexDesktopFixture {
    let rootURL: URL
    let appURL: URL
    let asarURL: URL
    let infoPlistURL: URL

    init(shortVersion: String = "26.519.41501", files: [String: String]) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentsHubCodexPatchTests-\(UUID().uuidString)", isDirectory: true)
        appURL = rootURL.appendingPathComponent("Codex.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        asarURL = resourcesURL.appendingPathComponent("app.asar")
        infoPlistURL = contentsURL.appendingPathComponent("Info.plist")

        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try makeAsar(files: files).write(to: asarURL)
        try writeInfoPlist(
            shortVersion: shortVersion, asarHash: sha256Hex(Data(contentsOf: asarURL)))
    }

    private func writeInfoPlist(shortVersion: String, asarHash: String) throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.openai.codex",
            "CFBundleShortVersionString": shortVersion,
            "CFBundleVersion": "1",
            "ElectronAsarIntegrity": [
                "Resources/app.asar": [
                    "algorithm": "SHA256",
                    "hash": asarHash,
                ]
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
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
                    "blocks": [sha256Hex(data)],
                ],
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

private func insertAsarEntry(
    pathComponents: [String], entry: [String: Any], into node: inout [String: Any]
) {
    guard let first = pathComponents.first else { return }
    var files = node["files"] as? [String: Any] ?? [:]

    if pathComponents.count == 1 {
        files[first] = entry
    } else {
        var child = files[first] as? [String: Any] ?? ["files": [String: Any]()]
        insertAsarEntry(
            pathComponents: Array(pathComponents.dropFirst()), entry: entry, into: &child)
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

extension Data {
    fileprivate mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}

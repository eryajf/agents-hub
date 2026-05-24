import Foundation

struct CodexDesktopPatchOptions: OptionSet, Codable, Sendable, Hashable {
    let rawValue: Int

    static let fastMode = CodexDesktopPatchOptions(rawValue: 1 << 0)
    static let plugins = CodexDesktopPatchOptions(rawValue: 1 << 1)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(enableFastMode: Bool, enablePlugins: Bool) {
        var options: CodexDesktopPatchOptions = []
        if enableFastMode { options.insert(.fastMode) }
        if enablePlugins { options.insert(.plugins) }
        self = options
    }
}

struct CodexDesktopInstallation: Equatable, Sendable {
    var appURL: URL
    var shortVersion: String
    var bundleVersion: String
    var asarURL: URL
    var infoPlistURL: URL
    var asarSHA256: String
}

enum CodexDesktopPatchState: Equatable, Sendable {
    case notInstalled
    case unpatched
    case patched(CodexDesktopPatchOptions)
    case damaged(String)
    case unsupported(String)
}

struct CodexDesktopPatchStatus: Equatable, Sendable {
    var installation: CodexDesktopInstallation?
    var patchState: CodexDesktopPatchState
    var availableCapabilities: CodexDesktopPatchOptions
    var backupURL: URL?
}

struct CodexDesktopPatchManifest: Sendable, Hashable {
    var shortVersion: String
    var originalAsarSHA256: String
    var replacements: [CodexDesktopPatchReplacement]

    func replacements(for options: CodexDesktopPatchOptions) -> [AsarReplacement] {
        replacements
            .filter { options.contains($0.option) }
            .map { AsarReplacement(path: $0.path, search: $0.search, replacement: $0.replacement) }
    }
}

struct CodexDesktopPatchReplacement: Sendable, Hashable {
    var option: CodexDesktopPatchOptions
    var path: String
    var search: String
    var replacement: String
}

struct CodexDesktopPatchMarker: Sendable, Hashable {
    var path: String
    var marker: String
}

enum CodexDesktopPatchError: LocalizedError, Equatable {
    case notInstalled
    case unsupportedVersion(String)
    case missingBackup
    case invalidBackup
    case noPatchOptionsSelected
    case codeSigningFailed(String)
    case signatureVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Codex Desktop is not installed."
        case let .unsupportedVersion(version):
            "Codex Desktop \(version) is not supported by the current patch manifest."
        case .missingBackup:
            "No Codex Desktop backup was found."
        case .invalidBackup:
            "Codex Desktop backup is incomplete."
        case .noPatchOptionsSelected:
            "Select at least one Codex Desktop patch option."
        case let .codeSigningFailed(output):
            "Codex Desktop code signing failed: \(output)"
        case let .signatureVerificationFailed(output):
            "Codex Desktop code signing verification failed: \(output)"
        }
    }
}

struct CodexDesktopPatcher {
    var appSearchURLs: [URL]
    var backupDirectory: URL
    var manifests: [CodexDesktopPatchManifest]
    var codeSigner: CodexDesktopCodeSigner
    var fileManager: FileManager

    init(
        appSearchURLs: [URL] = Self.defaultAppSearchURLs,
        backupDirectory: URL = AppPaths.codexDesktopBackupDirectory,
        manifests: [CodexDesktopPatchManifest] = Self.builtInManifests,
        codeSigner: CodexDesktopCodeSigner = ProcessCodexDesktopCodeSigner(),
        fileManager: FileManager = .default
    ) {
        self.appSearchURLs = appSearchURLs
        self.backupDirectory = backupDirectory
        self.manifests = manifests
        self.codeSigner = codeSigner
        self.fileManager = fileManager
    }

    func status() throws -> CodexDesktopPatchStatus {
        guard let installation = try detectInstallation(allowMissingAsar: true) else {
            return CodexDesktopPatchStatus(
                installation: nil,
                patchState: .notInstalled,
                availableCapabilities: [],
                backupURL: nil
            )
        }

        let backupURL = latestBackupURL(for: installation)
        return CodexDesktopPatchStatus(
            installation: installation,
            patchState: fileManager.fileExists(atPath: installation.asarURL.path())
                ? try patchState(for: installation)
                : .damaged("Codex Desktop app.asar is missing."),
            availableCapabilities: try availableCapabilities(for: installation),
            backupURL: backupURL
        )
    }

    func detectInstallation(allowMissingAsar: Bool = false) throws -> CodexDesktopInstallation? {
        for appURL in appSearchURLs where fileManager.fileExists(atPath: appURL.path()) {
            let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
            let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
            let asarURL = contentsURL.appendingPathComponent("Resources/app.asar")

            guard fileManager.fileExists(atPath: infoPlistURL.path()) else {
                continue
            }
            let asarExists = fileManager.fileExists(atPath: asarURL.path())
            guard asarExists || allowMissingAsar else { continue }

            let plist = try loadPlist(infoPlistURL)
            let shortVersion = plist["CFBundleShortVersionString"] as? String ?? "unknown"
            let bundleVersion = plist["CFBundleVersion"] as? String ?? "unknown"
            let asarHash = if asarExists {
                ElectronAsarArchive.sha256Hex(try Data(contentsOf: asarURL))
            } else {
                ""
            }

            return CodexDesktopInstallation(
                appURL: appURL,
                shortVersion: shortVersion,
                bundleVersion: bundleVersion,
                asarURL: asarURL,
                infoPlistURL: infoPlistURL,
                asarSHA256: asarHash
            )
        }

        return nil
    }

    func apply(options: CodexDesktopPatchOptions) throws {
        guard !options.isEmpty else { throw CodexDesktopPatchError.noPatchOptionsSelected }
        guard let installation = try detectInstallation() else { throw CodexDesktopPatchError.notInstalled }

        let existingOptions = try patchedOptions(for: installation)
        let pendingOptions = options.subtracting(existingOptions)
        guard !pendingOptions.isEmpty else { return }

        let manifest = try manifest(for: installation, options: pendingOptions)
        let replacements = manifest.replacements(for: pendingOptions)
        guard !replacements.isEmpty else { throw CodexDesktopPatchError.noPatchOptionsSelected }

        let backupURL = try createBackupIfNeeded(for: installation)
        do {
            try ElectronAsarArchive(url: installation.asarURL).apply(replacements)
            try syncInfoPlistAsarHash(for: installation)
            try codeSigner.sign(appURL: installation.appURL)
        } catch {
            try? restoreFiles(from: backupURL, to: installation)
            try? codeSigner.sign(appURL: installation.appURL)
            throw error
        }
    }

    func restore() throws {
        guard let installation = try detectInstallation(allowMissingAsar: true) else {
            throw CodexDesktopPatchError.notInstalled
        }
        guard let backupURL = latestBackupURL(for: installation) else {
            throw CodexDesktopPatchError.missingBackup
        }

        let asarBackupURL = backupURL.appendingPathComponent("app.asar")
        let plistBackupURL = backupURL.appendingPathComponent("Info.plist")

        guard fileManager.fileExists(atPath: asarBackupURL.path()),
              fileManager.fileExists(atPath: plistBackupURL.path())
        else { throw CodexDesktopPatchError.invalidBackup }

        try restoreFiles(from: backupURL, to: installation)
        try codeSigner.sign(appURL: installation.appURL)
    }

    private func patchState(for installation: CodexDesktopInstallation) throws -> CodexDesktopPatchState {
        let options = try patchedOptions(for: installation)

        if !options.isEmpty {
            return .patched(options)
        }

        if manifests.contains(where: { $0.shortVersion == installation.shortVersion }) {
            return .unpatched
        }

        return .unsupported(installation.shortVersion)
    }

    private func patchedOptions(for installation: CodexDesktopInstallation) throws -> CodexDesktopPatchOptions {
        var options: CodexDesktopPatchOptions = []
        let archive = ElectronAsarArchive(url: installation.asarURL)

        let fastReplacement = Self.fastModeReplacement
        if (try? archive.string(at: fastReplacement.path).contains(fastReplacement.replacement)) == true {
            options.insert(.fastMode)
        }

        let pluginReplacement = Self.pluginsReplacement
        let pluginMarkersPatched = try Self.pluginsPatchedMarkers.allSatisfy { marker in
            try archive.string(at: marker.path).contains(marker.marker)
        }
        if pluginMarkersPatched &&
            (try? archive.string(at: pluginReplacement.path).contains(Self.pluginsPageContentLegacyBrokenPatch.marker)) != true
        {
            options.insert(.plugins)
        }

        return options
    }

    private func availableCapabilities(for installation: CodexDesktopInstallation) throws -> CodexDesktopPatchOptions {
        guard fileManager.fileExists(atPath: installation.asarURL.path()) else { return [] }

        let archive = ElectronAsarArchive(url: installation.asarURL)
        var capabilities: CodexDesktopPatchOptions = []

        if (try? archive.contains(path: "webview/assets/use-is-fast-mode-enabled-CwUgvZ2O.js")) == true {
            capabilities.insert(.fastMode)
        }

        if (try? archive.contains(path: "webview/assets/use-is-plugins-enabled-aU0WrVOp.js")) == true ||
            (try? archive.contains(path: "webview/assets/skills-page-C8PW4EqX.js")) == true
        {
            capabilities.insert(.plugins)
        }

        return capabilities
    }

    private func manifest(
        for installation: CodexDesktopInstallation,
        options: CodexDesktopPatchOptions
    ) throws -> CodexDesktopPatchManifest {
        if let exact = manifests.first(where: {
            $0.shortVersion == installation.shortVersion &&
                $0.originalAsarSHA256 == installation.asarSHA256
        }) {
            return exact
        }

        if let versionMatch = manifests.first(where: { $0.shortVersion == installation.shortVersion }) {
            let archive = ElectronAsarArchive(url: installation.asarURL)
            let canApply = try versionMatch.replacements.filter { options.contains($0.option) }.allSatisfy { replacement in
                try archive.string(at: replacement.path).contains(replacement.search)
            }
            if canApply {
                return versionMatch
            }
        }

        throw CodexDesktopPatchError.unsupportedVersion(installation.shortVersion)
    }

    @discardableResult
    private func createBackupIfNeeded(for installation: CodexDesktopInstallation) throws -> URL {
        if let existingBackupURL = latestBackupURL(for: installation) {
            return existingBackupURL
        }

        let backupURL = backupURL(for: installation)
        let asarBackupURL = backupURL.appendingPathComponent("app.asar")
        let plistBackupURL = backupURL.appendingPathComponent("Info.plist")

        guard !fileManager.fileExists(atPath: asarBackupURL.path()) ||
            !fileManager.fileExists(atPath: plistBackupURL.path())
        else {
            return backupURL
        }

        try fileManager.createDirectory(at: backupURL, withIntermediateDirectories: true)
        try fileManager.copyReplacingItem(at: installation.asarURL, to: asarBackupURL)
        try fileManager.copyReplacingItem(at: installation.infoPlistURL, to: plistBackupURL)

        let metadata = CodexDesktopBackupMetadata(
            appPath: installation.appURL.path(),
            shortVersion: installation.shortVersion,
            bundleVersion: installation.bundleVersion,
            originalAsarSHA256: installation.asarSHA256,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: backupURL.appendingPathComponent("metadata.json"), options: .atomic)
        return backupURL
    }

    private func restoreFiles(from backupURL: URL, to installation: CodexDesktopInstallation) throws {
        let asarBackupURL = backupURL.appendingPathComponent("app.asar")
        let plistBackupURL = backupURL.appendingPathComponent("Info.plist")
        guard fileManager.fileExists(atPath: asarBackupURL.path()),
              fileManager.fileExists(atPath: plistBackupURL.path())
        else { throw CodexDesktopPatchError.invalidBackup }

        try fileManager.copyReplacingItem(at: asarBackupURL, to: installation.asarURL)
        try fileManager.copyReplacingItem(at: plistBackupURL, to: installation.infoPlistURL)
    }

    private func backupURL(for installation: CodexDesktopInstallation) -> URL {
        backupDirectory
            .appendingPathComponent(installation.shortVersion, isDirectory: true)
            .appendingPathComponent(installation.asarSHA256, isDirectory: true)
    }

    private func latestBackupURL(for installation: CodexDesktopInstallation) -> URL? {
        let url = backupURL(for: installation)
        if fileManager.fileExists(atPath: url.path()) {
            return url
        }

        let versionDirectory = backupDirectory.appendingPathComponent(installation.shortVersion, isDirectory: true)
        guard let backupCandidates = try? fileManager.contentsOfDirectory(
            at: versionDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        return backupCandidates
            .filter { candidate in
                let asarURL = candidate.appendingPathComponent("app.asar")
                let plistURL = candidate.appendingPathComponent("Info.plist")
                guard fileManager.fileExists(atPath: asarURL.path()),
                      fileManager.fileExists(atPath: plistURL.path())
                else {
                    return false
                }

                let metadataURL = candidate.appendingPathComponent("metadata.json")
                guard let data = try? Data(contentsOf: metadataURL),
                      let metadata = try? JSONDecoder.iso8601.decode(CodexDesktopBackupMetadata.self, from: data)
                else {
                    return true
                }

                return metadata.appPath == installation.appURL.path() &&
                    metadata.shortVersion == installation.shortVersion
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }

    private func syncInfoPlistAsarHash(for installation: CodexDesktopInstallation) throws {
        var plist = try loadPlist(installation.infoPlistURL)
        var integrity = plist["ElectronAsarIntegrity"] as? [String: Any] ?? [:]
        var appAsar = integrity["Resources/app.asar"] as? [String: Any] ?? [:]

        appAsar["algorithm"] = "SHA256"
        appAsar["hash"] = try ElectronAsarArchive(url: installation.asarURL).headerSHA256Hex()
        integrity["Resources/app.asar"] = appAsar
        plist["ElectronAsarIntegrity"] = integrity

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: installation.infoPlistURL, options: .atomic)
    }

    private func loadPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return object as? [String: Any] ?? [:]
    }

    static var defaultAppSearchURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
            home.appendingPathComponent("Applications/Codex.app", isDirectory: true)
        ]
    }

    static let fastModeReplacement = CodexDesktopPatchReplacement(
        option: .fastMode,
        path: "webview/assets/use-is-fast-mode-enabled-CwUgvZ2O.js",
        search: "d?.authMethod!==`chatgpt`||g",
        replacement: "false                    ||g"
    )

    static let pluginsSidebarReplacement = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/app-main-DG-Mf4Wj.js",
        search: "{authMethod:c}=Ba(),l=Li(`533078438`),u=Cc(c),d=e&&l&&u,f=bs({hostId:Tt}),p=e&&f&&!u,",
        replacement: "{authMethod:c}=Ba(),l=Li(`533078438`),u=Cc(c),d=!1  ,f=bs({hostId:Tt}),p=e&&f       ,"
    )

    static let pluginsPageContentGateReplacement = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/skills-page-C8PW4EqX.js",
        search: "let m=f,g,v;",
        replacement: "let m=0,g,v;"
    )

    static let pluginsPageContentLegacyRepairReplacement = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/skills-page-C8PW4EqX.js",
        search: "s&&!1)",
        replacement: "s&&!m)"
    )

    static let pluginDetailAccessReplacement = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/plugin-detail-page-jAJa26RM.js",
        search: "{authMethod:i}=oe();if(Be(i)){",
        replacement: "{authMethod:i}=oe();if(!1   ){"
    )

    static let pluginInstallAvailabilityReplacement = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/check-plugin-availability-6p9UsIaB.js",
        search: "let F=w.length>0&&N===w.length?M?`disabled-by-admin`:`connector-unavailable`:null,I;",
        replacement: "let F=w.length>0&&N===w.length?M?`disabled-by-admin`:null                   :null,I;"
    )

    static let pluginInstallModalContentReplacement = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/use-plugin-install-flow-IT_xMrDV.js",
        search: "let g=m,_=(u?.apps.length??0)>0&&u?.summary.authPolicy===`ON_INSTALL`,v;",
        replacement: "let g=m,_=(u?.apps.length??0)>0&&!1                                  ,v;"
    )

    static let pluginsReplacement = pluginsPageContentGateReplacement

    static let pluginsPatchedMarkers = [
        CodexDesktopPatchMarker(path: pluginsSidebarReplacement.path, marker: pluginsSidebarReplacement.replacement),
        CodexDesktopPatchMarker(path: pluginsPageContentGateReplacement.path, marker: pluginsPageContentGateReplacement.replacement),
        CodexDesktopPatchMarker(path: pluginDetailAccessReplacement.path, marker: pluginDetailAccessReplacement.replacement),
        CodexDesktopPatchMarker(path: pluginInstallAvailabilityReplacement.path, marker: pluginInstallAvailabilityReplacement.replacement),
        CodexDesktopPatchMarker(path: pluginInstallModalContentReplacement.path, marker: pluginInstallModalContentReplacement.replacement)
    ]

    static let pluginsPageContentLegacyBrokenPatch = CodexDesktopPatchMarker(
        path: pluginsPageContentLegacyRepairReplacement.path,
        marker: pluginsPageContentLegacyRepairReplacement.search
    )

    static let builtInManifests: [CodexDesktopPatchManifest] = [
        CodexDesktopPatchManifest(
            shortVersion: "26.519.41501",
            originalAsarSHA256: "cdc9847749438db200b94386385db764f0cea97b9a07b98143aa0f89977eece5",
            replacements: [
                fastModeReplacement,
                pluginsSidebarReplacement,
                pluginsPageContentGateReplacement,
                pluginsPageContentLegacyRepairReplacement,
                pluginDetailAccessReplacement,
                pluginInstallAvailabilityReplacement,
                pluginInstallModalContentReplacement
            ]
        )
    ]
}

protocol CodexDesktopCodeSigner: Sendable {
    func sign(appURL: URL) throws
}

struct ProcessCodexDesktopCodeSigner: CodexDesktopCodeSigner {
    func sign(appURL: URL) throws {
        let entitlementsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentshub-codex-electron-entitlements.plist")
        try Self.electronEntitlements.write(to: entitlementsURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--force",
            "--deep",
            "--options",
            "runtime",
            "--entitlements",
            entitlementsURL.path(),
            "--sign",
            "-",
            appURL.path()
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CodexDesktopPatchError.codeSigningFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        try verify(appURL: appURL)
    }

    private func verify(appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--verify",
            "--deep",
            "--strict",
            "--verbose=1",
            appURL.path()
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CodexDesktopPatchError.signatureVerificationFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static let electronEntitlements = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.security.cs.allow-jit</key>
        <true/>
        <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
        <true/>
        <key>com.apple.security.cs.disable-library-validation</key>
        <true/>
    </dict>
    </plist>

    """
}

private struct CodexDesktopBackupMetadata: Codable {
    var appPath: String
    var shortVersion: String
    var bundleVersion: String
    var originalAsarSHA256: String
    var createdAt: Date
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension FileManager {
    func copyReplacingItem(at sourceURL: URL, to destinationURL: URL) throws {
        try createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        try copyItem(at: sourceURL, to: temporaryURL)
        if fileExists(atPath: destinationURL.path()) {
            _ = try replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try moveItem(at: temporaryURL, to: destinationURL)
        }
    }
}

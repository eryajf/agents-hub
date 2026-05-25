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
    case noPatchOptionsSelected

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Codex Desktop is not installed."
        case let .unsupportedVersion(version):
            "Codex Desktop \(version) is not supported by the current patch manifest."
        case .noPatchOptionsSelected:
            "Select at least one Codex Desktop patch option."
        }
    }
}

struct CodexDesktopPatcher {
    var appSearchURLs: [URL]
    var manifests: [CodexDesktopPatchManifest]
    var fileManager: FileManager

    init(
        appSearchURLs: [URL] = Self.defaultAppSearchURLs,
        manifests: [CodexDesktopPatchManifest] = Self.builtInManifests,
        fileManager: FileManager = .default
    ) {
        self.appSearchURLs = appSearchURLs
        self.manifests = manifests
        self.fileManager = fileManager
    }

    func status() throws -> CodexDesktopPatchStatus {
        guard let installation = try detectInstallation(allowMissingAsar: true) else {
            return CodexDesktopPatchStatus(
                installation: nil,
                patchState: .notInstalled,
                availableCapabilities: []
            )
        }

        return CodexDesktopPatchStatus(
            installation: installation,
            patchState: fileManager.fileExists(atPath: installation.asarURL.path())
                ? try patchState(for: installation)
                : .damaged("Codex Desktop app.asar is missing."),
            availableCapabilities: try availableCapabilities(for: installation)
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

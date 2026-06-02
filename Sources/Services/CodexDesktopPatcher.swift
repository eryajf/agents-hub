import Foundation

struct CodexDesktopPatchOptions: OptionSet, Codable, Sendable, Hashable {
    let rawValue: Int

    static let fastMode = CodexDesktopPatchOptions(rawValue: 1 << 0)
    static let plugins = CodexDesktopPatchOptions(rawValue: 1 << 1)
    static let appshot = CodexDesktopPatchOptions(rawValue: 1 << 2)

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
        case .unsupportedVersion(let version):
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
            let asarHash =
                if asarExists {
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

    private func patchState(for installation: CodexDesktopInstallation) throws
        -> CodexDesktopPatchState
    {
        let options = try patchedOptions(for: installation)

        if !options.isEmpty {
            return .patched(options)
        }

        if manifests.contains(where: { $0.shortVersion == installation.shortVersion }) {
            return .unpatched
        }

        return .unsupported(installation.shortVersion)
    }

    private func patchedOptions(for installation: CodexDesktopInstallation) throws
        -> CodexDesktopPatchOptions
    {
        var options: CodexDesktopPatchOptions = []
        let archive = ElectronAsarArchive(url: installation.asarURL)

        let manifest = manifest(for: installation)
        let replacements = manifest?.replacements ?? Self.allKnownReplacements

        if let fastReplacement = replacements.first(where: { $0.option == .fastMode }),
            (try? archive.string(at: fastReplacement.path).contains(fastReplacement.replacement))
                == true
        {
            options.insert(.fastMode)
        }

        let pluginMarkers =
            replacements
            .filter {
                $0.option == .plugins
                    && $0 != Self.pluginsPageContentLegacyRepairReplacement519
            }
            .map { CodexDesktopPatchMarker(path: $0.path, marker: $0.replacement) }
        let pluginMarkersPatched =
            if pluginMarkers.isEmpty {
                false
            } else {
                try pluginMarkers.allSatisfy { marker in
                    try archive.string(at: marker.path).contains(marker.marker)
                }
            }
        let hasLegacyBrokenPatch =
            (try? archive.string(at: Self.pluginsPageContentLegacyBrokenPatch.path)
                .contains(Self.pluginsPageContentLegacyBrokenPatch.marker)) == true
        if pluginMarkersPatched && !hasLegacyBrokenPatch {
            options.insert(.plugins)
        }

        let appshotReplacements = replacements.filter { $0.option == .appshot }
        if appshotReplacements.contains(where: { replacement in
            (try? archive.string(at: replacement.path).contains(replacement.replacement)) == true
        }) {
            options.insert(.appshot)
        }

        return options
    }

    private func availableCapabilities(for installation: CodexDesktopInstallation) throws
        -> CodexDesktopPatchOptions
    {
        guard fileManager.fileExists(atPath: installation.asarURL.path()) else { return [] }

        let archive = ElectronAsarArchive(url: installation.asarURL)
        var capabilities: CodexDesktopPatchOptions = []
        let replacements = manifest(for: installation)?.replacements ?? Self.allKnownReplacements

        if replacements.contains(where: {
            $0.option == .fastMode && ((try? archive.contains(path: $0.path)) == true)
        }) {
            capabilities.insert(.fastMode)
        }

        if replacements.contains(where: {
            $0.option == .plugins && ((try? archive.contains(path: $0.path)) == true)
        }) {
            capabilities.insert(.plugins)
        }

        if replacements.contains(where: {
            $0.option == .appshot && ((try? archive.contains(path: $0.path)) == true)
        }) {
            capabilities.insert(.appshot)
        }

        return capabilities
    }

    private func manifest(for installation: CodexDesktopInstallation) -> CodexDesktopPatchManifest?
    {
        manifests.first { $0.shortVersion == installation.shortVersion }
    }

    private func loadPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        return object as? [String: Any] ?? [:]
    }

    static var defaultAppSearchURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
            home.appendingPathComponent("Applications/Codex.app", isDirectory: true),
        ]
    }

    static let fastModeReplacement519 = CodexDesktopPatchReplacement(
        option: .fastMode,
        path: "webview/assets/use-is-fast-mode-enabled-CwUgvZ2O.js",
        search: "d?.authMethod!==`chatgpt`||g",
        replacement: "false                    ||g"
    )

    static let fastModeReplacement527 = CodexDesktopPatchReplacement(
        option: .fastMode,
        path: "webview/assets/use-is-fast-mode-enabled-BCZ3vDoA.js",
        search: "c?.authMethod!==`chatgpt`||u",
        replacement: "false                    ||u"
    )

    static let fastModeDetailReplacement527 = CodexDesktopPatchReplacement(
        option: .fastMode,
        path: "webview/assets/use-is-fast-mode-enabled-BCZ3vDoA.js",
        search: "d?.authMethod!==`chatgpt`||g",
        replacement: "false                    ||g"
    )

    static let fastModeModelTiersReplacement527 = CodexDesktopPatchReplacement(
        option: .fastMode,
        path: "webview/assets/use-is-fast-mode-enabled-BCZ3vDoA.js",
        search: "v?.models.some(m)??!1",
        replacement: "true                 "
    )

    static let fastModeServiceTiersReplacement527 = CodexDesktopPatchReplacement(
        option: .fastMode,
        path: "webview/assets/app-server-manager-signals-Bpaj8VHp.js",
        search:
            "function Mp(e){return e?.serviceTiers?.find(e=>Ep(e.id,e.name)===`fast`||e.name.trim().toLowerCase()===`priority`)??null}",
        replacement:
            "function Mp(e){return e?.serviceTiers?.find(e=>Ep(e.id,e.name)===`fast`||e.name===wp)??{id:wp}}                          "
    )

    static let fastModeReplacement52760818 = CodexDesktopPatchReplacement(
        option: .fastMode,
        path: "webview/assets/use-is-fast-mode-enabled-CnM6Q1N9.js",
        search: fastModeReplacement527.search,
        replacement: fastModeReplacement527.replacement
    )

    static let fastModeDetailReplacement52760818 = CodexDesktopPatchReplacement(
        option: .fastMode,
        path: fastModeReplacement52760818.path,
        search: fastModeDetailReplacement527.search,
        replacement: fastModeDetailReplacement527.replacement
    )

    static let fastModeModelTiersReplacement52760818 = CodexDesktopPatchReplacement(
        option: .fastMode,
        path: fastModeReplacement52760818.path,
        search: fastModeModelTiersReplacement527.search,
        replacement: fastModeModelTiersReplacement527.replacement
    )

    static let pluginsSidebarReplacement519 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/app-main-DG-Mf4Wj.js",
        search:
            "{authMethod:c}=Ba(),l=Li(`533078438`),u=Cc(c),d=e&&l&&u,f=bs({hostId:Tt}),p=e&&f&&!u,",
        replacement:
            "{authMethod:c}=Ba(),l=Li(`533078438`),u=Cc(c),d=!1  ,f=bs({hostId:Tt}),p=e&&f       ,"
    )

    static let pluginsSidebarReplacement527 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/app-main-BxvNtdQT.js",
        search: "u=e&&c&&l,d=mc({hostId:mr}),f=e&&d&&!l,",
        replacement: "u=!1     ,d=mc({hostId:mr}),f=e&&d    ,"
    )

    static let pluginsSidebarReplacement52760818 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/app-main-BwpsB7rB.js",
        search: "u=e&&c&&l,d=hc({hostId:mr}),f=e&&d&&!l,",
        replacement: "u=!1     ,d=hc({hostId:mr}),f=e&&d    ,"
    )

    static let pluginsPageContentGateReplacement519 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/skills-page-C8PW4EqX.js",
        search: "let m=f,g,v;",
        replacement: "let m=0,g,v;"
    )

    static let pluginsPageContentGateReplacement527 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/skills-page-Cqn6vECJ.js",
        search: "s&&!h)",
        replacement: "s&&!1)"
    )

    static let pluginsPageContentGateReplacement52760818 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/skills-page-BIZqKbZI.js",
        search: "s&&!h)",
        replacement: "s&&!1)"
    )

    static let pluginsPageContentLegacyRepairReplacement519 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/skills-page-C8PW4EqX.js",
        search: "s&&!1)",
        replacement: "s&&!m)"
    )

    static let pluginDetailAccessReplacement519 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/plugin-detail-page-jAJa26RM.js",
        search: "{authMethod:i}=oe();if(Be(i)){",
        replacement: "{authMethod:i}=oe();if(!1   ){"
    )

    static let pluginDetailAccessReplacement527 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/plugin-detail-page-CETDWYs4.js",
        search: "{authMethod:i}=ae();if(Be(i)){",
        replacement: "{authMethod:i}=ae();if(!1   ){"
    )

    static let pluginDetailAccessReplacement52760818 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/plugin-detail-page-uf22h4TJ.js",
        search: "{authMethod:i}=ae();if(De(i)){",
        replacement: "{authMethod:i}=ae();if(!1   ){"
    )

    static let pluginInstallAvailabilityReplacement519 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/check-plugin-availability-6p9UsIaB.js",
        search:
            "let F=w.length>0&&N===w.length?M?`disabled-by-admin`:`connector-unavailable`:null,I;",
        replacement:
            "let F=w.length>0&&N===w.length?M?`disabled-by-admin`:null                   :null,I;"
    )

    static let pluginInstallAvailabilityReplacement527 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/check-plugin-availability-fTZpqnCL.js",
        search:
            "let F=b.length>0&&N===b.length?M?`disabled-by-admin`:`connector-unavailable`:null,I;",
        replacement:
            "let F=b.length>0&&N===b.length?M?`disabled-by-admin`:null                   :null,I;"
    )

    static let pluginInstallAvailabilityReplacement52760818 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/check-plugin-availability-CDJyCxkN.js",
        search: pluginInstallAvailabilityReplacement527.search,
        replacement: pluginInstallAvailabilityReplacement527.replacement
    )

    static let pluginInstallModalContentReplacement519 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/use-plugin-install-flow-IT_xMrDV.js",
        search: "let g=m,_=(u?.apps.length??0)>0&&u?.summary.authPolicy===`ON_INSTALL`,v;",
        replacement: "let g=m,_=(u?.apps.length??0)>0&&!1                                  ,v;"
    )

    static let pluginInstallModalContentReplacement527 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/use-plugin-install-flow-BXFieYft.js",
        search: "A=s.kind===`details`&&s.plugin.plugin.authPolicy===`ON_INSTALL`,",
        replacement: "A=!1,                                                           "
    )

    static let pluginInstallModalContentReplacement52760818 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/use-plugin-install-flow-DpUQcozA.js",
        search: "let h=m,g=(u?.apps.length??0)>0&&u?.summary.authPolicy===`ON_INSTALL`,_;",
        replacement: "let h=m,g=(u?.apps.length??0)>0&&!1                                  ,_;"
    )

    static let pluginAuthFlowReplacement527 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: "webview/assets/plugin-detail-page-CETDWYs4.js",
        search: "enabled:Y?.summary.installed===!0&&Y.summary.authPolicy===`ON_INSTALL`",
        replacement: "enabled:!1                                                            "
    )

    static let pluginAuthFlowReplacement52760818 = CodexDesktopPatchReplacement(
        option: .plugins,
        path: pluginDetailAccessReplacement52760818.path,
        search: pluginAuthFlowReplacement527.search,
        replacement: pluginAuthFlowReplacement527.replacement
    )

    static let appshotAvailabilityReplacement519 = CodexDesktopPatchReplacement(
        option: .appshot,
        path: "webview/assets/use-is-appshot-available-D0PV8qeY.js",
        search: "return n===`macOS`&&r",
        replacement: "return n===`macOS`   "
    )

    static let appshotAvailabilityReplacement527 = CodexDesktopPatchReplacement(
        option: .appshot,
        path: "webview/assets/use-is-appshot-available-BuzGfUqU.js",
        search: "return n===`macOS`&&r",
        replacement: "return n===`macOS`   "
    )

    static let appshotAvailabilityReplacement52760818 = CodexDesktopPatchReplacement(
        option: .appshot,
        path: "webview/assets/use-is-appshot-available-B6eTO-q8.js",
        search: appshotAvailabilityReplacement527.search,
        replacement: appshotAvailabilityReplacement527.replacement
    )

    static let appshotServiceEnablementReplacement519 = CodexDesktopPatchReplacement(
        option: .appshot,
        path: "webview/assets/app-main-DG-Mf4Wj.js",
        search: "appshotsEnabled:r,artifactsPane:!0",
        replacement: "appshotsEnabled:!0,artifactsPane:1"
    )

    static let appshotServiceEnablementReplacement527 = CodexDesktopPatchReplacement(
        option: .appshot,
        path: "webview/assets/app-main-BxvNtdQT.js",
        search: "appshotsEnabled:r,artifactsPane:!0",
        replacement: "appshotsEnabled:!0,artifactsPane:1"
    )

    static let appshotServiceEnablementReplacement52760818 = CodexDesktopPatchReplacement(
        option: .appshot,
        path: pluginsSidebarReplacement52760818.path,
        search: appshotServiceEnablementReplacement527.search,
        replacement: appshotServiceEnablementReplacement527.replacement
    )

    static let appshotCaptureWorkerReplacement519 = CodexDesktopPatchReplacement(
        option: .appshot,
        path: ".vite/build/main-DVEWN1ng.js",
        search: "T&&t.O.isInternal(a)&&P.startComputerUseCaptureWorker()",
        replacement: "T&&true             &&P.startComputerUseCaptureWorker()"
    )

    static let appshotCaptureWorkerReplacement527 = CodexDesktopPatchReplacement(
        option: .appshot,
        path: ".vite/build/main-B260eRdI.js",
        search: "O&&n.j.isInternal(s)&&ae.startComputerUseCaptureWorker()",
        replacement: "O&&true             &&ae.startComputerUseCaptureWorker()"
    )

    static let appshotCaptureWorkerReplacement52760818 = CodexDesktopPatchReplacement(
        option: .appshot,
        path: ".vite/build/main-DowL6vN4.js",
        search: appshotCaptureWorkerReplacement527.search,
        replacement: appshotCaptureWorkerReplacement527.replacement
    )

    static let pluginsPageContentLegacyBrokenPatch = CodexDesktopPatchMarker(
        path: pluginsPageContentLegacyRepairReplacement519.path,
        marker: pluginsPageContentLegacyRepairReplacement519.search
    )

    static let fastModeReplacement = fastModeReplacement519
    static let pluginsSidebarReplacement = pluginsSidebarReplacement519
    static let pluginsPageContentGateReplacement = pluginsPageContentGateReplacement519
    static let pluginDetailAccessReplacement = pluginDetailAccessReplacement519
    static let pluginInstallAvailabilityReplacement = pluginInstallAvailabilityReplacement519
    static let pluginInstallModalContentReplacement = pluginInstallModalContentReplacement519
    static let appshotAvailabilityReplacement = appshotAvailabilityReplacement519
    static let appshotServiceEnablementReplacement = appshotServiceEnablementReplacement519

    static let replacements519 = [
        fastModeReplacement519,
        pluginsSidebarReplacement519,
        pluginsPageContentGateReplacement519,
        pluginsPageContentLegacyRepairReplacement519,
        pluginDetailAccessReplacement519,
        pluginInstallAvailabilityReplacement519,
        pluginInstallModalContentReplacement519,
        appshotAvailabilityReplacement519,
        appshotServiceEnablementReplacement519,
        appshotCaptureWorkerReplacement519,
    ]

    static let replacements527 = [
        fastModeReplacement527,
        fastModeDetailReplacement527,
        fastModeModelTiersReplacement527,
        fastModeServiceTiersReplacement527,
        pluginsSidebarReplacement527,
        pluginsPageContentGateReplacement527,
        pluginDetailAccessReplacement527,
        pluginInstallAvailabilityReplacement527,
        pluginInstallModalContentReplacement527,
        pluginAuthFlowReplacement527,
        appshotAvailabilityReplacement527,
        appshotServiceEnablementReplacement527,
        appshotCaptureWorkerReplacement527,
    ]

    static let replacements52760818 = [
        fastModeReplacement52760818,
        fastModeDetailReplacement52760818,
        fastModeModelTiersReplacement52760818,
        fastModeServiceTiersReplacement527,
        pluginsSidebarReplacement52760818,
        pluginsPageContentGateReplacement52760818,
        pluginDetailAccessReplacement52760818,
        pluginInstallAvailabilityReplacement52760818,
        pluginInstallModalContentReplacement52760818,
        pluginAuthFlowReplacement52760818,
        appshotAvailabilityReplacement52760818,
        appshotServiceEnablementReplacement52760818,
        appshotCaptureWorkerReplacement52760818,
    ]

    static let allKnownReplacements = replacements519 + replacements527 + replacements52760818

    static let builtInManifests: [CodexDesktopPatchManifest] = [
        CodexDesktopPatchManifest(
            shortVersion: "26.519.41501",
            originalAsarSHA256: "cdc9847749438db200b94386385db764f0cea97b9a07b98143aa0f89977eece5",
            replacements: replacements519
        ),
        CodexDesktopPatchManifest(
            shortVersion: "26.527.31326",
            originalAsarSHA256: "d5328e1ee074cda36d4fe07c69c38d017b6ef9b467a5b88c118618e035f338d1",
            replacements: replacements527
        ),
        CodexDesktopPatchManifest(
            shortVersion: "26.527.60818",
            originalAsarSHA256: "63aa85903e8cd29e881fc2d098bc169fd9e7dce32532dee952b45e776338c0dc",
            replacements: replacements52760818
        ),
    ]
}

import Foundation

enum CodexRuntimeLaunchError: LocalizedError, Equatable {
    case notInstalled
    case noPatchOptionsSelected
    case alreadyRunning
    case launcherResourceMissing
    case nodeMissing(String)
    case untrustedSignature
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Codex Desktop is not installed."
        case .noPatchOptionsSelected:
            "Select at least one Codex runtime patch option."
        case .alreadyRunning:
            "Quit Codex before launching with runtime patches."
        case .launcherResourceMissing:
            "Codex runtime launcher resource is missing."
        case let .nodeMissing(path):
            "Codex bundled Node executable was not found at \(path)."
        case .untrustedSignature:
            "Codex.app is not signed by the official OpenAI Developer ID. Reinstall the official app before using runtime patches."
        case let .launchFailed(output):
            "Codex runtime launch failed: \(output)"
        }
    }
}

struct CodexRuntimeLaunchResult: Equatable, Sendable {
    var port: Int
    var processIdentifier: Int32
}

struct CodexRuntimeLauncher {
    var patcher: CodexDesktopPatcher
    var fileManager: FileManager
    var resourceBundle: Bundle

    init(
        patcher: CodexDesktopPatcher = CodexDesktopPatcher(),
        fileManager: FileManager = .default,
        resourceBundle: Bundle = AppResourceBundle.bundle
    ) {
        self.patcher = patcher
        self.fileManager = fileManager
        self.resourceBundle = resourceBundle
    }

    func launch(options: CodexDesktopPatchOptions) throws -> CodexRuntimeLaunchResult {
        guard !options.isEmpty else { throw CodexRuntimeLaunchError.noPatchOptionsSelected }
        guard let installation = try patcher.detectInstallation() else { throw CodexRuntimeLaunchError.notInstalled }
        let codexRunning = try isCodexRunning()
        guard !codexRunning else { throw CodexRuntimeLaunchError.alreadyRunning }
        guard try isOfficiallySigned(appURL: installation.appURL) else {
            throw CodexRuntimeLaunchError.untrustedSignature
        }

        let nodeURL = installation.appURL
            .appendingPathComponent("Contents/Resources/node", isDirectory: false)
        guard fileManager.fileExists(atPath: Self.fileSystemPath(for: nodeURL)) else {
            throw CodexRuntimeLaunchError.nodeMissing(Self.fileSystemPath(for: nodeURL))
        }

        guard let launcherURL = Self.launcherResourceURL(in: resourceBundle) else {
            throw CodexRuntimeLaunchError.launcherResourceMissing
        }

        let port = randomPort()
        let process = Process()
        process.executableURL = nodeURL
        process.arguments = [
            Self.fileSystemPath(for: launcherURL),
            "--app",
            Self.fileSystemPath(for: installation.appURL),
            "--port",
            String(port),
            "--features",
            featureArgument(options)
        ]

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentshub-codex-runtime-\(UUID().uuidString).log")
        fileManager.createFile(atPath: logURL.path(), contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()

        do {
            try waitForLauncherReady(process: process, logURL: logURL)
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw error
        }

        return CodexRuntimeLaunchResult(port: port, processIdentifier: process.processIdentifier)
    }

    private func featureArgument(_ options: CodexDesktopPatchOptions) -> String {
        var features: [String] = []
        if options.contains(.fastMode) { features.append("fast") }
        if options.contains(.plugins) { features.append("plugins") }
        return features.joined(separator: ",")
    }

    static func launcherResourceURL(in bundle: Bundle) -> URL? {
        bundle.url(
            forResource: "runtime-launcher",
            withExtension: "mjs",
            subdirectory: "CodexRuntimePatch"
        ) ?? bundle.url(forResource: "runtime-launcher", withExtension: "mjs")
    }

    static func fileSystemPath(for url: URL) -> String {
        url.path(percentEncoded: false)
    }

    private func waitForLauncherReady(process: Process, logURL: URL) throws {
        let deadline = Date().addingTimeInterval(12)
        var output = ""
        while Date() < deadline {
            output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? output
            if output.contains("[codex-runtime] ready") {
                return
            }
            if !process.isRunning {
                output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? output
                throw CodexRuntimeLaunchError.launchFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CodexRuntimeLaunchError.launchFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func randomPort() -> Int {
        Int.random(in: 40_000 ... 59_999)
    }

    private func isCodexRunning() throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "Codex"]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func isOfficiallySigned(appURL: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=4", appURL.path()]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.contains("TeamIdentifier=2DC432GLL2") &&
            !output.contains("Signature=adhoc")
    }
}

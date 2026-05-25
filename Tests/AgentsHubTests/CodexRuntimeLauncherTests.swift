import Foundation
import Testing
@testable import AgentsHub

@Suite("Codex runtime launcher")
struct CodexRuntimeLauncherTests {
    @Test("Runtime launcher resource is resolved from packaged resources")
    func runtimeLauncherResourceIsResolved() throws {
        let launcherURL = try #require(CodexRuntimeLauncher.launcherResourceURL(in: AppResourceBundle.bundle))

        #expect(launcherURL.lastPathComponent == "runtime-launcher.mjs")
        #expect(FileManager.default.fileExists(atPath: launcherURL.path()))
    }

    @Test("Filesystem paths passed to child processes are not percent encoded")
    func fileSystemPathIsNotPercentEncoded() {
        let url = URL(fileURLWithPath: "/tmp/Agents Hub.app/Contents/Resources/runtime-launcher.mjs")

        #expect(CodexRuntimeLauncher.fileSystemPath(for: url) == "/tmp/Agents Hub.app/Contents/Resources/runtime-launcher.mjs")
    }
}

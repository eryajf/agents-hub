import AppKit
import SwiftUI

@main
struct AgentsHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var localizationManager = LocalizationManager()
    @State private var manager = ProfileManager()
    @StateObject private var appUpdater = AppUpdater()

    var body: some Scene {
        WindowGroup(id: AppSceneID.mainWindow) {
            ContentView(manager: manager, appUpdater: appUpdater)
                .environment(localizationManager)
                .frame(
                    minWidth: AppLayoutConstants.windowMinWidth,
                    minHeight: AppLayoutConstants.windowMinHeight
                )
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 820, height: 540)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("\(L.string("ui.settings.about", using: localizationManager)) \(AppInfo.displayName)") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: AppInfo.displayName,
                        .applicationVersion: AppInfo.versionDisplay,
                        .version: ""
                    ])
                }
            }

            CommandGroup(after: .appInfo) {
                Button(L.string("ui.app.check_for_updates", using: localizationManager)) {
                    appUpdater.checkForUpdates()
                }
            }
        }

        MenuBarExtra(AppInfo.displayName, systemImage: "point.3.connected.trianglepath.dotted") {
            MenuBarActions(appUpdater: appUpdater)
                .environment(localizationManager)
        }
    }
}

private enum AppSceneID {
    static let mainWindow = "main-window"
}

private struct MenuBarActions: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(LocalizationManager.self) private var lm
    let appUpdater: AppUpdater

    var body: some View {
        Button(L.string("ui.app.show_main_window", using: lm)) {
            AppActivation.showMainWindow(openWindow: openWindow)
        }

        Divider()

        Button(L.string("ui.app.check_for_updates", using: lm)) {
            appUpdater.checkForUpdates()
        }

        Divider()

        Button("\(L.string("ui.app.quit", using: lm)) \(AppInfo.displayName)") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

private enum AppActivation {
    @MainActor
    static func showMainWindow(openWindow: OpenWindowAction) {
        NSApplication.shared.setActivationPolicy(.regular)
        openWindow(id: AppSceneID.mainWindow)

        Task { @MainActor in
            await Task.yield()
            NSApplication.shared.activate(ignoringOtherApps: true)
            visibleApplicationWindows.first?.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    static func hideDockIconIfNoWindowsRemain() {
        guard visibleApplicationWindows.isEmpty else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    @MainActor
    private static var visibleApplicationWindows: [NSWindow] {
        NSApplication.shared.windows.filter { window in
            window.isVisible
                && !window.isMiniaturized
                && window.canBecomeMain
                && window.level == .normal
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [weak self] in
            NSApplication.shared.setActivationPolicy(.regular)
            self?.updateApplicationMenuTitle()
            await Task.yield()
            self?.updateApplicationMenuTitle()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Task { @MainActor in
            await Task.yield()
            AppActivation.hideDockIconIfNoWindowsRemain()
        }

        return false
    }

    @MainActor
    private func updateApplicationMenuTitle() {
        NSApplication.shared.mainMenu?.items.first?.title = AppInfo.displayName
    }
}

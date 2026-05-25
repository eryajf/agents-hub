import AppKit
import SwiftUI

struct AgentProfilesView: View {
    @Environment(LocalizationManager.self) private var lm
    @Bindable var manager: ProfileManager
    let provider: ProviderKind
    @Binding var path: [DetailRoute]
    @State private var sessionManager: SessionManager
    @State private var profilePendingDelete: APIProfile?

    init(manager: ProfileManager, provider: ProviderKind, path: Binding<[DetailRoute]>) {
        self.manager = manager
        self.provider = provider
        self._path = path
        self._sessionManager = State(initialValue: SessionManager(provider: provider))
    }

    var body: some View {
        SettingsPageContent {
            if provider == .claudeCode {
                claudeSharedSettings
            }
            if provider == .codex {
                codexSharedSettings
                codexDesktopPatchSection
            }
            profilesList
            AgentSessionsView(sessionManager: sessionManager, provider: provider)
            if provider == .codex {
                agentsMdSection
            }
            targetFiles
        }
        .navigationTitle(provider.displayName)
        .task {
            await sessionManager.loadSessions()
        }
        .confirmationDialog(
            L.string("ui.confirm.delete_configuration", using: lm),
            isPresented: deleteConfirmationBinding(for: $profilePendingDelete)
        ) {
            Button(L.string("ui.action.delete", using: lm), role: .destructive) {
                if let profilePendingDelete {
                    manager.selectProfile(profilePendingDelete)
                    manager.removeSelectedProfile()
                    path.removeAll()
                    self.profilePendingDelete = nil
                }
            }
            Button(L.string("ui.action.cancel", using: lm), role: .cancel) {
                profilePendingDelete = nil
            }
        } message: {
            Text(L.string("ui.confirm.delete_configuration_detail", using: lm))
        }
    }

    private var sortedProfiles: [APIProfile] {
        manager.profiles(for: provider)
    }

    private var profilesList: some View {
        let profiles = sortedProfiles
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(profiles) { profile in
                Button {
                    manager.selectProfile(profile)
                    path.append(.profile(profile.id))
                } label: {
                    profileRow(profile)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(L.string("ui.action.set_current", using: lm)) {
                        manager.selectProfile(profile)
                        manager.applySelectedProfile()
                    }
                    .disabled(!manager.isProfileReady(profile))

                    Button(L.string("ui.action.duplicate", using: lm)) {
                        manager.selectProfile(profile)
                        manager.duplicateSelectedProfile()
                    }

                    Button(L.string("ui.action.delete", using: lm), role: .destructive) {
                        profilePendingDelete = profile
                    }
                    .disabled(profiles.count <= 1)
                }

                if profile.id != profiles.last?.id {
                    SettingsDivider()
                }
            }
        }
        .settingsCard(L.string("ui.agent_profiles.configurations", using: lm))
    }

    private var claudeSharedSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow {
                FieldLabel(
                    L.string("ui.profile.skip_claude_onboarding", using: lm),
                    detail: L.string("ui.profile.skip_claude_onboarding_detail", using: lm),
                    detailLineLimit: 1
                )
            } trailing: {
                Toggle("", isOn: skipClaudeOnboardingBinding())
                    .labelsHidden()
            }
        }
        .settingsCard(L.string("ui.agent_profiles.shared_settings", using: lm))
    }

    private var codexSharedSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow {
                FieldLabel(
                    L.string("ui.profile.disable_codex_automatic_updates", using: lm),
                    detail: L.string("ui.profile.disable_codex_automatic_updates_detail", using: lm),
                    detailLineLimit: 2
                )
            } trailing: {
                Toggle("", isOn: disableCodexAutomaticUpdatesBinding())
                    .labelsHidden()
            }
        }
        .settingsCard(L.string("ui.agent_profiles.shared_settings", using: lm))
    }

    private var codexDesktopPatchSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            codexDesktopStatusRow
            SettingsDivider()
            codexDesktopPatchOptionRow(
                title: L.string("ui.codex_desktop_patch.fast_mode", using: lm),
                detail: L.string("ui.codex_desktop_patch.fast_mode_detail", using: lm),
                option: .fastMode
            )
            SettingsDivider()
            codexDesktopPatchOptionRow(
                title: L.string("ui.codex_desktop_patch.plugins", using: lm),
                detail: L.string("ui.codex_desktop_patch.plugins_detail", using: lm),
                option: .plugins
            )
            SettingsDivider()
            codexDesktopPatchOptionRow(
                title: L.string("ui.codex_desktop_patch.appshot", using: lm),
                detail: L.string("ui.codex_desktop_patch.appshot_detail", using: lm),
                option: .appshot
            )
            SettingsDivider()
            SettingsRow {
                FieldLabel(
                    L.string("ui.codex_desktop_patch.actions", using: lm),
                    detail: L.string("ui.codex_desktop_patch.actions_detail", using: lm),
                    detailLineLimit: 2
                )
            } trailing: {
                codexPatchAction(
                    title: L.string("ui.codex_desktop_patch.runtime_launch", using: lm),
                    systemImage: "play.fill",
                    help: L.string("ui.codex_desktop_patch.runtime_launch_help", using: lm),
                    disabled: !codexDesktopCanRuntimeLaunch
                ) {
                    manager.launchCodexWithRuntimePatch()
                }
            }
        }
        .settingsCard(L.string("ui.codex_desktop_patch.title", using: lm))
        .onAppear {
            if manager.codexDesktopPatchStatus == nil {
                manager.refreshCodexDesktopPatchStatus()
            }
        }
    }

    private func codexPatchAction(
        title: String,
        systemImage: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 3) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .disabled(disabled)
            .help(help)

            CodexPatchHelpButton(help: help)
        }
    }

    private var codexDesktopStatusRow: some View {
        SettingsRow {
            FieldLabel(
                L.string("ui.codex_desktop_patch.installation", using: lm),
                detail: codexDesktopStatusDetail,
                detailLineLimit: 2
            )
        } trailing: {
            Text(codexDesktopPatchStateText)
                .font(.caption.weight(.medium))
                .foregroundStyle(codexDesktopPatchStateColor)
                .lineLimit(1)
        }
    }

    private func codexDesktopPatchOptionRow(
        title: String,
        detail: String,
        option: CodexDesktopPatchOptions
    ) -> some View {
        SettingsRow {
            FieldLabel(title, detail: detail, detailLineLimit: 2)
        } trailing: {
            Toggle("", isOn: codexDesktopPatchOptionBinding(option))
                .labelsHidden()
                .disabled(!codexDesktopCapabilityAvailable(option))
        }
    }

    private var agentsMdSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentsMdEditorView(
                content: agentsMdContentBinding,
                lastSyncInfo: manager.agentsMdSyncInfoText,
                onSync: { manager.syncAgentsMd() },
                onSave: { manager.saveAgentsMd(manager.agentsMdContent) }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .settingsCard(L.string("ui.agents_md.title", using: lm)) {
            HStack(spacing: 8) {
                Text(L.string("ui.agents_md.description", using: lm))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Link(destination: URL(string: "https://developers.openai.com/codex/guides/agents-md#create-global-guidance")!) {
                    Label(L.string("ui.agents_md.learn_more", using: lm), systemImage: "questionmark.circle")
                        .font(.caption)
                }
            }
        }
        .onAppear {
            manager.syncAgentsMd()
        }
    }

    private var agentsMdContentBinding: Binding<String> {
        Binding {
            manager.agentsMdContent
        } set: { newValue in
            manager.agentsMdContent = newValue
        }
    }

    private var targetFiles: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(targetURLs, id: \.self) { url in
                SettingsRow {
                    Text(url.path())
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } trailing: {
                    Button {
                        reveal(url)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help(L.string("ui.action.reveal_in_finder", using: lm))
                }
            }
        }
        .settingsCard(L.string("ui.profile.apply_target", using: lm), subtitle: targetDescription)
    }

    private func profileRow(_ profile: APIProfile) -> some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(profile.name)
                        .font(.subheadline.weight(.semibold))
                    if profile.isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                            .help(L.string("ui.label.current", using: lm))
                    }
                }

                Text(profileDetailText(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } trailing: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func profileDetailText(_ profile: APIProfile) -> String {
        guard let apiProvider = manager.apiProvider(for: profile) else {
            return L.string("ui.api_provider.no_provider", using: lm)
        }

        let key = manager.apiProviderKey(for: profile)
        let keyName = apiProvider.keys.count > 1 ? " · \(key?.name ?? "")" : ""
        let keyValue = key?.redactedKey ?? L.string("ui.label.no_key", using: lm)
        return "\(apiProvider.name)\(keyName) · \(profile.displayModel) · \(keyValue)"
    }

    private var targetURLs: [URL] {
        switch provider {
        case .claudeCode:
            [AppPaths.claudeSettingsURL]
        case .codex:
            [AppPaths.codexConfigURL, AppPaths.codexAuthURL]
        }
    }

    private var targetDescription: String {
        switch provider {
        case .claudeCode:
            L.string("ui.profile.target_claude_detail", using: lm)
        case .codex:
            L.string("ui.profile.target_codex_detail", using: lm)
        }
    }

    private func skipClaudeOnboardingBinding() -> Binding<Bool> {
        Binding {
            manager.skipClaudeCodeOnboarding
        } set: { newValue in
            manager.updateSkipClaudeCodeOnboarding(newValue)
        }
    }

    private func disableCodexAutomaticUpdatesBinding() -> Binding<Bool> {
        Binding {
            manager.disableCodexAutomaticUpdates
        } set: { newValue in
            manager.updateDisableCodexAutomaticUpdates(newValue)
        }
    }

    private func codexDesktopPatchOptionBinding(_ option: CodexDesktopPatchOptions) -> Binding<Bool> {
        Binding {
            manager.codexDesktopPatchOptions.contains(option)
        } set: { newValue in
            manager.updateCodexDesktopPatchOption(option, enabled: newValue)
        }
    }

    private func codexDesktopCapabilityAvailable(_ option: CodexDesktopPatchOptions) -> Bool {
        manager.codexDesktopPatchStatus?.availableCapabilities.contains(option) == true
    }

    private var codexDesktopCanRuntimeLaunch: Bool {
        guard !manager.codexDesktopPatchOptions.isEmpty,
              let status = manager.codexDesktopPatchStatus
        else { return false }

        switch status.patchState {
        case .unpatched, .patched:
            return true
        case .damaged, .notInstalled, .unsupported:
            return false
        }
    }

    private var codexDesktopStatusDetail: String {
        guard let status = manager.codexDesktopPatchStatus else {
            return L.string("status.not_checked", using: lm)
        }

        guard let installation = status.installation else {
            return L.string("ui.label.no_local_installation", using: lm)
        }

        return "\(installation.shortVersion) · \(installation.appURL.path())"
    }

    private var codexDesktopPatchStateText: String {
        guard let status = manager.codexDesktopPatchStatus else {
            return L.string("status.not_checked", using: lm)
        }

        switch status.patchState {
        case .notInstalled:
            return L.string("ui.label.not_installed", using: lm)
        case .unpatched:
            return L.string("ui.codex_desktop_patch.state_unpatched", using: lm)
        case let .patched(options):
            if options.contains([.fastMode, .plugins, .appshot]) {
                return L.string("ui.codex_desktop_patch.state_patched_all", using: lm)
            }
            if options.contains([.fastMode, .plugins]) {
                return L.string("ui.codex_desktop_patch.state_patched_fast_plugins", using: lm)
            }
            if options.contains([.fastMode, .appshot]) {
                return L.string("ui.codex_desktop_patch.state_patched_fast_appshot", using: lm)
            }
            if options.contains([.plugins, .appshot]) {
                return L.string("ui.codex_desktop_patch.state_patched_plugins_appshot", using: lm)
            }
            if options.contains(.fastMode) {
                return L.string("ui.codex_desktop_patch.state_patched_fast", using: lm)
            }
            if options.contains(.plugins) {
                return L.string("ui.codex_desktop_patch.state_patched_plugins", using: lm)
            }
            if options.contains(.appshot) {
                return L.string("ui.codex_desktop_patch.state_patched_appshot", using: lm)
            }
            return L.string("ui.codex_desktop_patch.state_patched", using: lm)
        case .damaged:
            return L.string("ui.codex_desktop_patch.state_damaged", using: lm)
        case .unsupported:
            return L.string("ui.codex_desktop_patch.state_unsupported", using: lm)
        }
    }

    private var codexDesktopPatchStateColor: Color {
        guard let status = manager.codexDesktopPatchStatus else { return .secondary }

        switch status.patchState {
        case .patched:
            return .green
        case .damaged, .unsupported:
            return .orange
        case .notInstalled:
            return .secondary
        case .unpatched:
            return .blue
        }
    }

    private func reveal(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        NSWorkspace.shared.selectFile(url.path(), inFileViewerRootedAtPath: directory.path())
    }
}

private struct CodexPatchHelpButton: View {
    let help: String
    @State private var isPresented = false

    var body: some View {
        Button {} label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering in
            isPresented = hovering
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(help)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(width: 240, alignment: .leading)
        }
    }
}

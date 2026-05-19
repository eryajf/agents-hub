import SwiftUI

struct AgentsMdEditorView: View {
    @Environment(LocalizationManager.self) private var lm
    @Binding var content: String
    var lastSyncInfo: String?
    var onSync: () -> Void
    var onSave: () -> Void
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar

            Rectangle()
                .fill(Color.agentsMarkdownBorder.opacity(0.55))
                .frame(height: 1 / max(NSScreen.main?.backingScaleFactor ?? 2, 1))

            editorSurface
        }
        .background(Color.agentsMarkdownBlockBackground, in: editorShape)
        .overlay {
            editorShape
                .stroke(editorBorderColor, lineWidth: isEditorFocused ? 1.2 : 1)
        }
        .shadow(color: focusedShadowColor, radius: isEditorFocused ? 4 : 0, y: 0)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if let lastSyncInfo {
                Text(lastSyncInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Button {
                onSync()
            } label: {
                Label(L.string("ui.agents_md.sync", using: lm), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(L.string("ui.agents_md.sync_help", using: lm))

            Button {
                onSave()
            } label: {
                Label(L.string("ui.agents_md.save", using: lm), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L.string("ui.agents_md.save_help", using: lm))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .trailing)
    }

    private var editorSurface: some View {
        TextEditor(text: $content)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(Color.agentsMarkdownText)
            .lineSpacing(2)
            .scrollContentBackground(.hidden)
            .focused($isEditorFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 190, idealHeight: 220, maxHeight: 320)
            .background(Color.clear)
    }

    private var editorShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    private var editorBorderColor: Color {
        if isEditorFocused {
            return .accentColor.opacity(0.42)
        }

        return .agentsMarkdownBorder
    }

    private var focusedShadowColor: Color {
        .accentColor.opacity(0.12)
    }
}

private extension Color {
    static var agentsMarkdownBlockBackground: Color { Color(nsColor: .quaternaryLabelColor).opacity(0.12) }
    static var agentsMarkdownBorder: Color { Color(nsColor: .separatorColor).opacity(0.36) }
    static var agentsMarkdownText: Color { Color(nsColor: .labelColor) }
}

import Foundation

enum AgentsMdSyncDirection: Sendable {
    case diskToApp
    case appToDisk
    case noChange
}

struct AgentsMdSyncResult: Sendable {
    let direction: AgentsMdSyncDirection
    let content: String
    let modifiedAt: Date
}

struct AgentsMdManager: Sendable {
    private let fileURL: URL

    init(fileURL: URL = AppPaths.codexAgentsMdURL) {
        self.fileURL = fileURL
    }

    /// Reads content and modification time from the disk file.
    func readFromDisk() throws -> (content: String, modifiedAt: Date)? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path()) else { return nil }

        let attributes = try fm.attributesOfItem(atPath: fileURL.path())
        guard let modifiedAt = attributes[.modificationDate] as? Date else { return nil }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        return (content, modifiedAt)
    }

    /// Writes content to the disk file, creating the directory if needed.
    func writeToDisk(_ content: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Performs bidirectional sync between disk and app state.
    /// Returns the sync result indicating which direction sync happened, or `.noChange`.
    func sync(
        appContent: String,
        appModifiedAt: Date?
    ) throws -> AgentsMdSyncResult? {
        let diskState = try readFromDisk()

        let hasDiskContent = !(diskState?.content.isEmpty ?? true)
        let hasAppContent = !appContent.isEmpty

        switch (hasDiskContent, hasAppContent) {
        case (false, false):
            return nil

        case (true, false):
            // Disk has content, app is empty → disk to app
            let disk = diskState!
            return AgentsMdSyncResult(
                direction: .diskToApp,
                content: disk.content,
                modifiedAt: disk.modifiedAt
            )

        case (false, true):
            // App has content, disk is empty → app to disk
            let now = Date()
            try writeToDisk(appContent)
            return AgentsMdSyncResult(
                direction: .appToDisk,
                content: appContent,
                modifiedAt: now
            )

        case (true, true):
            // Both have content → compare modification times
            let disk = diskState!
            let appTime = appModifiedAt ?? .distantPast

            if disk.modifiedAt > appTime {
                // Disk is newer
                return AgentsMdSyncResult(
                    direction: .diskToApp,
                    content: disk.content,
                    modifiedAt: disk.modifiedAt
                )
            } else if appTime > disk.modifiedAt {
                // App is newer
                let now = Date()
                try writeToDisk(appContent)
                return AgentsMdSyncResult(
                    direction: .appToDisk,
                    content: appContent,
                    modifiedAt: now
                )
            } else {
                // Same time, check content
                if disk.content == appContent {
                    return nil
                }
                // Same timestamp but different content → prefer disk
                return AgentsMdSyncResult(
                    direction: .diskToApp,
                    content: disk.content,
                    modifiedAt: disk.modifiedAt
                )
            }
        }
    }
}

import Foundation

enum CodexHistoryRebuildError: LocalizedError, Equatable {
    case codexRunning
    case codexDirectoryMissing
    case stateDatabaseMissing
    case noSessionsFound
    case sqliteFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexRunning:
            "Quit Codex before rebuilding local history."
        case .codexDirectoryMissing:
            "Codex data directory was not found."
        case .stateDatabaseMissing:
            "Codex history database state_5.sqlite was not found."
        case .noSessionsFound:
            "No local Codex session files were found."
        case let .sqliteFailed(output):
            "Codex history rebuild failed: \(output)"
        }
    }
}

struct CodexHistoryRebuildResult: Equatable, Sendable {
    var scannedCount: Int
    var restoredCount: Int
    var existingCount: Int
    var backupURL: URL
}

struct CodexHistoryRebuilder {
    var codexDirectory: URL
    var backupDirectory: URL
    var fileManager: FileManager
    var codexRunningChecker: () throws -> Bool

    init(
        codexDirectory: URL = AppPaths.codexDirectory,
        backupDirectory: URL = AppPaths.configDirectory.appendingPathComponent("codex-history-backups", isDirectory: true),
        fileManager: FileManager = .default,
        codexRunningChecker: @escaping () throws -> Bool = CodexHistoryRebuilder.defaultCodexRunning
    ) {
        self.codexDirectory = codexDirectory
        self.backupDirectory = backupDirectory
        self.fileManager = fileManager
        self.codexRunningChecker = codexRunningChecker
    }

    func rebuild() throws -> CodexHistoryRebuildResult {
        let codexRunning = try codexRunningChecker()
        guard !codexRunning else { throw CodexHistoryRebuildError.codexRunning }
        guard fileManager.fileExists(atPath: codexDirectory.path()) else {
            throw CodexHistoryRebuildError.codexDirectoryMissing
        }

        let databaseURL = codexDirectory.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: databaseURL.path()) else {
            throw CodexHistoryRebuildError.stateDatabaseMissing
        }

        let sessions = try scanSessions()
        guard !sessions.isEmpty else { throw CodexHistoryRebuildError.noSessionsFound }

        let backupURL = try createBackup()
        let existingIDs = try existingThreadIDs(databaseURL: databaseURL)
        let missingSessions = sessions.filter { !existingIDs.contains($0.id) }
        let existingCount = sessions.count - missingSessions.count
        if !missingSessions.isEmpty {
            try upsert(missingSessions, databaseURL: databaseURL)
        }

        return CodexHistoryRebuildResult(
            scannedCount: sessions.count,
            restoredCount: missingSessions.count,
            existingCount: existingCount,
            backupURL: backupURL
        )
    }

    private func scanSessions() throws -> [CodexThreadRecord] {
        var files: [URL] = []
        collectJSONLFiles(in: codexDirectory.appendingPathComponent("sessions", isDirectory: true), result: &files)
        collectJSONLFiles(in: codexDirectory.appendingPathComponent("archived_sessions", isDirectory: true), result: &files)

        var recordsByID: [String: CodexThreadRecord] = [:]
        for file in files where file.lastPathComponent.hasPrefix("rollout-") {
            guard let record = parseSession(file: file) else { continue }
            let existing = recordsByID[record.id]
            if existing == nil || record.updatedAt > existing!.updatedAt {
                recordsByID[record.id] = record
            }
        }
        return recordsByID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func collectJSONLFiles(in directory: URL, result: inout [URL]) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }

        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                collectJSONLFiles(in: entry, result: &result)
            } else if entry.pathExtension == "jsonl" {
                result.append(entry)
            }
        }
    }

    private func parseSession(file: URL) -> CodexThreadRecord? {
        guard let sessionID = sessionID(from: file) else { return nil }
        let archived = file.path().contains("/archived_sessions/")
        let attributes = try? fileManager.attributesOfItem(atPath: file.path())
        let modificationDate = attributes?[.modificationDate] as? Date

        var record = CodexThreadRecord(
            id: sessionID,
            rolloutPath: file.path(),
            createdAt: seconds(from: timestampInFilename(file)) ?? seconds(from: modificationDate) ?? Int(Date().timeIntervalSince1970),
            updatedAt: seconds(from: modificationDate) ?? Int(Date().timeIntervalSince1970),
            source: "cli",
            modelProvider: "openai",
            cwd: "",
            title: "",
            sandboxPolicy: #"{"type":"workspace-write"}"#,
            approvalMode: "on-request",
            archived: archived ? 1 : 0,
            archivedAt: archived ? seconds(from: modificationDate) : nil,
            cliVersion: "",
            firstUserMessage: "",
            model: nil,
            reasoningEffort: nil,
            createdAtMS: milliseconds(from: timestampInFilename(file)),
            updatedAtMS: milliseconds(from: modificationDate),
            threadSource: nil,
            preview: ""
        )

        guard let handle = try? FileHandle(forReadingFrom: file) else { return record }
        defer { try? handle.close() }

        for line in readLines(from: handle, maxCount: 400) {
            guard let object = parseJSON(line) else { continue }
            let type = object["type"] as? String
            let timestamp = parseTimestamp(object["timestamp"])
            if let timestamp {
                let seconds = Int(timestamp.timeIntervalSince1970)
                let millis = milliseconds(from: timestamp)
                record.createdAt = min(record.createdAt, seconds)
                record.updatedAt = max(record.updatedAt, seconds)
                record.createdAtMS = minOptional(record.createdAtMS, millis)
                record.updatedAtMS = maxOptional(record.updatedAtMS, millis)
            }

            if type == "session_meta", let payload = object["payload"] as? [String: Any] {
                applySessionMeta(payload, to: &record)
            } else if type == "turn_context", let payload = object["payload"] as? [String: Any] {
                applyTurnContext(payload, to: &record)
            } else if record.firstUserMessage.isEmpty, let text = firstUserText(from: object) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    record.firstUserMessage = String(trimmed.prefix(4_000))
                    record.title = String(trimmed.prefix(300))
                    record.preview = String(trimmed.prefix(4_000))
                }
            }
        }

        if record.title.isEmpty {
            record.title = record.firstUserMessage.nilIfBlank ?? file.deletingPathExtension().lastPathComponent
        }
        if record.preview.isEmpty {
            record.preview = record.firstUserMessage.nilIfBlank ?? record.title
        }

        return record
    }

    private func applySessionMeta(_ payload: [String: Any], to record: inout CodexThreadRecord) {
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty { record.cwd = cwd }
        if let source = payload["source"] as? String, !source.isEmpty { record.source = source }
        if let provider = payload["model_provider"] as? String, !provider.isEmpty { record.modelProvider = provider }
        if let cliVersion = payload["cli_version"] as? String, !cliVersion.isEmpty { record.cliVersion = cliVersion }
        if let threadSource = payload["thread_source"] as? String, !threadSource.isEmpty { record.threadSource = threadSource }
        if let timestamp = parseTimestamp(payload["timestamp"]) {
            record.createdAt = Int(timestamp.timeIntervalSince1970)
            record.createdAtMS = milliseconds(from: timestamp)
        }
    }

    private func applyTurnContext(_ payload: [String: Any], to record: inout CodexThreadRecord) {
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty { record.cwd = cwd }
        if let sandbox = payload["sandbox_policy"] {
            record.sandboxPolicy = jsonString(sandbox) ?? record.sandboxPolicy
        }
        if let approval = payload["approval_policy"] as? String, !approval.isEmpty { record.approvalMode = approval }
        if let model = payload["model"] as? String, !model.isEmpty { record.model = model }
        if let effort = payload["effort"] as? String, !effort.isEmpty { record.reasoningEffort = effort }
    }

    private func sessionID(from file: URL) -> String? {
        let filename = file.deletingPathExtension().lastPathComponent
        let parts = filename.components(separatedBy: "-")
        guard parts.count >= 6 else { return nil }
        return parts.suffix(5).joined(separator: "-")
    }

    private func timestampInFilename(_ file: URL) -> Date? {
        let stem = file.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("rollout-") else { return nil }
        let parts = stem.components(separatedBy: "-")
        guard parts.count >= 7 else { return nil }
        let timestamp = parts[1...5].joined(separator: "-")
        return parseTimestamp(timestamp)
    }

    private func readLines(from handle: FileHandle, maxCount: Int) -> [String] {
        var lines: [String] = []
        var buffer = Data()

        while lines.count < maxCount {
            guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { break }
            buffer.append(data)
            let text = String(data: buffer, encoding: .utf8) ?? ""
            let parts = text.components(separatedBy: "\n")
            buffer = parts.last?.data(using: .utf8) ?? Data()
            for line in parts.dropLast() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lines.append(trimmed)
                    if lines.count >= maxCount { break }
                }
            }
        }

        if lines.count < maxCount {
            let remaining = String(data: buffer, encoding: .utf8) ?? ""
            let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append(trimmed)
            }
        }
        return lines
    }

    private func parseJSON(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func parseTimestamp(_ value: Any?) -> Date? {
        if let string = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: string)
        }

        if let number = value as? Double {
            return Date(timeIntervalSince1970: number > 1_000_000_000_000 ? number / 1_000 : number)
        }

        if let number = value as? Int {
            let double = Double(number)
            return Date(timeIntervalSince1970: double > 1_000_000_000_000 ? double / 1_000 : double)
        }

        return nil
    }

    private func firstUserText(from object: [String: Any]) -> String? {
        if let role = object["role"] as? String, role == "user" {
            return extractText(from: object["content"])
        }
        if let payload = object["payload"] as? [String: Any],
           let type = payload["type"] as? String,
           type == "message",
           let role = payload["role"] as? String,
           role == "user"
        {
            return extractText(from: payload["content"])
        }
        return nil
    }

    private func extractText(from value: Any?) -> String? {
        if let string = value as? String {
            return string.nilIfBlank
        }
        if let array = value as? [[String: Any]] {
            let parts = array.compactMap { item in
                (item["text"] as? String) ??
                    (item["input_text"] as? String) ??
                    (item["output_text"] as? String)
            }
            return parts.joined(separator: " ").nilIfBlank
        }
        if let dict = value as? [String: Any] {
            return (dict["text"] as? String)?.nilIfBlank
        }
        return nil
    }

    private func existingThreadIDs(databaseURL: URL) throws -> Set<String> {
        let tableExists = try runSQLite(
            databaseURL: databaseURL,
            input: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'threads';\n"
        )
        guard !tableExists.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let output = try runSQLite(databaseURL: databaseURL, input: "SELECT id FROM threads;\n")
        return Set(output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private func upsert(_ records: [CodexThreadRecord], databaseURL: URL) throws {
        var sql = """
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            source TEXT NOT NULL,
            model_provider TEXT NOT NULL,
            cwd TEXT NOT NULL,
            title TEXT NOT NULL,
            sandbox_policy TEXT NOT NULL,
            approval_mode TEXT NOT NULL,
            tokens_used INTEGER NOT NULL DEFAULT 0,
            has_user_event INTEGER NOT NULL DEFAULT 0,
            archived INTEGER NOT NULL DEFAULT 0,
            archived_at INTEGER,
            git_sha TEXT,
            git_branch TEXT,
            git_origin_url TEXT,
            cli_version TEXT NOT NULL DEFAULT '',
            first_user_message TEXT NOT NULL DEFAULT '',
            agent_nickname TEXT,
            agent_role TEXT,
            memory_mode TEXT NOT NULL DEFAULT 'enabled',
            model TEXT,
            reasoning_effort TEXT,
            agent_path TEXT,
            created_at_ms INTEGER,
            updated_at_ms INTEGER,
            thread_source TEXT,
            preview TEXT NOT NULL DEFAULT ''
        );

        """

        for record in records {
            sql += record.insertSQL
            sql += "\n"
        }
        sql += "COMMIT;\n"
        _ = try runSQLite(databaseURL: databaseURL, input: sql)
    }

    private func runSQLite(databaseURL: URL, input: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path()]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        inputPipe.fileHandleForWriting.write(Data(input.utf8))
        try? inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CodexHistoryRebuildError.sqliteFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private func createBackup() throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = backupDirectory.appendingPathComponent(stamp, isDirectory: true)
        try fileManager.createDirectory(at: backupURL, withIntermediateDirectories: true)

        for name in ["state_5.sqlite", "state_5.sqlite-shm", "state_5.sqlite-wal", "session_index.jsonl"] {
            let source = codexDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path()) else { continue }
            try fileManager.copyItem(at: source, to: backupURL.appendingPathComponent(name))
        }
        return backupURL
    }

    private static func defaultCodexRunning() throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "Codex"]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private func seconds(from date: Date?) -> Int? {
        date.map { Int($0.timeIntervalSince1970) }
    }

    private func milliseconds(from date: Date?) -> Int? {
        date.map { Int($0.timeIntervalSince1970 * 1_000) }
    }

    private func minOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            min(lhs, rhs)
        case let (lhs?, nil):
            lhs
        case let (nil, rhs?):
            rhs
        case (nil, nil):
            nil
        }
    }

    private func maxOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            max(lhs, rhs)
        case let (lhs?, nil):
            lhs
        case let (nil, rhs?):
            rhs
        case (nil, nil):
            nil
        }
    }
}

private struct CodexThreadRecord {
    var id: String
    var rolloutPath: String
    var createdAt: Int
    var updatedAt: Int
    var source: String
    var modelProvider: String
    var cwd: String
    var title: String
    var sandboxPolicy: String
    var approvalMode: String
    var archived: Int
    var archivedAt: Int?
    var cliVersion: String
    var firstUserMessage: String
    var model: String?
    var reasoningEffort: String?
    var createdAtMS: Int?
    var updatedAtMS: Int?
    var threadSource: String?
    var preview: String

    var insertSQL: String {
        """
        INSERT OR IGNORE INTO threads (
            id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
            sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
            git_sha, git_branch, git_origin_url, cli_version, first_user_message,
            agent_nickname, agent_role, memory_mode, model, reasoning_effort, agent_path,
            created_at_ms, updated_at_ms, thread_source, preview
        ) VALUES (
            \(sql(id)), \(sql(rolloutPath)), \(createdAt), \(updatedAt), \(sql(source)), \(sql(modelProvider)),
            \(sql(cwd)), \(sql(title)), \(sql(sandboxPolicy)), \(sql(approvalMode)), 0, 0, \(archived),
            \(sql(archivedAt)), NULL, NULL, NULL, \(sql(cliVersion)), \(sql(firstUserMessage)),
            NULL, NULL, 'enabled', \(sql(model)), \(sql(reasoningEffort)), NULL,
            \(sql(createdAtMS)), \(sql(updatedAtMS)), \(sql(threadSource)), \(sql(preview))
        );
        """
    }

    private func sql(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func sql(_ value: Int?) -> String {
        value.map(String.init) ?? "NULL"
    }
}

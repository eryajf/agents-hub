import Foundation
import Testing
@testable import AgentsHub

@Suite("Codex history rebuilder")
struct CodexHistoryRebuilderTests {
    @Test("Rebuild inserts missing rollout sessions into Codex state database")
    func rebuildInsertsMissingRolloutSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let codexDirectory = root.appendingPathComponent("codex", isDirectory: true)
        let sessionsDirectory = codexDirectory.appendingPathComponent("sessions/2026/05/24", isDirectory: true)
        let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let databaseURL = codexDirectory.appendingPathComponent("state_5.sqlite")
        try Data().write(to: databaseURL)

        let sessionID = "019b3989-9693-7a33-8b31-2abe6af8b54a"
        let rolloutURL = sessionsDirectory.appendingPathComponent("rollout-2026-05-24T07-05-31-\(sessionID).jsonl")
        try """
        {"timestamp":"2026-05-24T07:05:31.000Z","type":"session_meta","payload":{"id":"\(sessionID)","timestamp":"2026-05-24T07:05:31.000Z","cwd":"/tmp/project","source":"cli","model_provider":"openai","cli_version":"0.76.0"}}
        {"timestamp":"2026-05-24T07:05:32.000Z","type":"turn_context","payload":{"cwd":"/tmp/project","sandbox_policy":{"type":"workspace-write"},"approval_policy":"on-request","model":"gpt-5.1-codex-max","effort":"high"}}
        {"timestamp":"2026-05-24T07:05:33.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello from restored history"}]}}

        """.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let rebuilder = CodexHistoryRebuilder(
            codexDirectory: codexDirectory,
            backupDirectory: backupDirectory,
            codexRunningChecker: { false }
        )

        let result = try rebuilder.rebuild()
        let title = try sqliteValue(databaseURL, "SELECT title FROM threads WHERE id = '\(sessionID)';")
        let countAfterSecondRun = try {
            let secondResult = try rebuilder.rebuild()
            #expect(secondResult.restoredCount == 0)
            #expect(secondResult.existingCount == 1)
            return try sqliteValue(databaseURL, "SELECT COUNT(*) FROM threads WHERE id = '\(sessionID)';")
        }()

        #expect(result.scannedCount == 1)
        #expect(result.restoredCount == 1)
        #expect(result.existingCount == 0)
        #expect(FileManager.default.fileExists(atPath: result.backupURL.appendingPathComponent("state_5.sqlite").path()))
        #expect(title == "hello from restored history")
        #expect(countAfterSecondRun == "1")
    }

    private func sqliteValue(_ databaseURL: URL, _ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path(), sql]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw CodexHistoryRebuildError.sqliteFailed(output)
        }
        return output
    }
}

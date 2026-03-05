import Foundation
import SQLite3

final class ChatThreadStore {
    private let dbURL: URL
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = appSupport.appendingPathComponent("MOBaiLE", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        dbURL = directory.appendingPathComponent("threads.sqlite3")
        setupSchema()
    }

    func migrateLegacyThreadsIfNeeded(defaults: UserDefaults, threadsKey: String) {
        guard loadThreads().isEmpty else {
            defaults.removeObject(forKey: threadsKey)
            return
        }
        guard let data = defaults.data(forKey: threadsKey),
              let decoded = try? JSONDecoder().decode([ChatThread].self, from: data) else {
            return
        }
        for thread in decoded {
            let metadata = ChatThread(
                id: thread.id,
                title: thread.title,
                updatedAt: thread.updatedAt,
                conversation: [],
                runID: thread.runID,
                summaryText: thread.summaryText,
                transcriptText: thread.transcriptText,
                statusText: thread.statusText,
                resolvedWorkingDirectory: thread.resolvedWorkingDirectory,
                activeRunExecutor: thread.activeRunExecutor
            )
            upsertThread(metadata)
            for (position, message) in thread.conversation.enumerated() {
                upsertMessage(threadID: thread.id, message: message, position: position)
            }
        }
        defaults.removeObject(forKey: threadsKey)
    }

    func loadThreads() -> [ChatThread] {
        guard let db = openConnection() else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, title, updated_at, run_id, summary_text, transcript_text, status_text, resolved_working_directory, active_run_executor
        FROM threads
        ORDER BY updated_at DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [ChatThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let idText = stringColumn(statement, index: 0)
            guard let uuid = UUID(uuidString: idText) else { continue }
            let title = stringColumn(statement, index: 1)
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            rows.append(
                ChatThread(
                    id: uuid,
                    title: title,
                    updatedAt: updatedAt,
                    conversation: [],
                    runID: stringColumn(statement, index: 3),
                    summaryText: stringColumn(statement, index: 4),
                    transcriptText: stringColumn(statement, index: 5),
                    statusText: stringColumn(statement, index: 6),
                    resolvedWorkingDirectory: stringColumn(statement, index: 7),
                    activeRunExecutor: stringColumn(statement, index: 8)
                )
            )
        }
        return rows
    }

    func loadMessages(threadID: UUID) -> [ConversationMessage] {
        guard let db = openConnection() else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT message_id, role, text
        FROM thread_messages
        WHERE thread_id = ?
        ORDER BY position ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: threadID.uuidString)

        var rows: [ConversationMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = UUID(uuidString: stringColumn(statement, index: 0)) ?? UUID()
            let role = stringColumn(statement, index: 1)
            let text = stringColumn(statement, index: 2)
            rows.append(ConversationMessage(id: id, role: role, text: text))
        }
        return rows
    }

    func upsertThread(_ thread: ChatThread) {
        guard let db = openConnection() else { return }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO threads (
            id, title, updated_at, run_id, summary_text, transcript_text, status_text, resolved_working_directory, active_run_executor
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title,
            updated_at=excluded.updated_at,
            run_id=excluded.run_id,
            summary_text=excluded.summary_text,
            transcript_text=excluded.transcript_text,
            status_text=excluded.status_text,
            resolved_working_directory=excluded.resolved_working_directory,
            active_run_executor=excluded.active_run_executor
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: thread.id.uuidString)
        bindText(statement, index: 2, value: thread.title)
        sqlite3_bind_double(statement, 3, thread.updatedAt.timeIntervalSince1970)
        bindText(statement, index: 4, value: thread.runID)
        bindText(statement, index: 5, value: thread.summaryText)
        bindText(statement, index: 6, value: thread.transcriptText)
        bindText(statement, index: 7, value: thread.statusText)
        bindText(statement, index: 8, value: thread.resolvedWorkingDirectory)
        bindText(statement, index: 9, value: thread.activeRunExecutor)
        _ = sqlite3_step(statement)
    }

    func upsertMessage(threadID: UUID, message: ConversationMessage, position: Int) {
        guard let db = openConnection() else { return }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO thread_messages (thread_id, position, message_id, role, text)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(thread_id, position) DO UPDATE SET
            message_id=excluded.message_id,
            role=excluded.role,
            text=excluded.text
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: threadID.uuidString)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(position))
        bindText(statement, index: 3, value: message.id.uuidString)
        bindText(statement, index: 4, value: message.role)
        bindText(statement, index: 5, value: message.text)
        _ = sqlite3_step(statement)
    }

    func deleteThread(threadID: UUID) {
        guard let db = openConnection() else { return }
        defer { sqlite3_close(db) }
        let sql = "DELETE FROM threads WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: threadID.uuidString)
        _ = sqlite3_step(statement)
    }

    private func setupSchema() {
        guard let db = openConnection() else { return }
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE IF NOT EXISTS threads (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            updated_at REAL NOT NULL,
            run_id TEXT NOT NULL,
            summary_text TEXT NOT NULL,
            transcript_text TEXT NOT NULL,
            status_text TEXT NOT NULL,
            resolved_working_directory TEXT NOT NULL,
            active_run_executor TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS thread_messages (
            thread_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            message_id TEXT NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            PRIMARY KEY (thread_id, position),
            FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_thread_messages_thread ON thread_messages(thread_id, position);
        """
        _ = sqlite3_exec(db, schema, nil, nil, nil)
    }

    private func openConnection() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            if let db {
                sqlite3_close(db)
            }
            return nil
        }
        _ = sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        return db
    }

    private func bindText(_ statement: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: raw)
    }
}

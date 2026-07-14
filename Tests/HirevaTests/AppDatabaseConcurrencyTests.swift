import Foundation
import GRDB
import Testing
@testable import Hireva

@Suite(.serialized)
struct AppDatabaseConcurrencyTests {
    @Test
    func shortExternalReadLockDoesNotDropAppWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaDatabaseLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let database = try AppDatabase(path: databaseURL)
        let externalReader = try DatabaseQueue(path: databaseURL.path)
        defer {
            try? externalReader.close()
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }

        let configuredBusyTimeout = try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA busy_timeout")
        }
        #expect(configuredBusyTimeout == 5_000)

        let readerLocked = DispatchSemaphore(value: 0)
        let releaseReader = DispatchSemaphore(value: 0)
        let readerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { readerFinished.signal() }
            try? externalReader.read { db in
                _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents")
                readerLocked.signal()
                releaseReader.wait()
            }
        }

        #expect(readerLocked.wait(timeout: .now() + 2.0) == .success)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25) {
            releaseReader.signal()
        }

        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO documents (id, type, title, content, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["locked-write", "resume", "Lock test", "Evidence", "2026-07-14", "2026-07-14"]
            )
        }

        #expect(readerFinished.wait(timeout: .now() + 2.0) == .success)
        let persistedCount = try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents WHERE id = ?", arguments: ["locked-write"])
        }
        #expect(persistedCount == 1)
    }
}

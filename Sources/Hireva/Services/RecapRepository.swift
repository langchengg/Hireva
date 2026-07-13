import Foundation
import GRDB

final class RecapRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func saveRecap(_ recap: RecapReport) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO recap_reports (
                    id, session_id, markdown, model_name, prompt_version, provider_kind,
                    provider_name, provider_base_url, latency_ms, is_local, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    recap.id,
                    recap.sessionID,
                    recap.markdown,
                    recap.modelName,
                    recap.promptVersion,
                    recap.providerKind?.rawValue,
                    recap.providerName,
                    recap.providerBaseURL,
                    recap.latencyMS,
                    recap.isLocal,
                    DateCoding.string(from: recap.createdAt)
                ]
            )
        }
    }

    func recap(sessionID: String) throws -> RecapReport? {
        try database.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM recap_reports WHERE session_id = ? ORDER BY created_at DESC LIMIT 1",
                arguments: [sessionID]
            )
            return row.map(Self.makeRecap)
        }
    }

    func exportMarkdown(recap: RecapReport, sessionTitle: String) throws -> URL {
        try AppPaths.ensureDirectoriesExist()
        let safeTitle = sessionTitle
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let filename = "\(safeTitle.isEmpty ? "interview-recap" : safeTitle)-\(recap.id.prefix(8)).md"
        let url = AppPaths.exportsDirectory.appendingPathComponent(filename)
        try recap.markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func makeRecap(row: Row) -> RecapReport {
        RecapReport(
            id: row["id"],
            sessionID: row["session_id"],
            markdown: row["markdown"],
            modelName: row["model_name"],
            promptVersion: row["prompt_version"],
            providerKind: (row["provider_kind"] as String?).flatMap(LLMProviderKind.init(rawValue:)),
            providerName: row["provider_name"],
            providerBaseURL: row["provider_base_url"],
            latencyMS: row["latency_ms"],
            isLocal: row["is_local"],
            createdAt: DateCoding.date(from: row["created_at"])
        )
    }
}

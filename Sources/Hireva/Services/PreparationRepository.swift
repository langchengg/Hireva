import Foundation
import GRDB

struct PreparationRecord: Identifiable, Codable {
    var id: String
    var kind: String
    var createdAt: Date
    var payload: Data
}
struct PreparationRepository {
    let database: AppDatabase
    func save<T: Encodable>(_ value: T, kind: String) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO preparation_records(id, kind, created_at, payload_json) VALUES (?, ?, ?, ?)", arguments: [UUID().uuidString, kind, DateCoding.string(from: Date()), try JSONEncoder().encode(value)])
        }
    }
    func saveStory(_ draft: StoryDraft) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO preparation_records(id,kind,created_at,payload_json) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload_json=excluded.payload_json", arguments: [draft.id, "story-draft", DateCoding.string(from: Date()), try JSONEncoder().encode(draft)])
        }
    }
    func records() throws -> [PreparationRecord] {
        try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM preparation_records ORDER BY created_at DESC").map { .init(id: $0["id"], kind: $0["kind"], createdAt: DateCoding.date(from: $0["created_at"]), payload: $0["payload_json"]) }
        }
    }
    func delete(_ id: String) throws { try database.dbQueue.write { try $0.execute(sql: "DELETE FROM preparation_records WHERE id = ?", arguments: [id]) } }
}

enum StaticCodeReview {
    static func notes(_ code: String) -> [String] {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ["Add code to inspect."] }
        var notes = ["Static checklist only; code has NOT executed or compiled.", "Confirm input/output, constraints, algorithm, complexity and boundary tests."]
        if code.contains("TODO") || code.contains("pass") { notes.append("Possible placeholder detected. Check completeness.") }
        if code.contains("while true") || code.contains("while True") { notes.append("Check loop termination and resource limits.") }
        if code.contains("eval(") || code.contains("exec(") || code.contains("os.system") { notes.append("Dynamic execution detected; review untrusted input boundaries.") }
        notes.append("Independent tests should include empty input, duplicates, maximum size, negative values and invalid input where applicable. Generated tests alone do not prove correctness.")
        return notes
    }
}

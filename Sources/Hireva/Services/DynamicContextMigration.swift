import Foundation
import GRDB

enum DynamicContextMigration {
    static func migrate(_ db: Database) throws {
        try db.create(table: "candidate_profiles", ifNotExists: true) { table in
            table.column("id", .text).primaryKey()
            table.column("display_name", .text)
            table.column("version", .integer).notNull()
            table.column("source_document_ids_json", .text).notNull()
            table.column("payload_json", .blob).notNull()
            table.column("updated_at", .text).notNull().indexed()
        }

        try db.create(table: "opportunity_contexts", ifNotExists: true) { table in
            table.column("id", .text).primaryKey()
            table.column("title", .text)
            table.column("organisation", .text)
            table.column("opportunity_type", .text).notNull()
            table.column("version", .integer).notNull()
            table.column("source_document_ids_json", .text).notNull()
            table.column("payload_json", .blob).notNull()
            table.column("updated_at", .text).notNull().indexed()
        }

        try db.create(table: "interview_context_snapshots", ifNotExists: true) { table in
            table.column("id", .text).primaryKey()
            table.column("session_id", .text).notNull().indexed().references("interview_sessions", onDelete: .cascade)
            table.column("candidate_profile_id", .text).references("candidate_profiles", onDelete: .setNull)
            table.column("candidate_profile_version", .integer)
            table.column("opportunity_context_id", .text).references("opportunity_contexts", onDelete: .setNull)
            table.column("opportunity_context_version", .integer)
            table.column("domain_profile_id", .text).notNull()
            table.column("payload_json", .blob).notNull()
            table.column("created_at", .text).notNull().indexed()
        }

        try addColumn("profile_id", definition: "TEXT REFERENCES candidate_profiles(id) ON DELETE SET NULL", table: "documents", db: db)
        try addColumn("opportunity_context_id", definition: "TEXT REFERENCES opportunity_contexts(id) ON DELETE SET NULL", table: "documents", db: db)
        try addColumn("document_classification", definition: "TEXT", table: "documents", db: db)
        try addColumn("source_format", definition: "TEXT", table: "documents", db: db)
        try addColumn("content_hash", definition: "TEXT", table: "documents", db: db)
        try addColumn("context_snapshot_id", definition: "TEXT REFERENCES interview_context_snapshots(id) ON DELETE SET NULL", table: "interview_sessions", db: db)

        let suggestionColumns: [(String, String)] = [
            ("context_snapshot_id", "TEXT REFERENCES interview_context_snapshots(id) ON DELETE SET NULL"),
            ("candidate_profile_id", "TEXT"),
            ("candidate_profile_version", "INTEGER"),
            ("opportunity_context_id", "TEXT"),
            ("opportunity_context_version", "INTEGER"),
            ("domain_profile_id", "TEXT"),
            ("candidate_evidence_ids_json", "TEXT"),
            ("opportunity_evidence_ids_json", "TEXT"),
            ("grounding_decision", "TEXT"),
            ("unsupported_claim_count", "INTEGER"),
            ("context_isolation_status", "TEXT")
        ]
        for (name, definition) in suggestionColumns {
            try addColumn(name, definition: definition, table: "suggestion_cards", db: db)
        }

        try migrateLegacyDocumentsIfNeeded(db)
    }

    private static func addColumn(_ name: String, definition: String, table: String, db: Database) throws {
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            .compactMap { $0["name"] as? String }
        guard !columns.contains(name) else { return }
        try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(name) \(definition)")
    }

    private static func migrateLegacyDocumentsIfNeeded(_ db: Database) throws {
        let existingProfiles = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM candidate_profiles") ?? 0
        let existingOpportunities = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM opportunity_contexts") ?? 0
        let documentRows = try Row.fetchAll(db, sql: "SELECT id, type, title, updated_at FROM documents ORDER BY updated_at ASC")
        guard !documentRows.isEmpty else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let now = Date()
        var migratedProfile: CandidateProfile?
        var migratedOpportunity: OpportunityContext?

        if existingProfiles == 0 {
            let resumeRows = documentRows.filter { ($0["type"] as String) == DocumentType.cv.rawValue || ($0["type"] as String) == DocumentType.additionalNotes.rawValue }
            if !resumeRows.isEmpty {
                let documentIDs = resumeRows.map { $0["id"] as String }
                let evidence = try legacyEvidence(db: db, documentIDs: documentIDs, type: .other)
                let profile = CandidateProfile(
                    id: "migrated-candidate-\(UUID().uuidString)",
                    displayName: "Migrated Candidate Profile",
                    sourceDocumentIDs: documentIDs,
                    education: [],
                    experience: evidence,
                    projects: [],
                    skills: [],
                    publications: [],
                    achievements: [],
                    declaredGaps: [],
                    goals: [],
                    generatedSummary: nil,
                    version: 1,
                    updatedAt: now
                )
                migratedProfile = profile
                try insertProfile(profile, encoder: encoder, db: db)
                try db.execute(
                    sql: "UPDATE documents SET profile_id = ?, document_classification = CASE WHEN type = 'cv' THEN 'resume' ELSE 'interview_notes' END, source_format = 'pasted_text' WHERE id IN (\(placeholders(documentIDs.count)))",
                    arguments: StatementArguments([profile.id] + documentIDs)
                )
            }
        }

        if existingOpportunities == 0 {
            let opportunityRows = documentRows.filter { ($0["type"] as String) == DocumentType.jobDescription.rawValue }
            if !opportunityRows.isEmpty {
                let documentIDs = opportunityRows.map { $0["id"] as String }
                let evidence = try legacyEvidence(db: db, documentIDs: documentIDs, type: .responsibility)
                let opportunity = OpportunityContext(
                    id: "migrated-opportunity-\(UUID().uuidString)",
                    title: opportunityRows.last?["title"],
                    organisation: nil,
                    opportunityType: .general,
                    responsibilities: evidence,
                    requiredSkills: [],
                    preferredSkills: [],
                    researchTopics: [],
                    evaluationCriteria: [],
                    sourceDocumentIDs: documentIDs,
                    version: 1,
                    updatedAt: now
                )
                migratedOpportunity = opportunity
                try insertOpportunity(opportunity, encoder: encoder, db: db)
                try db.execute(
                    sql: "UPDATE documents SET opportunity_context_id = ?, document_classification = 'job_description', source_format = 'pasted_text' WHERE id IN (\(placeholders(documentIDs.count)))",
                    arguments: StatementArguments([opportunity.id] + documentIDs)
                )
            }
        }

        guard migratedProfile != nil || migratedOpportunity != nil else { return }
        let domainID = try migratedDomainID(db)
        let sessions = try String.fetchAll(db, sql: "SELECT id FROM interview_sessions WHERE context_snapshot_id IS NULL")
        for sessionID in sessions {
            let snapshot = InterviewContextSnapshot(
                id: UUID().uuidString,
                sessionID: sessionID,
                candidateProfileID: migratedProfile?.id,
                candidateProfileVersion: migratedProfile?.version,
                opportunityContextID: migratedOpportunity?.id,
                opportunityContextVersion: migratedOpportunity?.version,
                domainProfileID: domainID,
                candidateEvidence: migratedProfile?.allEvidence ?? [],
                opportunityEvidence: migratedOpportunity?.allEvidence ?? [],
                createdAt: now
            )
            try db.execute(
                sql: """
                INSERT INTO interview_context_snapshots (
                    id, session_id, candidate_profile_id, candidate_profile_version,
                    opportunity_context_id, opportunity_context_version, domain_profile_id,
                    payload_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    snapshot.id, snapshot.sessionID, snapshot.candidateProfileID, snapshot.candidateProfileVersion,
                    snapshot.opportunityContextID, snapshot.opportunityContextVersion, snapshot.domainProfileID,
                    try encoder.encode(snapshot), DateCoding.string(from: now)
                ]
            )
            try db.execute(sql: "UPDATE interview_sessions SET context_snapshot_id = ? WHERE id = ?", arguments: [snapshot.id, sessionID])
            try db.execute(
                sql: """
                UPDATE suggestion_cards
                SET context_snapshot_id = ?, candidate_profile_id = ?, candidate_profile_version = ?,
                    opportunity_context_id = ?, opportunity_context_version = ?, domain_profile_id = ?,
                    context_isolation_status = 'migrated_history'
                WHERE session_id = ? AND context_snapshot_id IS NULL
                """,
                arguments: [
                    snapshot.id, snapshot.candidateProfileID, snapshot.candidateProfileVersion,
                    snapshot.opportunityContextID, snapshot.opportunityContextVersion, snapshot.domainProfileID,
                    sessionID
                ]
            )
        }
    }

    private static func legacyEvidence(db: Database, documentIDs: [String], type: EvidenceType) throws -> [ProfileEvidence] {
        guard !documentIDs.isEmpty else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, document_id, content FROM document_chunks WHERE document_id IN (\(placeholders(documentIDs.count))) ORDER BY document_id, chunk_index",
            arguments: StatementArguments(documentIDs)
        )
        return rows.map { row in
            let content: String = row["content"]
            return ProfileEvidence(
                id: "migrated-evidence-\(row["id"] as String)",
                statement: content,
                sourceDocumentID: row["document_id"],
                sourceChunkID: row["id"],
                sourceSpan: String(content.prefix(240)),
                confidence: 0.5,
                evidenceType: type,
                explicitness: .inferred
            )
        }
    }

    private static func insertProfile(_ profile: CandidateProfile, encoder: JSONEncoder, db: Database) throws {
        try db.execute(
            sql: "INSERT INTO candidate_profiles (id, display_name, version, source_document_ids_json, payload_json, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [
                profile.id, profile.displayName, profile.version,
                String(decoding: try encoder.encode(profile.sourceDocumentIDs), as: UTF8.self),
                try encoder.encode(profile), DateCoding.string(from: profile.updatedAt)
            ]
        )
    }

    private static func insertOpportunity(_ opportunity: OpportunityContext, encoder: JSONEncoder, db: Database) throws {
        try db.execute(
            sql: "INSERT INTO opportunity_contexts (id, title, organisation, opportunity_type, version, source_document_ids_json, payload_json, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            arguments: [
                opportunity.id, opportunity.title, opportunity.organisation, opportunity.opportunityType.rawValue,
                opportunity.version,
                String(decoding: try encoder.encode(opportunity.sourceDocumentIDs), as: UTF8.self),
                try encoder.encode(opportunity), DateCoding.string(from: opportunity.updatedAt)
            ]
        )
    }

    private static func migratedDomainID(_ db: Database) throws -> String {
        let stored = try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?", arguments: [DialogueSettingsStore.contextModeKey])
        return stored == InterviewContextMode.phdRobotics.rawValue
            ? InterviewDomainID.roboticsResearch.rawValue
            : InterviewDomainID.general.rawValue
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}

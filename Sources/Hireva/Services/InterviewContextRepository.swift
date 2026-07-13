import Foundation
import GRDB

final class InterviewContextRepository {
    private enum SelectionKey {
        static let candidate = "context.active_candidate_profile_id"
        static let opportunity = "context.active_opportunity_context_id"
        static let domain = "context.active_domain_profile_id"
        static let origin = "context.configuration_origin"
    }
    private let database: AppDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(database: AppDatabase) {
        self.database = database
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func saveCandidateProfile(_ profile: CandidateProfile) throws {
        let payload = try encoder.encode(profile)
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO candidate_profiles (id, display_name, version, source_document_ids_json, payload_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    version = excluded.version,
                    source_document_ids_json = excluded.source_document_ids_json,
                    payload_json = excluded.payload_json,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    profile.id,
                    profile.displayName,
                    profile.version,
                    try jsonString(profile.sourceDocumentIDs),
                    payload,
                    DateCoding.string(from: profile.updatedAt)
                ]
            )
        }
    }

    func candidateProfiles() throws -> [CandidateProfile] {
        try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT payload_json FROM candidate_profiles ORDER BY updated_at DESC")
                .map { row in try decoder.decode(CandidateProfile.self, from: row["payload_json"] as Data) }
        }
    }

    func candidateProfile(id: String) throws -> CandidateProfile? {
        try database.dbQueue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload_json FROM candidate_profiles WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return try decoder.decode(CandidateProfile.self, from: data)
        }
    }

    func saveOpportunityContext(_ context: OpportunityContext) throws {
        let payload = try encoder.encode(context)
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO opportunity_contexts (id, title, organisation, opportunity_type, version, source_document_ids_json, payload_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    organisation = excluded.organisation,
                    opportunity_type = excluded.opportunity_type,
                    version = excluded.version,
                    source_document_ids_json = excluded.source_document_ids_json,
                    payload_json = excluded.payload_json,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    context.id,
                    context.title,
                    context.organisation,
                    context.opportunityType.rawValue,
                    context.version,
                    try jsonString(context.sourceDocumentIDs),
                    payload,
                    DateCoding.string(from: context.updatedAt)
                ]
            )
        }
    }

    func opportunityContexts() throws -> [OpportunityContext] {
        try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT payload_json FROM opportunity_contexts ORDER BY updated_at DESC")
                .map { row in try decoder.decode(OpportunityContext.self, from: row["payload_json"] as Data) }
        }
    }

    func opportunityContext(id: String) throws -> OpportunityContext? {
        try database.dbQueue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload_json FROM opportunity_contexts WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return try decoder.decode(OpportunityContext.self, from: data)
        }
    }

    func updateEvidenceExplicitness(evidenceID: String, explicitness: EvidenceExplicitness) throws {
        for var profile in try candidateProfiles() where profile.updateEvidence(id: evidenceID, explicitness: explicitness) {
            try saveCandidateProfile(profile)
            return
        }
        for var opportunity in try opportunityContexts() where opportunity.updateEvidence(id: evidenceID, explicitness: explicitness) {
            try saveOpportunityContext(opportunity)
            return
        }
    }

    func updateEvidenceStatement(evidenceID: String, statement: String) throws {
        let clean = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        for var profile in try candidateProfiles() {
            if profile.updateEvidenceStatement(id: evidenceID, statement: clean) {
                try saveCandidateProfile(profile)
                return
            }
        }
        for var opportunity in try opportunityContexts() {
            if opportunity.updateEvidenceStatement(id: evidenceID, statement: clean) {
                try saveOpportunityContext(opportunity)
                return
            }
        }
    }

    func loadSelection() throws -> InterviewContextSelection {
        try database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT key, value FROM app_settings WHERE key IN (?, ?, ?)",
                arguments: [SelectionKey.candidate, SelectionKey.opportunity, SelectionKey.domain]
            )
            let values = Dictionary(uniqueKeysWithValues: rows.map { ($0["key"] as String, $0["value"] as String) })
            return InterviewContextSelection(
                candidateProfileID: values[SelectionKey.candidate].flatMap { $0.isEmpty ? nil : $0 },
                opportunityContextID: values[SelectionKey.opportunity].flatMap { $0.isEmpty ? nil : $0 },
                domainProfileID: values[SelectionKey.domain].flatMap(InterviewDomainID.init(rawValue:)) ?? .general
            )
        }
    }

    func saveSelection(_ selection: InterviewContextSelection) throws {
        let values: [(String, String)] = [
            (SelectionKey.candidate, selection.candidateProfileID ?? ""),
            (SelectionKey.opportunity, selection.opportunityContextID ?? ""),
            (SelectionKey.domain, selection.domainProfileID.rawValue)
        ]
        try database.dbQueue.write { db in
            for (key, value) in values {
                try db.execute(
                    sql: """
                    INSERT INTO app_settings (key, value, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                    """,
                    arguments: [key, value, DateCoding.string(from: Date())]
                )
            }
        }
    }

    func loadConfigurationOrigin() throws -> ContextConfigurationOrigin? {
        try database.dbQueue.read { db in
            let value = try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?", arguments: [SelectionKey.origin])
            return value.flatMap(ContextConfigurationOrigin.init(rawValue:))
        }
    }

    func saveConfigurationOrigin(_ origin: ContextConfigurationOrigin) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO app_settings (key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """,
                arguments: [SelectionKey.origin, origin.rawValue, DateCoding.string(from: Date())]
            )
        }
    }

    func upsertCandidateDocument(
        documentID: String,
        title: String,
        content: String,
        profileID: String?,
        persistedChunks: [DocumentChunk] = []
    ) throws -> CandidateProfile {
        let extractor = StructuredEvidenceExtractor()
        let extraction = extractor.extract(
            documentID: documentID,
            classification: .resume,
            content: content,
            persistedChunks: persistedChunks
        )
        var profile = try profileID.flatMap(candidateProfile(id:)) ?? CandidateProfile(
            id: UUID().uuidString,
            displayName: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Candidate Profile" : title,
            sourceDocumentIDs: [],
            education: [], experience: [], projects: [], skills: [], publications: [], achievements: [], declaredGaps: [], goals: [],
            generatedSummary: nil,
            version: 0,
            updatedAt: Date()
        )
        profile.removeEvidence(sourceDocumentID: documentID)
        profile.sourceDocumentIDs = Array(Set(profile.sourceDocumentIDs + [documentID])).sorted()
        for evidence in extraction.candidateEvidence {
            profile.append(evidence)
        }
        profile.version += 1
        profile.updatedAt = Date()
        try saveCandidateProfile(profile)
        try associateDocument(
            documentID: documentID,
            profileID: profile.id,
            opportunityID: nil,
            classification: .resume,
            contentHash: extraction.documentHash
        )
        return profile
    }

    func upsertOpportunityDocument(
        documentID: String,
        title: String,
        content: String,
        opportunityID: String?,
        persistedChunks: [DocumentChunk] = []
    ) throws -> OpportunityContext {
        let extractor = StructuredEvidenceExtractor()
        let extraction = extractor.extract(
            documentID: documentID,
            classification: .jobDescription,
            content: content,
            persistedChunks: persistedChunks
        )
        var opportunity = try opportunityID.flatMap(opportunityContext(id:)) ?? OpportunityContext(
            id: UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Target Opportunity" : title,
            organisation: nil,
            opportunityType: .job,
            responsibilities: [], requiredSkills: [], preferredSkills: [], researchTopics: [], evaluationCriteria: [],
            sourceDocumentIDs: [],
            version: 0,
            updatedAt: Date()
        )
        opportunity.removeEvidence(sourceDocumentID: documentID)
        opportunity.sourceDocumentIDs = Array(Set(opportunity.sourceDocumentIDs + [documentID])).sorted()
        for evidence in extraction.opportunityEvidence {
            opportunity.append(evidence)
        }
        opportunity.version += 1
        opportunity.updatedAt = Date()
        try saveOpportunityContext(opportunity)
        try associateDocument(
            documentID: documentID,
            profileID: nil,
            opportunityID: opportunity.id,
            classification: .jobDescription,
            contentHash: extraction.documentHash
        )
        return opportunity
    }

    func associateDocument(
        documentID: String,
        profileID: String?,
        opportunityID: String?,
        classification: DocumentClassification,
        contentHash: String
    ) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE documents
                SET profile_id = ?, opportunity_context_id = ?, document_classification = ?,
                    source_format = ?, content_hash = ?
                WHERE id = ?
                """,
                arguments: [
                    profileID, opportunityID, classification.rawValue,
                    DocumentSourceFormat.pastedText.rawValue, contentHash, documentID
                ]
            )
        }
    }

    func createSnapshot(
        sessionID: String,
        candidateProfileID: String?,
        opportunityContextID: String?,
        domainProfileID: String
    ) throws -> InterviewContextSnapshot {
        try database.dbQueue.write { db in
            let selection = InterviewContextSelection(
                candidateProfileID: candidateProfileID,
                opportunityContextID: opportunityContextID,
                domainProfileID: InterviewDomainID(rawValue: domainProfileID) ?? .general
            )
            let snapshot = try Self.makeSnapshot(db: db, sessionID: sessionID, selection: selection)
            try Self.insertSnapshot(snapshot, db: db)
            return snapshot
        }
    }

    func snapshot(id: String) throws -> InterviewContextSnapshot? {
        try database.dbQueue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload_json FROM interview_context_snapshots WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return try decoder.decode(InterviewContextSnapshot.self, from: data)
        }
    }

    func snapshots(sessionID: String) throws -> [InterviewContextSnapshot] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT payload_json FROM interview_context_snapshots WHERE session_id = ? ORDER BY created_at ASC",
                arguments: [sessionID]
            ).map { row in try decoder.decode(InterviewContextSnapshot.self, from: row["payload_json"] as Data) }
        }
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func makeSnapshot(
        db: Database,
        sessionID: String,
        selection: InterviewContextSelection
    ) throws -> InterviewContextSnapshot {
        let decoder = makeDecoder()
        let profile: CandidateProfile? = try selection.candidateProfileID.flatMap { id in
            guard let payload = try Data.fetchOne(db, sql: "SELECT payload_json FROM candidate_profiles WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return try decoder.decode(CandidateProfile.self, from: payload)
        }
        let opportunity: OpportunityContext? = try selection.opportunityContextID.flatMap { id in
            guard let payload = try Data.fetchOne(db, sql: "SELECT payload_json FROM opportunity_contexts WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return try decoder.decode(OpportunityContext.self, from: payload)
        }
        return InterviewContextSnapshot(
            id: UUID().uuidString,
            sessionID: sessionID,
            candidateProfileID: profile?.id,
            candidateProfileVersion: profile?.version,
            opportunityContextID: opportunity?.id,
            opportunityContextVersion: opportunity?.version,
            domainProfileID: selection.domainProfileID.rawValue,
            candidateEvidence: profile?.allEvidence ?? [],
            opportunityEvidence: opportunity?.allEvidence ?? [],
            createdAt: Date()
        )
    }

    static func insertSnapshot(_ snapshot: InterviewContextSnapshot, db: Database) throws {
        let encoder = makeEncoder()
        try db.execute(
            sql: """
            INSERT INTO interview_context_snapshots (
                id, session_id, candidate_profile_id, candidate_profile_version,
                opportunity_context_id, opportunity_context_version, domain_profile_id,
                payload_json, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                snapshot.id,
                snapshot.sessionID,
                snapshot.candidateProfileID,
                snapshot.candidateProfileVersion,
                snapshot.opportunityContextID,
                snapshot.opportunityContextVersion,
                snapshot.domainProfileID,
                try encoder.encode(snapshot),
                DateCoding.string(from: snapshot.createdAt)
            ]
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension CandidateProfile {
    mutating func removeEvidence(sourceDocumentID: String) {
        education.removeAll { $0.sourceDocumentID == sourceDocumentID }
        experience.removeAll { $0.sourceDocumentID == sourceDocumentID }
        projects.removeAll { $0.sourceDocumentID == sourceDocumentID }
        skills.removeAll { $0.sourceDocumentID == sourceDocumentID }
        publications.removeAll { $0.sourceDocumentID == sourceDocumentID }
        achievements.removeAll { $0.sourceDocumentID == sourceDocumentID }
        declaredGaps.removeAll { $0.sourceDocumentID == sourceDocumentID }
        goals.removeAll { $0.sourceDocumentID == sourceDocumentID }
    }

    mutating func append(_ evidence: ProfileEvidence) {
        switch evidence.evidenceType {
        case .education: education.append(evidence)
        case .experience, .other: experience.append(evidence)
        case .project: projects.append(evidence)
        case .skill: skills.append(evidence)
        case .publication: publications.append(evidence)
        case .achievement: achievements.append(evidence)
        case .declaredGap: declaredGaps.append(evidence)
        case .goal: goals.append(evidence)
        case .responsibility, .requiredSkill, .preferredSkill, .researchTopic, .evaluationCriterion: break
        }
    }

    mutating func updateEvidenceStatement(id evidenceID: String, statement: String) -> Bool {
        let keyPaths: [WritableKeyPath<CandidateProfile, [ProfileEvidence]>] = [
            \CandidateProfile.education, \CandidateProfile.experience, \CandidateProfile.projects,
            \CandidateProfile.skills, \CandidateProfile.publications, \CandidateProfile.achievements,
            \CandidateProfile.declaredGaps, \CandidateProfile.goals
        ]
        for keyPath in keyPaths {
            guard let index = self[keyPath: keyPath].firstIndex(where: { $0.id == evidenceID }) else { continue }
            self[keyPath: keyPath][index].statement = statement
            self[keyPath: keyPath][index].sourceSpan = nil
            self[keyPath: keyPath][index].explicitness = .userConfirmed
            version += 1
            updatedAt = Date()
            return true
        }
        return false
    }
}

private extension OpportunityContext {
    mutating func removeEvidence(sourceDocumentID: String) {
        responsibilities.removeAll { $0.sourceDocumentID == sourceDocumentID }
        requiredSkills.removeAll { $0.sourceDocumentID == sourceDocumentID }
        preferredSkills.removeAll { $0.sourceDocumentID == sourceDocumentID }
        researchTopics.removeAll { $0.sourceDocumentID == sourceDocumentID }
        evaluationCriteria.removeAll { $0.sourceDocumentID == sourceDocumentID }
    }

    mutating func append(_ evidence: ProfileEvidence) {
        switch evidence.evidenceType {
        case .requiredSkill: requiredSkills.append(evidence)
        case .preferredSkill: preferredSkills.append(evidence)
        case .researchTopic: researchTopics.append(evidence)
        case .evaluationCriterion: evaluationCriteria.append(evidence)
        default: responsibilities.append(evidence)
        }
    }

    mutating func updateEvidenceStatement(id evidenceID: String, statement: String) -> Bool {
        let keyPaths: [WritableKeyPath<OpportunityContext, [ProfileEvidence]>] = [
            \OpportunityContext.responsibilities, \OpportunityContext.requiredSkills,
            \OpportunityContext.preferredSkills, \OpportunityContext.researchTopics,
            \OpportunityContext.evaluationCriteria
        ]
        for keyPath in keyPaths {
            guard let index = self[keyPath: keyPath].firstIndex(where: { $0.id == evidenceID }) else { continue }
            self[keyPath: keyPath][index].statement = statement
            self[keyPath: keyPath][index].sourceSpan = nil
            self[keyPath: keyPath][index].explicitness = .userConfirmed
            version += 1
            updatedAt = Date()
            return true
        }
        return false
    }
}

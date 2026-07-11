import Foundation

enum InterviewDocumentType: String, Codable, CaseIterable, Hashable {
    case resume
    case jobDescription = "job_description"
    case phdProjectDescription = "phd_project_description"
    case researchProposal = "research_proposal"
    case coverLetter = "cover_letter"
    case portfolio
    case interviewNotes = "interview_notes"
    case other

    var documentClassification: DocumentClassification {
        DocumentClassification(rawValue: rawValue) ?? .other
    }

    var isCandidateSource: Bool { documentClassification.isCandidateSource }
    var isOpportunitySource: Bool { documentClassification.isOpportunitySource }
}

struct InterviewDocumentClassification: Codable, Equatable, Hashable, Identifiable {
    var id: String { documentID }
    var documentID: String
    var type: InterviewDocumentType
    var confidence: Double
    var reason: String
}

struct DomainCandidate: Codable, Equatable, Hashable, Identifiable {
    var id: String { domainID.rawValue }
    var domainID: InterviewDomainID
    var displayName: String
    var confidence: Double
}

struct InferredInterviewDomain: Codable, Equatable, Hashable {
    var domainID: InterviewDomainID
    var displayName: String
    var confidence: Double
    var evidenceIDs: [String]
    var alternatives: [DomainCandidate]

    var confidenceLabel: String {
        if confidence >= 0.78 { return "High" }
        if confidence >= 0.58 { return "Medium" }
        return "Low"
    }
}

enum AutomaticContextReadiness: String, Codable, Equatable, Hashable {
    case noDocuments = "no_documents"
    case extracting
    case needsReview = "needs_review"
    case ready
    case failed
}

enum ContextConfigurationOrigin: String, Codable, Equatable, Hashable {
    case automaticDocuments = "automatic_documents"
    case legacyManualContext = "legacy_manual_context"
}

enum ContextBuildWarningCode: String, Codable, Equatable, Hashable {
    case candidateDocumentMissing = "candidate_document_missing"
    case opportunityDocumentMissing = "opportunity_document_missing"
    case lowClassificationConfidence = "low_classification_confidence"
    case lowDomainConfidence = "low_domain_confidence"
    case conflictingEvidence = "conflicting_evidence"
    case promptInjectionIgnored = "prompt_injection_ignored"
    case localLLMFallback = "local_llm_fallback"
    case emptyExtraction = "empty_extraction"
}

struct ContextBuildWarning: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var code: ContextBuildWarningCode
    var message: String
    var documentID: String?
}

struct ContextEvidenceSummary: Codable, Equatable, Hashable {
    var candidateFactCount: Int
    var opportunityRequirementCount: Int
    var uncertainFactCount: Int
    var conflictCount: Int
    var candidateSourceTitles: [String]
    var opportunitySourceTitles: [String]
}

struct AutomaticContextBuildMetrics: Codable, Equatable, Hashable {
    var profileExtractionMS: Int
    var opportunityExtractionMS: Int
    var domainInferenceMS: Int
    var promptCharacterCount: Int
    var usedLocalQwen: Bool
    var extractionCacheHitCount: Int
}

struct InterviewContextBuildResult: Equatable {
    var candidateProfile: CandidateProfile?
    var opportunityContext: OpportunityContext?
    var inferredDomain: InferredInterviewDomain
    var readiness: AutomaticContextReadiness
    var warnings: [ContextBuildWarning]
    var evidenceSummary: ContextEvidenceSummary
    var classifications: [InterviewDocumentClassification]
    var metrics: AutomaticContextBuildMetrics
}

protocol InterviewContextBuilding {
    func buildContext(
        from documents: [DocumentRecord],
        previousConfirmedProfile: CandidateProfile?
    ) async throws -> InterviewContextBuildResult
}

enum ProductionContextPolicy {
    private static let knownFixtureIDs = [
        "robotics_phd_candidate_profile",
        "backend_candidate_profile",
        "data_scientist_candidate_profile",
        "product_manager_candidate_profile",
        "cybersecurity_candidate_profile",
        "biomedical_candidate_profile"
    ]

    static func isSyntheticProfile(_ profile: CandidateProfile) -> Bool {
        isSynthetic(id: profile.id, name: profile.displayName)
    }

    static func isSyntheticOpportunity(_ opportunity: OpportunityContext) -> Bool {
        isSynthetic(id: opportunity.id, name: opportunity.title)
    }

    static func isSynthetic(id: String, name: String?) -> Bool {
        let normalizedID = id.lowercased()
        let normalizedName = name?.lowercased() ?? ""
        return normalizedID.hasPrefix("fixture-") ||
            knownFixtureIDs.contains(normalizedID) ||
            normalizedID.hasPrefix("synthetic-") ||
            normalizedName.hasPrefix("synthetic ")
    }

    static var isTestProcess: Bool {
        isRunningUnderTestOrAutomation()
    }
}

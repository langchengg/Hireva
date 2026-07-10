import Foundation

enum EvidenceExplicitness: String, Codable, CaseIterable, Hashable {
    case explicit
    case inferred
    case userConfirmed = "user_confirmed"
    case userRejected = "user_rejected"
}

enum EvidenceType: String, Codable, CaseIterable, Hashable {
    case education
    case experience
    case project
    case skill
    case publication
    case achievement
    case declaredGap = "declared_gap"
    case goal
    case responsibility
    case requiredSkill = "required_skill"
    case preferredSkill = "preferred_skill"
    case researchTopic = "research_topic"
    case evaluationCriterion = "evaluation_criterion"
    case other
}

struct ProfileEvidence: Codable, Identifiable, Hashable {
    var id: String
    var statement: String
    var sourceDocumentID: String?
    var sourceChunkID: String?
    var sourceSpan: String?
    var confidence: Double
    var evidenceType: EvidenceType
    var explicitness: EvidenceExplicitness

    var isUsable: Bool {
        explicitness != .userRejected && !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CandidateProfile: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String?
    var sourceDocumentIDs: [String]
    var education: [ProfileEvidence]
    var experience: [ProfileEvidence]
    var projects: [ProfileEvidence]
    var skills: [ProfileEvidence]
    var publications: [ProfileEvidence]
    var achievements: [ProfileEvidence]
    var declaredGaps: [ProfileEvidence]
    var goals: [ProfileEvidence]
    var generatedSummary: String?
    var version: Int
    var updatedAt: Date

    var allEvidence: [ProfileEvidence] {
        (education + experience + projects + skills + publications + achievements + declaredGaps + goals)
            .filter(\.isUsable)
    }

    mutating func updateEvidence(id evidenceID: String, explicitness: EvidenceExplicitness) -> Bool {
        let keyPaths: [WritableKeyPath<CandidateProfile, [ProfileEvidence]>] = [
            \CandidateProfile.education,
            \CandidateProfile.experience,
            \CandidateProfile.projects,
            \CandidateProfile.skills,
            \CandidateProfile.publications,
            \CandidateProfile.achievements,
            \CandidateProfile.declaredGaps,
            \CandidateProfile.goals
        ]
        for keyPath in keyPaths {
            guard let index = self[keyPath: keyPath].firstIndex(where: { $0.id == evidenceID }) else { continue }
            self[keyPath: keyPath][index].explicitness = explicitness
            version += 1
            updatedAt = Date()
            return true
        }
        return false
    }
}

enum OpportunityType: String, Codable, CaseIterable, Hashable {
    case job
    case phdProject = "phd_project"
    case researchPosition = "research_position"
    case internship
    case general
}

struct OpportunityContext: Codable, Identifiable, Hashable {
    var id: String
    var title: String?
    var organisation: String?
    var opportunityType: OpportunityType
    var responsibilities: [ProfileEvidence]
    var requiredSkills: [ProfileEvidence]
    var preferredSkills: [ProfileEvidence]
    var researchTopics: [ProfileEvidence]
    var evaluationCriteria: [ProfileEvidence]
    var sourceDocumentIDs: [String]
    var version: Int
    var updatedAt: Date

    var allEvidence: [ProfileEvidence] {
        (responsibilities + requiredSkills + preferredSkills + researchTopics + evaluationCriteria)
            .filter(\.isUsable)
    }

    mutating func updateEvidence(id evidenceID: String, explicitness: EvidenceExplicitness) -> Bool {
        let keyPaths: [WritableKeyPath<OpportunityContext, [ProfileEvidence]>] = [
            \OpportunityContext.responsibilities,
            \OpportunityContext.requiredSkills,
            \OpportunityContext.preferredSkills,
            \OpportunityContext.researchTopics,
            \OpportunityContext.evaluationCriteria
        ]
        for keyPath in keyPaths {
            guard let index = self[keyPath: keyPath].firstIndex(where: { $0.id == evidenceID }) else { continue }
            self[keyPath: keyPath][index].explicitness = explicitness
            version += 1
            updatedAt = Date()
            return true
        }
        return false
    }
}

enum InterviewDomainID: String, Codable, CaseIterable, Identifiable, Hashable {
    case general
    case softwareEngineering = "software_engineering"
    case dataScience = "data_science"
    case productManagement = "product_management"
    case academicPhD = "academic_phd"
    case roboticsResearch = "robotics_research"
    case finance
    case cybersecurity
    case healthcare

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: return "General"
        case .softwareEngineering: return "Software Engineering"
        case .dataScience: return "Data Science"
        case .productManagement: return "Product Management"
        case .academicPhD: return "Academic / PhD"
        case .roboticsResearch: return "Academic / Robotics"
        case .finance: return "Finance"
        case .cybersecurity: return "Cybersecurity"
        case .healthcare: return "Healthcare"
        }
    }
}

struct InterviewDomainProfile: Codable, Identifiable, Hashable {
    var id: InterviewDomainID
    var commonTerminology: [String]
    var answerQualityCriteria: [String]
    var domainKnowledge: [String]
    var honestyConstraints: [String]
    var preferredAnswerStructures: [String]

    static func profile(for id: InterviewDomainID) -> InterviewDomainProfile {
        let universalHonesty = [
            "Separate personal contribution from team work.",
            "Do not state a personal achievement without candidate evidence.",
            "Treat opportunity requirements as targets, not completed achievements."
        ]
        switch id {
        case .roboticsResearch:
            return InterviewDomainProfile(
                id: id,
                commonTerminology: ["perception", "control", "manipulation", "sensing"],
                answerQualityCriteria: ["methodological clarity", "failure analysis", "evidence-based claims"],
                domainKnowledge: ["Tactile sensing can provide force, contact, slip, and pressure feedback."],
                honestyConstraints: universalHonesty + ["Domain knowledge must not be presented as hands-on candidate experience."],
                preferredAnswerStructures: ["problem-method-evidence-limit", "claim-evidence-next-step"]
            )
        case .academicPhD:
            return InterviewDomainProfile(
                id: id,
                commonTerminology: ["research question", "methodology", "evaluation", "publication"],
                answerQualityCriteria: ["research motivation", "methodological quality", "factual restraint"],
                domainKnowledge: [],
                honestyConstraints: universalHonesty + ["Publication plans must remain conditional unless supported by evidence."],
                preferredAnswerStructures: ["research-gap-method-evaluation", "claim-evidence-limit"]
            )
        default:
            return InterviewDomainProfile(
                id: id,
                commonTerminology: [],
                answerQualityCriteria: ["question relevance", "candidate grounding", "speakability"],
                domainKnowledge: [],
                honestyConstraints: universalHonesty,
                preferredAnswerStructures: ["claim-evidence-relevance", "situation-action-result"]
            )
        }
    }
}

struct InterviewContextSnapshot: Codable, Identifiable, Hashable {
    var id: String
    var sessionID: String
    var candidateProfileID: String?
    var candidateProfileVersion: Int?
    var opportunityContextID: String?
    var opportunityContextVersion: Int?
    var domainProfileID: String
    var candidateEvidence: [ProfileEvidence]
    var opportunityEvidence: [ProfileEvidence]
    var createdAt: Date
}

struct InterviewContextSelection: Codable, Equatable, Hashable {
    var candidateProfileID: String?
    var opportunityContextID: String?
    var domainProfileID: InterviewDomainID
}

enum DocumentClassification: String, Codable, CaseIterable, Identifiable, Hashable {
    case resume
    case portfolio
    case jobDescription = "job_description"
    case phdProjectDescription = "phd_project_description"
    case researchProposal = "research_proposal"
    case coverLetter = "cover_letter"
    case interviewNotes = "interview_notes"
    case other

    var id: String { rawValue }

    var isCandidateSource: Bool {
        switch self {
        case .resume, .portfolio, .coverLetter, .interviewNotes: return true
        case .jobDescription, .phdProjectDescription, .researchProposal, .other: return false
        }
    }

    var isOpportunitySource: Bool {
        switch self {
        case .jobDescription, .phdProjectDescription, .researchProposal: return true
        case .resume, .portfolio, .coverLetter, .interviewNotes, .other: return false
        }
    }
}

enum DocumentSourceFormat: String, Codable, CaseIterable, Hashable {
    case pdf
    case docx
    case txt
    case markdown
    case pastedText = "pasted_text"
}

struct StructuredEvidenceExtraction: Codable, Equatable {
    var documentID: String
    var documentHash: String
    var classification: DocumentClassification
    var candidateEvidence: [ProfileEvidence]
    var opportunityEvidence: [ProfileEvidence]
    var uncertainCount: Int
}

enum ContextReadinessStatus: String, Codable, Equatable {
    case ready
    case needsReview = "needs_review"
    case missing
}

struct InterviewContextReadiness: Equatable {
    var status: ContextReadinessStatus
    var candidateFactCount: Int
    var opportunityRequirementCount: Int
    var uncertainFactCount: Int
    var declaredGapCount: Int
}

enum GroundedAnswerStatus: String, Codable, Equatable {
    case grounded
    case candidateEvidenceInsufficient = "candidate_evidence_insufficient"
    case candidateContextMissing = "candidate_context_missing"
}

struct GroundedFallbackResult: Equatable {
    var answer: String
    var status: GroundedAnswerStatus
    var candidateEvidenceIDs: [String]
    var opportunityEvidenceIDs: [String]
    var contextSnapshotID: String
    var groundingDecision: String
    var unsupportedClaims: [String]
}

struct AnswerGroundingDecision: Equatable {
    var unsupportedClaims: [String]
    var supportingCandidateEvidenceIDs: [String]
    var groundingDecision: String
}

struct SnapshotRetrievedContext: Equatable {
    var context: RetrievedContext
    var candidateEvidenceIDs: [String]
    var opportunityEvidenceIDs: [String]
}

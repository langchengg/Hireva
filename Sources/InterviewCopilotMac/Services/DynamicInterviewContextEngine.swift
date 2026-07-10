import Foundation

struct AnswerClaimValidator {
    func validate(
        answer: String,
        candidateEvidence: [ProfileEvidence],
        opportunityEvidence: [ProfileEvidence],
        domainKnowledge: [String]
    ) -> AnswerGroundingDecision {
        let usableCandidateEvidence = candidateEvidence.filter(\.isUsable)
        var unsupported: [String] = []
        var supportingIDs = Set<String>()

        for sentence in claimSentences(answer) where isPersonalClaim(sentence) {
            let claimTokens = meaningfulTokens(sentence)
            let metricTokens = numericTokens(sentence)
            let matches = usableCandidateEvidence.filter { evidence in
                let evidenceTokens = meaningfulTokens(evidence.statement)
                let shared = claimTokens.intersection(evidenceTokens)
                let enoughSemanticOverlap = shared.count >= min(3, max(1, claimTokens.count / 4))
                let metricsSupported = metricTokens.isEmpty || metricTokens.isSubset(of: numericTokens(evidence.statement))
                return enoughSemanticOverlap && metricsSupported
            }
            if matches.isEmpty {
                unsupported.append(sentence)
            } else {
                supportingIDs.formUnion(matches.map(\.id))
            }
        }

        return AnswerGroundingDecision(
            unsupportedClaims: unsupported,
            supportingCandidateEvidenceIDs: supportingIDs.sorted(),
            groundingDecision: unsupported.isEmpty ? "supported_by_candidate_evidence" : "unsupported_personal_claim"
        )
    }

    private func claimSentences(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func isPersonalClaim(_ sentence: String) -> Bool {
        let lower = " " + sentence.lowercased() + " "
        let firstPerson = [" i ", " i've ", " i’ve ", " my ", " we ", " our "].contains { lower.contains($0) }
        let claimVerb = [
            " built ", " developed ", " implemented ", " led ", " owned ", " managed ",
            " worked ", " used ", " designed ", " delivered ", " improved ", " reduced ",
            " completed ", " published ", " studied ", " controlled ", " operated ", " trained ",
            " evaluated ", " validated ", " tested ", " integrated ", " contributed ", " achieved ", " demonstrated ",
            " background ", " experience ", " evidence "
        ].contains { lower.contains($0) }
        let personalAsset = [" project ", " platform ", " degree ", " publication ", " pipeline ", " system ", " model "]
            .contains { lower.contains(" my" + $0) || lower.contains(" our" + $0) }
        return firstPerson && (claimVerb || personalAsset)
    }

    private func meaningfulTokens(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "and", "that", "with", "from", "this", "into", "for", "was", "were",
            "have", "has", "had", "my", "our", "their", "using", "used", "most", "relevant",
            "evidence", "selected", "profile", "project", "experience", "includes", "include"
        ]
        return Set(TextChunker.tokenize(text).filter { $0.count > 2 && !stopWords.contains($0) && Int($0) == nil })
    }

    private func numericTokens(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty })
    }
}

struct DynamicInterviewContextEngine {
    private let validator = AnswerClaimValidator()

    func profileSafeFallback(
        question: String,
        snapshot: InterviewContextSnapshot
    ) -> GroundedFallbackResult {
        let candidate = snapshot.candidateProfileID.map { profileID in
            CandidateProfile(
                id: profileID,
                displayName: nil,
                sourceDocumentIDs: Set(snapshot.candidateEvidence.compactMap(\.sourceDocumentID)).sorted(),
                education: evidence(of: .education, in: snapshot.candidateEvidence),
                experience: evidence(of: .experience, in: snapshot.candidateEvidence),
                projects: evidence(of: .project, in: snapshot.candidateEvidence),
                skills: evidence(of: .skill, in: snapshot.candidateEvidence),
                publications: evidence(of: .publication, in: snapshot.candidateEvidence),
                achievements: evidence(of: .achievement, in: snapshot.candidateEvidence),
                declaredGaps: evidence(of: .declaredGap, in: snapshot.candidateEvidence),
                goals: evidence(of: .goal, in: snapshot.candidateEvidence),
                generatedSummary: nil,
                version: snapshot.candidateProfileVersion ?? 0,
                updatedAt: snapshot.createdAt
            )
        }
        let opportunity = snapshot.opportunityContextID.map { opportunityID in
            OpportunityContext(
                id: opportunityID,
                title: nil,
                organisation: nil,
                opportunityType: .general,
                responsibilities: evidence(of: .responsibility, in: snapshot.opportunityEvidence),
                requiredSkills: evidence(of: .requiredSkill, in: snapshot.opportunityEvidence),
                preferredSkills: evidence(of: .preferredSkill, in: snapshot.opportunityEvidence),
                researchTopics: evidence(of: .researchTopic, in: snapshot.opportunityEvidence),
                evaluationCriteria: evidence(of: .evaluationCriterion, in: snapshot.opportunityEvidence),
                sourceDocumentIDs: Set(snapshot.opportunityEvidence.compactMap(\.sourceDocumentID)).sorted(),
                version: snapshot.opportunityContextVersion ?? 0,
                updatedAt: snapshot.createdAt
            )
        }
        let domainID = InterviewDomainID(rawValue: snapshot.domainProfileID) ?? .general
        return profileSafeFallback(
            question: question,
            domainProfile: .profile(for: domainID),
            candidateProfile: candidate,
            opportunityContext: opportunity,
            contextSnapshotID: snapshot.id
        )
    }

    func profileSafeFallback(
        question: String,
        domainProfile: InterviewDomainProfile,
        candidateProfile: CandidateProfile?,
        opportunityContext: OpportunityContext?,
        contextSnapshotID: String
    ) -> GroundedFallbackResult {
        guard let candidateProfile else {
            return GroundedFallbackResult(
                answer: "",
                status: .candidateContextMissing,
                candidateEvidenceIDs: [],
                opportunityEvidenceIDs: opportunityContext?.allEvidence.map(\.id) ?? [],
                contextSnapshotID: contextSnapshotID,
                groundingDecision: "candidate_context_missing",
                unsupportedClaims: []
            )
        }

        let selectedCandidate = retrieveCandidateEvidence(question: question, profile: candidateProfile, opportunity: opportunityContext)
        let selectedOpportunity = retrieveOpportunityEvidence(question: question, opportunity: opportunityContext)
        let topicTokens = topicTokensForSpecificExperienceQuestion(question)
        if !topicTokens.isEmpty,
           !candidateProfile.allEvidence.contains(where: { !meaningfulTokens($0.statement).intersection(topicTokens).isEmpty }) {
            return GroundedFallbackResult(
                answer: "The selected profile does not document direct experience in that area. The closest supported experience should be reviewed before answering.",
                status: .candidateEvidenceInsufficient,
                candidateEvidenceIDs: [],
                opportunityEvidenceIDs: selectedOpportunity.map(\.id),
                contextSnapshotID: contextSnapshotID,
                groundingDecision: "candidate_evidence_insufficient",
                unsupportedClaims: []
            )
        }

        guard !selectedCandidate.isEmpty else {
            return GroundedFallbackResult(
                answer: "",
                status: .candidateEvidenceInsufficient,
                candidateEvidenceIDs: [],
                opportunityEvidenceIDs: selectedOpportunity.map(\.id),
                contextSnapshotID: contextSnapshotID,
                groundingDecision: "candidate_evidence_insufficient",
                unsupportedClaims: []
            )
        }

        let answer = composeAnswer(question: question, candidate: selectedCandidate, opportunity: selectedOpportunity)
        let decision = validator.validate(
            answer: answer,
            candidateEvidence: selectedCandidate,
            opportunityEvidence: selectedOpportunity,
            domainKnowledge: domainProfile.domainKnowledge
        )
        return GroundedFallbackResult(
            answer: answer,
            status: decision.unsupportedClaims.isEmpty ? .grounded : .candidateEvidenceInsufficient,
            candidateEvidenceIDs: selectedCandidate.map(\.id),
            opportunityEvidenceIDs: selectedOpportunity.map(\.id),
            contextSnapshotID: contextSnapshotID,
            groundingDecision: decision.groundingDecision,
            unsupportedClaims: decision.unsupportedClaims
        )
    }

    func retrieveCandidateEvidence(
        question: String,
        profile: CandidateProfile,
        opportunity: OpportunityContext?,
        limit: Int = 3
    ) -> [ProfileEvidence] {
        let questionTokens = meaningfulTokens(question)
        let opportunityTokens = Set((opportunity?.allEvidence ?? []).flatMap { meaningfulTokens($0.statement) })
        return profile.allEvidence
            .filter { isEligible($0.evidenceType, for: question) }
            .map { evidence in
                var score = Double(meaningfulTokens(evidence.statement).intersection(questionTokens.union(opportunityTokens)).count * 4)
                score += typePriority(evidence.evidenceType, question: question)
                score += evidence.confidence
                return (evidence, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.id < rhs.0.id }
                return lhs.1 > rhs.1
            }
            .prefix(limit)
            .map(\.0)
    }

    func retrieveContext(
        question: String,
        snapshot: InterviewContextSnapshot,
        maxCandidateEvidence: Int = 4,
        maxOpportunityEvidence: Int = 3
    ) -> SnapshotRetrievedContext {
        let questionTokens = meaningfulTokens(question)
        let opportunityTokens = Set(snapshot.opportunityEvidence.flatMap { meaningfulTokens($0.statement) })
        let candidate = rankedEvidence(
            snapshot.candidateEvidence,
            questionTokens: questionTokens,
            relatedTokens: opportunityTokens,
            question: question
        ).prefix(maxCandidateEvidence).map(\.0)
        let opportunity = rankedEvidence(
            snapshot.opportunityEvidence,
            questionTokens: questionTokens,
            relatedTokens: [],
            question: question
        ).prefix(maxOpportunityEvidence).map(\.0)
        return SnapshotRetrievedContext(
            context: RetrievedContext(
                cvChunks: candidate.enumerated().map { makeDocumentChunk($0.element, index: $0.offset, type: .cv) },
                jobDescriptionChunks: opportunity.enumerated().map { makeDocumentChunk($0.element, index: $0.offset, type: .jobDescription) },
                additionalNotesChunks: []
            ),
            candidateEvidenceIDs: candidate.map(\.id),
            opportunityEvidenceIDs: opportunity.map(\.id)
        )
    }

    func retrieveOpportunityEvidence(
        question: String,
        opportunity: OpportunityContext?,
        limit: Int = 2
    ) -> [ProfileEvidence] {
        guard let opportunity else { return [] }
        let tokens = meaningfulTokens(question)
        return opportunity.allEvidence
            .map { evidence in
                (evidence, meaningfulTokens(evidence.statement).intersection(tokens).count)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.id < rhs.0.id }
                return lhs.1 > rhs.1
            }
            .prefix(limit)
            .map(\.0)
    }

    private func composeAnswer(
        question: String,
        candidate: [ProfileEvidence],
        opportunity: [ProfileEvidence]
    ) -> String {
        let lower = question.lowercased()
        let statements = candidate.prefix(3).map(\.statement)
        let candidateText = statements.joined(separator: "; ")
        if lower.contains("difficult") || lower.contains("challenge") || lower.contains("technical problem") {
            return "A technically difficult project documented in my selected profile was: \(candidateText)."
        }
        if lower.contains("about yourself") || lower.contains("background") {
            return "My background is grounded in this evidence: \(candidateText)."
        }
        if lower.contains("fit") || lower.contains("prepare") || lower.contains("suitable") || lower.contains("contribution") {
            let target = opportunity.first?.statement
            return target.map { "My most relevant evidence is: \(candidateText). This aligns with the target responsibility: \($0)." }
                ?? "My most relevant evidence is: \(candidateText)."
        }
        if lower.contains("develop") || lower.contains("gap") || lower.contains("improve") {
            return "The selected profile records this development area: \(candidateText)."
        }
        return "My answer is grounded in this selected-profile evidence: \(candidateText)."
    }

    private func rankedEvidence(
        _ evidence: [ProfileEvidence],
        questionTokens: Set<String>,
        relatedTokens: Set<String>,
        question: String
    ) -> [(ProfileEvidence, Double)] {
        evidence.filter(\.isUsable).map { item in
            let tokens = meaningfulTokens(item.statement)
            var score = Double(tokens.intersection(questionTokens).count * 5)
            score += Double(tokens.intersection(relatedTokens).count * 2)
            score += typePriority(item.evidenceType, question: question)
            score += item.confidence
            return (item, score)
        }.sorted { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0.id < rhs.0.id }
            return lhs.1 > rhs.1
        }
    }

    private func makeDocumentChunk(_ evidence: ProfileEvidence, index: Int, type: DocumentType) -> DocumentChunk {
        DocumentChunk(
            id: evidence.id,
            documentID: evidence.sourceDocumentID ?? "context-evidence",
            documentType: type,
            chunkIndex: index,
            content: evidence.statement,
            keywords: TextChunker.tokenize(evidence.statement),
            sectionTitle: evidence.evidenceType.rawValue,
            wordCount: evidence.statement.split(whereSeparator: \.isWhitespace).count,
            metadataJSON: nil,
            createdAt: Date()
        )
    }

    private func typePriority(_ type: EvidenceType, question: String) -> Double {
        let lower = question.lowercased()
        if lower.contains("project") || lower.contains("difficult") || lower.contains("challenge") || lower.contains("technical problem") {
            return type == .project ? 30 : (type == .achievement ? 18 : 0)
        }
        if lower.contains("develop") || lower.contains("gap") || lower.contains("improve") {
            return type == .declaredGap ? 30 : 0
        }
        if lower.contains("about yourself") || lower.contains("background") {
            return [.education, .experience].contains(type) ? 20 : 0
        }
        if lower.contains("fit") || lower.contains("prepare") || lower.contains("suitable") || lower.contains("contribution") {
            return [.experience, .project, .skill].contains(type) ? 15 : 0
        }
        return 0
    }

    private func isEligible(_ type: EvidenceType, for question: String) -> Bool {
        let lower = question.lowercased()
        if lower.contains("project") || lower.contains("difficult") || lower.contains("challenge") || lower.contains("technical problem") {
            return [.project, .experience, .achievement].contains(type)
        }
        if lower.contains("develop") || lower.contains("gap") || lower.contains("improve") {
            return [.declaredGap, .goal, .skill, .experience].contains(type)
        }
        if lower.contains("about yourself") || lower.contains("background") {
            return [.education, .experience, .project, .skill, .goal].contains(type)
        }
        if lower.contains("fit") || lower.contains("prepare") || lower.contains("suitable") || lower.contains("contribution") {
            return [.experience, .project, .skill, .achievement, .education].contains(type)
        }
        return type != .declaredGap
    }

    private func evidence(of type: EvidenceType, in evidence: [ProfileEvidence]) -> [ProfileEvidence] {
        evidence.filter { $0.evidenceType == type }
    }

    private func topicTokensForSpecificExperienceQuestion(_ question: String) -> Set<String> {
        let lower = question.lowercased()
        let asksForSpecificExperience = lower.contains("what experience do you have") ||
            lower.contains("experience with") ||
            lower.contains("worked with") ||
            lower.contains("hands-on") ||
            lower.contains("hands on")
        guard asksForSpecificExperience else { return [] }
        let generic: Set<String> = ["what", "experience", "have", "with", "worked", "used", "direct", "your", "you", "does"]
        return meaningfulTokens(question).subtracting(generic)
    }

    private func meaningfulTokens(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "and", "that", "with", "from", "this", "into", "for", "was", "were",
            "have", "has", "had", "your", "you", "worked", "work", "most", "about", "what",
            "tell", "describe", "role", "position", "previous", "experience", "project"
        ]
        return Set(TextChunker.tokenize(text).filter { $0.count > 2 && !stopWords.contains($0) })
    }
}

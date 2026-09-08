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
                let experienceEventSupported = personalExperienceEventIsSupported(
                    claim: sentence,
                    evidence: evidence.statement
                )
                let salientFactsSupported = salientPersonalFactsAreSupported(
                    claim: sentence,
                    evidence: evidence.statement
                )
                return enoughSemanticOverlap && metricsSupported && experienceEventSupported && salientFactsSupported
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

    func assertedForbiddenClaims(in answer: String, forbiddenClaims: [String]) -> [String] {
        let clauses = claimSentences(answer)
        return forbiddenClaims.filter { forbiddenClaim in
            let normalizedClaim = normalizedClaimText(forbiddenClaim)
            guard !normalizedClaim.isEmpty else { return false }
            return clauses.contains { clause in
                normalizedClaimText(clause).contains(normalizedClaim) &&
                    !isExplicitEvidenceDenial(clause)
            }
        }
    }

    private func claimSentences(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .flatMap { sentence in
                sentence.replacingOccurrences(
                    of: #"\s*(?:;|\b(?:but|however|although|yet)\b|,\s*and(?=\s+(?:i|we)\b))\s*"#,
                    with: "\n",
                    options: [.regularExpression, .caseInsensitive]
                ).components(separatedBy: "\n")
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func isPersonalClaim(_ sentence: String) -> Bool {
        let lower = " " + sentence.lowercased() + " "
        if isExplicitEvidenceDenial(sentence) {
            return false
        }
        let prospectivePlan = [
            " i would ", " i'd ", " i’d ", " i will ", " i'll ", " i’ll ",
            " we would ", " we'd ", " we’d ", " we will ", " we'll ", " we’ll ",
            " my approach would ", " our approach would "
        ].contains { lower.contains($0) }
        let referencesPastExperience = [
            " my experience ", " our experience ", " my background ", " our background ",
            " i've ", " i’ve ", " i have ", " i had ", " we've ", " we’ve ", " we have ", " we had ",
            " previously ", " in my previous ", " in our previous "
        ].contains { lower.contains($0) }
        let completedExperienceVerb = [
            " built ", " developed ", " implemented ", " led ", " owned ",
            " worked ", " used ", " designed ", " delivered ", " improved ", " reduced ",
            " completed ", " published ", " studied ", " operated ", " trained ",
            " evaluated ", " validated ", " tested ", " integrated ", " contributed ", " achieved ",
            " demonstrated ", " observed ", " encountered ", " experienced ",
            " deployed ", " launched ", " shipped ", " generated ", " produced ",
            " served ", " sold ", " founded ", " scaled ", " maintained ", " authored ", " presented "
        ].contains { lower.contains($0) } || containsPastPersonalAction(lower)
        if prospectivePlan && !referencesPastExperience && !completedExperienceVerb {
            return false
        }
        let firstPerson = [" i ", " i've ", " i’ve ", " my ", " we ", " our ", " us "].contains { lower.contains($0) }
        let claimVerb = completedExperienceVerb || [" background ", " experience ", " evidence "]
            .contains { lower.contains($0) }
        let personalAsset = [" project ", " platform ", " degree ", " publication ", " pipeline ", " system ", " model "]
            .contains { lower.contains(" my" + $0) || lower.contains(" our" + $0) }
        let sensitiveFactPossession = containsSensitivePersonalFactReference(sentence)
        let implicitCandidateOutcome = isImplicitCompletedCandidateOutcome(sentence)
        return implicitCandidateOutcome || (firstPerson && (claimVerb || personalAsset || sensitiveFactPossession))
    }

    private func isImplicitCompletedCandidateOutcome(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let outcomeSubjectPattern = #"^(?:the|this|that)\s+(?:result|outcome)\b"#
        guard lower.range(of: outcomeSubjectPattern, options: .regularExpression) != nil else {
            return false
        }
        let prospectivePattern = #"\b(?:would|will|could|should|may|might)\b"#
        guard lower.range(of: prospectivePattern, options: .regularExpression) == nil else {
            return false
        }
        let completedOutcomePattern = #"\b(?:was|were|has\s+been|had\s+been|achieved|generated|produced|served|reached|improved|reduced|deployed|launched|shipped|scaled)\b"#
        return lower.range(of: completedOutcomePattern, options: .regularExpression) != nil
    }

    private func isExplicitEvidenceDenial(_ sentence: String) -> Bool {
        let lower = " " + sentence.lowercased() + " "
        let evidenceDenials = [
            " i do not have evidence ",
            " i don't have evidence ",
            " i don’t have evidence ",
            " i have no evidence ",
            " i cannot substantiate ",
            " i can't substantiate ",
            " i can’t substantiate ",
            " i cannot confirm ",
            " i can't confirm ",
            " i can’t confirm "
        ]
        if evidenceDenials.contains(where: lower.contains) {
            let affirmativeContinuation = [
                " but i ", " however i ", " although i ", " yet i ",
                " and i ", "; i "
            ].contains(where: lower.contains)
            if !affirmativeContinuation {
                return true
            }
        }
        return false
    }

    private func normalizedClaimText(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private func containsPastPersonalAction(_ text: String) -> Bool {
        let directPattern = #"\b(?:i|we|i['’]ve|we['’]ve)\s+(?:(?:have|had|previously|personally|directly|manually|successfully)\s+){0,3}(?:[a-z]+ed|built|led|sold|wrote|made|ran|saw|taught)\b"#
        let causativePattern = #"\b(?:allowed|enabled)\s+us\s+to\s+[a-z]+\b"#
        return text.range(of: directPattern, options: [.regularExpression, .caseInsensitive]) != nil ||
            text.range(of: causativePattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func personalExperienceEventIsSupported(claim: String, evidence: String) -> Bool {
        let claim = " " + claim.lowercased() + " "
        let evidence = " " + evidence.lowercased() + " "
        let eventGroups = [
            [" observed ", " saw ", " noticed "],
            [" encountered ", " experienced ", " faced "]
        ]
        for group in eventGroups where group.contains(where: claim.contains) {
            if !group.contains(where: evidence.contains) {
                return false
            }
        }
        return true
    }

    private func salientPersonalFactsAreSupported(claim: String, evidence: String) -> Bool {
        let claimTokens = normalizedFactTokens(claim)
        let evidenceTokens = normalizedFactTokens(evidence)
        let deploymentFacts: Set<String> = [
            "deploy", "deployed", "deploying", "deployment", "launch", "launched", "ship", "shipped", "rollout"
        ]
        let commercialFacts: Set<String> = [
            "revenue", "sale", "sales", "profit", "profits", "profitable", "income", "monetized", "monetised"
        ]
        let audienceFacts: Set<String> = [
            "user", "users", "customer", "customers", "client", "clients", "subscriber", "subscribers"
        ]
        let globalFacts: Set<String> = ["global", "globally", "worldwide", "international", "internationally"]
        let productionFacts: Set<String> = ["production"]
        let trainingProvenanceFacts: Set<String> = ["foundation", "scratch"]
        let deploymentActions = ["deploy", "deployed", "launch", "launched", "ship", "shipped", "rollout"]
        let commercialActions = ["generate", "generated", "produce", "produced", "earn", "earned", "sell", "sold", "monetize", "monetized", "monetise", "monetised"]
        let adoptionActions = deploymentActions + commercialActions + ["serve", "served", "reach", "reached", "support", "supported", "acquire", "acquired"]
        let trainingActions = ["train", "trained", "pretrain", "pretrained", "build", "built", "develop", "developed"]
        let hasPersonalFactReference = containsPersonalFactReference(claim)

        if !claimTokens.isDisjoint(with: deploymentFacts),
           (containsPersonalAction(claim, verbs: deploymentActions) || hasPersonalFactReference),
           evidenceTokens.isDisjoint(with: deploymentFacts) {
            return false
        }
        if !claimTokens.isDisjoint(with: commercialFacts),
           (containsPersonalAction(claim, verbs: commercialActions) || hasPersonalFactReference),
           evidenceTokens.isDisjoint(with: commercialFacts) {
            return false
        }
        if !claimTokens.isDisjoint(with: audienceFacts),
           (containsPersonalAction(claim, verbs: adoptionActions) || hasPersonalFactReference),
           evidenceTokens.isDisjoint(with: audienceFacts) {
            return false
        }
        if !claimTokens.isDisjoint(with: globalFacts),
           (containsPersonalAction(claim, verbs: adoptionActions) || hasPersonalFactReference),
           evidenceTokens.isDisjoint(with: globalFacts) {
            return false
        }
        if !claimTokens.isDisjoint(with: productionFacts),
           (containsPastPersonalAction(claim) || hasPersonalFactReference),
           evidenceTokens.isDisjoint(with: productionFacts) {
            return false
        }
        if !claimTokens.isDisjoint(with: trainingProvenanceFacts),
           (containsPersonalAction(claim, verbs: trainingActions) || hasPersonalFactReference),
           !claimTokens.intersection(trainingProvenanceFacts).isSubset(of: evidenceTokens) {
            return false
        }

        let leadershipActions: Set<String> = ["lead", "led", "manage", "managed", "supervise", "supervised"]
        let peopleScope: Set<String> = ["team", "teams", "engineer", "engineers", "people", "staff", "reports"]
        if !claimTokens.isDisjoint(with: leadershipActions),
           !claimTokens.isDisjoint(with: peopleScope),
           (evidenceTokens.isDisjoint(with: leadershipActions) || evidenceTokens.isDisjoint(with: peopleScope)) {
            return false
        }
        return true
    }

    private func containsPersonalAction(_ text: String, verbs: [String]) -> Bool {
        let alternatives = verbs.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let directPattern = "\\b(?:i|we|i['’]ve|we['’]ve)\\s+(?:(?:have|had|previously|personally|directly|manually|successfully)\\s+){0,3}(?:\(alternatives))\\b"
        let causativePattern = "\\b(?:allowed|enabled)\\s+us\\s+to\\s+(?:\(alternatives))\\b"
        return text.range(of: directPattern, options: [.regularExpression, .caseInsensitive]) != nil ||
            text.range(of: causativePattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func containsPersonalFactReference(_ text: String) -> Bool {
        let pattern = #"\b(?:(?:my|our)\s+(?:experience|background|project|pipeline|system|model|product|work|team|company|service)|(?:i|we)\s+(?:have|had))\b"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func containsSensitivePersonalFactReference(_ text: String) -> Bool {
        guard containsPersonalFactReference(text) else { return false }
        let sensitiveFacts: Set<String> = [
            "production", "deploy", "deployed", "deployment", "launch", "launched", "ship", "shipped",
            "revenue", "sales", "profit", "income", "user", "users", "customer", "customers",
            "client", "clients", "subscriber", "subscribers", "global", "globally", "worldwide",
            "international", "internationally", "foundation", "scratch", "team", "teams", "engineer", "engineers"
        ]
        return !normalizedFactTokens(text).isDisjoint(with: sensitiveFacts) || !numericTokens(text).isEmpty
    }

    private func normalizedFactTokens(_ text: String) -> Set<String> {
        Set(TextChunker.tokenize(text).map { $0.lowercased() })
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
        let numberWords: [String: String] = [
            "zero": "0", "two": "2", "three": "3", "four": "4", "five": "5",
            "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
            "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15",
            "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20",
            "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
            "eighty": "80", "ninety": "90"
        ]
        let scaleWords: Set<String> = ["hundred", "thousand", "million", "billion", "percent", "percentage"]
        var result = Set(text.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty })
        for token in TextChunker.tokenize(text).map({ $0.lowercased() }) {
            if let canonicalNumber = numberWords[token] {
                result.insert(canonicalNumber)
            } else if scaleWords.contains(token) {
                result.insert(token == "percentage" ? "percent" : token)
            }
        }
        if text.contains("%") {
            result.insert("percent")
        }
        let quantifiedOnePattern = #"\bone\s+(?:hundred|thousand|million|billion|percent|percentage|users?|customers?|clients?|subscribers?|engineers?|people|teams?|years?|months?)\b"#
        if text.range(of: quantifiedOnePattern, options: [.regularExpression, .caseInsensitive]) != nil {
            result.insert("1")
        }
        return result
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
        let intent = AnswerRelevancePolicy.intent(for: question)
        if intent == .candidateQuestions || intent == .interviewerQuestions {
            return GroundedFallbackResult(
                answer: "How will success be measured in the first three months? Which constraints most affect the team's delivery workflow? How does the team share ownership when issues reach production?",
                status: .grounded,
                candidateEvidenceIDs: [],
                opportunityEvidenceIDs: retrieveOpportunityEvidence(
                    question: question,
                    opportunity: opportunityContext
                ).map(\.id),
                contextSnapshotID: contextSnapshotID,
                groundingDecision: "profile_independent_interviewer_questions",
                unsupportedClaims: []
            )
        }

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
        let intent = AnswerRelevancePolicy.intent(for: question)
        let statements = candidate.prefix(3).map(\.statement)
        let candidateText = statements.joined(separator: "; ")
        let primaryEvidence = statements.first ?? candidateText
        if intent == .projectWalkthrough {
            return "I would walk through the documented project evidence in sequence: \(primaryEvidence). This identifies what was built; where the profile does not document the result or validation, I would say so rather than inventing it."
        }
        if intent == .improvementPlan {
            return "My first priority would be to improve the highest-risk part of this documented work: \(primaryEvidence). I would add failure-case tests, instrument the critical path, and validate the change against a measurable baseline."
        }
        if intent == .systemIntegrationDebugging || intent == .perceptionDebugging || intent == .simToRealDebugging || intent == .errorHandling {
            return "The documented integration evidence is: \(candidateText). I would isolate the failing boundary with logs and timestamps, apply a guarded mitigation with a recovery path, and validate the fix with failure-case tests to reduce risk."
        }
        if intent == .datasetAdaptation {
            return "The selected profile documents this relevant evidence: \(primaryEvidence). It does not document exactly how the data was converted or validated, so I would verify those implementation details before claiming them."
        }
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
        if lower.contains("develop") || lower.contains("gap") {
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
            switch type {
            case .project: return 12
            case .declaredGap, .goal: return 8
            case .experience, .achievement: return 6
            case .skill: return 4
            default: return 0
            }
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
            return [.declaredGap, .goal, .skill, .experience, .project, .achievement].contains(type)
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

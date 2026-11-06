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
                return enoughSemanticOverlap && metricsSupported && personalExperienceEventIsSupported(claim: sentence, evidence: evidence.statement)
                    && (evidence.confirmation?.permits(sentence) ?? true)
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
            groundingDecision: unsupported.isEmpty ? (supportingIDs.isEmpty ? "no_personal_fact_detected" : "supported_by_candidate_evidence") : "unsupported_personal_claim"
        )
    }

    private func claimSentences(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).flatMap { QuestionLanguageSupport.sentenceSlices($0).map(\.text) }
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ";；")) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Recognizes only the application's controlled missing-input notice.
    /// A disclaimer prefix never exempts a model's subsequent personal claims.
    static func isEvidenceLimitation(_ text: String) -> Bool {
        ["en", "zh"].contains { text.trimmingCharacters(in: .whitespacesAndNewlines) == InterviewQuestionDecision.missingPersonalEvidenceNotice(language: $0) }
    }

    private func isPersonalClaim(_ sentence: String) -> Bool {
        let lower = " " + sentence.lowercased().components(separatedBy: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’"))).joined(separator: " ") + " "
        let request = sentence.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hypotheticalAssetState = ["if ", "unless ", "suppose ", "assuming ", "imagine ", "如果", "假如", "假设"].contains(where: request.hasPrefix)
        let asksForInput = ["could you ", "can you ", "would you ", "please provide ", "please share ", "请提供", "请补充"].contains(where: request.hasPrefix)
        if asksForInput, request.range(of: #"\b(i|we|my|our)\b|我|我们"#, options: .regularExpression) == nil,
           !request.contains(";"), !request.contains("；") { return false }
        if sentence.contains("我") || sentence.contains("我们") {
            let planned = ["我会", "我将", "我计划", "我们将", "我建议", "我们会", "我可以", "我们可以", "我需要", "我们需要", "我们建议"].contains(where: sentence.contains)
            let past = ["曾", "已经", "完成了", "负责过", "提升了", "降低了", "开发了", "实现了"].contains(where: sentence.contains)
            if past || (!planned && !hypotheticalAssetState && ["我的项目", "我的经验", "我的原型", "我们的原型", "我负责", "我们实现"].contains(where: sentence.contains)) { return true }
            // Chinese completion/aspect and academic ownership do not require
            // an English verb or an Arabic-number metric to be a personal claim.
            let completedAction = sentence.range(of: #"(?:我|我们|我的|我们的)[^。！？；]*[了过]"#, options: .regularExpression) != nil
            let ownedAchievement = ["发表", "获奖", "获批", "专利", "论文", "奖项", "证书"].contains(where: sentence.contains)
            if !planned && (completedAction || ownedAchievement) { return true }
        }
        // Preferences, qualifications and commitments require evidence just as
        // completed achievements do. Hypothetical technical plans are separate.
        if [" i prefer ", " i expect ", " i can start ", " i can relocate ", " my salary ", " my notice ", " my visa ", " my availability "].contains(where: lower.contains) { return true }
        if ["我毕业", "我拥有", "我具有", "我希望", "我期望", "我偏好", "我能入职", "我可以入职", "我的薪", "我的签证", "我的学历"].contains(where: sentence.contains) { return true }
        if lower.range(of: #"\b(i am|i'm|i’m|you are|you're|the candidate is)\s+(a |an |experienced|qualified|certified|available|employed|based|fluent)"#, options: .regularExpression) != nil || ["我是一名", "我具有", "您曾", "你曾"].contains(where: sentence.contains) { return true }
        let personalSubject = [" i ", " my ", " you ", " your ", " i'm ", " i’m "].contains(where: lower.contains) || ["我", "你", "您", "候选人"].contains(where: sentence.contains)
        let personalConditions = ["salary", "sponsorship", "visa", "notice period", "available to start", "start work", "relocat", "qualification", "graduated", "degree", "work authorization", "authorized to work", "work permit", "薪资", "签证", "入职", "搬迁", "学历", "毕业", "工作许可"]
        let personalCondition = personalConditions.contains(where: lower.contains)
        let merelyClarifying = ["clarify", "ask about", "confirm", "澄清", "询问", "确认"].contains(where: lower.contains)
        if personalSubject && personalCondition {
            // An inquiry cannot exempt an independent candidate condition in the same sentence.
            let boundary = #"(?:[,，]\s*|\b(?:and|but|yet|because|since|then)\s+|(?:但是|但|不过|而且|并且|因为|然后)\s*)(?=(?:i\b|we\b|my\b|our\b|you\b|your\b|我|你|您))"#
            if let range = request.range(of: boundary, options: .regularExpression) {
                let clause = String(request[range.upperBound...])
                if clause.count < request.count, isPersonalClaim(clause) { return true }
            }
            let coordination = #"\b(?:and|but|yet|then|or|because|since)\s+|但是|不过|而且|并且|然后|但|并|或"#
            let qualificationTopics = ["qualification", "graduated", "degree", "学历", "毕业"]
            var ambiguousQualification = false
            var remainder = request[...]
            while let range = remainder.range(of: coordination, options: .regularExpression) {
                let tail = remainder[range.upperBound...]
                let clause = tail[..<(tail.range(of: coordination, options: .regularExpression)?.lowerBound ?? tail.endIndex)]
                let inquiryClause = clause.range(of: #"^(?:what|which|whether)\b|^(?:ask|inquire|enquire)\s+(?:about|what|which|whether|if)\b|^(?:clarify|confirm)\s+(?:what|which|whether)\b|^(?:询问|澄清|确认)(?:是否|什么|哪些|雇主|招聘方|招聘经理|面试官|岗位|职位)"#, options: .regularExpression) != nil
                if personalConditions.contains(where: clause.contains) && !inquiryClause {
                    if personalConditions.contains(where: { !qualificationTopics.contains($0) && clause.contains($0) }) { return true }
                    ambiguousQualification = true
                }
                remainder = tail
            }
            let inquiry = #"^i(?:['’](?:d|ll)|\s+(?:would|will))\s+ask\s+(?:the\s+)?(?:hiring manager|employer|recruiter|interviewer|hr)\s+(?:(?:whether|which|what|if)\b|to\s+(?:specify|explain|clarify|describe|state)\s+(?:(?:whether|which|what|if)\b|the\s+(?:[a-z]+\s+){0,3}(?:requirement|requirements|policy|policies)\b))|^(?:我|我们)(?:会|将)(?:先)?(?:向(?:雇主|招聘方|招聘经理|面试官|hr)(?:了解|询问|澄清)(?:是否|哪些|什么|岗位|职位)|请(?:雇主|招聘方|招聘经理|面试官|hr)(?:说明|澄清)(?:是否|哪些|什么|岗位|职位))"#
            let inquiryRange = request.range(of: inquiry, options: .regularExpression)
            // shortcut: inquiries with another personal subject retain source checks; extend with paired claim regressions.
            let pureFutureInquiry = inquiryRange.map {
                let remainder = request[$0.upperBound...]
                return !ambiguousQualification && remainder.range(of: #"\b(?:i|we|my|our|you|your)\b|我|你|您"#, options: .regularExpression) == nil
            } ?? false
            if !merelyClarifying && !pureFutureInquiry { return true }
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
        // A past participle modifying a future plan's object is not a claim
        // that the candidate already performed the confirmation.
        let completedConfirmation = pastConfirmationPredicate(sentence) != nil
        let completedFocus = !hypotheticalAssetState && lower.range(of: #"\b(?:i|we|you|(?:my|our) team|the candidate)(?:['’]ve)?\s+(?:(?:have|has|had|not|never|already|previously|personally|also|just|[a-z]+ly)\s+)*focused\b"#, options: .regularExpression) != nil
        let auxiliaryObservation = pastObservationPredicate(sentence)?.usesAuxiliaryForm == true
        let personalAssets = [" project ", " prototype ", " prototype's ", " prototype’s ", " platform ", " degree ", " publication ", " pipeline ", " system ", " model ", " thesis ", " paper ", " papers ", " patent ", " patents ", " award ", " awards "]
        let personalAsset = personalAssets.contains { lower.contains(" my" + $0) || lower.contains(" our" + $0) }
        let causalOwnedDefinition = [" because ", " since ", " but "].contains { separator in
            guard let boundary = lower.range(of: separator) else { return false }
            let clause = String(lower[boundary.upperBound...])
            return personalAssets.contains { clause.contains(" my" + $0) || clause.contains(" our" + $0) }
                && definitionPredicate(clause) != nil
        }
        let completedDefinition = definitionPredicate(sentence, personalActionOnly: true) != nil
        let completedExperienceVerb = completedConfirmation || completedFocus || completedDefinition || pastObservationPredicate(sentence) != nil || causalOwnedDefinition || [
            " built ", " developed ", " implemented ", " led ", " owned ", " managed ",
            " worked ", " used ", " designed ", " delivered ", " improved ", " reduced ",
            " completed ", " published ", " studied ", " controlled ", " operated ", " trained ",
            " evaluated ", " validated ", " tested ", " integrated ", " contributed ", " achieved ",
            " demonstrated ", " observed ", " encountered ", " experienced ", " resolved ", " handled ",
            " won ", " wrote ", " received ", " earned ", " obtained ", " secured ", " patented "
        ].contains { lower.contains($0) }
        if prospectivePlan && !referencesPastExperience && !completedExperienceVerb {
            return false
        }
        let firstPerson = auxiliaryObservation || [" i ", " i've ", " i’ve ", " my ", " we ", " our ", " you ", " your ", " the candidate "].contains { lower.contains($0) }
        let claimVerb = completedExperienceVerb || [" background ", " experience ", " evidence "]
            .contains { lower.contains($0) }
        return firstPerson && (claimVerb || (personalAsset && !hypotheticalAssetState))
    }

    /// Missing records do not establish whether the candidate observed an event.
    /// Keep polarity local to the observation predicate, not an unrelated clause.
    private func pastObservationPredicate(_ text: String, allowImplicitSubject: Bool = false) -> (affirmed: Bool, usesAuxiliaryForm: Bool)? {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["if ", "unless ", "suppose ", "assuming ", "imagine ", "如果", "假如", "假设"].contains(where: text.hasPrefix) {
            return nil
        }
        let subject = (allowImplicitSubject ? #"(?:^|"# : "(?:") + #"\b(?:i|we|you|(?:my|our) team|the candidate)(?:['’]ve)?\s+)"#
        let auxiliary = #"(?:(?:did\s+(?:(?:not|never)\s+)?|didn['’]t\s+)(?:observe|notice|note|see))"#
        let inflected = #"(?:(?:(?:have|has|had|haven['’]t|hasn['’]t|hadn['’]t|already|previously|personally|also|just|since|then)\s+)*(?:(?:not|never)\s+)?(?:observed|noticed|noted|saw))"#
        var remaining = text.startIndex..<text.endIndex
        while let range = text.range(of: subject + "(?:" + auxiliary + "|" + inflected + #")\b(?:\s+no\b)?"#, options: .regularExpression, range: remaining) {
            remaining = range.upperBound..<text.endIndex
            if uncertainPastEventPrefix(text[..<range.lowerBound]) { continue }
            let predicate = String(text[range])
            let denied = predicate.range(of: #"\b(?:not|never|no|didn['’]t|haven['’]t|hasn['’]t|hadn['’]t)\b"#, options: .regularExpression) != nil
            return (!denied, predicate.range(of: #"\bdid\b|\bdidn['’]t\b"#, options: .regularExpression) != nil)
        }
        if let range = text.range(of: #"(?:我|我们|你|您|候选人)(?:曾经|已经)?(?:没有|没|未曾|未|不曾)?(?:观察到|看到|注意到)"#, options: .regularExpression) {
            guard !uncertainPastEventPrefix(text[..<range.lowerBound]) else { return nil }
            let predicate = String(text[range])
            let denied = ["没有", "没", "未", "不曾"].contains(where: predicate.contains)
            return (!denied, denied)
        }
        return nil
    }

    private func uncertainPastEventPrefix(_ prefix: Substring) -> Bool {
        let clause = String(prefix).components(separatedBy: " but ").last?
            .components(separatedBy: CharacterSet(charactersIn: ";；.。,，")).last ?? ""
        return clause.range(of: #"\b(?:if|unless|whether|suppose|assuming|imagine)\b|(?:\b(?:unknown|unclear)|\bno (?:records?|evidence|information)|\bnot (?:recorded|documented|known))(?:\s+that)?\s*$|是否|如果|假如|假设|(?:没有记录|未记录|未说明|不清楚)\s*$"#, options: .regularExpression) != nil
    }

    private func pastConfirmationPredicate(_ text: String, allowImplicitSubject: Bool = false) -> (affirmed: Bool, usesAuxiliaryForm: Bool)? {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["if ", "unless ", "suppose ", "assuming ", "imagine ", "如果", "假如", "假设"].contains(where: text.hasPrefix) { return nil }
        let subject = (allowImplicitSubject ? #"(?:^|"# : "(?:") + #"\b(?:i|we|you|(?:my|our) team|the candidate)(?:['’]ve)?\s+)"#
        let action = #"(?:(?:did\s+(?:(?:not|never)\s+)?|didn['’]t\s+)(?:confirm|verify|find)|(?:(?:have|has|had|haven['’]t|hasn['’]t|hadn['’]t|not|never|already|previously|personally|also|just|since|then|[a-z]+ly)\s+)*(?:confirmed|verified|found))\b(?:\s+no\b)?"#
        var remaining = text.startIndex..<text.endIndex
        while let range = text.range(of: subject + action, options: .regularExpression, range: remaining) {
            remaining = range.upperBound..<text.endIndex
            if uncertainPastEventPrefix(text[..<range.lowerBound]) { continue }
            let predicate = String(text[range])
            let denied = predicate.range(of: #"\b(?:not|never|no|didn['’]t|haven['’]t|hasn['’]t|hadn['’]t)\b"#, options: .regularExpression) != nil
            return (!denied, predicate.range(of: #"\bdid\b|\bdidn['’]t\b"#, options: .regularExpression) != nil)
        }
        return nil
    }

    private func personalExperienceEventIsSupported(claim: String, evidence: String) -> Bool {
        let claim = " " + claim.lowercased() + " "
        let evidence = " " + evidence.lowercased() + " "
        let future = ["plan to", "will ", "would ", "计划", "打算", "将要", "我会", "我们会", "我将", "我们将"]
        // A future or negated source cannot support a positive factual claim
        // merely because its topic and numbers overlap. Prefer a narrower source
        // span when a source mixes completed work with plans/negative statements.
        if future.contains(where: evidence.contains) && !future.contains(where: claim.contains) { return false }
        func negated(_ text: String) -> Bool {
            text.range(of: #"\b(?:not|never|no|didn['’]t|haven['’]t|hasn['’]t|wasn['’]t|weren['’]t)\b|未|没有|不曾|并非"#, options: .regularExpression) != nil
        }
        let confirmation = pastConfirmationPredicate(claim)
        if let confirmation {
            if pastConfirmationPredicate(evidence, allowImplicitSubject: true)?.affirmed != confirmation.affirmed { return false }
        } else if let observation = pastObservationPredicate(claim) {
            if pastObservationPredicate(evidence, allowImplicitSubject: true)?.affirmed != observation.affirmed { return false }
        } else if let definition = definitionPredicate(claim) {
            if definitionPredicate(evidence) != definition { return false }
        } else if negated(evidence) != negated(claim) { return false }
        let simulation = ["simulation", "simulated", "仿真"].contains(where: evidence.contains)
        let realTerms = ["production", "real robot", "hardware", "实机", "生产部署"]
        if simulation && !realTerms.contains(where: evidence.contains) && realTerms.contains(where: claim.contains) { return false }
        if ["team", "团队"].contains(where: evidence.contains), ["independently", "solely", "独立", "独自"].contains(where: claim.contains),
           !["independently", "solely", "独立", "独自"].contains(where: evidence.contains) { return false }
        let eventGroups = [
            [" observed ", " saw ", " noticed ", " noted "],
            [" encountered ", " experienced ", " faced "],
            // Performing a test does not establish that its result was confirmed.
            [" confirmed ", " verified ", " found ", "确认", "验证", "发现"]
        ]
        for group in eventGroups where group.contains(where: claim.contains) {
            if confirmation != nil && group.contains(" confirmed ") { continue }
            if !group.contains(where: evidence.contains) {
                return false
            }
        }
        return true
    }

    private func definitionPredicate(_ text: String, personalActionOnly: Bool = false) -> Bool? {
        let text = text.lowercased()
        let passive = #"\b(?:(?:was|were|is|are|has been|have been|had been)\s+(?:(?:not|never)\s+)?|(?:wasn['’]t|weren['’]t|isn['’]t|aren['’]t)\s+)(?:defined|specified)\b"#
        let active = #"\b(?:i|we|you|the candidate)\s+(?:(?:did\s+(?:(?:not|never)\s+)?|didn['’]t\s+)(?:define|specify)|(?:(?:have|had|not|never|already|previously)\s+)*(?:defined|specified))\b"#
        let chinese = #"(?:没有|并未|未曾|未|已经|已)(?:定义|规定)|(?:定义|规定)了"#
        guard let range = text.range(of: personalActionOnly ? active : passive + "|" + active + "|" + chinese, options: .regularExpression) else { return nil }
        // shortcut: mixed source spans need narrower statements; uncertainty is not a definition event.
        let prefix = String(text[..<range.lowerBound])
        guard prefix.range(of: #"\b(?:if|unless|whether|suppose|assuming|imagine|unknown|unclear)\b|\b(?:no (?:records?|evidence|information)|not (?:recorded|documented|known))\b|是否|如果|假如|假设|没有记录|未记录|未说明|不清楚"#, options: .regularExpression) == nil else { return nil }
        return String(text[range]).range(of: #"\b(?:not|never|didn['’]t|wasn['’]t|weren['’]t|isn['’]t|aren['’]t)\b|没有|并未|未曾|未"#, options: .regularExpression) == nil
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
        let statements = candidate.prefix(3).map(\.statementForPrompt)
        let candidateText = statements.joined(separator: "\n")
        let primaryEvidence = statements.first ?? candidateText
        if intent == .projectWalkthrough {
            return "The documented project evidence is: \(primaryEvidence) Additional result or validation details need confirmation."
        }
        if intent == .improvementPlan {
            return "My first priority would be to improve the highest-risk part of this documented work: \(primaryEvidence). I would add failure-case tests, instrument the critical path, and validate the change against a measurable baseline."
        }
        if intent == .systemIntegrationDebugging || intent == .perceptionDebugging || intent == .simToRealDebugging || intent == .errorHandling {
            return "The documented integration evidence is: \(candidateText). I would isolate the failing boundary with logs and timestamps, apply a guarded mitigation with a recovery path, and validate the fix with failure-case tests to reduce risk."
        }
        if intent == .datasetAdaptation {
            return "The selected profile documents this relevant evidence: \(primaryEvidence). The supplied source does not document how the data was converted or validated. Those details need source confirmation."
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
            content: evidence.statementForPrompt,
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

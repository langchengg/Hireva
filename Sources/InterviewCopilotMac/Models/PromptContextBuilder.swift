// Builds immutable prompt snapshots for answer generation.
// The current detected question must dominate the prompt; transcript and RAG
// context are supporting background only and must not become the primary task.

import Foundation

/// Constructs prompt snapshots that freeze the current question, filtered
/// context, and background transcript at generation start.
///
/// The builder is intentionally stateless. It should not read AppState directly
/// because late transcript updates or newer questions must not alter an
/// in-flight generation prompt.
enum PromptContextBuilder {
    /// Builds the provider-facing prompt and diagnostic snapshot for one
    /// question.
    ///
    /// The returned `promptPrimaryQuestion` must equal the detected question
    /// snapshot. Previous transcript may be included only as labeled background.
    static func promptSnapshot(
        question: DetectedQuestion,
        context: RetrievedContext,
        transcriptContext: String,
        cvSummary: String,
        jdSummary: String,
        stage: AnswerPromptStage,
        interviewContextSnapshot: InterviewContextSnapshot? = nil
    ) -> AnswerPromptSnapshot {
        let questionTextSnapshot = question.questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = QuestionIntentPromptPolicy.intent(for: questionTextSnapshot)
        let filteredContext = QuestionIntentPromptPolicy.filterContext(context, intent: intent)
        let background = backgroundTranscript(
            from: transcriptContext,
            currentQuestion: questionTextSnapshot,
            currentIntent: intent
        )
        let prompt = buildPrompt(
            questionTextSnapshot: questionTextSnapshot,
            intent: intent,
            filteredContext: filteredContext,
            backgroundText: background.text,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            stage: stage
        )
        let chunkIntents = chunkIntents(from: filteredContext)
        let includedChunkIDs = Set(chunkIDs(from: filteredContext))
        return AnswerPromptSnapshot(
            detectedQuestionID: question.id,
            questionTextSnapshot: questionTextSnapshot,
            normalizedQuestionText: QuestionIntentPromptPolicy.normalizedQuestionText(for: questionTextSnapshot),
            questionIntent: intent,
            transcriptSegmentID: question.transcriptSegmentID,
            ragContextSnapshot: filteredContext,
            ragChunkPreviews: chunkPreviews(from: filteredContext),
            ragChunkIDs: chunkIDs(from: filteredContext),
            ragChunkIntents: chunkIntents,
            prompt: prompt,
            promptPrimaryQuestion: questionTextSnapshot,
            promptContainsPreviousQuestion: background.promptContainsPreviousQuestion,
            previousQuestionIncluded: background.included,
            previousQuestionText: background.previousQuestionText,
            contextBleedRisk: background.risk,
            promptTokenEstimate: estimateTokens(prompt),
            contextSnapshotID: interviewContextSnapshot?.id,
            candidateProfileID: interviewContextSnapshot?.candidateProfileID,
            candidateProfileVersion: interviewContextSnapshot?.candidateProfileVersion,
            opportunityContextID: interviewContextSnapshot?.opportunityContextID,
            opportunityContextVersion: interviewContextSnapshot?.opportunityContextVersion,
            domainProfileID: interviewContextSnapshot?.domainProfileID,
            candidateEvidenceIDs: interviewContextSnapshot?.candidateEvidence.map(\.id).filter(includedChunkIDs.contains) ?? [],
            opportunityEvidenceIDs: interviewContextSnapshot?.opportunityEvidence.map(\.id).filter(includedChunkIDs.contains) ?? []
        )
    }

    static func generationRequestSnapshot(
        question: DetectedQuestion,
        generationID: String,
        triggerPath: GenerationTriggerPath,
        source: AudioSourceType?,
        speaker: SpeakerRole?,
        acceptedAt: Date,
        context: RetrievedContext,
        transcriptContext: String,
        cvSummary: String,
        jdSummary: String,
        stage: AnswerPromptStage,
        interviewContextSnapshot: InterviewContextSnapshot? = nil
    ) -> GenerationRequestSnapshot {
        let prompt = promptSnapshot(
            question: question,
            context: context,
            transcriptContext: transcriptContext,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            stage: stage,
            interviewContextSnapshot: interviewContextSnapshot
        )
        return GenerationRequestSnapshot(
            detectedQuestionID: question.id,
            generationID: generationID,
            transcriptSegmentID: question.transcriptSegmentID,
            questionText: prompt.questionTextSnapshot,
            normalizedQuestionText: prompt.normalizedQuestionText,
            questionIntent: prompt.questionIntent,
            source: source,
            speaker: speaker,
            triggerPath: triggerPath,
            acceptedAt: acceptedAt,
            ragContextSnapshot: prompt.ragContextSnapshot,
            promptSnapshot: prompt,
            contextSnapshotID: interviewContextSnapshot?.id,
            candidateProfileID: interviewContextSnapshot?.candidateProfileID,
            candidateProfileVersion: interviewContextSnapshot?.candidateProfileVersion,
            opportunityContextID: interviewContextSnapshot?.opportunityContextID,
            opportunityContextVersion: interviewContextSnapshot?.opportunityContextVersion,
            domainProfileID: interviewContextSnapshot?.domainProfileID
        )
    }

    static func estimateTokens(_ text: String) -> Int {
        max(1, Int(Double(text.split(whereSeparator: \.isWhitespace).count) * 1.35))
    }

    /// Composes the actual user prompt from frozen inputs.
    ///
    /// Keep current-question placement ahead of context. Do not add instructions
    /// that let RAG chunks or previous transcript override the primary question.
    private static func buildPrompt(
        questionTextSnapshot: String,
        intent: AnswerRelevanceIntent,
        filteredContext: RetrievedContext,
        backgroundText: String,
        cvSummary: String,
        jdSummary: String,
        stage: AnswerPromptStage
    ) -> String {
        let outputInstructions: String
        switch stage {
        case .firstAnswer:
            outputInstructions = "Output only one natural first-person spoken answer, 1 to 3 concise sentences."
        case .sectionStream:
            outputInstructions = """
            Return plain text sections only:
            STRATEGY:
            SAY_FIRST:
            KEY_POINTS:
            FOLLOW_UP_READY:
            CAUTION:
            """
        case .fullAnswer, .jsonCard:
            outputInstructions = """
            Return valid JSON only using keys: strategy, say_first, key_points, follow_up_ready, confidence, caution, evidence_used, risk_level.
            """
        }

        let selectedEvidence = filteredContext.promptText.isEmpty
            ? "No matching local chunks were found. Use the question intent and profile summary; do not fabricate unsupported specifics."
            : filteredContext.promptText

        return """
        CURRENT QUESTION TO ANSWER:
        "\(redactSecrets(questionTextSnapshot))"

        You must answer this exact question directly.
        Previous transcript is background only and must not change the question.

        Your task:
        Answer this exact question directly in first person.
        Do not answer a previous question.
        Do not give a generic self-introduction unless the question asks for it.
        Do not summarize the CV unless relevant to the question.

        QUESTION INTENT:
        \(intent.rawValue)

        ANSWER SHAPE:
        \(QuestionIntentPromptPolicy.answerShape(for: intent))

        OUTPUT FORMAT:
        \(outputInstructions)

        RELEVANT CONTEXT:
        Candidate summary:
        \(redactSecrets(cvSummary))

        Target role summary:
        \(redactSecrets(jdSummary))

        Selected local evidence:
        \(redactSecrets(selectedEvidence))

        BACKGROUND FROM EARLIER INTERVIEW:
        \(redactSecrets(backgroundText))
        """
    }

    private static func chunkPreviews(from context: RetrievedContext) -> [String] {
        (context.cvChunks + context.jobDescriptionChunks + context.additionalNotesChunks).map { chunk in
            let title = chunk.sectionTitle ?? chunk.documentType.shortTitle
            let preview = chunk.content.replacingOccurrences(of: "\n", with: " ").prefix(120)
            return "\(title): \(preview)"
        }
    }

    private static func chunkIDs(from context: RetrievedContext) -> [String] {
        (context.cvChunks + context.jobDescriptionChunks + context.additionalNotesChunks).map(\.id)
    }

    private static func chunkIntents(from context: RetrievedContext) -> [AnswerRelevanceIntent] {
        (context.cvChunks + context.jobDescriptionChunks + context.additionalNotesChunks).map { chunk in
            QuestionIntentPromptPolicy.intent(for: [chunk.sectionTitle ?? "", chunk.content].joined(separator: " "))
        }
    }

    private static func backgroundTranscript(
        from transcriptContext: String,
        currentQuestion: String,
        currentIntent: AnswerRelevanceIntent
    ) -> (text: String, included: Bool, previousQuestionText: String?, promptContainsPreviousQuestion: Bool, risk: ContextBleedRisk) {
        let trimmed = transcriptContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("No earlier background included.", false, nil, false, .low)
        }

        let bounded = ContextBudgeter.limitWords(trimmed, maxWords: 130)
        let previousQuestion = extractQuestionLikeText(from: bounded)
        let previousIntent = previousQuestion.map(QuestionIntentPromptPolicy.intent(for:))
        let currentNormalized = QuestionIntentPromptPolicy.normalizedQuestionText(for: currentQuestion)
        let previousNormalized = previousQuestion.map(QuestionIntentPromptPolicy.normalizedQuestionText(for:)) ?? ""
        let isDifferentQuestion = !previousNormalized.isEmpty && previousNormalized != currentNormalized
        let intentDiffers = previousIntent != nil && previousIntent != currentIntent

        if isDifferentQuestion && intentDiffers {
            return (
                "Earlier transcript contained a different question and was excluded to keep this answer focused.",
                false,
                previousQuestion,
                false,
                .low
            )
        }

        let cleaned = stripCurrentQuestion(currentQuestion, from: bounded)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("No earlier background included.", false, previousQuestion, false, .low)
        }

        let containsPrevious = previousQuestion.map { normalize(cleaned).contains(normalize($0).trimmingCharacters(in: .whitespacesAndNewlines)) } ?? false
        let risk: ContextBleedRisk = containsPrevious && isDifferentQuestion ? .medium : .low
        return (cleaned, true, previousQuestion, containsPrevious, risk)
    }

    private static func extractQuestionLikeText(from text: String) -> String? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let candidates = lines.isEmpty ? [text] : lines
        for candidate in candidates.reversed() {
            let cleaned = candidate
                .replacingOccurrences(of: "Interviewer:", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalize(cleaned)
            if cleaned.contains("?") ||
                normalized.contains(" could you ") ||
                normalized.contains(" what ") ||
                normalized.contains(" why ") ||
                normalized.contains(" how ") ||
                normalized.contains(" which ") ||
                normalized.contains(" do you ") {
                return cleaned
            }
        }
        return nil
    }

    private static func stripCurrentQuestion(_ question: String, from text: String) -> String {
        let current = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return text }
        return text
            .replacingOccurrences(of: current, with: "", options: [.caseInsensitive])
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func redactSecrets(_ text: String) -> String {
        let replacements: [(pattern: String, template: String)] = [
            (#"sk-[A-Za-z0-9_\-]{16,}"#, "[REDACTED_API_KEY]"),
            (#"(?i)((?:api|deepseek)[_\-\s]?key\s*[:=]\s*)[A-Za-z0-9_\-]{12,}"#, "$1[REDACTED_API_KEY]")
        ]
        var redacted = text
        for replacement in replacements {
            guard let regex = try? NSRegularExpression(pattern: replacement.pattern) else { continue }
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = regex.stringByReplacingMatches(
                in: redacted,
                options: [],
                range: range,
                withTemplate: replacement.template
            )
        }
        return redacted
    }

    private static func normalize(_ text: String) -> String {
        " " + text
            .lowercased()
            .replacingOccurrences(of: "c++", with: "c plus plus")
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
    }
}

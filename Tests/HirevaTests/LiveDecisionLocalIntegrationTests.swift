import Foundation
import Testing
@testable import Hireva

/// Actual installed Qwen through AppState, retrieval, publication and persistence.
/// Synthetic text input: this is NOT audio or GUI acceptance.
@Suite(.serialized)
struct LiveDecisionLocalIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_LOCAL_LIVE_DECISION"] == "1"))
    @MainActor func actualLocalManualAnswerUsesFrozenDecisionAndPersistsUnknownSpeaker() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"])
        let database = try AppDatabase(path: URL(fileURLWithPath: root).appendingPathComponent("manual-" + UUID().uuidString + ".sqlite"))
        let app = AppState(database: database, keychainService: KeychainService(store: InMemoryMockKeychainStore()))
        app.answerProviderModeOverride = .localQwenPrimary
        app.localLLMProviderOverride = SyntheticCaptureProvider(suffix: "manual")
        app.setSelectedQwenModelName("qwen3.5:4b")
        app.generationFullCardWatchdogNanoseconds = 30_000_000_000
        var settings = app.settings; settings.saveTranscriptsLocally = true; settings.diagnosticTraceMode = .off
        app.saveSettings(settings)
        app.manualCaptureState = .transcriptReady
        app.manualCaptureTranscript = "Explain database transactions and atomicity."
        app.sendManualCaptureToAI()
        let deadline = ContinuousClock.now.advanced(by: .seconds(35))
        while app.manualCaptureState == .generatingSuggestion && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
        #expect(app.manualCaptureState == .suggestionReady)
        let session = try #require(app.currentSession)
        while (try app.suggestionRepository.suggestions(sessionID: session.id)).isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
        let row = try #require(app.suggestionRepository.suggestions(sessionID: session.id).first)
        let question = try #require(app.suggestionRepository.questions(sessionID: session.id).first(where: { $0.id == row.questionID }))
        #expect(question.isLocal == true)
        #expect(question.providerKind == .ollamaLocal)
        #expect(question.modelName == "qwen3.5:4b")
        #expect(question.taskDescriptor?.decision?.personalEvidence == .notRequired)
        #expect(question.taskDescriptor?.decision?.routerVersion == InterviewQuestionRouter.version)
        #expect(row.isLocal == true)
        #expect(row.sayFirst.localizedCaseInsensitiveContains("atomic"))
        #expect(row.candidateEvidenceIDs.isEmpty)
        #expect(try app.transcriptRepository.segments(sessionID: session.id).first?.speaker == .unknown)
        app.cancelActiveGenerationForStop()
    }

    private actor StreamObservation {
        var tokens = 0
        var ended = false
        func token() { tokens += 1 }
        func finish() { ended = true }
        func state() -> (Int, Bool) { (tokens, ended) }
    }

    /// Client cancellation plus next-request progress; not proof of immediate
    /// GPU-kernel termination, physical audio latency, or B1/B2 performance.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_LOCAL_CANCEL"] == "1"))
    func actualProviderCancellationReleasesNextRequest() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"])
        let provider = OllamaQwenProvider()
        struct Sample: Encodable { var iteration: Int; var endpoint: String; var idleProbeMS: Double; var clientCancellationMS: Double; var nextProbeMS: Double; var tokensBeforeCancel: Int }
        var samples: [Sample] = []
        func milliseconds(_ start: ContinuousClock.Instant) -> Double {
            let d = start.duration(to: .now).components
            return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
        }
        func probe() async throws -> Double {
            let start = ContinuousClock.now
            let stream = try await provider.generateAnswer(request: .init(prompt: "Reply with the single word ready.", systemPrompt: nil, modelName: "qwen3.5:4b", temperature: 0, numPredict: 8))
            var count = 0
            for try await token in stream { count += token.text.count }
            try #require(count > 0)
            return milliseconds(start)
        }
        for iteration in 0..<3 {
            let idle = try await probe()
            let observation = StreamObservation()
            let schema: LocalJSONValue? = iteration == 0 ? nil : .object([
                "type": .string("object"), "properties": .object(["steps": .object([
                    "type": .string("array"), "items": .object(["type": .string("string")])])]),
                "required": .array([.string("steps")]), "additionalProperties": .boolean(false)])
            let worker = Task {
                do {
                    let stream = try await provider.generateAnswer(request: .init(prompt: "Write a detailed tutorial of at least 200 steps explaining sorting algorithms and examples. When JSON is requested, put each step in the steps array. Continue until all steps are complete.", systemPrompt: nil, modelName: "qwen3.5:4b", temperature: 0, numPredict: 4096, responseSchema: schema))
                    for try await token in stream {
                        try Task.checkCancellation()
                        if !token.text.isEmpty { await observation.token() }
                    }
                } catch { /* Cancellation/error is observed through task completion. */ }
                await observation.finish()
            }
            defer { worker.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while await observation.state().0 == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            let before = await observation.state()
            try #require(before.0 > 0 && !before.1)
            let cancelStart = ContinuousClock.now
            worker.cancel()
            await worker.value
            let cancellation = milliseconds(cancelStart)
            let next = try await probe()
            samples.append(.init(iteration: iteration, endpoint: schema == nil ? "/api/chat" : "/api/generate", idleProbeMS: idle, clientCancellationMS: cancellation, nextProbeMS: next, tokensBeforeCancel: before.0))
            // Fixed diagnostic bounds before running. These do not replace the
            // stricter 20%/30% end-to-end B1/B2 degradation budgets.
            #expect(cancellation < 3000)
            #expect(next < 5000)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: URL(fileURLWithPath: root).appendingPathComponent("cancel-metrics.json"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_LOCAL_LIVE_DECISION"] == "1"))
    @MainActor func correctedAttemptReevaluatesOnlyItsVersionAndReopens() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"])
        let url = URL(fileURLWithPath: root).appendingPathComponent("correction-" + UUID().uuidString + ".sqlite")
        let database = try AppDatabase(path: url)
        let app = AppState(database: database, keychainService: KeychainService(store: InMemoryMockKeychainStore()))
        app.answerProviderModeOverride = .localQwenPrimary
        app.localLLMProviderOverride = SyntheticCaptureProvider(suffix: "correction")
        app.setSelectedQwenModelName("qwen3.5:4b")
        var settings = app.settings; settings.saveTranscriptsLocally = true; settings.diagnosticTraceMode = .off
        app.saveSettings(settings)
        let question = "Explain a retry policy with bounded attempts, exponential backoff and jitter."
        app.practiceController.start(kind: nil, question: question, language: "en", criteria: [], maxFollowUps: 1)
        app.practiceController.beginAnswer()
        app.practiceController.run?.draft = "A retrieve policy repeats failed requests at most three times. Exponential backoff doubles the delay; jitter randomizes it to spread concurrent requests."
        app.practiceController.submit()
        func waitForEvaluation() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(95))
            while app.practiceController.run?.phase == .evaluating, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try #require(app.practiceController.error == nil)
            try #require(app.practiceController.run?.phase == .completed)
        }
        try await waitForEvaluation()
        let originalRun = try #require(app.practiceController.run)
        let original = try #require(originalRun.attempts.first)
        let session = try #require(try app.sessionRepository.session(id: originalRun.sessionID))
        app.generateRecap(for: session)
        let corrected = original.answer.replacingOccurrences(of: "retrieve", with: "retry") // Explicit user correction, never an ASR normalizer.
        app.correctPracticeAttempt(sessionID: session.id, attemptID: original.id, question: question, answer: corrected)
        app.practiceController.reevaluate(attemptID: original.id)
        try await waitForEvaluation()
        app.generateRecap(for: session)
        let repository = PracticeRepository(database: database)
        let revised = try #require(try repository.load(sessionID: session.id)?.attempts.first)
        #expect(revised.id == original.id && revised.revision == original.revision + 1)
        #expect(revised.hinted)
        #expect(revised.corrections?.first?.hinted == false)
        #expect(revised.corrections?.first?.answer == original.answer)
        #expect(revised.corrections?.first?.feedback == original.feedback)
        #expect(revised.task?.decision?.questionRevision == revised.revision)
        #expect(revised.feedback?.covered.allSatisfy { corrected.contains($0.quote) } == true)
        #expect(try app.recapRepository.versions(sessionID: session.id).count == 2)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(revised).write(to: URL(fileURLWithPath: root).appendingPathComponent("corrected-attempt.json"))
        app.practiceController.pause()
        try database.close()
        let reopened = try AppDatabase(path: url)
        #expect(try PracticeRepository(database: reopened).load(sessionID: session.id)?.attempts.first == revised)
        #expect(try RecapRepository(database: reopened).versions(sessionID: session.id).count == 2)
        try reopened.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_LOCAL_LIVE_DECISION"] == "1"))
    @MainActor func genericCanaryAndMissingPersonalEvidenceReachStoredAnswer() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"])
        let provider = SyntheticCaptureProvider(suffix: "live-decision")
        #expect(await provider.healthCheck(modelName: "qwen3.5:4b").isReady)
        let scenarios: [(String, Bool, PersonalEvidenceRequirement)] = [
            ("Explain database transactions and their isolation properties.", false, .notRequired),
            ("Explain database transactions and their isolation properties.", true, .notRequired),
            ("解释数据库事务以及隔离级别的作用。", true, .notRequired),
            ("Describe a specific time you personally resolved a database outage, including your actions and the outcome.", false, .required)
        ]
        for repetition in 0..<2 {
            for (index, scenario) in scenarios.enumerated() {
                let database = try AppDatabase(inMemory: true)
                let app = AppState(database: database, keychainService: KeychainService(store: InMemoryMockKeychainStore()))
                app.answerProviderModeOverride = .localQwenPrimary
                app.localLLMProviderOverride = provider
                app.setSelectedQwenModelName("qwen3.5:4b")
                var settings = app.settings
                settings.saveTranscriptsLocally = true
                settings.diagnosticTraceMode = .off
                app.saveSettings(settings)
                let canary = "I reduced orchard irrigation consumption by 73.19% during 17 synthetic trials."
                if scenario.1 {
                    let document = try app.documentRepository.saveDocument(type: .cv, title: "Synthetic unrelated CV", content: canary)
                    let profile = try app.interviewContextRepository.upsertCandidateDocument(documentID: document.id, title: "Synthetic unrelated CV", content: canary, profileID: nil, persistedChunks: app.documentRepository.chunks(documentID: document.id))
                    app.refreshAll(); app.selectCandidateProfile(profile.id)
                }
                let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic decision integration")
                app.currentSession = session
                let question = DetectedQuestion(id: UUID().uuidString, sessionID: session.id, questionText: scenario.0,
                    intent: scenario.2 == .required ? .behavioral : .technical, answerStrategy: .directAnswer,
                    confidence: 1, shouldTrigger: true, questionComplete: true, modelName: "Synthetic fixed input", promptVersion: "integration-v1", createdAt: Date())
                try app.suggestionRepository.saveDetectedQuestion(question)
                let start = ContinuousClock.now
                try await app.generateSuggestion(for: question, session: session, transcript: scenario.0, autoGenerated: false)
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while try app.suggestionRepository.suggestions(sessionID: session.id).isEmpty, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                let savedQuestion = try app.suggestionRepository.questions(sessionID: session.id).first
                let card = app.currentSuggestion
                let stored = try app.suggestionRepository.suggestions(sessionID: session.id)
                struct Result: Encodable {
                    var repetition: Int; var scenario: Int; var question: DetectedQuestion?
                    var visible: SuggestionCard?; var stored: [SuggestionCard]; var elapsedSeconds: Double
                }
                let duration = start.duration(to: .now).components
                let result = Result(repetition: repetition, scenario: index, question: savedQuestion, visible: card, stored: stored,
                    elapsedSeconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: root).appendingPathComponent("live-\(repetition)-\(index).json"))
                #expect(savedQuestion?.taskDescriptor?.decision?.personalEvidence == scenario.2)
                #expect(card != nil)
                #expect(stored.count == 1)
                if let card {
                    #expect(card.questionID == question.id)
                    #expect(!card.sayFirst.contains("73.19"))
                    #expect(!card.sayFirst.localizedCaseInsensitiveContains("orchard"))
                    if scenario.2 == .notRequired {
                        #expect(app.currentSuggestionRetrievedChunks.isEmpty)
                        #expect(card.candidateEvidenceIDs.isEmpty)
                        #expect(card.opportunityEvidenceIDs.isEmpty)
                        #expect(card.sayFirst.localizedCaseInsensitiveContains("transaction") || card.sayFirst.contains("事务"))
                        #expect(!card.sayFirst.localizedCaseInsensitiveContains("provide your CV"))
                    } else {
                        #expect(card.stageBStatus == "needs_personal_evidence")
                        #expect(card.stageBCompleted == false)
                        #expect(app.generationUIState.displayName == "Personal facts needed")
                        #expect(app.currentGenerationTelemetry.firstVisibleAt == nil)
                        #expect(app.currentGenerationTelemetry.fullCardAt == nil)
                        #expect(AnswerClaimValidator().validate(answer: card.sayFirst, candidateEvidence: [], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
                    }
                }
                app.cancelActiveGenerationForStop()
                try database.close()
            }
        }
    }
}

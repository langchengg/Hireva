import Combine
import Foundation
import os
import Testing
@testable import Hireva

/// Synthetic development scenarios through the actual feature/repositories.
/// Root runs this opt-in filter alone, after ordinary suites; no concurrent GPU
/// inference. Semantic review remains explicit, separate from mechanical pass.
@MainActor
struct PracticeBroadLocalScenarioTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_PRACTICE_CRITERION_MICRO"] == "1"),
          .timeLimit(.minutes(4)))
    func frozenChineseShortAnswerUsesActualEvaluatorWithinTwoRequests() async throws {
        struct Frozen: Decodable {
            let scenarioID, questionID, attemptID, question, answer: String
            let revision: Int
            let contextSnapshotID: String?
            let task: InterviewTaskDescriptor
        }
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"]))
        let file = try #require(Bundle.module.url(forResource: "PracticeScopedAcceptedContradictions", withExtension: "json"))
        let rows = try JSONDecoder().decode([Frozen].self, from: Data(contentsOf: file))
        for scenarioID in ["cache-short-correct-zh-original", "cache-short-correct-zh-revised"] {
        let row = try #require(rows.first { $0.scenarioID == scenarioID })
        let artifacts = root.appendingPathComponent(scenarioID, isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try #require(row.task.decision != nil && row.task.decision?.questionRevision == row.revision)
        var attempt = PracticeAttempt(questionID: row.questionID, question: row.question, answer: row.answer,
            contextSnapshotID: row.contextSnapshotID, revision: row.revision, hinted: false,
            skipped: false, source: "synthetic-frozen-criterion-diagnostic", task: row.task)
        attempt.id = row.attemptID
        let frozenAttempt = attempt
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(frozenAttempt), to: artifacts.appendingPathComponent("criterion-frozen-attempt.json"))
        let capture = SyntheticCaptureProvider(suffix: "criterion-micro-" + scenarioID, expectedSourceEvidence: "")
        let provider = PracticeSubsetRequestBudget(base: capture, limit: 2)
        do {
            let feedback = try await GenerationCoordinator.withTimeout(seconds: 90) {
                try await PracticeController.evaluate(attempt: frozenAttempt, task: row.task, attachment: nil,
                    evidence: [], provider: provider, model: "qwen3.5:4b")
            }
            try write(encoder.encode(feedback), to: artifacts.appendingPathComponent("criterion-feedback.json"))
        } catch {
            try write(JSONSerialization.data(withJSONObject: ["failure": error.localizedDescription]),
                to: artifacts.appendingPathComponent("criterion-failure.json"))
            Issue.record("Criterion diagnostic returned no admitted feedback: \(error)")
        }
        await capture.cancelAndJoinCaptures()
        try write(JSONSerialization.data(withJSONObject: ["componentGenerateRequests": provider.requestCount,
            "maximumGenerateRequests": 2, "scope": "actual evaluator development diagnostic; not full16"]),
            to: artifacts.appendingPathComponent("criterion-request-count.json"))
        #expect(provider.requestCount <= 2)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_PRACTICE_BROAD_SCENARIOS"] == "1"),
          .timeLimit(.minutes(30)))
    func originalsAndCorrectionsKeepAllSixteenPredeclaredRows() async throws {
        let artifactPath = try #require(ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"])
        let artifacts = URL(fileURLWithPath: artifactPath, isDirectory: true)
        let fixtureURL = try #require(Bundle.module.url(forResource: "practice_broad_synthetic_development", withExtension: "json"))
        let bytes = try Data(contentsOf: fixtureURL)
        let declarations = try JSONDecoder().decode(Declarations.self, from: bytes)
        try #require(declarations.fixtures.count == 16)
        #expect(declarations.labelsFrozenBeforeAnyNewModelRun)
        let results = try await evaluateDeclaredConversations(declarations.fixtures, declarationData: bytes,
            artifacts: artifacts, declarationName: "practice-broad-declarations.json",
            resultName: "practice-broad-results.json", expectedGroups: 8, requestLimit: 10)
        #expect(results.count == 16)
        // Actual UUID receipts count model requests; 80 remains the full-set
        // maximum budget, not a claim that every request was made.
        #expect(results.allSatisfy { $0.acceptedFeedback })
    }

    /// Development failure microgate only. It reuses the exact full16 fixture
    /// bytes and the same feature/correction/repository path, never a new gold.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_PRACTICE_FAILURE_SUBSET"] == "1"),
          .timeLimit(.minutes(5)))
    func cacheWrongTopicChineseOriginalAndRevisionKeepTwoDeclaredRows() async throws {
        let artifactPath = try #require(ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"])
        let artifacts = URL(fileURLWithPath: artifactPath, isDirectory: true)
        let fixtureURL = try #require(Bundle.module.url(forResource: "practice_broad_synthetic_development", withExtension: "json"))
        let bytes = try Data(contentsOf: fixtureURL)
        let declarations = try JSONDecoder().decode(Declarations.self, from: bytes)
        try #require(declarations.fixtures.count == 16)
        #expect(declarations.labelsFrozenBeforeAnyNewModelRun)
        let selectedIDs = ["cache-wrong-topic-zh-original", "cache-wrong-topic-zh-revised"]
        let subset = declarations.fixtures.filter { selectedIDs.contains($0.scenarioID) }
        try #require(subset.count == 2 && Set(subset.map(\.scenarioID)) == Set(selectedIDs))
        let model = ProcessInfo.processInfo.environment["HIREVA_PRACTICE_DIAGNOSTIC_MODEL"] ?? "qwen3.5:4b"
        try #require(["qwen3.5:4b", "qwen3-vl:4b-instruct-q4_K_M", "gemma4:26b", "qwen3.5:9b-q4_K_M"].contains(model))
        let attachment = try ProcessInfo.processInfo.environment["HIREVA_PRACTICE_DIAGNOSTIC_ATTACHMENT"].map { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            try #require(url.deletingLastPathComponent() == artifacts.deletingLastPathComponent().standardizedFileURL)
            return try MaterialExtractionService.extract(url: url).0
        }
        let scope: [String: Any] = ["scope": "DEVELOPMENT_FAILURE_SUBSET_NOT_FULL16_NOT_HOLDOUT",
            "fullDeclarationRows": declarations.fixtures.count, "selectedRows": subset.count,
            "selectedScenarioIDs": selectedIDs, "maximumGenerateRequests": 8,
            "quality": "Mechanical admission and raw-output semantic review are separate; this subset never replaces the full16 result."]
        try write(JSONSerialization.data(withJSONObject: scope, options: [.prettyPrinted, .sortedKeys]),
            to: artifacts.appendingPathComponent("practice-failure-subset-scope.json"))
        let results = try await evaluateDeclaredConversations(subset, declarationData: bytes,
            artifacts: artifacts, declarationName: "practice-failure-subset-full-declarations.json",
            resultName: "practice-failure-subset-results.json", expectedGroups: 1, requestLimit: 8, model: model, attachment: attachment)
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.acceptedFeedback })
    }

    private func evaluateDeclaredConversations(_ fixtures: [Declaration], declarationData: Data,
        artifacts: URL, declarationName: String, resultName: String,
        expectedGroups: Int, requestLimit: Int? = nil, model: String = "qwen3.5:4b", attachment: ExtractedMaterial? = nil) async throws -> [Result] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(declarationData, to: artifacts.appendingPathComponent(declarationName))
        var results = fixtures.map { Result(scenarioID: $0.scenarioID) }
        func saveResults() throws {
            try write(encoder.encode(results), to: artifacts.appendingPathComponent(resultName))
        }
        try saveResults() // All rows exist before any inference, including failure/unexecuted rows.
        let groups = Dictionary(grouping: fixtures) { $0.conversationGroup + "-" + $0.language }
        try #require(groups.count == expectedGroups)
        for groupID in groups.keys.sorted() {
            try Task.checkCancellation()
            let versions = try #require(groups[groupID])
            let original = try #require(versions.first { $0.stage == "original" })
            let revised = try #require(versions.first { $0.stage == "revised" })
            let scene = try Scene(artifacts: artifacts, groupID: groupID)
            let app = scene.app
            app.answerProviderModeOverride = .localQwenPrimary
            let base = model == "qwen3.5:9b-q4_K_M"
                ? OllamaQwenProvider(baseURL: URL(string: "http://127.0.0.1:11535")!) : OllamaQwenProvider()
            let capture = SyntheticCaptureProvider(suffix: "broad-" + groupID, expectedSourceEvidence: "", base: base)
            let requestBudget = requestLimit.map { PracticeSubsetRequestBudget(base: capture, limit: $0) }
            if let requestBudget { app.localLLMProviderOverride = requestBudget }
            else { app.localLLMProviderOverride = capture }
            app.setSelectedQwenModelName(model)
            var settings = app.settings; settings.saveTranscriptsLocally = true; settings.diagnosticTraceMode = .off
            app.saveSettings(settings)
            do {
                let controller = app.practiceController
                controller.start(kind: original.selectedTask, question: original.question,
                    language: original.language, criteria: original.rubric, maxFollowUps: 1)
                if let attachment { controller.attach(attachment) }
                controller.beginAnswer()
                controller.run?.draft = original.answer
                var rowsSucceeded = 0
                let started = ContinuousClock.now
                try await evaluated(controller, label: original.scenarioID) { controller.submit() }
                let initialRun = try #require(controller.run)
                let initial = try #require(initialRun.attempts.first)
                let sessionID = initialRun.sessionID
                record(original, controller: controller, started: started, into: &results)
                if controller.error == nil, initial.feedback != nil {
                    rowsSucceeded += 1
                    app.generateRecap(for: try #require(try app.sessionRepository.session(id: sessionID)))
                }
                try saveResults()

                // Use the actual application correction and re-evaluation APIs.
                // Expected coverage is not placed in any provider input.
                app.correctPracticeAttempt(sessionID: sessionID, attemptID: initial.id,
                    question: revised.question, answer: revised.answer)
                let revisedStart = ContinuousClock.now
                try await evaluated(controller, label: revised.scenarioID) { controller.reevaluate(attemptID: initial.id) }
                let latest = try #require(controller.run?.attempts.first)
                record(revised, controller: controller, started: revisedStart, into: &results)
                #expect(latest.id == initial.id)
                #expect(latest.revision == initial.revision + 1)
                #expect(latest.answer == revised.answer)
                #expect(latest.corrections?.first?.answer == initial.answer)
                #expect(latest.corrections?.first?.feedback == initial.feedback)
                #expect(latest.task?.decision?.questionRevision == latest.revision)
                if controller.error == nil, latest.feedback != nil {
                    rowsSucceeded += 1
                    app.generateRecap(for: try #require(try app.sessionRepository.session(id: sessionID)))
                }
                #expect(try app.recapRepository.versions(sessionID: sessionID).count == rowsSucceeded)
                try saveResults()
                await scene.close(capture: capture)
                let reopened = try AppDatabase(path: scene.databaseURL)
                do {
                    #expect(try PracticeRepository(database: reopened).load(sessionID: sessionID)?.attempts.first == latest)
                    #expect(try RecapRepository(database: reopened).versions(sessionID: sessionID).count == rowsSucceeded)
                    for declaration in versions {
                        let index = try #require(results.firstIndex { $0.scenarioID == declaration.scenarioID })
                        results[index].reopenedLatestVersion = latest.revision
                    }
                    try reopened.close()
                } catch { try? reopened.close(); throw error }
                try saveResults()
            } catch {
                // Cancellation first ends the logical event wait; shutdown then
                // cancels and joins feature/network work before closing own DB.
                await scene.close(capture: capture)
                for declaration in versions {
                    if let index = results.firstIndex(where: { $0.scenarioID == declaration.scenarioID }),
                       results[index].status == "NOT RUN" {
                        results[index].status = "FAILED BEFORE COMPLETION"
                        results[index].failure = error.localizedDescription
                    }
                }
                try saveResults()
                if error is CancellationError { throw error }
                Issue.record("Synthetic practice conversation \(groupID) failed: \(error)")
            }
            if let requestBudget {
                #expect(requestBudget.requestCount <= requestBudget.limit)
                let receipt: [String: Any] = ["scope": expectedGroups == 1 ? "DEVELOPMENT_FAILURE_SUBSET_NOT_FULL16_NOT_HOLDOUT" : "DEVELOPMENT_FULL16_NOT_HOLDOUT",
                    "conversationGroup": groupID,
                    "componentGenerateRequestAttempts": requestBudget.requestCount, "maximumGenerateRequests": requestBudget.limit,
                    "ordinaryRoutePrimaryCriticMaximum": 6,
                    "ordinaryRoutePrimaryCriticScope": "Two revisions with one routing request, primary and critic each; excludes format repair and evidence review. The actual counter and maximumGenerateRequests enforce the total budget.",
                    "acceptedMissingQuestionRepairsMaximum": 2]
                try write(JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]),
                    to: artifacts.appendingPathComponent(expectedGroups == 1 ? "practice-failure-subset-request-count.json" : "practice-broad-\(groupID)-request-count.json"))
            }
        }
        return results
    }

    /// Empty input is UI admission, not a model-competence failure. These two
    /// keyboard-only cases do not enter the sixteen model denominator.
    @Test(.timeLimit(.minutes(1)), arguments: ["en", "zh"])
    func emptyAnswersDoNotCreateAttemptsOrCallEvaluation(language: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("practice-empty-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = try Scene(artifacts: root, groupID: language)
        let provider = EmptyAnswerProbeProvider()
        let app = scene.app
        app.localLLMProviderOverride = provider
        var settings = app.settings; settings.saveTranscriptsLocally = true; app.saveSettings(settings)
        do {
            let controller = app.practiceController
            let question = InterviewTaskKind.generalKnowledge.starter(chinese: language == "zh")
            controller.start(kind: .generalKnowledge, question: question, language: language,
                criteria: InterviewTaskKind.generalKnowledge.criteria, maxFollowUps: 0)
            controller.beginAnswer()
            controller.run?.draft = " \n\t"
            let sessionID = try #require(controller.run?.sessionID)
            controller.submit()
            #expect(controller.run?.phase == .answering)
            #expect(controller.run?.attempts.isEmpty == true)
            #expect(controller.error?.contains("No answer captured") == true)
            #expect(await provider.calls == 0)
            let stored = try #require(try PracticeRepository(database: scene.database).load(sessionID: sessionID))
            #expect(stored.phase == .answering)
            #expect(stored.attempts.isEmpty)
            await scene.close()
        } catch { await scene.close(); throw error }
    }

    /// Three controlled provider replies deliberately ignore cancellation until
    /// released. This tests real controller/correction/repository publication,
    /// not model quality and not a second implementation of the evaluator.
    @Test(.timeLimit(.minutes(1)), arguments: ["en", "zh"])
    func twoCorrectionsRejectBothEarlierEvaluationReplies(language: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("practice-two-corrections-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = try Scene(artifacts: root, groupID: language)
        let provider = LateReplyProvider()
        let app = scene.app
        app.localLLMProviderOverride = provider
        var settings = app.settings; settings.saveTranscriptsLocally = true; app.saveSettings(settings)
        let question = language == "zh" ? "说明有界重试机制。" : "Explain bounded retries."
        let answers = language == "zh" ? ["原文：限制重试次数。", "修订一：设置有限重试预算。", "修订二：达到预算就停止重试。"]
            : ["Original: bound the number of retries.", "First correction: set a finite retry budget.", "Second correction: stop retrying at the budget."]
        let trace = TestEventWaitTrace(label: "PracticeTwoCorrections-" + language)
        func releaseAndClose() async {
            await provider.releaseAll()
            provider.finishEnteredEvents()
            await scene.close() // Joins both retiring evaluations only after gates release.
        }
        do {
            let controller = app.practiceController
            controller.start(kind: .generalKnowledge, question: question, language: language,
                criteria: [language == "zh" ? "说明机制" : "Explain the mechanism"], maxFollowUps: 0)
            controller.beginAnswer()
            controller.run?.draft = answers[0]
            controller.submit()
            _ = try await trace.nextEvent(in: provider.entered[0], event: "original.provider_entered")
            let initial = try #require(controller.run?.attempts.first)
            let sessionID = try #require(controller.run?.sessionID)
            app.correctPracticeAttempt(sessionID: sessionID, attemptID: initial.id, question: question, answer: answers[1])
            controller.reevaluate(attemptID: initial.id)
            _ = try await trace.nextEvent(in: provider.entered[1], event: "revision1.provider_entered")
            app.correctPracticeAttempt(sessionID: sessionID, attemptID: initial.id, question: question, answer: answers[2])
            // Evaluation is already started by reevaluate. The same production
            // terminal observer is registered before opening its held provider.
            try await evaluated(controller, label: "PracticeLatest-" + language) {
                controller.reevaluate(attemptID: initial.id)
                _ = try await trace.nextEvent(in: provider.entered[2], event: "revision2.provider_entered")
                await provider.release(2)
            }
            let latest = try #require(controller.run?.attempts.first)
            #expect(latest.id == initial.id)
            #expect(latest.revision == initial.revision + 2)
            #expect(latest.answer == answers[2])
            #expect(latest.feedback?.covered.map(\.quote) == [answers[2]])
            #expect(await provider.reviewedAnswers == [answers[2]])
            #expect(latest.corrections?.map(\.answer) == [answers[0], answers[1]])
            #expect(latest.task?.decision?.questionRevision == latest.revision)
            #expect(controller.run?.phase == .completed)
            #expect(controller.error == nil)
            await releaseAndClose()
            #expect(controller.run?.attempts.first == latest)
            #expect(controller.run?.phase == .completed)
            #expect(await provider.reviewedAnswers == [answers[2]])
            let reopened = try AppDatabase(path: scene.databaseURL)
            do {
                #expect(try PracticeRepository(database: reopened).load(sessionID: sessionID)?.attempts.first == latest)
                try reopened.close()
            } catch { try? reopened.close(); throw error }
        } catch { await releaseAndClose(); throw error }
    }

    /// Observe the committed run update. Only a String crosses the test
    /// AsyncStream boundary; the event is distinct from persistence success.

    private func evaluated(_ controller: PracticeController, label: String,
        begin: () async throws -> Void) async throws {
        let events = AsyncStream<String>.makeStream()
        let subscription = controller.runUpdates.dropFirst().sink { run in
            if let phase = run?.phase, [.completed, .failed, .paused, .cancelled].contains(phase) {
                events.continuation.yield(phase.rawValue)
            }
        }
        defer { subscription.cancel(); events.continuation.finish() }
        try await begin()
        try #require([.evaluating, .completed, .failed, .paused, .cancelled].contains(controller.run?.phase))
        _ = try await TestEventWaitTrace(label: label).nextEvent(in: events.stream, event: "evaluation.terminal")
    }

    private func record(_ declaration: Declaration, controller: PracticeController,
        started: ContinuousClock.Instant, into results: inout [Result]) {
        guard let index = results.firstIndex(where: { $0.scenarioID == declaration.scenarioID }) else { return }
        let duration = started.duration(to: .now).components
        let attempt = controller.run?.attempts.first
        results[index].controllerSubmitToTerminalMS = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        results[index].phase = controller.run?.phase.rawValue
        results[index].attempt = attempt
        results[index].failure = controller.error
        results[index].semanticReview = "PENDING: verify first missing criterion, prose/map consistency, useful original-question reference and no invented past result; raw unique model outputs retained"
        guard controller.error == nil, controller.run?.phase == .completed,
              let feedback = attempt?.feedback else {
            results[index].status = "FAIL"
            Issue.record("Synthetic practice \(declaration.scenarioID) returned no accepted feedback")
            return
        }
        results[index].acceptedFeedback = true
        results[index].status = "ACCEPTED; SEMANTIC REVIEW PENDING"
        results[index].expectedPersonalEvidenceMatches = attempt?.task?.personalEvidence.rawValue == declaration.expectedPersonalEvidence
        #expect(attempt?.question == declaration.question)
        #expect(attempt?.answer == declaration.answer)
        #expect(attempt?.task?.criteria == declaration.rubric)
        #expect(attempt?.task?.personalEvidence.rawValue == declaration.expectedPersonalEvidence)
        let actualCovered = Set(feedback.covered.compactMap { coverage in
            declaration.rubric.firstIndex(of: coverage.criterion).map { "r\($0)" }
        })
        results[index].actualCoveredIDs = actualCovered.sorted()
        results[index].expectedCoverageMatches = actualCovered == Set(declaration.expectedCoveredIDs)
        #expect(results[index].expectedCoverageMatches == true)
        let actualMissing = feedback.missing.compactMap { criterion in
            declaration.rubric.firstIndex(of: criterion).map { "r\($0)" }
        }
        results[index].actualMissingIDs = actualMissing
        results[index].expectedCoverageMatches = results[index].expectedCoverageMatches == true && actualMissing == declaration.expectedMissingIDs
        #expect(actualMissing == declaration.expectedMissingIDs)
        if results[index].expectedCoverageMatches != true || results[index].expectedPersonalEvidenceMatches != true {
            results[index].status = "ACCEPTED; FROZEN LABEL MISMATCH"
        }
        #expect(feedback.covered.allSatisfy { declaration.answer.contains($0.quote) })
        if declaration.expectedMissingIDs.isEmpty { #expect(feedback.followUp == nil) }
        else { #expect(feedback.followUp?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }
        // Nonempty is only mechanical admission. This test intentionally does
        // not label that check as semantic first-gap acceptance.
    }

    private struct Declarations: Decodable {
        let labelsFrozenBeforeAnyNewModelRun: Bool
        let fixtures: [Declaration]
    }
    private struct Declaration: Decodable {
        let scenarioID: String
        let conversationGroup: String
        let language: String
        let stage: String
        let selectedTask: InterviewTaskKind
        let question: String
        let answer: String
        let rubric: [String]
        let expectedCoveredIDs: [String]
        let expectedMissingIDs: [String]
        let expectedPersonalEvidence: String
    }
    private struct Result: Encodable {
        let scenarioID: String
        var status = "NOT RUN"
        var phase: String?
        var failure: String?
        var attempt: PracticeAttempt?
        var controllerSubmitToTerminalMS: Double?
        var reopenedLatestVersion: Int?
        var actualCoveredIDs: [String]?
        var actualMissingIDs: [String]?
        var expectedCoverageMatches: Bool?
        var expectedPersonalEvidenceMatches: Bool?
        var acceptedFeedback = false
        var semanticReview = "NOT RUN"
    }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    @MainActor
    private final class Scene {
        let app: AppState
        let database: AppDatabase
        let databaseURL: URL
        let suiteName: String
        let defaults: UserDefaults
        private var closed = false
        init(artifacts: URL, groupID: String) throws {
            let id = UUID().uuidString
            suiteName = "com.langcheng.Hireva.tests.practiceBroad." + id
            guard let defaults = UserDefaults(suiteName: suiteName) else { throw TestEventWaitFailure.endedBeforeEvent }
            self.defaults = defaults
            databaseURL = artifacts.appendingPathComponent("practice-broad-\(groupID)-\(id).sqlite")
            database = try AppDatabase(path: databaseURL)
            app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
                llmRouter: LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: HermeticTestLLMClient()]),
                permissionService: HermeticPermissionService(), keychainService: KeychainService(store: InMemoryMockKeychainStore()),
                dialogueDefaults: defaults)
        }
        func close(capture: SyntheticCaptureProvider? = nil) async {
            guard !closed else { return }
            closed = true
            await app.shutdownForTesting()
            await capture?.cancelAndJoinCaptures()
            do { try database.close() } catch { Issue.record("Own synthetic practice DB close failed: \(error)") }
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

private actor EmptyAnswerProbeProvider: LocalLLMProvider {
    nonisolated let id = "empty-answer-local-probe"
    nonisolated let displayName = "Synthetic empty answer probe"
    private(set) var calls = 0
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        calls += 1
        throw PracticeBroadFixtureFailure.unexpectedRequest
    }
}

private actor PracticeReplyReleaseGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume(); waiter = nil
    }
}

private actor LateReplyProvider: LocalLLMProvider {
    nonisolated let id = "controlled-two-correction-local-provider"
    nonisolated let displayName = "Synthetic held feedback fixture"
    nonisolated let entered: [AsyncStream<Void>]
    private nonisolated let enteredContinuations: [AsyncStream<Void>.Continuation]
    private let gates = (0..<3).map { _ in PracticeReplyReleaseGate() }
    private var evaluations = 0
    private var initialInputs: [String: (model: String, payload: [String: String], draft: PracticeEvaluationPayload)] = [:]
    private(set) var reviewedAnswers: [String] = []
    init() {
        let events = (0..<3).map { _ in AsyncStream<Void>.makeStream() }
        entered = events.map(\.stream)
        enteredContinuations = events.map(\.continuation)
    }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let output: String
        if request.systemPrompt?.contains("Independently critique the complete original answer") == true {
            let payload = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            #expect(payload["draft_feedback"] == nil && payload["draft_first_missing_rubric_id"] == nil)
            let answer = try #require(payload["answer"])
            let initial = try #require(initialInputs[answer])
            for field in ["question", "answer", "rubric", "source_evidence", "attachment"] {
                guard payload[field] == initial.payload[field] else { throw PracticeBroadFixtureFailure.unexpectedRequest }
            }
            guard request.modelName == initial.model else {
                throw PracticeBroadFixtureFailure.unexpectedRequest
            }
            // Reviews have no held initial gate and cannot consume one of the
            // three original/revision slots or fabricate another answer.
            reviewedAnswers.append(answer)
            var accepted = initial.draft
            accepted.reviewOutcome = "accepted"
            output = String(decoding: try JSONEncoder().encode(accepted), as: UTF8.self)
        } else if request.systemPrompt?.contains("Evaluate this practice answer") == true {
            let payload = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            let index = evaluations; evaluations += 1
            guard index < gates.count else { throw PracticeBroadFixtureFailure.unexpectedRequest }
            let answer = payload["answer"] ?? ""
            enteredContinuations[index].yield(())
            await gates[index].hold() // Intentionally ignores cancellation; owning cleanup releases all gates.
            let fixture = PracticeEvaluationPayload(coverage: ["r0": .some(answer)],
                suggestion: payload["feedback_language"] == "zh" ? "合成受控反馈。" : "Synthetic controlled reply",
                followUp: nil, reason: payload["feedback_language"] == "zh" ? "已覆盖所给标准。" : "The one supplied criterion is covered.",
                reference: payload["reference_language"] == "zh" ? "限定重试次数，达到预算就停止。" : "Bound retries and stop at the retry budget.")
            initialInputs[answer] = (request.modelName, payload, fixture)
            output = String(decoding: try JSONEncoder().encode(fixture), as: UTF8.self)
        } else {
            output = #"{"task":"generalKnowledge","personalEvidence":"notRequired","basis":"generalKnowledge","relation":"independent","clarification":""}"#
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
    func release(_ index: Int) async { await gates[index].release() }
    func releaseAll() async { for gate in gates { await gate.release() } }
    nonisolated func finishEnteredEvents() { enteredContinuations.forEach { $0.finish() } }
}

private enum PracticeBroadFixtureFailure: Error { case unexpectedRequest }

/// Test-only component request budget. It never rewrites input/model output;
/// the underlying capture still owns and joins each exact network producer.
private struct PracticeSubsetRequestBudget: LocalLLMProvider {
    let base: SyntheticCaptureProvider
    let limit: Int
    private let requested = OSAllocatedUnfairLock(initialState: 0)
    init(base: SyntheticCaptureProvider, limit: Int) { self.base = base; self.limit = limit }
    var requestCount: Int { requested.withLock { $0 } }
    var id: String { base.id }
    var displayName: String { base.displayName }
    func healthCheck(modelName: String) async -> LocalLLMHealth { await base.healthCheck(modelName: modelName) }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { base.pullModel(modelName) }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let permitted = requested.withLock { count -> Bool in
            guard count < limit else { return false }
            count += 1; return true
        }
        guard permitted else { throw MaterialError.invalid("The practice diagnostic exceeded its \(limit)-request local budget; no extra provider call was made.") }
        return try await base.generateAnswer(request: request)
    }
}

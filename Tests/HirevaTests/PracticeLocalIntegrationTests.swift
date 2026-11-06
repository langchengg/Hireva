import Foundation
import os
import Testing
@testable import Hireva

@Suite(.serialized)
struct PracticeLocalIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_LOCAL_PRACTICE"] == "1"))
    @MainActor func genericFollowUpDoesNotAcquirePersonalEvidenceRequirement() async throws {
        var task = InterviewTaskDescriptor(question: "What bottlenecks can arise under peak load and how would the design mitigate them?", kind: .systemDesign)
        task.criteria = [InterviewTaskKind.systemDesign.criteria[2]]
        #expect(!task.requiresPersonalEvidence)
        let answer = "Queue backpressure and provider rate limits are likely bottlenecks. Measure queue age and retry rate. Bound worker concurrency per provider and tenant, apply backpressure at the API, and scale workers only within provider limits. Partition queues to isolate noisy tenants."
        let attempt = PracticeAttempt(questionID: "synthetic-bottleneck", question: task.question, answer: answer, revision: 1, hinted: false, skipped: false, source: "synthetic-integration")
        let unrelatedCV = ProfileEvidence(id: "synthetic-cv", statement: "I built a university library catalog.", sourceDocumentID: "synthetic", sourceChunkID: nil, sourceSpan: nil, confidence: 0.8, evidenceType: .achievement, explicitness: .explicit)
        let feedback = try await evaluate(attempt: attempt, task: task, attachment: nil, evidence: [unrelatedCV], provider: SyntheticCaptureProvider(suffix: "generic-context", expectedSourceEvidence: ""), model: "qwen3.5:4b")
        #expect(feedback.covered.count == 1)
        #expect(feedback.missing.isEmpty)
        #expect(feedback.followUp == nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_LOCAL_PRACTICE"] == "1"))
    @MainActor func installedQwenEvaluatesChineseAndFocusedFollowUp() async throws {
        var task = InterviewTaskDescriptor(question: "如何用哈希表查找数组中和为目标值的两个数？说明复杂度和边界。", kind: .coding, language: "zh")
        task.explanationLanguage = "zh"
        let answer = "我会遍历数组，用哈希表保存已访问的数和下标。每次查找目标值减去当前数的差值，找到就返回两个不同下标。时间复杂度为 O(n)，额外空间为 O(n)。还需要测试重复数字、负数和不存在解的情况。"
        let attempt = PracticeAttempt(questionID: "synthetic-zh", question: task.question, answer: answer, revision: 0, hinted: false, skipped: false, source: "synthetic-integration")
        let feedback = try await evaluate(attempt: attempt, task: task, attachment: nil, evidence: [], provider: SyntheticCaptureProvider(suffix: "zh"), model: "qwen3.5:4b")
        #expect(!feedback.covered.isEmpty)
        #expect(feedback.covered.allSatisfy { answer.contains($0.quote) })
        #expect(feedback.reference.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) })
        var followUp = InterviewTaskDescriptor(question: "How would you handle duplicate delivery?", kind: .systemDesign)
        followUp.criteria = [InterviewTaskKind.systemDesign.criteria[3]]
        let followUpAnswer = "I would persist an idempotency key with each notification and use a unique constraint to reject duplicate deliveries. A retry uses the same key; failed delivery attempts go to a dead-letter queue for review. A unique constraint makes deduplication atomic but adds database write contention and retained-key storage. A separate eventually consistent cache reduces database load but can permit duplicates during races; I would prefer the database constraint when preventing duplicate delivery matters more than peak throughput."
        let next = PracticeAttempt(questionID: "synthetic-follow-up", question: followUp.question, answer: followUpAnswer, revision: 1, hinted: false, skipped: false, source: "synthetic-integration")
        let nextFeedback = try await evaluate(attempt: next, task: followUp, attachment: nil, evidence: [], provider: SyntheticCaptureProvider(suffix: "follow-up"), model: "qwen3.5:4b")
        #expect(nextFeedback.covered.count == 1)
        #expect(nextFeedback.missing.isEmpty)
        #expect(nextFeedback.followUp == nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_LOCAL_PRACTICE"] == "1"))
    @MainActor func installedQwenEvaluatesSyntheticAnswer() async throws {
        let task = InterviewTaskDescriptor(question: "Design a notification service. Clarify requirements, then explain components, data flow, and reliability trade-offs.", kind: .systemDesign)
        let answer = "I would first clarify expected volume, latency and delivery channels. An API accepts notification requests and persists jobs in a durable queue. Workers read jobs and call delivery providers. I have not yet explained retries or bottlenecks."
        let attempt = PracticeAttempt(questionID: "synthetic-q", question: task.question, answer: answer, revision: 0, hinted: false, skipped: false, source: "synthetic-integration")
        let feedback = try await evaluate(attempt: attempt, task: task, attachment: nil, evidence: [], provider: SyntheticCaptureProvider(), model: "qwen3.5:4b")
        #expect(!feedback.covered.isEmpty)
        #expect(feedback.reference.localizedCaseInsensitiveContains("queue") || feedback.reference.localizedCaseInsensitiveContains("worker"))
        #expect(feedback.covered.allSatisfy { answer.contains($0.quote) })
        #expect(Set(feedback.covered.map(\.criterion) + feedback.missing) == Set(task.criteria))
        // This frozen answer discloses an omission; it does not explain the
        // reliability/trade-off criterion. A literal quote alone is insufficient.
        let reliabilityCriterion = try #require(task.criteria.dropFirst(3).first)
        #expect(feedback.missing.contains(reliabilityCriterion))
        #expect(!feedback.covered.contains { $0.criterion == reliabilityCriterion })
        let bottleneckCriterion = try #require(task.criteria.dropFirst(2).first)
        #expect(feedback.missing.contains(bottleneckCriterion))
        #expect(!feedback.covered.contains { $0.criterion == bottleneckCriterion })
    }
    // A failed semantic assertion/request must join the real capture worker and
    // its exact URLSession producer before this serial model case exits.
    @MainActor private func evaluate(attempt: PracticeAttempt, task: InterviewTaskDescriptor,
        attachment: ExtractedMaterial?, evidence: [ProfileEvidence],
        provider: SyntheticCaptureProvider, model: String) async throws -> PracticeFeedback {
        do {
            let feedback = try await PracticeController.evaluate(attempt: attempt, task: task,
                attachment: attachment, evidence: evidence, provider: provider, model: model)
            await provider.cancelAndJoinCaptures()
            return feedback
        } catch {
            await provider.cancelAndJoinCaptures()
            throw error
        }
    }

}

/// Only called by the opt-in synthetic test above, never from product logging.
struct SyntheticCaptureProvider: LocalLLMProvider {
    var suffix = "en"
    var expectedSourceEvidence: String?
    let base: OllamaQwenProvider
    private let artifactDirectoryOverride: URL?
    private let captureWorkers = SyntheticCaptureWorkers()
    init(suffix: String = "en", expectedSourceEvidence: String? = nil,
         base: OllamaQwenProvider = OllamaQwenProvider(), artifactDirectory: URL? = nil) {
        self.suffix = suffix; self.expectedSourceEvidence = expectedSourceEvidence
        self.base = base
        self.artifactDirectoryOverride = artifactDirectory
    }
    var id: String { "synthetic-local-validation" }
    var displayName: String { "Installed Ollama, synthetic test only" }
    func healthCheck(modelName: String) async -> LocalLLMHealth { await base.healthCheck(modelName: modelName) }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let captureStarted = ContinuousClock.now
        let captureID = UUID().uuidString
        let captureSuffix = suffix
        let artifactDirectory = artifactDirectoryOverride ?? ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
        let input = request.prompt
        let owned: OllamaQwenProvider.OwnedAnswerStream
        do {
            // This is the actual component input, not reconstructed HTTP wire.
            // Optional values stay absent instead of inventing transport defaults.
            if let artifactDirectory {
                var object: [String: Any] = ["captureID": captureID, "recordKind": "LocalLLMRequest",
                    "modelName": request.modelName, "prompt": request.prompt,
                    "thinkingEnabled": request.thinkingEnabled]
                if let value = request.systemPrompt { object["systemPrompt"] = value }
                if let value = request.temperature { object["temperature"] = value }
                if let value = request.numPredict { object["numPredict"] = value }
                if let value = request.responseFormat { object["responseFormat"] = value }
                if let value = request.responseSchemaPropertyOrder { object["responseSchemaPropertyOrder"] = value }
                if let value = request.responseSchema {
                    object["responseSchema"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                }
                let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                try Self.writeArtifact(data, to: artifactDirectory.appendingPathComponent("synthetic-local-\(captureSuffix)-\(captureID)-request.json"))
                try Self.writeArtifact(data, to: artifactDirectory.appendingPathComponent("synthetic-local-\(captureSuffix)-request.json"))
            }

            // Input-only assertion for both actual evaluator phases. Never
            // inject a disposition into or otherwise rewrite real model output.
            if let expectedSourceEvidence,
               request.systemPrompt?.contains("Evaluate this practice answer") == true || request.systemPrompt?.contains("Independently critique the complete original answer") == true {
                let payload = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
                #expect(payload["source_evidence"] == expectedSourceEvidence)
            }
            owned = try await base.generateOwnedAnswer(request: request)
            // Cancellation can arrive after readiness returns but before this
            // request is handed to a capture worker. Retain and drain its exact
            // producer here rather than leaving an unconsumed compatibility stream.
            if Task.isCancelled {
                owned.producerTask.cancel()
                await owned.producerTask.value
                throw CancellationError()
            }
        } catch {
            try? Self.recordResult(directory: artifactDirectory, suffix: captureSuffix, captureID: captureID,
                input: input, output: "", error: error, streamFinished: false, cancelled: Task.isCancelled,
                captureStarted: captureStarted)
            throw error
        }
        return AsyncThrowingStream { continuation in
            let worker = Task {
                var captured = ""
                var streamFinished = false
                var firstTokenAt: ContinuousClock.Instant?
                do {
                    try await withTaskCancellationHandler {
                        try Task.checkCancellation()
                        for try await token in owned.stream {
                            try Task.checkCancellation()
                            if firstTokenAt == nil && !token.text.isEmpty { firstTokenAt = .now }
                            captured += token.text
                            continuation.yield(token)
                        }
                        streamFinished = true
                        // A token stream terminal does not prove its URLSession
                        // producer has left cleanup. The existing capture worker
                        // retains that exact handle through every exit path.
                        await owned.producerTask.value
                        try Task.checkCancellation()
                    } onCancel: {
                        owned.producerTask.cancel()
                    }
                    try Self.recordResult(directory: artifactDirectory, suffix: captureSuffix, captureID: captureID,
                        input: input, output: captured, error: nil, streamFinished: true, cancelled: Task.isCancelled,
                        captureStarted: captureStarted, firstTokenAt: firstTokenAt, diagnostics: base.lastGenerationDiagnostics)
                    continuation.finish()
                } catch {
                    owned.producerTask.cancel()
                    await owned.producerTask.value
                    try? Self.recordResult(directory: artifactDirectory, suffix: captureSuffix, captureID: captureID,
                        input: input, output: captured, error: error, streamFinished: streamFinished, cancelled: Task.isCancelled,
                        captureStarted: captureStarted, firstTokenAt: firstTokenAt, diagnostics: base.lastGenerationDiagnostics)
                    continuation.finish(throwing: error)
                }
            }
            captureWorkers.register(worker)
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    /// Called only after the owning feature consumer has stopped admission and joined.
    func cancelAndJoinCaptures() async { await captureWorkers.cancelAndJoin() }

    private static func recordResult(directory: URL?, suffix: String, captureID: String,
        input: String, output: String, error: Error?, streamFinished: Bool, cancelled: Bool,
        captureStarted: ContinuousClock.Instant, firstTokenAt: ContinuousClock.Instant? = nil,
        diagnostics: OllamaProviderDiagnostics? = nil) throws {
        guard let directory else { return }
        var object: [String: Any] = ["captureID": captureID, "recordKind": "LocalLLMTokenCapture",
            "output": output, "streamFinished": streamFinished, "taskCancelled": cancelled]
        let elapsed = captureStarted.duration(to: .now).components
        object["generate_entry_to_capture_terminal_ms"] = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        if let firstTokenAt {
            let first = captureStarted.duration(to: firstTokenAt).components
            object["generate_entry_to_first_formal_token_ms"] = Double(first.seconds) * 1000 + Double(first.attoseconds) / 1e15
        }
        if let error { object["error"] = error.localizedDescription }
        if let diagnostics {
            // These fixture-scoped opt-in gates consume each provider serially.
            // The provider's latest cache is not a request receipt under overlap.
            var snapshot: [String: Any] = ["endpoint": diagnostics.endpoint, "model": diagnostics.model,
                "responseSchema": diagnostics.responseSchema.rawValue, "streamCompleted": diagnostics.streamCompleted,
                "reasoningCharacters": diagnostics.reasoningCharacters, "contentChunksReceived": diagnostics.contentChunksReceived,
                "chunksReceived": diagnostics.chunksReceived, "firstContentObserved": diagnostics.firstContentObserved]
            if let value = diagnostics.doneReason { snapshot["done_reason"] = value }
            if let value = diagnostics.promptEvalCount { snapshot["prompt_eval_count"] = value }
            if let value = diagnostics.evalCount { snapshot["eval_count"] = value }
            if let value = diagnostics.totalDurationNS { snapshot["total_duration"] = value }
            if let value = diagnostics.loadDurationNS { snapshot["load_duration"] = value }
            if let value = diagnostics.promptEvalDurationNS { snapshot["prompt_eval_duration"] = value }
            if let value = diagnostics.evalDurationNS { snapshot["eval_duration"] = value }
            if let value = diagnostics.finalErrorCategory { snapshot["finalErrorCategory"] = value.rawValue }
            object["providerDiagnostics"] = snapshot
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try writeArtifact(data, to: directory.appendingPathComponent("synthetic-local-\(suffix)-\(captureID)-result.json"))
        try writeArtifact(Data(output.utf8), to: directory.appendingPathComponent("synthetic-local-\(suffix)-feedback.json"))
        if suffix == "routing" {
            object["input"] = input
            try writeArtifact(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                to: directory.appendingPathComponent("routing-wire-\(captureID).json"))
        }
    }

    private static func writeArtifact(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Test-only producer ownership. Handles are copied under the lock; cancellation
/// and joining occur after unlocking. The provider is scoped to one fixture.
private final class SyntheticCaptureWorkers: Sendable {
    private let handles = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
    func register(_ task: Task<Void, Never>) { handles.withLock { $0.append(task) } }
    func cancelAndJoin() async {
        let tasks = handles.withLock { $0 }
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
    }
}

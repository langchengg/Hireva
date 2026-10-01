import Foundation
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
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil, evidence: [unrelatedCV], provider: SyntheticCaptureProvider(suffix: "generic-context", expectedSourceEvidence: ""), model: "qwen3.5:4b")
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
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil, evidence: [], provider: SyntheticCaptureProvider(suffix: "zh"), model: "qwen3.5:4b")
        #expect(!feedback.covered.isEmpty)
        #expect(feedback.covered.allSatisfy { answer.contains($0.quote) })
        #expect(feedback.reference.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) })
        var followUp = InterviewTaskDescriptor(question: "How would you handle duplicate delivery?", kind: .systemDesign)
        followUp.criteria = [InterviewTaskKind.systemDesign.criteria[3]]
        let followUpAnswer = "I would persist an idempotency key with each notification and use a unique constraint to reject duplicate deliveries. A retry uses the same key; failed delivery attempts go to a dead-letter queue for review. A unique constraint makes deduplication atomic but adds database write contention and retained-key storage. A separate eventually consistent cache reduces database load but can permit duplicates during races; I would prefer the database constraint when preventing duplicate delivery matters more than peak throughput."
        let next = PracticeAttempt(questionID: "synthetic-follow-up", question: followUp.question, answer: followUpAnswer, revision: 1, hinted: false, skipped: false, source: "synthetic-integration")
        let nextFeedback = try await PracticeController.evaluate(attempt: next, task: followUp, attachment: nil, evidence: [], provider: SyntheticCaptureProvider(suffix: "follow-up"), model: "qwen3.5:4b")
        #expect(nextFeedback.covered.count == 1)
        #expect(nextFeedback.missing.isEmpty)
        #expect(nextFeedback.followUp == nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_LOCAL_PRACTICE"] == "1"))
    @MainActor func installedQwenEvaluatesSyntheticAnswer() async throws {
        let task = InterviewTaskDescriptor(question: "Design a notification service. Clarify requirements, then explain components, data flow, and reliability trade-offs.", kind: .systemDesign)
        let answer = "I would first clarify expected volume, latency and delivery channels. An API accepts notification requests and persists jobs in a durable queue. Workers read jobs and call delivery providers. I have not yet explained retries or bottlenecks."
        let attempt = PracticeAttempt(questionID: "synthetic-q", question: task.question, answer: answer, revision: 0, hinted: false, skipped: false, source: "synthetic-integration")
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil, evidence: [], provider: SyntheticCaptureProvider(), model: "qwen3.5:4b")
        #expect(!feedback.covered.isEmpty)
        #expect(feedback.reference.localizedCaseInsensitiveContains("queue") || feedback.reference.localizedCaseInsensitiveContains("worker"))
        #expect(feedback.covered.allSatisfy { answer.contains($0.quote) })
        #expect(Set(feedback.covered.map(\.criterion) + feedback.missing) == Set(task.criteria))
    }
}

/// Only called by the opt-in synthetic test above, never from product logging.
struct SyntheticCaptureProvider: LocalLLMProvider {
    var suffix = "en"
    var expectedSourceEvidence: String?
    let base = OllamaQwenProvider()
    var id: String { "synthetic-local-validation" }
    var displayName: String { "Installed Ollama, synthetic test only" }
    func healthCheck(modelName: String) async -> LocalLLMHealth { await base.healthCheck(modelName: modelName) }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        if let expectedSourceEvidence, request.systemPrompt?.contains("Evaluate this practice answer") == true {
            let payload = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            #expect(payload["source_evidence"] == expectedSourceEvidence)
        }
        if let root = ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"] {
            var object: [String: Any] = ["model": request.modelName, "messages": [["role": "system", "content": request.systemPrompt ?? ""], ["role": "user", "content": request.prompt]], "stream": true, "think": request.thinkingEnabled, "options": ["temperature": 0, "num_predict": request.numPredict ?? 4000]]
            if let schema = request.responseSchema {
                object["format"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema))
                if !request.thinkingEnabled {
                    object.removeValue(forKey: "messages")
                    object["prompt"] = request.prompt
                    object["system"] = request.systemPrompt
                    object["endpoint"] = "/api/generate"
                }
            }
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: root).appendingPathComponent("synthetic-local-\(suffix)-request.json"))
        }
        let captureID = UUID().uuidString
        let source = try await base.generateAnswer(request: request)
        return AsyncThrowingStream { continuation in
            let worker = Task {
                var captured = ""
                do {
                    for try await token in source { captured += token.text; continuation.yield(token) }
                    if let root = ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"] {
                        try Data(captured.utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent("synthetic-local-\(suffix)-feedback.json"))
                        if suffix == "routing" {
                            try JSONSerialization.data(withJSONObject: ["input": request.prompt, "output": captured]).write(to: URL(fileURLWithPath: root).appendingPathComponent("routing-wire-\(captureID).json"))
                        }
                    }
                    continuation.finish()
                } catch {
                    if suffix == "routing", let root = ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"] {
                        try? JSONSerialization.data(withJSONObject: ["input": request.prompt, "output": captured, "error": error.localizedDescription]).write(to: URL(fileURLWithPath: root).appendingPathComponent("routing-wire-\(captureID).json"))
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}

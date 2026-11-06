import Foundation
import Testing
@testable import Hireva

struct QuestionPipelineLocalBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_QUESTION_PIPELINE_BENCHMARK"] == "1"),
          .timeLimit(.minutes(1)))
    func fiftyWarmSyntheticBatchesKeepCandidateSnapshots() throws {
        let inputs = [
            "Explain database transactions and atomicity.",
            "How would you diagnose a failed request? What evidence would you collect?",
            "Could you explain the difference between C plus plus and S Q L?",
            "If the same fault appeared again, how would you diagnose the cause?",
            "What did you build, and how did you test the result?",
            "The report can explain how the result was reproduced for another analyst.",
            "Thanks for explaining the experiment.",
            "What questions would you ask us about the team?",
            "请解释数据库事务和原子性。你会如何验证并发写入的结果？",
            "🙂 Explain the difference between atomicity and isolation."
        ]
        // This small pure-pipeline measurement is separate from ASR/model/UI
        // latency. The initial reference pass warms the same frozen workload.
        let reference = inputs.map { QuestionCandidatePipeline.extract(from: $0) }
        var samples: [[String: Any]] = []
        for sample in 0..<50 {
            let start = DispatchTime.now().uptimeNanoseconds
            let actual = inputs.map { QuestionCandidatePipeline.extract(from: $0) }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            #expect(actual == reference)
            samples.append(["sample": sample, "elapsedNanoseconds": elapsed,
                            "inputCount": inputs.count,
                            "candidateCount": actual.reduce(0) { $0 + $1.count }])
        }
        let snapshots = reference.map { candidates in
            candidates.map { candidate -> [String: Any] in
                ["text": candidate.text, "confidence": candidate.confidence,
                 "intent": candidate.intent.rawValue,
                 "answerStrategy": candidate.answerStrategy.rawValue,
                 "answerRelevanceIntent": candidate.answerRelevanceIntent.rawValue,
                 "duplicateKey": candidate.duplicateKey,
                 "sourceStartUTF16": candidate.sourceStartUTF16,
                 "sourceEndUTF16": candidate.sourceEndUTF16]
            }
        }
        let directory = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "scope": "Warm pure question-pipeline microbenchmark; no ASR, model, capture or GUI",
            "warmupBatches": 1, "samples": samples, "inputs": inputs,
            "candidateSnapshots": snapshots, "clock": "DispatchTime.uptimeNanoseconds"
        ]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("question-pipeline-microbenchmark.json"),
                   options: .withoutOverwriting)
    }
}

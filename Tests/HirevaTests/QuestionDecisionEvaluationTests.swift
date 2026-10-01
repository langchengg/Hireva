import Foundation
import Testing
@testable import Hireva

/// Explicit local-only integration. Dataset lives outside production resources.
/// Exports every attempt; gate failures fail the test rather than just the export.
@Suite(.serialized)
struct QuestionDecisionEvaluationTests {
    struct Item: Decodable {
        var id: String?
        var groupID: String?
        var language: String?
        var question: String
        var previousQuestion: String?
        var previousAnswer: String?
        var artifact: String?
        var expectedTask: InterviewTaskKind?
        var expectedPersonalEvidence: PersonalEvidenceRequirement?
        var expectedBasis: QuestionAnswerBasis?
        var expectedRelation: QuestionConversationRelation?
        var inDomain: Bool?
        var kind: InterviewTaskKind?
        var expectedRequiresEvidence: Bool?
        var goldTask: InterviewTaskKind { expectedTask ?? kind ?? .unknown }
        var goldEvidence: PersonalEvidenceRequirement { expectedPersonalEvidence ?? (expectedRequiresEvidence == true ? .required : .notRequired) }
    }
    @Test func nativeLocalDecisionEvaluation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["HIREVA_ROUTING_EVAL"] == "1", let path = env["HIREVA_ROUTING_CASES"], let root = env["HIREVA_TEST_ARTIFACT_DIR"] else { return }
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require(!items.isEmpty)
        let provider = SyntheticCaptureProvider(suffix: "routing")
        let model = env["HIREVA_ROUTING_MODEL"] ?? "qwen3.5:4b"
        let health = await provider.healthCheck(modelName: model)
        try #require(health.isReady)
        let base = URL(fileURLWithPath: root)
        let jsonl = base.appendingPathComponent("routing-predictions.jsonl")
        try Data().write(to: jsonl)
        let file = try FileHandle(forWritingTo: jsonl)
        defer { try? file.close() }
        var rows: [[String: Any]] = []
        var confusion: [String: [String: Int]] = [:]
        var evidenceConfusion: [String: [String: Int]] = [:]
        var languageCounts: [String: [String: Int]] = [:]
        var latencies: [Int] = []
        var covered = 0, failed = 0, taskCorrect = 0, basisCorrect = 0, relationCorrect = 0, inDomain = 0
        var allTaskCorrect = 0, evidenceCorrect = 0, unknown = 0, clarified = 0, requests = 0, requestedCases = 0, repairedCases = 0
        var failures: [String: Int] = [:]
        var rawEvidenceConfusion: [String: [String: Int]] = [:]
        for (index, item) in items.enumerated() {
            let id = item.id ?? "known-\(index + 1)"
            let decision = try await InterviewQuestionRouter.resolve(.init(question: item.question, questionID: id,
                artifact: item.artifact, parentQuestionID: item.previousQuestion == nil ? nil : "parent-" + id,
                previousQuestion: item.previousQuestion, previousAnswer: item.previousAnswer, language: item.language), provider: provider, model: model)
            allTaskCorrect += decision.task == item.goldTask ? 1 : 0
            evidenceCorrect += decision.personalEvidence == item.goldEvidence ? 1 : 0
            unknown += decision.task == .unknown ? 1 : 0
            clarified += decision.relation == .clarification ? 1 : 0
            requests += decision.modelRequests ?? 0
            requestedCases += (decision.modelRequests ?? 0) > 0 ? 1 : 0
            repairedCases += (decision.modelRequests ?? 0) > 1 ? 1 : 0
            if let failure = decision.failure { failures[failure, default: 0] += 1 }
            rawEvidenceConfusion[item.goldEvidence.rawValue, default: [:]][decision.modelPersonalEvidence?.rawValue ?? "invalid", default: 0] += 1
            let domain = item.inDomain ?? (item.goldTask != .unknown)
            if domain {
                inDomain += 1
                if decision.task != .unknown && decision.failure == nil && decision.clarification.isEmpty { covered += 1 }
                if decision.task == item.goldTask { taskCorrect += 1 }
                confusion[item.goldTask.rawValue, default: [:]][decision.task.rawValue, default: 0] += 1
                let language = decision.language
                languageCounts[language, default: [:]]["n", default: 0] += 1
                languageCounts[language, default: [:]]["correct", default: 0] += decision.task == item.goldTask ? 1 : 0
            }
            evidenceConfusion[item.goldEvidence.rawValue, default: [:]][decision.personalEvidence.rawValue, default: 0] += 1
            if decision.failure != nil { failed += 1 }
            if item.expectedBasis == decision.basis { basisCorrect += 1 }
            if item.expectedRelation == decision.relation { relationCorrect += 1 }
            latencies.append(decision.latencyMS)
            let encoded = try JSONEncoder().encode(decision)
            let row: [String: Any] = ["id": id, "groupID": item.groupID ?? id, "question": item.question,
                "expectedTask": item.goldTask.rawValue, "expectedPersonalEvidence": item.goldEvidence.rawValue,
                "decision": try JSONSerialization.jsonObject(with: encoded), "inDomain": domain]
            rows.append(row)
            try file.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            try file.write(contentsOf: Data([10]))
            try file.synchronize()
            print("Routing sample \(index + 1)/\(items.count); failed=\(failed)")
        }
        func ratio(_ numerator: Int, _ denominator: Int) -> Double { denominator == 0 ? 0 : Double(numerator) / Double(denominator) }
        var perClass: [String: [String: Double]] = [:]
        for label in confusion.keys.sorted() {
            let tp = confusion[label]?[label] ?? 0
            let n = confusion[label]!.values.reduce(0, +)
            let predicted = confusion.values.reduce(0) { $0 + ($1[label] ?? 0) }
            let precision = ratio(tp, predicted), recall = ratio(tp, n)
            perClass[label] = ["precision": precision, "recall": recall, "f1": precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall), "n": Double(n)]
        }
        let macro = perClass.values.reduce(0) { $0 + ($1["f1"] ?? 0) } / Double(max(1, perClass.count))
        let required = evidenceConfusion["required"] ?? [:], negative = evidenceConfusion["notRequired"] ?? [:]
        let recall = ratio(required["required"] ?? 0, required.values.reduce(0,+))
        let specificity = ratio(negative["notRequired"] ?? 0, negative.values.reduce(0,+))
        let languages = languageCounts.mapValues { ratio($0["correct"] ?? 0, $0["n"] ?? 0) }
        let coverage = ratio(covered, inDomain)
        let pass = macro >= 0.85 && coverage >= 0.90 && recall >= 0.95 && specificity >= 0.90 && languages.values.allSatisfy { $0 >= 0.80 }
        latencies.sort()
        let report: [String: Any] = ["n": items.count, "inDomain": inDomain, "model": model, "routerVersion": InterviewQuestionRouter.version,
            "accuracy": ratio(taskCorrect, inDomain), "macroF1": macro, "languageAccuracy": languages, "languageCounts": languageCounts,
            "perClass": perClass, "taskConfusion": confusion, "evidenceConfusion": evidenceConfusion,
            "requiredRecall": recall, "notRequiredSpecificity": specificity, "coverage": coverage, "failures": failed,
            "basisCorrect": basisCorrect, "relationCorrect": relationCorrect,
            "allTaskCorrect": allTaskCorrect, "allEvidenceCorrect": evidenceCorrect,
            "allTaskAccuracy": ratio(allTaskCorrect, items.count), "allEvidenceAccuracy": ratio(evidenceCorrect, items.count),
            "unknownCount": unknown, "unknownRate": ratio(unknown, items.count), "clarificationCount": clarified,
            "failureCounts": failures, "failureRate": ratio(failed, items.count),
            "rawModelEvidenceConfusion": rawEvidenceConfusion, "modelRequests": requests,
            "modelCallRate": ratio(requestedCases, items.count), "formatRepairCases": repairedCases,
            "p50RoutingMS": latencies[latencies.count / 2], "p95RoutingMS": latencies[min(latencies.count-1, Int(Double(latencies.count)*0.95))],
            "qualityGate": pass ? "PASS" : "FAIL", "review": "Synthetic model-assisted labels; not human gold. Original labels preserved."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: base.appendingPathComponent("routing-summary.json"))
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        if env["HIREVA_ROUTING_ENFORCE_GATE"] == "1" { #expect(pass, "Predeclared routing quality gate failed; see routing-summary.json") }
    }
}

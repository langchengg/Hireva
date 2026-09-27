import Foundation
import Testing
@testable import Hireva

/// Independent fixed prompts supplied by a read-only reviewer before it read
/// the classifier. This produces an evaluation report, NOT a quality pass gate.
/// Routing/recall misses remain visible; do not tune phrases to this fixture.
struct WorkflowEvaluationTests {
    struct Case: Codable {
        var kind: InterviewTaskKind
        var question: String
        var expectedRequiresEvidence: Bool
    }
    @Test func reportIndependentRoutingAndEvidenceCoverage() throws {
        let url = try #require(Bundle.module.url(forResource: "workflow_independent_102", withExtension: "json"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        #expect(cases.count == 102)
        #expect(Set(cases.map(\.question)).count == 102)
        var routingCorrect = 0, evidenceCorrect = 0, falseNegatives = 0
        var misses: [[String: Any]] = []
        for item in cases {
            let actual = InterviewTaskDescriptor(question: item.question)
            if actual.kind == item.kind { routingCorrect += 1 }
            if actual.requiresPersonalEvidence == item.expectedRequiresEvidence { evidenceCorrect += 1 }
            if item.expectedRequiresEvidence && !actual.requiresPersonalEvidence { falseNegatives += 1 }
            if actual.kind != item.kind || actual.requiresPersonalEvidence != item.expectedRequiresEvidence {
                misses.append(["question": item.question, "expectedTask": item.kind.rawValue, "actualTask": actual.kind.rawValue, "expectedPersonalEvidence": item.expectedRequiresEvidence, "actualPersonalEvidence": actual.requiresPersonalEvidence])
            }
        }
        let report: [String: Any] = ["cases": cases.count, "routingCorrect": routingCorrect, "evidenceCorrect": evidenceCorrect, "personalEvidenceFalseNegatives": falseNegatives, "qualityStatus": misses.isEmpty ? "ALL_FIXED_CASES_MATCH" : "LIMITED_HEURISTIC_WITH_MISSES", "misses": misses, "scope": "Fixed synthetic textual routing evaluation. No model scores or hiring outcomes. Not proof of unseen generalization."]
        print("Independent routing report: \(routingCorrect)/102 task matches; \(evidenceCorrect)/102 evidence-gate matches; \(falseNegatives) evidence false negatives. This is not a quality PASS.")
        if let root = ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: root).appendingPathComponent("workflow-quality.json"))
        }
    }
}

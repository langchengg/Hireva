import Foundation
import Testing
@testable import Hireva

/// Schema annotation contracts only; no model, stream or quality claim.
@Suite
struct PracticeFollowUpTargetBindingTests {
    @Test(arguments: Array(0..<12))
    func finalSelectorBindsOrderedFrozenCriteriaWithoutFreezingDraftGap(_ variant: Int) throws {
        let count = [1, 4, 12][variant / 4]
        let language = variant & 1 == 0 ? "en" : "zh"
        let personal = variant & 2 != 0
        let criteria = (0..<count).map { language == "zh" ? "说明第\($0)项规则的适用范围" : "Explain the scope of supplied rule \($0)" }
        let reference = personal ? PracticeFeedback.sourceLimitedReference(language: language) : "Use only the supplied scope."
        let draft = PracticeEvaluationPayload(coverage: Dictionary(uniqueKeysWithValues:
            (0..<count).map { ("r\($0)", Optional("Literal answer substring \($0).")) }),
            suggestion: "Keep each boundary.", followUp: nil, reason: "The original map is a draft.", reference: reference)
        let schema = draft.semanticReviewSchema(fixedReference: personal, criteria: criteria)
        let fields = try properties(schema)
        let followUp = try object(try #require(fields["followUp"]))
        #expect(Set(followUp.keys) == ["type", "description"])
        #expect(followUp["type"] == .string("string") && followUp["const"] == nil && followUp["enum"] == nil)
        guard case .string(let description)? = followUp["description"] else { Issue.record("Expected follow-up selector annotation."); return }
        #expect(description.hasPrefix("One direct question for only the first criterion whose assessments fulfillment is not met,"))
        #expect(description.contains("your own final returned rubric values, not the draft map"))
        var locations: [String.Index] = []
        for (index, criterion) in criteria.enumerated() {
            let branch = "\(index == 0 ? "if" : "else if") assessments.r\(index).fulfillment != \"met\": target r\(index): \(criterion)"
            try #require(description.components(separatedBy: branch).count == 2)
            locations.append(try #require(description.range(of: branch)).lowerBound)
        }
        #expect(locations == locations.sorted())
        #expect(description.contains("else: return \"\""))
        #expect(description.contains("only its remaining unmet part, without repeating already expressed content"))
        #expect(description.contains("Do not emit rubric IDs or selection mechanics"))
        let expectedTemporalScope = """
        For an actual past-event result gap, ask what is known or observed so far, if anything, and allow no outcome yet.
        Keep stated future activities as future; do not ask whether they already happened or ask for their completed result.
        For a hypothetical proposal, ask about reasoning or proposed choices without requiring a past personal event.
        """
        #expect(description.hasSuffix(expectedTemporalScope))
        // A different draft gap cannot select or constrain the final target.
        var changedDraft = draft
        _ = changedDraft.coverage.updateValue(nil, forKey: "r\(count - 1)")
        #expect(changedDraft.semanticReviewSchema(fixedReference: personal, criteria: criteria) == schema)
        #expect(fields["reviewOutcome"] == .object(["type": .string("string"), "enum": .array([.string("accepted"), .string("rejected")])]))
        #expect(practiceReferenceSchemaConstraints(fields["reference"]) == (personal ? .object(["type": .string("string"), "const": .string("")]) : .object(["type": .string("string")])))
        // Isolate the observed critic failure: no new primary description.
        let primary = try properties(PracticeEvaluationPayload.schema(criteria: criteria, sourceLimitedReference: personal ? reference : nil))
        #expect(primary["followUp"] == .object(["type": .string("string")]))
    }
    private func properties(_ schema: LocalJSONValue) throws -> [String: LocalJSONValue] {
        let schema = try object(schema)
        return try object(try #require(schema["properties"]))
    }
    private func object(_ value: LocalJSONValue) throws -> [String: LocalJSONValue] {
        guard case .object(let value) = value else { throw MaterialError.invalid("Expected the existing schema object.") }
        return value
    }
}

import Foundation
import Testing
@testable import Hireva

/// Field annotation contracts only; no model or technical-quality claim.
@Suite
struct PracticeReferenceDescriptionBindingTests {
    @Test(arguments: Array(0..<12))
    func groundedSchemasBindEditableReferencePolicyWithoutChangingFixedSourceNotice(_ variant: Int) throws {
        let count = [1, 4, 12][variant / 4]
        let language = variant & 1 == 0 ? "en" : "zh"
        let personal = variant & 2 != 0
        let criteria = (0..<count).map { language == "zh" ? "说明第\($0)项规则的适用范围" : "Explain the scope of supplied rule \($0)" }
        let reference = personal ? PracticeFeedback.sourceLimitedReference(language: language) : "PROVISIONAL_REFERENCE_IS_NOT_AUTHORITY"
        let draft = PracticeEvaluationPayload(coverage: Dictionary(uniqueKeysWithValues:
            (0..<count).map { ("r\($0)", Optional("Literal answer substring \($0).")) }),
            suggestion: "Keep each boundary.", followUp: nil, reason: "The original map is a draft.", reference: reference)
        let expectedDescription = """
        Answer the original question with a concise qualified explanation, separate from the candidate's omissions.
        Preserve the original question's stated constraints. Do not assume omitted existence, uniqueness or other conditions; state any added assumption explicitly.
        Do not add unrequested exercise, source or task identifiers, or present an unverified identifier as established fact.
        For any claimed guarantee, state assumptions, operation boundaries, conditions and relevant possible failures.
        A local mechanism or category name does not establish unconditional system outcomes or physical properties.
        Keep each property or limitation attached to its actual subject and operation; do not transfer it to the other subject of a comparison. Do not invent a comparison axis or a property difference absent from the question; qualify implementation-dependent properties.
        Submitted assertions and draft wording are not authority; independently correct them. Preserve the existing source, language, temporal and ownership restrictions.
        """
        let fixedField: LocalJSONValue = .object(["type": .string("string"), "const": .string(reference)])
        let applicationWireField: LocalJSONValue = .object(["type": .string("string"), "const": .string("")])
        let editableField: LocalJSONValue = .object(["type": .string("string"), "description": .string(expectedDescription)])
        let schemas = [
            PracticeEvaluationPayload.schema(criteria: criteria, sourceLimitedReference: personal ? reference : nil),
            draft.semanticReviewSchema(fixedReference: personal, criteria: criteria)
        ]
        for (phase, schema) in schemas.enumerated() {
            let object = try object(schema)
            let fields = try self.object(try #require(object["properties"]))
            #expect(fields["reference"] == (personal ? (phase == 0 ? fixedField : applicationWireField) : editableField))
            #expect(object["additionalProperties"] == .boolean(false))
            let names = (0..<count).map { "r\($0)" } + ["assessments", "suggestion", "followUp", "reason", "reference"] + (phase == 0 ? [] : ["reviewOutcome"])
            #expect(Set(fields.keys) == Set(names))
            for (index, criterion) in criteria.enumerated() {
                let field = try self.object(try #require(fields["r\(index)"]))
                #expect(Set(field.keys) == ["type", "description"] && field["type"] == .string("string"))
                guard case .string(let description)? = field["description"] else { Issue.record("Expected a criterion annotation."); continue }
                #expect(description.contains(criterion))
            }
            #expect(practiceReferenceSchemaConstraints(fields["reference"]) == (personal
                ? (phase == 0 ? fixedField : applicationWireField) : .object(["type": .string("string")])))
        }
        // Only grounded request schemas receive the annotation; raw templates remain unchanged.
        let templates = [
            PracticeEvaluationPayload.schema(criteriaCount: count, sourceLimitedReference: personal ? reference : nil),
            draft.semanticReviewSchema(fixedReference: personal)
        ]
        for (phase, template) in templates.enumerated() {
            let fields = try object(try #require(try object(template)["properties"]))
            #expect(fields["reference"] == (personal
                ? (phase == 0 ? fixedField : applicationWireField) : .object(["type": .string("string")])))
        }
        if !personal {
            var differentDraft = draft
            differentDraft.reference = "A different unverified draft reference."
            #expect(differentDraft.semanticReviewSchema(fixedReference: false, criteria: criteria) == schemas[1])
        }
    }
    private func object(_ value: LocalJSONValue) throws -> [String: LocalJSONValue] {
        guard case .object(let value) = value else { throw MaterialError.invalid("Expected the existing schema object.") }
        return value
    }
}

// Keep pre-existing exact constraint checks while the characterization above checks the annotation.
func practiceReferenceSchemaConstraints(_ value: LocalJSONValue?) -> LocalJSONValue? {
    guard case .object(var field)? = value else { return value }
    field.removeValue(forKey: "description")
    return .object(field)
}

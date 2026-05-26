import Testing
@testable import InterviewCopilotMac

@Suite
struct JSONParsingTests {
    struct Payload: Decodable, Equatable {
        var shouldTrigger: Bool
        var confidence: Double

        enum CodingKeys: String, CodingKey {
            case shouldTrigger = "should_trigger"
            case confidence
        }
    }

    @Test
    func strictJSONDecodesFirst() throws {
        let payload = try JSONParsing.decodeObject(Payload.self, from: #"{"should_trigger":true,"confidence":0.9}"#)
        #expect(payload == Payload(shouldTrigger: true, confidence: 0.9))
    }

    @Test
    func extractsFirstJSONObjectFromModelText() throws {
        let payload = try JSONParsing.decodeObject(
            Payload.self,
            from: #"Here is the result: {"should_trigger":false,"confidence":0.4} trailing text"#
        )
        #expect(payload == Payload(shouldTrigger: false, confidence: 0.4))
    }

    @Test
    func repairsCommonTrailingCommaJSON() throws {
        let payload = try JSONParsing.decodeObject(
            Payload.self,
            from: #"```json {"should_trigger":true,"confidence":0.75,} ```"#
        )
        #expect(payload == Payload(shouldTrigger: true, confidence: 0.75))
    }
}

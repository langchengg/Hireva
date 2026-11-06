import Foundation
import Testing
@testable import Hireva

struct OllamaTerminalTokenDiagnosticsTests {
    @Test(arguments: [OllamaResponseSchema.chatMessageContent, .generateResponse])
    func serverDurationsRequireTerminalFrameAndPreserveNanoseconds(schema: OllamaResponseSchema) throws {
        let metrics = ["total_duration": 8_001_234_567, "load_duration": 0,
            "prompt_eval_duration": 6_400_000_001, "eval_duration": 900_000_002]
        var accumulator = OllamaResponseAccumulator(schema: schema)
        _ = try accumulator.ingest(frame(schema: schema, content: "synthetic packet", done: false, usage: metrics))
        #expect(accumulator.currentDiagnostics.totalDurationNS == nil)
        #expect(accumulator.currentDiagnostics.loadDurationNS == nil)
        #expect(accumulator.currentDiagnostics.promptEvalDurationNS == nil)
        #expect(accumulator.currentDiagnostics.evalDurationNS == nil)
        _ = try accumulator.ingest(frame(schema: schema, content: "", done: true, usage: metrics))
        let parsed = try accumulator.finish(requireDone: true)
        #expect(parsed.content == "synthetic packet")
        #expect(parsed.diagnostics.totalDurationNS == 8_001_234_567)
        #expect(parsed.diagnostics.loadDurationNS == 0)
        #expect(parsed.diagnostics.promptEvalDurationNS == 6_400_000_001)
        #expect(parsed.diagnostics.evalDurationNS == 900_000_002)
    }

    @Test(arguments: [OllamaResponseSchema.chatMessageContent, .generateResponse])
    func missingOrInvalidDurationsRemainUnknownWithoutDroppingContent(schema: OllamaResponseSchema) throws {
        let values: [Any] = [NSNull(), "not-a-duration", true, -1, 0.5]
        for value in values {
            var accumulator = OllamaResponseAccumulator(schema: schema)
            _ = try accumulator.ingest(frame(schema: schema, content: "synthetic packet", done: true,
                usage: ["total_duration": value, "load_duration": value,
                    "prompt_eval_duration": value, "eval_duration": value]))
            let parsed = try accumulator.finish(requireDone: true)
            #expect(parsed.content == "synthetic packet" && parsed.diagnostics.malformedEvents == 0)
            #expect(parsed.diagnostics.totalDurationNS == nil && parsed.diagnostics.loadDurationNS == nil)
            #expect(parsed.diagnostics.promptEvalDurationNS == nil && parsed.diagnostics.evalDurationNS == nil)
        }
    }

    @Test(arguments: [OllamaResponseSchema.chatMessageContent, .generateResponse])
    func terminalCountsDoNotComeFromIntermediateFrames(schema: OllamaResponseSchema) throws {
        var accumulator = OllamaResponseAccumulator(schema: schema)
        _ = try accumulator.ingest(frame(schema: schema, content: "synthetic packet", done: false,
            usage: ["prompt_eval_count": 17, "eval_count": 5]))
        #expect(accumulator.currentDiagnostics.promptEvalCount == nil)
        #expect(accumulator.currentDiagnostics.evalCount == nil)
        _ = try accumulator.ingest(frame(schema: schema, content: "", done: true,
            usage: ["prompt_eval_count": 1379, "eval_count": 43]))
        let parsed = try accumulator.finish(requireDone: true)
        #expect(parsed.content == "synthetic packet")
        #expect(parsed.diagnostics.promptEvalCount == 1379)
        #expect(parsed.diagnostics.evalCount == 43)
    }

    @Test(arguments: [OllamaResponseSchema.chatMessageContent, .generateResponse])
    func omittedMetricsStayUnknownAndExplicitZeroStaysZero(schema: OllamaResponseSchema) throws {
        for zero in [false, true] {
            var accumulator = OllamaResponseAccumulator(schema: schema)
            _ = try accumulator.ingest(frame(schema: schema, content: "synthetic packet", done: true,
                usage: zero ? ["prompt_eval_count": 0, "eval_count": 0] : [:]))
            let parsed = try accumulator.finish(requireDone: true)
            #expect(parsed.diagnostics.promptEvalCount == (zero ? 0 : nil))
            #expect(parsed.diagnostics.evalCount == (zero ? 0 : nil))
            #expect(parsed.diagnostics.totalDurationNS == nil && parsed.diagnostics.loadDurationNS == nil)
            #expect(parsed.diagnostics.promptEvalDurationNS == nil && parsed.diagnostics.evalDurationNS == nil)
        }
    }

    @Test(arguments: [OllamaResponseSchema.chatMessageContent, .generateResponse])
    func malformedOptionalMetricCannotDropValidContent(schema: OllamaResponseSchema) throws {
        let malformedValues: [Any] = ["not-a-count", true]
        for malformed in malformedValues {
            var accumulator = OllamaResponseAccumulator(schema: schema)
            _ = try accumulator.ingest(frame(schema: schema, content: "synthetic packet", done: true,
                usage: ["prompt_eval_count": malformed, "eval_count": 43]))
            let parsed = try accumulator.finish(requireDone: true)
            #expect(parsed.content == "synthetic packet")
            #expect(parsed.diagnostics.promptEvalCount == nil)
            #expect(parsed.diagnostics.evalCount == 43)
            #expect(parsed.diagnostics.malformedEvents == 0)
        }
    }

    @Test(arguments: [OllamaResponseSchema.chatMessageContent, .generateResponse])
    func usageMetadataCannotSatisfyMissingDone(schema: OllamaResponseSchema) throws {
        var accumulator = OllamaResponseAccumulator(schema: schema)
        _ = try accumulator.ingest(frame(schema: schema, content: "synthetic packet", done: false,
            usage: ["prompt_eval_count": 77, "eval_count": 1, "total_duration": 100, "load_duration": 10]))
        do {
            _ = try accumulator.finish(requireDone: true)
            Issue.record("Usage metadata must not replace the required done envelope.")
        } catch let error as OllamaQwenProviderError {
            #expect(error.category == .streamParserDroppedContent)
        }
        #expect(accumulator.currentDiagnostics.promptEvalCount == nil)
        #expect(accumulator.currentDiagnostics.evalCount == nil)
        #expect(accumulator.currentDiagnostics.totalDurationNS == nil && accumulator.currentDiagnostics.loadDurationNS == nil)
    }

    @Test(arguments: [OllamaResponseSchema.chatMessageContent, .generateResponse])
    func terminalCountsSurviveAnExistingContentFailure(schema: OllamaResponseSchema) throws {
        var accumulator = OllamaResponseAccumulator(schema: schema)
        _ = try accumulator.ingest(frame(schema: schema, content: "", done: true,
            usage: ["prompt_eval_count": 77, "eval_count": 0, "total_duration": 100, "load_duration": 10]))
        do {
            _ = try accumulator.finish(requireDone: true)
            Issue.record("Usage metadata must not turn an empty answer into success.")
        } catch let error as OllamaQwenProviderError {
            #expect(error.category == .providerReturnedNoContent)
        }
        #expect(accumulator.currentDiagnostics.promptEvalCount == 77)
        #expect(accumulator.currentDiagnostics.evalCount == 0)
        #expect(accumulator.currentDiagnostics.totalDurationNS == 100 && accumulator.currentDiagnostics.loadDurationNS == 10)
    }

    private func frame(schema: OllamaResponseSchema, content: String, done: Bool,
        usage: [String: Any]) throws -> String {
        var value = usage
        value["done"] = done
        value["done_reason"] = "stop"
        switch schema {
        case .chatMessageContent: value["message"] = ["content": content]
        case .generateResponse: value["response"] = content
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}

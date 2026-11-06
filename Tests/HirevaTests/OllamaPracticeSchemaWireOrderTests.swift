import Foundation
import os
import Testing
@testable import Hireva

/// Actual URLRequest bytes from the real evaluator/provider, finite fake HTTP.
/// Predetermined replies prove wire/admission only, never model reasoning order.
@Suite(.timeLimit(.minutes(1)))
struct OllamaPracticeSchemaWireOrderTests {
    @Test
    func routerWireOrdersEachBranchWithoutChangingItsSchema() async throws {
        let harness = SchemaOrderHTTPHarness(packets: [#"{"personalEvidence":"notRequired","basis":"generalKnowledge","task":"generalKnowledge","relation":"independent","clarification":""}"#])
        let host = "schema-wire-\(UUID().uuidString).invalid"
        SchemaOrderURLProtocol.register(harness, host: host)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SchemaOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); SchemaOrderURLProtocol.remove(host: host) }
        let provider = OllamaQwenProvider(baseURL: URL(string: "https://\(host)")!, session: session)
        let decision = try await InterviewQuestionRouter.resolve(.init(question: "Explain a transaction boundary.",
            questionID: "wire-order", selectedTask: .generalKnowledge), provider: provider, model: "synthetic-wire-order")
        #expect(decision.personalEvidence == .notRequired && decision.modelRequests == 1)
        let data = try #require(harness.bodies.first)
        #expect(harness.bodies.count == 1)
        let body = try JSONDecoder().decode(SchemaOrderBody.self, from: data)
        #expect(body.format == InterviewQuestionRouter.Wire.schema)
        #expect(body.options.numPredict == 260 && body.options.temperature == 0 && !body.think)
        let branches = String(decoding: data, as: UTF8.self).components(separatedBy: "\"properties\":{")
        try #require(branches.count == 4)
        for branch in branches.dropFirst() {
            try expectPropertyByteOrder(Data(branch.utf8), order: ["personalEvidence", "basis", "task", "relation", "clarification"])
        }
    }

    @Test
    func unionOrderDoesNotReorderNestedProperties() async throws {
        let nested: LocalJSONValue = .object(["type": .string("object"), "properties": .object([
            "a": .object(["type": .string("string")]), "z": .object(["type": .string("string")])]),
            "required": .array([.string("a"), .string("z")]), "additionalProperties": .boolean(false)])
        let branch: LocalJSONValue = .object(["type": .string("object"), "properties": .object([
            "a": nested, "z": .object(["type": .string("string"), "enum": .array([.string("中文🙂"), .string("other")])])]),
            "required": .array([.string("a"), .string("z")]), "additionalProperties": .boolean(false)])
        let schema: LocalJSONValue = .object(["anyOf": .array([branch, branch])])
        let harness = SchemaOrderHTTPHarness(packets: [#"{"a":{"a":"ready","z":"ready"},"z":"中文🙂"}"#])
        let host = "schema-wire-\(UUID().uuidString).invalid"
        SchemaOrderURLProtocol.register(harness, host: host)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SchemaOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); SchemaOrderURLProtocol.remove(host: host) }
        let provider = OllamaQwenProvider(baseURL: URL(string: "https://\(host)")!, session: session)
        let owned = try await provider.generateOwnedAnswer(request: .init(prompt: "Nested wire control", systemPrompt: nil,
            modelName: "synthetic-wire-order", temperature: 0, numPredict: 32, responseSchema: schema,
            responseSchemaPropertyOrder: ["z", "a"]))
        do { for try await _ in owned.stream {}; await owned.producerTask.value }
        catch { owned.producerTask.cancel(); await owned.producerTask.value; throw error }
        let data = try #require(harness.bodies.first)
        #expect(try JSONDecoder().decode(SchemaOrderBody.self, from: data).format == schema)
        let properties = String(decoding: data, as: UTF8.self).components(separatedBy: "\"properties\":{")
        try #require(properties.count == 5)
        for index in [1, 3] { try expectPropertyByteOrder(Data(properties[index].utf8), order: ["z", "a"]) }
        for index in [2, 4] { try expectPropertyByteOrder(Data(properties[index].utf8), order: ["a", "z"]) }
    }

    @Test(arguments: Array(0..<8))
    func invalidUnionOrderFailsBeforeTransport(_ variant: Int) async throws {
        let fields: LocalJSONValue = .object(["a": .object(["type": .string("string")]), "z": .object(["type": .string("string")])])
        let valid: [String: LocalJSONValue] = ["type": .string("object"), "properties": fields,
            "required": .array([.string("a"), .string("z")]), "additionalProperties": .boolean(false)]
        var second = valid
        if variant == 0 { second["required"] = .array([.string("a")]) }
        if variant == 1 { second["required"] = .array([.string("a"), .string("a")]) }
        if variant == 2 { second["anyOf"] = .array([.object(valid)]) }
        if variant == 3 { second["$ref"] = .string("#/$defs/other") }
        if variant == 4 { second.removeValue(forKey: "properties") }
        var root: [String: LocalJSONValue] = ["anyOf": .array(variant == 5 ? [] : [.object(valid), .object(second)])]
        if variant == 6 { root["type"] = .string("object") }
        if variant == 7 { root["anyOf"] = .array([.object(valid), .string("unsupported branch")]) }
        let harness = SchemaOrderHTTPHarness(packets: [])
        let host = "schema-wire-\(UUID().uuidString).invalid"
        SchemaOrderURLProtocol.register(harness, host: host)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SchemaOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); SchemaOrderURLProtocol.remove(host: host) }
        let provider = OllamaQwenProvider(baseURL: URL(string: "https://\(host)")!, session: session)
        let owned = try await provider.generateOwnedAnswer(request: .init(prompt: "Invalid union control", systemPrompt: nil,
            modelName: "synthetic-wire-order", temperature: 0, numPredict: 32, responseSchema: .object(root),
            responseSchemaPropertyOrder: ["z", "a"]))
        do { for try await _ in owned.stream {}; await owned.producerTask.value; Issue.record("Invalid union order must fail before POST.") }
        catch { owned.producerTask.cancel(); await owned.producerTask.value; #expect(error.localizedDescription.contains("Explicit schema order")) }
        #expect(harness.bodies.isEmpty)
    }

    @Test(arguments: Array(0..<4))
    @MainActor func practiceWireEmitsNumericCriteriaBeforeDependentFields(_ variant: Int) async throws {
        let count = variant & 1 == 0 ? 4 : 12, personal = variant & 2 != 0
        let quotes = (0..<count).map { "Operation \($0) is limited to its assigned interval." }
        let answer = quotes.joined(separator: " ") + " Quoted annotation: \"中文🙂\" / \\ \n\tend."
        var task = InterviewTaskDescriptor(question: personal ? "Describe your stated operation boundaries." : "Explain each operation boundary.",
            kind: personal ? .behavioral : .generalKnowledge, language: "en")
        task.apply(.init(task: task.kind, personalEvidence: personal ? .required : .notRequired,
            basis: personal ? .candidateRecord : .generalKnowledge, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-wire-order",
            routerVersion: InterviewQuestionRouter.version, language: "en", clarification: "", questionID: "wire-order",
            questionRevision: 7, contextSnapshotID: "wire-order-context", artifactRevision: 3,
            model: "synthetic-wire-order", failure: nil, latencyMS: 0))
        task.criteria = (0..<count).map { "Explain operation \($0)'s boundary" }
        let reference = personal ? PracticeFeedback.sourceLimitedReference(language: "en") : "Each declared operation applies only within its stated interval."
        let primary = PracticeEvaluationPayload(coverage: Dictionary(uniqueKeysWithValues: quotes.enumerated().map { ("r\($0.offset)", Optional($0.element)) }),
            suggestion: "Preserve the declared boundaries.", followUp: nil, reason: "All declared boundaries are stated.", reference: personal ? "" : reference)
        var final = primary; final.reviewOutcome = "accepted"
        let packets = try [primary, final].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let harness = SchemaOrderHTTPHarness(packets: packets)
        let host = "schema-wire-\(UUID().uuidString).invalid"
        SchemaOrderURLProtocol.register(harness, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SchemaOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); SchemaOrderURLProtocol.remove(host: host) }
        let provider = OllamaQwenProvider(baseURL: URL(string: "https://\(host)")!, session: session)
        let attempt = PracticeAttempt(questionID: "wire-order", question: task.question, answer: answer,
            contextSnapshotID: "wire-order-context", revision: 7, hinted: false, skipped: false,
            source: "synthetic-contract", task: task, attachmentRevision: 3)
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
            evidence: [], provider: provider, model: "synthetic-wire-order")
        #expect(feedback.covered.map(\.quote) == quotes && feedback.missing.isEmpty && feedback.followUp == nil)
        #expect(feedback.reference == reference)
        let bodies = harness.bodies
        try #require(bodies.count == 2)
        let frozen = try primary.semanticReviewCandidate(answer: answer, task: task, evidence: [])
        for (phase, data) in bodies.enumerated() {
            let body = try JSONDecoder().decode(SchemaOrderBody.self, from: data)
            #expect(body.model == "synthetic-wire-order" && body.stream && !body.think)
            #expect(body.options.temperature == 0 && body.options.numPredict == 1200)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["truncate"] as? Bool == false)
            #expect(object["shift"] as? Bool == false)
            #expect((object["options"] as? [String: Any])?["num_ctx"] == nil)
            let input = try JSONDecoder().decode([String: String].self, from: Data(body.prompt.utf8))
            #expect(input["answer"] == attempt.answer && input["question"] == attempt.question)
            #expect(input["source_evidence"] == "" && input["attachment"] == "")
            #expect(input["draft_feedback"] == nil && input["draft_first_missing_rubric_id"] == nil)
            #expect(input["application_reference_notice"] == nil)
            if personal {
                #expect(!body.prompt.contains(reference))
                #expect(!(object["system"] as? String ?? "").contains(reference))
                #expect(!String(decoding: try JSONEncoder().encode(body.format), as: UTF8.self).contains(reference))
            }
            #expect(body.prompt.utf8.count <= 24000)
            let expectedSchema = phase == 0
                ? PracticeEvaluationPayload.schema(criteria: task.criteria, sourceLimitedReference: personal ? "" : nil)
                : frozen.semanticReviewSchema(fixedReference: personal, criteria: task.criteria, feedbackLanguage: task.explanationLanguage ?? task.language)
            #expect(body.format == expectedSchema)
            let order = task.criteria.indices.map { "r\($0)" } + ["assessments", "reason", "suggestion", "reference", "followUp"]
                + (phase == 0 ? [] : ["reviewOutcome"])
            try expectPropertyByteOrder(data, order: order)
            let outputSchema = try JSONDecoder().decode(LocalJSONValue.self, from: Data(try #require(input["output_schema"]).utf8))
            #expect(outputSchema == expectedSchema)
        }
    }

    @Test(arguments: Array(0..<3))
    func defaultStructuredChatAndStringFormatsKeepExistingWire(_ variant: Int) async throws {
        let schema: LocalJSONValue = .object(["type": .string("object"), "properties": .object([
            "r0": .object(["type": .string("string")]), "followUp": .object(["type": .string("string")])]),
            "required": .array([.string("r0"), .string("followUp")]), "additionalProperties": .boolean(false)])
        let harness = SchemaOrderHTTPHarness(packets: [#"{"followUp":"","r0":"ready"}"#])
        let host = "schema-wire-\(UUID().uuidString).invalid"
        SchemaOrderURLProtocol.register(harness, host: host)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SchemaOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); SchemaOrderURLProtocol.remove(host: host) }
        let provider = OllamaQwenProvider(baseURL: URL(string: "https://\(host)")!, session: session)
        let request = LocalLLMRequest(prompt: "Scalar UTF-8 中文🙂, quote \" and slash / and \\ and \n\t.",
            systemPrompt: nil, modelName: "synthetic-wire-order", temperature: 0, numPredict: Int.max,
            responseFormat: variant == 2 ? "json" : nil, responseSchema: variant == 2 ? nil : schema,
            thinkingEnabled: variant == 1)
        let owned = try await provider.generateOwnedAnswer(request: request)
        do {
            for try await _ in owned.stream {}
            await owned.producerTask.value
        } catch { owned.producerTask.cancel(); await owned.producerTask.value; throw error }
        let data = try #require(harness.bodies.first)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let options = try #require(object["options"] as? [String: Any])
        #expect((options["num_predict"] as? NSNumber)?.int64Value == Int64(Int.max))
        #expect(object["system"] == nil && object["raw"] == nil && object["template"] == nil)
        #expect((object["think"] as? Bool) == (variant == 1))
        if variant == 0 {
            #expect(object["truncate"] as? Bool == false)
            #expect(object["shift"] as? Bool == false)
            #expect(object["prompt"] as? String == request.prompt)
            try expectPropertyByteOrder(data, order: ["followUp", "r0"])
        } else {
            #expect(object["truncate"] == nil && object["shift"] == nil)
            #expect(object["prompt"] == nil)
            let messages = try #require(object["messages"] as? [[String: String]])
            #expect(messages.count == 1 && messages[0]["content"] == request.prompt)
        }
        if variant == 2 { #expect(object["format"] as? String == "json") }
        else { #expect(try JSONDecoder().decode(LocalJSONValue.self, from: JSONSerialization.data(withJSONObject: try #require(object["format"]))) == schema) }
    }

    @Test
    func optedInWirePreservesLargeIntegersOptionalOmissionAndSchemaScalars() async throws {
        let schema: LocalJSONValue = .object(["type": .string("object"), "properties": .object([
            "r0": .object(["type": .string("string"), "description": .string("中文🙂 \"quote\" / \\ \n\t"), "maxLength": .number(24), "default": .null]),
            "followUp": .object(["type": .string("string")])]),
            "required": .array([.string("followUp"), .string("r0")]), "additionalProperties": .boolean(false)])
        let harness = SchemaOrderHTTPHarness(packets: [#"{"followUp":"","r0":"ready"}"#])
        let host = "schema-wire-\(UUID().uuidString).invalid"
        SchemaOrderURLProtocol.register(harness, host: host)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SchemaOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); SchemaOrderURLProtocol.remove(host: host) }
        let provider = OllamaQwenProvider(baseURL: URL(string: "https://\(host)")!, session: session)
        let prompt = "Untrusted input 中文🙂 \" \\ / \n\t"
        let owned = try await provider.generateOwnedAnswer(request: .init(prompt: prompt, systemPrompt: nil,
            modelName: "synthetic-wire-order", temperature: 0, numPredict: Int.max, responseSchema: schema,
            responseSchemaPropertyOrder: ["r0", "followUp"]))
        do { for try await _ in owned.stream {}; await owned.producerTask.value }
        catch { owned.producerTask.cancel(); await owned.producerTask.value; throw error }
        let data = try #require(harness.bodies.first)
        let body = try JSONDecoder().decode(SchemaOrderBody.self, from: data)
        #expect(body.prompt == prompt && body.format == schema)
        #expect(body.options.numPredict == Int.max && body.options.temperature == 0)
        #expect(body.stream && !body.think)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["system"] == nil && object["raw"] == nil && object["template"] == nil)
        try expectPropertyByteOrder(data, order: ["r0", "followUp"])
    }

    /// Actual finite HTTP rejection, not a model/tokenizer or overflow simulation.
    /// Frozen structured input must be kept whole or fail without emitted output.
    @Test
    func structuredInputTooLongHTTPFailureCannotBecomeCompletedOutput() async throws {
        let schema: LocalJSONValue = .object(["type": .string("object"), "properties": .object([
            "r0": .object(["type": .string("string")]), "followUp": .object(["type": .string("string")])]),
            "required": .array([.string("r0"), .string("followUp")]), "additionalProperties": .boolean(false)])
        let harness = SchemaOrderHTTPHarness(packets: [#"{"error":"the input length exceeds the context length"}"#], statusCode: 400)
        let host = "schema-wire-\(UUID().uuidString).invalid"
        SchemaOrderURLProtocol.register(harness, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SchemaOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); SchemaOrderURLProtocol.remove(host: host) }
        let provider = OllamaQwenProvider(baseURL: URL(string: "https://\(host)")!, session: session)
        let request = LocalLLMRequest(prompt: "Frozen input 中文🙂 \"quotes\" / \\ \n\tend.",
            systemPrompt: "Frozen system policy: keep the complete supplied answer and rubric.",
            modelName: "synthetic-wire-order", temperature: 0, numPredict: 1200,
            responseSchema: schema, responseSchemaPropertyOrder: ["r0", "followUp"])
        let owned = try await provider.generateOwnedAnswer(request: request)
        var emitted = 0
        do {
            for try await _ in owned.stream { emitted += 1 }
            Issue.record("An HTTP 400 input rejection cannot complete a structured generation.")
        } catch {
            #expect((error as? OllamaQwenProviderError)?.category == .providerHTTPError)
            #expect(error.localizedDescription.contains("HTTP 400"))
        }
        await owned.producerTask.value
        #expect(emitted == 0)
        #expect(harness.bodies.count == 1)
        let data = try #require(harness.bodies.first)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["truncate"] as? Bool == false)
        #expect(body["prompt"] as? String == request.prompt)
        #expect(body["system"] as? String == request.systemPrompt)
        #expect(body["model"] as? String == request.modelName)
        #expect(body["stream"] as? Bool == true && body["think"] as? Bool == false)
        #expect(body["raw"] == nil && body["template"] == nil)
        #expect(body["shift"] as? Bool == false)
        let options = try #require(body["options"] as? [String: Any])
        #expect(Set(options.keys) == Set(["temperature", "num_predict"]))
        #expect((options["temperature"] as? NSNumber)?.doubleValue == 0)
        #expect((options["num_predict"] as? NSNumber)?.intValue == 1200)
        #expect(try JSONDecoder().decode(LocalJSONValue.self,
            from: JSONSerialization.data(withJSONObject: try #require(body["format"]))) == schema)
        try expectPropertyByteOrder(data, order: ["r0", "followUp"])
        let diagnostics = provider.lastGenerationDiagnostics
        #expect(!diagnostics.streamCompleted && diagnostics.finalErrorCategory == .providerHTTPError)
    }

    /// Complete JSON and a terminal frame are insufficient when the structured
    /// generation hit a limit. Ordinary chat/string-format semantics stay unchanged.
    @Test(arguments: Array(0..<3), ["stop", "length"])
    func onlyStructuredLengthTerminalRejectsEvenClosedJSON(_ variant: Int, doneReason: String) async throws {
        let schema: LocalJSONValue = .object(["type": .string("object"), "properties": .object([
            "r0": .object(["type": .string("string")]), "followUp": .object(["type": .string("string")])]),
            "required": .array([.string("r0"), .string("followUp")]), "additionalProperties": .boolean(false)])
        let packet = #"{"r0":"literal content","followUp":""}"#
        let harness = SchemaOrderHTTPHarness(packets: [packet], doneReason: doneReason)
        let host = "schema-wire-\(UUID().uuidString).invalid"
        SchemaOrderURLProtocol.register(harness, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SchemaOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); SchemaOrderURLProtocol.remove(host: host) }
        let provider = OllamaQwenProvider(baseURL: URL(string: "https://\(host)")!, session: session)
        let request = LocalLLMRequest(prompt: "Frozen answer and rubric", systemPrompt: nil,
            modelName: "synthetic-wire-order", temperature: 0, numPredict: 1200,
            responseFormat: variant == 2 ? "json" : nil,
            responseSchema: variant == 2 ? nil : schema, thinkingEnabled: variant == 1)
        let owned = try await provider.generateOwnedAnswer(request: request)
        let shouldReject = variant == 0 && doneReason == "length"
        var content = "", completed = false
        do {
            for try await token in owned.stream { content += token.text }
            completed = true
        } catch {
            #expect(shouldReject)
            #expect((error as? OllamaQwenProviderError)?.category == .responseSchemaMismatch)
            #expect(error.localizedDescription.contains("context or token limit"))
        }
        await owned.producerTask.value
        // Content can stream before rejection; do not confuse it with normal completion.
        #expect(content == packet && completed == !shouldReject)
        let diagnostics = provider.lastGenerationDiagnostics
        #expect(diagnostics.streamCompleted && diagnostics.doneReason == doneReason)
        #expect(diagnostics.promptEvalCount == 113 && diagnostics.evalCount == 7)
        #expect(diagnostics.totalDurationNS == 1_000_000)
        if shouldReject { #expect(diagnostics.finalErrorCategory == .responseSchemaMismatch) }
        else { #expect(diagnostics.finalErrorCategory == nil) }
        #expect(harness.bodies.count == 1)
        #expect((await session.allTasks).isEmpty)
    }

    @Test(arguments: Array(0..<6))
    func invalidOrderContractsFailWithoutSubmittingAChangedGeneration(_ variant: Int) async throws {
        var fields: [String: LocalJSONValue] = ["r0": .object(["type": .string("string")]), "followUp": .object(["type": .string("string")])]
        var required = ["r0", "followUp"], order = ["r0", "followUp"]
        if variant == 0 { order = ["r0", "r0"] }
        if variant == 1 { order = ["r0"] }
        if variant == 2 { required = ["r0"] }
        if variant == 3 { fields.removeValue(forKey: "followUp") }
        let schema: LocalJSONValue = .object(["type": .string("object"), "properties": .object(fields),
            "required": .array(required.map(LocalJSONValue.string)), "additionalProperties": .boolean(false)])
        let harness = SchemaOrderHTTPHarness(packets: [])
        let host = "schema-wire-\(UUID().uuidString).invalid"
        SchemaOrderURLProtocol.register(harness, host: host)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SchemaOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); SchemaOrderURLProtocol.remove(host: host) }
        let provider = OllamaQwenProvider(baseURL: URL(string: "https://\(host)")!, session: session)
        let owned = try await provider.generateOwnedAnswer(request: .init(prompt: "Finite invalid order control", systemPrompt: nil,
            modelName: "synthetic-wire-order", temperature: 0, numPredict: 32,
            responseSchema: variant == 5 ? nil : schema, responseSchemaPropertyOrder: order,
            thinkingEnabled: variant == 4))
        do { for try await _ in owned.stream {}; await owned.producerTask.value; Issue.record("Invalid explicit wire order must not be ignored.") }
        catch { owned.producerTask.cancel(); await owned.producerTask.value; #expect(error.localizedDescription.contains("Explicit schema order")) }
        #expect(harness.bodies.isEmpty)
    }

    // Root format.properties emits each requested field before nested assessment
    // properties. Nested rN keys repeat; escaped JSON in prompt is not an
    // unescaped field token. Check first root positions, not dictionary iteration.
    private func expectPropertyByteOrder(_ data: Data, order: [String]) throws {
        let wire = String(decoding: data, as: UTF8.self)
        var positions: [String.Index] = []
        for key in order {
            let token = String(decoding: try JSONEncoder().encode(key), as: UTF8.self) + ":"
            try #require(wire.components(separatedBy: token).count >= 2)
            positions.append(try #require(wire.range(of: token)).lowerBound)
        }
        #expect(positions == positions.sorted())
    }
}

private struct SchemaOrderBody: Decodable {
    struct Options: Decodable {
        let temperature: Double; let numPredict: Int
        enum CodingKeys: String, CodingKey { case temperature; case numPredict = "num_predict" }
    }
    let model: String; let prompt: String; let stream: Bool; let think: Bool
    let format: LocalJSONValue; let options: Options
}
private final class SchemaOrderHTTPHarness: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [Data]())
    let packets: [String]
    let statusCode: Int
    let doneReason: String?
    init(packets: [String], statusCode: Int = 200, doneReason: String? = nil) {
        self.packets = packets; self.statusCode = statusCode; self.doneReason = doneReason
    }
    var bodies: [Data] { state.withLock { $0 } }
    func response(for request: URLRequest) throws -> Data {
        if request.url?.path == "/api/tags" { return Data(#"{"models":[{"name":"synthetic-wire-order"}]}"#.utf8) }
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
                if count == 0 { break }; body.append(buffer, count: count)
            }
            data = body
        } else { throw URLError(.badServerResponse) }
        let index = state.withLock { values in let index = values.count; values.append(data); return index }
        guard index < packets.count else { throw URLError(.badServerResponse) }
        if statusCode != 200 { return Data(packets[index].utf8) }
        let text = String(decoding: try JSONEncoder().encode(packets[index]), as: UTF8.self)
        let field = request.url?.path == "/api/generate" ? "\"response\":\(text)" : "\"message\":{\"role\":\"assistant\",\"content\":\(text)}"
        let terminal = doneReason.map {
            ",\"done_reason\":\"\($0)\",\"prompt_eval_count\":113,\"eval_count\":7,\"total_duration\":1000000"
        } ?? ""
        return Data(("{\(field),\"done\":true\(terminal)}\n").utf8)
    }
}
/// Stateless synchronous URL-loading adapter: no task or mutable instance state.
/// Foundation's URLProtocol base is unchecked Sendable; fixture state is checked
/// lock-protected and private to an exact unique host. This is a test SDK leaf only.
private final class SchemaOrderURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = OSAllocatedUnfairLock(initialState: [String: SchemaOrderHTTPHarness]())
    static func register(_ harness: SchemaOrderHTTPHarness, host: String) { registry.withLock { $0[host] = harness } }
    static func remove(host: String) { registry.withLock { _ = $0.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url, let host = url.host,
                  let harness = Self.registry.withLock({ $0[host] }) else { throw URLError(.badURL) }
            let data = try harness.response(for: request)
            let status = url.path == "/api/tags" ? 200 : harness.statusCode
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/x-ndjson"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

import Foundation
import Testing
@testable import Hireva

// These call existing production APIs and are valid before the owner transfer.
// A pure migration should preserve every result rather than manufacture a RED.
@MainActor
struct LiveQuestionIngressCharacterizationTests {
    enum DuplicateCase: CaseIterable {
        case sameOriginAfterCooldown, differentOriginBeforeCooldown
        case differentOriginAtCooldown, differentOriginAfterCooldown
        case nearDuplicateSameOriginAfterCooldown, emptyQuestion
    }

    @Test(.timeLimit(.minutes(1)), arguments: DuplicateCase.allCases)
    func actualDuplicateEntryPreservesOriginAndCooldown(_ testCase: DuplicateCase) async throws {
        try await withApp { app in
            let question = "Explain database transactions and atomicity."
            let began = Date(timeIntervalSince1970: 1_000)
            let first = app.isDuplicateAutoQuestion(question, transcriptSegmentID: "first-origin", now: began)
            #expect(!first)
            let second: String
            let origin: String
            let elapsed: TimeInterval
            let expected: Bool
            switch testCase {
            case .sameOriginAfterCooldown:
                second = question; origin = "first-origin"; elapsed = 120; expected = true
            case .differentOriginBeforeCooldown:
                second = question; origin = "second-origin"; elapsed = 59; expected = true
            case .differentOriginAtCooldown:
                second = question; origin = "second-origin"; elapsed = 60; expected = true
            case .differentOriginAfterCooldown:
                second = question; origin = "second-origin"; elapsed = 120; expected = false
            case .nearDuplicateSameOriginAfterCooldown:
                second = "Explain database transactions and atomicity in detail."
                origin = "first-origin"; elapsed = 120; expected = true
            case .emptyQuestion:
                second = "   "; origin = "second-origin"; elapsed = 1; expected = false
            }
            let result = app.isDuplicateAutoQuestion(second,
                transcriptSegmentID: origin, now: began.addingTimeInterval(elapsed))
            #expect(result == expected)
            #expect(app.duplicateSuppressionCount == (expected ? 1 : 0))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [AudioSourceType.systemAudio, .processAudio, .mock], [false, true])
    func actualExtractionKeepsFinalTruthAndNovelSpan(_ source: AudioSourceType, unicode: Bool) async throws {
        try await withApp { app in
            let firstText = "Explain database transactions and atomicity."
            let final = segment(id: "cumulative", source: source, text: firstText,
                recognition: "first-recognition", sequence: 1, finalization: "final_accepted")
            let first = try #require(app.systemAudioSegmentForQuestionExtraction(from: final))
            #expect(first.text == firstText)
            #expect(first.recognitionTaskID == final.recognitionTaskID)
            #expect(first.sourceTextStartUTF16 == 0)
            #expect(first.sourceTextEndUTF16 == firstText.utf16.count)

            let partial = segment(id: "cumulative", source: source, text: firstText + " How does isolation",
                recognition: "first-recognition", sequence: 2, finalization: "partial")
            let partialResult = try #require(app.systemAudioSegmentForQuestionExtraction(from: partial))
            #expect(partialResult == partial, "A partial remains a UI/extraction input and does not consume final reconciliation memory")
            let secondText = unicode ? "请解释数据库事务隔离级别，以及它如何影响并发处理。🧪" : "Explain transaction isolation and concurrency."
            let merged = segment(id: "cumulative", source: source, text: firstText + " " + secondText,
                recognition: "rotated-recognition", sequence: 1, finalization: "final_accepted")
            let novel = try #require(app.systemAudioSegmentForQuestionExtraction(from: merged))
            #expect(novel.text == secondText)
            #expect(novel.sourceTextStartUTF16 == firstText.utf16.count + 1)
            #expect(novel.recognitionTaskID == merged.recognitionTaskID)
            #expect(novel.recognitionEventSequence == merged.recognitionEventSequence)
            #expect(novel.asrSource == merged.asrSource)
            let matchingFinal = try #require(app.systemAudioSegmentForQuestionExtraction(from: merged))
            #expect(matchingFinal == merged, "A matching final with a complete question keeps the existing final source-of-truth fallback")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualClearResetsQuestionOriginMemoryWithoutStartingAudio() async throws {
        try await withApp { app in
            let question = "Explain database transactions and atomicity."
            let began = Date(timeIntervalSince1970: 1_000)
            #expect(!app.isDuplicateAutoQuestion(question, transcriptSegmentID: "same-origin", now: began))
            #expect(app.isDuplicateAutoQuestion(question, transcriptSegmentID: "same-origin", now: began.addingTimeInterval(120)))
            app.clearLiveSession()
            #expect(app.currentSession == nil)
            #expect(app.transcriptSegments.isEmpty)
            #expect(!app.isDuplicateAutoQuestion(question, transcriptSegmentID: "same-origin", now: began.addingTimeInterval(120)))
        }
    }

    private func segment(id: String, source: AudioSourceType, text: String,
        recognition: String, sequence: Int, finalization: String) -> TranscriptSegment {
        TranscriptSegment(id: id, sessionID: "synthetic-ingress", source: source,
            speaker: .interviewer, text: text, asrSource: .appleASR,
            asrFinalizationReason: finalization, recognitionTaskID: recognition,
            recognitionEventSequence: sequence, sourceTextStartUTF16: 0,
            sourceTextEndUTF16: text.utf16.count, recognitionIsFinal: finalization != "partial")
    }

    private func withApp(_ body: (AppState) async throws -> Void) async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(), keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: nil)
        do {
            try await body(app)
            await app.shutdownForTesting()
            try database.close()
        } catch {
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }
}

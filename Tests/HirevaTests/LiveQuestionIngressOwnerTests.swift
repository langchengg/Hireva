import Combine
import Foundation
import Testing
@testable import Hireva

// New-owner characterization, compiled after the pure transfer. No claim of an
// original-API failure is made for these newly available method boundaries.
@MainActor
struct LiveQuestionIngressOwnerTests {
    enum ReplayCase: CaseIterable {
        case sameRecognitionOccurrence, rotatedExactSpan, rotatedOverlap
        case rotatedDistantSpan, distinctExplicitUtterance, legacyExplicitUtterance
    }

    @Test(arguments: ReplayCase.allCases)
    func consumedSourceIdentityAndIntentionalRepeatKeepTheirExistingRules(_ testCase: ReplayCase) throws {
        let owner = LiveInterviewFeature()
        let original = question(id: "original", recognition: "recognition-1", start: 0, end: 100)
        owner.rememberConsumedTranscriptOccurrence(original)
        let incoming: DetectedQuestion
        let cumulative: Bool
        let expectedReplay: Bool
        let expectedRepeat: Bool
        switch testCase {
        case .sameRecognitionOccurrence:
            incoming = question(id: "same-occurrence", recognition: "recognition-1", start: 0, end: 100)
            cumulative = false; expectedReplay = true; expectedRepeat = false
        case .rotatedExactSpan:
            incoming = question(id: "rotated-exact", recognition: "recognition-2", start: 0, end: 100)
            cumulative = true; expectedReplay = true; expectedRepeat = false
        case .rotatedOverlap:
            incoming = question(id: "rotated-overlap", recognition: "recognition-2", start: 5, end: 105)
            cumulative = true; expectedReplay = true; expectedRepeat = false
        case .rotatedDistantSpan:
            incoming = question(id: "rotated-distant", recognition: "recognition-2", start: 50, end: 150)
            cumulative = true; expectedReplay = false; expectedRepeat = false
        case .distinctExplicitUtterance:
            incoming = question(id: "intentional", recognition: "recognition-2", start: 150, end: 250)
            cumulative = false; expectedReplay = false; expectedRepeat = true
        case .legacyExplicitUtterance:
            var legacy = question(id: "legacy-intentional", recognition: "recognition-2", start: 150, end: 250)
            legacy.ingressIdentity = nil
            incoming = legacy
            cumulative = false; expectedReplay = false; expectedRepeat = true
        }
        let replay = owner.consumedReplaySource(incoming, isCumulativeTranscript: cumulative)
        #expect((replay != nil) == expectedReplay)
        if expectedReplay { #expect(replay == original.ingressIdentity) }
        let repeatAllowed = owner.isIntentionalQuestionRepeat(incoming,
            isCumulativeTranscript: cumulative, replayedOccurrence: replay != nil)
        #expect(repeatAllowed == expectedRepeat)
        if repeatAllowed { owner.markIntentionalQuestionRepeat(incoming.id) }
        #expect(owner.intentionalRepeatQuestionIDs.contains(incoming.id) == expectedRepeat)
        owner.resetQuestionIngress()
        #expect(owner.consumedReplaySource(incoming, isCumulativeTranscript: cumulative) == nil)
        #expect(!owner.isIntentionalQuestionRepeat(incoming,
            isCumulativeTranscript: cumulative, replayedOccurrence: false))
        #expect(owner.intentionalRepeatQuestionIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func appCompatibilityAndDirectOwnerUseTheSameIngressMemory() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(), keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: nil)
        do {
            let owner = app.liveInterview
            let text = "Explain database transactions and atomicity."
            let began = Date(timeIntervalSince1970: 1_000)
            owner.rememberAutoQuestion(text, transcriptSegmentID: "owner-origin", now: began)
            #expect(app.isDuplicateAutoQuestion(text, transcriptSegmentID: "owner-origin", now: began.addingTimeInterval(120)))
            app.recentQuestionTimestamps = app.recentQuestionTimestamps.mapValues { _ in began.addingTimeInterval(-120) }
            #expect(!owner.isRecentDuplicateAutoQuestion(text,
                transcriptSegmentID: "different-origin", now: began))
            owner.markIntentionalQuestionRepeat("synthetic-repeat")
            #expect(app.intentionalRepeatQuestionIDs == ["synthetic-repeat"])
            app.clearLiveSession()
            #expect(owner.intentionalRepeatQuestionIDs.isEmpty)
            #expect(!owner.isRecentDuplicateAutoQuestion(text,
                transcriptSegmentID: "owner-origin", now: began))
            await app.shutdownForTesting()
            try database.close()
        } catch {
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    @Test
    func ingressTimingPrunesOldestMetadataWithoutHighFrequencyUIPublication() {
        let owner = LiveInterviewFeature()
        let began = Date(timeIntervalSince1970: 1_000)
        var publications = 0
        let subscription = owner.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for index in 0...512 {
            owner.recordTranscriptIngress(segmentID: "synthetic-ingress-\(index)",
                at: began.addingTimeInterval(Double(index)))
        }
        #expect(owner.transcriptIngressDate(for: "synthetic-ingress-0") == nil)
        #expect(owner.transcriptIngressDate(for: "synthetic-ingress-255") == nil)
        #expect(owner.transcriptIngressDate(for: "synthetic-ingress-256") == began.addingTimeInterval(256))
        #expect(owner.transcriptIngressDate(for: "synthetic-ingress-512") == began.addingTimeInterval(512))
        #expect(publications == 0)
    }

    @Test
    func acceptedQueueCommitsNestedCoordinationBeforeOneFinalNotification() {
        let owner = LiveInterviewFeature()
        let began = Date(timeIntervalSince1970: 1_000)
        let session = InterviewSession(id: "synthetic-ingress-session", title: "Synthetic queue", company: nil,
            role: nil, startedAt: began, endedAt: nil, mode: .mock, createdAt: began)
        let detected = question(id: "queued", recognition: "queue-recognition", start: 0, end: 100)
        let pending = LiveInterviewFeature.PendingAcceptedQuestion(question: detected, session: session,
            transcript: detected.questionText, canonicalQuestion: detected.questionText,
            intent: AnswerRelevancePolicy.intent(for: detected.questionText), promptPrimaryQuestion: detected.questionText,
            duplicateKey: "synthetic-queue-key", queuedAt: began, consentTicket: 7)
        var effects: [String] = []
        var observedEffects: [[String]] = []
        let subscription = owner.objectWillChange.sink { observedEffects.append(effects) }
        defer { subscription.cancel() }
        let enqueued = owner.enqueueAcceptedQuestion(pending) {
            effects.append("enqueued")
            #expect(owner.pendingAcceptedQuestions == [pending])
            let duplicate = owner.enqueueAcceptedQuestion(pending) { Issue.record("Duplicate ran committed effects") }
            #expect(!duplicate)
            var revised = pending.question; revised.reason = "Synthetic revised head"
            let wrongHead = LiveInterviewFeature.PendingAcceptedQuestion(question: revised, session: session,
                transcript: pending.transcript, canonicalQuestion: pending.canonicalQuestion, intent: pending.intent,
                promptPrimaryQuestion: pending.promptPrimaryQuestion, duplicateKey: pending.duplicateKey,
                queuedAt: pending.queuedAt, consentTicket: pending.consentTicket)
            let rejected = owner.dequeueAcceptedQuestion(ifHeadMatches: wrongHead) { _ in
                Issue.record("An obsolete full head was removed")
            }
            #expect(!rejected)
            let dequeued = owner.dequeueAcceptedQuestion(ifHeadMatches: pending) { removed in
                #expect(removed == pending && owner.pendingAcceptedQuestions.isEmpty)
                effects.append("dequeued")
            }
            #expect(dequeued)
            #expect(observedEffects.isEmpty, "A nested commit cannot publish before outer App coordination finishes.")
            effects.append("outer_finished")
        }
        #expect(enqueued)
        #expect(owner.pendingAcceptedQuestions.isEmpty)
        #expect(observedEffects == [["enqueued", "dequeued", "outer_finished"]])
    }

    private func question(id: String, recognition: String, start: Int, end: Int) -> DetectedQuestion {
        let text = "Explain database transactions and atomicity."
        return DetectedQuestion(id: id, sessionID: "synthetic-ingress-session", transcriptSegmentID: id,
            questionText: text, intent: .technical, answerStrategy: .technicalExplanation,
            confidence: 1, reason: "Synthetic ingress characterization", shouldTrigger: true,
            questionComplete: true, modelName: "fixture", promptVersion: "fixture", createdAt: Date(timeIntervalSince1970: 1_000),
            ingressIdentity: .init(recognitionTaskID: recognition, recognitionEventSequence: 1,
                sourceSegmentID: id, sourceStartUTF16: start, sourceEndUTF16: end,
                normalizedText: SemanticDuplicateKeyBuilder.key(for: text),
                eventTimestamp: Date(timeIntervalSince1970: 1_000), isFinal: true))
    }
}

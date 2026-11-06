import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct GenerationStageADeadlineStateTests {
    private let answer = "A database transaction groups operations into an atomic unit. All operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe."

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func actualFirstAnswerPreservationIsIdempotentAndRemainsProvisional(repetition: Int) async throws {
        try await exercise(repetition: repetition)
    }

    @Test(.timeLimit(.minutes(1)))
    func preservationMarkerPublicationCannotClearAReplacementAnswer() async throws {
        try await exercise(repetition: 20, replaceAtMarker: true)
    }

    @Test(.timeLimit(.minutes(1)))
    func preservationCardPublicationCannotChangeReplacementStreamingState() async throws {
        try await exercise(repetition: 21, replaceAtCard: true)
    }

    @Test(.timeLimit(.minutes(1)))
    func preservationFallbackPublicationCannotChangeReplacementTiming() async throws {
        try await exercise(repetition: 22, replaceAtFallback: true)
    }

    private func exercise(repetition: Int, replaceAtMarker: Bool = false, replaceAtCard: Bool = false,
                          replaceAtFallback: Bool = false) async throws {
        let suite = "StageADeadlineState-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try await TestSupport.makeInMemoryDatabase()
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: defaults)
        var stageB: Task<Void, Never>?
        var markerObservation: AnyCancellable?
        defer { markerObservation?.cancel() }
        do {
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            let question = DetectedQuestion(id: "synthetic-stage-a-\(repetition)", sessionID: session.id,
                transcriptSegmentID: nil, questionText: "Explain database transactions and atomicity.",
                intent: .technical, answerStrategy: .directAnswer, confidence: 1,
                reason: "Synthetic Stage A ownership characterization", shouldTrigger: true,
                questionComplete: true, modelName: "fixture", promptVersion: "fixture", createdAt: Date())
            try app.suggestionRepository.saveDetectedQuestion(question)
            let generationID = "synthetic-stage-a-generation-\(repetition)"
            let start = Date()
            app.activateGeneration(question: question, generationID: generationID,
                triggerPath: .manualGenerate, requestStart: start, source: nil, speaker: nil)
            let context = GenerationExecutionContext.make(session: session, question: question,
                generationID: generationID, triggerPath: .manualGenerate, provider: nil,
                retrievedContext: .init(cvChunks: [], jobDescriptionChunks: []),
                transcriptSnapshot: question.questionText, cvSummary: "", jdSummary: "",
                startedAt: start, source: nil, speaker: nil, stage: .firstAnswer)
            let sections = StreamingSuggestionSections(strategy: "Explanation", sayFirst: answer,
                keyPoints: ["All operations commit together or roll back together.",
                    "Isolation controls which concurrent changes are visible."], followUpReady: [], caution: "")
            #expect(app.publishStreamingSections(sections, cardID: "synthetic-stage-a-card-\(repetition)",
                generationID: generationID, question: question, session: session, requestStart: start,
                stageBStreamStartedMS: nil, markFullCardVisible: true))
            try #require(!app.generationUIState.isTerminal)
            let child = Task<Void, Never> {
                do { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
                catch { }
            }
            stageB = child
            app.registerStageBTask(child, generationID: generationID)
            #expect(!app.generationCoordinator.hasPreservedStageADeadlineAnswer(identity: context.identity))
            var replaced = false
            let nextGenerationID = UUID().uuidString
            let replacementTime = Date(timeIntervalSince1970: 1_000_000)
            func replaceGeneration() {
                replaced = true
                var nextQuestion = question
                nextQuestion.id = UUID().uuidString
                app.activateGeneration(question: nextQuestion, generationID: nextGenerationID,
                    triggerPath: .regenerate, requestStart: Date(), source: nil, speaker: nil)
                app.isStreamingSayFirst = true
                app.isExpandingSuggestionCard = false
                app.streamedSayFirst = "Synthetic replacement answer remains visible"
                app.finalVisibleSource = "synthetic-replacement-source"
                app.softFallbackLatencyMS = 777
                app.softFallbackShownAt = replacementTime
            }
            if replaceAtMarker {
                markerObservation = app.generationCoordinator.objectWillChange.sink {
                    guard !replaced, app.generationCoordinator.hasPreservedStageADeadlineAnswer(identity: context.identity) else { return }
                    replaceGeneration()
                }
            } else if replaceAtCard {
                markerObservation = app.liveInterview.suggestionUpdates.sink { card in
                    guard !replaced, card?.generationID == generationID,
                          card?.stageBStatus == "expanding" else { return }
                    replaceGeneration()
                }
            } else if replaceAtFallback {
                app.currentSuggestion = nil
                app.streamedSayFirst = ""
                markerObservation = app.liveInterview.softFallbackUsedUpdates.sink { used in
                    guard used, !replaced else { return }
                    replaceGeneration()
                }
            }
            let preservationAccepted = app.preserveStageAAnswerWhileExpansionContinues(context: context,
                cardID: "synthetic-stage-a-card-\(repetition)", answerProviderConfiguration: nil,
                fallbackProviderModel: "fixture", generationRetrievedChunks: [])
            if replaceAtMarker || replaceAtCard || replaceAtFallback {
                #expect(replaced)
                #expect(!preservationAccepted)
                #expect(app.currentGenerationID == nextGenerationID)
                #expect(app.streamedSayFirst == "Synthetic replacement answer remains visible")
                #expect(app.finalVisibleSource == "synthetic-replacement-source")
                #expect(app.isStreamingSayFirst)
                #expect(!app.isExpandingSuggestionCard)
                #expect(app.softFallbackLatencyMS == 777)
                #expect(app.softFallbackShownAt == replacementTime)
                child.cancel()
                await child.value
                await app.shutdownForTesting()
                #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
                try database.close()
                return
            }
            #expect(preservationAccepted)
            #expect(app.generationCoordinator.hasPreservedStageADeadlineAnswer(identity: context.identity))
            #expect(app.currentSuggestion?.stageBStatus == "expanding")
            #expect(!app.generationUIState.isTerminal)
            #expect(app.stageBTask != nil)
            #expect(app.suggestionPersistenceClaims.isEmpty)
            #expect(try app.suggestionRepository.suggestions(sessionID: session.id).isEmpty)
            let card = app.currentSuggestion
            let ui = app.generationUIState
            let telemetry = app.currentGenerationTelemetry
            let events = app.recentTranscriptRuntimeEvents
            #expect(app.preserveStageAAnswerWhileExpansionContinues(context: context,
                cardID: "synthetic-stage-a-card-\(repetition)", answerProviderConfiguration: nil,
                fallbackProviderModel: "fixture", generationRetrievedChunks: []))
            #expect(app.currentSuggestion == card)
            #expect(app.generationUIState == ui)
            #expect(app.currentGenerationTelemetry == telemetry)
            #expect(app.recentTranscriptRuntimeEvents == events)
            app.generationCoordinator.markTerminal(generationID: generationID)
            #expect(!app.preserveStageAAnswerWhileExpansionContinues(context: context,
                cardID: "synthetic-stage-a-card-\(repetition)", answerProviderConfiguration: nil,
                fallbackProviderModel: "fixture", generationRetrievedChunks: []))
            #expect(app.currentSuggestion == card)
            #expect(app.generationUIState == ui)
            child.cancel()
            await child.value
            await app.shutdownForTesting()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
            try database.close()
        } catch {
            stageB?.cancel()
            await stageB?.value
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    @Test
    func preservationMarkerBelongsOnlyToItsCompleteActiveIdentity() {
        let owner = GenerationCoordinator()
        let original = identity(generationID: "original", context: "original-context")
        owner.activate(identity: original, persistenceTicket: 1, triggerPath: .manualGenerate, startedAt: Date())
        #expect(!owner.hasPreservedStageADeadlineAnswer(identity: original))
        #expect(owner.recordPreservedStageADeadlineAnswer(identity: original))
        owner.markTerminal(generationID: original.generationID)
        #expect(!owner.recordPreservedStageADeadlineAnswer(identity: original))
        let next = identity(generationID: "next", context: "next-context")
        owner.activate(identity: next, persistenceTicket: 2, triggerPath: .manualGenerate, startedAt: Date())
        #expect(!owner.hasPreservedStageADeadlineAnswer(identity: next))
        #expect(!owner.recordPreservedStageADeadlineAnswer(identity: original))
        #expect(owner.recordPreservedStageADeadlineAnswer(identity: next))
        let replacedContext = identity(generationID: "next", context: "replaced-context")
        owner.activate(identity: replacedContext, persistenceTicket: 3, triggerPath: .manualGenerate, startedAt: Date())
        #expect(!owner.hasPreservedStageADeadlineAnswer(identity: replacedContext))
        #expect(!owner.recordPreservedStageADeadlineAnswer(identity: next))
        #expect(owner.recordPreservedStageADeadlineAnswer(identity: replacedContext))
        owner.closeAdmission()
        #expect(!owner.recordPreservedStageADeadlineAnswer(identity: replacedContext))
        #expect(owner.pendingCleanupTaskCount == 0)
    }

    private func identity(generationID: String, context: String) -> GenerationIdentity {
        .init(acceptedQuestionID: "synthetic-marker-question", generationID: generationID,
            sessionID: "synthetic-marker-session", questionText: "Explain database transactions.",
            promptPrimaryQuestion: "Explain database transactions.", contextSnapshotID: context)
    }
}

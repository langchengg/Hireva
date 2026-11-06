import Foundation
import Testing
@testable import Hireva

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ManualSubmissionBoundaryTests {
    @Test(arguments: [false, true])
    func explicitRegenerateAfterEnablingSavingDoesNotRestoreTheOffTranscript(sourceStored: Bool) async throws {
        let fixture = try await ManualSnapshotFixture()
        var pending: [Task<Void, Never>] = []
        do {
            let text = "Explain database transactions and atomicity."
            let segment = TranscriptSegment(id: "regenerate-source", sessionID: fixture.session.id,
                source: .mock, speaker: .interviewer, text: text)
            if sourceStored { try fixture.app.transcriptRepository.saveSegment(segment) }
            var visible = fixture.parent(id: "off-question", answer:
                "A database transaction groups operations into an atomic unit.")
            visible.questionText = text
            visible.transcriptSegmentID = segment.id
            fixture.app.currentSuggestion = visible
            let oldTicket = fixture.app.persistenceConsent.ticket()
            var settings = fixture.app.settings
            settings.saveTranscriptsLocally = true
            fixture.app.saveSettings(settings)
            #expect(!fixture.app.persistenceConsent.isCurrent(ticket: oldTicket))
            #expect(try fixture.app.suggestionRepository.suggestionCount() == 0)

            fixture.app.regenerateVisibleSuggestion()
            pending.append(try #require(fixture.app.activeAITask))
            try await fixture.join(try #require(pending.last))
            fixture.clock.cancelAll()
            await fixture.app.generationCoordinator.drainRetiredTasks()

            let question = try #require(try fixture.app.suggestionRepository.questions(sessionID: fixture.session.id).first)
            #expect(question.id == visible.questionID)
            #expect(question.transcriptSegmentID == (sourceStored ? segment.id : nil))
            let storedSource = try fixture.app.transcriptRepository.segmentByID(segment.id)
            #expect(storedSource?.id == (sourceStored ? segment.id : nil))
            #expect(storedSource?.text == (sourceStored ? segment.text : nil))
            let saved = try #require(try fixture.app.suggestionRepository.latestSuggestion(sessionID: fixture.session.id))
            #expect(saved.generationID == fixture.app.currentSuggestion?.generationID)
            #expect(saved.generationID != visible.generationID)
            #expect(saved.questionDecision?.questionID == question.id)
            #expect(fixture.app.currentGenerationTelemetry.dbError == nil)
            try await fixture.close(pending)
        } catch {
            try? await fixture.close(pending)
            throw error
        }
    }

    @Test
    func regenerateCannotRenewItsSubmittedPersistenceTicketAfterOffOn() async throws {
        let fixture = try await ManualSnapshotFixture()
        var pending: [Task<Void, Never>] = []
        do {
            var settings = fixture.app.settings
            settings.saveTranscriptsLocally = true
            fixture.app.saveSettings(settings)
            var visible = fixture.parent(id: "revoked-regenerate", answer:
                "A database transaction groups operations into an atomic unit.")
            visible.questionText = "Explain database transactions and atomicity."
            visible.transcriptSegmentID = "unsaved-off-source"
            fixture.app.currentSuggestion = visible
            let submittedTicket = fixture.app.persistenceConsent.ticket()
            fixture.app.regenerateVisibleSuggestion()
            pending.append(try #require(fixture.app.activeAITask))
            // Revoke before the queued root executes, then enable a newer ticket.
            settings.saveTranscriptsLocally = false; fixture.app.saveSettings(settings)
            settings.saveTranscriptsLocally = true; fixture.app.saveSettings(settings)
            try await fixture.join(try #require(pending.last))
            fixture.clock.cancelAll()
            await fixture.app.generationCoordinator.drainRetiredTasks()
            #expect(!fixture.app.persistenceConsent.isCurrent(ticket: submittedTicket))
            #expect(fixture.app.activeGenerationController?.persistenceTicket == submittedTicket)
            #expect(try fixture.app.suggestionRepository.questions(sessionID: fixture.session.id).isEmpty)
            #expect(try fixture.app.suggestionRepository.suggestionCount() == 0)
            #expect(try fixture.app.transcriptRepository.segments(sessionID: fixture.session.id).isEmpty)
            try await fixture.close(pending)
        } catch {
            try? await fixture.close(pending)
            throw error
        }
    }

    @Test(arguments: [ManualRequestSnapshotTests.ManualEntry.answerNow, .capture])
    func remoteEntryUsesSubmissionConfigurationBeforeRootTaskRuns(entry: ManualRequestSnapshotTests.ManualEntry) async throws {
        let fixture = try await ManualSnapshotFixture(mode: .deepSeekPrimary)
        var pending: [Task<Void, Never>] = []
        do {
            let text = "Explain database transactions and atomicity."
            fixture.setTranscript(text)
            let original = try #require(fixture.app.activeRealtimeProvider)
            switch entry {
            case .answerNow:
                fixture.app.manualAnswerNow()
                pending.append(try #require(fixture.app.activeAITask))
            case .capture:
                fixture.app.manualCaptureState = .transcriptReady
                fixture.app.manualCaptureTranscript = text
                fixture.app.sendManualCaptureToAI()
                pending.append(try #require(fixture.app.stageBTask))
            }

            // No MainActor suspension separates the action from this edit.
            // The queued real request must use the configuration at submission.
            var replacement = original
            replacement.model = "replacement-remote-manual-model"
            replacement.name = "Replacement Synthetic Provider"
            replacement.baseURL = "https://replacement.example.invalid"
            fixture.app.saveProviderConfiguration(replacement)
            let saved = try #require(fixture.app.activeRealtimeProvider)
            #expect(saved.id == replacement.id && saved.kind == replacement.kind &&
                saved.model == replacement.model && saved.name == replacement.name &&
                saved.baseURL == replacement.baseURL)
            try await fixture.join(try #require(pending.last))
            if let expansion = fixture.app.stageBTask {
                pending.append(expansion)
                try await fixture.join(expansion)
            }

            let configurations = fixture.remote.providerConfigurations()
            #expect(!configurations.isEmpty)
            #expect(configurations.allSatisfy { $0.id == original.id && $0.kind == original.kind &&
                $0.model == original.model && $0.name == original.name && $0.baseURL == original.baseURL })
            #expect(fixture.app.currentSuggestion?.modelName == original.model)
            #expect(fixture.app.currentSuggestion?.providerName == original.name)
            #expect(fixture.app.currentSuggestion?.providerBaseURL == original.baseURL)
            if entry == .answerNow {
                #expect(fixture.app.lastDetectedQuestion?.modelName == original.model)
                #expect(fixture.app.lastDetectedQuestion?.providerName == original.name)
                #expect(fixture.app.lastDetectedQuestion?.providerBaseURL == original.baseURL)
            }
            #expect(await fixture.original.requests().isEmpty)
            #expect(await fixture.replacement.requests().isEmpty)
            try await fixture.close(pending)
        } catch {
            try? await fixture.close(pending)
            throw error
        }
    }

    @Test
    func regenerateFreezesLocalProviderAndModelBeforeRootTaskRuns() async throws {
        let fixture = try await ManualSnapshotFixture()
        var pending: [Task<Void, Never>] = []
        do {
            var visible = fixture.parent(id: "regenerate-visible", answer:
                "A database transaction groups operations into an atomic unit.")
            visible.questionText = "Explain database transactions and atomicity."
            fixture.app.currentSuggestion = visible
            fixture.app.regenerateVisibleSuggestion()
            pending.append(try #require(fixture.app.activeAITask))
            fixture.app.setSelectedQwenModelName("replacement-regenerate-model")
            fixture.app.localLLMProviderOverride = fixture.replacement
            try await fixture.join(try #require(pending.last))

            let requests = await fixture.original.requests()
            #expect(requests.count == 1)
            #expect(requests.first?.modelName == fixture.originalModel)
            #expect(requests.first?.prompt.contains(try #require(visible.questionText)) == true)
            #expect(await fixture.replacement.requests().isEmpty)
            #expect(fixture.remote.requests().isEmpty)
            #expect(fixture.app.currentSuggestion?.questionText == visible.questionText)
            #expect(fixture.app.currentSuggestion?.modelName == fixture.originalModel)
            #expect(fixture.app.currentSuggestion?.sayFirstSource == "ollama_qwen")
            try await fixture.close(pending)
        } catch {
            try? await fixture.close(pending)
            throw error
        }
    }

    @Test(arguments: [ManualRequestSnapshotTests.ManualEntry.answerNow, .capture])
    func localRouterFallbackUsesTheSameFrozenProviderAsAnswer(entry: ManualRequestSnapshotTests.ManualEntry) async throws {
        // The router override is an immutable AppState dependency. When it is
        // absent, routing must reuse the concrete local provider frozen by the
        // user action rather than read a later local override.
        let fixture = try await ManualSnapshotFixture(useAnswerProviderForRouting: true)
        var pending: [Task<Void, Never>] = []
        do {
            let text = "Explain database transactions and atomicity."
            fixture.setTranscript(text)
            switch entry {
            case .answerNow:
                fixture.app.manualAnswerNow()
                pending.append(try #require(fixture.app.activeAITask))
            case .capture:
                fixture.app.manualCaptureState = .transcriptReady
                fixture.app.manualCaptureTranscript = text
                fixture.app.sendManualCaptureToAI()
                pending.append(try #require(fixture.app.stageBTask))
            }
            fixture.app.setSelectedQwenModelName("replacement-router-model")
            fixture.app.localLLMProviderOverride = fixture.replacement
            try await fixture.join(try #require(pending.last))

            let requests = await fixture.original.requests()
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.modelName == fixture.originalModel })
            #expect(requests.filter { $0.responseSchema != nil }.count == 1)
            #expect(requests.filter { $0.responseSchema == nil }.count == 1)
            #expect(await fixture.replacement.requests().isEmpty)
            #expect(fixture.remote.requests().isEmpty)
            #expect(fixture.app.currentSuggestion?.modelName == fixture.originalModel)
            #expect(fixture.app.currentSuggestion?.sayFirstSource == "ollama_qwen")
            try await fixture.close(pending)
        } catch {
            try? await fixture.close(pending)
            throw error
        }
    }

    @Test
    func remoteAnswerNowCapturesParentBeforeDetectionStarts() async throws {
        let fixture = try await ManualSnapshotFixture(mode: .deepSeekPrimary)
        var pending: [Task<Void, Never>] = []
        do {
            fixture.setTranscript("Explain database transactions and atomicity.")
            let original = fixture.parent(id: "submitted-remote-parent", answer:
                "Use bounded retries for transient transaction failures.")
            fixture.app.currentSuggestion = original
            fixture.app.manualAnswerNow()
            pending.append(try #require(fixture.app.activeAITask))
            fixture.app.currentSuggestion = fixture.parent(id: "later-remote-parent", answer:
                "This later answer must not become the submitted request's parent.")
            try await fixture.join(try #require(pending.last))
            if let expansion = fixture.app.stageBTask {
                pending.append(expansion)
                try await fixture.join(expansion)
            }

            let parent = try #require(fixture.app.lastDetectedQuestion?.taskDescriptor?.conversationContext)
            #expect(parent.questionID == original.questionID)
            #expect(parent.questionText == original.questionText)
            #expect(parent.answerText == original.sayFirst)
            #expect(parent.contextSnapshotID == original.contextSnapshotID)
            #expect(fixture.app.lastDetectedQuestion?.taskDescriptor?.conversationContextCaptured == true)
            #expect(fixture.app.currentSuggestion?.questionText == "Explain database transactions and atomicity.")
            #expect(!fixture.remote.requests().isEmpty)
            try await fixture.close(pending)
        } catch {
            try? await fixture.close(pending)
            throw error
        }
    }
}

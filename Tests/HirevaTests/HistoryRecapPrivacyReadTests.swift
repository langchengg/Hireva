import Foundation
import Testing
@testable import Hireva

/// App settings changes revoke the ticket and cancel its root. The direct
/// feature test separately exercises a fresh policy read with a valid ticket.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct HistoryRecapPrivacyReadTests {
    @Test
    func appliedHistorySettingRevokesTheTicketAndCancelsTheRecap() async throws {
        let fixture = try await RecapEntryFixture(localOnly: false, holdRouting: true)
        var roots: [Task<Void, Never>] = []
        do {
            let ticket = fixture.app.persistenceConsent.ticket()
            fixture.app.generateRecap(for: fixture.session)
            let root = try #require(fixture.app.recapTask)
            roots.append(root)
            try await fixture.routingGate.waitUntilEntered()
            fixture.app.settingsState.settings.saveTranscriptsLocally = false
            #expect(!fixture.app.persistenceConsent.isCurrent(ticket: ticket),
                "The applied settings owner emits its existing privacy event for member mutation too.")
            #expect(root.isCancelled)
            fixture.routingGate.releaseAll()
            try await fixture.join(root)
            #expect(try fixture.app.recapRepository.versions(sessionID: fixture.session.id).isEmpty)
            #expect(fixture.app.selectedSessionRecap == nil)
            #expect(!fixture.app.isGeneratingRecap)
            try await fixture.close(roots)
        } catch {
            try? await fixture.close(roots)
            throw error
        }
    }

    @Test
    func aFreshDeniedFeaturePolicyCannotBeReplacedByAnOldValidTicket() async throws {
        let fixture = try await RecapEntryFixture(localOnly: false, holdRouting: true)
        var roots: [Task<Void, Never>] = []
        var persistenceAllowed = true
        do {
            let ticket = fixture.app.persistenceConsent.ticket()
            let root = try #require(try fixture.app.historyState.requestRecap(
                sessionID: fixture.session.id, providerConfiguration: fixture.configuration,
                routingProvider: fixture.local, routingModel: fixture.originalModel,
                localOnly: false, persistenceAllowed: { persistenceAllowed },
                onFeedback: { _ in }, onError: { _ in }, didPublish: { _ in }))
            roots.append(root)
            try await fixture.routingGate.waitUntilEntered()
            // This feature dependency deliberately emits no settings event or
            // consent transition. It isolates the independent pre-write read.
            persistenceAllowed = false
            #expect(fixture.app.persistenceConsent.isCurrent(ticket: ticket))
            #expect(!root.isCancelled)
            fixture.routingGate.releaseAll()
            try await fixture.join(root)
            #expect(try fixture.app.recapRepository.versions(sessionID: fixture.session.id).isEmpty)
            #expect(fixture.app.selectedSessionRecap == nil)
            #expect(!fixture.app.isGeneratingRecap)
            try await fixture.close(roots)
        } catch {
            try? await fixture.close(roots)
            throw error
        }
    }
}

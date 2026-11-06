import Combine
import Foundation
import Testing
@testable import Hireva

/// Calls the existing error setter and its real publisher. No stream, native
/// capture, TCC, models, process or production preference domain is created.
@Suite
@MainActor
struct SystemAudioErrorPublicationTests {
    @Test(arguments: [false, true])
    func synchronousErrorObserverSeesCommittedValueAndCannotRestoreTheOuterError(clear: Bool) {
        let service = ScreenCaptureKitSystemAudioCaptureService()
        let original = "synthetic terminal error before a new request"
        let replacement: String? = clear ? nil : "synthetic replacement owner diagnostic"
        var observedStoredValue: String?
        var replaced = false
        let subscription = service.lastErrorUpdates.dropFirst().sink { incoming in
            guard !replaced, incoming == original else { return }
            replaced = true
            observedStoredValue = service.lastError
            service.lastError = replacement
        }
        defer { subscription.cancel() }
        service.lastError = original
        #expect(replaced)
        #expect(observedStoredValue == original,
            "Error admission must commit its only authoritative value before a synchronous observer runs")
        #expect(service.lastError == replacement,
            "The old setter must not restore its value over the observer's clear or replacement")
    }

    @Test
    func clearingErrorNotifiesAnAlreadyCommittedNilValue() {
        let service = ScreenCaptureKitSystemAudioCaptureService()
        service.lastError = "synthetic old diagnostic"
        var observed = false
        var observedOldValue = false
        let subscription = service.lastErrorUpdates.dropFirst().sink { incoming in
            guard incoming == nil else { return }
            observed = true
            observedOldValue = service.lastError != nil
        }
        defer { subscription.cancel() }
        service.lastError = nil
        #expect(observed)
        #expect(!observedOldValue,
            "A nil update must expose committed storage, rather than the former error")
        #expect(service.lastError == nil)
    }
}

import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite
struct GenerationCoordinatorTests {
    @Test
    func coordinatorInitializesWithDependenciesWithoutAppState() async throws {
        let delayProvider = RecordingDelayProvider()
        let dependencies = GenerationCoordinator.Dependencies(delayProvider: delayProvider)
        let coordinator = GenerationCoordinator(dependencies: dependencies)

        try await coordinator.dependencies.delayProvider.sleep(nanoseconds: 123)

        #expect(coordinator.dependencies.suggestionGenerationService == nil)
        #expect(delayProvider.recordedSleeps == [123])
    }

    @Test
    func elapsedMSIsDeterministicWhenNowIsSupplied() {
        let start = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 101.5)

        #expect(GenerationCoordinator.elapsedMS(since: start, now: now) == 1500)
    }

    @Test
    func timeoutHelperReturnsCompletedOperation() async throws {
        let value = try await GenerationCoordinator.withTimeout(seconds: 1.0) {
            "completed"
        }

        #expect(value == "completed")
    }

    @Test
    func timeoutHelperThrowsSameTimeoutErrorShape() async throws {
        do {
            _ = try await GenerationCoordinator.withTimeout(seconds: 0.001) {
                try await Task.sleep(nanoseconds: 50_000_000)
                return "late"
            }
            Issue.record("Expected timeout helper to throw")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "TimeoutDomain")
            #expect(nsError.code == 1)
            #expect(nsError.localizedDescription.contains("Request timed out after 0.001s"))
        }
    }

    @Test
    func specificAnswerCheckMatchesExistingCompletenessRules() {
        #expect(GenerationCoordinator.isSpecificAnswer("short answer") == false)
        #expect(GenerationCoordinator.isSpecificAnswer("Based on my experience") == false)
        #expect(GenerationCoordinator.isSpecificAnswer("The diffusion policy was more stable because it produced smoother continuous actions and recovered better from small trajectory errors.") == true)
    }
}

private final class RecordingDelayProvider: DelayProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var sleeps: [UInt64] = []

    var recordedSleeps: [UInt64] {
        lock.withLock { sleeps }
    }

    func sleep(nanoseconds: UInt64) async throws {
        lock.withLock { sleeps.append(nanoseconds) }
    }
}

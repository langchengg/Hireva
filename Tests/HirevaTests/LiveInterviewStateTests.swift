import Testing
@testable import Hireva

struct LiveInterviewStateTests {
    @Test
    func permissionDeniedCanRecoverByStartingAgainButCannotStop() {
        let state = LiveInterviewState.permissionDenied

        #expect(state.canStartListening)
        #expect(!state.canStop)
        #expect(state.canAnswerNow)
        #expect(state.displayName == "Permission Denied")
    }

    @Test
    func errorStateCarriesUserFacingMessageAndCanRecover() {
        let state = LiveInterviewState.error("Microphone unavailable")

        #expect(state.canStartListening)
        #expect(!state.canStop)
        #expect(state.canAnswerNow)
        #expect(state.displayName == "Error")
        #expect(state.errorMessage == "Microphone unavailable")
    }
}

import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
@MainActor
struct InterviewDialogueModeTests {
    @Test
    func panelQuestionsModeDoesNotRequireCandidateAnswerSwitch() {
        var state = DialogueRuntimeState.initial(for: .panelQuestions)

        let q1 = decide(systemQuestion("How did your technical background prepare you for robotics research?"), state: state)
        state = state.applying(q1)
        let a1 = decide(candidateSpeech("My background was mainly computer science and deep learning."), state: state)
        state = state.applying(a1)
        let q2 = decide(systemQuestion("How did that background help you move into robotics?"), state: state)

        #expect(q1.shouldEvaluateQuestion)
        #expect(!a1.shouldEvaluateQuestion)
        #expect(a1.turnType == .candidateAnswer)
        #expect(q2.shouldEvaluateQuestion)
        #expect(state.resolvedSessionPhase == .panelQuestions)
    }

    @Test
    func continuousFiveTurnDialogueRequiresNoManualModeChanges() {
        var state = DialogueRuntimeState.initial(for: .panelQuestions)
        let turns = [
            systemQuestion("How did your technical background prepare you for robotics research?"),
            candidateSpeech("My background was mainly computer science and deep learning."),
            systemQuestion("How did that background help you move into robotics?"),
            candidateSpeech("It gave me experience in modelling and programming."),
            systemQuestion("Which part of your current project became most relevant to this PhD?")
        ]

        let decisions = turns.map { segment -> DialogueTriggerDecision in
            let decision = decide(segment, state: state)
            state = state.applying(decision)
            return decision
        }

        #expect(decisions.filter(\.shouldEvaluateQuestion).count == 3)
        #expect(decisions.filter { $0.turnType == .candidateAnswer && !$0.shouldEvaluateQuestion }.count == 2)
        #expect(state.selectedSessionMode == .panelQuestions)
        #expect(state.resolvedSessionPhase == .panelQuestions)
    }

    @Test
    func microphoneCandidateSpeechDoesNotTriggerAnswer() {
        let state = DialogueRuntimeState.initial(for: .panelQuestions)
        let decision = decide(candidateSpeech("Could you explain the first year milestones?"), state: state)

        #expect(!decision.shouldEvaluateQuestion)
        #expect(decision.speakerRole == .candidate)
        #expect(decision.turnType == .candidateAnswer)
        #expect(decision.blockedReasonCode == "candidateSpeech")
    }

    @Test
    func systemAudioPanelQuestionTriggersWithMicOff() {
        let state = DialogueRuntimeState.initial(for: .auto)
        let decision = decide(
            TranscriptSegment(
                id: "system-unknown",
                sessionID: "test",
                source: .systemAudio,
                speaker: .unknown,
                text: "How does your current project prepare you for this PhD?"
            ),
            state: state
        )

        #expect(decision.shouldEvaluateQuestion)
        #expect(decision.speakerRole == .interviewer)
        #expect(decision.nextResolvedSessionPhase == .panelQuestions)
    }

    @Test
    func presentationSuppressesCandidateSpeech() {
        let state = DialogueRuntimeState.initial(for: .presentation)
        let decision = decide(
            candidateSpeech("My presentation explains a language guided manipulation pipeline."),
            state: state
        )

        #expect(!decision.shouldEvaluateQuestion)
        #expect(decision.turnType == .candidatePresentation)
        #expect(decision.decision == .suppressCandidatePresentation)
    }

    @Test
    func firstPanelQuestionAutomaticallyEndsPresentation() {
        let state = DialogueRuntimeState.initial(for: .presentation)
        let decision = decide(
            systemQuestion("How did your current project prepare you for this PhD?"),
            state: state,
            mode: .presentation
        )
        let next = state.applying(decision)

        #expect(decision.shouldEvaluateQuestion)
        #expect(next.resolvedSessionPhase == .panelQuestions)
        #expect(decision.modeTransitionReason == "first substantive panel question accepted")
    }

    @Test
    func candidateAnswerDoesNotChangeGlobalPanelMode() {
        let state = DialogueRuntimeState.initial(for: .panelQuestions)
        let decision = decide(candidateSpeech("I used deep learning and NLP before robotics."), state: state)
        let next = state.applying(decision)

        #expect(decision.turnType == .candidateAnswer)
        #expect(decision.nextResolvedSessionPhase == nil)
        #expect(next.selectedSessionMode == .panelQuestions)
        #expect(next.resolvedSessionPhase == .panelQuestions)
    }

    @Test
    func panelInvitationTransitionsToCandidateQuestions() {
        let state = DialogueRuntimeState.initial(for: .panelQuestions)
        let decision = decide(systemQuestion("Do you have any questions for us?"), state: state)
        let next = state.applying(decision)

        #expect(!decision.shouldEvaluateQuestion)
        #expect(decision.decision == .transitionToCandidateQuestions)
        #expect(next.resolvedSessionPhase == .candidateQuestions)
    }

    @Test
    func candidateQuestionToPanelDoesNotGenerateAnswer() {
        let state = DialogueRuntimeState(
            selectedSessionMode: .auto,
            resolvedSessionPhase: .candidateQuestions
        )
        let decision = decide(
            candidateSpeech("Which tactile sensor would you recommend that I learn first?"),
            state: state,
            mode: .auto
        )

        #expect(!decision.shouldEvaluateQuestion)
        #expect(decision.turnType == .candidateQuestionToPanel)
        #expect(decision.decision == .candidateQuestionToPanel)
    }

    @Test
    func systemAudioCandidateQuestionStaysSuppressedAfterPanelInvitation() {
        var state = DialogueRuntimeState.initial(for: .auto)
        state = state.applying(decide(
            systemQuestion("That completes our formal questions. Is there anything you would like to ask the panel?"),
            state: state
        ))

        let candidateQuestion = decide(
            systemQuestion("Which tactile sensor and robot platform would you recommend that I learn first in your laboratory?"),
            state: state
        )
        state = state.applying(candidateQuestion)

        #expect(!candidateQuestion.shouldEvaluateQuestion)
        #expect(candidateQuestion.decision == .candidateQuestionToPanel)
        #expect(state.resolvedSessionPhase == .candidateQuestions)
    }

    @Test
    func autoModeCanResumePanelQuestionsAfterCandidateQuestions() {
        var state = DialogueRuntimeState.initial(for: .auto)
        let invitation = decide(systemQuestion("Do you have any questions for us?"), state: state)
        state = state.applying(invitation)
        let candidateQuestion = decide(
            candidateSpeech("Which tactile sensor would you recommend that I learn first?"),
            state: state
        )
        state = state.applying(candidateQuestion)
        let panelFollowUp = decide(
            systemQuestion("Before we finish, how would you validate that tactile policy?"),
            state: state
        )
        state = state.applying(panelFollowUp)

        #expect(!invitation.shouldEvaluateQuestion)
        #expect(!candidateQuestion.shouldEvaluateQuestion)
        #expect(panelFollowUp.shouldEvaluateQuestion)
        #expect(panelFollowUp.speakerRole == .interviewer)
        #expect(state.selectedSessionMode == .auto)
        #expect(state.resolvedSessionPhase == .panelQuestions)
    }

    @Test
    func panelModeCanResumeAfterCandidateQuestionsWithoutManualSwitch() {
        var state = DialogueRuntimeState.initial(for: .panelQuestions)
        state = state.applying(decide(systemQuestion("Do you have any questions for us?"), state: state))
        state = state.applying(decide(
            candidateSpeech("Which tactile sensor would you recommend that I learn first?"),
            state: state
        ))
        let followUp = decide(
            systemQuestion("Before we finish, how would you validate that tactile policy?"),
            state: state
        )
        state = state.applying(followUp)

        #expect(followUp.shouldEvaluateQuestion)
        #expect(state.selectedSessionMode == .panelQuestions)
        #expect(state.resolvedSessionPhase == .panelQuestions)
    }

    @Test
    func legacyCandidateAnswerPhaseMigratesToPanelQuestions() throws {
        let suiteName = "InterviewDialogueModeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(InterviewListeningMode.panelQuestionsOnly.rawValue, forKey: DialogueSettingsStore.legacyListeningModeKey)
        defaults.set(InterviewPhase.candidateAnswer.rawValue, forKey: DialogueSettingsStore.legacyPhaseKey)

        let result = DialogueSettingsStore.loadAndMigrate(defaults: defaults)

        #expect(result.selectedMode == .panelQuestions)
        #expect(result.resolvedPhase == .panelQuestions)
        #expect(result.legacyTurnType == .candidateAnswer)
        #expect(result.contextMode == .phdRobotics)
        #expect(result.answerPanelQuestions)
        #expect(result.suppressPresentation)
        #expect(result.suppressCandidateQuestions)
        #expect(defaults.string(forKey: DialogueSettingsStore.sessionModeKey) == InterviewSessionMode.panelQuestions.rawValue)
        #expect(defaults.object(forKey: DialogueSettingsStore.legacyPhaseKey) == nil)
        #expect(defaults.object(forKey: DialogueSettingsStore.legacyListeningModeKey) == nil)
    }

    @Test
    func nextPanelQuestionWorksAfterLongCandidateAnswer() {
        var state = DialogueRuntimeState.initial(for: .panelQuestions)
        let longAnswer = Array(repeating: "I tested the pipeline on real hardware and inspected each handoff.", count: 12).joined(separator: " ")
        let candidateDecision = decide(candidateSpeech(longAnswer), state: state)
        state = state.applying(candidateDecision)
        let panelDecision = decide(
            systemQuestion("Which failure case would you prioritise when moving onto the real robot?"),
            state: state
        )

        #expect(!candidateDecision.shouldEvaluateQuestion)
        #expect(panelDecision.shouldEvaluateQuestion)
        #expect(state.resolvedSessionPhase == .panelQuestions)
    }

    @Test
    func displayModeSwitchDoesNotChangeInterviewMode() throws {
        let appState = AppState(database: try TestSupport.makeTemporaryDatabase(prefix: "InterviewDialogueModeTests"))
        appState.interviewSessionMode = .panelQuestions
        var settings = appState.settings

        for mode in FloatingAssistantDisplayMode.allCases {
            settings.floatingAssistantDisplayMode = mode
            appState.saveSettings(settings)
            #expect(appState.interviewSessionMode == .panelQuestions)
            #expect(appState.resolvedInterviewSessionPhase == .panelQuestions)
        }
    }

    @Test
    func imperativeAndScenarioPromptsUseGeneralQuestionFamilies() {
        let prompts = [
            "Describe the control architecture you used on the robot arm, from perception through ROS2 to physical motion execution.",
            "Imagine that the camera predicts a stable grasp, but the tactile sensor reports that the object is slipping. How should the robot respond?"
        ]

        for prompt in prompts {
            let candidates = QuestionCandidatePipeline.extract(from: prompt)
            let expected = prompt.hasSuffix(".") ? String(prompt.dropLast()) : prompt
            #expect(candidates.map(\.text) == [expected])
            #expect(QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: prompt).accepted)
        }
    }

    @Test
    func narrativeImperativesAreNotPromotedToQuestions() {
        let statements = [
            "I can explain the architecture we used.",
            "We can describe the control stack in more detail.",
            "I can imagine that the tactile signal would be noisy.",
            "The report will explain why the controller failed."
        ]

        for statement in statements {
            #expect(QuestionCandidatePipeline.extract(from: statement).isEmpty)
            #expect(!QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: statement).accepted)
        }
    }

    @Test
    func politeQualifiedImperativesRemainQuestions() {
        let prompts = [
            "Please briefly describe your control architecture.",
            "I'd like you to explain the main trade-off.",
            "Now briefly imagine that the tactile signal becomes noisy."
        ]

        for prompt in prompts {
            #expect(QuestionCandidatePipeline.extract(from: prompt).count == 1)
            #expect(QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: prompt).accepted)
        }
    }

    @Test
    func partialASRDoesNotCommitDialogueTransition() throws {
        let appState = AppState(database: try TestSupport.makeTemporaryDatabase(prefix: "InterviewDialogueModeTests"))
        appState.interviewSessionMode = .auto
        let decision = decide(
            systemQuestion("Do you have any questions for us?"),
            state: appState.dialogueRuntimeState
        )

        appState.applyDialogueDecision(
            decision,
            source: .systemAudio,
            allowModeTransition: false
        )

        #expect(appState.resolvedInterviewSessionPhase == .auto)
        #expect(appState.detectedDialogueSpeakerRole == .interviewer)
        #expect(appState.detectedDialogueTurnType == .statement)
    }

    @Test
    func dialogueControlsPersistIndependently() throws {
        let suiteName = "InterviewDialogueModeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(InterviewContextMode.general.rawValue, forKey: DialogueSettingsStore.contextModeKey)
        defaults.set(InterviewSessionMode.presentation.rawValue, forKey: DialogueSettingsStore.sessionModeKey)
        defaults.set(false, forKey: DialogueSettingsStore.answerPanelQuestionsKey)
        defaults.set(false, forKey: DialogueSettingsStore.suppressPresentationKey)
        defaults.set(false, forKey: DialogueSettingsStore.suppressCandidateQuestionsKey)

        let result = DialogueSettingsStore.loadAndMigrate(defaults: defaults)

        #expect(result.contextMode == .general)
        #expect(result.selectedMode == .presentation)
        #expect(!result.answerPanelQuestions)
        #expect(!result.suppressPresentation)
        #expect(!result.suppressCandidateQuestions)
    }

    private func decide(
        _ segment: TranscriptSegment,
        state: DialogueRuntimeState,
        mode: InterviewSessionMode? = nil
    ) -> DialogueTriggerDecision {
        InterviewDialogueTriggerPolicy.decideDialogueTrigger(
            segment: segment,
            sessionMode: mode ?? state.selectedSessionMode,
            currentState: state,
            answerPanelQuestions: true,
            suppressPresentation: true,
            suppressCandidateQuestions: true
        )
    }

    private func systemQuestion(_ text: String) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID().uuidString,
            sessionID: "test",
            source: .systemAudio,
            speaker: .interviewer,
            text: text
        )
    }

    private func candidateSpeech(_ text: String) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID().uuidString,
            sessionID: "test",
            source: .microphone,
            speaker: .candidate,
            text: text
        )
    }
}

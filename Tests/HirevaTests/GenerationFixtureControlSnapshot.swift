import Dispatch
import Foundation
@testable import Hireva

// Control metadata only. Handle presence does not claim that work has exited.
@MainActor
func generationFixtureControlSnapshot(app: AppState,
    clock: ControlledGenerationWatchdogClock, monotonicStartNS: UInt64) -> String {
    let now = DispatchTime.now().uptimeNanoseconds
    let identity = app.generationCoordinator.activeGeneration?.identity
    let card = app.currentSuggestion
    let values: [String: Any] = [
        "monotonic_now_ns": now,
        "poll_elapsed_monotonic_ns": now >= monotonicStartNS ? now - monotonicStartNS : 0,
        "generation_id": app.currentGenerationID ?? "",
        "question_id": app.activeQuestionID ?? "",
        "request_id": app.generationCoordinator.activeRequest?.id ?? "",
        "request_handle_present": app.activeAITask != nil,
        "request_cancelled": app.activeAITask?.isCancelled ?? false,
        "stage_a_handle_present": app.generationCoordinator.stageATask != nil,
        "stage_a_cancelled": app.generationCoordinator.stageATask?.isCancelled ?? false,
        "stage_b_handle_present": app.stageBTask != nil,
        "stage_b_cancelled": app.stageBTask?.isCancelled ?? false,
        "full_watchdog_handle_present": app.fullCardWatchdogTask != nil,
        "full_watchdog_cancelled": app.fullCardWatchdogTask?.isCancelled ?? false,
        "retiring_task_count": app.generationCoordinator.retiringTaskCount,
        "owned_cleanup_handle_count": app.generationCoordinator.pendingCleanupTaskCount,
        "clock_pending_count": clock.pendingCount,
        "clock_requested_count": clock.requestedNanoseconds.count,
        // This is an actual clock request count, not an invented trigger count.
        "stage_b_500ms_deadline_requests": clock.requestedNanoseconds.filter { $0 == 500_000_000 }.count,
        "question_generation_triggered": app.lastTranscriptQuestionGenerationTrace.generationTriggered,
        "question_trigger_decision": app.lastTranscriptQuestionGenerationTrace.triggerDecision,
        "generation_ui_state": app.generationUIState.displayName,
        "generation_terminal": app.generationUIState.isTerminal,
        "coordinator_current_identity_matches": identity.map { app.generationCoordinator.isCurrent($0) } ?? false,
        "coordinator_current_identity_can_publish": identity.map { app.generationCoordinator.canPublish($0) } ?? false,
        "coordinator_current_terminal_fence": app.currentGenerationID.map { app.generationCoordinator.terminalGenerationIDs.contains($0) } ?? false,
        "visible_card_matches_current_owner": identity.flatMap { owner in card.map { app.visibleCardMatchesGeneration(card: $0, generationID: owner.generationID, detectedQuestionID: owner.acceptedQuestionID, promptPrimaryQuestion: owner.questionText) } } ?? false,
        "visible_card_stage_b_completed": card?.stageBCompleted ?? false,
        "visible_card_stage_b_stream_started": card?.stageBStreamStartedMS != nil,
        "visible_card_full_snapshot_marked": card?.fullCardVisibleMS != nil,
        "sqlite_awaiting_transcript_timing": app.lastSQLiteOperation == "Loading transcript timing in background",
        "sqlite_transcript_timing_loaded": app.lastSQLiteOperation == "Loaded transcript timing",
        "provider_operation_stage_b_sections": app.lastProviderOperation == "Stage B section stream started",
        "provider_operation_stage_b_full_fallback": app.lastProviderOperation == "Stage B full-card fallback started",
        "stage_b_worker_trace_matches_current": app.diagnosticsState.stageBWorkerTrace?.generationID == app.currentGenerationID,
        "stage_b_worker_trace_phase": app.diagnosticsState.stageBWorkerTrace?.phase ?? 0,
        "stage_b_worker_trace_token_count": app.diagnosticsState.stageBWorkerTrace?.tokenCount ?? 0,
        "stage_b_worker_trace_did_exit": app.diagnosticsState.stageBWorkerTrace?.didExit ?? false,
        "stage_b_worker_trace_uptime_ns": app.diagnosticsState.stageBWorkerTrace?.updatedMonotonicNS ?? 0,
        "stage_b_worker_trace_began_uptime_ns": app.diagnosticsState.stageBWorkerTrace?.beganMonotonicNS ?? 0,
        "stage_b_worker_first_phase_uptime_ns": Dictionary(uniqueKeysWithValues:
            (app.diagnosticsState.stageBWorkerTrace?.firstPhaseMonotonicNS ?? [:]).map { (String($0.key), $0.value) }),
        "visible_answer_exists": app.visibleAnswerExists,
        "pending_question_count": app.pendingAcceptedQuestions.count
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else {
        return "generation_control_snapshot_serialization_failed"
    }
    return String(decoding: data, as: UTF8.self)
}

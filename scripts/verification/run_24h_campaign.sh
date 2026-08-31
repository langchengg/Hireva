#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DURATION_HOURS=""
STATE_DIR=""
ARTIFACT_DIR=""
RESUME=false
HEARTBEAT_INTERVAL_SECONDS="${HIREVA_CAMPAIGN_HEARTBEAT_SECONDS:-300}"
CHECKPOINT_INTERVAL_SECONDS="${HIREVA_CAMPAIGN_CHECKPOINT_SECONDS:-1800}"
POLL_INTERVAL_SECONDS="${HIREVA_CAMPAIGN_POLL_SECONDS:-5}"
CURRENT_CHILD_PID=""
CURRENT_PHASE="initializing"
LOCK_DIR=""
RUN_STARTED_EPOCH=""
ACTIVE_BASE_SECONDS=0
LAST_HEARTBEAT_EPOCH=0
LAST_CHECKPOINT_EPOCH=0
CAMPAIGN_EXIT_REASON=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/verification/run_24h_campaign.sh \
  --duration-hours HOURS \
  --state-dir ABSOLUTE_PATH \
  --artifact-dir ABSOLUTE_PATH [--resume]

Runs the Hireva validation campaign in the foreground. Active time advances
only while this supervisor is running. Interruptions are persisted and excluded
from active elapsed time. Use resume_24h_campaign.sh after an interruption.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration-hours) DURATION_HOURS="${2:-}"; shift 2 ;;
        --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
        --artifact-dir) ARTIFACT_DIR="${2:-}"; shift 2 ;;
        --resume) RESUME=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: required command is unavailable: $1" >&2
        exit 2
    }
}

for required_command in jq git swift ruby python3; do
    require_command "$required_command"
done

[[ "$DURATION_HOURS" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: --duration-hours must be a positive whole number" >&2
    exit 2
}
[[ "$STATE_DIR" == /* && "$ARTIFACT_DIR" == /* ]] || {
    echo "error: state and artifact directories must be absolute paths" >&2
    exit 2
}
[[ "$HEARTBEAT_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ &&
   "$CHECKPOINT_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ &&
   "$POLL_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: campaign intervals must be positive whole seconds" >&2
    exit 2
}

mkdir -p "$STATE_DIR" "$ARTIFACT_DIR/logs" "$ARTIFACT_DIR/research" \
    "$ARTIFACT_DIR/results" "$ARTIFACT_DIR/audio" "$ARTIFACT_DIR/db" \
    "$ARTIFACT_DIR/crashes" "$ARTIFACT_DIR/patches" "$ARTIFACT_DIR/reports"
STATE_DIR="$(cd "$STATE_DIR" && pwd -P)"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd -P)"
case "$STATE_DIR/" in "$ROOT_DIR/"*) echo "error: campaign state must remain outside the repository" >&2; exit 2;; esac
case "$ARTIFACT_DIR/" in "$ROOT_DIR/"*) echo "error: campaign artifacts must remain outside the repository" >&2; exit 2;; esac
[[ "$STATE_DIR" == "$ARTIFACT_DIR/state" ]] || {
    echo "error: state directory must be the artifact directory's state subdirectory" >&2
    exit 2
}

STATE_FILE="$STATE_DIR/campaign_state.json"
FAILURE_QUEUE="$STATE_DIR/failure_queue.jsonl"
RESEARCH_SOURCES="$STATE_DIR/research_sources.jsonl"
CHECKPOINTS="$STATE_DIR/checkpoints.jsonl"
HEARTBEAT_FILE="$STATE_DIR/heartbeat.json"
SCENARIO_RESULTS="$ARTIFACT_DIR/results/scenario_results.jsonl"
REAL_AUDIO_RESULTS="$ARTIFACT_DIR/results/real_audio_results.jsonl"
ANSWER_QUALITY_RESULTS="$ARTIFACT_DIR/results/answer_quality_results.jsonl"
APP_HOME="$ARTIFACT_DIR/app-home"
APP_SUPPORT_DIR="$APP_HOME/Library/Application Support/Hireva"
LOCK_DIR="$STATE_DIR/campaign.lock"
umask 077
mkdir -p "$APP_SUPPORT_DIR"

utc_timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

iso_from_epoch() {
    date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

atomic_jq_write() {
    local destination="$1"
    shift
    local temporary_file
    temporary_file="$(mktemp "$STATE_DIR/.state.XXXXXX")"
    jq "$@" > "$temporary_file"
    mv "$temporary_file" "$destination"
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        return
    fi
    local existing_pid=""
    if [[ -f "$LOCK_DIR/pid" ]]; then
        existing_pid="$(sed -n '1p' "$LOCK_DIR/pid")"
    fi
    if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
        echo "error: campaign supervisor is already running with pid $existing_pid" >&2
        exit 2
    fi
    local stale_lock="$STATE_DIR/campaign.lock.stale.$(date -u +%Y%m%dT%H%M%SZ).$$"
    mv "$LOCK_DIR" "$stale_lock"
    mkdir "$LOCK_DIR"
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

release_lock() {
    [[ -d "$LOCK_DIR" ]] || return 0
    if [[ -f "$LOCK_DIR/pid" ]] && [[ "$(sed -n '1p' "$LOCK_DIR/pid")" == "$$" ]]; then
        rm "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR"
    fi
}

current_active_seconds() {
    local now_epoch
    now_epoch="$(date +%s)"
    printf '%s\n' "$((ACTIVE_BASE_SECONDS + now_epoch - RUN_STARTED_EPOCH))"
}

owned_process_ids() {
    local app_binary="$ROOT_DIR/dist/Hireva.app/Contents/MacOS/Hireva"
    local helper_binary="$ROOT_DIR/dist/Hireva.app/Contents/Helpers/parakeet_asr_helper"
    /bin/ps -axo pid=,command= | awk -v app="$app_binary" -v helper="$helper_binary" '
        $2 == app || $2 == helper { print $1 }
    '
}

owned_app_pid() {
    local app_binary="$ROOT_DIR/dist/Hireva.app/Contents/MacOS/Hireva"
    /bin/ps -axo pid=,command= | awk -v app="$app_binary" '$2 == app { print $1; exit }'
}

owned_helper_pids_json() {
    local helper_binary="$ROOT_DIR/dist/Hireva.app/Contents/Helpers/parakeet_asr_helper"
    /bin/ps -axo pid=,command= | awk -v helper="$helper_binary" '$2 == helper { print $1 }' | jq -Rsc '
        split("\n") | map(select(length > 0) | tonumber)
    '
}

persist_state() {
    local now active app_pid helpers_json status
    now="$(utc_timestamp)"
    active="$(current_active_seconds)"
    app_pid="$(owned_app_pid || true)"
    helpers_json="$(owned_helper_pids_json)"
    status="running"
    [[ -n "$CAMPAIGN_EXIT_REASON" ]] && status="$CAMPAIGN_EXIT_REASON"
    atomic_jq_write "$STATE_FILE" \
        --arg now "$now" \
        --arg phase "$CURRENT_PHASE" \
        --arg status "$status" \
        --argjson active "$active" \
        --argjson app_pid "${app_pid:-null}" \
        --argjson helper_pids "$helpers_json" \
        '.active_elapsed_seconds = $active
         | .current_phase = $phase
         | .status = $status
         | .app_pid = $app_pid
         | .helper_pids = $helper_pids
         | .last_heartbeat = $now
         | .updated_at_utc = $now' "$STATE_FILE"
}

write_heartbeat() {
    local now active temporary_file
    now="$(utc_timestamp)"
    active="$(current_active_seconds)"
    temporary_file="$(mktemp "$STATE_DIR/.heartbeat.XXXXXX")"
    jq -n \
        --arg campaign_id "$(jq -r '.campaign_id' "$STATE_FILE")" \
        --arg timestamp "$now" \
        --arg phase "$CURRENT_PHASE" \
        --argjson pid "$$" \
        --argjson active "$active" \
        '{campaign_id: $campaign_id, timestamp: $timestamp, pid: $pid,
          current_phase: $phase, active_elapsed_seconds: $active}' > "$temporary_file"
    mv "$temporary_file" "$HEARTBEAT_FILE"
    persist_state
    LAST_HEARTBEAT_EPOCH="$(date +%s)"
    echo "[campaign] heartbeat phase=$CURRENT_PHASE active_seconds=$active"
}

write_checkpoint() {
    local now active head patch_path
    now="$(utc_timestamp)"
    active="$(current_active_seconds)"
    head="$(git -C "$ROOT_DIR" rev-parse HEAD)"
    patch_path="$ARTIFACT_DIR/patches/checkpoint-$(date -u +%Y%m%dT%H%M%SZ).patch"
    git -C "$ROOT_DIR" diff --binary > "$patch_path"
    jq -cn \
        --arg timestamp "$now" \
        --arg phase "$CURRENT_PHASE" \
        --arg head "$head" \
        --arg patch_path "$patch_path" \
        --argjson active "$active" \
        '{timestamp: $timestamp, active_elapsed_seconds: $active,
          current_phase: $phase, head: $head, patch_path: $patch_path}' >> "$CHECKPOINTS"
    LAST_CHECKPOINT_EPOCH="$(date +%s)"
    echo "[campaign] checkpoint phase=$CURRENT_PHASE head=$head"
}

maybe_heartbeat_and_checkpoint() {
    local now_epoch
    now_epoch="$(date +%s)"
    if (( now_epoch - LAST_HEARTBEAT_EPOCH >= HEARTBEAT_INTERVAL_SECONDS )); then
        write_heartbeat
    fi
    if (( now_epoch - LAST_CHECKPOINT_EPOCH >= CHECKPOINT_INTERVAL_SECONDS )); then
        write_checkpoint
    fi
}

terminate_child_tree() {
    local parent_pid="$1"
    local child_pid
    while IFS= read -r child_pid; do
        [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
        terminate_child_tree "$child_pid"
    done < <(pgrep -P "$parent_pid" 2>/dev/null || true)
    kill -TERM "$parent_pid" 2>/dev/null || true
}

stop_owned_runtime_processes() {
    local pid
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done < <(owned_process_ids)
    local deadline=$((SECONDS + 10))
    while (( SECONDS < deadline )); do
        [[ -z "$(owned_process_ids)" ]] && return 0
        sleep 0.25
    done
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -KILL "$pid" 2>/dev/null || true
    done < <(owned_process_ids)
}

cleanup() {
    local exit_status=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n "$CURRENT_CHILD_PID" ]] && kill -0 "$CURRENT_CHILD_PID" 2>/dev/null; then
        terminate_child_tree "$CURRENT_CHILD_PID"
        wait "$CURRENT_CHILD_PID" 2>/dev/null
    fi
    CURRENT_CHILD_PID=""
    stop_owned_runtime_processes
    if [[ -f "$STATE_FILE" ]]; then
        [[ -n "$CAMPAIGN_EXIT_REASON" ]] || CAMPAIGN_EXIT_REASON="interrupted"
        if [[ "$CAMPAIGN_EXIT_REASON" == "interrupted" ]]; then
            atomic_jq_write "$STATE_FILE" '.interrupt_count += 1' "$STATE_FILE"
        fi
        persist_state
        write_checkpoint
        {
            echo "Resume with:"
            echo "./scripts/verification/resume_24h_campaign.sh \\"
            printf '  --state-dir "%s"\n' "$(jq -r '.state_dir' "$STATE_FILE")"
        } > "$STATE_DIR/resume_command.txt"
    fi
    release_lock
    exit "$exit_status"
}

trap cleanup EXIT
trap 'CAMPAIGN_EXIT_REASON="interrupted"; exit 130' INT
trap 'CAMPAIGN_EXIT_REASON="interrupted"; exit 143' TERM

acquire_lock
NOW_EPOCH="$(date +%s)"
RUN_STARTED_EPOCH="$NOW_EPOCH"
TARGET_ACTIVE_SECONDS="$((DURATION_HOURS * 60 * 60))"

if [[ ! -f "$STATE_FILE" ]]; then
    [[ "$RESUME" == "false" ]] || { echo "error: no campaign state exists to resume" >&2; exit 2; }
    CAMPAIGN_ID="hireva-24h-$(date -u +%Y%m%dT%H%M%SZ)"
    START_TIME="$(iso_from_epoch "$NOW_EPOCH")"
    TARGET_END_TIME="$(iso_from_epoch "$((NOW_EPOCH + TARGET_ACTIVE_SECONDS))")"
    BASE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
    BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
    jq -n \
        --arg campaign_id "$CAMPAIGN_ID" \
        --arg start_time "$START_TIME" \
        --arg target_end_time "$TARGET_END_TIME" \
        --arg base_commit "$BASE_COMMIT" \
        --arg branch "$BRANCH" \
        --arg state_dir "$STATE_DIR" \
        --arg artifact_dir "$ARTIFACT_DIR" \
        --arg now "$(utc_timestamp)" \
        --argjson target_active "$TARGET_ACTIVE_SECONDS" \
        '{schema_version: 1, campaign_id: $campaign_id,
          start_time_utc: $start_time, target_end_time_utc: $target_end_time,
          target_active_seconds: $target_active, active_elapsed_seconds: 0,
          base_commit: $base_commit, branch: $branch, last_good_commit: $base_commit,
          current_phase: "initializing", current_scenario: null,
          completed_cycles: 0, completed_steps: [], open_failures: 0,
          fixed_failures: 0, last_successful_gate: null, app_pid: null,
          helper_pids: [], last_heartbeat: $now, updated_at_utc: $now,
          status: "running", interrupt_count: 0, resume_count: 0,
          state_dir: $state_dir, artifact_dir: $artifact_dir}' > "$STATE_FILE"
    : > "$FAILURE_QUEUE"
    : > "$RESEARCH_SOURCES"
    : > "$CHECKPOINTS"
    : > "$SCENARIO_RESULTS"
    : > "$REAL_AUDIO_RESULTS"
    : > "$ANSWER_QUALITY_RESULTS"
else
    [[ "$RESUME" == "true" ]] || {
        echo "error: campaign state already exists; use resume_24h_campaign.sh" >&2
        exit 2
    }
    jq -e '.schema_version == 1 and (.active_elapsed_seconds | type == "number")' "$STATE_FILE" >/dev/null
    [[ "$(jq -r '.state_dir' "$STATE_FILE")" == "$STATE_DIR" ]] || { echo "error: state directory does not match persisted campaign" >&2; exit 2; }
    [[ "$(jq -r '.artifact_dir' "$STATE_FILE")" == "$ARTIFACT_DIR" ]] || { echo "error: artifact directory does not match persisted campaign" >&2; exit 2; }
    TARGET_ACTIVE_SECONDS="$(jq -r '.target_active_seconds' "$STATE_FILE")"
    DURATION_HOURS="$((TARGET_ACTIVE_SECONDS / 3600))"
    ACTIVE_BASE_SECONDS="$(jq -r '.active_elapsed_seconds | floor' "$STATE_FILE")"
    atomic_jq_write "$STATE_FILE" '.resume_count += 1 | .status = "running"' "$STATE_FILE"
fi

ACTIVE_BASE_SECONDS="$(jq -r '.active_elapsed_seconds | floor' "$STATE_FILE")"
LAST_HEARTBEAT_EPOCH="$NOW_EPOCH"
LAST_CHECKPOINT_EPOCH="$NOW_EPOCH"
write_heartbeat
write_checkpoint

step_completed() {
    local step_id="$1"
    jq -e --arg step "$step_id" '.completed_steps | index($step) != null' "$STATE_FILE" >/dev/null
}

mark_step_completed() {
    local step_id="$1" gate_name="$2"
    local head
    head="$(git -C "$ROOT_DIR" rev-parse HEAD)"
    atomic_jq_write "$STATE_FILE" \
        --arg step "$step_id" \
        --arg gate "$gate_name" \
        --arg head "$head" \
        '.completed_steps += [$step] | .completed_steps |= unique
         | .last_successful_gate = $gate | .last_good_commit = $head' "$STATE_FILE"
}

record_failure() {
    local step_id="$1" category="$2" reproduction="$3" log_path="$4" exit_code="$5"
    local failure_id
    failure_id="H24-$(printf '%04d' "$(( $(wc -l < "$FAILURE_QUEUE") + 1 ))")"
    jq -cn \
        --arg id "$failure_id" \
        --arg first_seen "$(utc_timestamp)" \
        --arg scenario "$step_id" \
        --arg category "$category" \
        --arg symptom "command exited nonzero; inspect the recorded log" \
        --arg expected "exit code 0 with no skipped gate" \
        --arg actual "exit code $exit_code" \
        --arg reproduction "$reproduction" \
        --arg log_path "$log_path" \
        '{id: $id, severity: "P1", firstSeenAt: $first_seen,
          scenarioID: $scenario, category: $category, symptom: $symptom,
          expected: $expected, actual: $actual,
          reproductionCommand: $reproduction, reproducedCount: 1,
          researchSourceIDs: [], rootCause: null, regressionTest: null,
          fixCommit: null, status: "open", logPath: $log_path}' >> "$FAILURE_QUEUE"
    atomic_jq_write "$STATE_FILE" '.open_failures += 1' "$STATE_FILE"
}

run_step() {
    local step_id="$1" category="$2" log_name="$3"
    shift 3
    local log_path="$ARTIFACT_DIR/logs/$log_name"
    local command_display status
    printf -v command_display '%q ' "$@"
    if step_completed "$step_id"; then
        echo "[campaign] skip completed step=$step_id"
        return 0
    fi
    CURRENT_PHASE="$step_id"
    persist_state
    echo "[campaign] start step=$step_id log=$log_path"
    (
        cd "$ROOT_DIR"
        "$@"
    ) > "$log_path" 2>&1 &
    CURRENT_CHILD_PID=$!
    while kill -0 "$CURRENT_CHILD_PID" 2>/dev/null; do
        sleep "$POLL_INTERVAL_SECONDS"
        maybe_heartbeat_and_checkpoint
    done
    if wait "$CURRENT_CHILD_PID"; then status=0; else status=$?; fi
    CURRENT_CHILD_PID=""
    tail -n 40 "$log_path" || true
    jq -cn \
        --arg timestamp "$(utc_timestamp)" \
        --arg step "$step_id" \
        --arg category "$category" \
        --arg log_path "$log_path" \
        --argjson exit_code "$status" \
        '{timestamp: $timestamp, scenarioID: $step, category: $category,
          exitCode: $exit_code, passed: ($exit_code == 0), logPath: $log_path}' >> "$SCENARIO_RESULTS"
    if [[ "$status" -eq 0 ]]; then
        mark_step_completed "$step_id" "$step_id"
        echo "[campaign] pass step=$step_id"
        return 0
    fi
    record_failure "$step_id" "$category" "$command_display" "$log_path" "$status"
    echo "[campaign] fail step=$step_id exit=$status"
    return 1
}

BASELINE_FAILURES=0
run_step baseline-package-resolve dependency 00-package-resolve.log swift package resolve || BASELINE_FAILURES=$((BASELINE_FAILURES + 1))
run_step baseline-build compiler 01-baseline-build.log swift build || BASELINE_FAILURES=$((BASELINE_FAILURES + 1))
run_step baseline-test unit 02-baseline-test.log swift test || BASELINE_FAILURES=$((BASELINE_FAILURES + 1))
run_step baseline-runtime-smoke runtime 03-baseline-runtime-smoke.log ./scripts/runtime_smoke.sh --suite all || BASELINE_FAILURES=$((BASELINE_FAILURES + 1))
run_step baseline-stability stability 04-baseline-stability.log env HIREVA_FIXED_USER_HOME="$APP_HOME" ./scripts/verify_runtime_stability.sh || BASELINE_FAILURES=$((BASELINE_FAILURES + 1))
run_step baseline-tsan sanitizer 05-baseline-tsan.log swift test --sanitize=thread || BASELINE_FAILURES=$((BASELINE_FAILURES + 1))
run_step baseline-asan sanitizer 06-baseline-asan.log swift test --sanitize=address || BASELINE_FAILURES=$((BASELINE_FAILURES + 1))
run_step baseline-app-verify app 07-baseline-app-verify.log env HIREVA_FIXED_USER_HOME="$APP_HOME" ./script/build_and_run.sh --verify || BASELINE_FAILURES=$((BASELINE_FAILURES + 1))

if (( BASELINE_FAILURES > 0 )); then
    CAMPAIGN_EXIT_REASON="needs_triage"
    echo "[campaign] baseline found $BASELINE_FAILURES failing gate(s); state is ready for root-cause triage"
    exit 1
fi

FOCUSED_FILTERS=(
    QuestionCandidatePipelineTests
    RapidFollowUpSupersessionTests
    GenerationContextIsolationTests
    QuestionAnswerAlignmentTests
    DualAudioTranscriptionTests
    ReleaseSQLiteStressRegressionTests
    ReleasePrivacyIntegrationRegressionTests
    OllamaStreamingTransportRegressionTests
)

while (( $(current_active_seconds) < TARGET_ACTIVE_SECONDS )); do
    cycle="$(jq -r '.completed_cycles' "$STATE_FILE")"
    filter_index=$((cycle % ${#FOCUSED_FILTERS[@]}))
    filter="${FOCUSED_FILTERS[$filter_index]}"
    step_id="soak-cycle-$((cycle + 1))"
    if run_step "$step_id" soak "soak-cycle-$((cycle + 1)).log" swift test --filter "$filter"; then
        atomic_jq_write "$STATE_FILE" '.completed_cycles += 1' "$STATE_FILE"
    else
        CAMPAIGN_EXIT_REASON="needs_triage"
        exit 1
    fi
    completed_cycles="$(jq -r '.completed_cycles' "$STATE_FILE")"
    if (( completed_cycles % 20 == 0 )); then
        run_step "app-reopen-$completed_cycles" app "app-reopen-$completed_cycles.log" env HIREVA_FIXED_USER_HOME="$APP_HOME" ./script/build_and_run.sh --verify || {
            CAMPAIGN_EXIT_REASON="needs_triage"
            exit 1
        }
        stop_owned_runtime_processes
    fi
    if (( completed_cycles % 100 == 0 )); then
        run_step "stability-$completed_cycles" stability "stability-$completed_cycles.log" env HIREVA_FIXED_USER_HOME="$APP_HOME" ./scripts/verify_runtime_stability.sh || {
            CAMPAIGN_EXIT_REASON="needs_triage"
            exit 1
        }
    fi
done

CURRENT_PHASE="final-gates"
FINAL_FAILURES=0
run_step final-build compiler final-build.log swift build || FINAL_FAILURES=$((FINAL_FAILURES + 1))
run_step final-test-1 unit final-test-1.log swift test --enable-code-coverage || FINAL_FAILURES=$((FINAL_FAILURES + 1))
run_step final-test-2 unit final-test-2.log swift test || FINAL_FAILURES=$((FINAL_FAILURES + 1))
run_step final-test-3 unit final-test-3.log swift test || FINAL_FAILURES=$((FINAL_FAILURES + 1))
run_step final-tsan sanitizer final-tsan.log swift test --sanitize=thread || FINAL_FAILURES=$((FINAL_FAILURES + 1))
run_step final-asan sanitizer final-asan.log swift test --sanitize=address || FINAL_FAILURES=$((FINAL_FAILURES + 1))
run_step final-runtime-smoke runtime final-runtime-smoke.log ./scripts/runtime_smoke.sh --suite all || FINAL_FAILURES=$((FINAL_FAILURES + 1))
run_step final-stability stability final-stability.log env HIREVA_FIXED_USER_HOME="$APP_HOME" ./scripts/verify_runtime_stability.sh || FINAL_FAILURES=$((FINAL_FAILURES + 1))
run_step final-app-verify app final-app-verify.log env HIREVA_FIXED_USER_HOME="$APP_HOME" ./script/build_and_run.sh --verify || FINAL_FAILURES=$((FINAL_FAILURES + 1))
run_step final-db-diagnostics persistence final-db-diagnostics.log env HOME="$APP_HOME" ./scripts/db_diagnostics.sh || FINAL_FAILURES=$((FINAL_FAILURES + 1))
run_step final-release-status release final-release-status.log env \
    RELEASE_STATUS_DB_PATH="$APP_SUPPORT_DIR/hireva.sqlite" \
    RELEASE_STATUS_TRACE_PATH="$APP_SUPPORT_DIR/runtime_transcript_trace.jsonl" \
    ./scripts/release_status.sh || FINAL_FAILURES=$((FINAL_FAILURES + 1))
run_step final-signing-status signing final-signing-status.log ./scripts/signing_status.sh || FINAL_FAILURES=$((FINAL_FAILURES + 1))

CURRENT_PHASE="reporting"
python3 "$ROOT_DIR/scripts/verification/analyze_campaign_results.py" \
    --state-dir "$STATE_DIR" --artifact-dir "$ARTIFACT_DIR"
if (( FINAL_FAILURES == 0 )); then
    CAMPAIGN_EXIT_REASON="completed"
else
    CAMPAIGN_EXIT_REASON="completed_with_failures"
fi
persist_state
echo "[campaign] finished active_seconds=$(current_active_seconds) final_failures=$FINAL_FAILURES"

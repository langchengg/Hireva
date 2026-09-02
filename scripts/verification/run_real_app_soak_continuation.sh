#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT_DIR"
TARGET_ACTIVE_SECONDS=21600
FIXED_SEED=20260902
MANIFEST_PATH="$ROOT_DIR/scripts/fixtures/real_audio_campaign/manifest.json"
SCENARIO_ROOT="$ROOT_DIR/scripts/fixtures/real_audio_campaign"
DIALOGUE_RUNNER="$ROOT_DIR/scripts/run_real_dialogue_verification.sh"
RESOURCE_RUNNER="$ROOT_DIR/script/soak/run_resource_soak.sh"
ANALYZER="$ROOT_DIR/scripts/verification/analyze_real_app_soak_continuation.py"
APP_BINARY="$ROOT_DIR/dist/Hireva.app/Contents/MacOS/Hireva"
HELPER_BINARY="$ROOT_DIR/dist/Hireva.app/Contents/Helpers/parakeet_asr_helper"

MODE="new"
ARTIFACT_DIR=""
STATE_DIR=""
REQUESTED_MODEL_PATH=""
LOCK_DIR=""
LOCK_OWNED=false
COUNTING_ACTIVE=false
BASE_ACTIVE_SECONDS=0
ATTEMPT_STARTED_MONOTONIC=0
ATTEMPT_NUMBER=0
CURRENT_SCENARIO=""
CURRENT_RUNNER_PID=""
RESOURCE_PID=""
RESOURCE_EXIT_STATUS=""
CAFFEINATE_PID=""
FINAL_STATUS="interrupted"
EXIT_REASON="campaign_interrupted"
CAMPAIGN_COMPLETE=false
LAST_HEARTBEAT_MONOTONIC=0
LAST_CHECKPOINT_MONOTONIC=0

usage() {
    printf '%s\n' \
        "usage: $0 --artifact-dir <fresh-absolute-path> --state-dir <fresh-absolute-path> [--model-path <absolute-path>]" \
        "       $0 --resume --state-dir <existing-absolute-path>"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifact-dir) ARTIFACT_DIR="${2:-}"; shift 2 ;;
        --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
        --model-path) REQUESTED_MODEL_PATH="${2:-}"; shift 2 ;;
        --resume) MODE="resume"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

for required_command in git jq ruby sqlite3 shasum python3; do
    command -v "$required_command" >/dev/null 2>&1 || {
        echo "error: required command is unavailable: $required_command" >&2
        exit 2
    }
done
for required_file in "$MANIFEST_PATH" "$DIALOGUE_RUNNER" "$RESOURCE_RUNNER" "$ANALYZER"; do
    [[ -f "$required_file" && ! -L "$required_file" ]] || {
        echo "error: required campaign file is unavailable" >&2
        exit 2
    }
done

timestamp_utc() {
    /usr/bin/ruby -rtime -e 'puts Time.now.utc.iso8601(6)'
}

monotonic_seconds() {
    /usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC).floor'
}

resolve_new_directory() {
    local input="$1" parent base
    [[ "$input" == /* && ! -e "$input" && ! -L "$input" ]] || return 1
    parent="$(cd -P "$(dirname "$input")" && pwd)" || return 1
    base="$(basename "$input")"
    [[ -n "$base" && "$base" != "." && "$base" != ".." ]] || return 1
    printf '%s/%s\n' "$parent" "$base"
}

resolve_existing_directory() {
    local input="$1"
    [[ "$input" == /* && -d "$input" && ! -L "$input" ]] || return 1
    cd -P "$input" && pwd
}

repository_relative_guard() {
    local path="$1"
    case "$path/" in
        "$ROOT_DIR/"*) return 1 ;;
    esac
    return 0
}

production_support_guard() {
    local path="$1"
    case "$path/" in
        /Users/*/Library/Application\ Support/Hireva/|/Users/*/Library/Application\ Support/Hireva/*) return 1 ;;
    esac
    return 0
}

exact_process_pids() {
    local executable_path="$1" pid command
    /bin/ps -ax -o pid=,command= | while read -r pid command; do
        [[ "$command" == "$executable_path" || "$command" == "$executable_path "* ]] || continue
        printf '%s\n' "$pid"
    done
}

exact_process_count() {
    local count
    count="$(exact_process_pids "$1" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')"
    printf '%s\n' "$count"
}

stop_exact_app_bundle() {
    /usr/bin/osascript -e 'tell application id "com.langcheng.Hireva" to quit' >/dev/null 2>&1 || true
    local attempt pid
    for ((attempt=0; attempt<40; attempt++)); do
        [[ "$(exact_process_count "$APP_BINARY")" -eq 0 ]] && break
        sleep 0.25
    done
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -TERM "$pid" >/dev/null 2>&1 || true
    done < <(exact_process_pids "$APP_BINARY")
    for ((attempt=0; attempt<20; attempt++)); do
        [[ "$(exact_process_count "$APP_BINARY")" -eq 0 ]] && break
        sleep 0.25
    done
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -KILL "$pid" >/dev/null 2>&1 || true
    done < <(exact_process_pids "$APP_BINARY")
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -TERM "$pid" >/dev/null 2>&1 || true
    done < <(exact_process_pids "$HELPER_BINARY")
    for ((attempt=0; attempt<20; attempt++)); do
        [[ "$(exact_process_count "$HELPER_BINARY")" -eq 0 ]] && break
        sleep 0.25
    done
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -KILL "$pid" >/dev/null 2>&1 || true
    done < <(exact_process_pids "$HELPER_BINARY")
}

if [[ "$MODE" == "new" ]]; then
    [[ -n "$ARTIFACT_DIR" && -n "$STATE_DIR" ]] || { usage >&2; exit 2; }
    ARTIFACT_DIR="$(resolve_new_directory "$ARTIFACT_DIR")" || {
        echo "error: artifact directory must be a fresh absolute path with an existing parent" >&2
        exit 2
    }
    [[ "$STATE_DIR" == "$ARTIFACT_DIR/state" && ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]] || {
        echo "error: state directory must be the artifact directory's state child" >&2
        exit 2
    }
    repository_relative_guard "$ARTIFACT_DIR" || { echo "error: artifacts must remain outside Git" >&2; exit 2; }
    production_support_guard "$ARTIFACT_DIR" || { echo "error: production support data is forbidden" >&2; exit 2; }
    /bin/mkdir -m 700 "$ARTIFACT_DIR"
    /bin/mkdir -m 700 "$STATE_DIR"
    /bin/mkdir -m 700 "$ARTIFACT_DIR/logs" "$ARTIFACT_DIR/results" "$ARTIFACT_DIR/reports" \
        "$ARTIFACT_DIR/runs" "$ARTIFACT_DIR/app-support" "$ARTIFACT_DIR/preflight" \
        "$ARTIFACT_DIR/resources" "$ARTIFACT_DIR/patches"
    CAMPAIGN_ID="hireva-real-app-soak-$(date -u +%Y%m%dT%H%M%SZ)"
    BASE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
    BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
    STARTED_AT="$(timestamp_utc)"
    jq -n \
        --arg campaign_id "$CAMPAIGN_ID" \
        --arg start_time_utc "$STARTED_AT" \
        --arg artifact_dir "$ARTIFACT_DIR" \
        --arg state_dir "$STATE_DIR" \
        --arg repository_root "$ROOT_DIR" \
        --arg base_commit "$BASE_COMMIT" \
        --arg branch "$BRANCH" \
        --arg requested_model_path "$REQUESTED_MODEL_PATH" \
        --argjson target_active_seconds "$TARGET_ACTIVE_SECONDS" \
        --argjson fixed_seed "$FIXED_SEED" \
        '{schema_version: 1, campaign_id: $campaign_id, status: "initialized",
          start_time_utc: $start_time_utc, finished_at_utc: null,
          artifact_dir: $artifact_dir, state_dir: $state_dir, repository_root: $repository_root,
          base_commit: $base_commit, branch: $branch, last_good_commit: $base_commit,
          target_active_seconds: $target_active_seconds, active_elapsed_seconds: 0,
          fixed_seed: $fixed_seed, completed_cycles: 0, resume_count: 0,
          preflight_complete: false, requested_model_path: $requested_model_path,
          model_root: null, current_scenario: null, last_cycle_status: null,
          resource_attempts: 0, last_heartbeat: null, exit_reason: null}' \
        > "$STATE_DIR/campaign_state.json"
    : > "$STATE_DIR/checkpoints.jsonl"
    : > "$STATE_DIR/failure_queue.jsonl"
    : > "$ARTIFACT_DIR/results/cycle_results.jsonl"
    : > "$ARTIFACT_DIR/results/asr_accuracy.jsonl"
    : > "$ARTIFACT_DIR/results/answer_quality.jsonl"
    : > "$ARTIFACT_DIR/results/pipeline_latency.jsonl"
else
    [[ -n "$STATE_DIR" && -z "$ARTIFACT_DIR" && -z "$REQUESTED_MODEL_PATH" ]] || {
        echo "error: resume accepts only --state-dir" >&2
        exit 2
    }
    STATE_DIR="$(resolve_existing_directory "$STATE_DIR")" || {
        echo "error: resume state directory must exist and must not be a symlink" >&2
        exit 2
    }
    [[ -f "$STATE_DIR/campaign_state.json" && ! -L "$STATE_DIR/campaign_state.json" ]] || {
        echo "error: campaign state is unavailable" >&2
        exit 2
    }
    ARTIFACT_DIR="$(jq -er '.artifact_dir' "$STATE_DIR/campaign_state.json")"
    ARTIFACT_DIR="$(resolve_existing_directory "$ARTIFACT_DIR")" || {
        echo "error: recorded artifact directory is unavailable" >&2
        exit 2
    }
    [[ "$STATE_DIR" == "$ARTIFACT_DIR/state" ]] || { echo "error: state/artifact binding mismatch" >&2; exit 2; }
    [[ "$(jq -r '.repository_root' "$STATE_DIR/campaign_state.json")" == "$ROOT_DIR" ]] || {
        echo "error: continuation belongs to another repository" >&2
        exit 2
    }
    [[ "$(jq -r '.target_active_seconds' "$STATE_DIR/campaign_state.json")" -eq "$TARGET_ACTIVE_SECONDS" ]] || {
        echo "error: continuation target was changed" >&2
        exit 2
    }
fi

STATE_FILE="$STATE_DIR/campaign_state.json"
LOCK_DIR="$STATE_DIR/continuation.lock"
if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
    lock_pid="$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" >/dev/null 2>&1; then
        echo "error: continuation is already running as pid $lock_pid" >&2
        exit 2
    fi
    stale_lock="$STATE_DIR/continuation.lock.stale.$(date -u +%Y%m%dT%H%M%SZ)"
    /bin/mv "$LOCK_DIR" "$stale_lock"
    /bin/mkdir "$LOCK_DIR"
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"
LOCK_OWNED=true

BASE_ACTIVE_SECONDS="$(jq -r '.active_elapsed_seconds' "$STATE_FILE")"
if [[ "$MODE" == "resume" ]]; then
    resume_count="$(jq -r '.resume_count + 1' "$STATE_FILE")"
    state_temp="$(/usr/bin/mktemp "$STATE_DIR/.state.XXXXXX")"
    jq --argjson resume_count "$resume_count" '.resume_count = $resume_count' "$STATE_FILE" > "$state_temp"
    /bin/mv "$state_temp" "$STATE_FILE"
fi
ATTEMPT_NUMBER="$(jq -r '.resource_attempts + 1' "$STATE_FILE")"

current_active_seconds() {
    if [[ "$COUNTING_ACTIVE" != "true" ]]; then
        printf '%s\n' "$BASE_ACTIVE_SECONDS"
        return
    fi
    local now delta
    now="$(monotonic_seconds)"
    delta=$((now - ATTEMPT_STARTED_MONOTONIC))
    (( delta >= 0 )) || delta=0
    printf '%s\n' "$((BASE_ACTIVE_SECONDS + delta))"
}

write_state() {
    local status="$1" reason="$2" active state_temp finished_at
    active="$(current_active_seconds)"
    finished_at="null"
    [[ "$status" != "completed" ]] || finished_at="$(timestamp_utc)"
    state_temp="$(/usr/bin/mktemp "$STATE_DIR/.state.XXXXXX")"
    jq \
        --arg status "$status" \
        --arg exit_reason "$reason" \
        --arg current_scenario "$CURRENT_SCENARIO" \
        --arg last_heartbeat "$(timestamp_utc)" \
        --arg final_commit "$(git -C "$ROOT_DIR" rev-parse HEAD)" \
        --arg finished_at "$finished_at" \
        --argjson active "$active" \
        '.status = $status
         | .exit_reason = (if $exit_reason == "" then null else $exit_reason end)
         | .current_scenario = (if $current_scenario == "" then null else $current_scenario end)
         | .last_heartbeat = $last_heartbeat
         | .last_good_commit = $final_commit
         | .active_elapsed_seconds = $active
         | .finished_at_utc = (if $finished_at == "null" then null else $finished_at end)' \
        "$STATE_FILE" > "$state_temp"
    /bin/mv "$state_temp" "$STATE_FILE"
}

write_heartbeat() {
    local active heartbeat_temp
    active="$(current_active_seconds)"
    heartbeat_temp="$(/usr/bin/mktemp "$STATE_DIR/.heartbeat.XXXXXX")"
    jq -n \
        --arg timestamp "$(timestamp_utc)" \
        --arg status "$FINAL_STATUS" \
        --arg scenario "$CURRENT_SCENARIO" \
        --argjson active "$active" \
        --argjson cycles "$(jq -r '.completed_cycles' "$STATE_FILE")" \
        --argjson runner_pid "${CURRENT_RUNNER_PID:-0}" \
        --argjson resource_pid "${RESOURCE_PID:-0}" \
        '{timestamp_utc: $timestamp, status: $status, active_elapsed_seconds: $active,
          completed_cycles: $cycles, current_scenario: (if $scenario == "" then null else $scenario end),
          runner_pid: $runner_pid, resource_collector_pid: $resource_pid}' \
        > "$heartbeat_temp"
    /bin/mv "$heartbeat_temp" "$STATE_DIR/heartbeat.json"
    write_state "$FINAL_STATUS" "$EXIT_REASON"
    LAST_HEARTBEAT_MONOTONIC="$(monotonic_seconds)"
}

write_checkpoint() {
    jq -cn \
        --arg timestamp "$(timestamp_utc)" \
        --arg status "$FINAL_STATUS" \
        --arg scenario "$CURRENT_SCENARIO" \
        --arg commit "$(git -C "$ROOT_DIR" rev-parse HEAD)" \
        --argjson active "$(current_active_seconds)" \
        --argjson cycles "$(jq -r '.completed_cycles' "$STATE_FILE")" \
        '{timestamp_utc: $timestamp, status: $status, active_elapsed_seconds: $active,
          completed_cycles: $cycles, current_scenario: (if $scenario == "" then null else $scenario end),
          commit: $commit}' >> "$STATE_DIR/checkpoints.jsonl"
    LAST_CHECKPOINT_MONOTONIC="$(monotonic_seconds)"
}

save_patch() {
    local patch_path
    patch_path="$ARTIFACT_DIR/patches/exit-$(date -u +%Y%m%dT%H%M%SZ).patch"
    git -C "$ROOT_DIR" diff --binary > "$patch_path" || true
    git -C "$ROOT_DIR" status --short > "$ARTIFACT_DIR/patches/last-status.txt" || true
}

record_failure() {
    local scenario="$1" category="$2" symptom="$3" command="$4"
    local current_max failure_number failure_id
    current_max="$(jq -r '.id // empty' "$STATE_DIR/failure_queue.jsonl" 2>/dev/null \
        | /usr/bin/sed -n 's/^H24C-\([0-9][0-9]*\)$/\1/p' \
        | /usr/bin/sort -n \
        | /usr/bin/tail -n 1)"
    failure_number=$(( 10#${current_max:-0} + 1 ))
    failure_id="H24C-$(printf '%04d' "$failure_number")"
    jq -cn \
        --arg id "$failure_id" \
        --arg firstSeenAt "$(timestamp_utc)" \
        --arg scenarioID "$scenario" \
        --arg category "$category" \
        --arg symptom "$symptom" \
        --arg reproductionCommand "$command" \
        '{id: $id, severity: "P1", firstSeenAt: $firstSeenAt, scenarioID: $scenarioID,
          category: $category, symptom: $symptom,
          expected: "The real app cycle and its privacy-safe evidence gates complete successfully.",
          actual: $symptom, reproductionCommand: $reproductionCommand,
          reproducedCount: 1, researchSourceIDs: [], rootCause: null,
          regressionTest: null, fixCommit: null, status: "open"}' \
        >> "$STATE_DIR/failure_queue.jsonl"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n "$CURRENT_RUNNER_PID" ]] && kill -0 "$CURRENT_RUNNER_PID" >/dev/null 2>&1; then
        kill -TERM "$CURRENT_RUNNER_PID" >/dev/null 2>&1 || true
        wait "$CURRENT_RUNNER_PID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$RESOURCE_PID" ]] && kill -0 "$RESOURCE_PID" >/dev/null 2>&1; then
        kill -TERM "$RESOURCE_PID" >/dev/null 2>&1 || true
        wait "$RESOURCE_PID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$CAFFEINATE_PID" ]] && kill -0 "$CAFFEINATE_PID" >/dev/null 2>&1; then
        kill -TERM "$CAFFEINATE_PID" >/dev/null 2>&1 || true
        wait "$CAFFEINATE_PID" >/dev/null 2>&1 || true
    fi
    stop_exact_app_bundle
    if [[ "$COUNTING_ACTIVE" == "true" ]]; then
        BASE_ACTIVE_SECONDS="$(current_active_seconds)"
        COUNTING_ACTIVE=false
    fi
    if [[ "$CAMPAIGN_COMPLETE" == "true" ]]; then
        FINAL_STATUS="completed"
        EXIT_REASON="target_active_duration_reached"
    elif [[ "$status" -eq 0 ]]; then
        status=1
    fi
    write_state "$FINAL_STATUS" "$EXIT_REASON" || true
    write_heartbeat || true
    write_checkpoint || true
    save_patch
    if [[ "$LOCK_OWNED" == "true" && -d "$LOCK_DIR" ]]; then
        /bin/rm -f "$LOCK_DIR/pid"
        /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    if [[ "$CAMPAIGN_COMPLETE" == "true" ]]; then
        exit 0
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'FINAL_STATUS="interrupted"; EXIT_REASON="signal_int"; exit 130' INT
trap 'FINAL_STATUS="interrupted"; EXIT_REASON="signal_term"; exit 143' TERM

# The real ScreenCaptureKit lane requires an awake display. Keep a bounded
# assertion owned by this foreground supervisor and generate one user-activity
# pulse so a display that was already asleep can become capture-capable. This
# starts only after cleanup traps are armed, so early failures cannot leak it.
/usr/bin/caffeinate -dims -w "$$" >/dev/null 2>&1 &
CAFFEINATE_PID=$!
/usr/bin/caffeinate -u -t 5 >/dev/null 2>&1 &
wake_pid=$!
wait "$wake_pid"

run_preflight() {
    local preflight_number preflight_root prep_args helper_path audio_path provenance_path harness_path
    preflight_number="$(printf '%03d' "$(( $(jq -r '.resume_count' "$STATE_FILE") + 1 ))")"
    preflight_root="$ARTIFACT_DIR/preflight/attempt-$preflight_number"
    /bin/mkdir -m 700 "$preflight_root" "$preflight_root/build-home" "$preflight_root/app-support"
    FINAL_STATUS="preflight"
    EXIT_REASON="preflight_running"
    write_heartbeat

    HIREVA_FIXED_USER_HOME="$preflight_root/build-home" \
        "$ROOT_DIR/script/build_and_run.sh" --verify \
        > "$ARTIFACT_DIR/logs/preflight-build-app-$preflight_number.log" 2>&1
    stop_exact_app_bundle
    [[ "$(exact_process_count "$APP_BINARY")" -eq 0 ]] || {
        echo "error: preflight app process did not stop" >&2
        return 1
    }

    prep_args=(--artifact-dir "$ARTIFACT_DIR" --state-dir "$STATE_DIR")
    if [[ -n "$REQUESTED_MODEL_PATH" ]]; then
        prep_args+=(--model-path "$REQUESTED_MODEL_PATH")
    fi
    "$ROOT_DIR/scripts/verification/prepare_local_integration.sh" "${prep_args[@]}" \
        > "$ARTIFACT_DIR/logs/preflight-local-integration-$preflight_number.log" 2>&1
    MODEL_ROOT="$(jq -er '.model_path' "$STATE_DIR/local_integration_environment.json")"
    helper_path="$(jq -er '.helper_path' "$STATE_DIR/local_integration_environment.json")"
    audio_path="$(jq -er '.audio_path' "$STATE_DIR/local_integration_environment.json")"
    provenance_path="$(jq -er '.provenance_path' "$STATE_DIR/local_integration_environment.json")"
    [[ -d "$MODEL_ROOT" && ! -L "$MODEL_ROOT" && -x "$helper_path" && -f "$audio_path" && -f "$provenance_path" ]] || {
        echo "error: prepared local integration contract is incomplete" >&2
        return 1
    }

    HIREVA_ANSWER_QUALITY_JSONL="$preflight_root/answer_quality.jsonl" \
        swift test --filter InterviewCampaignFixtureTests.answersRemainEvidenceBoundAndIdentitySafe \
        > "$ARTIFACT_DIR/logs/preflight-answer-quality-$preflight_number.log" 2>&1
    [[ "$(wc -l < "$preflight_root/answer_quality.jsonl" | tr -d ' ')" -eq 800 ]] || return 1

    harness_path="$preflight_root/harness_metrics.jsonl"
    HIREVA_HARNESS_METRICS_JSONL="$harness_path" \
        swift test --filter RuntimeSmokeHarnessTests.release64QuestionGate \
        > "$ARTIFACT_DIR/logs/preflight-harness-$preflight_number.log" 2>&1
    [[ -s "$harness_path" ]] || return 1

    HIREVA_REAL_OLLAMA_SMOKE=1 \
    HIREVA_PROVIDER_ONLY_ITERATIONS=5 \
    HIREVA_PROVIDER_ONLY_METRICS_JSONL="$preflight_root/provider_only_metrics.jsonl" \
        swift test --filter LocalModelsSetupTests.realOllamaQwenProviderSmokeWhenExplicitlyEnabled \
        > "$ARTIFACT_DIR/logs/preflight-provider-$preflight_number.log" 2>&1

    HIREVA_REAL_PARAKEET_STREAM_TEST=1 \
    HIREVA_PARAKEET_HELPER_PATH="$helper_path" \
    HIREVA_PARAKEET_MODEL_PATH="$MODEL_ROOT" \
    HIREVA_PARAKEET_TEST_AUDIO="$audio_path" \
    HIREVA_PARAKEET_TEST_AUDIO_PROVENANCE="$provenance_path" \
    HIREVA_DIRECT_ASR_METRICS_JSONL="$preflight_root/direct_asr_metrics.jsonl" \
        swift test --filter ParakeetNativeRuntimeTests.realRuntimePreservesMultipleUtterancesInOneStream \
        > "$ARTIFACT_DIR/logs/preflight-direct-asr-$preflight_number.log" 2>&1

    scenario="$(jq -er '.scenarios[0].filename' "$MANIFEST_PATH")"
    "$DIALOGUE_RUNNER" "$SCENARIO_ROOT/$scenario" \
        "$preflight_root/real-dialogue" "$preflight_root/app-support/real-dialogue" "$MODEL_ROOT" \
        > "$ARTIFACT_DIR/logs/preflight-real-dialogue-$preflight_number.log" 2>&1

    state_temp="$(/usr/bin/mktemp "$STATE_DIR/.state.XXXXXX")"
    jq --arg model_root "$MODEL_ROOT" --arg preflight_attempt "attempt-$preflight_number" \
        '.preflight_complete = true | .model_root = $model_root
         | .preflight_attempt = $preflight_attempt | .status = "ready_for_soak"' \
        "$STATE_FILE" > "$state_temp"
    /bin/mv "$state_temp" "$STATE_FILE"
    write_checkpoint
}

if [[ "$(jq -r '.preflight_complete' "$STATE_FILE")" != "true" ]]; then
    set +e
    (
        set -euo pipefail
        run_preflight
    )
    preflight_status=$?
    set -e
    if [[ "$preflight_status" -ne 0 ]]; then
        record_failure \
            "real-app-continuation-preflight" \
            "preflight" \
            "Continuation preflight exited nonzero before the active soak timer started." \
            "$ROOT_DIR/scripts/verification/resume_real_app_soak_continuation.sh --state-dir $STATE_DIR"
        FINAL_STATUS="failed"
        EXIT_REASON="preflight_failed"
        exit "$preflight_status"
    fi
fi

MODEL_ROOT="$(jq -er '.model_root' "$STATE_FILE")"
[[ -d "$MODEL_ROOT" && ! -L "$MODEL_ROOT" ]] || { echo "error: recorded model root is unavailable" >&2; exit 2; }
[[ -x "$APP_BINARY" && -x "$HELPER_BINARY" ]] || { echo "error: verified app bundle is unavailable" >&2; exit 2; }
"$DIALOGUE_RUNNER" --validate-runtime-compatibility >/dev/null
"$ROOT_DIR/scripts/run_real_audio_campaign.sh" --validate-plan >/dev/null

BASE_ACTIVE_SECONDS="$(jq -r '.active_elapsed_seconds' "$STATE_FILE")"
if (( BASE_ACTIVE_SECONDS >= TARGET_ACTIVE_SECONDS )); then
    CAMPAIGN_COMPLETE=true
    FINAL_STATUS="completed"
    EXIT_REASON="target_already_recorded_no_time_added"
    echo "target active duration is already recorded; no additional time was added"
    exit 0
fi
ATTEMPT_STARTED_MONOTONIC="$(monotonic_seconds)"
COUNTING_ACTIVE=true
FINAL_STATUS="running"
EXIT_REASON="soak_running"
LAST_HEARTBEAT_MONOTONIC="$ATTEMPT_STARTED_MONOTONIC"
LAST_CHECKPOINT_MONOTONIC="$ATTEMPT_STARTED_MONOTONIC"

state_temp="$(/usr/bin/mktemp "$STATE_DIR/.state.XXXXXX")"
jq --argjson attempts "$ATTEMPT_NUMBER" '.resource_attempts = $attempts | .status = "running"' \
    "$STATE_FILE" > "$state_temp"
/bin/mv "$state_temp" "$STATE_FILE"

remaining_seconds=$((TARGET_ACTIVE_SECONDS - BASE_ACTIVE_SECONDS))
resource_csv="$ARTIFACT_DIR/resources/resource_metrics_attempt_$(printf '%03d' "$ATTEMPT_NUMBER").csv"
resource_log="$ARTIFACT_DIR/logs/resource_metrics_attempt_$(printf '%03d' "$ATTEMPT_NUMBER").log"
"$RESOURCE_RUNNER" \
    --output "$resource_csv" \
    --process-name Hireva \
    --process-path "$APP_BINARY" \
    --helper-path "$HELPER_BINARY" \
    --interval 5 \
    --duration "$remaining_seconds" \
    --max-bytes 10485760 \
    --max-files 4 \
    --minimum-coverage 0.90 \
    --max-collection-errors 20 \
    --missing-app-limit 24 \
    > "$resource_log" 2>&1 &
RESOURCE_PID=$!
write_heartbeat
write_checkpoint

collect_cycle_database_metrics() {
    local database_path="$1"
    sqlite3 -readonly -noheader -separator '|' "$database_path" '
        SELECT "session_count", COUNT(*) FROM interview_sessions;
        SELECT "transcript_count", COUNT(*) FROM transcript_segments;
        SELECT "question_count", COUNT(*) FROM detected_questions WHERE should_trigger = 1;
        SELECT "suggestion_count", COUNT(*) FROM suggestion_cards;
        SELECT "distinct_question_count", COUNT(DISTINCT detected_question_id) FROM suggestion_cards;
        SELECT "distinct_generation_count", COUNT(DISTINCT generation_id) FROM suggestion_cards;
        SELECT "identity_null_count", COUNT(*) FROM suggestion_cards
          WHERE session_id IS NULL OR detected_question_id IS NULL OR generation_id IS NULL OR context_snapshot_id IS NULL;
        SELECT "duplicate_identity_count", COUNT(*) FROM (
          SELECT session_id, detected_question_id, generation_id, context_snapshot_id, COUNT(*) AS duplicate_count
          FROM suggestion_cards
          GROUP BY session_id, detected_question_id, generation_id, context_snapshot_id
          HAVING duplicate_count > 1
        );
    '
}

while (( $(current_active_seconds) < TARGET_ACTIVE_SECONDS )); do
    completed_cycles="$(jq -r '.completed_cycles' "$STATE_FILE")"
    scenario_count="$(jq -r '.scenarios | length' "$MANIFEST_PATH")"
    scenario_index=$(( (completed_cycles * 5 + FIXED_SEED) % scenario_count ))
    scenario_filename="$(jq -er ".scenarios[$scenario_index].filename" "$MANIFEST_PATH")"
    role_family="$(jq -er ".scenarios[$scenario_index].roleFamilyID" "$MANIFEST_PATH")"
    cycle_number=$((completed_cycles + 1))
    cycle_label="cycle-$(printf '%06d' "$cycle_number")-$role_family"
    run_output="$ARTIFACT_DIR/runs/$cycle_label"
    run_support="$ARTIFACT_DIR/app-support/$cycle_label"
    run_log="$ARTIFACT_DIR/logs/$cycle_label.log"
    CURRENT_SCENARIO="$scenario_filename"
    write_heartbeat

    cycle_started_monotonic="$(monotonic_seconds)"
    "$DIALOGUE_RUNNER" "$SCENARIO_ROOT/$scenario_filename" "$run_output" "$run_support" "$MODEL_ROOT" \
        > "$run_log" 2>&1 &
    CURRENT_RUNNER_PID=$!
    runner_status=""
    while kill -0 "$CURRENT_RUNNER_PID" >/dev/null 2>&1; do
        now="$(monotonic_seconds)"
        if (( now - LAST_HEARTBEAT_MONOTONIC >= 300 )); then write_heartbeat; fi
        if (( now - LAST_CHECKPOINT_MONOTONIC >= 1800 )); then write_checkpoint; fi
        if ! kill -0 "$RESOURCE_PID" >/dev/null 2>&1; then
            set +e
            wait "$RESOURCE_PID"
            RESOURCE_EXIT_STATUS=$?
            set -e
            RESOURCE_PID=""
            if (( $(current_active_seconds) < TARGET_ACTIVE_SECONDS )); then
                kill -TERM "$CURRENT_RUNNER_PID" >/dev/null 2>&1 || true
                wait "$CURRENT_RUNNER_PID" >/dev/null 2>&1 || true
                CURRENT_RUNNER_PID=""
                record_failure "$scenario_filename" resource_sampling "Resource collector stopped before the active-duration target." "$RESOURCE_RUNNER --output $resource_csv"
                FINAL_STATUS="failed"
                EXIT_REASON="resource_collector_failed"
                exit 1
            fi
        fi
        sleep 5
    done
    set +e
    wait "$CURRENT_RUNNER_PID"
    runner_status=$?
    set -e
    CURRENT_RUNNER_PID=""
    if [[ "$runner_status" -ne 0 ]]; then
        record_failure "$scenario_filename" real_app_dialogue "Real app dialogue cycle exited nonzero." "$DIALOGUE_RUNNER $SCENARIO_ROOT/$scenario_filename <fresh-output> <fresh-support> $MODEL_ROOT"
        FINAL_STATUS="failed"
        EXIT_REASON="real_app_cycle_failed"
        exit 1
    fi

    events_path="$run_output/app_verification_events.jsonl"
    database_path="$run_support/hireva.sqlite"
    [[ -f "$events_path" && -f "$database_path" && ! -L "$database_path" ]] || {
        record_failure "$scenario_filename" evidence "Cycle evidence or isolated SQLite database is missing." "$DIALOGUE_RUNNER $SCENARIO_ROOT/$scenario_filename <fresh-output> <fresh-support> $MODEL_ROOT"
        FINAL_STATUS="failed"
        EXIT_REASON="cycle_evidence_missing"
        exit 1
    }
    db_quick_check="$(sqlite3 -readonly "$database_path" 'PRAGMA quick_check;')"
    [[ "$db_quick_check" == "ok" ]] || {
        record_failure "$scenario_filename" persistence "SQLite quick_check did not return ok." "sqlite3 -readonly <isolated-db> 'PRAGMA quick_check;'"
        FINAL_STATUS="failed"
        EXIT_REASON="sqlite_quick_check_failed"
        exit 1
    }
    db_metrics="$(collect_cycle_database_metrics "$database_path")"
    metric() { printf '%s\n' "$db_metrics" | /usr/bin/awk -F '|' -v key="$1" '$1 == key { print $2 }'; }
    suggestion_count="$(metric suggestion_count)"
    distinct_question_count="$(metric distinct_question_count)"
    distinct_generation_count="$(metric distinct_generation_count)"
    identity_null_count="$(metric identity_null_count)"
    duplicate_identity_count="$(metric duplicate_identity_count)"
    [[ "$suggestion_count" -eq "$distinct_question_count" &&
       "$suggestion_count" -eq "$distinct_generation_count" &&
       "$identity_null_count" -eq 0 && "$duplicate_identity_count" -eq 0 ]] || {
        record_failure "$scenario_filename" persistence "Cycle SQLite identity or exactly-once tie-out failed." "sqlite3 -readonly <isolated-db> <count-only-tie-out>"
        FINAL_STATUS="failed"
        EXIT_REASON="sqlite_identity_tie_out_failed"
        exit 1
    }

    jq -c --argjson cycle "$cycle_number" --arg roleFamily "$role_family" --arg scenario "$scenario_filename" \
        'select(.event == "asr.accuracy") + {cycle: $cycle, roleFamily: $roleFamily, scenario: $scenario}' \
        "$events_path" >> "$ARTIFACT_DIR/results/asr_accuracy.jsonl"
    jq -c --argjson cycle "$cycle_number" --arg roleFamily "$role_family" --arg scenario "$scenario_filename" \
        'select(.event == "answer.quality") + {cycle: $cycle, roleFamily: $roleFamily, scenario: $scenario}' \
        "$events_path" >> "$ARTIFACT_DIR/results/answer_quality.jsonl"
    jq -c --argjson cycle "$cycle_number" --arg roleFamily "$role_family" --arg scenario "$scenario_filename" \
        'select(.event == "pipeline.latency") + {cycle: $cycle, roleFamily: $roleFamily, scenario: $scenario}' \
        "$events_path" >> "$ARTIFACT_DIR/results/pipeline_latency.jsonl"

    trace_bytes="$(find "$run_support" -type f -name '*trace*.jsonl' -exec /usr/bin/stat -f '%z' {} \; | /usr/bin/awk '{ total += $1 } END { print total + 0 }')"
    db_bytes="$(/usr/bin/stat -f '%z' "$database_path")"
    wal_bytes=0
    [[ ! -f "$database_path-wal" ]] || wal_bytes="$(/usr/bin/stat -f '%z' "$database_path-wal")"
    artifact_disk_bytes="$(( $(/usr/bin/du -sk "$ARTIFACT_DIR" | /usr/bin/awk '{print $1}') * 1024 ))"
    cycle_duration=$(( $(monotonic_seconds) - cycle_started_monotonic ))
    app_count="$(exact_process_count "$APP_BINARY")"
    helper_count="$(exact_process_count "$HELPER_BINARY")"
    jq -cn \
        --arg timestamp "$(timestamp_utc)" \
        --argjson cycle "$cycle_number" \
        --arg scenario "$scenario_filename" \
        --arg roleFamily "$role_family" \
        --arg failureInjection "rapid_generation_supersession" \
        --argjson duration "$cycle_duration" \
        --argjson active "$(current_active_seconds)" \
        --argjson sessions "$(metric session_count)" \
        --argjson transcripts "$(metric transcript_count)" \
        --argjson questions "$(metric question_count)" \
        --argjson suggestions "$suggestion_count" \
        --argjson distinctQuestions "$distinct_question_count" \
        --argjson distinctGenerations "$distinct_generation_count" \
        --argjson identityNulls "$identity_null_count" \
        --argjson duplicates "$duplicate_identity_count" \
        --argjson dbBytes "$db_bytes" \
        --argjson walBytes "$wal_bytes" \
        --argjson traceBytes "$trace_bytes" \
        --argjson artifactDiskBytes "$artifact_disk_bytes" \
        --argjson appCount "$app_count" \
        --argjson helperCount "$helper_count" \
        '{timestamp_utc: $timestamp, cycle: $cycle, scenario: $scenario, roleFamily: $roleFamily,
          status: "passed", failureInjection: $failureInjection,
          duration_seconds: $duration, active_elapsed_seconds: $active,
          session_count: $sessions, transcript_count: $transcripts,
          question_count: $questions, suggestion_count: $suggestions,
          distinct_question_count: $distinctQuestions, distinct_generation_count: $distinctGenerations,
          identity_null_count: $identityNulls, duplicate_identity_count: $duplicates,
          db_bytes: $dbBytes, wal_bytes: $walBytes, trace_bytes: $traceBytes,
          artifact_disk_bytes: $artifactDiskBytes, app_count_after_cleanup: $appCount,
          helper_count_after_cleanup: $helperCount}' \
        >> "$ARTIFACT_DIR/results/cycle_results.jsonl"
    [[ "$app_count" -eq 0 && "$helper_count" -eq 0 ]] || {
        record_failure "$scenario_filename" process_cleanup "Cycle left a residual exact-path app or helper process." "ps -ax -o pid=,command="
        FINAL_STATUS="failed"
        EXIT_REASON="process_cleanup_failed"
        exit 1
    }

    state_temp="$(/usr/bin/mktemp "$STATE_DIR/.state.XXXXXX")"
    jq --argjson completed "$cycle_number" --arg scenario "$scenario_filename" \
        '.completed_cycles = $completed | .last_cycle_status = "passed" | .current_scenario = $scenario' \
        "$STATE_FILE" > "$state_temp"
    /bin/mv "$state_temp" "$STATE_FILE"
    write_heartbeat
    if (( $(monotonic_seconds) - LAST_CHECKPOINT_MONOTONIC >= 1800 )); then write_checkpoint; fi
done

if [[ -n "$RESOURCE_PID" ]]; then
    set +e
    wait "$RESOURCE_PID"
    RESOURCE_EXIT_STATUS=$?
    set -e
    RESOURCE_PID=""
fi
[[ "${RESOURCE_EXIT_STATUS:-0}" -eq 0 ]] || {
    record_failure "$CURRENT_SCENARIO" resource_sampling "Resource collector failed its coverage gate." "$RESOURCE_RUNNER --output $resource_csv"
    FINAL_STATUS="failed"
    EXIT_REASON="resource_coverage_failed"
    exit 1
}

BASE_ACTIVE_SECONDS="$(current_active_seconds)"
COUNTING_ACTIVE=false
(( BASE_ACTIVE_SECONDS >= TARGET_ACTIVE_SECONDS )) || {
    FINAL_STATUS="interrupted"
    EXIT_REASON="active_duration_not_reached"
    exit 1
}
FINAL_STATUS="analyzing"
EXIT_REASON="target_reached_analysis_running"
write_state "$FINAL_STATUS" "$EXIT_REASON"
if ! python3 "$ANALYZER" --state-dir "$STATE_DIR" --artifact-dir "$ARTIFACT_DIR" \
    > "$ARTIFACT_DIR/logs/final-analysis.log" 2>&1; then
    FINAL_STATUS="failed"
    EXIT_REASON="final_analysis_failed"
    exit 1
fi
FINAL_STATUS="completed"
EXIT_REASON="target_active_duration_reached"
write_state "$FINAL_STATUS" "$EXIT_REASON"
if ! python3 "$ANALYZER" --state-dir "$STATE_DIR" --artifact-dir "$ARTIFACT_DIR" \
    >> "$ARTIFACT_DIR/logs/final-analysis.log" 2>&1; then
    FINAL_STATUS="failed"
    EXIT_REASON="final_report_refresh_failed"
    exit 1
fi
CAMPAIGN_COMPLETE=true
printf 'REAL_APP_SOAK_CONTINUATION=completed active_seconds=%s cycles=%s artifact_dir=%s\n' \
    "$BASE_ACTIVE_SECONDS" "$(jq -r '.completed_cycles' "$STATE_FILE")" "$ARTIFACT_DIR"

#!/usr/bin/env bash
set -euo pipefail

VALIDATE_ONLY=false
EVIDENCE_ONLY=false
RUNTIME_COMPATIBILITY_ONLY=false
EVIDENCE_PATH=""
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATED_SCENARIO_DIRECTORY=""
APP_LAUNCHED=false
OWNED_APP_PID=""
OWNED_HELPER_PIDS=()
NOTIFY_BINARY=""
RUN_REQUIRES_COMPLETION=false
VERIFICATION_COMPLETED=false

resolve_existing_file() {
    local input="$1" parent base
    [[ -f "$input" && ! -L "$input" ]] || return 1
    parent="$(cd -P "$(dirname "$input")" && pwd)"
    base="$(basename "$input")"
    printf '%s/%s\n' "$parent" "$base"
}

resolve_new_directory() {
    local input="$1" parent base
    [[ ! -e "$input" && ! -L "$input" ]] || return 1
    base="$(basename "$input")"
    [[ -n "$base" && "$base" != "." && "$base" != ".." && "$base" != "/" ]] || return 1
    parent="$(cd -P "$(dirname "$input")" && pwd)" || return 1
    printf '%s/%s\n' "$parent" "$base"
}

if [[ $# -eq 1 && "$1" == "--validate-runtime-compatibility" ]]; then
    RUNTIME_COMPATIBILITY_ONLY=true
elif [[ $# -eq 2 && "$1" == "--validate-scenario" ]]; then
    SCENARIO_PATH="$(resolve_existing_file "$2")" || { echo "scenario fixture must be a regular non-symlink file" >&2; exit 2; }
    VALIDATE_ONLY=true
elif [[ $# -eq 3 && "$1" == "--validate-evidence" ]]; then
    SCENARIO_PATH="$(resolve_existing_file "$2")" || { echo "scenario fixture must be a regular non-symlink file" >&2; exit 2; }
    EVIDENCE_PATH="$(resolve_existing_file "$3")" || { echo "evidence must be a regular non-symlink file" >&2; exit 2; }
    EVIDENCE_ONLY=true
elif [[ $# -eq 4 ]]; then
    SCENARIO_PATH="$(resolve_existing_file "$1")" || { echo "scenario fixture must be a regular non-symlink file" >&2; exit 2; }
    OUTPUT_ROOT="$(resolve_new_directory "$2")" || { echo "verification output must be a fresh non-symlink directory path with an existing parent" >&2; exit 2; }
    APP_SUPPORT_ROOT="$(resolve_new_directory "$3")" || { echo "verification app support must be a fresh non-symlink directory path with an existing parent" >&2; exit 2; }
    [[ -d "$4" && ! -L "$4" ]] || { echo "local model root must be an existing non-symlink directory" >&2; exit 2; }
    MODEL_ROOT="$(cd -P "$4" && pwd)"
    RUN_REQUIRES_COMPLETION=true
else
    echo "usage: $0 <scenario.json> <output-root> <app-support-root> <local-models-root>" >&2
    echo "       $0 --validate-scenario <scenario.json>" >&2
    echo "       $0 --validate-evidence <scenario.json> <events.jsonl>" >&2
    echo "       $0 --validate-runtime-compatibility" >&2
    exit 2
fi

APP_BUNDLE="$ROOT_DIR/dist/Hireva.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Hireva"

wait_for_pid_exit() {
    local pid="$1" attempts="$2"
    local attempt
    for ((attempt=0; attempt<attempts; attempt++)); do
        kill -0 "$pid" >/dev/null 2>&1 || return 0
        sleep 0.25
    done
    return 1
}

process_command() {
    /bin/ps -p "$1" -o command= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

process_matches_app() {
    local command
    command="$(process_command "$1")"
    [[ "$command" == "$APP_BINARY" || "$command" == "$APP_BINARY "* ]]
}

process_matches_bundled_helper() {
    local command
    command="$(process_command "$1")"
    [[ "$command" == "$APP_BUNDLE/Contents/Helpers/parakeet_asr_helper" ||
       "$command" == "$APP_BUNDLE/Contents/Helpers/parakeet_asr_helper "* ]]
}

capture_owned_helper_pids() {
    [[ -n "$OWNED_APP_PID" ]] || return 0
    local pid
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        process_matches_bundled_helper "$pid" || continue
        remember_owned_helper_pid "$pid"
    done < <(pgrep -P "$OWNED_APP_PID" 2>/dev/null || true)
}

remember_owned_helper_pid() {
    local pid="$1" existing_pid
    if (( ${#OWNED_HELPER_PIDS[@]} > 0 )); then
        for existing_pid in "${OWNED_HELPER_PIDS[@]}"; do
            [[ "$existing_pid" == "$pid" ]] && return 0
        done
    fi
    OWNED_HELPER_PIDS+=("$pid")
}

completion_checked_status() {
    local status="$1"
    if [[ "$RUN_REQUIRES_COMPLETION" == "true" &&
          "$VERIFICATION_COMPLETED" != "true" &&
          "$status" -eq 0 ]]; then
        status=1
    fi
    printf '%s\n' "$status"
}

terminate_owned_process() {
    local pid="$1" kind="$2"
    kill -0 "$pid" >/dev/null 2>&1 || return 0
    if [[ "$kind" == "app" ]]; then
        process_matches_app "$pid" || return 0
    else
        process_matches_bundled_helper "$pid" || return 0
    fi
    kill -TERM "$pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$pid" 20 && return 0
    if [[ "$kind" == "app" ]]; then
        process_matches_app "$pid" || return 0
    else
        process_matches_bundled_helper "$pid" || return 0
    fi
    kill -KILL "$pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$pid" 8 || true
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    set +u
    status="$(completion_checked_status "$status")"
    if [[ "$APP_LAUNCHED" == "true" ]]; then
        capture_owned_helper_pids
        if [[ -n "$NOTIFY_BINARY" && -x "$NOTIFY_BINARY" ]]; then
            "$NOTIFY_BINARY" stop >/dev/null 2>&1 &
            local notify_pid=$!
            wait_for_pid_exit "$notify_pid" 12 || kill -TERM "$notify_pid" >/dev/null 2>&1
            wait "$notify_pid" >/dev/null 2>&1 || true
        fi
        /usr/bin/osascript -e 'tell application id "com.langcheng.Hireva" to quit' >/dev/null 2>&1 &
        local quit_pid=$!
        wait_for_pid_exit "$quit_pid" 20 || kill -TERM "$quit_pid" >/dev/null 2>&1
        wait "$quit_pid" >/dev/null 2>&1 || true
        [[ -z "$OWNED_APP_PID" ]] || wait_for_pid_exit "$OWNED_APP_PID" 40 || true
        [[ -z "$OWNED_APP_PID" ]] || terminate_owned_process "$OWNED_APP_PID" app
        local helper_pid
        for helper_pid in "${OWNED_HELPER_PIDS[@]}"; do
            terminate_owned_process "$helper_pid" helper
        done
    fi
    if [[ -n "$VALIDATED_SCENARIO_DIRECTORY" &&
          "$VALIDATED_SCENARIO_DIRECTORY" == /tmp/hireva-validated-scenario.* &&
          -d "$VALIDATED_SCENARIO_DIRECTORY" ]]; then
        /bin/rm -rf -- "$VALIDATED_SCENARIO_DIRECTORY"
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$RUNTIME_COMPATIBILITY_ONLY" == "true" ]]; then
    remember_owned_helper_pid 101
    remember_owned_helper_pid 101
    remember_owned_helper_pid 202
    [[ "${#OWNED_HELPER_PIDS[@]}" -eq 2 ]] || {
        echo "runtime compatibility helper tracking failed" >&2
        exit 1
    }
    RUN_REQUIRES_COMPLETION=true
    VERIFICATION_COMPLETED=false
    incomplete_status="$(completion_checked_status 0)"
    [[ "$incomplete_status" -eq 1 ]] || {
        echo "runtime compatibility completion status failed" >&2
        exit 1
    }
    RUN_REQUIRES_COMPLETION=false
    OWNED_HELPER_PIDS=()
    echo "runtime_compatibility_valid empty_helper_tracking=true incomplete_real_run_status=$incomplete_status"
    exit 0
fi

if [[ "$VALIDATE_ONLY" == "false" && "$EVIDENCE_ONLY" == "false" ]]; then
    case "$OUTPUT_ROOT/" in "$ROOT_DIR/"*) echo "verification output must remain outside the source repository" >&2; exit 2;; esac
    case "$APP_SUPPORT_ROOT/" in "$ROOT_DIR/"*) echo "verification app support must remain outside the source repository" >&2; exit 2;; esac
    case "$OUTPUT_ROOT/" in "$APP_SUPPORT_ROOT/"*) echo "verification output and app support must not contain one another" >&2; exit 2;; esac
    case "$APP_SUPPORT_ROOT/" in "$OUTPUT_ROOT/"*) echo "verification output and app support must not contain one another" >&2; exit 2;; esac
    PRODUCTION_SUPPORT_ROOT="$HOME/Library/Application Support/Hireva"
    [[ "$APP_SUPPORT_ROOT" != "$PRODUCTION_SUPPORT_ROOT" ]] || { echo "verification app support must not use the production support directory" >&2; exit 2; }

    APPROVED_SCENARIO_RELATIVE="scripts/fixtures/release_verification_scenario_v1.json"
    APPROVED_SCENARIO="$ROOT_DIR/$APPROVED_SCENARIO_RELATIVE"
    [[ -f "$APPROVED_SCENARIO" && ! -L "$APPROVED_SCENARIO" ]] || {
        echo "the approved release verification scenario is unavailable" >&2
        exit 2
    }
    git -C "$ROOT_DIR" ls-files --error-unmatch "$APPROVED_SCENARIO_RELATIVE" >/dev/null 2>&1 || {
        echo "the approved release verification scenario must be tracked" >&2
        exit 2
    }
    git -C "$ROOT_DIR" diff --quiet -- "$APPROVED_SCENARIO_RELATIVE" || {
        echo "the approved release verification scenario has uncommitted changes" >&2
        exit 2
    }
    git -C "$ROOT_DIR" diff --cached --quiet -- "$APPROVED_SCENARIO_RELATIVE" || {
        echo "the approved release verification scenario has staged but uncommitted changes" >&2
        exit 2
    }
    /usr/bin/cmp -s "$SCENARIO_PATH" "$APPROVED_SCENARIO" || {
    echo "real release verification accepts only the approved release verification scenario" >&2
        exit 2
    }
fi

[[ -f "$SCENARIO_PATH" ]] || { echo "scenario not found: $SCENARIO_PATH" >&2; exit 2; }
if ! SCENARIO_VALIDATION="$(/usr/bin/ruby "$ROOT_DIR/scripts/validate_synthetic_verification_scenario.rb" "$SCENARIO_PATH")"; then
    echo "scenario failed synthetic provenance validation" >&2
    exit 2
fi
SCENARIO_SHA256="$(printf '%s\n' "$SCENARIO_VALIDATION" | sed -n 's/^SYNTHETIC_SCENARIO_SHA256=//p')"
[[ "$SCENARIO_SHA256" =~ ^[a-f0-9]{64}$ ]] || { echo "scenario validation did not return a digest" >&2; exit 2; }
VALIDATED_SCENARIO_DIRECTORY="$(mktemp -d /tmp/hireva-validated-scenario.XXXXXX)"
VALIDATED_SCENARIO="$VALIDATED_SCENARIO_DIRECTORY/scenario.json"
cp "$SCENARIO_PATH" "$VALIDATED_SCENARIO"
VALIDATED_SCENARIO_SHA256="$(/usr/bin/shasum -a 256 "$VALIDATED_SCENARIO" | /usr/bin/awk '{print $1}')"
[[ "$VALIDATED_SCENARIO_SHA256" == "$SCENARIO_SHA256" ]] || { echo "scenario changed during validation" >&2; exit 2; }
SCENARIO_PATH="$VALIDATED_SCENARIO"
VERIFICATION_RUN_NONCE="$(/usr/bin/uuidgen | /usr/bin/tr -d '-' | /usr/bin/tr '[:upper:]' '[:lower:]')"
[[ "$VERIFICATION_RUN_NONCE" =~ ^[a-f0-9]{32}$ ]] || { echo "could not create verification run nonce" >&2; exit 2; }
printf '%s\n' "$SCENARIO_VALIDATION"
validation_value() {
    local key="$1"
    printf '%s\n' "$SCENARIO_VALIDATION" | sed -n "s/^${key}=//p"
}
EXPECTED_SESSION_COUNT="$(validation_value SYNTHETIC_SCENARIO_SESSIONS)"
EXPECTED_TURN_COUNT="$(validation_value SYNTHETIC_SCENARIO_TURNS)"
EXPECTED_TRIGGER_COUNT="$(validation_value SYNTHETIC_SCENARIO_TRIGGERS)"
EXPECTED_REJECT_COUNT="$(validation_value SYNTHETIC_SCENARIO_REJECTS)"
EXPECTED_VISIBLE_MINIMUM="$(validation_value SYNTHETIC_SCENARIO_VISIBLE_MINIMUM)"
EXPECTED_VISIBLE_MAXIMUM="$(validation_value SYNTHETIC_SCENARIO_VISIBLE_MAXIMUM)"
EXPECTED_RAPID_TRANSITIONS="$(validation_value SYNTHETIC_SCENARIO_RAPID_TRANSITIONS)"
for validated_count in "$EXPECTED_SESSION_COUNT" "$EXPECTED_TURN_COUNT" "$EXPECTED_TRIGGER_COUNT" \
    "$EXPECTED_REJECT_COUNT" "$EXPECTED_VISIBLE_MINIMUM" "$EXPECTED_VISIBLE_MAXIMUM" "$EXPECTED_RAPID_TRANSITIONS"; do
    [[ "$validated_count" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "scenario validation returned an invalid count" >&2; exit 2; }
done

echo "scenario_valid sessions=$EXPECTED_SESSION_COUNT turns=$EXPECTED_TURN_COUNT triggers=$EXPECTED_TRIGGER_COUNT rejects=$EXPECTED_REJECT_COUNT visible_min=$EXPECTED_VISIBLE_MINIMUM visible_max=$EXPECTED_VISIBLE_MAXIMUM rapid_transitions=$EXPECTED_RAPID_TRANSITIONS"

evidence_missing_visible_matches() {
    local events_path="$1"
    jq -s --slurpfile scenario "$SCENARIO_PATH" '
        . as $events
        | [$scenario[0].sessions[]
            | .id as $session_id
            | .turns
            | to_entries[]
            | select(.value.expectedShouldTrigger == true and (.value.rapid // false) == false)
            | "\($session_id).\(.key)" as $turn_id
            | select(any($events[];
                .event == "suggestion.visible" and
                (.matchedTurnID // "") == $turn_id
              ) | not)
          ]
        | length
    ' "$events_path"
}

evidence_invalid_visible_count() {
    local events_path="$1"
    jq -r '
        select(
            .event == "suggestion.visible" and
            ((.answerProvider // "") != "ollama_qwen" or
             (.alignmentVerdict // "") != "aligned" or
             (.matchedTurnID // "") == "")
        )
        | .event
    ' "$events_path" | wc -l | tr -d ' '
}

evidence_failure_count() {
    local events_path="$1"
    jq -r 'select(.event == "bootstrap.failed" or .event == "control.next_session.failed" or .event == "app.error") | .event' "$events_path" |
        wc -l | tr -d ' '
}

evidence_forbidden_field_count() {
    local events_path="$1"
    jq -r 'select(
        has("databasePath") or has("scenarioPath") or has("text") or
        has("questionText") or has("answer") or has("latestQuestion") or has("error")
    ) | .event // "invalid"' "$events_path" | wc -l | tr -d ' '
}

evidence_unexpected_event_count() {
    local events_path="$1"
    jq -r 'select((.event // "") as $event | [
        "bootstrap.started", "bootstrap.configured", "bootstrap.failed",
        "control.next_session.requested", "control.next_session.failed",
        "control.stopped", "verification.finished", "control.rejected",
        "bootstrap.ready", "sck.first_buffer", "asr.transcript",
        "question.accepted", "generation.started", "suggestion.visible",
        "dialogue.decision", "sqlite.suggestion_count", "app.error", "status"
    ] | index($event) | not) | .event // "invalid"' "$events_path" | wc -l | tr -d ' '
}

evidence_schema_error_count() {
    local events_path="$1"
    jq -r '
        def exact($fields): ((keys | sort) == (($fields + ["event", "timestamp"]) | sort));
        def string: type == "string";
        def boolean: type == "boolean";
        def nonnegative_integer: type == "number" and . >= 0 and floor == .;
        def positive_number: type == "number" and . > 0;
        def safe_id: type == "string" and test("^[A-Za-z0-9._-]{0,160}$");
        select(
            (.event | string | not) or
            (.timestamp | string | not) or
            (if .event == "bootstrap.started" then
                (exact(["runID", "databaseLocation", "scenarioSHA256"]) | not) or
                (.runID | safe_id | not) or
                (.databaseLocation != "isolated_verification_support") or
                (.scenarioSHA256 | string | not) or
                (.scenarioSHA256 | test("^[a-f0-9]{64}$") | not)
             elif .event == "bootstrap.configured" then
                (exact(["asrProvider", "answerProvider", "candidateProfileID", "opportunityContextID"]) | not) or
                ([.asrProvider, .answerProvider, .candidateProfileID, .opportunityContextID] | all(string) | not)
             elif .event == "bootstrap.failed" then
                (exact(["errorCode"]) | not) or (.errorCode | safe_id | not)
             elif .event == "control.next_session.requested" or
                  .event == "control.stopped" then
                (exact([]) | not)
             elif .event == "control.next_session.failed" then
                (exact(["errorCode"]) | not) or (.errorCode | safe_id | not)
             elif .event == "verification.finished" then
                (exact(["suggestionRows", "databaseLocation", "systemCaptureRunning"]) | not) or
                (.suggestionRows | nonnegative_integer | not) or
                (.databaseLocation != "isolated_verification_support") or
                (.systemCaptureRunning | boolean | not)
             elif .event == "control.rejected" then
                (exact(["actionCode"]) | not) or (.actionCode | safe_id | not)
             elif .event == "bootstrap.ready" then
                (exact(["sessionID", "contextSnapshotID", "activeASRProvider", "systemCaptureRunning"]) | not) or
                ([.sessionID, .contextSnapshotID, .activeASRProvider] | all(safe_id) | not) or
                (.systemCaptureRunning | boolean | not)
             elif .event == "sck.first_buffer" then
                (exact(["sessionID", "totalBuffers", "sampleRate", "channelCount", "lastBufferAt"]) | not) or
                (.sessionID | safe_id | not) or
                (.totalBuffers | nonnegative_integer | not) or
                (.sampleRate | positive_number | not) or
                (.channelCount | nonnegative_integer | not) or
                (.lastBufferAt | string | not)
             elif .event == "asr.transcript" then
                (exact(["sessionID", "segmentID", "textCharacters", "textWords", "source", "speaker", "asrProvider", "isFinal", "finalizationReason"]) | not) or
                ([.sessionID, .segmentID, .source, .speaker, .asrProvider, .finalizationReason] | all(safe_id) | not) or
                (.textCharacters | nonnegative_integer | not) or
                (.textWords | nonnegative_integer | not) or
                (.isFinal | boolean | not)
             elif .event == "question.accepted" then
                (exact(["sessionID", "questionID", "questionCharacters", "contextSnapshotID"]) | not) or
                ([.sessionID, .questionID, .contextSnapshotID] | all(safe_id) | not) or
                (.questionCharacters | nonnegative_integer | not)
             elif .event == "generation.started" then
                (exact(["sessionID", "questionID", "generationID", "contextSnapshotID"]) | not) or
                ([.sessionID, .questionID, .generationID, .contextSnapshotID] | all(safe_id) | not)
             elif .event == "suggestion.visible" then
                (exact(["sessionID", "suggestionID", "questionID", "generationID", "contextSnapshotID", "matchedTurnID", "answerCharacters", "answerProvider", "alignmentVerdict"]) | not) or
                ([.sessionID, .suggestionID, .questionID, .generationID, .contextSnapshotID, .matchedTurnID, .answerProvider, .alignmentVerdict] | all(safe_id) | not) or
                (.answerCharacters | nonnegative_integer | not)
             elif .event == "dialogue.decision" then
                (exact(["sessionID", "segmentID", "triggerDecision", "questionID", "generationID", "speaker", "source", "asrProvider"]) | not) or
                ([.sessionID, .segmentID, .triggerDecision, .questionID, .generationID, .speaker, .source, .asrProvider] | all(safe_id) | not)
             elif .event == "sqlite.suggestion_count" then
                (exact(["sessionID", "count", "latestQuestionCharacters"]) | not) or
                (.sessionID | safe_id | not) or
                (.count | nonnegative_integer | not) or
                (.latestQuestionCharacters | nonnegative_integer | not)
             elif .event == "app.error" then
                (exact(["errorCode", "sessionID"]) | not) or
                ([.errorCode, .sessionID] | all(safe_id) | not)
             elif .event == "status" then
                (exact(["sessionID", "captureState", "systemCaptureRunning", "activeASRProvider", "questionID", "generationID", "suggestionID", "suggestionRows"]) | not) or
                ([.sessionID, .captureState, .activeASRProvider, .questionID, .generationID, .suggestionID] | all(safe_id) | not) or
                (.systemCaptureRunning | boolean | not) or
                (.suggestionRows | nonnegative_integer | not)
             else true
             end)
        )
        | .event // "invalid"
    ' "$events_path" | wc -l | tr -d ' '
}

evidence_scenario_digest_count() {
    local events_path="$1"
    jq -r --arg digest "$SCENARIO_SHA256" '
        select(.event == "bootstrap.started" and (.scenarioSHA256 // "") == $digest) | .event
    ' "$events_path" | wc -l | tr -d ' '
}

evidence_event_count() {
    local events_path="$1" event="$2"
    jq -r --arg event "$event" 'select(.event == $event) | .event' "$events_path" | wc -l | tr -d ' '
}

evidence_rapid_metrics() {
    local events_path="$1"
    /usr/bin/ruby - "$SCENARIO_PATH" "$events_path" <<'RUBY'
require "json"

scenario = JSON.parse(File.read(ARGV.fetch(0)))
events = File.readlines(ARGV.fetch(1), chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
trigger_turns = scenario.fetch("sessions").flat_map do |session|
  session.fetch("turns").select { |turn| turn["expectedShouldTrigger"] == true }
end
generations = []
questions = []
events.each_with_index do |event, index|
  generations << [event, index] if event["event"] == "generation.started"
  questions << [event, index] if event["event"] == "question.accepted"
end

rapid_indices = []
trigger_turns.each_with_index do |turn, index|
  rapid_indices << index if turn.fetch("rapid", false) == true
end

completed_before_followup = 0
cancellations = 0
stale_visible = 0
rapid_indices.each do |rapid_index|
  rapid_generation = generations[rapid_index]
  followup_question = questions[rapid_index + 1]
  unless rapid_generation && followup_question
    stale_visible += 1
    next
  end

  rapid_generation_id = rapid_generation.fetch(0).fetch("generationID", "")
  followup_event_index = followup_question.fetch(1)
  suggestion_indices = []
  events.each_with_index do |event, event_index|
    if event["event"] == "suggestion.visible" && event["generationID"] == rapid_generation_id
      suggestion_indices << event_index
    end
  end
  before_followup = suggestion_indices.count { |event_index| event_index < followup_event_index }
  after_followup = suggestion_indices.count { |event_index| event_index > followup_event_index }
  completed_before_followup += 1 if before_followup.positive?
  cancellations += 1 if suggestion_indices.empty?
  stale_visible += [before_followup - 1, 0].max + after_followup
end

puts [
  "rapid_transitions=#{rapid_indices.length}",
  "rapid_completed_before_followup=#{completed_before_followup}",
  "rapid_cancellations=#{cancellations}",
  "stale_rapid_visible=#{stale_visible}"
].join(" ")
RUBY
}

metric_value() {
    local metrics="$1" key="$2"
    printf '%s\n' "$metrics" | tr ' ' '\n' | sed -n "s/^${key}=//p"
}

require_equal() {
    local label="$1" actual="$2" expected="$3"
    if [[ "$actual" -ne "$expected" ]]; then
        echo "$label count mismatch: actual=$actual expected=$expected" >&2
        exit 1
    fi
}

require_between() {
    local label="$1" actual="$2" minimum="$3" maximum="$4"
    if [[ "$actual" -lt "$minimum" || "$actual" -gt "$maximum" ]]; then
        echo "$label count outside range: actual=$actual minimum=$minimum maximum=$maximum" >&2
        exit 1
    fi
}

if [[ "$EVIDENCE_ONLY" == "true" ]]; then
    [[ -f "$EVIDENCE_PATH" ]] || { echo "evidence not found: $EVIDENCE_PATH" >&2; exit 2; }
    ready_count="$(evidence_event_count "$EVIDENCE_PATH" bootstrap.ready)"
    buffer_count="$(evidence_event_count "$EVIDENCE_PATH" sck.first_buffer)"
    transcript_count="$(evidence_event_count "$EVIDENCE_PATH" asr.transcript)"
    question_count="$(evidence_event_count "$EVIDENCE_PATH" question.accepted)"
    generation_count="$(evidence_event_count "$EVIDENCE_PATH" generation.started)"
    visible_count="$(evidence_event_count "$EVIDENCE_PATH" suggestion.visible)"
    finished_count="$(evidence_event_count "$EVIDENCE_PATH" verification.finished)"
    digest_count="$(evidence_scenario_digest_count "$EVIDENCE_PATH")"
    failure_count="$(evidence_failure_count "$EVIDENCE_PATH")"
    forbidden_field_count="$(evidence_forbidden_field_count "$EVIDENCE_PATH")"
    unexpected_event_count="$(evidence_unexpected_event_count "$EVIDENCE_PATH")"
    schema_error_count="$(evidence_schema_error_count "$EVIDENCE_PATH")"
    missing_visible_match_count="$(evidence_missing_visible_matches "$EVIDENCE_PATH")"
    invalid_visible_count="$(evidence_invalid_visible_count "$EVIDENCE_PATH")"
    rapid_metrics="$(evidence_rapid_metrics "$EVIDENCE_PATH")"
    rapid_transition_count="$(metric_value "$rapid_metrics" rapid_transitions)"
    rapid_completed_before_followup_count="$(metric_value "$rapid_metrics" rapid_completed_before_followup)"
    rapid_cancellation_count="$(metric_value "$rapid_metrics" rapid_cancellations)"
    stale_rapid_visible_count="$(metric_value "$rapid_metrics" stale_rapid_visible)"
    rapid_disposition_count=$((rapid_completed_before_followup_count + rapid_cancellation_count))
    expected_visible_count=$((EXPECTED_VISIBLE_MINIMUM + rapid_completed_before_followup_count))
    echo "evidence_valid ready=$ready_count buffers=$buffer_count transcripts=$transcript_count questions=$question_count generations=$generation_count visible=$visible_count finished=$finished_count digest=$digest_count failures=$failure_count forbidden_fields=$forbidden_field_count unexpected_events=$unexpected_event_count schema_errors=$schema_error_count missing_visible_matches=$missing_visible_match_count invalid_visible=$invalid_visible_count $rapid_metrics"
    require_equal ready "$ready_count" "$EXPECTED_SESSION_COUNT"
    require_equal buffers "$buffer_count" "$EXPECTED_SESSION_COUNT"
    require_equal transcripts "$transcript_count" "$EXPECTED_TURN_COUNT"
    require_equal questions "$question_count" "$EXPECTED_TRIGGER_COUNT"
    require_equal generations "$generation_count" "$EXPECTED_TRIGGER_COUNT"
    require_between visible "$visible_count" "$EXPECTED_VISIBLE_MINIMUM" "$EXPECTED_VISIBLE_MAXIMUM"
    require_equal visible_from_rapid_disposition "$visible_count" "$expected_visible_count"
    require_equal finished "$finished_count" 1
    require_equal scenario_digest "$digest_count" 1
    require_equal failures "$failure_count" 0
    require_equal forbidden_fields "$forbidden_field_count" 0
    require_equal unexpected_events "$unexpected_event_count" 0
    require_equal schema_errors "$schema_error_count" 0
    require_equal missing_visible_matches "$missing_visible_match_count" 0
    require_equal invalid_visible "$invalid_visible_count" 0
    require_equal rapid_transitions "$rapid_transition_count" "$EXPECTED_RAPID_TRANSITIONS"
    require_equal rapid_dispositions "$rapid_disposition_count" "$EXPECTED_RAPID_TRANSITIONS"
    require_equal stale_rapid_visible "$stale_rapid_visible_count" 0
    exit
fi
[[ "$VALIDATE_ONLY" == "false" ]] || exit 0

EVENTS="$OUTPUT_ROOT/app_verification_events.jsonl"
RESULTS="$OUTPUT_ROOT/real_dialogue_results.tsv"
AUDIO_ROOT="$OUTPUT_ROOT/dialogue_audio"
[[ -d "$APP_BUNDLE" && -x "$APP_BINARY" ]] || { echo "signed app bundle not found: $APP_BUNDLE" >&2; exit 2; }

umask 077
mkdir -m 700 "$OUTPUT_ROOT"
mkdir -m 700 "$APP_SUPPORT_ROOT"
mkdir -m 700 "$AUDIO_ROOT"
for owned_directory in "$OUTPUT_ROOT" "$APP_SUPPORT_ROOT" "$AUDIO_ROOT"; do
    [[ -d "$owned_directory" && ! -L "$owned_directory" ]] || { echo "verification directory creation was not atomic" >&2; exit 2; }
    [[ "$(cd -P "$owned_directory" && pwd)" == "$owned_directory" ]] || { echo "verification directory resolved outside its requested location" >&2; exit 2; }
done
[[ ! -e "$EVENTS" && ! -e "$RESULTS" ]] || { echo "verification evidence already exists; use a fresh output root" >&2; exit 2; }
/usr/bin/say -v '?' > "$OUTPUT_ROOT/available_voices.txt"

ruby - "$OUTPUT_ROOT/available_voices.txt" "$OUTPUT_ROOT/selected_voices.json" <<'RUBY'
require "json"
lines = File.readlines(ARGV[0], chomp: true)
voices = lines.map do |line|
  match = line.match(/^(.*?)\s+(en_[A-Z]{2})\s+#/)
  match && {"voice" => match[1].strip, "locale" => match[2]}
end.compact
selected = []
preferred_voices = {"en_GB" => "Daniel", "en_US" => "Samantha", "en_AU" => "Karen"}
["en_GB", "en_US", "en_AU"].each do |locale|
  candidate = voices.find { |item| item["locale"] == locale && item["voice"] == preferred_voices[locale] }
  candidate ||= voices.find { |item| item["locale"] == locale && !selected.include?(item) }
  selected << candidate if candidate
end
while selected.length < 3
  candidate = voices.find { |item| !selected.any? { |picked| picked["locale"] == item["locale"] } }
  break unless candidate
  selected << candidate
end
abort("fewer than three English voices are available") if selected.length < 3
abort("three distinct English locales are required") if selected.map { |item| item["locale"] }.uniq.length < 3
File.write(ARGV[1], JSON.pretty_generate(selected) + "\n")
RUBY

cat > "$OUTPUT_ROOT/verification_notify.swift" <<'SWIFT'
import Foundation
guard CommandLine.arguments.count == 2 else { exit(2) }
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.langcheng.Hireva.VerificationControl"),
    object: nil,
    userInfo: ["action": CommandLine.arguments[1]],
    deliverImmediately: true
)
SWIFT
swiftc "$OUTPUT_ROOT/verification_notify.swift" -o "$OUTPUT_ROOT/verification_notify"
NOTIFY_BINARY="$OUTPUT_ROOT/verification_notify"

notify() {
    "$OUTPUT_ROOT/verification_notify" "$1"
}

event_count() {
    local event="$1"
    [[ -f "$EVENTS" ]] || { echo 0; return; }
    jq -r --arg event "$event" 'select(.event == $event) | .event' "$EVENTS" 2>/dev/null | wc -l | tr -d ' '
}

wait_for_count() {
    local event="$1" previous="$2" timeout="$3"
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if (( $(event_count "$event") > previous )); then return 0; fi
        sleep 0.25
    done
    return 1
}

latest_suggestion_match() {
    [[ -f "$EVENTS" ]] || return 0
    jq -sr '[.[] | select(.event == "suggestion.visible")] | last | .matchedTurnID // ""' "$EVENTS" 2>/dev/null
}

latest_generation_id() {
    [[ -f "$EVENTS" ]] || return 0
    jq -sr '[.[] | select(.event == "generation.started")] | last | .generationID // ""' "$EVENTS" 2>/dev/null
}

wait_for_matching_suggestion() {
    local previous="$1" expected_turn_id="$2" timeout="$3"
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if (( $(event_count suggestion.visible) > previous )); then
            local observed
            observed="$(latest_suggestion_match)"
            if [[ "$observed" == "$expected_turn_id" ]]; then return 0; fi
        fi
        sleep 0.25
    done
    return 1
}

/usr/bin/osascript -e 'tell application id "com.langcheng.Hireva" to quit' >/dev/null 2>&1 &
PRELAUNCH_QUIT_PID=$!
wait_for_pid_exit "$PRELAUNCH_QUIT_PID" 20 || kill -TERM "$PRELAUNCH_QUIT_PID" >/dev/null 2>&1
wait "$PRELAUNCH_QUIT_PID" >/dev/null 2>&1 || true
for _ in {1..20}; do
    pgrep -f "$APP_BINARY" >/dev/null || break
    sleep 0.25
done
if pgrep -f "$APP_BINARY" >/dev/null; then
    echo "an existing Hireva process is still using the verification bundle" >&2
    exit 1
fi

/usr/bin/open -n \
    --env "HIREVA_VERIFICATION_MODE=1" \
    --env "HIREVA_VERIFICATION_SCENARIO_PATH=$SCENARIO_PATH" \
    --env "HIREVA_VERIFICATION_SCENARIO_SHA256=$SCENARIO_SHA256" \
    --env "HIREVA_VERIFICATION_RUN_NONCE=$VERIFICATION_RUN_NONCE" \
    --env "HIREVA_VERIFICATION_OUTPUT_ROOT=$OUTPUT_ROOT" \
    --env "HIREVA_VERIFICATION_APP_SUPPORT_DIR=$APP_SUPPORT_ROOT" \
    --env "HIREVA_VERIFICATION_MODEL_ROOT=$MODEL_ROOT" \
    "$APP_BUNDLE"
APP_LAUNCHED=true

for _ in {1..80}; do
    APP_PID_LIST="$(pgrep -f "$APP_BINARY" 2>/dev/null || true)"
    APP_PID_COUNT="$(printf '%s\n' "$APP_PID_LIST" | awk 'NF { count++ } END { print count + 0 }')"
    if [[ "$APP_PID_COUNT" -eq 1 ]]; then
        OWNED_APP_PID="$APP_PID_LIST"
        break
    fi
    if [[ "$APP_PID_COUNT" -gt 1 ]]; then
        while IFS= read -r duplicate_pid; do
            [[ "$duplicate_pid" =~ ^[0-9]+$ ]] && terminate_owned_process "$duplicate_pid" app
        done <<< "$APP_PID_LIST"
        echo "verification launch created multiple Hireva processes" >&2
        exit 1
    fi
    sleep 0.25
done
[[ -n "$OWNED_APP_PID" ]] || { echo "verification launch did not create a Hireva process" >&2; exit 1; }
process_matches_app "$OWNED_APP_PID" || { echo "verification launch process identity did not match the bundle" >&2; exit 1; }

wait_for_count "bootstrap.ready" 0 60 || {
    echo "app did not become verification-ready" >&2
    [[ -f "$EVENTS" ]] && tail -50 "$EVENTS" >&2
    exit 1
}
capture_owned_helper_pids

printf 'session\tturn\tvoice\tlocale\trate\texpected_trigger\ttranscript_observed\tvisible_observed\tfalse_trigger\tmatched_turn_id\n' > "$RESULTS"

session_count="$(jq '.sessions | length' "$SCENARIO_PATH")"
rapid_pending_generation_id=""
rapid_transition_count=0
for ((session_index=0; session_index<session_count; session_index++)); do
    if (( session_index > 0 )); then
        ready_before="$(event_count bootstrap.ready)"
        notify next_session
        wait_for_count bootstrap.ready "$ready_before" 60 || { echo "session $session_index did not restart" >&2; exit 1; }
    fi
    turn_count="$(jq ".sessions[$session_index].turns | length" "$SCENARIO_PATH")"
    for ((turn_index=0; turn_index<turn_count; turn_index++)); do
        text="$(jq -r ".sessions[$session_index].turns[$turn_index].text" "$SCENARIO_PATH")"
        expected="$(jq -r ".sessions[$session_index].turns[$turn_index].expectedShouldTrigger" "$SCENARIO_PATH")"
        rate="$(jq -r ".sessions[$session_index].turns[$turn_index].rate" "$SCENARIO_PATH")"
        voice_slot="$(jq -r ".sessions[$session_index].turns[$turn_index].voiceSlot" "$SCENARIO_PATH")"
        rapid="$(jq -r ".sessions[$session_index].turns[$turn_index].rapid // false" "$SCENARIO_PATH")"
        session_id="$(jq -r ".sessions[$session_index].id" "$SCENARIO_PATH")"
        expected_turn_id="$session_id.$turn_index"
        voice="$(jq -r ".[$voice_slot].voice" "$OUTPUT_ROOT/selected_voices.json")"
        locale="$(jq -r ".[$voice_slot].locale" "$OUTPUT_ROOT/selected_voices.json")"
        audio="$AUDIO_ROOT/session-$((session_index+1))-turn-$((turn_index+1)).aiff"
        transcript_before="$(event_count asr.transcript)"
        generation_before="$(event_count generation.started)"
        visible_before="$(event_count suggestion.visible)"
        /usr/bin/say -v "$voice" -r "$rate" -o "$audio" "$text"
        /usr/bin/afplay "$audio"
        if [[ "$rapid" == "true" ]]; then sleep 0.1; else sleep 2; fi
        transcript_observed=false
        visible_observed=false
        false_trigger=false
        observed_question=""
        if wait_for_count asr.transcript "$transcript_before" 35; then transcript_observed=true; fi
        if [[ -n "$rapid_pending_generation_id" ]]; then
            wait_for_count generation.started "$generation_before" 45 || { echo "rapid follow-up did not start generation" >&2; exit 1; }
            rapid_pending_generation_id=""
        fi
        if [[ "$expected" == "true" ]]; then
            if [[ "$rapid" == "true" ]]; then
                wait_for_count generation.started "$generation_before" 45 || { echo "rapid turn did not start generation" >&2; exit 1; }
                rapid_pending_generation_id="$(latest_generation_id)"
                [[ -n "$rapid_pending_generation_id" ]] || { echo "rapid generation identity was not recorded" >&2; exit 1; }
                rapid_transition_count=$((rapid_transition_count + 1))
            elif wait_for_matching_suggestion "$visible_before" "$expected_turn_id" 90; then
                visible_observed=true
            fi
            observed_question="$(latest_suggestion_match)"
        else
            sleep 4
            if (( $(event_count suggestion.visible) > visible_before )); then false_trigger=true; fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$((session_index+1))" "$((turn_index+1))" "$voice" "$locale" "$rate" "$expected" \
            "$transcript_observed" "$visible_observed" "$false_trigger" "$observed_question" >> "$RESULTS"
        echo "session=$((session_index+1)) turn=$((turn_index+1)) transcript=$transcript_observed visible=$visible_observed false_trigger=$false_trigger"
    done
done

[[ -z "$rapid_pending_generation_id" ]] || { echo "rapid turn was not followed by a completed follow-up" >&2; exit 1; }

notify finish
wait_for_count verification.finished 0 30 || { echo "verification did not emit its terminal event" >&2; exit 1; }
capture_owned_helper_pids
/usr/bin/osascript -e 'tell application id "com.langcheng.Hireva" to quit' >/dev/null 2>&1 &
FINAL_QUIT_PID=$!
wait_for_pid_exit "$FINAL_QUIT_PID" 20 || kill -TERM "$FINAL_QUIT_PID" >/dev/null 2>&1
wait "$FINAL_QUIT_PID" >/dev/null 2>&1 || true
wait_for_pid_exit "$OWNED_APP_PID" 40 || true

app_count=0
if kill -0 "$OWNED_APP_PID" >/dev/null 2>&1 && process_matches_app "$OWNED_APP_PID"; then
    app_count=1
fi
helper_count=0
if (( ${#OWNED_HELPER_PIDS[@]} > 0 )); then
    for helper_pid in "${OWNED_HELPER_PIDS[@]}"; do
        if kill -0 "$helper_pid" >/dev/null 2>&1 && process_matches_bundled_helper "$helper_pid"; then
            helper_count=$((helper_count + 1))
        fi
    done
fi
ready_count="$(event_count bootstrap.ready)"
buffer_count="$(event_count sck.first_buffer)"
transcript_count="$(event_count asr.transcript)"
question_count="$(event_count question.accepted)"
generation_count="$(event_count generation.started)"
visible_count="$(event_count suggestion.visible)"
false_trigger_count="$(awk -F '\t' 'NR > 1 && $9 == "true" { count++ } END { print count + 0 }' "$RESULTS")"
finished_count="$(event_count verification.finished)"
digest_count="$(evidence_scenario_digest_count "$EVENTS")"
failure_count="$(evidence_failure_count "$EVENTS")"
forbidden_field_count="$(evidence_forbidden_field_count "$EVENTS")"
unexpected_event_count="$(evidence_unexpected_event_count "$EVENTS")"
schema_error_count="$(evidence_schema_error_count "$EVENTS")"
missing_visible_match_count="$(evidence_missing_visible_matches "$EVENTS")"
invalid_visible_count="$(evidence_invalid_visible_count "$EVENTS")"
rapid_metrics="$(evidence_rapid_metrics "$EVENTS")"
rapid_completed_before_followup_count="$(metric_value "$rapid_metrics" rapid_completed_before_followup)"
rapid_cancellation_count="$(metric_value "$rapid_metrics" rapid_cancellations)"
stale_rapid_visible_count="$(metric_value "$rapid_metrics" stale_rapid_visible)"
rapid_disposition_count=$((rapid_completed_before_followup_count + rapid_cancellation_count))
expected_visible_count=$((EXPECTED_VISIBLE_MINIMUM + rapid_completed_before_followup_count))
echo "ready=$ready_count buffers=$buffer_count transcripts=$transcript_count questions=$question_count generations=$generation_count visible=$visible_count finished=$finished_count digest=$digest_count failures=$failure_count forbidden_fields=$forbidden_field_count unexpected_events=$unexpected_event_count schema_errors=$schema_error_count false_triggers=$false_trigger_count $rapid_metrics missing_visible_matches=$missing_visible_match_count invalid_visible=$invalid_visible_count"
echo "app_count=$app_count helper_count=$helper_count"
require_equal ready "$ready_count" "$EXPECTED_SESSION_COUNT"
require_equal buffers "$buffer_count" "$EXPECTED_SESSION_COUNT"
require_equal transcripts "$transcript_count" "$EXPECTED_TURN_COUNT"
require_equal questions "$question_count" "$EXPECTED_TRIGGER_COUNT"
require_equal generations "$generation_count" "$EXPECTED_TRIGGER_COUNT"
require_between visible "$visible_count" "$EXPECTED_VISIBLE_MINIMUM" "$EXPECTED_VISIBLE_MAXIMUM"
require_equal visible_from_rapid_disposition "$visible_count" "$expected_visible_count"
require_equal finished "$finished_count" 1
require_equal scenario_digest "$digest_count" 1
require_equal failures "$failure_count" 0
require_equal forbidden_fields "$forbidden_field_count" 0
require_equal unexpected_events "$unexpected_event_count" 0
require_equal schema_errors "$schema_error_count" 0
require_equal false_triggers "$false_trigger_count" 0
require_equal rapid_transitions "$rapid_transition_count" "$EXPECTED_RAPID_TRANSITIONS"
require_equal rapid_dispositions "$rapid_disposition_count" "$EXPECTED_RAPID_TRANSITIONS"
require_equal stale_rapid_visible "$stale_rapid_visible_count" 0
require_equal missing_visible_matches "$missing_visible_match_count" 0
require_equal invalid_visible "$invalid_visible_count" 0
require_equal app_processes "$app_count" 0
require_equal helper_processes "$helper_count" 0
VERIFICATION_COMPLETED=true

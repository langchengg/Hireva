#!/usr/bin/env bash
set -euo pipefail

VALIDATE_ONLY=false
EVIDENCE_ONLY=false
EVIDENCE_PATH=""
if [[ $# -eq 2 && "$1" == "--validate-scenario" ]]; then
    SCENARIO_PATH="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
    VALIDATE_ONLY=true
elif [[ $# -eq 3 && "$1" == "--validate-evidence" ]]; then
    SCENARIO_PATH="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
    EVIDENCE_PATH="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
    EVIDENCE_ONLY=true
elif [[ $# -eq 4 ]]; then
    SCENARIO_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    OUTPUT_ROOT="$(cd "$2" && pwd)"
    APP_SUPPORT_ROOT="$(cd "$3" && pwd)"
    MODEL_ROOT="$(cd "$4" && pwd)"
else
    echo "usage: $0 <scenario.json> <output-root> <app-support-root> <local-models-root>" >&2
    echo "       $0 --validate-scenario <scenario.json>" >&2
    echo "       $0 --validate-evidence <scenario.json> <events.jsonl>" >&2
    exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/Hireva.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Hireva"

[[ -f "$SCENARIO_PATH" ]] || { echo "scenario not found: $SCENARIO_PATH" >&2; exit 2; }
[[ "$(jq -r '.synthetic' "$SCENARIO_PATH")" == "true" ]] || { echo "scenario must be synthetic" >&2; exit 2; }
EXPECTED_SESSION_COUNT="$(jq -r '.expectedSessionCount // 8' "$SCENARIO_PATH")"
EXPECTED_TURN_COUNT="$(jq -r '.expectedTurnCount // 40' "$SCENARIO_PATH")"
EXPECTED_TRIGGER_COUNT="$(jq -r '.expectedTriggerCount // 32' "$SCENARIO_PATH")"
EXPECTED_REJECT_COUNT="$(jq -r '.expectedRejectCount // 8' "$SCENARIO_PATH")"
RAPID_TURN_COUNT="$(jq '[.sessions[].turns[] | select(.rapid == true)] | length' "$SCENARIO_PATH")"
EXPECTED_VISIBLE_COUNT="$(jq -r --argjson fallback "$((EXPECTED_TRIGGER_COUNT - RAPID_TURN_COUNT))" '.expectedVisibleCount // $fallback' "$SCENARIO_PATH")"
EXPECTED_RAPID_CANCELLATIONS="$(jq -r --argjson fallback "$RAPID_TURN_COUNT" '.expectedRapidCancellationCount // $fallback' "$SCENARIO_PATH")"
[[ "$(jq '.sessions | length' "$SCENARIO_PATH")" -eq "$EXPECTED_SESSION_COUNT" ]] || { echo "scenario session count does not match expectedSessionCount=$EXPECTED_SESSION_COUNT" >&2; exit 2; }
[[ "$(jq '[.sessions[].turns[]] | length' "$SCENARIO_PATH")" -eq "$EXPECTED_TURN_COUNT" ]] || { echo "scenario turn count does not match expectedTurnCount=$EXPECTED_TURN_COUNT" >&2; exit 2; }
[[ "$(jq '[.sessions[].turns[] | select(.expectedShouldTrigger == true)] | length' "$SCENARIO_PATH")" -eq "$EXPECTED_TRIGGER_COUNT" ]] || { echo "scenario trigger count does not match expectedTriggerCount=$EXPECTED_TRIGGER_COUNT" >&2; exit 2; }
[[ "$(jq '[.sessions[].turns[] | select(.expectedShouldTrigger == false)] | length' "$SCENARIO_PATH")" -eq "$EXPECTED_REJECT_COUNT" ]] || { echo "scenario reject count does not match expectedRejectCount=$EXPECTED_REJECT_COUNT" >&2; exit 2; }
[[ "$(jq '[.sessions[].turns[] | select(.expectedShouldTrigger == true and ((.expectedQuestionNeedle // "") | length == 0))] | length' "$SCENARIO_PATH")" -eq 0 ]] || { echo "every triggering utterance needs expectedQuestionNeedle" >&2; exit 2; }
[[ "$(jq '[.sessions[].turns as $turns | range(0; $turns | length) as $index | select($turns[$index].rapid == true and (($index + 1 >= ($turns | length)) or $turns[$index + 1].expectedShouldTrigger != true))] | length' "$SCENARIO_PATH")" -eq 0 ]] || { echo "every rapid turn must be followed by a triggering utterance in the same session" >&2; exit 2; }

echo "scenario_valid sessions=$EXPECTED_SESSION_COUNT turns=$EXPECTED_TURN_COUNT triggers=$EXPECTED_TRIGGER_COUNT rejects=$EXPECTED_REJECT_COUNT visible=$EXPECTED_VISIBLE_COUNT rapid_cancellations=$EXPECTED_RAPID_CANCELLATIONS"

evidence_missing_visible_needles() {
    local events_path="$1"
    jq -s --slurpfile scenario "$SCENARIO_PATH" '
        . as $events
        | [$scenario[0].sessions[].turns[]
            | select(.expectedShouldTrigger == true and (.rapid // false) == false)
            | (.expectedQuestionNeedle | ascii_downcase) as $needle
            | select(any($events[];
                .event == "suggestion.visible" and
                ((.questionText // "" | ascii_downcase) | contains($needle))
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
            ((.answerProvider // "") != "ollama_qwen" or (.alignmentVerdict // "") != "aligned")
        )
        | .event
    ' "$events_path" | wc -l | tr -d ' '
}

evidence_event_count() {
    local events_path="$1" event="$2"
    jq -r --arg event "$event" 'select(.event == $event) | .event' "$events_path" | wc -l | tr -d ' '
}

require_equal() {
    local label="$1" actual="$2" expected="$3"
    if [[ "$actual" -ne "$expected" ]]; then
        echo "$label count mismatch: actual=$actual expected=$expected" >&2
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
    missing_visible_needle_count="$(evidence_missing_visible_needles "$EVIDENCE_PATH")"
    invalid_visible_count="$(evidence_invalid_visible_count "$EVIDENCE_PATH")"
    echo "evidence_valid ready=$ready_count buffers=$buffer_count transcripts=$transcript_count questions=$question_count generations=$generation_count visible=$visible_count missing_visible_needles=$missing_visible_needle_count invalid_visible=$invalid_visible_count"
    require_equal ready "$ready_count" "$EXPECTED_SESSION_COUNT"
    require_equal buffers "$buffer_count" "$EXPECTED_SESSION_COUNT"
    require_equal transcripts "$transcript_count" "$EXPECTED_TURN_COUNT"
    require_equal questions "$question_count" "$EXPECTED_TRIGGER_COUNT"
    require_equal generations "$generation_count" "$EXPECTED_TRIGGER_COUNT"
    require_equal visible "$visible_count" "$EXPECTED_VISIBLE_COUNT"
    require_equal missing_visible_needles "$missing_visible_needle_count" 0
    require_equal invalid_visible "$invalid_visible_count" 0
    exit
fi
[[ "$VALIDATE_ONLY" == "false" ]] || exit 0

EVENTS="$OUTPUT_ROOT/app_verification_events.jsonl"
RESULTS="$OUTPUT_ROOT/real_dialogue_results.tsv"
AUDIO_ROOT="$OUTPUT_ROOT/dialogue_audio"
[[ -d "$APP_BUNDLE" && -x "$APP_BINARY" ]] || { echo "signed app bundle not found: $APP_BUNDLE" >&2; exit 2; }

mkdir -p "$OUTPUT_ROOT" "$APP_SUPPORT_ROOT" "$AUDIO_ROOT"
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

latest_suggestion_question() {
    [[ -f "$EVENTS" ]] || return 0
    jq -sr '[.[] | select(.event == "suggestion.visible")] | last | .questionText // ""' "$EVENTS" 2>/dev/null
}

latest_generation_id() {
    [[ -f "$EVENTS" ]] || return 0
    jq -sr '[.[] | select(.event == "generation.started")] | last | .generationID // ""' "$EVENTS" 2>/dev/null
}

suggestion_count_for_generation() {
    local generation_id="$1"
    [[ -f "$EVENTS" ]] || { echo 0; return; }
    jq -r --arg generation_id "$generation_id" 'select(.event == "suggestion.visible" and .generationID == $generation_id) | .event' "$EVENTS" 2>/dev/null | wc -l | tr -d ' '
}

wait_for_matching_suggestion() {
    local previous="$1" needle="$2" timeout="$3"
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if (( $(event_count suggestion.visible) > previous )); then
            local observed observed_lower needle_lower
            observed="$(latest_suggestion_question)"
            observed_lower="$(printf '%s' "$observed" | tr '[:upper:]' '[:lower:]')"
            needle_lower="$(printf '%s' "$needle" | tr '[:upper:]' '[:lower:]')"
            if [[ "$observed_lower" == *"$needle_lower"* ]]; then return 0; fi
        fi
        sleep 0.25
    done
    return 1
}

osascript -e 'tell application id "com.langcheng.Hireva" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
    pgrep -f "$APP_BINARY" >/dev/null || break
    sleep 0.25
done

/usr/bin/open -n \
    --env "HIREVA_VERIFICATION_MODE=1" \
    --env "HIREVA_VERIFICATION_SCENARIO_PATH=$SCENARIO_PATH" \
    --env "HIREVA_VERIFICATION_OUTPUT_ROOT=$OUTPUT_ROOT" \
    --env "HIREVA_VERIFICATION_APP_SUPPORT_DIR=$APP_SUPPORT_ROOT" \
    --env "HIREVA_VERIFICATION_MODEL_ROOT=$MODEL_ROOT" \
    "$APP_BUNDLE"

wait_for_count "bootstrap.ready" 0 60 || {
    echo "app did not become verification-ready" >&2
    [[ -f "$EVENTS" ]] && tail -50 "$EVENTS" >&2
    exit 1
}

printf 'session\tturn\tvoice\tlocale\trate\texpected_trigger\ttranscript_observed\tvisible_observed\tfalse_trigger\tobserved_question\n' > "$RESULTS"

session_count="$(jq '.sessions | length' "$SCENARIO_PATH")"
rapid_pending_generation_id=""
rapid_generation_ids=()
rapid_cancellation_count=0
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
        needle="$(jq -r ".sessions[$session_index].turns[$turn_index].expectedQuestionNeedle // \"\"" "$SCENARIO_PATH")"
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
            [[ "$(suggestion_count_for_generation "$rapid_pending_generation_id")" -eq 0 ]] || { echo "stale rapid generation became visible before follow-up generation started" >&2; exit 1; }
            rapid_pending_generation_id=""
        fi
        if [[ "$expected" == "true" ]]; then
            if [[ "$rapid" == "true" ]]; then
                wait_for_count generation.started "$generation_before" 45 || { echo "rapid turn did not start generation" >&2; exit 1; }
                (( $(event_count suggestion.visible) == visible_before )) || { echo "rapid turn completed before its follow-up could start" >&2; exit 1; }
                rapid_pending_generation_id="$(latest_generation_id)"
                [[ -n "$rapid_pending_generation_id" ]] || { echo "rapid generation identity was not recorded" >&2; exit 1; }
                rapid_generation_ids+=("$rapid_pending_generation_id")
                rapid_cancellation_count=$((rapid_cancellation_count + 1))
            elif wait_for_matching_suggestion "$visible_before" "$needle" 90; then
                visible_observed=true
            fi
            observed_question="$(latest_suggestion_question)"
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
if (( rapid_cancellation_count > 0 )); then
    for generation_id in "${rapid_generation_ids[@]}"; do
        [[ "$(suggestion_count_for_generation "$generation_id")" -eq 0 ]] || { echo "stale rapid generation became visible: $generation_id" >&2; exit 1; }
    done
fi

notify finish
wait_for_count verification.finished 0 30 || true
osascript -e 'tell application id "com.langcheng.Hireva" to quit' >/dev/null 2>&1 || true
for _ in {1..40}; do
    pgrep -f "$APP_BINARY" >/dev/null || break
    sleep 0.25
done

app_count="$( (pgrep -f "$APP_BINARY" || true) | wc -l | tr -d ' ')"
helper_count="$( (pgrep -f 'parakeet_asr_helper|parakeet_asr_sidecar' || true) | wc -l | tr -d ' ')"
ready_count="$(event_count bootstrap.ready)"
buffer_count="$(event_count sck.first_buffer)"
transcript_count="$(event_count asr.transcript)"
question_count="$(event_count question.accepted)"
generation_count="$(event_count generation.started)"
visible_count="$(event_count suggestion.visible)"
false_trigger_count="$(awk -F '\t' 'NR > 1 && $9 == "true" { count++ } END { print count + 0 }' "$RESULTS")"
missing_visible_needle_count="$(evidence_missing_visible_needles "$EVENTS")"
invalid_visible_count="$(evidence_invalid_visible_count "$EVENTS")"
echo "ready=$ready_count buffers=$buffer_count transcripts=$transcript_count questions=$question_count generations=$generation_count visible=$visible_count false_triggers=$false_trigger_count rapid_cancellations=$rapid_cancellation_count missing_visible_needles=$missing_visible_needle_count invalid_visible=$invalid_visible_count"
echo "app_count=$app_count helper_count=$helper_count"
require_equal ready "$ready_count" "$EXPECTED_SESSION_COUNT"
require_equal buffers "$buffer_count" "$EXPECTED_SESSION_COUNT"
require_equal transcripts "$transcript_count" "$EXPECTED_TURN_COUNT"
require_equal questions "$question_count" "$EXPECTED_TRIGGER_COUNT"
require_equal generations "$generation_count" "$EXPECTED_TRIGGER_COUNT"
require_equal visible "$visible_count" "$EXPECTED_VISIBLE_COUNT"
require_equal false_triggers "$false_trigger_count" 0
require_equal rapid_cancellations "$rapid_cancellation_count" "$EXPECTED_RAPID_CANCELLATIONS"
require_equal missing_visible_needles "$missing_visible_needle_count" 0
require_equal invalid_visible "$invalid_visible_count" 0
require_equal app_processes "$app_count" 0
require_equal helper_processes "$helper_count" 0

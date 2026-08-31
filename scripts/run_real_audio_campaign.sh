#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MANIFEST_RELATIVE="scripts/fixtures/real_audio_campaign/manifest.json"
MANIFEST_PATH="$ROOT_DIR/$MANIFEST_RELATIVE"
FIXTURE_RELATIVE="scripts/fixtures/real_audio_campaign"
FIXTURE_PATH="$ROOT_DIR/$FIXTURE_RELATIVE"
DIALOGUE_RUNNER="$ROOT_DIR/scripts/run_real_dialogue_verification.sh"
VALIDATE_PLAN=false
ARTIFACT_DIR=""
APP_SUPPORT_DIR=""
MODEL_ROOT=""

usage() {
    echo "usage: $0 --validate-plan" >&2
    echo "       $0 --artifact-dir <fresh-absolute-path> --app-support-dir <fresh-absolute-path> --local-model-root <absolute-path>" >&2
}

if [[ $# -eq 1 && "$1" == "--validate-plan" ]]; then
    VALIDATE_PLAN=true
else
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --artifact-dir) ARTIFACT_DIR="${2:-}"; shift 2 ;;
            --app-support-dir) APP_SUPPORT_DIR="${2:-}"; shift 2 ;;
            --local-model-root) MODEL_ROOT="${2:-}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
        esac
    done
    [[ -n "$ARTIFACT_DIR" && -n "$APP_SUPPORT_DIR" && -n "$MODEL_ROOT" ]] || {
        usage
        exit 2
    }
fi

for command_name in git jq ruby shasum; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "required command is unavailable: $command_name" >&2
        exit 2
    }
done
[[ -x "$DIALOGUE_RUNNER" && ! -L "$DIALOGUE_RUNNER" ]] || {
    echo "real-dialogue runner is unavailable or not executable" >&2
    exit 2
}

resolve_new_directory() {
    local input="$1" parent base
    [[ "$input" == /* && ! -e "$input" && ! -L "$input" ]] || return 1
    base="$(basename "$input")"
    [[ -n "$base" && "$base" != "." && "$base" != ".." && "$base" != "/" ]] || return 1
    parent="$(cd -P "$(dirname "$input")" && pwd)" || return 1
    printf '%s/%s\n' "$parent" "$base"
}

require_clean_tracked_file() {
    local relative_path="$1"
    git -C "$ROOT_DIR" ls-files --error-unmatch "$relative_path" >/dev/null 2>&1 || return 1
    git -C "$ROOT_DIR" diff --quiet -- "$relative_path" || return 1
    git -C "$ROOT_DIR" diff --cached --quiet -- "$relative_path" || return 1
}

validate_manifest_and_plan() {
    [[ -f "$MANIFEST_PATH" && ! -L "$MANIFEST_PATH" ]] || {
        echo "real-audio campaign manifest is unavailable" >&2
        return 1
    }
    require_clean_tracked_file "$MANIFEST_RELATIVE" || {
        echo "real-audio campaign manifest must be tracked and clean" >&2
        return 1
    }
    jq -e '
        .synthetic == true and
        .schemaVersion == 1 and
        .generator == "scripts/generate_real_audio_campaign_fixtures.rb" and
        .coverage.roleFamilies == 16 and
        (.coverage.candidateProfiles | length) == 10 and
        .coverage.opportunityContexts == 16 and
        .coverage.sessions == 16 and
        .coverage.turns == 128 and
        .coverage.triggerTurns == 80 and
        .coverage.rejectTurns == 48 and
        .coverage.rapidTransitions == 16 and
        (.sourceFiles | length) == 6 and
        all(.sourceFiles[];
            (.path | type) == "string" and
            (.sha256 | test("^[a-f0-9]{64}$"))
        ) and
        (.scenarios | length) == 16 and
        ([.scenarios[].filename] | unique | length) == 16 and
        ([.scenarios[].roleFamilyID] | unique | length) == 16 and
        ([.scenarios[].sessionID] | unique | length) == 16 and
        all(.scenarios[];
            (.filename | test("^role-[0-9]{2}-[a-z0-9_]+[.]json$")) and
            (.sha256 | test("^[a-f0-9]{64}$")) and
            .turns == 8 and .triggerTurns == 5 and .rejectTurns == 3 and
            .rapidTransitions == 1
        )
    ' "$MANIFEST_PATH" >/dev/null || {
        echo "real-audio campaign manifest violates the reviewed coverage contract" >&2
        return 1
    }

    local source_path expected_sha source_relative actual_sha
    while IFS=$'\t' read -r source_path expected_sha; do
        [[ "$source_path" == Tests/HirevaTests/Fixtures/InterviewCampaign/*.json &&
           "$source_path" != *".."* &&
           "$expected_sha" =~ ^[a-f0-9]{64}$ ]] || {
            echo "manifest source binding is invalid" >&2
            return 1
        }
        source_relative="$source_path"
        [[ -f "$ROOT_DIR/$source_relative" && ! -L "$ROOT_DIR/$source_relative" ]] || {
            echo "manifest source fixture is unavailable" >&2
            return 1
        }
        require_clean_tracked_file "$source_relative" || {
            echo "manifest source fixture must be tracked and clean" >&2
            return 1
        }
        actual_sha="$(/usr/bin/shasum -a 256 "$ROOT_DIR/$source_relative" | /usr/bin/awk '{print $1}')"
        [[ "$actual_sha" == "$expected_sha" ]] || {
            echo "manifest source fixture digest mismatch" >&2
            return 1
        }
    done < <(jq -r '.sourceFiles[] | [.path, .sha256] | @tsv' "$MANIFEST_PATH")

    local filename scenario_path
    while IFS= read -r filename; do
        scenario_path="$FIXTURE_PATH/$filename"
        [[ -f "$scenario_path" && ! -L "$scenario_path" ]] || {
            echo "approved campaign scenario is unavailable" >&2
            return 1
        }
        "$DIALOGUE_RUNNER" --validate-approved-scenario "$scenario_path" >/dev/null || return 1
    done < <(jq -r '.scenarios[].filename' "$MANIFEST_PATH")

    printf 'REAL_AUDIO_CAMPAIGN_PLAN=valid\n'
    printf 'REAL_AUDIO_SCENARIOS=%s\n' "$(jq -r '.coverage.sessions' "$MANIFEST_PATH")"
    printf 'REAL_AUDIO_TURNS=%s\n' "$(jq -r '.coverage.turns' "$MANIFEST_PATH")"
    printf 'REAL_AUDIO_TRIGGERS=%s\n' "$(jq -r '.coverage.triggerTurns' "$MANIFEST_PATH")"
    printf 'REAL_AUDIO_REJECTS=%s\n' "$(jq -r '.coverage.rejectTurns' "$MANIFEST_PATH")"
}

validate_manifest_and_plan
[[ "$VALIDATE_PLAN" == "false" ]] || exit 0

ARTIFACT_DIR="$(resolve_new_directory "$ARTIFACT_DIR")" || {
    echo "artifact directory must be a fresh absolute non-symlink path with an existing parent" >&2
    exit 2
}
APP_SUPPORT_DIR="$(resolve_new_directory "$APP_SUPPORT_DIR")" || {
    echo "app support directory must be a fresh absolute non-symlink path with an existing parent" >&2
    exit 2
}
[[ -d "$MODEL_ROOT" && ! -L "$MODEL_ROOT" ]] || {
    echo "local model root must be an existing non-symlink directory" >&2
    exit 2
}
MODEL_ROOT="$(cd -P "$MODEL_ROOT" && pwd)"
case "$ARTIFACT_DIR/" in "$ROOT_DIR/"*) echo "artifacts must remain outside the repository" >&2; exit 2;; esac
case "$APP_SUPPORT_DIR/" in "$ROOT_DIR/"*) echo "app support must remain outside the repository" >&2; exit 2;; esac
case "$ARTIFACT_DIR/" in "$APP_SUPPORT_DIR/"*) echo "artifact and app support roots must not contain one another" >&2; exit 2;; esac
case "$APP_SUPPORT_DIR/" in "$ARTIFACT_DIR/"*) echo "artifact and app support roots must not contain one another" >&2; exit 2;; esac
PRODUCTION_SUPPORT_ROOT="$HOME/Library/Application Support/Hireva"
case "$APP_SUPPORT_DIR/" in "$PRODUCTION_SUPPORT_ROOT/"*) echo "campaign app support must not use production user data" >&2; exit 2;; esac

/bin/mkdir -m 700 "$ARTIFACT_DIR" "$APP_SUPPORT_DIR"
/bin/mkdir -m 700 "$ARTIFACT_DIR/logs"
RESULTS_PATH="$ARTIFACT_DIR/matrix_results.jsonl"
SUMMARY_PATH="$ARTIFACT_DIR/matrix_summary.json"
RUNS_PATH="$ARTIFACT_DIR/matrix_runs.tsv"
printf 'index\trole_family\tscenario\tstatus\texit_code\n' > "$RUNS_PATH"
: > "$RESULTS_PATH"

STARTED_AT="$(/usr/bin/ruby -rtime -e 'puts Time.now.utc.iso8601(6)')"
COMPLETED_RUNS=0
SCENARIO_COUNT="$(jq -r '.scenarios | length' "$MANIFEST_PATH")"

for ((scenario_index=0; scenario_index<SCENARIO_COUNT; scenario_index++)); do
    filename="$(jq -r ".scenarios[$scenario_index].filename" "$MANIFEST_PATH")"
    role_family="$(jq -r ".scenarios[$scenario_index].roleFamilyID" "$MANIFEST_PATH")"
    scenario_path="$FIXTURE_PATH/$filename"
    run_label="$(printf 'run-%02d-%s' "$((scenario_index + 1))" "$role_family")"
    run_artifacts="$ARTIFACT_DIR/$run_label"
    run_support="$APP_SUPPORT_DIR/$run_label"
    run_log="$ARTIFACT_DIR/logs/$run_label.log"

    set +e
    /bin/bash "$DIALOGUE_RUNNER" "$scenario_path" "$run_artifacts" "$run_support" "$MODEL_ROOT" \
        2>&1 | /usr/bin/tee "$run_log"
    run_status=${PIPESTATUS[0]}
    set -e

    if [[ "$run_status" -eq 0 ]]; then
        run_result="passed"
        COMPLETED_RUNS=$((COMPLETED_RUNS + 1))
    else
        run_result="failed"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$((scenario_index + 1))" "$role_family" "$filename" "$run_result" "$run_status" >> "$RUNS_PATH"
    jq -cn \
        --argjson index "$((scenario_index + 1))" \
        --arg roleFamily "$role_family" \
        --arg scenario "$filename" \
        --arg status "$run_result" \
        --argjson exitCode "$run_status" \
        '{index: $index, roleFamily: $roleFamily, scenario: $scenario, status: $status, exitCode: $exitCode}' \
        >> "$RESULTS_PATH"

    if [[ "$run_status" -ne 0 ]]; then
        FINISHED_AT="$(/usr/bin/ruby -rtime -e 'puts Time.now.utc.iso8601(6)')"
        jq -n \
            --arg startedAt "$STARTED_AT" \
            --arg finishedAt "$FINISHED_AT" \
            --arg status "failed" \
            --argjson plannedRuns "$SCENARIO_COUNT" \
            --argjson completedRuns "$COMPLETED_RUNS" \
            --arg failedScenario "$filename" \
            '{startedAt: $startedAt, finishedAt: $finishedAt, status: $status, plannedRuns: $plannedRuns, completedRuns: $completedRuns, failedScenario: $failedScenario}' \
            > "$SUMMARY_PATH"
        exit "$run_status"
    fi
done

APP_COUNT="$( { pgrep -f "$ROOT_DIR/dist/Hireva.app/Contents/MacOS/Hireva" 2>/dev/null || true; } | wc -l | tr -d ' ')"
HELPER_COUNT="$( { pgrep -f "$ROOT_DIR/dist/Hireva.app/Contents/Helpers/parakeet_asr_helper" 2>/dev/null || true; } | wc -l | tr -d ' ')"
[[ "$APP_COUNT" -eq 0 && "$HELPER_COUNT" -eq 0 ]] || {
    echo "real-audio campaign ended with a residual owned process" >&2
    exit 1
}

FINISHED_AT="$(/usr/bin/ruby -rtime -e 'puts Time.now.utc.iso8601(6)')"
jq -n \
    --arg startedAt "$STARTED_AT" \
    --arg finishedAt "$FINISHED_AT" \
    --arg status "passed" \
    --argjson plannedRuns "$SCENARIO_COUNT" \
    --argjson completedRuns "$COMPLETED_RUNS" \
    --argjson turns "$(jq -r '.coverage.turns' "$MANIFEST_PATH")" \
    --argjson triggers "$(jq -r '.coverage.triggerTurns' "$MANIFEST_PATH")" \
    --argjson rejects "$(jq -r '.coverage.rejectTurns' "$MANIFEST_PATH")" \
    --argjson appCount "$APP_COUNT" \
    --argjson helperCount "$HELPER_COUNT" \
    '{startedAt: $startedAt, finishedAt: $finishedAt, status: $status, plannedRuns: $plannedRuns, completedRuns: $completedRuns, turns: $turns, triggers: $triggers, rejects: $rejects, appCount: $appCount, helperCount: $helperCount}' \
    > "$SUMMARY_PATH"
printf 'REAL_AUDIO_CAMPAIGN=passed runs=%s turns=%s triggers=%s rejects=%s app_count=%s helper_count=%s\n' \
    "$COMPLETED_RUNS" \
    "$(jq -r '.coverage.turns' "$MANIFEST_PATH")" \
    "$(jq -r '.coverage.triggerTurns' "$MANIFEST_PATH")" \
    "$(jq -r '.coverage.rejectTurns' "$MANIFEST_PATH")" \
    "$APP_COUNT" "$HELPER_COUNT"

#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/Hireva.app"
APP_BINARY="$ROOT_DIR/dist/Hireva.app/Contents/MacOS/Hireva"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
DB_PATH="$HOME/Library/Application Support/Hireva/hireva.sqlite"
TOTAL_STARTED_AT="$(date +%s)"

STEP_NAMES=()
STEP_RESULTS=()
STEP_SECONDS=()
STEP_EXIT_CODES=()
STEP_LOG_PATHS=()
OVERALL_STATUS=0

print_summary() {
    local total_elapsed
    total_elapsed=$(($(date +%s) - TOTAL_STARTED_AT))

    echo ""
    echo "======================================================================"
    echo "Runtime Stability Gate"
    echo "======================================================================"
    local index
    for index in "${!STEP_NAMES[@]}"; do
        printf "%s: %s\n" "${STEP_NAMES[$index]}" "${STEP_RESULTS[$index]}"
        printf "  exit: %s, elapsed: %ss\n" "${STEP_EXIT_CODES[$index]}" "${STEP_SECONDS[$index]}"
        printf "  log: %s\n" "${STEP_LOG_PATHS[$index]}"
    done
    if [[ "$OVERALL_STATUS" -eq 0 ]]; then
        echo "overall: PASS"
    else
        echo "overall: FAIL"
    fi
    echo "Total elapsed: ${total_elapsed}s"
    echo "Expected DB: $DB_PATH"
}

print_failure_diagnostics() {
    local label="$1"
    local log_path="$2"
    local relevant_pattern='failed|FAILED|Issue recorded|XCTAssert|Expectation failed|timeout|timed out|persistence|queue|Runtime|error:'
    local failing_test_pattern='✘ Test .* (recorded an issue|failed)|Test Case .* failed|error:.*test'

    echo "Step failed: $label" >&2
    echo "Full log: $log_path" >&2
    echo "Failing tests:" >&2
    if ! grep -E "$failing_test_pattern" "$log_path" | tail -n 40 >&2; then
        echo "  (no failing test name found in this step log)" >&2
    fi
    echo "Last 80 relevant lines:" >&2
    if ! grep -E "$relevant_pattern" "$log_path" | tail -n 80 >&2; then
        tail -n 80 "$log_path" >&2 || true
    fi
}

run_step() {
    local label="$1"
    shift
    local started_at
    local elapsed
    local status
    local safe_label
    local log_path
    started_at="$(date +%s)"
    safe_label="$(printf '%s' "$label" | tr '[:upper:] /' '[:lower:]__' | tr -cd '[:alnum:]_-')"
    log_path="/tmp/runtime_stability_${safe_label}_$(date -u +%Y%m%dT%H%M%SZ)_$$.log"

    echo ""
    echo "======================================================================"
    echo "[START] $label"
    echo "======================================================================"

    "$@" 2>&1 | tee "$log_path"
    status=${PIPESTATUS[0]}
    if [[ "$status" -eq 0 ]]; then
        STEP_RESULTS+=("PASS")
    else
        STEP_RESULTS+=("FAIL")
    fi

    elapsed=$(($(date +%s) - started_at))
    STEP_NAMES+=("$label")
    STEP_SECONDS+=("$elapsed")
    STEP_EXIT_CODES+=("$status")
    STEP_LOG_PATHS+=("$log_path")

    if [[ "$status" -ne 0 ]]; then
        echo "[FAIL] $label (${elapsed}s)" >&2
        print_failure_diagnostics "$label" "$log_path"
        OVERALL_STATUS=1
        return 0
    fi

    echo "[PASS] $label (${elapsed}s)"
}

run_build_and_run_verification() {
    ./script/build_and_run.sh --verify || return $?
    print_bundle_timestamps
}

print_bundle_timestamps() {
    local build_timestamp_utc

    if [[ ! -f "$APP_BINARY" || ! -f "$INFO_PLIST" ]]; then
        echo "error: verified app bundle is incomplete at $APP_BUNDLE" >&2
        return 1
    fi

    stat -f "%Sm  %N" "$APP_BUNDLE"
    stat -f "%Sm  %N" "$APP_BINARY"
    if ! build_timestamp_utc="$(/usr/libexec/PlistBuddy -c 'Print :HirevaBuildTimestampUTC' "$INFO_PLIST")"; then
        echo "error: HirevaBuildTimestampUTC is missing from $INFO_PLIST" >&2
        return 1
    fi
    echo "HirevaBuildTimestampUTC: $build_timestamp_utc"
}

cd "$ROOT_DIR" || {
    echo "error: cannot enter repository root: $ROOT_DIR" >&2
    exit 1
}

run_step "Swift build" swift build
run_step "Swift test" swift test
run_step "runtime_smoke" ./scripts/runtime_smoke.sh --suite all
run_step "build_and_run verify" run_build_and_run_verification

print_summary
if [[ "$OVERALL_STATUS" -eq 0 ]]; then
    echo ""
    echo "Manual reminder: real System Audio smoke is still required after risky"
    echo "audio, ASR callback, transcript UI, queue, persistence, or provider-streaming changes."
fi
exit "$OVERALL_STATUS"

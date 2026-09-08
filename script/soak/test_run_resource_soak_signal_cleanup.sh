#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RUNNER="$ROOT_DIR/script/soak/run_resource_soak.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hireva-resource-signal-test.XXXXXX")"
TARGET="/usr/bin/tail"
OUTPUT="$TEST_ROOT/resource_metrics.csv"
RUNNER_PID=""
TARGET_PID=""

owned_children() {
    local parent_pid="$1"
    pgrep -P "$parent_pid" 2>/dev/null || true
}

process_is_running() {
    local pid="$1" process_state
    process_state="$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$process_state" && "$process_state" != Z* ]]
}

stop_owned_processes() {
    local child_pid
    if [[ -n "$RUNNER_PID" ]] && kill -0 "$RUNNER_PID" 2>/dev/null; then
        while IFS= read -r child_pid; do
            [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
            kill -TERM "$child_pid" 2>/dev/null || true
        done < <(owned_children "$RUNNER_PID")
        kill -TERM "$RUNNER_PID" 2>/dev/null || true
        local deadline=$((SECONDS + 5))
        while kill -0 "$RUNNER_PID" 2>/dev/null && (( SECONDS < deadline )); do
            sleep 0.1
        done
        while IFS= read -r child_pid; do
            [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
            kill -KILL "$child_pid" 2>/dev/null || true
        done < <(owned_children "$RUNNER_PID")
        kill -KILL "$RUNNER_PID" 2>/dev/null || true
        wait "$RUNNER_PID" 2>/dev/null || true
    fi
    if [[ -n "$TARGET_PID" ]] && kill -0 "$TARGET_PID" 2>/dev/null; then
        kill -TERM "$TARGET_PID" 2>/dev/null || true
        wait "$TARGET_PID" 2>/dev/null || true
    fi
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    stop_owned_processes
    if [[ "$TEST_ROOT" == "${TMPDIR:-/tmp}/hireva-resource-signal-test."* ]]; then
        rm -rf "$TEST_ROOT"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$TARGET" -f /dev/null &
TARGET_PID=$!

/bin/bash "$RUNNER" \
    --output "$OUTPUT" \
    --process-name "$(basename "$TARGET")" \
    --process-path "$TARGET" \
    --interval 5 \
    --duration 300 \
    --minimum-coverage 0.1 \
    --max-collection-errors 20 \
    --missing-app-limit 24 \
    > "$TEST_ROOT/runner.log" 2>&1 &
RUNNER_PID=$!

COLLECTOR_PID=""
for ((attempt=0; attempt<160; attempt++)); do
    while IFS= read -r child_pid; do
        [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
        child_command="$(ps -p "$child_pid" -o command= 2>/dev/null || true)"
        case "$child_command" in
            *'/resource_metrics --output '*"$OUTPUT"*) COLLECTOR_PID="$child_pid" ;;
        esac
    done < <(owned_children "$RUNNER_PID")
    if [[ -n "$COLLECTOR_PID" ]]; then
        break
    fi
    if ! kill -0 "$RUNNER_PID" 2>/dev/null; then
        break
    fi
    sleep 0.25
done

[[ -n "$COLLECTOR_PID" ]] || {
    echo "resource signal regression setup did not observe owned collector" >&2
    tail -40 "$TEST_ROOT/runner.log" >&2 || true
    exit 1
}

kill -TERM "$RUNNER_PID"
deadline=$((SECONDS + 10))
while process_is_running "$RUNNER_PID" && (( SECONDS < deadline )); do
    sleep 0.1
done
if process_is_running "$RUNNER_PID"; then
    echo "resource sampler did not terminate within 10 seconds of TERM" >&2
    ps -p "$RUNNER_PID","$COLLECTOR_PID","$TARGET_PID" -o pid=,ppid=,stat=,etime=,command= >&2 || true
    tail -40 "$TEST_ROOT/runner.log" >&2 || true
    exit 1
fi

set +e
wait "$RUNNER_PID"
runner_status=$?
set -e
RUNNER_PID=""

[[ "$runner_status" -eq 143 ]] || {
    echo "resource sampler TERM exit mismatch: actual=$runner_status expected=143" >&2
    exit 1
}
if kill -0 "$COLLECTOR_PID" 2>/dev/null; then
    echo "owned resource collector remained after TERM: pid=$COLLECTOR_PID" >&2
    exit 1
fi
if ! kill -0 "$TARGET_PID" 2>/dev/null; then
    echo "resource sampler unexpectedly terminated the independently owned target" >&2
    exit 1
fi

echo "resource sampler TERM cleanup passed"

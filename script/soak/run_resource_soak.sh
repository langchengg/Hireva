#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/Hireva/Services/SoakResourceMetrics.swift"
MAIN_FILE="$ROOT_DIR/script/soak/ResourceMetricsMain.swift"
OUTPUT_DIR="${TMPDIR:-/tmp}/HirevaSoakMetrics"
OUTPUT="$OUTPUT_DIR/resource-metrics-$(date -u +%Y%m%dT%H%M%SZ).csv"
PROCESS_NAME="Hireva"
PROCESS_PATH=""
DATABASE=""
TRACE=""
LIFECYCLE_METRICS=""
INTERVAL="5"
DURATION="300"
MAX_BYTES="$((5 * 1024 * 1024))"
MAX_FILES="4"
MINIMUM_COVERAGE="0.9"
MAX_COLLECTION_ERRORS="3"
MISSING_APP_LIMIT="3"
HELPER_NAMES=()
HELPER_PATHS=()
SOAK_COMMAND=()

usage() {
    cat <<'USAGE'
Usage: bash script/soak/run_resource_soak.sh [options] [-- command [args...]]

Options:
  --output PATH          Metrics CSV path (default: a timestamped file under TMPDIR)
  --process-name NAME    Exact app executable basename (default: Hireva)
  --process-path PATH    Exact verification app executable path
  --database PATH        Runtime SQLite path measured read-only
  --trace PATH           Runtime trace base path measured by size only
  --lifecycle-metrics PATH
                         Bounded numeric lifecycle summary
  --interval SECONDS     Sampling interval from 5 through 10 (default: 5)
  --duration SECONDS     Bounded duration up to 86400 (default: 300)
  --max-bytes BYTES      Per-file CSV cap (default: 5242880)
  --max-files COUNT      Active plus rotated file cap (default: 4)
  --minimum-coverage N   Exact-target sample ratio (default: 0.9)
  --max-collection-errors COUNT
                         Maximum collection failures (default: 3)
  --missing-app-limit COUNT
                         Consecutive missing samples before failure (default: 3)
  --helper-name NAME     Additional helper executable basename; may be repeated
  --helper-path PATH     Exact helper executable path; may be repeated
  --help                 Show this message

The optional command is started for this isolated run. On exit, the runner only
terminates that command wrapper if it is still active; it never kills processes
discovered by name. CSV output contains numeric metrics and timestamps only.
Database, trace, and lifecycle inputs are disabled unless explicit isolated
paths are supplied; the script never defaults to a real user's support root.
The collector exits nonzero unless exactly one target process meets the required
sample coverage and error limits.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        --process-name) PROCESS_NAME="$2"; shift 2 ;;
        --process-path) PROCESS_PATH="$2"; shift 2 ;;
        --database) DATABASE="$2"; shift 2 ;;
        --trace) TRACE="$2"; shift 2 ;;
        --lifecycle-metrics) LIFECYCLE_METRICS="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --max-bytes) MAX_BYTES="$2"; shift 2 ;;
        --max-files) MAX_FILES="$2"; shift 2 ;;
        --minimum-coverage) MINIMUM_COVERAGE="$2"; shift 2 ;;
        --max-collection-errors) MAX_COLLECTION_ERRORS="$2"; shift 2 ;;
        --missing-app-limit) MISSING_APP_LIMIT="$2"; shift 2 ;;
        --helper-name) HELPER_NAMES+=("$2"); shift 2 ;;
        --helper-path) HELPER_PATHS+=("$2"); shift 2 ;;
        --help) usage; exit 0 ;;
        --) shift; SOAK_COMMAND=("$@"); break ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

SQLITE3_PATH="$(command -v sqlite3 || true)"
if [[ -z "$SQLITE3_PATH" ]]; then
    echo "error: sqlite3 is required for count-only database metrics" >&2
    exit 1
fi
LSOF_PATH="$(command -v lsof || true)"

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hireva-resource-metrics.XXXXXX")"
COLLECTOR="$BUILD_DIR/resource_metrics"
COMMAND_PID=""

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -n "$COMMAND_PID" ]]; then
        if kill -0 "$COMMAND_PID" 2>/dev/null; then
            kill "$COMMAND_PID" 2>/dev/null || true
        fi
        wait "$COMMAND_PID" 2>/dev/null || true
    fi
    rm -rf "$BUILD_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

xcrun swiftc -parse-as-library "$SOURCE_FILE" "$MAIN_FILE" -o "$COLLECTOR"

if [[ ${#SOAK_COMMAND[@]} -gt 0 ]]; then
    "${SOAK_COMMAND[@]}" &
    COMMAND_PID=$!
fi

COLLECTOR_ARGS=(
    --output "$OUTPUT"
    --process-name "$PROCESS_NAME"
    --sqlite3 "$SQLITE3_PATH"
    --interval "$INTERVAL"
    --duration "$DURATION"
    --max-bytes "$MAX_BYTES"
    --max-files "$MAX_FILES"
    --minimum-coverage "$MINIMUM_COVERAGE"
    --max-collection-errors "$MAX_COLLECTION_ERRORS"
    --missing-app-limit "$MISSING_APP_LIMIT"
)
if [[ -n "$PROCESS_PATH" ]]; then
    COLLECTOR_ARGS+=(--process-path "$PROCESS_PATH")
fi
if [[ -n "$DATABASE" ]]; then
    COLLECTOR_ARGS+=(--database "$DATABASE")
fi
if [[ -n "$TRACE" ]]; then
    COLLECTOR_ARGS+=(--trace "$TRACE")
fi
if [[ -n "$LIFECYCLE_METRICS" ]]; then
    COLLECTOR_ARGS+=(--lifecycle-metrics "$LIFECYCLE_METRICS")
fi
if [[ -n "$LSOF_PATH" ]]; then
    COLLECTOR_ARGS+=(--lsof "$LSOF_PATH")
fi
for helper_name in "${HELPER_NAMES[@]}"; do
    COLLECTOR_ARGS+=(--helper-name "$helper_name")
done
for helper_path in "${HELPER_PATHS[@]}"; do
    COLLECTOR_ARGS+=(--helper-path "$helper_path")
done

"$COLLECTOR" "${COLLECTOR_ARGS[@]}"

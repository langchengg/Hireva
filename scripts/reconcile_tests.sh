#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/reconcile_tests.sh OUTPUT_DIRECTORY

Runs an isolated SwiftPM discovery and test pass, then executes every hermetic
RuntimeSmoke body in a separate lane. It preserves raw and xUnit evidence and
emits reconciled CSV tables. The output directory must not already exist.

Real provider tests that require Ollama, Parakeet model files, a remote API,
Keychain, or a production database remain separate release-matrix checks; this
script deliberately clears their opt-in variables.
USAGE
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIRECTORY="$1"
if [[ "$OUTPUT_DIRECTORY" != /* ]]; then
  OUTPUT_DIRECTORY="$PWD/$OUTPUT_DIRECTORY"
fi
if [[ -e "$OUTPUT_DIRECTORY" ]]; then
  echo "error: output directory already exists: $OUTPUT_DIRECTORY" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIRECTORY"
ISOLATED_HOME="$(mktemp -d /tmp/hireva-test-home.XXXXXX)"
SCRATCH_PATH="${HIREVA_TEST_SCRATCH_PATH:-$(mktemp -d /tmp/hireva-test-scratch.XXXXXX)}"
LIST_LOG="$OUTPUT_DIRECTORY/swift-test-list.log"
TEST_LOG="$OUTPUT_DIRECTORY/swift-test.log"
XUNIT_PATH="$OUTPUT_DIRECTORY/swift-test.xml"
STATUS_PATH="$OUTPUT_DIRECTORY/test-status.csv"
RUNTIME_LIST_LOG="$OUTPUT_DIRECTORY/runtime-smoke-list.log"
RUNTIME_TEST_LOG="$OUTPUT_DIRECTORY/runtime-smoke.log"
RUNTIME_XUNIT_PATH="$OUTPUT_DIRECTORY/runtime-smoke.xml"
RUNTIME_STATUS_PATH="$OUTPUT_DIRECTORY/runtime-smoke-status.csv"
SUMMARY_PATH="$OUTPUT_DIRECTORY/reconciliation-summary.txt"

COMMON_ARGUMENTS=(
  --scratch-path "$SCRATCH_PATH"
  --disable-keychain
  --disable-netrc
  --only-use-versions-from-resolved-file
)
SAFE_ENV=(
  env
  -u REAL_APP_DB_TESTS
  -u DEEPSEEK_API_KEY
  -u HIREVA_REAL_OLLAMA_SMOKE
  -u RUN_LOCAL_QWEN_EXTRACTION_TEST
  -u HIREVA_REAL_PARAKEET_STREAM_TEST
  CFFIXED_USER_HOME="$ISOLATED_HOME"
)

cd "$ROOT_DIR"
{
  swift --version
  sw_vers
  uname -m
  printf 'git_revision='
  git rev-parse HEAD
  printf 'git_status_begin\n'
  git status --porcelain=v1
  printf 'git_status_end\n'
  printf 'scratch_path=%s\n' "$SCRATCH_PATH"
} > "$OUTPUT_DIRECTORY/environment.txt"

set +e
"${SAFE_ENV[@]}" RUNTIME_SMOKE_SUITE=none swift test "${COMMON_ARGUMENTS[@]}" list 2>&1 | tee "$LIST_LOG"
LIST_EXIT=${PIPESTATUS[0]}
set -e
if [[ "$LIST_EXIT" -ne 0 ]]; then
  echo "error: swift test list failed with exit $LIST_EXIT" >&2
  exit "$LIST_EXIT"
fi

set +e
"${SAFE_ENV[@]}" RUNTIME_SMOKE_SUITE=none swift test "${COMMON_ARGUMENTS[@]}" --xunit-output "$XUNIT_PATH" 2>&1 | tee "$TEST_LOG"
TEST_EXIT=${PIPESTATUS[0]}
set -e

set +e
/usr/bin/ruby "$ROOT_DIR/scripts/reconcile_test_results.rb" \
  "$LIST_LOG" "$XUNIT_PATH" "$STATUS_PATH" 2>&1 | tee "$SUMMARY_PATH"
RECONCILIATION_EXIT=${PIPESTATUS[0]}
set -e

grep '^HirevaTests\.RuntimeSmokeHarnessTests/' "$LIST_LOG" > "$RUNTIME_LIST_LOG"
set +e
"${SAFE_ENV[@]}" RUNTIME_SMOKE_SUITE=all swift test "${COMMON_ARGUMENTS[@]}" \
  --filter RuntimeSmokeHarnessTests \
  --xunit-output "$RUNTIME_XUNIT_PATH" 2>&1 | tee "$RUNTIME_TEST_LOG"
RUNTIME_TEST_EXIT=${PIPESTATUS[0]}
set -e

set +e
/usr/bin/ruby "$ROOT_DIR/scripts/reconcile_test_results.rb" \
  "$RUNTIME_LIST_LOG" "$RUNTIME_XUNIT_PATH" "$RUNTIME_STATUS_PATH" 2>&1 | tee -a "$SUMMARY_PATH"
RUNTIME_RECONCILIATION_EXIT=${PIPESTATUS[0]}
set -e

cp "$ROOT_DIR/scripts/release_test_prerequisites.tsv" "$OUTPUT_DIRECTORY/external-integration-prerequisites.tsv"
printf 'swift_test_list_exit=%s\n' "$LIST_EXIT" >> "$SUMMARY_PATH"
printf 'swift_test_exit=%s\n' "$TEST_EXIT" >> "$SUMMARY_PATH"
printf 'reconciliation_exit=%s\n' "$RECONCILIATION_EXIT" >> "$SUMMARY_PATH"
printf 'runtime_smoke_exit=%s\n' "$RUNTIME_TEST_EXIT" >> "$SUMMARY_PATH"
printf 'runtime_smoke_reconciliation_exit=%s\n' "$RUNTIME_RECONCILIATION_EXIT" >> "$SUMMARY_PATH"
printf 'external_integration_prerequisites=%s\n' "$(($(wc -l < "$ROOT_DIR/scripts/release_test_prerequisites.tsv") - 1))" >> "$SUMMARY_PATH"

if [[ "$TEST_EXIT" -ne 0 ]]; then
  exit "$TEST_EXIT"
fi
if [[ "$RECONCILIATION_EXIT" -ne 0 ]]; then
  exit "$RECONCILIATION_EXIT"
fi
if [[ "$RUNTIME_TEST_EXIT" -ne 0 ]]; then
  exit "$RUNTIME_TEST_EXIT"
fi
exit "$RUNTIME_RECONCILIATION_EXIT"

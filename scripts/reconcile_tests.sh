#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/reconcile_tests.sh OUTPUT_DIRECTORY

Runs one isolated SwiftPM discovery and test pass in which every registered
test body executes. It preserves raw and xUnit evidence and emits a reconciled
CSV table. The output directory must not already exist.

The three local integration variables and Parakeet paths listed below are
mandatory. Remote-provider checks remain separate release-matrix items and no
credential, production database, or user document is accessed by this script.
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

for required_gate in \
  HIREVA_REAL_OLLAMA_SMOKE \
  RUN_LOCAL_QWEN_EXTRACTION_TEST \
  HIREVA_REAL_PARAKEET_STREAM_TEST
do
  if [[ "${!required_gate:-}" != "1" ]]; then
    echo "error: $required_gate=1 is required; no registered test may silently no-op" >&2
    exit 2
  fi
done

for required_path in \
  HIREVA_PARAKEET_HELPER_PATH \
  HIREVA_PARAKEET_MODEL_PATH \
  HIREVA_PARAKEET_TEST_AUDIO \
  HIREVA_PARAKEET_TEST_AUDIO_PROVENANCE
do
  if [[ -z "${!required_path:-}" || ! -e "${!required_path}" ]]; then
    echo "error: $required_path must identify an existing release-test prerequisite" >&2
    exit 2
  fi
done
if [[ ! -x "$HIREVA_PARAKEET_HELPER_PATH" ]]; then
  echo "error: HIREVA_PARAKEET_HELPER_PATH must be executable" >&2
  exit 2
fi
if [[ ! -d "$HIREVA_PARAKEET_MODEL_PATH" ]]; then
  echo "error: HIREVA_PARAKEET_MODEL_PATH must be a directory" >&2
  exit 2
fi
if [[ ! -f "$HIREVA_PARAKEET_TEST_AUDIO" ]]; then
  echo "error: HIREVA_PARAKEET_TEST_AUDIO must be a synthetic audio file" >&2
  exit 2
fi
if [[ ! -f "$HIREVA_PARAKEET_TEST_AUDIO_PROVENANCE" ]]; then
  echo "error: HIREVA_PARAKEET_TEST_AUDIO_PROVENANCE must be a JSON file" >&2
  exit 2
fi
if ! PROVENANCE_VALIDATION="$(/usr/bin/ruby \
  "$ROOT_DIR/scripts/validate_synthetic_audio_provenance.rb" \
  "$HIREVA_PARAKEET_TEST_AUDIO" \
  "$HIREVA_PARAKEET_TEST_AUDIO_PROVENANCE")"; then
  echo "error: Parakeet release-test audio lacks valid synthetic provenance" >&2
  exit 2
fi

MODEL_PROBE_OUTPUT="$(mktemp /tmp/hireva-parakeet-model-probe.XXXXXX)"
if ! env -i \
  HOME="${TMPDIR:-/tmp}" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "$HIREVA_PARAKEET_HELPER_PATH" \
  --health \
  --probe-model \
  --model-dir "$HIREVA_PARAKEET_MODEL_PATH" \
  > "$MODEL_PROBE_OUTPUT" 2>/dev/null; then
  /bin/rm -f -- "$MODEL_PROBE_OUTPUT"
  echo "error: Parakeet native model probe failed" >&2
  exit 2
fi
PROBE_STATUS="$(/usr/bin/plutil -extract status raw -o - "$MODEL_PROBE_OUTPUT" 2>/dev/null || true)"
PROBE_RUNTIME_MODE="$(/usr/bin/plutil -extract runtimeMode raw -o - "$MODEL_PROBE_OUTPUT" 2>/dev/null || true)"
PROBE_SOURCE="$(/usr/bin/plutil -extract source raw -o - "$MODEL_PROBE_OUTPUT" 2>/dev/null || true)"
PROBE_MODEL_STATUS="$(/usr/bin/plutil -extract modelStatus raw -o - "$MODEL_PROBE_OUTPUT" 2>/dev/null || true)"
/bin/rm -f -- "$MODEL_PROBE_OUTPUT"
if [[ "$PROBE_STATUS" != "ok" || \
      "$PROBE_RUNTIME_MODE" != "bundled_native" || \
      "$PROBE_SOURCE" != "local_parakeet_asr" || \
      "$PROBE_MODEL_STATUS" != "ready" ]]; then
  echo "error: Parakeet native model probe returned an invalid release response" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIRECTORY"
ISOLATED_HOME="$(mktemp -d /tmp/hireva-test-home.XXXXXX)"
if [[ -n "${HIREVA_TEST_SCRATCH_PATH:-}" ]]; then
  SCRATCH_PATH="$HIREVA_TEST_SCRATCH_PATH"
  SCRATCH_PATH_OWNED=false
else
  SCRATCH_PATH="$(mktemp -d /tmp/hireva-test-scratch.XXXXXX)"
  SCRATCH_PATH_OWNED=true
fi
cleanup() {
  /bin/rm -rf -- "$ISOLATED_HOME"
  if [[ "$SCRATCH_PATH_OWNED" == "true" ]]; then
    /bin/rm -rf -- "$SCRATCH_PATH"
  fi
}
trap cleanup EXIT

LIST_LOG="$OUTPUT_DIRECTORY/swift-test-list.log"
TEST_LOG="$OUTPUT_DIRECTORY/swift-test.log"
XUNIT_PATH="$OUTPUT_DIRECTORY/swift-test.xml"
STATUS_PATH="$OUTPUT_DIRECTORY/test-status.csv"
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
  printf '%s\n' "$PROVENANCE_VALIDATION"
  printf 'parakeet_native_model_probe=passed\n'
} > "$OUTPUT_DIRECTORY/environment.txt"

set +e
"${SAFE_ENV[@]}" swift test "${COMMON_ARGUMENTS[@]}" list 2>&1 | tee "$LIST_LOG"
LIST_EXIT=${PIPESTATUS[0]}
set -e
if [[ "$LIST_EXIT" -ne 0 ]]; then
  echo "error: swift test list failed with exit $LIST_EXIT" >&2
  exit "$LIST_EXIT"
fi

set +e
"${SAFE_ENV[@]}" swift test "${COMMON_ARGUMENTS[@]}" --xunit-output "$XUNIT_PATH" 2>&1 | tee "$TEST_LOG"
TEST_EXIT=${PIPESTATUS[0]}
set -e

set +e
/usr/bin/ruby "$ROOT_DIR/scripts/reconcile_test_results.rb" \
  "$LIST_LOG" "$XUNIT_PATH" "$STATUS_PATH" \
  "$ROOT_DIR/scripts/release_test_prerequisites.tsv" 2>&1 | tee "$SUMMARY_PATH"
RECONCILIATION_EXIT=${PIPESTATUS[0]}
set -e

cp "$ROOT_DIR/scripts/release_test_prerequisites.tsv" "$OUTPUT_DIRECTORY/release-test-prerequisites.tsv"
cp "$HIREVA_PARAKEET_TEST_AUDIO_PROVENANCE" "$OUTPUT_DIRECTORY/parakeet-test-audio-provenance.json"
printf 'swift_test_list_exit=%s\n' "$LIST_EXIT" >> "$SUMMARY_PATH"
printf 'swift_test_exit=%s\n' "$TEST_EXIT" >> "$SUMMARY_PATH"
printf 'reconciliation_exit=%s\n' "$RECONCILIATION_EXIT" >> "$SUMMARY_PATH"
printf 'release_test_prerequisites=%s\n' "$(($(wc -l < "$ROOT_DIR/scripts/release_test_prerequisites.tsv") - 1))" >> "$SUMMARY_PATH"

if [[ "$TEST_EXIT" -ne 0 ]]; then
  exit "$TEST_EXIT"
fi
if [[ "$RECONCILIATION_EXIT" -ne 0 ]]; then
  exit "$RECONCILIATION_EXIT"
fi
exit 0

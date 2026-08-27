#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/reconcile_tests.sh OUTPUT_DIRECTORY

Runs one isolated SwiftPM discovery and test pass in which every registered
test body executes. It preserves raw and xUnit evidence and emits a reconciled
CSV table. The output directory must be a fresh child of an existing directory
outside the source repository.

The three local-integration gates plus an executable Parakeet helper and model
directory are mandatory. Synthetic audio, provenance, and transcript oracles
are generated inside a private run directory; callers cannot supply them.
Remote-provider checks remain separate release-matrix items, and no credential,
production database, or user document is accessed by this script.
USAGE
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_REQUESTED="$1"
OUTPUT_NAME="$(basename "$OUTPUT_REQUESTED")"
case "$OUTPUT_NAME" in
  ''|.|..|/) echo "error: output directory must name a fresh child directory" >&2; exit 2 ;;
esac
OUTPUT_PARENT_REQUESTED="$(dirname "$OUTPUT_REQUESTED")"
OUTPUT_PARENT="$(cd -P "$OUTPUT_PARENT_REQUESTED" 2>/dev/null && pwd)" || {
  echo "error: output parent directory must already exist" >&2
  exit 2
}
OUTPUT_DIRECTORY="$OUTPUT_PARENT/$OUTPUT_NAME"
if [[ -e "$OUTPUT_DIRECTORY" || -L "$OUTPUT_DIRECTORY" ]]; then
  echo "error: output directory already exists" >&2
  exit 2
fi
case "$OUTPUT_DIRECTORY/" in
  "$ROOT_DIR/"*) echo "error: reconciliation evidence must remain outside the source repository" >&2; exit 2 ;;
esac

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
  HIREVA_PARAKEET_MODEL_PATH
do
  if [[ -z "${!required_path:-}" || ! -e "${!required_path}" ]]; then
    echo "error: $required_path must identify an existing release-test prerequisite" >&2
    exit 2
  fi
done
if [[ ! -f "$HIREVA_PARAKEET_HELPER_PATH" || \
      -L "$HIREVA_PARAKEET_HELPER_PATH" || \
      ! -x "$HIREVA_PARAKEET_HELPER_PATH" ]]; then
  echo "error: HIREVA_PARAKEET_HELPER_PATH must be an executable regular file, not a symlink" >&2
  exit 2
fi
if [[ ! -d "$HIREVA_PARAKEET_MODEL_PATH" || -L "$HIREVA_PARAKEET_MODEL_PATH" ]]; then
  echo "error: HIREVA_PARAKEET_MODEL_PATH must be a directory, not a symlink" >&2
  exit 2
fi
HIREVA_PARAKEET_MODEL_PATH="$(cd "$HIREVA_PARAKEET_MODEL_PATH" && pwd -P)" || {
  echo "error: HIREVA_PARAKEET_MODEL_PATH could not be resolved" >&2
  exit 2
}

MODEL_FILE_NAMES=(encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt)
for model_file_name in "${MODEL_FILE_NAMES[@]}"; do
  model_file="$HIREVA_PARAKEET_MODEL_PATH/$model_file_name"
  if [[ ! -f "$model_file" || -L "$model_file" ]]; then
    echo "error: Parakeet model requires regular, non-symlink file $model_file_name" >&2
    exit 2
  fi
done

# The caller must never control release-test audio, provenance, or transcript
# oracles. Remove inherited values before generating the fixture in our run root.
unset HIREVA_PARAKEET_TEST_AUDIO
unset HIREVA_PARAKEET_TEST_AUDIO_PROVENANCE
unset HIREVA_SYNTHETIC_AUDIO_VOICE
unset HIREVA_SYNTHETIC_AUDIO_RATE
unset HIREVA_TEST_SCRATCH_PATH

RUN_ROOT="$(/usr/bin/mktemp -d /tmp/hireva-reconcile.XXXXXX)"
ISOLATED_HOME="$RUN_ROOT/home"
ISOLATED_TMP="$RUN_ROOT/tmp"
HELPER_BOUNDARY="$RUN_ROOT/parakeet-runtime"
SYNTHETIC_PARENT="$RUN_ROOT/synthetic"
SCRATCH_PATH_OWNED=true
cleanup() {
  if [[ -n "${RUN_ROOT:-}" && -d "$RUN_ROOT" ]]; then
    /bin/chmod -R u+w "$RUN_ROOT" 2>/dev/null || true
    /bin/rm -rf -- "$RUN_ROOT"
  fi
}
trap cleanup EXIT
/bin/mkdir -m 700 "$ISOLATED_HOME" "$ISOLATED_TMP" "$HELPER_BOUNDARY" "$SYNTHETIC_PARENT"

runtime_content_fingerprint() {
  local helper_path="$1"
  local frameworks_path="$2"
  local observations
  local file_path
  local relative_path
  local file_sha256

  file_sha256="$(/usr/bin/shasum -a 256 "$helper_path" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 1
  observations="${file_sha256}|Helpers/parakeet_asr_helper"$'\n'
  if [[ -n "$frameworks_path" ]]; then
    while IFS= read -r file_path; do
      relative_path="${file_path#"$frameworks_path"/}"
      file_sha256="$(/usr/bin/shasum -a 256 "$file_path" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 1
      observations+="${file_sha256}|Frameworks/${relative_path}"$'\n'
    done < <(/usr/bin/find "$frameworks_path" -type f -print | LC_ALL=C /usr/bin/sort)
  fi
  printf '%s' "$observations" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

SOURCE_HELPER_DIRECTORY="$(cd "$(dirname "$HIREVA_PARAKEET_HELPER_PATH")" && pwd -P)"
SOURCE_HELPER="$SOURCE_HELPER_DIRECTORY/$(basename "$HIREVA_PARAKEET_HELPER_PATH")"
SOURCE_FRAMEWORKS=""
if [[ "$(basename "$SOURCE_HELPER_DIRECTORY")" == "Helpers" && \
      -d "$(dirname "$SOURCE_HELPER_DIRECTORY")/Frameworks" ]]; then
  SOURCE_FRAMEWORKS="$(dirname "$SOURCE_HELPER_DIRECTORY")/Frameworks"
  if [[ -L "$SOURCE_FRAMEWORKS" || \
        -n "$(/usr/bin/find "$SOURCE_FRAMEWORKS" -type l -print -quit)" ]]; then
    echo "error: Parakeet helper frameworks must not contain symlinks" >&2
    exit 2
  fi
fi

SOURCE_RUNTIME_FINGERPRINT_BEFORE="$(runtime_content_fingerprint "$SOURCE_HELPER" "$SOURCE_FRAMEWORKS")" || {
  echo "error: failed to fingerprint the Parakeet helper runtime" >&2
  exit 2
}
/bin/mkdir "$HELPER_BOUNDARY/Helpers"
SNAPSHOT_HELPER="$HELPER_BOUNDARY/Helpers/parakeet_asr_helper"
/bin/cp -p "$SOURCE_HELPER" "$SNAPSHOT_HELPER"
SNAPSHOT_FRAMEWORKS=""
if [[ -n "$SOURCE_FRAMEWORKS" ]]; then
  /bin/cp -R -p "$SOURCE_FRAMEWORKS" "$HELPER_BOUNDARY/Frameworks"
  SNAPSHOT_FRAMEWORKS="$HELPER_BOUNDARY/Frameworks"
fi
SOURCE_RUNTIME_FINGERPRINT_AFTER="$(runtime_content_fingerprint "$SOURCE_HELPER" "$SOURCE_FRAMEWORKS")" || {
  echo "error: failed to recheck the Parakeet helper runtime" >&2
  exit 2
}
SNAPSHOT_RUNTIME_CONTENT_FINGERPRINT="$(runtime_content_fingerprint "$SNAPSHOT_HELPER" "$SNAPSHOT_FRAMEWORKS")" || {
  echo "error: failed to fingerprint the private Parakeet helper snapshot" >&2
  exit 2
}
if [[ "$SOURCE_RUNTIME_FINGERPRINT_BEFORE" != "$SOURCE_RUNTIME_FINGERPRINT_AFTER" || \
      "$SOURCE_RUNTIME_FINGERPRINT_BEFORE" != "$SNAPSHOT_RUNTIME_CONTENT_FINGERPRINT" ]]; then
  echo "error: Parakeet helper runtime changed while it was being snapshotted" >&2
  exit 2
fi
/bin/chmod -R a-w "$HELPER_BOUNDARY"

# The model is about 640 MB, so duplicating it for every reconciliation pass is
# intentionally avoided. Keep all four source inodes open, then combine each
# path/descriptor stat identity with a full SHA-256 before and after every stage.
exec 6<"$HIREVA_PARAKEET_MODEL_PATH/encoder.int8.onnx"
exec 7<"$HIREVA_PARAKEET_MODEL_PATH/decoder.int8.onnx"
exec 8<"$HIREVA_PARAKEET_MODEL_PATH/joiner.int8.onnx"
exec 9<"$HIREVA_PARAKEET_MODEL_PATH/tokens.txt"

model_fingerprint() {
  local observations=""
  local name descriptor path path_stat_before path_identity_before descriptor_identity_before
  local path_stat_after path_identity_after descriptor_identity_after file_sha256 specification

  for specification in \
    "encoder.int8.onnx:6" \
    "decoder.int8.onnx:7" \
    "joiner.int8.onnx:8" \
    "tokens.txt:9"
  do
    name="${specification%%:*}"
    descriptor="${specification##*:}"
    path="$HIREVA_PARAKEET_MODEL_PATH/$name"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    path_stat_before="$(/usr/bin/stat -f '%d:%i:%z:%m:%c' "$path" 2>/dev/null)" || return 1
    path_identity_before="$(/usr/bin/stat -f '%i:%z:%m:%c' "$path" 2>/dev/null)" || return 1
    descriptor_identity_before="$(/usr/bin/stat -f '%i:%z:%m:%c' "/dev/fd/$descriptor" 2>/dev/null)" || return 1
    [[ "$path_identity_before" == "$descriptor_identity_before" ]] || return 1
    file_sha256="$(/usr/bin/shasum -a 256 "$path" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 1
    path_stat_after="$(/usr/bin/stat -f '%d:%i:%z:%m:%c' "$path" 2>/dev/null)" || return 1
    path_identity_after="$(/usr/bin/stat -f '%i:%z:%m:%c' "$path" 2>/dev/null)" || return 1
    descriptor_identity_after="$(/usr/bin/stat -f '%i:%z:%m:%c' "/dev/fd/$descriptor" 2>/dev/null)" || return 1
    [[ "$path_stat_before" == "$path_stat_after" && \
       "$path_identity_before" == "$path_identity_after" && \
       "$descriptor_identity_before" == "$descriptor_identity_after" && \
       "$path_identity_after" == "$descriptor_identity_after" ]] || return 1
    observations+="${name}|${path_stat_after}|${file_sha256}"$'\n'
  done
  printf '%s' "$observations" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

MODEL_FINGERPRINT_BASELINE="$(model_fingerprint)" || {
  echo "error: Parakeet model changed while its integrity boundary was established" >&2
  exit 2
}

assert_model_unchanged() {
  local current_fingerprint
  current_fingerprint="$(model_fingerprint)" || {
    echo "error: Parakeet model identity or contents changed during reconciliation" >&2
    return 1
  }
  if [[ "$current_fingerprint" != "$MODEL_FINGERPRINT_BASELINE" ]]; then
    echo "error: Parakeet model identity or contents changed during reconciliation" >&2
    return 1
  fi
}

assert_helper_snapshot_unchanged() {
  local current_fingerprint
  if [[ -w "$SNAPSHOT_HELPER" || \
        -n "$(/usr/bin/find "$HELPER_BOUNDARY" -perm -u+w -print -quit)" ]]; then
    echo "error: private Parakeet helper snapshot became writable" >&2
    return 1
  fi
  current_fingerprint="$(runtime_content_fingerprint "$SNAPSHOT_HELPER" "$SNAPSHOT_FRAMEWORKS")" || {
    echo "error: private Parakeet helper snapshot became unreadable" >&2
    return 1
  }
  if [[ "$current_fingerprint" != "$SNAPSHOT_RUNTIME_CONTENT_FINGERPRINT" ]]; then
    echo "error: private Parakeet helper snapshot changed during reconciliation" >&2
    return 1
  fi
}

MODEL_PROBE_OUTPUT="$RUN_ROOT/parakeet-model-probe.plist"
if ! /usr/bin/env -i \
  HOME="$ISOLATED_HOME" \
  TMPDIR="$ISOLATED_TMP/" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANG=en_US.UTF-8 \
  LC_CTYPE=UTF-8 \
  "$SNAPSHOT_HELPER" \
  --health --probe-model --model-dir "$HIREVA_PARAKEET_MODEL_PATH" \
  > "$MODEL_PROBE_OUTPUT" 2>/dev/null \
  6<&- 7<&- 8<&- 9<&-; then
  echo "error: Parakeet native model probe failed" >&2
  exit 2
fi
PROBE_STATUS="$(/usr/bin/plutil -extract status raw -o - "$MODEL_PROBE_OUTPUT" 2>/dev/null || true)"
PROBE_RUNTIME_MODE="$(/usr/bin/plutil -extract runtimeMode raw -o - "$MODEL_PROBE_OUTPUT" 2>/dev/null || true)"
PROBE_SOURCE="$(/usr/bin/plutil -extract source raw -o - "$MODEL_PROBE_OUTPUT" 2>/dev/null || true)"
PROBE_MODEL_STATUS="$(/usr/bin/plutil -extract modelStatus raw -o - "$MODEL_PROBE_OUTPUT" 2>/dev/null || true)"
if [[ "$PROBE_STATUS" != "ok" || \
      "$PROBE_RUNTIME_MODE" != "bundled_native" || \
      "$PROBE_SOURCE" != "local_parakeet_asr" || \
      "$PROBE_MODEL_STATUS" != "ready" ]]; then
  echo "error: Parakeet native model probe returned an invalid release response" >&2
  exit 2
fi
assert_model_unchanged || exit 2
assert_helper_snapshot_unchanged || exit 2

SYNTHETIC_FIXTURE_DIRECTORY="$SYNTHETIC_PARENT/fixture"
GENERATION_LOG="$RUN_ROOT/synthetic-generation.log"
if ! /usr/bin/env -i \
  HOME="$ISOLATED_HOME" \
  TMPDIR="$ISOLATED_TMP/" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANG=en_US.UTF-8 \
  LC_CTYPE=UTF-8 \
  "$ROOT_DIR/scripts/generate_synthetic_parakeet_fixture.sh" \
  "$SYNTHETIC_FIXTURE_DIRECTORY" \
  > "$GENERATION_LOG" 2>&1; then
  echo "error: private synthetic Parakeet fixture generation failed" >&2
  exit 2
fi
SYNTHETIC_AUDIO="$SYNTHETIC_FIXTURE_DIRECTORY/parakeet-three-utterances.wav"
SYNTHETIC_PROVENANCE="$SYNTHETIC_FIXTURE_DIRECTORY/parakeet-three-utterances.provenance.json"
if [[ ! -f "$SYNTHETIC_AUDIO" || -L "$SYNTHETIC_AUDIO" || \
      ! -f "$SYNTHETIC_PROVENANCE" || -L "$SYNTHETIC_PROVENANCE" ]]; then
  echo "error: private synthetic Parakeet generator did not produce the required files" >&2
  exit 2
fi
if ! PROVENANCE_VALIDATION="$(/usr/bin/ruby \
  "$ROOT_DIR/scripts/validate_synthetic_audio_provenance.rb" \
  "$SYNTHETIC_AUDIO" "$SYNTHETIC_PROVENANCE")"; then
  echo "error: generated Parakeet release-test audio lacks valid synthetic provenance" >&2
  exit 2
fi
SYNTHETIC_AUDIO_SHA256="$(/usr/bin/shasum -a 256 "$SYNTHETIC_AUDIO" | /usr/bin/awk '{print $1}')"
SYNTHETIC_PROVENANCE_SHA256="$(/usr/bin/shasum -a 256 "$SYNTHETIC_PROVENANCE" | /usr/bin/awk '{print $1}')"
/bin/chmod -R a-w "$SYNTHETIC_FIXTURE_DIRECTORY"

assert_fixture_unchanged() {
  local audio_sha256 provenance_sha256
  if [[ -w "$SYNTHETIC_AUDIO" || -w "$SYNTHETIC_PROVENANCE" ]]; then
    echo "error: private synthetic Parakeet fixture became writable" >&2
    return 1
  fi
  audio_sha256="$(/usr/bin/shasum -a 256 "$SYNTHETIC_AUDIO" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 1
  provenance_sha256="$(/usr/bin/shasum -a 256 "$SYNTHETIC_PROVENANCE" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 1
  if [[ "$audio_sha256" != "$SYNTHETIC_AUDIO_SHA256" || \
        "$provenance_sha256" != "$SYNTHETIC_PROVENANCE_SHA256" ]]; then
    echo "error: private synthetic Parakeet fixture changed during reconciliation" >&2
    return 1
  fi
  /usr/bin/ruby "$ROOT_DIR/scripts/validate_synthetic_audio_provenance.rb" \
    "$SYNTHETIC_AUDIO" "$SYNTHETIC_PROVENANCE" >/dev/null 2>&1 || {
    echo "error: private synthetic Parakeet fixture provenance became invalid" >&2
    return 1
  }
}

/bin/mkdir -m 700 "$OUTPUT_DIRECTORY"
[[ -d "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" &&
   "$(cd -P "$OUTPUT_DIRECTORY" && pwd)" == "$OUTPUT_DIRECTORY" ]] || {
  echo "error: reconciliation evidence directory was not created atomically" >&2
  exit 2
}
SCRATCH_PATH="$RUN_ROOT/swift-scratch"
/bin/mkdir "$SCRATCH_PATH"

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
  /usr/bin/env -i
  HOME="$ISOLATED_HOME"
  CFFIXED_USER_HOME="$ISOLATED_HOME"
  TMPDIR="$ISOLATED_TMP/"
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  LANG=en_US.UTF-8
  LC_CTYPE=UTF-8
  TZ=UTC
  HIREVA_REAL_OLLAMA_SMOKE=1
  RUN_LOCAL_QWEN_EXTRACTION_TEST=1
  HIREVA_REAL_PARAKEET_STREAM_TEST=1
  HIREVA_PARAKEET_HELPER_PATH="$SNAPSHOT_HELPER"
  HIREVA_PARAKEET_MODEL_PATH="$HIREVA_PARAKEET_MODEL_PATH"
  HIREVA_PARAKEET_TEST_AUDIO="$SYNTHETIC_AUDIO"
  HIREVA_PARAKEET_TEST_AUDIO_PROVENANCE="$SYNTHETIC_PROVENANCE"
)

cd "$ROOT_DIR"
{
  /usr/bin/swift --version
  /usr/bin/sw_vers
  /usr/bin/uname -m
  printf 'git_revision='
  /usr/bin/git rev-parse HEAD
  printf 'git_status_begin\n'
  /usr/bin/git status --porcelain=v1
  printf 'git_status_end\n'
  printf 'scratch_path_owned=%s\n' "$SCRATCH_PATH_OWNED"
  printf '%s\n' "$PROVENANCE_VALIDATION"
  printf 'parakeet_native_model_probe=passed\n'
  printf 'parakeet_helper_snapshot_sha256=%s\n' "$SNAPSHOT_RUNTIME_CONTENT_FINGERPRINT"
  printf 'parakeet_model_boundary=held_file_descriptors_plus_stat_and_sha256_rechecks\n'
  printf 'parakeet_model_fingerprint_sha256=%s\n' "$MODEL_FINGERPRINT_BASELINE"
} > "$OUTPUT_DIRECTORY/environment.txt"

set +e
"${SAFE_ENV[@]}" /usr/bin/swift test "${COMMON_ARGUMENTS[@]}" list \
  6<&- 7<&- 8<&- 9<&- 2>&1 | /usr/bin/tee "$LIST_LOG"
LIST_EXIT=${PIPESTATUS[0]}
set -e
if [[ "$LIST_EXIT" -ne 0 ]]; then
  echo "error: swift test list failed with exit $LIST_EXIT" >&2
  exit "$LIST_EXIT"
fi
assert_model_unchanged || exit 2
assert_helper_snapshot_unchanged || exit 2
assert_fixture_unchanged || exit 2

set +e
"${SAFE_ENV[@]}" /usr/bin/swift test "${COMMON_ARGUMENTS[@]}" --xunit-output "$XUNIT_PATH" \
  6<&- 7<&- 8<&- 9<&- 2>&1 | /usr/bin/tee "$TEST_LOG"
TEST_EXIT=${PIPESTATUS[0]}
set -e
assert_model_unchanged || exit 2
assert_helper_snapshot_unchanged || exit 2
assert_fixture_unchanged || exit 2

set +e
/usr/bin/ruby "$ROOT_DIR/scripts/reconcile_test_results.rb" \
  "$LIST_LOG" "$XUNIT_PATH" "$STATUS_PATH" \
  "$ROOT_DIR/scripts/release_test_prerequisites.tsv" 2>&1 | /usr/bin/tee "$SUMMARY_PATH"
RECONCILIATION_EXIT=${PIPESTATUS[0]}
set -e

/bin/cp "$ROOT_DIR/scripts/release_test_prerequisites.tsv" "$OUTPUT_DIRECTORY/release-test-prerequisites.tsv"
/bin/cp "$SYNTHETIC_PROVENANCE" "$OUTPUT_DIRECTORY/parakeet-test-audio-provenance.json"
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

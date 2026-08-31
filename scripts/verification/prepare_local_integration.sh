#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ARTIFACT_DIR=""
STATE_DIR=""
REQUESTED_MODEL_PATH="${HIREVA_CAMPAIGN_PARAKEET_MODEL_PATH:-}"

usage() {
    cat <<'USAGE'
Usage: ./scripts/verification/prepare_local_integration.sh \
  --artifact-dir ABSOLUTE_PATH \
  --state-dir ABSOLUTE_PATH [--model-path ABSOLUTE_PATH]

Builds a campaign-owned Parakeet helper snapshot, resolves and verifies the
installed model read-only, generates synthetic audio with provenance, and
checks that qwen3.5:4b is available from the local Ollama service.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifact-dir) ARTIFACT_DIR="${2:-}"; shift 2 ;;
        --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
        --model-path) REQUESTED_MODEL_PATH="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$ARTIFACT_DIR" == /* && "$STATE_DIR" == /* ]] || {
    echo "error: artifact and state directories must be absolute" >&2
    exit 2
}
[[ -d "$ARTIFACT_DIR" && -d "$STATE_DIR" ]] || {
    echo "error: artifact and state directories must already exist" >&2
    exit 2
}
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd -P)"
STATE_DIR="$(cd "$STATE_DIR" && pwd -P)"
[[ "$STATE_DIR" == "$ARTIFACT_DIR/state" ]] || {
    echo "error: state directory must be the artifact directory's state child" >&2
    exit 2
}
case "$ARTIFACT_DIR/" in
    "$ROOT_DIR/"*) echo "error: integration artifacts must remain outside the repository" >&2; exit 2 ;;
esac

for required_command in jq plutil shasum ruby say afconvert xcrun codesign; do
    command -v "$required_command" >/dev/null 2>&1 || {
        echo "error: required command is unavailable: $required_command" >&2
        exit 2
    }
done

umask 077
RUNTIME_PARENT="$ARTIFACT_DIR/runtime"
RUNTIME_ROOT="$RUNTIME_PARENT/parakeet-local-integration"
HELPER_PATH="$RUNTIME_ROOT/Helpers/parakeet_asr_helper"
FIXTURE_PARENT="$ARTIFACT_DIR/audio"
FIXTURE_ROOT="$FIXTURE_PARENT/local-integration-parakeet"
AUDIO_PATH="$FIXTURE_ROOT/parakeet-three-utterances.wav"
PROVENANCE_PATH="$FIXTURE_ROOT/parakeet-three-utterances.provenance.json"
ENVIRONMENT_FILE="$STATE_DIR/local_integration_environment.json"
BUILD_WORK_ROOT=""
HEALTH_FILE=""

cleanup() {
    if [[ -n "$HEALTH_FILE" && -f "$HEALTH_FILE" ]]; then
        /bin/rm -f "$HEALTH_FILE"
    fi
    if [[ -n "$BUILD_WORK_ROOT" && -d "$BUILD_WORK_ROOT" && \
          "$BUILD_WORK_ROOT" == "$RUNTIME_PARENT/.parakeet-build."* ]]; then
        /bin/rm -rf -- "$BUILD_WORK_ROOT"
    fi
}
trap cleanup EXIT INT TERM

/bin/mkdir -p "$RUNTIME_PARENT" "$FIXTURE_PARENT"
if [[ ! -e "$RUNTIME_ROOT" && ! -L "$RUNTIME_ROOT" ]]; then
    BUILD_WORK_ROOT="$(/usr/bin/mktemp -d "$RUNTIME_PARENT/.parakeet-build.XXXXXX")"
    "$ROOT_DIR/script/runtime/build_parakeet_helper.sh" "$BUILD_WORK_ROOT/runtime" >/dev/null
    [[ ! -e "$RUNTIME_ROOT" && ! -L "$RUNTIME_ROOT" ]] || {
        echo "error: campaign runtime path appeared during atomic build" >&2
        exit 1
    }
    /bin/mv "$BUILD_WORK_ROOT/runtime" "$RUNTIME_ROOT"
    /bin/rmdir "$BUILD_WORK_ROOT"
    BUILD_WORK_ROOT=""
fi
if [[ ! -d "$RUNTIME_ROOT" || -L "$RUNTIME_ROOT" || \
      ! -f "$HELPER_PATH" || -L "$HELPER_PATH" || ! -x "$HELPER_PATH" || \
      ! -s "$RUNTIME_ROOT/RuntimeProvenance.plist" ]]; then
    echo "error: campaign-owned Parakeet runtime is incomplete or unsafe" >&2
    exit 1
fi
/usr/bin/codesign --verify --strict --verbose=2 "$HELPER_PATH" >/dev/null

contains_model_files() {
    local directory="$1"
    local name
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    for name in encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt; do
        [[ -f "$directory/$name" && ! -L "$directory/$name" ]] || return 1
    done
}

MODEL_MIGRATION_FILE=""
if [[ -z "$REQUESTED_MODEL_PATH" ]]; then
    [[ -n "${HOME:-}" ]] || { echo "error: HOME is unavailable for read-only model discovery" >&2; exit 2; }
    REQUESTED_MODEL_PATH="$HOME/Library/Application Support/Hireva/LocalModels/asr/parakeet-tdt-0.6b-v3-int8"
fi
[[ "$REQUESTED_MODEL_PATH" == /* ]] || {
    echo "error: Parakeet model path must be absolute" >&2
    exit 2
}

if contains_model_files "$REQUESTED_MODEL_PATH"; then
    MODEL_PATH="$(cd "$REQUESTED_MODEL_PATH" && pwd -P)"
elif [[ -f "$REQUESTED_MODEL_PATH/.legacy-migration.json" && \
        ! -L "$REQUESTED_MODEL_PATH/.legacy-migration.json" ]]; then
    MODEL_MIGRATION_FILE="$REQUESTED_MODEL_PATH/.legacy-migration.json"
    MIGRATION_DESTINATION="$(/usr/bin/plutil -extract destination raw -o - "$MODEL_MIGRATION_FILE" 2>/dev/null || true)"
    case "/$MIGRATION_DESTINATION/" in
        *"/../"*|*"/./"*|*"//"*) echo "error: model migration destination is unsafe" >&2; exit 1 ;;
    esac
    [[ -n "$MIGRATION_DESTINATION" && "$MIGRATION_DESTINATION" != /* ]] || {
        echo "error: model migration destination must be a non-empty relative path" >&2
        exit 1
    }
    LOCAL_MODELS_ROOT="$(cd "$(dirname "$(dirname "$REQUESTED_MODEL_PATH")")" && pwd -P)"
    MODEL_CANDIDATE="$LOCAL_MODELS_ROOT/$MIGRATION_DESTINATION"
    contains_model_files "$MODEL_CANDIDATE" || {
        echo "error: migrated Parakeet model is incomplete" >&2
        exit 1
    }
    MODEL_PATH="$(cd "$MODEL_CANDIDATE" && pwd -P)"
    case "$MODEL_PATH/" in
        "$LOCAL_MODELS_ROOT/"*) ;;
        *) echo "error: migrated model escaped the LocalModels root" >&2; exit 1 ;;
    esac
else
    echo "error: Parakeet model files and migration record are unavailable" >&2
    exit 1
fi

if [[ -n "$MODEL_MIGRATION_FILE" ]]; then
    for model_name in encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt; do
        expected_hash="$(jq -r --arg name "$model_name" '.verifiedFileHashes[$name] // empty' "$MODEL_MIGRATION_FILE")"
        [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || {
            echo "error: migration record lacks a valid hash for $model_name" >&2
            exit 1
        }
        actual_hash="$(/usr/bin/shasum -a 256 "$MODEL_PATH/$model_name" | /usr/bin/awk '{print $1}')"
        [[ "$actual_hash" == "$expected_hash" ]] || {
            echo "error: migrated model hash mismatch for $model_name" >&2
            exit 1
        }
    done
fi

HEALTH_FILE="$(/usr/bin/mktemp "$STATE_DIR/.parakeet-health.XXXXXX")"
"$HELPER_PATH" --health --probe-model --model-dir "$MODEL_PATH" > "$HEALTH_FILE"
for health_contract in status:ok source:local_parakeet_asr runtimeMode:bundled_native modelStatus:ready; do
    health_key="${health_contract%%:*}"
    health_value="${health_contract#*:}"
    [[ "$(/usr/bin/plutil -extract "$health_key" raw -o - "$HEALTH_FILE" 2>/dev/null || true)" == "$health_value" ]] || {
        echo "error: Parakeet health contract failed for $health_key" >&2
        exit 1
    }
done
/bin/rm -f "$HEALTH_FILE"
HEALTH_FILE=""

if [[ ! -e "$FIXTURE_ROOT" && ! -L "$FIXTURE_ROOT" ]]; then
    "$ROOT_DIR/scripts/generate_synthetic_parakeet_fixture.sh" "$FIXTURE_ROOT" >/dev/null
    /bin/chmod -R a-w "$FIXTURE_ROOT"
fi
[[ -d "$FIXTURE_ROOT" && ! -L "$FIXTURE_ROOT" ]] || {
    echo "error: synthetic fixture directory is incomplete or unsafe" >&2
    exit 1
}
/usr/bin/ruby "$ROOT_DIR/scripts/validate_synthetic_audio_provenance.rb" \
    "$AUDIO_PATH" "$PROVENANCE_PATH" >/dev/null

OLLAMA_BINARY="${HIREVA_CAMPAIGN_OLLAMA_PATH:-$(command -v ollama || true)}"
[[ -n "$OLLAMA_BINARY" && -x "$OLLAMA_BINARY" ]] || {
    echo "error: local Ollama executable is unavailable" >&2
    exit 1
}
"$OLLAMA_BINARY" show qwen3.5:4b >/dev/null

ENVIRONMENT_TEMP="$(/usr/bin/mktemp "$STATE_DIR/.local-integration.XXXXXX")"
jq -n \
    --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg helper_path "$HELPER_PATH" \
    --arg model_path "$MODEL_PATH" \
    --arg audio_path "$AUDIO_PATH" \
    --arg provenance_path "$PROVENANCE_PATH" \
    --arg ollama_model "qwen3.5:4b" \
    '{schema_version: 1, prepared_at_utc: $prepared_at,
      synthetic_audio: true, contains_real_personal_data: false,
      helper_path: $helper_path, model_path: $model_path,
      audio_path: $audio_path, provenance_path: $provenance_path,
      ollama_model: $ollama_model}' > "$ENVIRONMENT_TEMP"
/bin/mv "$ENVIRONMENT_TEMP" "$ENVIRONMENT_FILE"

printf 'LOCAL_INTEGRATION_ENVIRONMENT=%s\n' "$ENVIRONMENT_FILE"
printf 'PARAKEET_RUNTIME=ready\n'
printf 'PARAKEET_MODEL=ready\n'
printf 'SYNTHETIC_AUDIO_PROVENANCE=passed\n'
printf 'OLLAMA_MODEL=qwen3.5:4b\n'

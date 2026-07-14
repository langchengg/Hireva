#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=release_common.sh
source "$SCRIPT_DIR/release_common.sh"

usage() {
    cat <<'USAGE'
Usage: package_release.sh /path/to/signed/Hireva.app

Required environment:
  HIREVA_SIGNING_MODE        adhoc, development, or developer-id
  HIREVA_BUILD_ARCHS         Required architectures, comma or space separated
  HIREVA_RELEASE_OUTPUT_DIR  Parent directory for the versioned artifact directory

Creates an app copy, ZIP, SHA-256 checksum, and JSON version manifest. Existing
artifact directories are never overwritten. Signing identities, notary profile
names, credentials, and source filesystem paths are never written to metadata.
USAGE
}

validate_hireva_release_contract() {
    local app="$RELEASE_APP_PATH"
    local helper="$app/Contents/Helpers/parakeet_asr_helper"
    local sherpa="$app/Contents/Frameworks/libsherpa-onnx-c-api.dylib"
    local onnx="$app/Contents/Frameworks/libonnxruntime.1.27.0.dylib"
    local runtime_mode
    local embedded_mode
    local tree_state
    local distribution_build
    local actual_arches
    local forbidden
    local required
    local required_macho
    local unexpected

    [[ "$RELEASE_PRODUCT_NAME" == "Hireva" ]] || release_die "CFBundleName must be Hireva"
    [[ "$RELEASE_EXECUTABLE_NAME" == "Hireva" ]] || release_die "CFBundleExecutable must be Hireva"
    [[ "$RELEASE_BUNDLE_IDENTIFIER" == "com.langcheng.Hireva" ]] || \
        release_die "CFBundleIdentifier must be com.langcheng.Hireva"
    if [[ ${#RELEASE_ARCHS[@]} -ne 1 || "${RELEASE_ARCHS[0]}" != "arm64" ]]; then
        release_die "Hireva release packaging requires exactly HIREVA_BUILD_ARCHS=arm64"
    fi

    runtime_mode="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaRuntimeMode || true)"
    embedded_mode="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaSigningMode || true)"
    tree_state="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaGitTreeState || true)"
    distribution_build="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaDistributionBuild || true)"
    [[ "$runtime_mode" == "bundled_native" ]] || release_die "HirevaRuntimeMode must be bundled_native"
    [[ "$embedded_mode" == "$RELEASE_SIGNING_MODE" ]] || \
        release_die "embedded signing mode does not match HIREVA_SIGNING_MODE"
    case "$tree_state" in
        clean|dirty) ;;
        *) release_die "HirevaGitTreeState must explicitly be clean or dirty" ;;
    esac
    if [[ "$RELEASE_SIGNING_MODE" == "developer-id" ]]; then
        [[ "$tree_state" == "clean" ]] || release_die "developer-id packaging requires a clean source tree"
        [[ "$distribution_build" == "true" ]] || release_die "developer-id app is not marked as a distribution build"
    else
        [[ "$distribution_build" == "false" ]] || release_die "non-distribution signing mode has distribution metadata"
    fi

    forbidden="$(/usr/bin/find "$app/Contents" \( \
        -type l -o \
        -type d \( -iname '__pycache__' -o -iname 'site-packages' -o \
            -iname 'numpy' -o -iname 'LocalModels' -o -iname 'Models' -o \
            -iname 'test_wavs' -o -name '.git' -o -name '.build' \) -o \
        -type f \( -iname '*.py' -o -iname '*.pyc' -o -iname '*.pyo' -o \
            -iname 'python' -o -iname 'python[0-9]*' -o -iname 'libpython*' -o \
            -iname '*.onnx' -o -iname '*.ort' -o -iname '*.bin' -o \
            -iname '*.gguf' -o -iname '*.ggml' -o -iname '*.safetensors' -o \
            -iname '*.pt' -o -iname '*.pth' -o -iname '*.mlmodel' -o \
            -iname 'tokens.txt' -o -iname '*.sqlite' -o -iname '*.sqlite3' -o \
            -iname '*.sqlite-*' -o -iname '*.db' -o -iname '*.db-*' -o \
            -iname '*-wal' -o -iname '*-shm' -o -iname '*.wav' -o \
            -iname '*.jsonl' -o -iname '*.trace' -o -iname '*.trace.*' -o \
            -iname '*.log' -o -iname '*.zip' -o -iname '*.dmg' -o \
            -iname '*.tar' -o -iname '*.tar.*' -o -iname '*.bz2' -o \
            -iname '.env' -o -iname '.env.*' -o -iname '*.pem' -o \
            -iname '*.p12' -o -iname '*.key' -o -iname 'auth.json' -o \
            -iname 'credentials.json' -o -iname 'secrets.*' -o \
            -name '.DS_Store' -o -name '._*' \) \
    \) -print -quit)"
    [[ -z "$forbidden" ]] || release_die "forbidden private/runtime payload in app: ${forbidden#"$app/"}"

    for required in \
        "$helper" \
        "$sherpa" \
        "$onnx" \
        "$app/Contents/Resources/Documentation/release-installation.md" \
        "$app/Contents/Resources/Documentation/local-model-installation.md" \
        "$app/Contents/Resources/Documentation/privacy-and-data-flow.md" \
        "$app/Contents/Resources/Documentation/third-party-licenses.md" \
        "$app/Contents/Resources/Documentation/release-notes-0.1.0.md" \
        "$app/Contents/Resources/ThirdPartyNotices/sherpa-onnx-LICENSE.txt" \
        "$app/Contents/Resources/ThirdPartyNotices/onnxruntime-LICENSE.txt" \
        "$app/Contents/Resources/ThirdPartyNotices/onnxruntime-ThirdPartyNotices.txt" \
        "$app/Contents/Resources/ThirdPartyNotices/GRDB-LICENSE.txt"; do
        [[ -s "$required" ]] || release_die "required Hireva payload is missing or empty: ${required#"$app/"}"
    done
    [[ -x "$helper" ]] || release_die "bundled Parakeet helper is not executable"
    [[ "$(/usr/bin/file -b "$helper")" == *Mach-O* ]] || release_die "bundled Parakeet helper is not Mach-O"
    [[ "$(/usr/bin/file -b "$sherpa")" == *"dynamically linked shared library"* ]] || \
        release_die "bundled sherpa runtime is not a dynamic library"
    [[ "$(/usr/bin/file -b "$onnx")" == *"dynamically linked shared library"* ]] || \
        release_die "bundled ONNX runtime is not a dynamic library"

    for required_macho in "$RELEASE_MAIN_EXECUTABLE" "$helper" "$sherpa" "$onnx"; do
        actual_arches="$(/usr/bin/lipo -archs "$required_macho" 2>/dev/null)" || \
            release_die "unable to inspect required Hireva Mach-O: ${required_macho#"$app/"}"
        [[ "$actual_arches" == "arm64" ]] || \
            release_die "required Hireva Mach-O must be exactly arm64: ${required_macho#"$app/"} (found: $actual_arches)"
    done

    unexpected="$(/usr/bin/find "$app/Contents/Helpers" -mindepth 1 -maxdepth 1 \
        ! -name 'parakeet_asr_helper' -print -quit)"
    [[ -z "$unexpected" ]] || release_die "unexpected bundled helper: ${unexpected#"$app/"}"
    unexpected="$(/usr/bin/find "$app/Contents/Frameworks" -mindepth 1 -maxdepth 1 \
        ! -name 'libsherpa-onnx-c-api.dylib' \
        ! -name 'libonnxruntime.1.27.0.dylib' -print -quit)"
    [[ -z "$unexpected" ]] || release_die "unexpected bundled framework: ${unexpected#"$app/"}"
}

validate_hireva_runtime_health() {
    local app="$RELEASE_APP_PATH"
    local helper="$app/Contents/Helpers/parakeet_asr_helper"
    local health_file

    health_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/hireva-helper-health.XXXXXX")" || \
        release_die "unable to create helper health probe file"
    if ! /usr/bin/env -i HOME="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        "$helper" --health >"$health_file" 2>/dev/null; then
        /bin/rm -f "$health_file"
        release_die "bundled Parakeet helper health probe failed"
    fi
    if [[ "$(/usr/bin/plutil -extract status raw -o - "$health_file" 2>/dev/null || true)" != "ok" ]] || \
       [[ "$(/usr/bin/plutil -extract source raw -o - "$health_file" 2>/dev/null || true)" != "local_parakeet_asr" ]] || \
       [[ "$(/usr/bin/plutil -extract runtimeMode raw -o - "$health_file" 2>/dev/null || true)" != "bundled_native" ]] || \
       [[ "$(/usr/bin/plutil -extract runtimeVersion raw -o - "$health_file" 2>/dev/null || true)" != "1" ]] || \
       [[ "$(/usr/bin/plutil -extract sherpaVersion raw -o - "$health_file" 2>/dev/null || true)" != "1.13.4" ]] || \
       [[ "$(/usr/bin/plutil -extract onnxRuntimeVersion raw -o - "$health_file" 2>/dev/null || true)" != "1.27.0" ]] || \
       [[ "$(/usr/bin/plutil -extract architecture raw -o - "$health_file" 2>/dev/null || true)" != "arm64" ]] || \
       [[ "$(/usr/bin/plutil -extract modelStatus raw -o - "$health_file" 2>/dev/null || true)" != "not_probed" ]]; then
        /bin/rm -f "$health_file"
        release_die "bundled Parakeet helper returned an invalid health contract"
    fi
    /bin/rm -f "$health_file"
}

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

release_validate_mode
release_load_architectures
release_load_app "$1"
release_load_versions
release_reject_unstable_metadata
validate_hireva_release_contract
release_validate_architectures
release_assert_signature_mode "$RELEASE_APP_PATH"
validate_hireva_runtime_health
release_prepare_output_root

ARTIFACT_STEM="$RELEASE_PRODUCT_NAME-$RELEASE_SHORT_VERSION-$RELEASE_BUNDLE_VERSION-$RELEASE_SIGNING_MODE"
FINAL_RELEASE_DIR="$RELEASE_OUTPUT_ROOT/$ARTIFACT_STEM"
if [[ -e "$FINAL_RELEASE_DIR" ]] || [[ -L "$FINAL_RELEASE_DIR" ]]; then
    release_die "release artifact directory already exists: $FINAL_RELEASE_DIR"
fi

WORK_DIR="$(/usr/bin/mktemp -d "$RELEASE_OUTPUT_ROOT/.hireva-package.XXXXXX")" || \
    release_die "unable to create packaging work directory"
trap '/bin/rm -rf "$WORK_DIR"' EXIT
STAGED_RELEASE_DIR="$WORK_DIR/$ARTIFACT_STEM"
/bin/mkdir "$STAGED_RELEASE_DIR"

APP_ARTIFACT="$(basename "$RELEASE_APP_PATH")"
ZIP_ARTIFACT="$ARTIFACT_STEM.zip"
CHECKSUM_ARTIFACT="$ZIP_ARTIFACT.sha256"
MANIFEST_ARTIFACT="version-manifest.json"
DOCUMENTATION_ARTIFACT="Documentation"
STAGED_APP="$STAGED_RELEASE_DIR/$APP_ARTIFACT"
STAGED_ZIP="$STAGED_RELEASE_DIR/$ZIP_ARTIFACT"
STAGED_CHECKSUM="$STAGED_RELEASE_DIR/$CHECKSUM_ARTIFACT"
STAGED_MANIFEST="$STAGED_RELEASE_DIR/$MANIFEST_ARTIFACT"
STAGED_DOCUMENTATION="$STAGED_RELEASE_DIR/$DOCUMENTATION_ARTIFACT"

printf '[package] copying signed app without resource-fork metadata\n'
/usr/bin/ditto --norsrc "$RELEASE_APP_PATH" "$STAGED_APP"
if [[ ! -d "$STAGED_APP/Contents/Resources/Documentation" || \
      ! -d "$STAGED_APP/Contents/Resources/ThirdPartyNotices" ]]; then
    release_die "signed app is missing release documentation or third-party notices"
fi
/usr/bin/ditto --norsrc "$STAGED_APP/Contents/Resources/Documentation" "$STAGED_DOCUMENTATION"
/usr/bin/ditto --norsrc "$STAGED_APP/Contents/Resources/ThirdPartyNotices" \
    "$STAGED_DOCUMENTATION/ThirdPartyNotices"
release_load_app "$STAGED_APP"
release_reject_unstable_metadata
validate_hireva_release_contract
release_validate_architectures
release_assert_signature_mode "$STAGED_APP"
validate_hireva_runtime_health

printf '[package] creating notarization-compatible ZIP\n'
/usr/bin/ditto -c -k --keepParent --norsrc "$STAGED_APP" "$STAGED_ZIP"
if ! /usr/bin/unzip -tq "$STAGED_ZIP" >/dev/null; then
    release_die "ZIP integrity validation failed: $STAGED_ZIP"
fi
release_verify_zip_matches_app "$STAGED_APP" "$STAGED_ZIP"

ZIP_SHA256="$(release_sha256 "$STAGED_ZIP")"
printf '%s  %s\n' "$ZIP_SHA256" "$ZIP_ARTIFACT" > "$STAGED_CHECKSUM"

SIGNING_DETAILS="$(release_signature_details "$STAGED_APP")"
TEAM_IDENTIFIER="$(printf '%s\n' "$SIGNING_DETAILS" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
CDHASH="$(printf '%s\n' "$SIGNING_DETAILS" | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
ACTUAL_ARCHS="$(/usr/bin/lipo -archs "$RELEASE_MAIN_EXECUTABLE")"
SOURCE_COMMIT="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaGitCommitHash || true)"
SOURCE_TREE_STATE="$(release_plist_value "$RELEASE_INFO_PLIST" HirevaGitTreeState || true)"
GENERATED_AT_UTC="$(/bin/date -u +'%Y-%m-%dT%H:%M:%SZ')"

/usr/bin/plutil -create xml1 "$STAGED_MANIFEST"
/usr/bin/plutil -insert schema_version -integer 1 "$STAGED_MANIFEST"
/usr/bin/plutil -insert product_name -string "$RELEASE_PRODUCT_NAME" "$STAGED_MANIFEST"
/usr/bin/plutil -insert bundle_identifier -string "$RELEASE_BUNDLE_IDENTIFIER" "$STAGED_MANIFEST"
/usr/bin/plutil -insert short_version -string "$RELEASE_SHORT_VERSION" "$STAGED_MANIFEST"
/usr/bin/plutil -insert bundle_version -string "$RELEASE_BUNDLE_VERSION" "$STAGED_MANIFEST"
/usr/bin/plutil -insert signing_mode -string "$RELEASE_SIGNING_MODE" "$STAGED_MANIFEST"
/usr/bin/plutil -insert hardened_runtime -bool "$([[ "$RELEASE_SIGNING_MODE" == "developer-id" ]] && printf true || printf false)" "$STAGED_MANIFEST"
/usr/bin/plutil -insert notarized -bool false "$STAGED_MANIFEST"
/usr/bin/plutil -insert app_artifact -string "$APP_ARTIFACT" "$STAGED_MANIFEST"
/usr/bin/plutil -insert zip_artifact -string "$ZIP_ARTIFACT" "$STAGED_MANIFEST"
/usr/bin/plutil -insert checksum_artifact -string "$CHECKSUM_ARTIFACT" "$STAGED_MANIFEST"
/usr/bin/plutil -insert documentation_artifact -string "$DOCUMENTATION_ARTIFACT" "$STAGED_MANIFEST"
/usr/bin/plutil -insert zip_sha256 -string "$ZIP_SHA256" "$STAGED_MANIFEST"
/usr/bin/plutil -insert code_directory_hash -string "${CDHASH:-unavailable}" "$STAGED_MANIFEST"
/usr/bin/plutil -insert team_identifier -string "${TEAM_IDENTIFIER:-none}" "$STAGED_MANIFEST"
/usr/bin/plutil -insert source_commit -string "${SOURCE_COMMIT:-unknown}" "$STAGED_MANIFEST"
/usr/bin/plutil -insert source_tree_state -string "$SOURCE_TREE_STATE" "$STAGED_MANIFEST"
/usr/bin/plutil -insert generated_at_utc -string "$GENERATED_AT_UTC" "$STAGED_MANIFEST"
/usr/bin/plutil -insert requested_architectures -json '[]' "$STAGED_MANIFEST"
index=0
for arch in "${RELEASE_ARCHS[@]}"; do
    /usr/bin/plutil -insert "requested_architectures.$index" -string "$arch" "$STAGED_MANIFEST"
    ((index += 1))
done
/usr/bin/plutil -insert actual_architectures -json '[]' "$STAGED_MANIFEST"
index=0
for arch in $ACTUAL_ARCHS; do
    /usr/bin/plutil -insert "actual_architectures.$index" -string "$arch" "$STAGED_MANIFEST"
    ((index += 1))
done
/usr/bin/plutil -insert entitlements -json '[]' "$STAGED_MANIFEST"
if [[ "$RELEASE_SIGNING_MODE" == "developer-id" ]]; then
    /usr/bin/plutil -insert entitlements.0 -string 'com.apple.security.device.audio-input' "$STAGED_MANIFEST"
fi
/usr/bin/plutil -convert json "$STAGED_MANIFEST"
if ! /usr/bin/plutil -p "$STAGED_MANIFEST" >/dev/null; then
    release_die "generated version manifest is invalid"
fi

/bin/mv "$STAGED_RELEASE_DIR" "$FINAL_RELEASE_DIR"
printf 'RELEASE_DIR=%s\n' "$FINAL_RELEASE_DIR"
printf 'APP_ARTIFACT=%s\n' "$FINAL_RELEASE_DIR/$APP_ARTIFACT"
printf 'ZIP_ARTIFACT=%s\n' "$FINAL_RELEASE_DIR/$ZIP_ARTIFACT"
printf 'ZIP_SHA256=%s\n' "$ZIP_SHA256"
printf 'VERSION_MANIFEST=%s\n' "$FINAL_RELEASE_DIR/$MANIFEST_ARTIFACT"
printf 'DOCUMENTATION=%s\n' "$FINAL_RELEASE_DIR/$DOCUMENTATION_ARTIFACT"

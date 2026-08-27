#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

RUNTIME_CONTRACT="$ROOT_DIR/script/runtime/runtime_contract.sh"
MACHO_PAYLOAD_SHA256="$ROOT_DIR/script/runtime/macho_payload_sha256.sh"
EXCLUSIVE_RENAME="$ROOT_DIR/script/release/exclusive_rename.rb"
PARAKEET_DESCRIPTOR_ID="parakeet-tdt-0.6b-v3-int8"
PARAKEET_MODEL_VERSION="asr-models-5793d0fd397c5778"
PARAKEET_ARCHIVE_SHA256="5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf"
PARAKEET_ARCHIVE_SIZE_BYTES="487170055"
APP_CONTENT_HASH_ALGORITHM="sha256-v1-of-lowercase-file-sha256-hex-tab-relative-path-nul-in-lc-all-c-find-s-order"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ -f "$RUNTIME_CONTRACT" ]] || fail "runtime source contract is missing: $RUNTIME_CONTRACT"
[[ -x "$MACHO_PAYLOAD_SHA256" ]] || \
    fail "Mach-O payload hashing tool is missing or not executable: $MACHO_PAYLOAD_SHA256"
# shellcheck source=../script/runtime/runtime_contract.sh
source "$RUNTIME_CONTRACT"

usage() {
    cat <<'USAGE'
Usage: package_dmg.sh [--validate-only] /path/to/signed/Hireva.app /path/to/new-output-directory

The app must already be assembled and signed. The output directory must not
exist. This command never builds, launches the app, installs, signs, notarizes,
or overwrites an app or artifact. Validation does execute the bundled Parakeet
helper's bounded --health probe. --validate-only runs every pre-DMG gate
without creating the output directory or invoking hdiutil.

A Developer ID input is accepted only when HIREVA_ALLOW_DISTRIBUTION_DMG=1 is
set explicitly. Developer ID validation also requires an explicit 10-character
HIREVA_EXPECTED_TEAM_IDENTIFIER. This script still does not notarize, staple,
or publish it.
USAGE
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

app_content_sha256() {
    local app="$1"
    local index_file="$2"
    local file_list="${index_file}.files"
    local candidate
    local digest
    local relative

    : > "$index_file" || fail "unable to create app content hash index"
    if ! LC_ALL=C /usr/bin/find -s "$app" -type f -print0 > "$file_list"; then
        fail "unable to enumerate app content for hashing: $app"
    fi
    while IFS= read -r -d '' candidate; do
        relative="${candidate#"$app/"}"
        digest="$(sha256 "$candidate")" || fail "unable to hash app content: $relative"
        printf '%s\t%s\0' "$digest" "$relative" >> "$index_file" || \
            fail "unable to write app content hash index"
    done < "$file_list"
    sha256 "$index_file" || fail "unable to hash app content index"
}

VALIDATE_ONLY=0
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ "${1:-}" == "--validate-only" ]]; then
    VALIDATE_ONLY=1
    shift
fi
if [[ $# -ne 2 ]]; then
    usage >&2
    exit 2
fi

SOURCE_APP_BUNDLE="$1"
REQUESTED_OUTPUT_DIR="$2"
SOURCE_APP_BUNDLE="$(/usr/bin/ruby -e 'print File.expand_path(ARGV.fetch(0))' \
    "$SOURCE_APP_BUNDLE")" || fail "unable to normalize app bundle path"
[[ "$SOURCE_APP_BUNDLE" == *.app ]] || fail "expected a .app bundle: $SOURCE_APP_BUNDLE"

OUTPUT_NAME="$(basename "$REQUESTED_OUTPUT_DIR")"
case "$OUTPUT_NAME" in
    ''|.|..) fail "output directory must name a new child directory" ;;
esac
OUTPUT_PARENT_REQUESTED="$(dirname "$REQUESTED_OUTPUT_DIR")"
[[ -d "$OUTPUT_PARENT_REQUESTED" ]] || \
    fail "output parent directory does not exist: $OUTPUT_PARENT_REQUESTED"
[[ ! -L "$OUTPUT_PARENT_REQUESTED" ]] || \
    fail "output parent directory must not be a symbolic link: $OUTPUT_PARENT_REQUESTED"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT_REQUESTED" && pwd -P)"
OUTPUT_DIR="$OUTPUT_PARENT/$OUTPUT_NAME"
if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
    fail "output directory already exists: $OUTPUT_DIR"
fi

[[ -d "$SOURCE_APP_BUNDLE" ]] || fail "app bundle is missing: $SOURCE_APP_BUNDLE"
[[ ! -L "$SOURCE_APP_BUNDLE" ]] || fail "app bundle must not be a symbolic link"
[[ "$(basename "$SOURCE_APP_BUNDLE")" == "Hireva.app" ]] || \
    fail "release app bundle filename must be Hireva.app"
SOURCE_APP_BUNDLE="$(cd "$SOURCE_APP_BUNDLE" && pwd -P)" || \
    fail "unable to resolve app bundle path: $SOURCE_APP_BUNDLE"
case "$OUTPUT_PARENT" in
    "$SOURCE_APP_BUNDLE"|"$SOURCE_APP_BUNDLE"/*)
        fail "output parent must not be the source app or one of its descendants"
        ;;
esac

MOUNT_DEVICE=""
MOUNT_ATTACHED=0
MOUNT_ATTACH_ATTEMPTED=0
WORK_DIR="$(/usr/bin/mktemp -d "$OUTPUT_PARENT/.hireva-dmg.XXXXXX")" || \
    fail "unable to create a temporary packaging directory"
cleanup() {
    if [[ -n "$MOUNT_DEVICE" ]]; then
        /usr/bin/hdiutil detach "$MOUNT_DEVICE" >/dev/null 2>&1 || true
    elif [[ "${MOUNT_ATTACH_ATTEMPTED:-0}" -eq 1 ]]; then
        /usr/bin/hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

STAGING_DIR="$WORK_DIR/staging"
RESULT_DIR="$WORK_DIR/result"
STAGED_APP="$STAGING_DIR/Hireva.app"
APP_HASH_INDEX="$WORK_DIR/app-content-hashes"
MOUNTED_APP_HASH_INDEX="$WORK_DIR/mounted-app-content-hashes"
MOUNT_DIR="$WORK_DIR/mount"
ATTACH_PLIST="$WORK_DIR/attach.plist"
/bin/mkdir "$STAGING_DIR" "$RESULT_DIR" "$MOUNT_DIR"

printf '[snapshot] Copying the signed app into private staging\n'
/usr/bin/ditto --norsrc "$SOURCE_APP_BUNDLE" "$STAGED_APP"

# All release metadata and hashes below are derived from this immutable staged
# snapshot, never from the caller's app path.
APP_BUNDLE="$STAGED_APP"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Hireva"
RUNTIME_PROVENANCE="$APP_BUNDLE/Contents/Resources/RuntimeProvenance.plist"
SHERPA_LIBRARY="$APP_BUNDLE/Contents/Frameworks/libsherpa-onnx-c-api.dylib"
ONNX_LIBRARY="$APP_BUNDLE/Contents/Frameworks/libonnxruntime.1.27.0.dylib"

[[ -f "$INFO_PLIST" ]] || fail "Info.plist is missing: $INFO_PLIST"
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"
[[ -x "$APP_BINARY" ]] || fail "app executable is missing or not executable: $APP_BINARY"

PRODUCT_NAME="$(plist_value "$INFO_PLIST" CFBundleName)" || fail "CFBundleName is missing"
VERSION="$(plist_value "$INFO_PLIST" CFBundleShortVersionString)" || \
    fail "CFBundleShortVersionString is missing"
BUILD_NUMBER="$(plist_value "$INFO_PLIST" CFBundleVersion)" || fail "CFBundleVersion is missing"
SIGNING_MODE="$(plist_value "$INFO_PLIST" HirevaSigningMode)" || \
    fail "HirevaSigningMode is missing"
BUILD_CONFIGURATION="$(plist_value "$INFO_PLIST" HirevaBuildConfiguration)" || \
    fail "HirevaBuildConfiguration is missing"
SOURCE_COMMIT="$(plist_value "$INFO_PLIST" HirevaGitCommitHash)" || \
    fail "HirevaGitCommitHash is missing"
SOURCE_TREE_STATE="$(plist_value "$INFO_PLIST" HirevaGitTreeState)" || \
    fail "HirevaGitTreeState is missing"

[[ "$PRODUCT_NAME" == "Hireva" ]] || fail "CFBundleName must be Hireva"
[[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe app version: $VERSION"
[[ "$BUILD_NUMBER" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe app build number: $BUILD_NUMBER"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "unsafe source commit metadata"
[[ "$SOURCE_TREE_STATE" == "clean" || "$SOURCE_TREE_STATE" == "dirty" ]] || \
    fail "source tree state must be clean or dirty"
[[ "$BUILD_CONFIGURATION" == "release" ]] || \
    fail "DMG packaging requires HirevaBuildConfiguration=release"
case "$SIGNING_MODE" in
    adhoc|development|developer-id) ;;
    *) fail "unsupported embedded signing mode: $SIGNING_MODE" ;;
esac
case "${HIREVA_ALLOW_DISTRIBUTION_DMG:-0}" in
    0|1) ;;
    *) fail "HIREVA_ALLOW_DISTRIBUTION_DMG must be 0 or 1" ;;
esac
if [[ "$SIGNING_MODE" == "developer-id" ]] && \
   [[ "${HIREVA_ALLOW_DISTRIBUTION_DMG:-0}" != "1" ]]; then
    fail "Developer ID DMG creation requires explicit HIREVA_ALLOW_DISTRIBUTION_DMG=1 authorization"
fi

printf '[verify] Running the shared release app contract\n'
HIREVA_SIGNING_MODE="$SIGNING_MODE" HIREVA_BUILD_ARCHS="arm64" \
    "$ROOT_DIR/script/release/package_release.sh" --validate-only "$APP_BUNDLE"

[[ -f "$RUNTIME_PROVENANCE" ]] || fail "runtime provenance manifest is missing"
SHERPA_VERSION="$(plist_value "$RUNTIME_PROVENANCE" 'sherpa_onnx:version')" || \
    fail "sherpa runtime version is missing from provenance"
ONNX_RUNTIME_VERSION="$(plist_value "$RUNTIME_PROVENANCE" 'onnx_runtime:version')" || \
    fail "ONNX Runtime version is missing from provenance"
SHERPA_RUNTIME_ARCHIVE_SHA256="$(plist_value "$RUNTIME_PROVENANCE" 'source_archive_sha256')" || \
    fail "runtime archive hash is missing from provenance"
SHERPA_SOURCE_LIBRARY_SHA256="$(plist_value "$RUNTIME_PROVENANCE" 'sherpa_onnx:source_library_sha256')" || \
    fail "sherpa source library hash is missing from provenance"
ONNX_SOURCE_LIBRARY_SHA256="$(plist_value "$RUNTIME_PROVENANCE" 'onnx_runtime:source_library_sha256')" || \
    fail "ONNX source library hash is missing from provenance"
RUNTIME_PAYLOAD_HASH_ALGORITHM="$(plist_value "$RUNTIME_PROVENANCE" 'payload_hash_algorithm')" || \
    fail "runtime payload hash algorithm is missing from provenance"
RUNTIME_BINARY_TRANSFORM_IDENTIFIER="$(plist_value "$RUNTIME_PROVENANCE" 'binary_transform_identifier')" || \
    fail "runtime binary transform identifier is missing from provenance"
RUNTIME_PATH_SANITIZATION_IDENTIFIER="$(plist_value "$RUNTIME_PROVENANCE" 'path_sanitization_identifier')" || \
    fail "runtime path sanitization identifier is missing from provenance"
SHERPA_PROVENANCE_PAYLOAD_SHA256="$(plist_value "$RUNTIME_PROVENANCE" 'sherpa_onnx:macho_payload_sha256')" || \
    fail "sherpa payload hash is missing from provenance"
ONNX_PROVENANCE_PAYLOAD_SHA256="$(plist_value "$RUNTIME_PROVENANCE" 'onnx_runtime:macho_payload_sha256')" || \
    fail "ONNX payload hash is missing from provenance"
SHERPA_SOURCE_PATH_REPLACEMENT_COUNT="$(plist_value "$RUNTIME_PROVENANCE" 'sherpa_onnx:source_path_replacement_count')" || \
    fail "sherpa path replacement count is missing from provenance"
ONNX_SOURCE_PATH_REPLACEMENT_COUNT="$(plist_value "$RUNTIME_PROVENANCE" 'onnx_runtime:source_path_replacement_count')" || \
    fail "ONNX path replacement count is missing from provenance"

SHERPA_PAYLOAD_SHA256="$("$MACHO_PAYLOAD_SHA256" "$SHERPA_LIBRARY")"
ONNX_PAYLOAD_SHA256="$("$MACHO_PAYLOAD_SHA256" "$ONNX_LIBRARY")"
[[ "$SHERPA_PAYLOAD_SHA256" == "$SHERPA_PROVENANCE_PAYLOAD_SHA256" ]] || \
    fail "signed sherpa runtime payload differs from verified provenance"
[[ "$ONNX_PAYLOAD_SHA256" == "$ONNX_PROVENANCE_PAYLOAD_SHA256" ]] || \
    fail "signed ONNX runtime payload differs from verified provenance"
SHERPA_SIGNED_ARTIFACT_SHA256="$(sha256 "$SHERPA_LIBRARY")"
ONNX_SIGNED_ARTIFACT_SHA256="$(sha256 "$ONNX_LIBRARY")"

if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
    printf 'VALIDATION=passed\n'
    printf 'APP_ARTIFACT=%s\n' "$(basename "$APP_BUNDLE")"
    printf 'OUTPUT_DIRECTORY_CANDIDATE=%s\n' "$OUTPUT_NAME"
    exit 0
fi

ARTIFACT_STEM="Hireva-$VERSION-$BUILD_NUMBER-arm64"
FINAL_DMG="$RESULT_DIR/$ARTIFACT_STEM.dmg"
FINAL_MANIFEST="$RESULT_DIR/$ARTIFACT_STEM.manifest.json"

/bin/ln -s /Applications "$STAGING_DIR/Applications"

[[ -L "$STAGING_DIR/Applications" ]] || fail "Applications symlink was not created"
[[ "$(/usr/bin/readlink "$STAGING_DIR/Applications")" == "/Applications" ]] || \
    fail "Applications symlink has an unexpected target"
UNEXPECTED_TOP_LEVEL="$(/usr/bin/find "$STAGING_DIR" -mindepth 1 -maxdepth 1 \
    ! -name 'Hireva.app' ! -name 'Applications' -print -quit)"
[[ -z "$UNEXPECTED_TOP_LEVEL" ]] || \
    fail "unexpected top-level DMG payload: $UNEXPECTED_TOP_LEVEL"

APP_CONTENT_SHA256="$(app_content_sha256 "$STAGED_APP" "$APP_HASH_INDEX")"
HELPER_SHA256="$(sha256 "$STAGED_APP/Contents/Helpers/parakeet_asr_helper")"

printf '[package] Creating %s\n' "$(basename "$FINAL_DMG")"
/usr/bin/hdiutil create \
    -volname "Hireva" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    "$FINAL_DMG"
/usr/bin/hdiutil verify "$FINAL_DMG"

printf '[verify] Mounting the completed image read-only for payload verification\n'
MOUNT_ATTACH_ATTEMPTED=1
/usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$MOUNT_DIR" \
    -plist \
    "$FINAL_DMG" > "$ATTACH_PLIST"
MOUNT_ATTACHED=1
mount_index=0
while :; do
    candidate_device="$(/usr/bin/plutil -extract "system-entities.$mount_index.dev-entry" raw \
        -o - "$ATTACH_PLIST" 2>/dev/null || true)"
    candidate_mount="$(/usr/bin/plutil -extract "system-entities.$mount_index.mount-point" raw \
        -o - "$ATTACH_PLIST" 2>/dev/null || true)"
    if [[ -z "$candidate_device" && -z "$candidate_mount" ]]; then
        break
    fi
    if [[ "$candidate_mount" == "$MOUNT_DIR" ]]; then
        MOUNT_DEVICE="$candidate_device"
        break
    fi
    ((mount_index += 1))
done
[[ -n "$MOUNT_DEVICE" ]] || fail "unable to identify the mounted DMG device"

MOUNTED_APP="$MOUNT_DIR/Hireva.app"
MOUNTED_APPLICATIONS_LINK="$MOUNT_DIR/Applications"
[[ -d "$MOUNTED_APP" ]] || fail "mounted DMG is missing Hireva.app"
[[ -L "$MOUNTED_APPLICATIONS_LINK" ]] || fail "mounted DMG is missing the Applications symlink"
[[ "$(/usr/bin/readlink "$MOUNTED_APPLICATIONS_LINK")" == "/Applications" ]] || \
    fail "mounted DMG Applications symlink has an unexpected target"
MOUNTED_UNEXPECTED_TOP_LEVEL="$(/usr/bin/find "$MOUNT_DIR" -mindepth 1 -maxdepth 1 \
    ! -name 'Hireva.app' ! -name 'Applications' -print -quit)"
[[ -z "$MOUNTED_UNEXPECTED_TOP_LEVEL" ]] || \
    fail "unexpected top-level payload in mounted DMG: $MOUNTED_UNEXPECTED_TOP_LEVEL"

HIREVA_SIGNING_MODE="$SIGNING_MODE" HIREVA_BUILD_ARCHS="arm64" \
    "$ROOT_DIR/script/release/package_release.sh" --validate-only "$MOUNTED_APP"
MOUNTED_APP_CONTENT_SHA256="$(app_content_sha256 "$MOUNTED_APP" "$MOUNTED_APP_HASH_INDEX")"
[[ "$MOUNTED_APP_CONTENT_SHA256" == "$APP_CONTENT_SHA256" ]] || \
    fail "mounted DMG app content differs from the staged app"

/usr/bin/hdiutil detach "$MOUNT_DEVICE"
MOUNT_DEVICE=""
MOUNT_ATTACHED=0
MOUNT_ATTACH_ATTEMPTED=0

DMG_SHA256="$(sha256 "$FINAL_DMG")"
DMG_SIZE="$(/usr/bin/stat -f '%z' "$FINAL_DMG")"
GENERATED_AT_UTC="$(/bin/date -u +'%Y-%m-%dT%H:%M:%SZ')"
if [[ "$SOURCE_TREE_STATE" == "dirty" ]]; then
    ARTIFACT_SCOPE="internal_validation"
    SOURCE_PROVENANCE="working_tree_snapshot"
else
    SOURCE_PROVENANCE="committed_source"
    if [[ "$SIGNING_MODE" == "developer-id" ]]; then
        ARTIFACT_SCOPE="distribution_candidate_not_notarized"
    else
        ARTIFACT_SCOPE="internal_validation"
    fi
fi

/usr/bin/plutil -create xml1 "$FINAL_MANIFEST"
/usr/bin/plutil -insert schema_version -integer 2 "$FINAL_MANIFEST"
/usr/bin/plutil -insert product_name -string "$PRODUCT_NAME" "$FINAL_MANIFEST"
/usr/bin/plutil -insert bundle_identifier -string "com.langcheng.Hireva" "$FINAL_MANIFEST"
/usr/bin/plutil -insert short_version -string "$VERSION" "$FINAL_MANIFEST"
/usr/bin/plutil -insert bundle_version -string "$BUILD_NUMBER" "$FINAL_MANIFEST"
/usr/bin/plutil -insert build_configuration -string "$BUILD_CONFIGURATION" "$FINAL_MANIFEST"
/usr/bin/plutil -insert artifact_scope -string "$ARTIFACT_SCOPE" "$FINAL_MANIFEST"
/usr/bin/plutil -insert source_commit -string "$SOURCE_COMMIT" "$FINAL_MANIFEST"
/usr/bin/plutil -insert source_tree_state -string "$SOURCE_TREE_STATE" "$FINAL_MANIFEST"
/usr/bin/plutil -insert source_provenance -string "$SOURCE_PROVENANCE" "$FINAL_MANIFEST"
/usr/bin/plutil -insert signing_mode -string "$SIGNING_MODE" "$FINAL_MANIFEST"
/usr/bin/plutil -insert architecture -string "arm64" "$FINAL_MANIFEST"
/usr/bin/plutil -insert generated_at_utc -string "$GENERATED_AT_UTC" "$FINAL_MANIFEST"
/usr/bin/plutil -insert app_artifact -string "Hireva.app" "$FINAL_MANIFEST"
/usr/bin/plutil -insert app_content_hash_algorithm \
    -string "$APP_CONTENT_HASH_ALGORITHM" "$FINAL_MANIFEST"
/usr/bin/plutil -insert app_content_sha256 -string "$APP_CONTENT_SHA256" "$FINAL_MANIFEST"
/usr/bin/plutil -insert dmg_artifact -string "$(basename "$FINAL_DMG")" "$FINAL_MANIFEST"
/usr/bin/plutil -insert dmg_size_bytes -integer "$DMG_SIZE" "$FINAL_MANIFEST"
/usr/bin/plutil -insert dmg_sha256 -string "$DMG_SHA256" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime -json '{}' "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.helper -json '{}' "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.helper.signed_artifact_sha256 -string "$HELPER_SHA256" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.helper.provenance -string "$SOURCE_PROVENANCE" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.helper.source_commit -string "$SOURCE_COMMIT" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.sherpa_onnx -json '{}' "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.sherpa_onnx.version -string "$SHERPA_VERSION" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.sherpa_onnx.source_library_sha256 \
    -string "$SHERPA_SOURCE_LIBRARY_SHA256" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.sherpa_onnx.macho_payload_hash_algorithm \
    -string "$RUNTIME_PAYLOAD_HASH_ALGORITHM" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.sherpa_onnx.binary_transform_identifier \
    -string "$RUNTIME_BINARY_TRANSFORM_IDENTIFIER" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.sherpa_onnx.source_path_sanitization_identifier \
    -string "$RUNTIME_PATH_SANITIZATION_IDENTIFIER" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.sherpa_onnx.source_path_replacement_count \
    -integer "$SHERPA_SOURCE_PATH_REPLACEMENT_COUNT" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.sherpa_onnx.macho_payload_sha256 \
    -string "$SHERPA_PAYLOAD_SHA256" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.sherpa_onnx.signed_artifact_sha256 \
    -string "$SHERPA_SIGNED_ARTIFACT_SHA256" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.sherpa_onnx.source_archive_sha256 \
    -string "$SHERPA_RUNTIME_ARCHIVE_SHA256" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.onnx_runtime -json '{}' "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.onnx_runtime.version -string "$ONNX_RUNTIME_VERSION" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.onnx_runtime.source_library_sha256 \
    -string "$ONNX_SOURCE_LIBRARY_SHA256" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.onnx_runtime.macho_payload_hash_algorithm \
    -string "$RUNTIME_PAYLOAD_HASH_ALGORITHM" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.onnx_runtime.binary_transform_identifier \
    -string "$RUNTIME_BINARY_TRANSFORM_IDENTIFIER" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.onnx_runtime.source_path_sanitization_identifier \
    -string "$RUNTIME_PATH_SANITIZATION_IDENTIFIER" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.onnx_runtime.source_path_replacement_count \
    -integer "$ONNX_SOURCE_PATH_REPLACEMENT_COUNT" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.onnx_runtime.macho_payload_sha256 \
    -string "$ONNX_PAYLOAD_SHA256" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.onnx_runtime.signed_artifact_sha256 \
    -string "$ONNX_SIGNED_ARTIFACT_SHA256" "$FINAL_MANIFEST"
/usr/bin/plutil -insert runtime.onnx_runtime.source_archive_sha256 \
    -string "$SHERPA_RUNTIME_ARCHIVE_SHA256" "$FINAL_MANIFEST"
/usr/bin/plutil -insert parakeet_model -json '{}' "$FINAL_MANIFEST"
/usr/bin/plutil -insert parakeet_model.descriptor_id -string "$PARAKEET_DESCRIPTOR_ID" "$FINAL_MANIFEST"
/usr/bin/plutil -insert parakeet_model.version -string "$PARAKEET_MODEL_VERSION" "$FINAL_MANIFEST"
/usr/bin/plutil -insert parakeet_model.archive_sha256 -string "$PARAKEET_ARCHIVE_SHA256" "$FINAL_MANIFEST"
/usr/bin/plutil -insert parakeet_model.archive_size_bytes \
    -integer "$PARAKEET_ARCHIVE_SIZE_BYTES" "$FINAL_MANIFEST"
/usr/bin/plutil -convert json "$FINAL_MANIFEST"
/usr/bin/plutil -p "$FINAL_MANIFEST" >/dev/null || fail "generated DMG manifest is invalid"

if LC_ALL=C /usr/bin/grep -a -Eq \
    '/Users/|signing_identity|team_identifier|certificate|notary_profile|provisioning_profile' \
    "$FINAL_MANIFEST"; then
    fail "DMG manifest contains forbidden source-path or signing identity metadata"
fi
[[ "$(/usr/bin/find "$RESULT_DIR" -mindepth 1 -maxdepth 1 \
    ! -name "$(basename "$FINAL_DMG")" ! -name "$(basename "$FINAL_MANIFEST")" \
    -print -quit)" == "" ]] || fail "unexpected file in completed DMG result directory"
[[ -f "$EXCLUSIVE_RENAME" && ! -L "$EXCLUSIVE_RENAME" ]] || \
    fail "exclusive artifact publisher is unavailable"
/bin/chmod 755 "$RESULT_DIR"
/usr/bin/ruby "$EXCLUSIVE_RENAME" "$RESULT_DIR" "$OUTPUT_DIR"

printf 'DMG_PATH=%s\n' "$OUTPUT_DIR/$(basename "$FINAL_DMG")"
printf 'DMG_MANIFEST=%s\n' "$OUTPUT_DIR/$(basename "$FINAL_MANIFEST")"
printf 'DMG_VERSION=%s\n' "$VERSION"
printf 'DMG_BUILD=%s\n' "$BUILD_NUMBER"
printf 'DMG_ARCHITECTURE=arm64\n'
printf 'DMG_SIGNING_MODE=%s\n' "$SIGNING_MODE"
printf 'DMG_SIZE_BYTES=%s\n' "$DMG_SIZE"
printf 'DMG_SHA256=%s\n' "$DMG_SHA256"

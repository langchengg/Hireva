#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=release_common.sh
source "$SCRIPT_DIR/release_common.sh"
EXCLUSIVE_RENAME="$SCRIPT_DIR/exclusive_rename.rb"

usage() {
    cat <<'USAGE'
Usage: notarize_release.sh /path/to/versioned-dmg-directory

Required environment:
  HIREVA_SIGNING_MODE        Must be developer-id
  HIREVA_BUILD_ARCHS         Must be exactly arm64
  HIREVA_EXPECTED_TEAM_IDENTIFIER
                              Explicit 10-character Apple Team ID
  HIREVA_NOTARY_PROFILE      Existing notarytool Keychain profile
  HIREVA_ALLOW_NOTARIZATION_SUBMIT
                              Must be exactly 1 for explicit upload authorization
  HIREVA_RELEASE_OUTPUT_DIR  Parent of the versioned DMG directory

Submits the exact signed DMG bound by its package manifest SHA-256. After an
Accepted response, the workflow preserves the upload DMG, staples a private
copy, validates the ticket, disk image, Developer ID signature, and Gatekeeper,
then publishes a separately checksummed final DMG and manifest. The submission
response and Apple notarization log are retained. Identity, Team ID, notary
profile, and credential values are never written to either manifest.
USAGE
}

validate_developer_id_dmg() {
    local dmg="$1"
    local details
    local authority
    local team

    /usr/bin/codesign --verify --strict --verbose=4 "$dmg" || \
        release_die "Developer ID DMG signature verification failed: $dmg"
    details="$(/usr/bin/codesign -dv --verbose=4 "$dmg" 2>&1)" || \
        release_die "unable to inspect Developer ID DMG signature: $dmg"
    authority="$(printf '%s\n' "$details" | /usr/bin/sed -n 's/^Authority=//p' | /usr/bin/head -1)"
    team="$(printf '%s\n' "$details" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -1)"
    [[ "$authority" == "Developer ID Application:"* ]] || \
        release_die "DMG signature is not Developer ID Application"
    [[ "$team" == "$RELEASE_EXPECTED_TEAM_IDENTIFIER" ]] || \
        release_die "DMG TeamIdentifier differs from HIREVA_EXPECTED_TEAM_IDENTIFIER"
    printf '%s\n' "$details" | /usr/bin/grep -q '^Timestamp=' || \
        release_die "Developer ID DMG signature is missing a secure timestamp"
}

publish_exclusively() {
    local source="$1"
    local destination="$2"
    /usr/bin/ruby "$EXCLUSIVE_RENAME" "$source" "$destination" || \
        release_die "unable to publish notarization evidence without overwrite: $destination"
}

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

# Validate every operator-controlled authorization input before inspecting the
# artifact. A configured profile alone is never treated as upload permission.
release_validate_mode
if [[ "$RELEASE_SIGNING_MODE" != "developer-id" ]]; then
    release_die "notarization requires HIREVA_SIGNING_MODE=developer-id"
fi
release_load_architectures
if [[ ${#RELEASE_ARCHS[@]} -ne 1 || "${RELEASE_ARCHS[0]}" != "arm64" ]]; then
    release_die "DMG notarization requires exactly HIREVA_BUILD_ARCHS=arm64"
fi
release_validate_expected_team_identifier
release_require_env HIREVA_NOTARY_PROFILE
case "${HIREVA_ALLOW_NOTARIZATION_SUBMIT:-0}" in
    0|1) ;;
    *) release_die "HIREVA_ALLOW_NOTARIZATION_SUBMIT must be 0 or 1" ;;
esac
if [[ "${HIREVA_ALLOW_NOTARIZATION_SUBMIT:-0}" != "1" ]]; then
    release_die "notarization submission requires explicit HIREVA_ALLOW_NOTARIZATION_SUBMIT=1 authorization"
fi
release_prepare_output_root
[[ -f "$EXCLUSIVE_RENAME" && ! -L "$EXCLUSIVE_RENAME" ]] || \
    release_die "exclusive artifact publisher is unavailable"

if [[ ! -d "$1" ]] || [[ -L "$1" ]]; then
    release_die "DMG release directory does not exist or is a symbolic link: $1"
fi
RELEASE_DIR="$(cd "$1" && pwd -P)"
if [[ "$(dirname "$RELEASE_DIR")" != "$RELEASE_OUTPUT_ROOT" ]]; then
    release_die "DMG release directory must be a direct child of HIREVA_RELEASE_OUTPUT_DIR"
fi

MANIFEST_CANDIDATES=()
while IFS= read -r -d '' candidate; do
    MANIFEST_CANDIDATES+=("$candidate")
done < <(/usr/bin/find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -type f \
    -name 'Hireva-*-arm64.manifest.json' ! -name '*.notarized.manifest.json' -print0)
if [[ ${#MANIFEST_CANDIDATES[@]} -ne 1 ]]; then
    release_die "DMG release directory must contain exactly one package manifest"
fi
UPLOAD_MANIFEST="${MANIFEST_CANDIDATES[0]}"
if [[ -L "$UPLOAD_MANIFEST" ]] || ! /usr/bin/plutil -p "$UPLOAD_MANIFEST" >/dev/null; then
    release_die "missing or invalid DMG package manifest: $UPLOAD_MANIFEST"
fi

SCHEMA_VERSION="$(release_manifest_value "$UPLOAD_MANIFEST" schema_version)" || \
    release_die "DMG package manifest is missing schema_version"
DMG_ARTIFACT="$(release_manifest_value "$UPLOAD_MANIFEST" dmg_artifact)" || \
    release_die "DMG package manifest is missing dmg_artifact"
EXPECTED_UPLOAD_SHA256="$(release_manifest_value "$UPLOAD_MANIFEST" dmg_sha256)" || \
    release_die "DMG package manifest is missing dmg_sha256"
EXPECTED_UPLOAD_SIZE="$(release_manifest_value "$UPLOAD_MANIFEST" dmg_size_bytes)" || \
    release_die "DMG package manifest is missing dmg_size_bytes"
MANIFEST_MODE="$(release_manifest_value "$UPLOAD_MANIFEST" signing_mode)" || \
    release_die "DMG package manifest is missing signing_mode"
ARTIFACT_SCOPE="$(release_manifest_value "$UPLOAD_MANIFEST" artifact_scope)" || \
    release_die "DMG package manifest is missing artifact_scope"
SOURCE_TREE_STATE="$(release_manifest_value "$UPLOAD_MANIFEST" source_tree_state)" || \
    release_die "DMG package manifest is missing source_tree_state"
ARCHITECTURE="$(release_manifest_value "$UPLOAD_MANIFEST" architecture)" || \
    release_die "DMG package manifest is missing architecture"

[[ "$SCHEMA_VERSION" == "2" ]] || release_die "unsupported DMG package manifest schema"
[[ "$DMG_ARTIFACT" == "$(basename "$DMG_ARTIFACT")" && "$DMG_ARTIFACT" == *.dmg ]] || \
    release_die "manifest DMG artifact must be a basename ending in .dmg"
[[ "$(basename "$UPLOAD_MANIFEST")" == "${DMG_ARTIFACT%.dmg}.manifest.json" ]] || \
    release_die "DMG package manifest filename does not match its artifact"
[[ "$EXPECTED_UPLOAD_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
    release_die "DMG package manifest contains an invalid SHA-256"
[[ "$EXPECTED_UPLOAD_SIZE" =~ ^[0-9]+$ ]] || \
    release_die "DMG package manifest contains an invalid byte size"
[[ "$MANIFEST_MODE" == "developer-id" ]] || \
    release_die "DMG package manifest was not produced for developer-id signing"
[[ "$ARTIFACT_SCOPE" == "distribution_candidate_not_notarized" ]] || \
    release_die "DMG package manifest is not an unnotarized distribution candidate"
[[ "$SOURCE_TREE_STATE" == "clean" ]] || \
    release_die "DMG notarization requires a clean committed source artifact"
[[ "$ARCHITECTURE" == "arm64" ]] || release_die "DMG package manifest architecture must be arm64"

UPLOAD_DMG="$RELEASE_DIR/$DMG_ARTIFACT"
if [[ ! -f "$UPLOAD_DMG" ]] || [[ -L "$UPLOAD_DMG" ]]; then
    release_die "signed DMG artifact is missing or is a symbolic link: $UPLOAD_DMG"
fi
UNEXPECTED_INPUT="$(/usr/bin/find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 \
    ! -name "$DMG_ARTIFACT" ! -name "$(basename "$UPLOAD_MANIFEST")" -print -quit)"
[[ -z "$UNEXPECTED_INPUT" ]] || \
    release_die "unexpected file in unnotarized DMG release directory: $UNEXPECTED_INPUT"
if LC_ALL=C /usr/bin/grep -a -Eq \
    '/Users/|signing_identity|team_identifier|certificate|notary_profile|provisioning_profile|credential' \
    "$UPLOAD_MANIFEST"; then
    release_die "DMG package manifest contains forbidden identity, profile, credential, or source-path metadata"
fi

UPLOAD_DMG_SHA256="$(release_sha256 "$UPLOAD_DMG")"
UPLOAD_DMG_SIZE="$(/usr/bin/stat -f '%z' "$UPLOAD_DMG")"
UPLOAD_MANIFEST_SHA256="$(release_sha256 "$UPLOAD_MANIFEST")"
[[ "$UPLOAD_DMG_SHA256" == "$EXPECTED_UPLOAD_SHA256" ]] || \
    release_die "DMG checksum differs from package manifest; refusing to submit"
[[ "$UPLOAD_DMG_SIZE" == "$EXPECTED_UPLOAD_SIZE" ]] || \
    release_die "DMG byte size differs from package manifest; refusing to submit"
/usr/bin/hdiutil verify "$UPLOAD_DMG" || release_die "upload DMG integrity validation failed"
validate_developer_id_dmg "$UPLOAD_DMG"

ARTIFACT_STEM="${DMG_ARTIFACT%.dmg}"
SUBMIT_RESPONSE="$RELEASE_DIR/notarization-submit.plist"
NOTARY_LOG="$RELEASE_DIR/notarization-log.json"
FINAL_DMG_ARTIFACT="$ARTIFACT_STEM.notarized.dmg"
FINAL_CHECKSUM_ARTIFACT="$FINAL_DMG_ARTIFACT.sha256"
FINAL_MANIFEST_ARTIFACT="$ARTIFACT_STEM.notarized.manifest.json"
FINAL_DMG="$RELEASE_DIR/$FINAL_DMG_ARTIFACT"
FINAL_CHECKSUM="$RELEASE_DIR/$FINAL_CHECKSUM_ARTIFACT"
FINAL_MANIFEST="$RELEASE_DIR/$FINAL_MANIFEST_ARTIFACT"
for output in "$SUBMIT_RESPONSE" "$NOTARY_LOG" "$FINAL_DMG" "$FINAL_CHECKSUM" "$FINAL_MANIFEST"; do
    if [[ -e "$output" ]] || [[ -L "$output" ]]; then
        release_die "notarization output already exists; refusing to overwrite: $output"
    fi
done

TEMP_SUBMIT_RESPONSE=""
TEMP_NOTARY_LOG=""
WORK_DIR=""
cleanup() {
    if [[ -n "$TEMP_SUBMIT_RESPONSE" ]]; then
        /bin/rm -f "$TEMP_SUBMIT_RESPONSE"
    fi
    if [[ -n "$TEMP_NOTARY_LOG" ]]; then
        /bin/rm -f "$TEMP_NOTARY_LOG"
    fi
    if [[ -n "$WORK_DIR" ]]; then
        /bin/rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

printf '[notary] submitting exact signed DMG sha256=%s\n' "$UPLOAD_DMG_SHA256"
TEMP_SUBMIT_RESPONSE="$(/usr/bin/mktemp "$RELEASE_DIR/.notarization-submit.XXXXXX")" || \
    release_die "unable to create temporary notary response file"
set +e
/usr/bin/xcrun notarytool submit "$UPLOAD_DMG" \
    --keychain-profile "$HIREVA_NOTARY_PROFILE" \
    --wait \
    --output-format plist > "$TEMP_SUBMIT_RESPONSE"
SUBMIT_EXIT=$?
set -e
publish_exclusively "$TEMP_SUBMIT_RESPONSE" "$SUBMIT_RESPONSE"
TEMP_SUBMIT_RESPONSE=""

SUBMISSION_ID=""
NOTARY_STATUS=""
if /usr/bin/plutil -lint "$SUBMIT_RESPONSE" >/dev/null 2>&1; then
    SUBMISSION_ID="$(release_manifest_value "$SUBMIT_RESPONSE" id || true)"
    NOTARY_STATUS="$(release_manifest_value "$SUBMIT_RESPONSE" status || true)"
fi
if [[ -n "$SUBMISSION_ID" ]]; then
    TEMP_NOTARY_LOG="$(/usr/bin/mktemp "$RELEASE_DIR/.notarization-log.XXXXXX")" || \
        release_die "unable to create temporary notary log path"
    /bin/rm -f "$TEMP_NOTARY_LOG"
    set +e
    /usr/bin/xcrun notarytool log "$SUBMISSION_ID" \
        --keychain-profile "$HIREVA_NOTARY_PROFILE" \
        "$TEMP_NOTARY_LOG"
    LOG_EXIT=$?
    set -e
    if [[ -f "$TEMP_NOTARY_LOG" ]]; then
        publish_exclusively "$TEMP_NOTARY_LOG" "$NOTARY_LOG"
        TEMP_NOTARY_LOG=""
    fi
    [[ "$LOG_EXIT" -eq 0 ]] || \
        release_die "notarization finished but its log could not be retrieved"
fi
if [[ "$SUBMIT_EXIT" -ne 0 ]]; then
    release_die "notarytool submission failed; inspect $SUBMIT_RESPONSE"
fi
[[ -n "$SUBMISSION_ID" ]] || release_die "notarytool response did not contain a submission id"
[[ "$NOTARY_STATUS" == "Accepted" ]] || \
    release_die "notarization status is '$NOTARY_STATUS', expected 'Accepted'; inspect $NOTARY_LOG"
[[ -f "$NOTARY_LOG" ]] || release_die "notarization log was not saved"
/usr/bin/plutil -lint "$NOTARY_LOG" >/dev/null 2>&1 || \
    release_die "saved notarization log is not valid JSON"
[[ "$(release_sha256 "$UPLOAD_DMG")" == "$UPLOAD_DMG_SHA256" ]] || \
    release_die "submitted DMG changed during notarization"

WORK_DIR="$(/usr/bin/mktemp -d "$RELEASE_DIR/.hireva-notarized-dmg.XXXXXX")" || \
    release_die "unable to create final DMG work directory"
STAGED_FINAL_DMG="$WORK_DIR/$FINAL_DMG_ARTIFACT"
STAGED_FINAL_CHECKSUM="$WORK_DIR/$FINAL_CHECKSUM_ARTIFACT"
STAGED_FINAL_MANIFEST="$WORK_DIR/$FINAL_MANIFEST_ARTIFACT"
/bin/cp "$UPLOAD_DMG" "$STAGED_FINAL_DMG"
[[ "$(release_sha256 "$STAGED_FINAL_DMG")" == "$UPLOAD_DMG_SHA256" ]] || \
    release_die "private DMG copy differs before stapling"

printf '[notary] stapling accepted ticket to final DMG copy\n'
/usr/bin/xcrun stapler staple "$STAGED_FINAL_DMG"
/usr/bin/xcrun stapler validate "$STAGED_FINAL_DMG"
/usr/bin/hdiutil verify "$STAGED_FINAL_DMG" || release_die "stapled DMG integrity validation failed"
validate_developer_id_dmg "$STAGED_FINAL_DMG"
if ! /usr/sbin/spctl -a -t open --context context:primary-signature -v "$STAGED_FINAL_DMG"; then
    release_die "Gatekeeper primary-signature assessment failed for stapled DMG"
fi

FINAL_DMG_SHA256="$(release_sha256 "$STAGED_FINAL_DMG")"
FINAL_DMG_SIZE="$(/usr/bin/stat -f '%z' "$STAGED_FINAL_DMG")"
SUBMIT_RESPONSE_SHA256="$(release_sha256 "$SUBMIT_RESPONSE")"
NOTARY_LOG_SHA256="$(release_sha256 "$NOTARY_LOG")"
printf '%s  %s\n' "$FINAL_DMG_SHA256" "$FINAL_DMG_ARTIFACT" > "$STAGED_FINAL_CHECKSUM"

/bin/cp "$UPLOAD_MANIFEST" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -convert xml1 "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -replace schema_version -integer 3 "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -replace artifact_scope -string distribution_candidate_notarized "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -replace dmg_artifact -string "$FINAL_DMG_ARTIFACT" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -replace dmg_size_bytes -integer "$FINAL_DMG_SIZE" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -replace dmg_sha256 -string "$FINAL_DMG_SHA256" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert notarized -bool true "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert stapled -bool true "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert notarization_status -string "$NOTARY_STATUS" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert notarization_submission_id -string "$SUBMISSION_ID" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert notarization_response_artifact -string "$(basename "$SUBMIT_RESPONSE")" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert notarization_response_sha256 -string "$SUBMIT_RESPONSE_SHA256" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert notarization_log_artifact -string "$(basename "$NOTARY_LOG")" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert notarization_log_sha256 -string "$NOTARY_LOG_SHA256" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert upload_dmg_artifact -string "$DMG_ARTIFACT" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert upload_dmg_size_bytes -integer "$UPLOAD_DMG_SIZE" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert upload_dmg_sha256 -string "$UPLOAD_DMG_SHA256" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert upload_manifest_artifact -string "$(basename "$UPLOAD_MANIFEST")" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert upload_manifest_sha256 -string "$UPLOAD_MANIFEST_SHA256" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert distribution_dmg_artifact -string "$FINAL_DMG_ARTIFACT" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert distribution_dmg_size_bytes -integer "$FINAL_DMG_SIZE" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert distribution_dmg_sha256 -string "$FINAL_DMG_SHA256" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert distribution_dmg_checksum_artifact -string "$FINAL_CHECKSUM_ARTIFACT" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -convert json "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -p "$STAGED_FINAL_MANIFEST" >/dev/null || \
    release_die "generated notarized DMG manifest is invalid"
if LC_ALL=C /usr/bin/grep -a -Eq \
    '/Users/|signing_identity|team_identifier|certificate|notary_profile|provisioning_profile|credential' \
    "$STAGED_FINAL_MANIFEST" || \
   LC_ALL=C /usr/bin/grep -a -F "$HIREVA_EXPECTED_TEAM_IDENTIFIER" "$STAGED_FINAL_MANIFEST" >/dev/null || \
   LC_ALL=C /usr/bin/grep -a -F "$HIREVA_NOTARY_PROFILE" "$STAGED_FINAL_MANIFEST" >/dev/null; then
    release_die "notarized DMG manifest contains forbidden identity, profile, credential, or source-path metadata"
fi

publish_exclusively "$STAGED_FINAL_DMG" "$FINAL_DMG"
publish_exclusively "$STAGED_FINAL_CHECKSUM" "$FINAL_CHECKSUM"
publish_exclusively "$STAGED_FINAL_MANIFEST" "$FINAL_MANIFEST"
/bin/rm -rf "$WORK_DIR"
WORK_DIR=""

[[ "$(release_sha256 "$FINAL_DMG")" == "$FINAL_DMG_SHA256" ]] || \
    release_die "published final DMG checksum changed"
[[ "$(/usr/bin/awk 'NR == 1 {print $1 " " $2}' "$FINAL_CHECKSUM")" == \
    "$FINAL_DMG_SHA256 $FINAL_DMG_ARTIFACT" ]] || \
    release_die "published final DMG checksum file is inconsistent"
UNEXPECTED_OUTPUT="$(/usr/bin/find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 \
    ! -name "$DMG_ARTIFACT" ! -name "$(basename "$UPLOAD_MANIFEST")" \
    ! -name "$(basename "$SUBMIT_RESPONSE")" ! -name "$(basename "$NOTARY_LOG")" \
    ! -name "$FINAL_DMG_ARTIFACT" ! -name "$FINAL_CHECKSUM_ARTIFACT" \
    ! -name "$FINAL_MANIFEST_ARTIFACT" -print -quit)"
[[ -z "$UNEXPECTED_OUTPUT" ]] || \
    release_die "unexpected file in completed notarized DMG directory: $UNEXPECTED_OUTPUT"

printf 'NOTARIZATION_STATUS=%s\n' "$NOTARY_STATUS"
printf 'NOTARIZATION_SUBMISSION_ID=%s\n' "$SUBMISSION_ID"
printf 'NOTARIZATION_RESPONSE=%s\n' "$SUBMIT_RESPONSE"
printf 'NOTARIZATION_LOG=%s\n' "$NOTARY_LOG"
printf 'UPLOAD_DMG=%s\n' "$UPLOAD_DMG"
printf 'UPLOAD_DMG_SHA256=%s\n' "$UPLOAD_DMG_SHA256"
printf 'DISTRIBUTION_DMG=%s\n' "$FINAL_DMG"
printf 'DISTRIBUTION_DMG_SHA256=%s\n' "$FINAL_DMG_SHA256"
printf 'DISTRIBUTION_DMG_CHECKSUM=%s\n' "$FINAL_CHECKSUM"
printf 'NOTARIZED_MANIFEST=%s\n' "$FINAL_MANIFEST"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=release_common.sh
source "$SCRIPT_DIR/release_common.sh"

usage() {
    cat <<'USAGE'
Usage: notarize_release.sh /path/to/versioned-release-directory

Required environment:
  HIREVA_SIGNING_MODE        Must be developer-id
  HIREVA_BUILD_ARCHS         Required architectures, comma or space separated
  HIREVA_NOTARY_PROFILE      Existing notarytool Keychain profile
  HIREVA_RELEASE_OUTPUT_DIR  Parent of the versioned release directory

Submits the exact checksummed ZIP with notarytool --wait, saves the submission
response and log, staples and validates the app, then creates a separate exact
notarized ZIP, checksum, and manifest. Credentials are read only through the
named Keychain profile and are never written to artifacts.
USAGE
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
if [[ "$RELEASE_SIGNING_MODE" != "developer-id" ]]; then
    release_die "notarization requires HIREVA_SIGNING_MODE=developer-id"
fi
release_load_architectures
release_require_env HIREVA_NOTARY_PROFILE
release_prepare_output_root

if [[ ! -d "$1" ]] || [[ -L "$1" ]]; then
    release_die "release directory does not exist or is a symbolic link: $1"
fi
RELEASE_DIR="$(cd "$1" && pwd -P)"
if [[ "$(dirname "$RELEASE_DIR")" != "$RELEASE_OUTPUT_ROOT" ]]; then
    release_die "release directory must be a direct child of HIREVA_RELEASE_OUTPUT_DIR"
fi

VERSION_MANIFEST="$RELEASE_DIR/version-manifest.json"
if [[ -L "$VERSION_MANIFEST" ]] || [[ ! -f "$VERSION_MANIFEST" ]] || ! /usr/bin/plutil -p "$VERSION_MANIFEST" >/dev/null; then
    release_die "missing or invalid version manifest: $VERSION_MANIFEST"
fi

APP_ARTIFACT="$(release_manifest_value "$VERSION_MANIFEST" app_artifact)" || \
    release_die "version manifest is missing app_artifact"
ZIP_ARTIFACT="$(release_manifest_value "$VERSION_MANIFEST" zip_artifact)" || \
    release_die "version manifest is missing zip_artifact"
CHECKSUM_ARTIFACT="$(release_manifest_value "$VERSION_MANIFEST" checksum_artifact)" || \
    release_die "version manifest is missing checksum_artifact"
EXPECTED_ZIP_SHA256="$(release_manifest_value "$VERSION_MANIFEST" zip_sha256)" || \
    release_die "version manifest is missing zip_sha256"
MANIFEST_MODE="$(release_manifest_value "$VERSION_MANIFEST" signing_mode)" || \
    release_die "version manifest is missing signing_mode"

for artifact in "$APP_ARTIFACT" "$ZIP_ARTIFACT" "$CHECKSUM_ARTIFACT"; do
    if [[ "$artifact" != "$(basename "$artifact")" ]]; then
        release_die "manifest artifact names must not contain path components: $artifact"
    fi
done
if [[ "$MANIFEST_MODE" != "developer-id" ]]; then
    release_die "version manifest was not produced for developer-id signing"
fi

APP_PATH="$RELEASE_DIR/$APP_ARTIFACT"
UPLOAD_ZIP="$RELEASE_DIR/$ZIP_ARTIFACT"
CHECKSUM_PATH="$RELEASE_DIR/$CHECKSUM_ARTIFACT"
if [[ ! -d "$APP_PATH" ]] || [[ ! -f "$UPLOAD_ZIP" ]] || [[ ! -f "$CHECKSUM_PATH" ]]; then
    release_die "versioned release directory is incomplete"
fi
for input in "$APP_PATH" "$UPLOAD_ZIP" "$CHECKSUM_PATH"; do
    if [[ -L "$input" ]]; then
        release_die "release artifacts must not be symbolic links: $input"
    fi
done

UPLOAD_ZIP_SHA256="$(release_sha256 "$UPLOAD_ZIP")"
if [[ "$UPLOAD_ZIP_SHA256" != "$EXPECTED_ZIP_SHA256" ]]; then
    release_die "ZIP checksum differs from version manifest; refusing to submit"
fi
CHECKSUM_LINE="$(/usr/bin/awk 'NR == 1 {print $1 " " $2}' "$CHECKSUM_PATH")"
if [[ "$CHECKSUM_LINE" != "$EXPECTED_ZIP_SHA256 $ZIP_ARTIFACT" ]]; then
    release_die "checksum file does not match the exact ZIP artifact"
fi

release_load_app "$APP_PATH"
release_reject_unstable_metadata
release_validate_architectures
release_assert_signature_mode "$RELEASE_APP_PATH"
release_verify_zip_matches_app "$APP_PATH" "$UPLOAD_ZIP"

ARTIFACT_STEM="${ZIP_ARTIFACT%.zip}"
SUBMIT_RESPONSE="$RELEASE_DIR/notarization-submit.plist"
NOTARY_LOG="$RELEASE_DIR/notarization-log.json"
FINAL_ZIP_ARTIFACT="$ARTIFACT_STEM.notarized.zip"
FINAL_CHECKSUM_ARTIFACT="$FINAL_ZIP_ARTIFACT.sha256"
FINAL_MANIFEST_ARTIFACT="notarized-manifest.json"
FINAL_ZIP="$RELEASE_DIR/$FINAL_ZIP_ARTIFACT"
FINAL_CHECKSUM="$RELEASE_DIR/$FINAL_CHECKSUM_ARTIFACT"
FINAL_MANIFEST="$RELEASE_DIR/$FINAL_MANIFEST_ARTIFACT"
for output in "$SUBMIT_RESPONSE" "$NOTARY_LOG" "$FINAL_ZIP" "$FINAL_CHECKSUM" "$FINAL_MANIFEST"; do
    if [[ -e "$output" ]] || [[ -L "$output" ]]; then
        release_die "notarization output already exists; refusing to overwrite: $output"
    fi
done

printf '[notary] submitting exact ZIP sha256=%s\n' "$UPLOAD_ZIP_SHA256"
TEMP_SUBMIT_RESPONSE="$(/usr/bin/mktemp "$RELEASE_DIR/.notarization-submit.XXXXXX")" || \
    release_die "unable to create temporary notary response file"
set +e
/usr/bin/xcrun notarytool submit "$UPLOAD_ZIP" \
    --keychain-profile "$HIREVA_NOTARY_PROFILE" \
    --wait \
    --output-format plist > "$TEMP_SUBMIT_RESPONSE"
SUBMIT_EXIT=$?
set -e

SUBMISSION_ID=""
NOTARY_STATUS=""
if /usr/bin/plutil -lint "$TEMP_SUBMIT_RESPONSE" >/dev/null 2>&1; then
    /bin/mv "$TEMP_SUBMIT_RESPONSE" "$SUBMIT_RESPONSE"
    TEMP_SUBMIT_RESPONSE=""
    SUBMISSION_ID="$(release_manifest_value "$SUBMIT_RESPONSE" id || true)"
    NOTARY_STATUS="$(release_manifest_value "$SUBMIT_RESPONSE" status || true)"
else
    /bin/rm -f "$TEMP_SUBMIT_RESPONSE"
    TEMP_SUBMIT_RESPONSE=""
fi
if [[ -n "$SUBMISSION_ID" ]]; then
    if ! /usr/bin/xcrun notarytool log "$SUBMISSION_ID" \
        --keychain-profile "$HIREVA_NOTARY_PROFILE" \
        "$NOTARY_LOG"; then
        release_die "notarization finished but its log could not be retrieved"
    fi
fi
if [[ "$SUBMIT_EXIT" -ne 0 ]]; then
    if [[ -f "$SUBMIT_RESPONSE" ]]; then
        release_die "notarytool submission failed; verify HIREVA_NOTARY_PROFILE and network access, then inspect $SUBMIT_RESPONSE"
    fi
    release_die "notarytool submission failed before returning a valid response; verify HIREVA_NOTARY_PROFILE and network access"
fi
if [[ -z "$SUBMISSION_ID" ]]; then
    release_die "notarytool response did not contain a submission id"
fi
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    release_die "notarization status is '$NOTARY_STATUS', expected 'Accepted'; inspect $NOTARY_LOG"
fi
if [[ ! -f "$NOTARY_LOG" ]]; then
    release_die "notarization log was not saved"
fi
if [[ "$(release_sha256 "$UPLOAD_ZIP")" != "$UPLOAD_ZIP_SHA256" ]]; then
    release_die "submitted ZIP changed during notarization"
fi

printf '[notary] stapling accepted ticket to app\n'
/usr/bin/xcrun stapler staple "$APP_PATH"
/usr/bin/xcrun stapler validate "$APP_PATH"
release_load_app "$APP_PATH"
release_validate_architectures
release_assert_signature_mode "$RELEASE_APP_PATH"
if ! /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"; then
    release_die "Gatekeeper assessment failed after stapling"
fi

WORK_DIR="$(/usr/bin/mktemp -d "$RELEASE_DIR/.hireva-notarized.XXXXXX")" || \
    release_die "unable to create final artifact work directory"
trap '/bin/rm -rf "$WORK_DIR"' EXIT
STAGED_FINAL_ZIP="$WORK_DIR/$FINAL_ZIP_ARTIFACT"
STAGED_FINAL_CHECKSUM="$WORK_DIR/$FINAL_CHECKSUM_ARTIFACT"
STAGED_FINAL_MANIFEST="$WORK_DIR/$FINAL_MANIFEST_ARTIFACT"

/usr/bin/ditto -c -k --keepParent --norsrc "$APP_PATH" "$STAGED_FINAL_ZIP"
if ! /usr/bin/unzip -tq "$STAGED_FINAL_ZIP" >/dev/null; then
    release_die "final notarized ZIP integrity validation failed"
fi
release_verify_zip_matches_app "$APP_PATH" "$STAGED_FINAL_ZIP"
FINAL_ZIP_SHA256="$(release_sha256 "$STAGED_FINAL_ZIP")"
printf '%s  %s\n' "$FINAL_ZIP_SHA256" "$FINAL_ZIP_ARTIFACT" > "$STAGED_FINAL_CHECKSUM"

/bin/cp "$VERSION_MANIFEST" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -convert xml1 "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -replace notarized -bool true "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert notarization_status -string "$NOTARY_STATUS" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert notarization_submission_id -string "$SUBMISSION_ID" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert upload_zip_artifact -string "$ZIP_ARTIFACT" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert upload_zip_sha256 -string "$UPLOAD_ZIP_SHA256" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert distribution_zip_artifact -string "$FINAL_ZIP_ARTIFACT" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert distribution_zip_sha256 -string "$FINAL_ZIP_SHA256" "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -insert stapled -bool true "$STAGED_FINAL_MANIFEST"
/usr/bin/plutil -convert json "$STAGED_FINAL_MANIFEST"

/bin/mv "$STAGED_FINAL_ZIP" "$FINAL_ZIP"
/bin/mv "$STAGED_FINAL_CHECKSUM" "$FINAL_CHECKSUM"
/bin/mv "$STAGED_FINAL_MANIFEST" "$FINAL_MANIFEST"

printf 'NOTARIZATION_STATUS=%s\n' "$NOTARY_STATUS"
printf 'NOTARIZATION_SUBMISSION_ID=%s\n' "$SUBMISSION_ID"
printf 'NOTARIZATION_LOG=%s\n' "$NOTARY_LOG"
printf 'DISTRIBUTION_ZIP=%s\n' "$FINAL_ZIP"
printf 'DISTRIBUTION_ZIP_SHA256=%s\n' "$FINAL_ZIP_SHA256"
printf 'NOTARIZED_MANIFEST=%s\n' "$FINAL_MANIFEST"

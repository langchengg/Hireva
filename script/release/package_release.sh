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
release_validate_architectures
release_assert_signature_mode "$RELEASE_APP_PATH"
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
release_validate_architectures
release_assert_signature_mode "$RELEASE_APP_PATH"

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

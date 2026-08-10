#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
APP_BUNDLE="$ROOT_DIR/dist/Hireva.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Hireva"
OUTPUT_DIR="$ROOT_DIR/release"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

printf '[build] Building, signing, launching, and verifying Hireva.app\n'
"$ROOT_DIR/script/build_and_run.sh" --verify

[[ -d "$APP_BUNDLE" ]] || fail "app bundle is missing: $APP_BUNDLE"
[[ ! -L "$APP_BUNDLE" ]] || fail "app bundle must not be a symbolic link"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist is missing: $INFO_PLIST"
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"
[[ -x "$APP_BINARY" ]] || fail "app executable is missing or not executable: $APP_BINARY"

PRODUCT_NAME="$(plist_value "$INFO_PLIST" CFBundleName)" || fail "CFBundleName is missing"
VERSION="$(plist_value "$INFO_PLIST" CFBundleShortVersionString)" || \
    fail "CFBundleShortVersionString is missing"
SIGNING_MODE="$(plist_value "$INFO_PLIST" HirevaSigningMode)" || \
    fail "HirevaSigningMode is missing"

[[ "$PRODUCT_NAME" == "Hireva" ]] || fail "CFBundleName must be Hireva"
[[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe app version: $VERSION"
case "$SIGNING_MODE" in
    adhoc|development|developer-id) ;;
    *) fail "unsupported embedded signing mode: $SIGNING_MODE" ;;
esac

ARCHITECTURES="$(/usr/bin/lipo -archs "$APP_BINARY" 2>/dev/null)" || \
    fail "unable to inspect app architecture"
[[ "$ARCHITECTURES" == "arm64" ]] || \
    fail "DMG packaging requires an arm64-only app; found: $ARCHITECTURES"

printf '[verify] Validating the source app and nested Mach-O signatures\n'
HIREVA_SIGNING_MODE="$SIGNING_MODE" HIREVA_BUILD_ARCHS="arm64" \
    "$ROOT_DIR/script/release/verify_app.sh" "$APP_BUNDLE"

for required_path in \
    "$APP_BUNDLE/Contents/Helpers/parakeet_asr_helper" \
    "$APP_BUNDLE/Contents/Frameworks/libsherpa-onnx-c-api.dylib" \
    "$APP_BUNDLE/Contents/Frameworks/libonnxruntime.1.27.0.dylib" \
    "$APP_BUNDLE/Contents/Resources/Documentation/privacy-and-data-flow.md" \
    "$APP_BUNDLE/Contents/Resources/ThirdPartyNotices/sherpa-onnx-LICENSE.txt"; do
    [[ -s "$required_path" ]] || fail "required bundled runtime payload is missing: $required_path"
done

FORBIDDEN_PAYLOAD="$(/usr/bin/find "$APP_BUNDLE/Contents" \( \
    -type d \( -name '.git' -o -name '.build' -o -name 'LocalModels' -o -name '__pycache__' \) -o \
    -type f \( -iname '*.sqlite' -o -iname '*.sqlite3' -o -iname '*.db' -o \
        -iname '*.jsonl' -o -iname '*.trace' -o -iname '*.log' -o -iname '*.wav' -o \
        -iname '*.onnx' -o -iname '*.gguf' -o -iname '*.dmg' -o -iname '*.zip' -o \
        -iname '*.pem' -o -iname '*.p12' -o -iname '*.key' -o -iname '.env' \) \
    \) -print -quit)"
[[ -z "$FORBIDDEN_PAYLOAD" ]] || \
    fail "private, generated, or model payload found in app: $FORBIDDEN_PAYLOAD"

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hireva-dmg.XXXXXX")" || \
    fail "unable to create a temporary packaging directory"
cleanup() {
    /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

STAGING_DIR="$WORK_DIR/staging"
STAGED_APP="$STAGING_DIR/Hireva.app"
TEMP_DMG="$WORK_DIR/Hireva-$VERSION-arm64.dmg"
FINAL_DMG="$OUTPUT_DIR/Hireva-$VERSION-arm64.dmg"

/bin/mkdir "$STAGING_DIR"
/usr/bin/ditto --norsrc "$APP_BUNDLE" "$STAGED_APP"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

[[ -L "$STAGING_DIR/Applications" ]] || fail "Applications symlink was not created"
[[ "$(/usr/bin/readlink "$STAGING_DIR/Applications")" == "/Applications" ]] || \
    fail "Applications symlink has an unexpected target"

UNEXPECTED_TOP_LEVEL="$(/usr/bin/find "$STAGING_DIR" -mindepth 1 -maxdepth 1 \
    ! -name 'Hireva.app' ! -name 'Applications' -print -quit)"
[[ -z "$UNEXPECTED_TOP_LEVEL" ]] || \
    fail "unexpected top-level DMG payload: $UNEXPECTED_TOP_LEVEL"

printf '[verify] Validating the staged app copy\n'
HIREVA_SIGNING_MODE="$SIGNING_MODE" HIREVA_BUILD_ARCHS="arm64" \
    "$ROOT_DIR/script/release/verify_app.sh" "$STAGED_APP"

printf '[package] Creating %s\n' "$(basename "$FINAL_DMG")"
/usr/bin/hdiutil create \
    -volname "Hireva" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$TEMP_DMG"

/usr/bin/hdiutil verify "$TEMP_DMG"
/bin/mkdir -p "$OUTPUT_DIR"
if [[ -e "$FINAL_DMG" ]]; then
    printf '[package] Replacing existing local developer-preview DMG\n'
fi
/bin/mv -f "$TEMP_DMG" "$FINAL_DMG"

DMG_SHA256="$(/usr/bin/shasum -a 256 "$FINAL_DMG" | /usr/bin/awk '{print $1}')"
DMG_SIZE="$(/usr/bin/stat -f '%z' "$FINAL_DMG")"

printf 'DMG_PATH=%s\n' "$FINAL_DMG"
printf 'DMG_VERSION=%s\n' "$VERSION"
printf 'DMG_ARCHITECTURE=arm64\n'
printf 'DMG_SIGNING_MODE=%s\n' "$SIGNING_MODE"
printf 'DMG_SIZE_BYTES=%s\n' "$DMG_SIZE"
printf 'DMG_SHA256=%s\n' "$DMG_SHA256"

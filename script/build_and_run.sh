#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Hireva - Build, Sign & Launch
#
# Key requirement: keep the bundle identifier and path stable.
#
# macOS TCC (Transparency, Consent and Control) also evaluates the code signing
# requirement. Signing is selected explicitly with HIREVA_SIGNING_MODE. The
# local ad-hoc mode uses an identifier-only requirement but remains
# non-distributable; development and Developer ID modes never fall back.
#
# After granting permission to an ad-hoc build, use --relaunch to restart the
# existing signed bundle without replacing or re-signing it.
# =============================================================================

MODE="${1:-run}"
REQUESTED_SIGNING_IDENTITY="${HIREVA_SIGNING_IDENTITY:-${INTERVIEW_COPILOT_SIGNING_IDENTITY:-}}"
REQUESTED_SIGNING_MODE="${HIREVA_SIGNING_MODE:-adhoc}"
REQUESTED_SWIFTPM_BUILD_PATH="${HIREVA_SWIFTPM_BUILD_PATH:-${INTERVIEW_COPILOT_SWIFTPM_BUILD_PATH:-}}"
REQUESTED_PREBUILT_BINARY="${HIREVA_PREBUILT_BINARY:-${INTERVIEW_COPILOT_PREBUILT_BINARY:-}}"
REQUESTED_FIXED_USER_HOME="${HIREVA_FIXED_USER_HOME:-${INTERVIEW_COPILOT_FIXED_USER_HOME:-}}"
REQUESTED_BUILD_ARCHS="${HIREVA_BUILD_ARCHS:-arm64}"

# --- Stable identity constants (do NOT change without resetting TCC) ---
APP_NAME="Hireva"                                  # .app bundle name
EXECUTABLE_NAME="Hireva"                           # CFBundleExecutable (binary inside .app)
SPM_PRODUCT_NAME="Hireva"                          # SPM product name (output of swift build)
BUNDLE_ID="com.langcheng.Hireva"
DISPLAY_NAME="Hireva"
VERSION="0.1.0"
BUILD_NUMBER="1"
MIN_SYSTEM_VERSION="14.0"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_DOCUMENTATION="$APP_RESOURCES/Documentation"
APP_THIRD_PARTY_NOTICES="$APP_RESOURCES/ThirdPartyNotices"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icns"
APP_ICON_BUNDLE="$APP_RESOURCES/AppIcon.icns"
PARAKEET_RUNTIME_BUILD_DIR="${HIREVA_PARAKEET_RUNTIME_BUILD_DIR:-$ROOT_DIR/.build/parakeet-helper}"
PARAKEET_HELPER_BUILD="$PARAKEET_RUNTIME_BUILD_DIR/Helpers/parakeet_asr_helper"
PARAKEET_HELPER_BUNDLE="$APP_HELPERS/parakeet_asr_helper"
BUILD_TIMESTAMP_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_COMMIT_HASH="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if GIT_STATUS_PORCELAIN="$(git status --porcelain --untracked-files=normal 2>/dev/null)"; then
        if [[ -n "$GIT_STATUS_PORCELAIN" ]]; then
            GIT_TREE_STATE="dirty"
        else
            GIT_TREE_STATE="clean"
        fi
    else
        GIT_TREE_STATE="unknown"
    fi
else
    GIT_TREE_STATE="unknown"
fi
EXPECTED_BUNDLE_PATH="$APP_BUNDLE"
BUNDLE_CONTENTS_CLEARED_BEFORE_REBUILD="no"

case "$REQUESTED_SIGNING_MODE" in
    adhoc|development|developer-id)
        ;;
    *)
        echo "[sign] ERROR: HIREVA_SIGNING_MODE must be adhoc, development, or developer-id." >&2
        exit 2
        ;;
esac

if [[ "$REQUESTED_BUILD_ARCHS" != "arm64" ]]; then
    echo "[build] ERROR: this release currently supports only HIREVA_BUILD_ARCHS=arm64." >&2
    exit 2
fi

if [[ "$REQUESTED_SIGNING_MODE" == "developer-id" ]]; then
    if [[ "$GIT_TREE_STATE" != "clean" ]]; then
        echo "[build] ERROR: developer-id builds require a clean Git worktree; found $GIT_TREE_STATE." >&2
        exit 2
    fi
    BUILD_CONFIGURATION="${HIREVA_BUILD_CONFIGURATION:-release}"
else
    BUILD_CONFIGURATION="${HIREVA_BUILD_CONFIGURATION:-debug}"
fi
if [[ "$BUILD_CONFIGURATION" != "debug" && "$BUILD_CONFIGURATION" != "release" ]]; then
    echo "[build] ERROR: HIREVA_BUILD_CONFIGURATION must be debug or release." >&2
    exit 2
fi

launch_existing_bundle() {
    local open_args=(-n)

    if [[ ! -d "$APP_BUNDLE" || ! -x "$APP_BINARY" ]]; then
        echo "[Launch] ERROR: runnable app bundle not found at $APP_BUNDLE" >&2
        echo "[Launch] Run $0 --verify once before using --relaunch." >&2
        return 1
    fi

    if ! codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"; then
        echo "[Launch] ERROR: existing app bundle failed code-signature verification." >&2
        return 1
    fi

    if [[ -x "$LSREGISTER" ]]; then
        "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || {
            echo "[Launch] WARNING: could not refresh the current LaunchServices registration." >&2
        }
    fi

    if [[ -n "$REQUESTED_FIXED_USER_HOME" ]]; then
        mkdir -p "$REQUESTED_FIXED_USER_HOME"
        open_args+=(--env "CFFIXED_USER_HOME=$REQUESTED_FIXED_USER_HOME")
        echo "[Launch]   Fixed user home: $REQUESTED_FIXED_USER_HOME"
    fi

    if [[ "${HIREVA_VERIFICATION_MODE:-}" == "1" ]]; then
        for variable_name in \
            HIREVA_VERIFICATION_MODE \
            HIREVA_VERIFICATION_SCENARIO_PATH \
            HIREVA_VERIFICATION_OUTPUT_ROOT \
            HIREVA_VERIFICATION_APP_SUPPORT_DIR \
            HIREVA_VERIFICATION_MODEL_ROOT; do
            variable_value="${!variable_name:-}"
            if [[ -n "$variable_value" ]]; then
                open_args+=(--env "$variable_name=$variable_value")
            fi
        done
        echo "[Launch]   Verification mode: enabled with explicit scenario"
    fi

    /usr/bin/open "${open_args[@]}" "$APP_BUNDLE"
}

verify_launched_process() {
    local app_pid=""

    for i in {1..20}; do
        app_pid="$(pgrep -f "$APP_BINARY" | head -1 || true)"
        if [[ -n "$app_pid" ]]; then
            break
        fi
        sleep 0.5
    done
    if [[ -n "$app_pid" ]]; then
        sleep 2
    fi
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
        echo "$app_pid"
        return 0
    fi
    return 1
}

print_usage() {
    cat <<EOF
usage: $0 [run|--relaunch|--debug|--logs|--telemetry|--verify|--identity-check|--reset-tcc]

  run               Build, sign, and launch (default)
  --relaunch        Relaunch the existing signed bundle without rebuilding or re-signing
  --debug           Build and launch under lldb
  --logs            Build, launch, and stream process logs
  --telemetry       Build, launch, and stream subsystem logs
  --verify          Build, launch, and verify the app is running
  --identity-check  Verify CFBundleIdentifier, codesign authority, designated requirement, and cdhash
  --reset-tcc       Reset all TCC permissions for the app's bundle ID

Environment:
  HIREVA_FIXED_USER_HOME=/path
                     Pass CFFIXED_USER_HOME only to the launched app process
  HIREVA_SIGNING_MODE=adhoc|development|developer-id
                     Select an explicit signing mode; no implicit fallback.
  HIREVA_SIGNING_IDENTITY, HIREVA_SWIFTPM_BUILD_PATH, HIREVA_PREBUILT_BINARY,
  HIREVA_BUILD_ARCHS=arm64, HIREVA_BUILD_CONFIGURATION=debug|release
                     Configure signing, architecture, and build inputs.
EOF
}

# Reject unsupported modes before any process is stopped or bundle is rebuilt.
case "$MODE" in
    run|--relaunch|relaunch|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--identity-check|identity-check|--reset-tcc|reset-tcc)
        ;;
    --help|help|-h)
        print_usage
        exit 0
        ;;
    *)
        print_usage >&2
        exit 2
        ;;
esac

# --- Handle --reset-tcc mode early ---
if [[ "$MODE" == "--reset-tcc" || "$MODE" == "reset-tcc" ]]; then
    echo "Resetting TCC permissions for $BUNDLE_ID ..."
    tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset SpeechRecognition "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
    echo "Done. Rebuild and relaunch to re-grant permissions."
    exit 0
fi

cd "$ROOT_DIR"

# Permission prompts may relaunch the current app process. This mode intentionally
# runs before every build, bundle replacement, and signing operation so the
# process always points to the exact bundle whose permissions were granted.
if [[ "$MODE" == "--relaunch" || "$MODE" == "relaunch" ]]; then
    echo "[relaunch] Relaunching the existing signed bundle without rebuilding or re-signing..."
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 &
    RELAUNCH_QUIT_PID=$!
    for i in {1..8}; do
        if ! kill -0 "$RELAUNCH_QUIT_PID" >/dev/null 2>&1; then
            wait "$RELAUNCH_QUIT_PID" >/dev/null 2>&1 || true
            break
        fi
        sleep 0.25
    done
    if kill -0 "$RELAUNCH_QUIT_PID" >/dev/null 2>&1; then
        echo "[relaunch] WARNING: AppleScript quit request timed out."
        kill "$RELAUNCH_QUIT_PID" >/dev/null 2>&1 || true
        wait "$RELAUNCH_QUIT_PID" >/dev/null 2>&1 || true
    fi
    for i in {1..12}; do
        if ! pgrep -f "$APP_BINARY" >/dev/null; then
            break
        fi
        sleep 0.25
    done
    if pgrep -f "$APP_BINARY" >/dev/null; then
        echo "[relaunch] WARNING: graceful quit timed out; stopping the existing bundle process."
        pkill -f "$APP_BINARY" >/dev/null 2>&1 || true
        sleep 0.5
    fi

    launch_existing_bundle
    if APP_PID="$(verify_launched_process)"; then
        echo "[relaunch] $EXECUTABLE_NAME is running from the unchanged bundle (pid $APP_PID)."
        exit 0
    fi
    echo "[relaunch] ERROR: $EXECUTABLE_NAME did not remain running from $APP_BINARY." >&2
    exit 1
fi

# --- Quit existing app instance ---
# Required first step for every build: stop the user-facing process name.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
echo "[quit] Attempting graceful quit of $BUNDLE_ID ..."
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 &
QUIT_SCRIPT_PID=$!
for i in {1..8}; do
    if ! kill -0 "$QUIT_SCRIPT_PID" >/dev/null 2>&1; then
        wait "$QUIT_SCRIPT_PID" >/dev/null 2>&1 || true
        break
    fi
    sleep 0.25
done
if kill -0 "$QUIT_SCRIPT_PID" >/dev/null 2>&1; then
    echo "[quit] WARNING: AppleScript quit request timed out. Continuing with process fallback..."
    kill "$QUIT_SCRIPT_PID" >/dev/null 2>&1 || true
    wait "$QUIT_SCRIPT_PID" >/dev/null 2>&1 || true
fi

# Wait up to 3 seconds for the processes to exit
for i in {1..12}; do
    if ! pgrep -x "$EXECUTABLE_NAME" >/dev/null && ! pgrep -x "$SPM_PRODUCT_NAME" >/dev/null; then
        echo "[quit] Application exited gracefully."
        break
    fi
    sleep 0.25
done

# Path-specific fallback kill if still running after 3 seconds
if pgrep -x "$EXECUTABLE_NAME" >/dev/null || pgrep -x "$SPM_PRODUCT_NAME" >/dev/null; then
    echo "[quit] WARNING: Application did not quit gracefully within 3 seconds. Using pkill fallback..."
    pkill -f "$APP_BINARY" >/dev/null 2>&1 || true
    pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
    pkill -x "$SPM_PRODUCT_NAME" >/dev/null 2>&1 || true
    sleep 0.5
fi

# --- Build ---
if [[ -n "$REQUESTED_PREBUILT_BINARY" ]]; then
    if [[ "$REQUESTED_SIGNING_MODE" == "developer-id" ]]; then
        echo "[build] ERROR: developer-id distribution does not accept HIREVA_PREBUILT_BINARY." >&2
        exit 2
    fi
    echo "[build] Using prebuilt binary: $REQUESTED_PREBUILT_BINARY"
    BUILD_BINARY="$REQUESTED_PREBUILT_BINARY"
else
    echo "[build] Building $SPM_PRODUCT_NAME ($BUILD_CONFIGURATION, arm64) ..."
    SWIFTPM_BUILD_ARGS=(-c "$BUILD_CONFIGURATION" --arch arm64)
    if [[ -n "$REQUESTED_SWIFTPM_BUILD_PATH" ]]; then
        mkdir -p "$REQUESTED_SWIFTPM_BUILD_PATH"
        SWIFTPM_BUILD_ARGS+=(--build-path "$REQUESTED_SWIFTPM_BUILD_PATH")
        echo "[build] Using SwiftPM build path: $REQUESTED_SWIFTPM_BUILD_PATH"
    fi
    swift build "${SWIFTPM_BUILD_ARGS[@]}"
    BUILD_BINARY="$(swift build "${SWIFTPM_BUILD_ARGS[@]}" --show-bin-path)/$SPM_PRODUCT_NAME"
fi

if [[ ! -f "$BUILD_BINARY" ]]; then
    echo "[build] ERROR: Built binary not found at $BUILD_BINARY" >&2
    exit 1
fi

# --- Assemble .app bundle ---
# Preserve the outer .app directory. Cloud file providers can move a deleted
# bundle into their own Trash, where LaunchServices may register it as a second
# app with the same bundle identifier. Replacing only Contents keeps one path.
echo "[bundle] Clearing stale bundle contents at $APP_CONTENTS ..."
mkdir -p "$APP_BUNDLE"
rm -rf "$APP_CONTENTS"
find "$DIST_DIR" -name '._*' -delete 2>/dev/null || true
find "$DIST_DIR" -name '.DS_Store' -delete 2>/dev/null || true
if [[ ! -e "$APP_CONTENTS" ]]; then
    BUNDLE_CONTENTS_CLEARED_BEFORE_REBUILD="yes"
else
    echo "[bundle] ERROR: stale bundle contents still exist after removal: $APP_CONTENTS" >&2
    exit 1
fi
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_HELPERS" "$APP_FRAMEWORKS" \
    "$APP_DOCUMENTATION" "$APP_THIRD_PARTY_NOTICES"

# Copy the SPM product binary, renamed to match CFBundleExecutable
# Clean up any stale binaries from previous builds with different executable names
find "$APP_MACOS" -type f ! -name "$EXECUTABLE_NAME" -delete 2>/dev/null || true
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# --- Generate Info.plist ---
/usr/bin/plutil -create xml1 "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleExecutable         -string "$EXECUTABLE_NAME"     "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleIdentifier         -string "$BUNDLE_ID"           "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleName               -string "$APP_NAME"            "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleDisplayName        -string "$DISPLAY_NAME"        "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleIconFile           -string "AppIcon"             "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleShortVersionString  -string "$VERSION"            "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleVersion            -string "$BUILD_NUMBER"        "$INFO_PLIST"
/usr/bin/plutil -insert CFBundlePackageType        -string "APPL"                 "$INFO_PLIST"
/usr/bin/plutil -insert LSMinimumSystemVersion     -string "$MIN_SYSTEM_VERSION"  "$INFO_PLIST"
/usr/bin/plutil -insert NSPrincipalClass           -string "NSApplication"        "$INFO_PLIST"
/usr/bin/plutil -insert NSHighResolutionCapable    -bool true                     "$INFO_PLIST"
/usr/bin/plutil -insert NSHumanReadableCopyright   -string "Copyright 2026"       "$INFO_PLIST"
/usr/bin/plutil -insert HirevaBuildTimestampUTC    -string "$BUILD_TIMESTAMP_UTC" "$INFO_PLIST"
/usr/bin/plutil -insert HirevaGitCommitHash        -string "$GIT_COMMIT_HASH"     "$INFO_PLIST"
/usr/bin/plutil -insert HirevaGitBranch            -string "$GIT_BRANCH"          "$INFO_PLIST"
/usr/bin/plutil -insert HirevaGitTreeState         -string "$GIT_TREE_STATE"      "$INFO_PLIST"
/usr/bin/plutil -insert HirevaSigningMode          -string "$REQUESTED_SIGNING_MODE" "$INFO_PLIST"
/usr/bin/plutil -insert HirevaRuntimeMode          -string "bundled_native"        "$INFO_PLIST"
if [[ "$REQUESTED_SIGNING_MODE" == "developer-id" ]]; then
    /usr/bin/plutil -insert HirevaDistributionBuild -bool true "$INFO_PLIST"
else
    /usr/bin/plutil -insert HirevaDistributionBuild -bool false "$INFO_PLIST"
    /usr/bin/plutil -insert HirevaSourceRoot         -string "$ROOT_DIR"            "$INFO_PLIST"
    /usr/bin/plutil -insert HirevaExpectedBundlePath -string "$EXPECTED_BUNDLE_PATH" "$INFO_PLIST"
fi

# --- Usage descriptions (required for TCC prompts) ---
/usr/bin/plutil -insert NSMicrophoneUsageDescription \
    -string "Hireva uses the microphone to transcribe interview audio in real time." \
    "$INFO_PLIST"
/usr/bin/plutil -insert NSSpeechRecognitionUsageDescription \
    -string "Hireva uses Apple Speech Recognition to create live interview transcripts." \
    "$INFO_PLIST"
/usr/bin/plutil -insert NSScreenCaptureUsageDescription \
    -string "Hireva captures system audio to detect interviewer questions automatically." \
    "$INFO_PLIST"
/usr/bin/plutil -insert NSAudioCaptureUsageDescription \
    -string "Hireva captures system audio for real-time interviewer question detection." \
    "$INFO_PLIST"

# --- App Icon ---
if [[ ! -f "$APP_ICON_SOURCE" ]]; then
    echo "[bundle] ERROR: App icon not found at $APP_ICON_SOURCE" >&2
    exit 1
fi
echo "[bundle] Copying app icon to bundle resources..."
cp "$APP_ICON_SOURCE" "$APP_ICON_BUNDLE"

echo "[bundle] Copying release documentation and verified third-party notices..."
for document in \
    third-party-licenses.md \
    privacy-and-data-flow.md \
    release-installation.md \
    local-model-installation.md \
    release-notes-0.1.0.md; do
    cp "$ROOT_DIR/docs/$document" "$APP_DOCUMENTATION/$document"
done
NOTICE_SOURCE_DIR="$("$ROOT_DIR/script/runtime/prepare_third_party_notices.sh")"
cp "$NOTICE_SOURCE_DIR"/*.txt "$APP_THIRD_PARTY_NOTICES/"

echo "[bundle] Building the pinned native Parakeet runtime..."
"$ROOT_DIR/script/runtime/build_parakeet_helper.sh" "$PARAKEET_RUNTIME_BUILD_DIR" >/dev/null
if [[ ! -x "$PARAKEET_HELPER_BUILD" ]]; then
    echo "[bundle] ERROR: native Parakeet helper was not produced." >&2
    exit 1
fi
cp "$PARAKEET_HELPER_BUILD" "$PARAKEET_HELPER_BUNDLE"
cp "$PARAKEET_RUNTIME_BUILD_DIR/Frameworks/libsherpa-onnx-c-api.dylib" "$APP_FRAMEWORKS/"
cp "$PARAKEET_RUNTIME_BUILD_DIR/Frameworks/libonnxruntime.1.27.0.dylib" "$APP_FRAMEWORKS/"
chmod 0755 "$PARAKEET_HELPER_BUNDLE"

if find "$APP_CONTENTS" -type f \( -name 'parakeet_asr_sidecar.py' -o -name 'parakeet_asr_sidecar' \) | grep -q .; then
    echo "[bundle] ERROR: legacy Python Parakeet runtime leaked into the app bundle." >&2
    exit 1
fi

# Google Drive/Finder can leave extended attributes or AppleDouble files inside
# the assembled bundle; codesign rejects those as resource-fork detritus.
echo "[sign] Clearing bundle extended attributes before signing..."
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
find "$DIST_DIR" -name '._*' -delete 2>/dev/null || true
find "$DIST_DIR" -name '.DS_Store' -delete 2>/dev/null || true

print_signing_diagnostics() {
    local signing_details
    local team_identifier
    local signing_authority
    local quarantine_exists="no"
    local inside_google_drive="no"
    local apple_double_file

    echo ""
    echo "======================================================================"
    echo "Signing and launch diagnostics"
    echo "======================================================================"
    echo "App path: $APP_BUNDLE"
    echo "Executable path: $APP_BINARY"
    echo "Bundle ID: $BUNDLE_ID"

    signing_details="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 || true)"
    team_identifier="$(printf '%s\n' "$signing_details" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    signing_authority="$(printf '%s\n' "$signing_details" | awk -F= '/^Authority=/{print $2; exit}')"
    echo "TeamIdentifier: ${team_identifier:-not set}"
    echo "Signing authority: ${signing_authority:-none (ad-hoc or unsigned)}"

    if xattr -p com.apple.quarantine "$APP_BUNDLE" >/dev/null 2>&1; then
        quarantine_exists="yes"
    fi
    if [[ "$APP_BUNDLE" == *"/Library/CloudStorage/GoogleDrive-"* ]]; then
        inside_google_drive="yes"
    fi
    apple_double_file="$(find "$APP_BUNDLE" -name '._*' -print -quit 2>/dev/null || true)"
    echo "Quarantine xattr exists: $quarantine_exists"
    echo "Inside Google Drive path: $inside_google_drive"
    if [[ -n "$apple_double_file" ]]; then
        echo "AppleDouble files exist: yes ($apple_double_file)"
    else
        echo "AppleDouble files exist: no"
    fi
    echo "Bundle contents cleared before rebuild: $BUNDLE_CONTENTS_CLEARED_BEFORE_REBUILD"

    echo ""
    echo "+ codesign -dv --verbose=4 $APP_BUNDLE"
    codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 || true
    echo "+ codesign --verify --deep --strict --verbose=4 $APP_BUNDLE"
    codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE" 2>&1 || true
    echo "+ spctl --assess --type execute --verbose=4 $APP_BUNDLE"
    spctl --assess --type execute --verbose=4 "$APP_BUNDLE" 2>&1 || true
    echo "+ xattr -lr $APP_BUNDLE"
    xattr -lr "$APP_BUNDLE" 2>&1 || true
    echo "+ log show --predicate 'process == \"amfid\" OR eventMessage CONTAINS \"Hireva\"' --last 5m --style compact"
    /usr/bin/log show \
        --predicate 'process == "amfid" OR eventMessage CONTAINS "Hireva"' \
        --last 5m \
        --style compact 2>&1 || true
    echo "======================================================================"
}

# --- Code Signing ---
echo "[sign] Available code-signing identities:"
security find-identity -v -p codesigning || true
SIGNING_IDENTITY="$REQUESTED_SIGNING_IDENTITY"
echo "[sign] Explicit mode: $REQUESTED_SIGNING_MODE"
HIREVA_SIGNING_MODE="$REQUESTED_SIGNING_MODE" \
HIREVA_BUILD_ARCHS="$REQUESTED_BUILD_ARCHS" \
HIREVA_SIGNING_IDENTITY="$SIGNING_IDENTITY" \
    "$ROOT_DIR/script/release/sign_app.sh" "$APP_BUNDLE"

echo "[sign] Verifying code signature..."
if ! HIREVA_SIGNING_MODE="$REQUESTED_SIGNING_MODE" \
    HIREVA_BUILD_ARCHS="$REQUESTED_BUILD_ARCHS" \
    "$ROOT_DIR/script/release/verify_app.sh" "$APP_BUNDLE"; then
    echo "[sign] ERROR: code signature verification failed." >&2
    print_signing_diagnostics
    exit 1
fi

echo ""
echo "[sign] Running signing diagnostics..."
codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 || true
codesign -d -r- "$APP_BUNDLE" 2>&1 || true
echo "[sign] Gatekeeper pre-notarization assessment (ad-hoc rejection is expected):"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE" || true
echo ""

echo "[sign] Log Identity Information:"
echo "  - Signing Mode: $REQUESTED_SIGNING_MODE"
echo "  - Signing Identity: ${SIGNING_IDENTITY:-Ad-Hoc (non-distributable)}"
echo "  - TeamIdentifier: $(codesign -dv "$APP_BUNDLE" 2>&1 | grep "TeamIdentifier" | cut -d= -f2 || echo "None")"
echo "  - CFBundleIdentifier: $BUNDLE_ID"
echo "  - Executable Path: $APP_BINARY"
echo "  - App Bundle Path: $APP_BUNDLE"
echo ""

echo "[verify] Bundle timestamps:"
stat -f "%Sm  %N" "$APP_BINARY"
stat -f "%Sm  %N" "$INFO_PLIST"
stat -f "%Sm  %N" "$APP_ICON_BUNDLE"
echo ""

echo "[verify] Bundle identity:"
plutil -p "$INFO_PLIST" | grep -E "CFBundleIdentifier|CFBundleName|CFBundleExecutable|CFBundleIconFile|NSMicrophoneUsageDescription|NSSpeechRecognitionUsageDescription"
codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" || true
echo ""

# --- Launch ---
open_app() {
    echo "[Launch] Launching $APP_NAME..."
    echo "[Launch]   Bundle Path: $APP_BUNDLE"
    echo "[Launch]   Bundle ID:   $BUNDLE_ID"
    echo "[Launch]   Binary Path: $APP_BINARY"
    echo "[Launch]   Signature Info:"
    codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E "Identifier|Authority|Signature" | sed 's/^/  /' || true
    launch_existing_bundle
}

case "$MODE" in
    run)
        open_app
        echo "[run] Launched $APP_BUNDLE"
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        echo "[logs] Streaming process logs for $EXECUTABLE_NAME ..."
        /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        echo "[telemetry] Streaming subsystem logs for $BUNDLE_ID ..."
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        if open_app; then
            :
        else
            launch_status=$?
            echo "[verify] ERROR: open failed with exit $launch_status." >&2
            print_signing_diagnostics
            exit "$launch_status"
        fi
        if APP_PID="$(verify_launched_process)"; then
            echo "[verify] ✅ $EXECUTABLE_NAME is running from the expected path (pid $APP_PID)."
            echo "[verify] Bundle: $APP_BUNDLE"
            echo "[verify] Bundle ID: $BUNDLE_ID"
            echo "[verify] CFBundleExecutable: $EXECUTABLE_NAME"
            codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E "Identifier|Authority|Signature" || true
        else
            echo "[verify] ❌ $EXECUTABLE_NAME is NOT running from $APP_BINARY."
            print_signing_diagnostics
            exit 1
        fi
        ;;
    --identity-check|identity-check)
        echo "=== [Identity Check] ==="
        echo "Bundle Path: $APP_BUNDLE"
        if [[ ! -d "$APP_BUNDLE" ]]; then
            echo "Bundle not built yet. Run build first."
            exit 1
        fi
        if [[ -f "$INFO_PLIST" ]]; then
            echo "CFBundleIdentifier: $(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$INFO_PLIST" 2>/dev/null || echo "Unknown")"
        else
            echo "CFBundleIdentifier: Info.plist missing"
        fi
        echo ""
        echo "Codesign Info:"
        codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E "Identifier|Authority|Signature|TeamIdentifier" || true
        echo ""
        echo "Designated Requirement:"
        codesign -d -r- "$APP_BUNDLE" 2>&1 || true
        echo ""
        echo "cdhash:"
        codesign -dvvvv "$APP_BUNDLE" 2>&1 | grep "CDHash" || true
        echo ""
        echo "Executable Path: $APP_BINARY"
        echo "========================"
        ;;
    --reset-tcc|reset-tcc)
        # handled above
        ;;
    *)
        print_usage >&2
        exit 2
        ;;
esac

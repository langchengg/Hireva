#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Interview Copilot Mac — Build, Sign & Launch
#
# Key requirement: STABLE APP IDENTITY across rebuilds.
#
# macOS TCC (Transparency, Consent and Control) tracks permissions by:
#   bundle identifier + code signing identity + bundle path
#
# If any of these change, macOS treats it as a different app and re-prompts.
# This script ensures all three remain constant across normal rebuilds.
# =============================================================================

MODE="${1:-run}"

# --- Stable identity constants (do NOT change without resetting TCC) ---
APP_NAME="InterviewCopilotMac"                    # .app bundle name
EXECUTABLE_NAME="InterviewCopilotMacRunner"       # CFBundleExecutable (binary inside .app)
LEGACY_EXECUTABLE_NAME="InterviewCopilotMac"
SPM_PRODUCT_NAME="InterviewCopilotMac"            # SPM product name (output of swift build)
BUNDLE_ID="com.langcheng.InterviewCopilotMac"
DISPLAY_NAME="Interview Copilot"
VERSION="0.1.0"
BUILD_NUMBER="1"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
BUILD_TIMESTAMP_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_COMMIT_HASH="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
EXPECTED_BUNDLE_PATH="$APP_BUNDLE"

# --- Handle --reset-tcc mode early ---
if [[ "$MODE" == "--reset-tcc" || "$MODE" == "reset-tcc" ]]; then
    echo "Resetting TCC permissions for $BUNDLE_ID ..."
    tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset SpeechRecognition "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
    echo ""
    echo "Also resetting old bundle ID (com.interviewcopilot.mac) ..."
    tccutil reset Microphone com.interviewcopilot.mac 2>/dev/null || true
    tccutil reset SpeechRecognition com.interviewcopilot.mac 2>/dev/null || true
    tccutil reset ScreenCapture com.interviewcopilot.mac 2>/dev/null || true
    echo "Done. Rebuild and relaunch to re-grant permissions."
    exit 0
fi

cd "$ROOT_DIR"

# --- Quit existing app instance (both old and new executable names) ---
# Required first step for every build: stop the user-facing process name.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "$LEGACY_EXECUTABLE_NAME" >/dev/null 2>&1 || true
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
    if ! pgrep -x "$EXECUTABLE_NAME" >/dev/null && ! pgrep -x "$SPM_PRODUCT_NAME" >/dev/null && ! pgrep -x "$LEGACY_EXECUTABLE_NAME" >/dev/null; then
        echo "[quit] Application exited gracefully."
        break
    fi
    sleep 0.25
done

# Path-specific fallback kill if still running after 3 seconds
if pgrep -x "$EXECUTABLE_NAME" >/dev/null || pgrep -x "$SPM_PRODUCT_NAME" >/dev/null || pgrep -x "$LEGACY_EXECUTABLE_NAME" >/dev/null; then
    echo "[quit] WARNING: Application did not quit gracefully within 3 seconds. Using pkill fallback..."
    pkill -f "$APP_BINARY" >/dev/null 2>&1 || true
    pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
    pkill -x "$SPM_PRODUCT_NAME" >/dev/null 2>&1 || true
    pkill -x "$LEGACY_EXECUTABLE_NAME" >/dev/null 2>&1 || true
    sleep 0.5
fi

# --- Build ---
echo "[build] Building $SPM_PRODUCT_NAME ..."
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$SPM_PRODUCT_NAME"

if [[ ! -f "$BUILD_BINARY" ]]; then
    echo "[build] ERROR: Built binary not found at $BUILD_BINARY" >&2
    exit 1
fi

# --- Assemble .app bundle ---
# Always remove the old bundle before assembly so Finder never launches stale code.
echo "[bundle] Removing stale bundle at $APP_BUNDLE ..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"

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
/usr/bin/plutil -insert CFBundleShortVersionString  -string "$VERSION"            "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleVersion            -string "$BUILD_NUMBER"        "$INFO_PLIST"
/usr/bin/plutil -insert CFBundlePackageType        -string "APPL"                 "$INFO_PLIST"
/usr/bin/plutil -insert LSMinimumSystemVersion     -string "$MIN_SYSTEM_VERSION"  "$INFO_PLIST"
/usr/bin/plutil -insert NSPrincipalClass           -string "NSApplication"        "$INFO_PLIST"
/usr/bin/plutil -insert NSHighResolutionCapable    -bool true                     "$INFO_PLIST"
/usr/bin/plutil -insert NSHumanReadableCopyright   -string "Copyright 2026"       "$INFO_PLIST"
/usr/bin/plutil -insert ICBuildTimestampUTC        -string "$BUILD_TIMESTAMP_UTC" "$INFO_PLIST"
/usr/bin/plutil -insert ICGitCommitHash            -string "$GIT_COMMIT_HASH"     "$INFO_PLIST"
/usr/bin/plutil -insert ICGitBranch                -string "$GIT_BRANCH"          "$INFO_PLIST"
/usr/bin/plutil -insert ICSourceRoot               -string "$ROOT_DIR"            "$INFO_PLIST"
/usr/bin/plutil -insert ICExpectedBundlePath       -string "$EXPECTED_BUNDLE_PATH" "$INFO_PLIST"

# --- Usage descriptions (required for TCC prompts) ---
/usr/bin/plutil -insert NSMicrophoneUsageDescription \
    -string "Interview Copilot uses the microphone to transcribe interview audio in real time." \
    "$INFO_PLIST"
/usr/bin/plutil -insert NSSpeechRecognitionUsageDescription \
    -string "Interview Copilot uses Apple Speech Recognition to create live interview transcripts." \
    "$INFO_PLIST"
/usr/bin/plutil -insert NSScreenCaptureUsageDescription \
    -string "Interview Copilot captures system audio to detect interviewer questions automatically." \
    "$INFO_PLIST"
/usr/bin/plutil -insert NSAudioCaptureUsageDescription \
    -string "Interview Copilot captures system audio for real-time interviewer question detection." \
    "$INFO_PLIST"

# Google Drive/Finder can leave extended attributes or AppleDouble files inside
# the assembled bundle; codesign rejects those as resource-fork detritus.
echo "[sign] Clearing bundle extended attributes before signing..."
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
find "$APP_BUNDLE" -name "._*" -delete 2>/dev/null || true

# --- Code Signing ---
# Try Apple Development certificate for stable signing across rebuilds.
# Fall back to ad-hoc (--sign -) if none is available.
SIGNING_IDENTITY=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/')
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "[sign] Signing with Apple Development: $SIGNING_IDENTITY"
    codesign --force --deep --options runtime \
        --sign "$SIGNING_IDENTITY" \
        "$APP_BUNDLE"
else
    echo "================================================================================"
    echo "⚠️  WARNING: No Apple Development signing identity found. Falling back to ad-hoc signing."
    echo "⚠️  macOS Screen/System Audio permissions may reset after rebuilds."
    echo "================================================================================"
    codesign --force --deep \
        --sign - \
        "$APP_BUNDLE"
fi

echo "[sign] Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo ""
echo "[sign] Running signing diagnostics..."
codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 || true
codesign -d -r- "$APP_BUNDLE" 2>&1 || true
spctl --assess --type execute --verbose "$APP_BUNDLE" || true
echo ""

echo "[sign] Log Identity Information:"
echo "  - Signing Identity: ${SIGNING_IDENTITY:-Ad-Hoc FALLBACK}"
echo "  - TeamIdentifier: $(codesign -dv "$APP_BUNDLE" 2>&1 | grep "TeamIdentifier" | cut -d= -f2 || echo "None")"
echo "  - CFBundleIdentifier: $BUNDLE_ID"
echo "  - Executable Path: $APP_BINARY"
echo "  - App Bundle Path: $APP_BUNDLE"
echo ""

echo "[verify] Bundle timestamps:"
stat -f "%Sm  %N" "$APP_BINARY"
stat -f "%Sm  %N" "$INFO_PLIST"
echo ""

echo "[verify] Bundle identity:"
plutil -p "$INFO_PLIST" | grep -E "CFBundleIdentifier|CFBundleName|NSMicrophoneUsageDescription|NSSpeechRecognitionUsageDescription"
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
    /usr/bin/open "$APP_BUNDLE"
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
        open_app
        for i in {1..20}; do
            if pgrep -x "$EXECUTABLE_NAME" >/dev/null || pgrep -f "$APP_BINARY" >/dev/null; then
                break
            fi
            sleep 0.5
        done
        if pgrep -x "$EXECUTABLE_NAME" >/dev/null || pgrep -f "$APP_BINARY" >/dev/null; then
            echo "[verify] ✅ $EXECUTABLE_NAME is running."
            echo "[verify] Bundle: $APP_BUNDLE"
            echo "[verify] Bundle ID: $BUNDLE_ID"
            echo "[verify] CFBundleExecutable: $EXECUTABLE_NAME"
            codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E "Identifier|Authority|Signature" || true
        else
            echo "[verify] ❌ $EXECUTABLE_NAME is NOT running."
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
        codesign -d -r- "$APP_BUNDLE" 2>&1 | grep -v "designated =>" || true
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
        cat <<EOF >&2
usage: $0 [run|--debug|--logs|--telemetry|--verify|--identity-check|--reset-tcc]

  run               Build, sign, and launch (default)
  --debug           Build and launch under lldb
  --logs            Build, launch, and stream process logs
  --telemetry       Build, launch, and stream subsystem logs
  --verify          Build, launch, and verify the app is running
  --identity-check  Verify CFBundleIdentifier, codesign authority, designated requirement, and cdhash
  --reset-tcc       Reset all TCC permissions for the app's bundle ID
EOF
        exit 2
        ;;
esac

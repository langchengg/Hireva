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
pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
pkill -x "$SPM_PRODUCT_NAME" >/dev/null 2>&1 || true
# Brief wait for the process to fully exit
sleep 0.5

# --- Build ---
echo "[build] Building $SPM_PRODUCT_NAME ..."
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$SPM_PRODUCT_NAME"

if [[ ! -f "$BUILD_BINARY" ]]; then
    echo "[build] ERROR: Built binary not found at $BUILD_BINARY" >&2
    exit 1
fi

# --- Assemble .app bundle ---
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
    echo "[sign] No Apple Development certificate found. Using ad-hoc signing."
    echo "[sign] ⚠️  WARNING: Ad-hoc signing produces a new signature hash on every rebuild."
    echo "[sign] ⚠️  macOS may re-prompt for permissions after each rebuild."
    echo "[sign] ⚠️  To avoid this, install an Apple Development certificate from Xcode → Settings → Accounts."
    codesign --force --deep \
        --sign - \
        "$APP_BUNDLE"
fi

echo ""
echo "[sign] Signature info:"
codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority|Signature" || true
echo ""

# --- Launch ---
open_app() {
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
        sleep 2
        if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
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
    --reset-tcc|reset-tcc)
        # handled above
        ;;
    *)
        cat <<EOF >&2
usage: $0 [run|--debug|--logs|--telemetry|--verify|--reset-tcc]

  run           Build, sign, and launch (default)
  --debug       Build and launch under lldb
  --logs        Build, launch, and stream process logs
  --telemetry   Build, launch, and stream subsystem logs
  --verify      Build, launch, and verify the app is running
  --reset-tcc   Reset all TCC permissions for the app's bundle ID
EOF
        exit 2
        ;;
esac

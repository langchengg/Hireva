#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./scripts/package_local_release.sh [--skip-verify]

Build and validate a local InterviewCopilotMac release package.

Options:
  --skip-verify  Skip verify_runtime_stability.sh only. The packaged app is
                 still rebuilt, launched, and validated.
  -h, --help     Show this help without building or modifying release output.
USAGE
}

SKIP_VERIFY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-verify)
            SKIP_VERIFY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/InterviewCopilotMac.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/InterviewCopilotMacRunner"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
EXPECTED_BUNDLE_ID="com.langcheng.InterviewCopilotMac"
DB_PATH="$HOME/Library/Application Support/InterviewCopilotMac/interview_copilot.sqlite"
TRACE_PATH="$HOME/Library/Application Support/InterviewCopilotMac/runtime_transcript_trace.jsonl"
RELEASE_ROOT="$ROOT_DIR/release"
STARTED_AT="$(date +%s)"

cd "$ROOT_DIR"

if [[ "$SKIP_VERIFY" -eq 0 ]]; then
    echo "[verify] Running runtime stability gate..."
    ./scripts/verify_runtime_stability.sh
    GATE_RESULT="PASS"
else
    echo "[verify] Skipping runtime stability gate by request."
    GATE_RESULT="SKIPPED (--skip-verify)"
fi

echo "[build] Rebuilding, signing, launching, and verifying app bundle..."
./script/build_and_run.sh --verify
BUILD_VERIFY_RESULT="PASS"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: app bundle is missing: $APP_BUNDLE" >&2
    exit 1
fi
if [[ ! -f "$INFO_PLIST" ]] || ! plutil -lint "$INFO_PLIST" >/dev/null 2>&1; then
    echo "error: Info.plist is missing or invalid: $INFO_PLIST" >&2
    exit 1
fi
if [[ ! -f "$APP_BINARY" ]] || [[ ! -x "$APP_BINARY" ]]; then
    echo "error: app executable is missing or not executable: $APP_BINARY" >&2
    exit 1
fi
if ! codesign --verify --deep --strict "$APP_BUNDLE"; then
    echo "error: source app code signature verification failed" >&2
    exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "error: bundle ID is '$BUNDLE_ID'; expected '$EXPECTED_BUNDLE_ID'" >&2
    exit 1
fi

SIGNING_DETAILS="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 || true)"
if printf '%s\n' "$SIGNING_DETAILS" | grep -q '^Signature=adhoc$'; then
    SIGNING_MODE="AD_HOC"
elif printf '%s\n' "$SIGNING_DETAILS" | grep -q '^Authority=Developer ID Application:'; then
    SIGNING_MODE="DEVELOPER_ID_APPLICATION"
elif printf '%s\n' "$SIGNING_DETAILS" | grep -q '^Authority=Apple Development:'; then
    SIGNING_MODE="APPLE_DEVELOPMENT"
else
    SIGNING_MODE="UNKNOWN"
fi
SIGNING_IDENTITY="${INTERVIEW_COPILOT_SIGNING_IDENTITY:-not configured}"

TIMESTAMP="$(date -u +'%Y%m%d-%H%M%S')"
RELEASE_NAME="InterviewCopilotMac-local-$TIMESTAMP"
RELEASE_DIR="$RELEASE_ROOT/$RELEASE_NAME"
ZIP_PATH="$RELEASE_ROOT/$RELEASE_NAME.zip"
PACKAGED_APP="$RELEASE_DIR/InterviewCopilotMac.app"
RELEASE_INFO="$RELEASE_DIR/RELEASE_INFO.txt"

mkdir -p "$RELEASE_ROOT"
if [[ -e "$RELEASE_DIR" || -e "$ZIP_PATH" ]]; then
    echo "error: release output already exists for timestamp $TIMESTAMP" >&2
    exit 1
fi
mkdir "$RELEASE_DIR"

echo "[package] Copying allowlisted app and operator documents..."
/usr/bin/ditto --norsrc "$APP_BUNDLE" "$PACKAGED_APP"
for document in \
    docs/release-runbook.md \
    docs/release-checklist.md \
    docs/macos-local-signing.md \
    docs/runtime-regression-checklist.md \
    docs/ai-coding-agent-rules.md \
    docs/local-workspace-migration.md \
    docs/notarization-prep.md \
    docs/rollback-known-good.md; do
    if [[ ! -f "$ROOT_DIR/$document" ]]; then
        echo "error: required release document is missing: $document" >&2
        exit 1
    fi
    cp "$ROOT_DIR/$document" "$RELEASE_DIR/$(basename "$document")"
done

# Cloud providers and Finder can recreate metadata that destabilizes signing.
xattr -cr "$PACKAGED_APP" 2>/dev/null || true
find "$RELEASE_DIR" -name '.DS_Store' -delete 2>/dev/null || true
find "$RELEASE_DIR" -name '._*' -delete 2>/dev/null || true

if ! codesign --verify --deep --strict "$PACKAGED_APP"; then
    echo "error: packaged app code signature verification failed" >&2
    exit 1
fi

GIT_BRANCH="$(git branch --show-current 2>/dev/null || echo unknown)"
GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_STATUS="$(git status --short 2>/dev/null || true)"
LATEST_TAG="$(git tag --sort=-creatordate 2>/dev/null | head -n 1 || true)"
TAG_LIST="$(git tag --sort=-creatordate 2>/dev/null | head -n 10 || true)"
BUNDLE_SOURCE_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :ICGitCommitHash' "$INFO_PLIST" 2>/dev/null || echo unavailable)"
APP_BINARY_TIMESTAMP="$(stat -f '%Sm' "$APP_BINARY" 2>/dev/null || echo unavailable)"

{
    echo "InterviewCopilotMac Local Release"
    echo "Generated UTC: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "Git branch: $GIT_BRANCH"
    echo "Git commit: $GIT_COMMIT"
    echo "Bundle source commit: $BUNDLE_SOURCE_COMMIT"
    echo "Latest tag: ${LATEST_TAG:-none}"
    echo "Tag list (latest 10):"
    if [[ -n "$TAG_LIST" ]]; then printf '%s\n' "$TAG_LIST"; else echo "(none)"; fi
    echo "Git status summary:"
    if [[ -n "$GIT_STATUS" ]]; then printf '%s\n' "$GIT_STATUS"; else echo "(clean)"; fi
    echo "Bundle ID: $BUNDLE_ID"
    echo "Source app path: $APP_BUNDLE"
    echo "Packaged app path: $RELEASE_NAME/InterviewCopilotMac.app"
    echo "Signing mode: $SIGNING_MODE"
    echo "Signing identity if used: $SIGNING_IDENTITY"
    echo "App binary timestamp: $APP_BINARY_TIMESTAMP"
    echo "Runtime stability gate: $GATE_RESULT"
    echo "Build and launch verification: $BUILD_VERIFY_RESULT"
    echo "Source signature verification: PASS"
    echo "Packaged signature verification: PASS"
    echo "Expected DB path: $DB_PATH"
    echo "Expected trace path: $TRACE_PATH"
    echo "WARNING: The packaged app is a local handoff artifact, not a portable installed-app release."
    echo "WARNING: Launching it outside the source workspace's dist path can show the existing stale-build warning because ICExpectedBundlePath is absolute."
    if [[ "$SIGNING_MODE" == "AD_HOC" ]]; then
        echo "WARNING: This package is ad-hoc signed. It is for local development/handoff only."
    fi
    if [[ "$ROOT_DIR" == *"/Library/CloudStorage/GoogleDrive-"* ]]; then
        echo "WARNING: Source was built under a Google Drive path; cloud xattrs/AppleDouble files can destabilize signing."
    fi
    if [[ -n "$GIT_STATUS" ]]; then
        echo "WARNING: The source worktree was dirty when this package was generated."
    fi
} > "$RELEASE_INFO"

# Defense in depth: fail if any prohibited runtime/build/repository artifact
# appears despite the allowlisted copy above.
FORBIDDEN_PATH="$(find "$RELEASE_DIR" \
    \( -name '.git' -o -name '.build' -o -name '.DS_Store' -o -name '._*' \
       -o -name 'interview_copilot.sqlite' -o -name 'runtime_transcript_trace.jsonl' \
       -o -name '*.sqlite' -o -name '*.sqlite-wal' -o -name '*.sqlite-shm' \) \
    -print -quit 2>/dev/null || true)"
if [[ -n "$FORBIDDEN_PATH" ]]; then
    echo "error: forbidden artifact entered release directory: $FORBIDDEN_PATH" >&2
    exit 1
fi

echo "[archive] Creating ZIP without resource-fork metadata..."
(
    cd "$RELEASE_ROOT"
    /usr/bin/zip -qry -X "$RELEASE_NAME.zip" "$RELEASE_NAME" \
        -x '*/.DS_Store' '*/._*' '*/__MACOSX/*'
)

if [[ ! -f "$ZIP_PATH" ]]; then
    echo "error: ZIP archive was not created: $ZIP_PATH" >&2
    exit 1
fi

ARCHIVE_LISTING="$(/usr/bin/unzip -Z1 "$ZIP_PATH")"
if printf '%s\n' "$ARCHIVE_LISTING" | grep -Eq '(^|/)(\.git|\.build|__MACOSX)(/|$)|(^|/)(\.DS_Store|\._[^/]*)$|interview_copilot\.sqlite|runtime_transcript_trace\.jsonl|\.sqlite-(wal|shm)$'; then
    echo "error: ZIP archive contains a forbidden path" >&2
    printf '%s\n' "$ARCHIVE_LISTING" >&2
    exit 1
fi

ELAPSED="$(($(date +%s) - STARTED_AT))"
echo "[pass] Local release package created."
echo "Release directory: $RELEASE_DIR"
echo "Release archive: $ZIP_PATH"
echo "RELEASE_INFO: $RELEASE_INFO"
echo "Warning: launching the copied app outside the canonical dist path can show the existing stale-build warning."
echo "Elapsed seconds: $ELAPSED"

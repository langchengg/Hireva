#!/usr/bin/env bash
set -uo pipefail

DEFAULT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="${RELEASE_STATUS_ROOT_DIR:-$DEFAULT_ROOT_DIR}"
APP_BUNDLE="${RELEASE_STATUS_APP_BUNDLE:-$ROOT_DIR/dist/InterviewCopilotMac.app}"
APP_BINARY="${RELEASE_STATUS_APP_BINARY:-$APP_BUNDLE/Contents/MacOS/InterviewCopilotMacRunner}"
INFO_PLIST="${RELEASE_STATUS_INFO_PLIST:-$APP_BUNDLE/Contents/Info.plist}"
DB_PATH="${RELEASE_STATUS_DB_PATH:-$HOME/Library/Application Support/InterviewCopilotMac/interview_copilot.sqlite}"
TRACE_PATH="${RELEASE_STATUS_TRACE_PATH:-$HOME/Library/Application Support/InterviewCopilotMac/runtime_transcript_trace.jsonl}"
EXPECTED_BUNDLE_ID="com.langcheng.InterviewCopilotMac"
OVERALL_STATUS=0

echo "=== InterviewCopilotMac Release Status ==="
echo "Repository root: $ROOT_DIR"
echo "Current branch: $(git -C "$ROOT_DIR" branch --show-current 2>/dev/null || echo unknown)"
echo "Latest commit: $(git -C "$ROOT_DIR" log -1 --format='%h %cI %s' 2>/dev/null || echo unavailable)"

echo "Git status (short):"
GIT_STATUS="$(git -C "$ROOT_DIR" status --short 2>/dev/null || true)"
if [[ -n "$GIT_STATUS" ]]; then
    printf '%s\n' "$GIT_STATUS"
else
    echo "(clean)"
fi

echo "Latest tags:"
LATEST_TAGS="$(git -C "$ROOT_DIR" tag --sort=-creatordate 2>/dev/null | head -n 5 || true)"
if [[ -n "$LATEST_TAGS" ]]; then
    printf '%s\n' "$LATEST_TAGS"
else
    echo "(none)"
fi

echo ""
echo "=== App Bundle ==="
echo "App bundle: $APP_BUNDLE"
if [[ -d "$APP_BUNDLE" ]]; then
    echo "App bundle exists: yes"
else
    echo "App bundle exists: no"
    OVERALL_STATUS=1
fi
echo "App runner: $APP_BINARY"

BUNDLE_ID=""
if [[ -f "$INFO_PLIST" ]] && plutil -lint "$INFO_PLIST" >/dev/null 2>&1; then
    echo "Info.plist validation: PASS"
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
else
    echo "Info.plist validation: FAIL"
    OVERALL_STATUS=1
fi
echo "Bundle ID: ${BUNDLE_ID:-unavailable}"
if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "Bundle ID validation: FAIL (expected $EXPECTED_BUNDLE_ID)"
    OVERALL_STATUS=1
else
    echo "Bundle ID validation: PASS"
fi

if [[ -f "$APP_BINARY" ]]; then
    echo "App binary timestamp: $(stat -f '%Sm' "$APP_BINARY" 2>/dev/null || echo unavailable)"
else
    echo "App binary timestamp: unavailable"
    OVERALL_STATUS=1
fi

if [[ -d "$APP_BUNDLE" ]] && codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
    echo "Code signature validation: PASS"
else
    echo "Code signature validation: FAIL"
    OVERALL_STATUS=1
fi

echo "Expected DB: $DB_PATH"
echo "Expected trace: $TRACE_PATH"

echo ""
echo "=== Verification Commands ==="
for relative_path in \
    "scripts/verify_runtime_stability.sh" \
    "scripts/runtime_smoke.sh" \
    "script/build_and_run.sh" \
    "scripts/db_diagnostics.sh"; do
    absolute_path="$ROOT_DIR/$relative_path"
    exists="$([[ -f "$absolute_path" ]] && echo yes || echo no)"
    executable="$([[ -x "$absolute_path" ]] && echo yes || echo no)"
    echo "$relative_path: exists=$exists executable=$executable"
    if [[ "$exists" != "yes" || "$executable" != "yes" ]]; then
        OVERALL_STATUS=1
    fi
done

if [[ -n "${INTERVIEW_COPILOT_SIGNING_IDENTITY:-}" ]]; then
    echo "INTERVIEW_COPILOT_SIGNING_IDENTITY: set"
else
    echo "INTERVIEW_COPILOT_SIGNING_IDENTITY: unset (ad-hoc fallback)"
fi

IDENTITY_OUTPUT="$(security find-identity -v -p codesigning 2>/dev/null || true)"
IDENTITY_COUNT="$(printf '%s\n' "$IDENTITY_OUTPUT" | awk '/valid identities found/{print $1; exit}')"
echo "Available codesigning identities: ${IDENTITY_COUNT:-unknown}"

echo ""
echo "=== Runtime Data ==="
echo "Runtime rows and events are summarized without transcript or answer text."
if [[ -f "$DB_PATH" ]]; then
    echo "Database exists: yes"
    if command -v sqlite3 >/dev/null 2>&1; then
        TABLE_EXISTS="$(sqlite3 -readonly "$DB_PATH" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='suggestion_cards';" 2>/dev/null || true)"
        if [[ "$TABLE_EXISTS" == "1" ]]; then
            echo "Latest 5 DB rows:"
            sqlite3 -readonly -header -column "$DB_PATH" "
SELECT
  created_at,
  question_intent,
  alignment_verdict,
  stage_b_status,
  final_visible_source
FROM suggestion_cards
ORDER BY created_at DESC
LIMIT 5;
" || echo "Unable to read suggestion_cards."
        else
            echo "Latest 5 DB rows: suggestion_cards table is unavailable."
        fi
    else
        echo "Latest 5 DB rows: sqlite3 is unavailable."
    fi
else
    echo "Database exists: no"
    echo "Latest 5 DB rows: unavailable until the app creates the database."
fi

if [[ -f "$TRACE_PATH" ]]; then
    echo "Trace exists: yes"
    echo "Latest trace events:"
    tail -n 10 "$TRACE_PATH" | awk '
function json_string_value(line, key, token, start, rest, finish) {
    token = "\"" key "\":\""
    start = index(line, token)
    if (start == 0) return "unknown"
    rest = substr(line, start + length(token))
    finish = index(rest, "\"")
    if (finish == 0) return "unknown"
    return substr(rest, 1, finish - 1)
}
{
    printf "%s | event_type=%s | acceptance_status=%s\n",
        json_string_value($0, "timestamp"),
        json_string_value($0, "event_type"),
        json_string_value($0, "acceptance_status")
}
' || true
else
    echo "Trace exists: no"
    echo "Latest trace events: unavailable until the app creates the trace."
fi

if [[ "$OVERALL_STATUS" -eq 0 ]]; then
    echo "Overall release status: PASS"
else
    echo "Overall release status: FAIL"
fi

exit "$OVERALL_STATUS"

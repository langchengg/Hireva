#!/usr/bin/env bash
set -uo pipefail

DB_PATH="$HOME/Library/Application Support/InterviewCopilotMac/interview_copilot.sqlite"
TRACE_PATH="$HOME/Library/Application Support/InterviewCopilotMac/runtime_transcript_trace.jsonl"

print_trace_events() {
    echo ""
    echo "=== Latest Runtime Trace Events ==="
    echo "Trace path: $TRACE_PATH"
    if [[ -f "$TRACE_PATH" ]]; then
        tail -n 20 "$TRACE_PATH"
    else
        echo "Trace file does not exist yet."
    fi
}

echo "=== InterviewCopilotMac Database Diagnostics ==="
echo "Expected DB path: $DB_PATH"
echo "Warning: diagnostic output may contain interview questions and answers."

if [[ ! -e "$DB_PATH" ]]; then
    echo "Database exists: no"
    echo "The app has not created its runtime database at the expected path yet."
    print_trace_events
    exit 0
fi

echo "Database exists: yes"
echo "File size: $(stat -f '%z bytes' "$DB_PATH")"

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "error: sqlite3 is required to inspect the existing database" >&2
    print_trace_events
    exit 1
fi

echo ""
echo "=== Tables ==="
sqlite3 -readonly "$DB_PATH" ".tables"

SUGGESTION_TABLE_EXISTS=$(sqlite3 -readonly "$DB_PATH" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='suggestion_cards';")
if [[ "$SUGGESTION_TABLE_EXISTS" == "1" ]]; then
    echo ""
    echo "=== suggestion_cards Row Count ==="
    sqlite3 -readonly "$DB_PATH" "SELECT COUNT(*) FROM suggestion_cards;"

    echo ""
    echo "=== Latest 10 suggestion_cards Rows ==="
    sqlite3 -readonly -header -column "$DB_PATH" "
SELECT
  created_at,
  question_intent,
  substr(question_text, 1, 120) AS question,
  alignment_verdict,
  stage_b_status,
  final_visible_source,
  substr(say_first, 1, 180) AS say_first
FROM suggestion_cards
ORDER BY created_at DESC
LIMIT 10;
"
else
    echo ""
    echo "suggestion_cards table does not exist yet."
fi

print_trace_events

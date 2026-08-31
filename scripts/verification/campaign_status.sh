#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=""
usage() {
    echo "Usage: ./scripts/verification/campaign_status.sh --state-dir ABSOLUTE_PATH"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$STATE_DIR" == /* && -d "$STATE_DIR" ]] || {
    echo "error: --state-dir must identify an existing absolute directory" >&2
    exit 2
}
STATE_FILE="$STATE_DIR/campaign_state.json"
[[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || {
    echo "error: campaign_state.json is unavailable" >&2
    exit 2
}

jq -r '
  "Campaign: \(.campaign_id)",
  "Status: \(.status)",
  "Branch: \(.branch)",
  "Base commit: \(.base_commit)",
  "Last good commit: \(.last_good_commit)",
  "Phase: \(.current_phase)",
  "Active elapsed: \(.active_elapsed_seconds)s / \(.target_active_seconds)s",
  "Completed cycles: \(.completed_cycles)",
  "Open failures: \(.open_failures)",
  "Fixed failures: \(.fixed_failures)",
  "Interruptions: \(.interrupt_count)",
  "Resumes: \(.resume_count)",
  "Last heartbeat: \(.last_heartbeat)",
  "Artifact directory: \(.artifact_dir)"
' "$STATE_FILE"

if [[ -f "$STATE_DIR/heartbeat.json" ]]; then
    heartbeat_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(jq -r '.timestamp' "$STATE_DIR/heartbeat.json")" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    if [[ "$heartbeat_epoch" =~ ^[0-9]+$ && "$heartbeat_epoch" -gt 0 ]]; then
        echo "Heartbeat age: $((now_epoch - heartbeat_epoch))s"
    fi
fi

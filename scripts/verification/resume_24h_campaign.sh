#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
STATE_DIR=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/verification/resume_24h_campaign.sh --state-dir ABSOLUTE_PATH
USAGE
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
STATE_DIR="$(cd "$STATE_DIR" && pwd -P)"
STATE_FILE="$STATE_DIR/campaign_state.json"
[[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || {
    echo "error: campaign_state.json is unavailable" >&2
    exit 2
}
jq -e '.schema_version == 1' "$STATE_FILE" >/dev/null
ARTIFACT_DIR="$(jq -r '.artifact_dir' "$STATE_FILE")"
TARGET_ACTIVE_SECONDS="$(jq -r '.target_active_seconds' "$STATE_FILE")"
[[ "$ARTIFACT_DIR" == /* && "$TARGET_ACTIVE_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: persisted campaign paths or duration are invalid" >&2
    exit 2
}
DURATION_HOURS="$((TARGET_ACTIVE_SECONDS / 3600))"

exec "$ROOT_DIR/scripts/verification/run_24h_campaign.sh" \
    --duration-hours "$DURATION_HOURS" \
    --state-dir "$STATE_DIR" \
    --artifact-dir "$ARTIFACT_DIR" \
    --resume

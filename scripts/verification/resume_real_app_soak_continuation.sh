#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
STATE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
        -h|--help)
            echo "usage: $0 --state-dir <existing-absolute-path>"
            exit 0
            ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ "$STATE_DIR" == /* && -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || {
    echo "error: state directory must be an existing absolute non-symlink path" >&2
    exit 2
}

exec "$ROOT_DIR/scripts/verification/run_real_app_soak_continuation.sh" \
    --resume \
    --state-dir "$STATE_DIR"

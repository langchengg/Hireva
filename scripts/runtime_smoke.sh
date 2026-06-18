#!/usr/bin/env bash
set -euo pipefail

SUITE="all"

usage() {
  cat <<'USAGE'
Usage: ./scripts/runtime_smoke.sh [--suite SUITE]

Suites:
  all
  bad-fragments
  rapid-two
  rapid-three
  conditional-asr
  noisy-canonicalization
  incomplete-stream
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite)
      if [[ $# -lt 2 ]]; then
        echo "error: --suite requires a value" >&2
        usage >&2
        exit 2
      fi
      SUITE="$2"
      shift 2
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

case "$SUITE" in
  all|bad-fragments|rapid-two|rapid-three|conditional-asr|noisy-canonicalization|incomplete-stream)
    ;;
  *)
    echo "error: unknown runtime smoke suite: $SUITE" >&2
    usage >&2
    exit 2
    ;;
esac

echo "Runtime smoke suite: $SUITE"
export RUNTIME_SMOKE_SUITE="$SUITE"
swift test --filter RuntimeSmokeHarnessTests

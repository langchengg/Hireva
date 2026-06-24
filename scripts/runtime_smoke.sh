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
  long-interview
  apple-speech-cross-task-replay
  seven-question-real-order
  apple-speech-cumulative-replay
  real-long-interview-ordering
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
  all|bad-fragments|rapid-two|rapid-three|conditional-asr|noisy-canonicalization|incomplete-stream|long-interview|apple-speech-cross-task-replay|seven-question-real-order|apple-speech-cumulative-replay|real-long-interview-ordering)
    ;;
  *)
    echo "error: unknown runtime smoke suite: $SUITE" >&2
    usage >&2
    exit 2
    ;;
esac

CANONICAL_SUITE="$SUITE"
case "$CANONICAL_SUITE" in
  apple-speech-cumulative-replay)
    CANONICAL_SUITE="apple-speech-cross-task-replay"
    ;;
  real-long-interview-ordering)
    CANONICAL_SUITE="seven-question-real-order"
    ;;
esac

echo "Runtime smoke suite: $SUITE"
export RUNTIME_SMOKE_SUITE="$CANONICAL_SUITE"
swift test --filter RuntimeSmokeHarnessTests

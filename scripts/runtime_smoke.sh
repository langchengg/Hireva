#!/usr/bin/env bash
set -euo pipefail

SUITE="all"

usage() {
  cat <<'USAGE'
Usage: ./scripts/runtime_smoke.sh [--suite SUITE]

Suites:
  all
  release-64
  bad-fragments
  rapid-two
  callback-ownership
  rapid-three
  conditional-asr
  noisy-canonicalization
  incomplete-stream
  stage-b-watchdog
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
  all|release-64|bad-fragments|rapid-two|callback-ownership|rapid-three|conditional-asr|noisy-canonicalization|incomplete-stream|stage-b-watchdog|long-interview|apple-speech-cross-task-replay|seven-question-real-order|apple-speech-cumulative-replay|real-long-interview-ordering)
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

TEST_FILTER="RuntimeSmokeHarnessTests"
case "$CANONICAL_SUITE" in
  all)
    ;;
  release-64)
    TEST_FILTER="RuntimeSmokeHarnessTests.release64QuestionGate"
    ;;
  bad-fragments)
    TEST_FILTER="RuntimeSmokeHarnessTests.badFragmentsSuiteRejectsWithoutGenerationOrPersistence"
    ;;
  rapid-two)
    TEST_FILTER="RuntimeSmokeHarnessTests.rapidTwoQuestionSuiteRejectsLateFirstQuestionCallbacksAndPersistsSeparateRows"
    ;;
  callback-ownership)
    TEST_FILTER="RuntimeSmokeHarnessTests.replacementCancelsLiveCallbackAfterGenerationBecomesTerminal"
    ;;
  rapid-three)
    TEST_FILTER="RuntimeSmokeHarnessTests.rapidThreeQuestionSuiteKeepsLatestCardAfterTwoLateProviderCompletions"
    ;;
  conditional-asr)
    TEST_FILTER="RuntimeSmokeHarnessTests.conditionalASRSuiteKeepsFullConditionalQuestion"
    ;;
  noisy-canonicalization)
    TEST_FILTER="RuntimeSmokeHarnessTests.noisyCanonicalizationSuiteNormalizesCommonASRVariants"
    ;;
  incomplete-stream)
    TEST_FILTER="RuntimeSmokeHarnessTests.incompleteStreamSuiteRejectsPartialProviderAnswerAndUsesFallback"
    ;;
  stage-b-watchdog)
    TEST_FILTER="RuntimeSmokeHarnessTests.completedStageBCancelsFullCardWatchdog"
    ;;
  long-interview)
    TEST_FILTER="RuntimeSmokeHarnessTests.longInterviewSuiteKeepsSevenCumulativeQuestionsDistinctAndCurrent"
    ;;
  apple-speech-cross-task-replay)
    TEST_FILTER="RuntimeSmokeHarnessTests.appleSpeechCumulativeReplaySuiteRejectsOldCallbacksAndKeepsNewestCard"
    ;;
  seven-question-real-order)
    TEST_FILTER="RuntimeSmokeHarnessTests.realLongInterviewOrderingSuiteNeverRegressesToOldCumulativeQuestion"
    ;;
esac

echo "Runtime smoke suite: $SUITE"
swift test --filter "$TEST_FILTER"

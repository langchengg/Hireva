#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/generate_synthetic_parakeet_fixture.sh OUTPUT_DIRECTORY

Generates a three-utterance, on-device macOS text-to-speech WAV fixture and a
JSON provenance manifest. The output directory must not already exist. No
microphone, user recording, network service, CV, JD, or transcript is used.
USAGE
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

REQUESTED_OUTPUT="$1"
if [[ "$REQUESTED_OUTPUT" != /* ]]; then
  REQUESTED_OUTPUT="$PWD/$REQUESTED_OUTPUT"
fi
if [[ -e "$REQUESTED_OUTPUT" || -L "$REQUESTED_OUTPUT" ]]; then
  echo "error: output directory already exists: $REQUESTED_OUTPUT" >&2
  exit 2
fi

OUTPUT_PARENT_REQUESTED="$(dirname "$REQUESTED_OUTPUT")"
[[ -d "$OUTPUT_PARENT_REQUESTED" ]] || {
  echo "error: output parent directory does not exist: $OUTPUT_PARENT_REQUESTED" >&2
  exit 2
}
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT_REQUESTED" && pwd -P)"
OUTPUT_NAME="$(basename "$REQUESTED_OUTPUT")"
case "$OUTPUT_NAME" in
  ''|.|..)
    echo "error: output directory must name a new child directory" >&2
    exit 2
    ;;
esac
OUTPUT_DIRECTORY="$OUTPUT_PARENT/$OUTPUT_NAME"

VOICE="${HIREVA_SYNTHETIC_AUDIO_VOICE:-Daniel}"
RATE="${HIREVA_SYNTHETIC_AUDIO_RATE:-165}"
[[ "$RATE" =~ ^[0-9]+$ ]] || {
  echo "error: HIREVA_SYNTHETIC_AUDIO_RATE must be an integer" >&2
  exit 2
}

WORK_DIRECTORY="$(/usr/bin/mktemp -d "$OUTPUT_PARENT/.hireva-synthetic-audio.XXXXXX")"
cleanup() {
  /bin/rm -rf -- "$WORK_DIRECTORY"
}
trap cleanup EXIT

AIFF_PATH="$WORK_DIRECTORY/parakeet-three-utterances.aiff"
RESULT_DIRECTORY="$WORK_DIRECTORY/result"
AUDIO_NAME="parakeet-three-utterances.wav"
MANIFEST_NAME="parakeet-three-utterances.provenance.json"
AUDIO_PATH="$RESULT_DIRECTORY/$AUDIO_NAME"
MANIFEST_PATH="$RESULT_DIRECTORY/$MANIFEST_NAME"
UTTERANCE_ONE="How did you reduce processing latency in the event ingestion service?"
UTTERANCE_TWO="Which retry strategy did you evaluate during recovery?"
UTTERANCE_THREE="How did you verify consistency after the deployment?"
SPEECH_TEXT="$UTTERANCE_ONE [[slnc 1800]] $UTTERANCE_TWO [[slnc 1800]] $UTTERANCE_THREE"

/bin/mkdir "$RESULT_DIRECTORY"
/usr/bin/say -v "$VOICE" -r "$RATE" -o "$AIFF_PATH" "$SPEECH_TEXT"
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$AIFF_PATH" "$AUDIO_PATH"
[[ -s "$AUDIO_PATH" ]] || {
  echo "error: speech synthesis did not produce a WAV file" >&2
  exit 1
}

AUDIO_SHA256="$(/usr/bin/shasum -a 256 "$AUDIO_PATH" | /usr/bin/awk '{print $1}')"
AUDIO_SIZE_BYTES="$(/usr/bin/stat -f '%z' "$AUDIO_PATH")"
MACOS_VERSION="$(/usr/bin/sw_vers -productVersion)"
ARCHITECTURE="$(/usr/bin/uname -m)"

/usr/bin/plutil -create xml1 "$MANIFEST_PATH"
/usr/bin/plutil -insert schema_version -integer 1 "$MANIFEST_PATH"
/usr/bin/plutil -insert synthetic -bool true "$MANIFEST_PATH"
/usr/bin/plutil -insert contains_real_personal_data -bool false "$MANIFEST_PATH"
/usr/bin/plutil -insert generator -string "macos_say" "$MANIFEST_PATH"
/usr/bin/plutil -insert voice -string "$VOICE" "$MANIFEST_PATH"
/usr/bin/plutil -insert rate_words_per_minute -integer "$RATE" "$MANIFEST_PATH"
/usr/bin/plutil -insert macos_product_version -string "$MACOS_VERSION" "$MANIFEST_PATH"
/usr/bin/plutil -insert architecture -string "$ARCHITECTURE" "$MANIFEST_PATH"
/usr/bin/plutil -insert audio -json '{}' "$MANIFEST_PATH"
/usr/bin/plutil -insert audio.filename -string "$AUDIO_NAME" "$MANIFEST_PATH"
/usr/bin/plutil -insert audio.sha256 -string "$AUDIO_SHA256" "$MANIFEST_PATH"
/usr/bin/plutil -insert audio.size_bytes -integer "$AUDIO_SIZE_BYTES" "$MANIFEST_PATH"
/usr/bin/plutil -insert utterances -json '[
  {"id":"processing-latency","text":"How did you reduce processing latency in the event ingestion service?","expected_transcript_terms":["processing","latency"]},
  {"id":"retry-strategy","text":"Which retry strategy did you evaluate during recovery?","expected_transcript_terms":["retry","strategy"]},
  {"id":"consistency-check","text":"How did you verify consistency after the deployment?","expected_transcript_terms":["consistency","deployment"]}
]' "$MANIFEST_PATH"
/usr/bin/plutil -convert json "$MANIFEST_PATH"

/usr/bin/ruby "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/validate_synthetic_audio_provenance.rb" \
  "$AUDIO_PATH" "$MANIFEST_PATH"

if [[ -e "$OUTPUT_DIRECTORY" || -L "$OUTPUT_DIRECTORY" ]]; then
  echo "error: output directory appeared during generation: $OUTPUT_DIRECTORY" >&2
  exit 1
fi
/bin/mv "$RESULT_DIRECTORY" "$OUTPUT_DIRECTORY"

printf 'SYNTHETIC_AUDIO=%s\n' "$OUTPUT_DIRECTORY/$AUDIO_NAME"
printf 'SYNTHETIC_AUDIO_PROVENANCE=%s\n' "$OUTPUT_DIRECTORY/$MANIFEST_NAME"
printf 'SYNTHETIC_AUDIO_SHA256=%s\n' "$AUDIO_SHA256"

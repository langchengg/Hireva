#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
    echo "usage: $0 <voice> <rate> <text> <audio-profile> <audio-seed-or-empty> <output.aiff>" >&2
    exit 2
fi

VOICE="$1"
RATE="$2"
TEXT="$3"
AUDIO_PROFILE="$4"
AUDIO_SEED="$5"
OUTPUT_PATH="$6"

[[ -n "$VOICE" && ${#VOICE} -le 80 && "$VOICE" != *$'\n'* && "$VOICE" != *$'\r'* ]] || {
    echo "voice must be a bounded single-line value" >&2
    exit 2
}
[[ "$RATE" =~ ^(0|[1-9][0-9]*)$ ]] && (( RATE >= 80 && RATE <= 300 )) || {
    echo "rate must be an integer from 80 through 300" >&2
    exit 2
}
[[ -n "$TEXT" && ${#TEXT} -le 2000 ]] || {
    echo "text must be non-empty and no longer than 2000 characters" >&2
    exit 2
}
case "$AUDIO_PROFILE" in
    clean|low_volume|high_volume_limited|white_noise|synthetic_cafe_noise|mild_echo) ;;
    *) echo "audio profile is not an approved local synthetic profile" >&2; exit 2 ;;
esac
if [[ "$AUDIO_PROFILE" == "white_noise" || "$AUDIO_PROFILE" == "synthetic_cafe_noise" ]]; then
    [[ "$AUDIO_SEED" =~ ^[1-9][0-9]*$ ]] && (( AUDIO_SEED <= 2147483647 )) || {
        echo "noise profile requires an explicit audio seed from 1 through 2147483647" >&2
        exit 2
    }
elif [[ -n "$AUDIO_SEED" ]]; then
    [[ "$AUDIO_SEED" =~ ^[1-9][0-9]*$ ]] && (( AUDIO_SEED <= 2147483647 )) || {
        echo "audio seed must be empty or an integer from 1 through 2147483647" >&2
        exit 2
    }
fi

[[ ! -e "$OUTPUT_PATH" && ! -L "$OUTPUT_PATH" ]] || {
    echo "audio output must be a fresh non-symlink path" >&2
    exit 2
}
OUTPUT_BASENAME="$(basename "$OUTPUT_PATH")"
[[ "$OUTPUT_BASENAME" == *.aiff && "$OUTPUT_BASENAME" != ".aiff" ]] || {
    echo "audio output must use a non-empty .aiff filename" >&2
    exit 2
}
OUTPUT_PARENT="$(cd -P "$(dirname "$OUTPUT_PATH")" && pwd)" || {
    echo "audio output parent must exist" >&2
    exit 2
}
OUTPUT_PATH="$OUTPUT_PARENT/$OUTPUT_BASENAME"

FFMPEG_BINARY=""
if [[ "$AUDIO_PROFILE" != "clean" ]]; then
    FFMPEG_BINARY="$(command -v ffmpeg || true)"
    [[ -n "$FFMPEG_BINARY" && -x "$FFMPEG_BINARY" ]] || {
        echo "ffmpeg is required for non-clean synthetic audio profiles" >&2
        exit 2
    }
fi
[[ -x /usr/bin/afinfo ]] || { echo "macOS afinfo is required to record synthetic audio duration" >&2; exit 2; }

RENDER_DIRECTORY="$(mktemp -d "$OUTPUT_PARENT/.hireva-audio-render.XXXXXX")"
RAW_AUDIO="$RENDER_DIRECTORY/raw.aiff"
RENDERED_AUDIO="$RENDER_DIRECTORY/rendered.aiff"

cleanup_render_directory() {
    /bin/rm -f -- "$RAW_AUDIO" "$RENDERED_AUDIO"
    /bin/rmdir -- "$RENDER_DIRECTORY" 2>/dev/null || true
}
trap cleanup_render_directory EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/say -v "$VOICE" -r "$RATE" -o "$RAW_AUDIO" "$TEXT"

case "$AUDIO_PROFILE" in
    clean)
        /bin/cp "$RAW_AUDIO" "$RENDERED_AUDIO"
        ;;
    low_volume)
        "$FFMPEG_BINARY" -nostdin -hide_banner -loglevel error -y \
            -i "$RAW_AUDIO" -map_metadata -1 -af 'volume=0.30' -f aiff "$RENDERED_AUDIO"
        ;;
    high_volume_limited)
        "$FFMPEG_BINARY" -nostdin -hide_banner -loglevel error -y \
            -i "$RAW_AUDIO" -map_metadata -1 -af 'volume=1.8,alimiter=limit=0.90' -f aiff "$RENDERED_AUDIO"
        ;;
    white_noise)
        "$FFMPEG_BINARY" -nostdin -hide_banner -loglevel error -y \
            -i "$RAW_AUDIO" \
            -f lavfi -i "anoisesrc=color=white:amplitude=0.018:sample_rate=44100:seed=$AUDIO_SEED" \
            -filter_complex '[0:a][1:a]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.95[out]' \
            -map '[out]' -map_metadata -1 -f aiff "$RENDERED_AUDIO"
        ;;
    synthetic_cafe_noise)
        "$FFMPEG_BINARY" -nostdin -hide_banner -loglevel error -y \
            -i "$RAW_AUDIO" \
            -f lavfi -i "anoisesrc=color=pink:amplitude=0.022:sample_rate=44100:seed=$AUDIO_SEED" \
            -filter_complex '[1:a]highpass=f=120,lowpass=f=4200[ambience];[0:a][ambience]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.95[out]' \
            -map '[out]' -map_metadata -1 -f aiff "$RENDERED_AUDIO"
        ;;
    mild_echo)
        "$FFMPEG_BINARY" -nostdin -hide_banner -loglevel error -y \
            -i "$RAW_AUDIO" -map_metadata -1 \
            -af 'aecho=0.8:0.5:70:0.18,alimiter=limit=0.95' -f aiff "$RENDERED_AUDIO"
        ;;
esac

[[ -s "$RENDERED_AUDIO" ]] || { echo "synthetic audio renderer produced no output" >&2; exit 1; }
AUDIO_DURATION_SECONDS="$(/usr/bin/afinfo "$RENDERED_AUDIO" | /usr/bin/sed -n 's/^[[:space:]]*estimated duration: \([0-9][0-9.]*\) sec[[:space:]]*$/\1/p')"
[[ "$AUDIO_DURATION_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    echo "afinfo did not return a numeric duration" >&2
    exit 1
}
AUDIO_SHA256="$(/usr/bin/shasum -a 256 "$RENDERED_AUDIO" | /usr/bin/cut -d ' ' -f 1)"
[[ "$AUDIO_SHA256" =~ ^[a-f0-9]{64}$ ]] || { echo "could not hash rendered audio" >&2; exit 1; }
/bin/mv "$RENDERED_AUDIO" "$OUTPUT_PATH"

printf 'AUDIO_PROFILE=%s\n' "$AUDIO_PROFILE"
printf 'AUDIO_SEED=%s\n' "$AUDIO_SEED"
printf 'AUDIO_DURATION_SECONDS=%s\n' "$AUDIO_DURATION_SECONDS"
printf 'AUDIO_SHA256=%s\n' "$AUDIO_SHA256"

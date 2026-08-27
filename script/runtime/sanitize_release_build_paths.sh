#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'Usage: sanitize_release_build_paths.sh /path/to/Hireva /private/tmp/hireva-swiftpm-release-<commit> expected-replacement-count\n' >&2
}

if [[ $# -ne 3 ]]; then
    usage
    exit 2
fi

BINARY="$1"
BUILD_ROOT="$2"
EXPECTED_COUNT="$3"
[[ "$EXPECTED_COUNT" =~ ^[1-9][0-9]*$ ]] || {
    printf 'error: expected replacement count must be a positive integer\n' >&2
    exit 2
}
[[ -f "$BINARY" && ! -L "$BINARY" ]] || {
    printf 'error: release executable must be a regular non-symlink file: %s\n' "$BINARY" >&2
    exit 1
}
[[ "$(/usr/bin/file -b "$BINARY")" == *Mach-O* ]] || {
    printf 'error: release build-path sanitizer accepts only Mach-O files: %s\n' "$BINARY" >&2
    exit 1
}
[[ "$BUILD_ROOT" =~ ^/private/tmp/hireva-swiftpm-release-[0-9a-f]{40}$ ]] || {
    printf 'error: release build root does not match the reviewed deterministic form\n' >&2
    exit 1
}

SOURCE_PREFIX="$BUILD_ROOT/"
SANITIZED_PREFIX="/build/root_/${SOURCE_PREFIX#/private/tmp/}"
[[ ${#SOURCE_PREFIX} -eq ${#SANITIZED_PREFIX} ]] || {
    printf 'error: reviewed release build-path replacement must preserve byte length\n' >&2
    exit 1
}

count_occurrences() {
    HIREVA_PATH_NEEDLE="$1" LC_ALL=C /usr/bin/perl -0777 -ne '
        $needle = $ENV{"HIREVA_PATH_NEEDLE"};
        $count = () = /\Q$needle\E/g;
        print "$count\n";
    ' "$2"
}

SOURCE_COUNT="$(count_occurrences "$SOURCE_PREFIX" "$BINARY")"
[[ "$SOURCE_COUNT" == "$EXPECTED_COUNT" ]] || {
    printf 'error: release build-path count changed (expected %s, found %s): %s\n' \
        "$EXPECTED_COUNT" "$SOURCE_COUNT" "$BINARY" >&2
    exit 1
}

HIREVA_PATH_FROM="$SOURCE_PREFIX" \
HIREVA_PATH_TO="$SANITIZED_PREFIX" \
LC_ALL=C /usr/bin/perl -0777 -pi -e '
    $from = $ENV{"HIREVA_PATH_FROM"};
    $to = $ENV{"HIREVA_PATH_TO"};
    die "replacement length mismatch\n" unless length($from) == length($to);
    s/\Q$from\E/$to/g;
' "$BINARY"

[[ "$(count_occurrences "$SOURCE_PREFIX" "$BINARY")" == "0" ]] || {
    printf 'error: release build-path sanitization was incomplete: %s\n' "$BINARY" >&2
    exit 1
}
[[ "$(count_occurrences "$SANITIZED_PREFIX" "$BINARY")" == "$EXPECTED_COUNT" ]] || {
    printf 'error: sanitized release build-path count differs from the reviewed contract: %s\n' \
        "$BINARY" >&2
    exit 1
}
if LC_ALL=C /usr/bin/grep -a -Eq \
    '/Users/|/Volumes/|/home/|/private/tmp/hireva-swiftpm-release-' "$BINARY"; then
    printf 'error: release executable still contains a forbidden build path: %s\n' "$BINARY" >&2
    exit 1
fi

printf 'SANITIZATION=deterministic-swiftpm-prefix-to-build-root-v1\n'
printf 'REPLACEMENTS=%s\n' "$EXPECTED_COUNT"

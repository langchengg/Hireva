#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=runtime_contract.sh
source "$ROOT_DIR/script/runtime/runtime_contract.sh"

usage() {
    printf 'Usage: sanitize_runtime_paths.sh /path/to/runtime.dylib expected-replacement-count\n' >&2
}

if [[ $# -ne 2 ]]; then
    usage
    exit 2
fi

LIBRARY="$1"
EXPECTED_COUNT="$2"
[[ "$EXPECTED_COUNT" =~ ^[1-9][0-9]*$ ]] || {
    printf 'error: expected replacement count must be a positive integer\n' >&2
    exit 2
}
[[ -f "$LIBRARY" && ! -L "$LIBRARY" ]] || {
    printf 'error: runtime library must be a regular non-symlink file: %s\n' "$LIBRARY" >&2
    exit 1
}
[[ "$(/usr/bin/file -b "$LIBRARY")" == *Mach-O* ]] || {
    printf 'error: runtime path sanitizer accepts only Mach-O files: %s\n' "$LIBRARY" >&2
    exit 1
}
[[ ${#HIREVA_RUNTIME_SOURCE_PATH_PREFIX} -eq ${#HIREVA_RUNTIME_SANITIZED_PATH_PREFIX} ]] || {
    printf 'error: reviewed runtime path replacement must preserve byte length\n' >&2
    exit 1
}

count_occurrences() {
    HIREVA_PATH_NEEDLE="$1" LC_ALL=C /usr/bin/perl -0777 -ne '
        $needle = $ENV{"HIREVA_PATH_NEEDLE"};
        $count = () = /\Q$needle\E/g;
        print "$count\n";
    ' "$2"
}

SOURCE_COUNT="$(count_occurrences "$HIREVA_RUNTIME_SOURCE_PATH_PREFIX" "$LIBRARY")"
[[ "$SOURCE_COUNT" == "$EXPECTED_COUNT" ]] || {
    printf 'error: runtime source path count changed (expected %s, found %s): %s\n' \
        "$EXPECTED_COUNT" "$SOURCE_COUNT" "$LIBRARY" >&2
    exit 1
}

HIREVA_PATH_FROM="$HIREVA_RUNTIME_SOURCE_PATH_PREFIX" \
HIREVA_PATH_TO="$HIREVA_RUNTIME_SANITIZED_PATH_PREFIX" \
LC_ALL=C /usr/bin/perl -0777 -pi -e '
    $from = $ENV{"HIREVA_PATH_FROM"};
    $to = $ENV{"HIREVA_PATH_TO"};
    die "replacement length mismatch\n" unless length($from) == length($to);
    s/\Q$from\E/$to/g;
' "$LIBRARY"

[[ "$(count_occurrences "$HIREVA_RUNTIME_SOURCE_PATH_PREFIX" "$LIBRARY")" == "0" ]] || {
    printf 'error: runtime source path sanitization was incomplete: %s\n' "$LIBRARY" >&2
    exit 1
}
[[ "$(count_occurrences "$HIREVA_RUNTIME_SANITIZED_PATH_PREFIX" "$LIBRARY")" == "$EXPECTED_COUNT" ]] || {
    printf 'error: runtime sanitized path count differs from the reviewed contract: %s\n' "$LIBRARY" >&2
    exit 1
}
if LC_ALL=C /usr/bin/grep -a -Eq '/Users/|/Volumes/|/home/' "$LIBRARY"; then
    printf 'error: runtime library still contains an absolute user path: %s\n' "$LIBRARY" >&2
    exit 1
fi

printf 'SANITIZATION=%s\n' "$HIREVA_RUNTIME_PATH_SANITIZATION_IDENTIFIER"
printf 'REPLACEMENTS=%s\n' "$EXPECTED_COUNT"

#!/usr/bin/env bash
set -euo pipefail

# Compute a repository-defined canonical hash of a complete thin arm64 Mach-O.
# The parser covers headers, normalized non-signature load commands, every
# file-backed segment byte, and __LINKEDIT while excluding only the embedded
# code-signature command/blob and signature-dependent __LINKEDIT sizes.

if [[ $# -ne 1 ]]; then
    printf 'usage: %s /path/to/thin-macho\n' "$(basename "$0")" >&2
    exit 2
fi

TARGET="$1"
[[ -f "$TARGET" && ! -L "$TARGET" ]] || {
    printf 'error: expected a regular non-symlink Mach-O file\n' >&2
    exit 1
}

PARSER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/macho_payload_sha256.rb"
[[ -f "$PARSER" && ! -L "$PARSER" ]] || {
    printf 'error: canonical Mach-O parser is unavailable\n' >&2
    exit 1
}
exec /usr/bin/ruby "$PARSER" "$TARGET"

#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'Usage: %s /path/to/macho\n' "$(basename "$0")"
}

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

BINARY_PATH="$1"
if [[ ! -f "$BINARY_PATH" || -L "$BINARY_PATH" ]]; then
    echo "[grdb-resource] ERROR: binary must be a regular, non-symlink file: $BINARY_PATH" >&2
    exit 2
fi
if [[ "$(/usr/bin/file -b "$BINARY_PATH")" != *Mach-O* ]]; then
    echo "[grdb-resource] ERROR: binary is not Mach-O: $BINARY_PATH" >&2
    exit 2
fi

ACCESSOR_SYMBOL='$sSo8NSBundleC4GRDBE6moduleABvgZ'
BUNDLE_MARKER='GRDB_GRDB.bundle'
WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hireva-grdb-accessor.XXXXXX")"
cleanup() {
    /bin/rm -f "$WORK_DIR/strings.txt" "$WORK_DIR/symbols.txt" "$WORK_DIR/disassembly.txt"
    /bin/rmdir "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

/usr/bin/strings -a "$BINARY_PATH" > "$WORK_DIR/strings.txt"
if ! /usr/bin/grep -F "$BUNDLE_MARKER" "$WORK_DIR/strings.txt" >/dev/null; then
    exit 0
fi

/usr/bin/nm -nm "$BINARY_PATH" > "$WORK_DIR/symbols.txt"
if ! /usr/bin/grep -F "$ACCESSOR_SYMBOL" "$WORK_DIR/symbols.txt" >/dev/null; then
    echo "[grdb-resource] ERROR: GRDB bundle marker exists without the pinned generated accessor definition; refusing resource relocation." >&2
    exit 1
fi

/usr/bin/otool -tvV "$BINARY_PATH" > "$WORK_DIR/disassembly.txt"
CALL_COUNT="$(/usr/bin/awk -v symbol="$ACCESSOR_SYMBOL" '
    ($2 == "b" || $2 == "bl") && index($0, symbol) > 0 { count += 1 }
    END { print count + 0 }
' "$WORK_DIR/disassembly.txt")"
if (( CALL_COUNT > 0 )); then
    echo "[grdb-resource] ERROR: live GRDB Bundle.module accessor call prevents relocation to Contents/Resources (calls=$CALL_COUNT)." >&2
    exit 1
fi

exit 0

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
NOTICE_DIR="$ROOT_DIR/Resources/ThirdPartyNotices"

verify_notice() {
    local name="$1"
    local expected="$2"
    local path="$NOTICE_DIR/$name"
    local actual

    [[ -f "$path" && ! -L "$path" ]] || {
        printf '[notices] ERROR: vendored notice must be a regular non-symlink file: %s\n' "$name" >&2
        exit 1
    }
    actual="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
        printf '[notices] ERROR: SHA-256 mismatch for vendored notice: %s\n' "$name" >&2
        exit 1
    }
}

verify_notice \
    sherpa-onnx-LICENSE.txt \
    cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
verify_notice \
    onnxruntime-LICENSE.txt \
    2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c
verify_notice \
    onnxruntime-ThirdPartyNotices.txt \
    0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2
verify_notice \
    GRDB-LICENSE.txt \
    b9ce5b40c859a62fa6998995a9d284565aba72e92ca7c655f64777948f885139

unexpected="$(/usr/bin/find "$NOTICE_DIR" -mindepth 1 -maxdepth 1 -type f \
    ! -name 'sherpa-onnx-LICENSE.txt' \
    ! -name 'onnxruntime-LICENSE.txt' \
    ! -name 'onnxruntime-ThirdPartyNotices.txt' \
    ! -name 'GRDB-LICENSE.txt' -print -quit)"
[[ -z "$unexpected" ]] || {
    printf '[notices] ERROR: unexpected vendored notice: %s\n' "${unexpected#"$NOTICE_DIR/"}" >&2
    exit 1
}

printf '%s\n' "$NOTICE_DIR"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=release_common.sh
source "$SCRIPT_DIR/release_common.sh"

usage() {
    cat <<'USAGE'
Usage: HIREVA_SIGNING_MODE=<mode> HIREVA_BUILD_ARCHS="<archs>" \
       [HIREVA_SIGNING_IDENTITY=<identity>] \
       ./script/release/verify_app.sh /path/to/Hireva.app

Verify bundle structure, required Mach-O architectures, nested signatures,
requested signature class, hardened runtime/timestamp policy, and the reviewed
entitlement set. Verification reads the signature and does not require access
to its private signing key.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
[[ "$#" -eq 1 ]] || {
    usage >&2
    exit 2
}

release_validate_mode
release_load_architectures
release_load_app "$1"
release_reject_unstable_metadata
release_validate_architectures
release_assert_signature_mode "$RELEASE_APP_PATH"

echo "[pass] Verified $(basename "$RELEASE_APP_PATH") in $RELEASE_SIGNING_MODE mode for ${RELEASE_ARCHS[*]}."

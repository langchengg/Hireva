#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=release_common.sh
source "$SCRIPT_DIR/release_common.sh"

usage() {
    cat <<'USAGE'
Usage: HIREVA_SIGNING_MODE=<mode> [HIREVA_SIGNING_IDENTITY=<identity>] \
       ./script/release/check_identity.sh

Validate the explicitly selected signing mode and identity without changing an
app bundle. Supported modes are adhoc, development, and developer-id.

development and developer-id require HIREVA_SIGNING_IDENTITY to select exactly
one currently valid identity. Adhoc requires it to be unset. A full common name
or SHA-1 hash is accepted for certificate-backed modes.
USAGE
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    '')
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

release_validate_mode
release_validate_identity_for_signing

case "$RELEASE_SIGNING_MODE" in
    adhoc)
        echo "Identity check passed: ad-hoc mode explicitly selected; no certificate will be used."
        ;;
    development)
        echo "Identity check passed: one valid Apple Development identity matched."
        ;;
    developer-id)
        echo "Identity check passed: one valid Developer ID Application identity matched."
        ;;
esac

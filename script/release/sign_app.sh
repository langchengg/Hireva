#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=release_common.sh
source "$SCRIPT_DIR/release_common.sh"

usage() {
    cat <<'USAGE'
Usage: sign_app.sh /path/to/Hireva.app

Required environment:
  HIREVA_SIGNING_MODE      adhoc, development, or developer-id
  HIREVA_BUILD_ARCHS       Required architectures, comma or space separated
  HIREVA_SIGNING_IDENTITY  Required for development/developer-id; forbidden for adhoc
  HIREVA_EXPECTED_TEAM_IDENTIFIER
                           Explicit 10-character Apple Team ID for developer-id

The app is modified in place. Identity, architecture, bundle, and metadata
validation complete before the first signing operation.
USAGE
}

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

release_validate_mode
release_load_architectures
release_validate_identity_for_signing
release_load_app "$1"
release_reject_unstable_metadata
release_validate_architectures

if [[ "$RELEASE_SIGNING_MODE" == "developer-id" ]]; then
    if [[ ! -f "$RELEASE_ENTITLEMENTS_PATH" ]] || ! /usr/bin/plutil -lint "$RELEASE_ENTITLEMENTS_PATH" >/dev/null; then
        release_die "missing or invalid reviewed release entitlements: $RELEASE_ENTITLEMENTS_PATH"
    fi
fi

release_sign_target() {
    local target="$1"
    local is_outer_app="$2"
    local requirements
    local args=(--force --sign "$RELEASE_SIGNING_VALUE")

    case "$RELEASE_SIGNING_MODE" in
        adhoc)
            if [[ "$is_outer_app" == "yes" ]]; then
                requirements="=designated => identifier \"$RELEASE_BUNDLE_IDENTIFIER\""
                args+=(--requirements "$requirements")
            fi
            ;;
        development)
            args+=(--timestamp=none)
            ;;
        developer-id)
            args+=(--options runtime --timestamp)
            if [[ "$is_outer_app" == "yes" ]]; then
                args+=(--entitlements "$RELEASE_ENTITLEMENTS_PATH")
            fi
            ;;
    esac

    /usr/bin/codesign "${args[@]}" "$target"
}

printf '[sign] mode=%s architectures=%s\n' "$RELEASE_SIGNING_MODE" "${RELEASE_ARCHS[*]}"
if [[ "$RELEASE_SIGNING_MODE" != "adhoc" ]]; then
    printf '[sign] validated identity class for mode=%s\n' "$RELEASE_SIGNING_MODE"
fi

# Sign standalone Mach-O code first. The outer app's main executable is signed
# when the app bundle is signed last with its reviewed entitlements.
for macho in "${RELEASE_MACHO_PATHS[@]}"; do
    if [[ "$macho" == "$RELEASE_MAIN_EXECUTABLE" ]]; then
        continue
    fi
    printf '[sign] nested Mach-O: %s\n' "${macho#"$RELEASE_APP_PATH"/}"
    release_sign_target "$macho" no
done

# Sign nested code bundles deepest-first, then seal the outer app last.
release_collect_nested_bundles
if [[ -n "${RELEASE_NESTED_BUNDLES+x}" ]]; then
    for bundle in "${RELEASE_NESTED_BUNDLES[@]}"; do
        printf '[sign] nested bundle: %s\n' "${bundle#"$RELEASE_APP_PATH"/}"
        release_sign_target "$bundle" no
    done
fi
printf '[sign] outer app: %s\n' "$RELEASE_APP_PATH"
release_sign_target "$RELEASE_APP_PATH" yes

release_assert_signature_mode "$RELEASE_APP_PATH"
printf 'SIGNING_MODE=%s\n' "$RELEASE_SIGNING_MODE"
printf 'SIGNED_APP=%s\n' "$RELEASE_APP_PATH"
printf '[verify] code signatures, mode, architectures, runtime, and entitlements passed\n'

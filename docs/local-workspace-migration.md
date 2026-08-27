# Local Workspace Migration

Building inside Google Drive can reintroduce extended attributes, Finder
metadata, resource forks, and AppleDouble `._*` files after a build cleans the
bundle. Those changes can invalidate a sealed app bundle or make signing and
Gatekeeper results intermittent.

The recommended local build path is:

```text
~/Developer/Hireva
```

## Safe Source Copy Without Repository or Build Artifacts

Set explicit source and destination roots, validate both, preview the change,
then copy only source and operator files:

```bash
export HIREVA_SOURCE_ROOT="/path/to/your/Hireva"
export HIREVA_DESTINATION_ROOT="$HOME/Developer/Hireva"
test -d "$HIREVA_SOURCE_ROOT/.git"
test ! -L "$HIREVA_SOURCE_ROOT"
test ! -e "$HIREVA_DESTINATION_ROOT"
HIREVA_SOURCE_REAL="$(cd -P "$HIREVA_SOURCE_ROOT" && pwd)"
HIREVA_DESTINATION_PARENT="$(cd -P "$(dirname "$HIREVA_DESTINATION_ROOT")" && pwd)"
HIREVA_DESTINATION_REAL="$HIREVA_DESTINATION_PARENT/$(basename "$HIREVA_DESTINATION_ROOT")"
test "$HIREVA_SOURCE_REAL" != "$HIREVA_DESTINATION_REAL"
case "$HIREVA_DESTINATION_REAL/" in "$HIREVA_SOURCE_REAL/"*) exit 1;; esac
case "$HIREVA_SOURCE_REAL/" in "$HIREVA_DESTINATION_REAL/"*) exit 1;; esac
rsync -an \
  --exclude '.git' \
  --exclude '.build' \
  --exclude 'dist' \
  --exclude 'release' \
  "$HIREVA_SOURCE_REAL/" \
  "$HIREVA_DESTINATION_REAL/"
```

This method intentionally requires a new destination and omits Git history,
caches, existing app bundles, and generated release packages. It never uses
`--delete`.

The command above is intentionally a dry run. After reviewing every deletion,
run the corresponding copy command:

```bash
test ! -e "$HIREVA_DESTINATION_REAL"
mkdir -m 700 "$HIREVA_DESTINATION_REAL"
rsync -a \
  --exclude '.git' \
  --exclude '.build' \
  --exclude 'dist' \
  --exclude 'release' \
  "$HIREVA_SOURCE_REAL/" \
  "$HIREVA_DESTINATION_REAL/"
```

If the source currently contains `.DS_Store` or AppleDouble files, add
`--exclude '.DS_Store' --exclude '._*'` to both the preview and final command.

## Alternative: Move the Full Git Repository

To preserve `.git`, start with a different new destination, repeat the same
canonical-path and non-nesting checks above, and omit only the `.git` exclusion
while retaining the build artifact exclusions:

```bash
test -d "$HIREVA_SOURCE_REAL/.git"
test ! -e "$HIREVA_DESTINATION_REAL"
rsync -an \
  --exclude '.build' \
  --exclude 'dist' \
  --exclude 'release' \
  "$HIREVA_SOURCE_REAL/" \
  "$HIREVA_DESTINATION_REAL/"
# Review the preview, create the destination with mkdir -m 700, then repeat
# with -a instead of -an. Do not add --delete.
```

Before the full-repository copy, make sure no Git operation is running. After
the copy, compare `git status --short`, branch, commit, remotes, and tags in both
locations.

## Verify Before Removing the Original

Do not delete or rename the Google Drive source until the local copy has passed
verification and any required manual System Audio smoke.

```bash
cd "$HIREVA_DESTINATION_ROOT"
./scripts/verify_runtime_stability.sh
./script/build_and_run.sh --verify
./scripts/release_status.sh
```

Then run `./scripts/signing_status.sh` and create one package with
`./scripts/package_local_release.sh`. Confirm the bundle path and permissions
now refer to the local workspace before considering the migration complete.

Release builds do not record source or expected-bundle absolute paths. Those
diagnostics are available only when an operator explicitly opts into a debug,
development-signed build. Rebuild in the destination workspace so the app and
evidence are derived from the intended source tree.

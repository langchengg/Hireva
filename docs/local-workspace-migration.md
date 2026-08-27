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
test "$HIREVA_SOURCE_ROOT" != "$HIREVA_DESTINATION_ROOT"
mkdir -p "$HIREVA_DESTINATION_ROOT"
rsync -an --delete \
  --exclude '.git' \
  --exclude '.build' \
  --exclude 'dist' \
  --exclude 'release' \
  "$HIREVA_SOURCE_ROOT/" \
  "$HIREVA_DESTINATION_ROOT/"
# Review the preview, then repeat with -a instead of -an.
```

`--delete` removes destination files that are absent from the source. Confirm
the destination path before running it. This method intentionally omits Git
history, caches, existing app bundles, and generated release packages.

The command above is intentionally a dry run. After reviewing every deletion,
repeat it with `-a` instead of `-an`. If the source currently contains
`.DS_Store` or AppleDouble files, add
`--exclude '.DS_Store' --exclude '._*'` to both the preview and final command.

## Alternative: Move the Full Git Repository

To preserve `.git`, omit only the `.git` exclusion while retaining the build
artifact exclusions:

```bash
test -d "$HIREVA_SOURCE_ROOT/.git"
test "$HIREVA_SOURCE_ROOT" != "$HIREVA_DESTINATION_ROOT"
rsync -an --delete \
  --exclude '.build' \
  --exclude 'dist' \
  --exclude 'release' \
  "$HIREVA_SOURCE_ROOT/" \
  "$HIREVA_DESTINATION_ROOT/"
# Review the preview, then repeat with -a instead of -an.
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

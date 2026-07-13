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

Create the destination parent, then copy only source and operator files:

```bash
mkdir -p "$HOME/Developer/Hireva"
rsync -a --delete \
  --exclude '.git' \
  --exclude '.build' \
  --exclude 'dist' \
  --exclude 'release' \
  "/Users/delaynomore/Library/CloudStorage/GoogleDrive-langcheng.cn@gmail.com/My Drive/Hireva/" \
  "$HOME/Developer/Hireva/"
```

`--delete` removes destination files that are absent from the source. Confirm
the destination path before running it. This method intentionally omits Git
history, caches, existing app bundles, and generated release packages.

Preview the same operation before copying by changing `-a` to `-an`. If the
source currently contains `.DS_Store` or AppleDouble files, add
`--exclude '.DS_Store' --exclude '._*'` to both the preview and final command.

## Alternative: Move the Full Git Repository

To preserve `.git`, omit only the `.git` exclusion while retaining the build
artifact exclusions:

```bash
mkdir -p "$HOME/Developer/Hireva"
rsync -a --delete \
  --exclude '.build' \
  --exclude 'dist' \
  --exclude 'release' \
  "/Users/delaynomore/Library/CloudStorage/GoogleDrive-langcheng.cn@gmail.com/My Drive/Hireva/" \
  "$HOME/Developer/Hireva/"
```

Before the full-repository copy, make sure no Git operation is running. After
the copy, compare `git status --short`, branch, commit, remotes, and tags in both
locations.

## Verify Before Removing the Original

Do not delete or rename the Google Drive source until the local copy has passed
verification and any required manual System Audio smoke.

```bash
cd "$HOME/Developer/Hireva"
./scripts/verify_runtime_stability.sh
./script/build_and_run.sh --verify
./scripts/release_status.sh
```

Then run `./scripts/signing_status.sh` and create one package with
`./scripts/package_local_release.sh`. Confirm the bundle path and permissions
now refer to the local workspace before considering the migration complete.

The build identity records the workspace's absolute `dist` app path. A package
copied from that workspace is suitable for local archive/handoff, but launching
the copied app from another path can display the existing stale-build warning.
Rebuild in the destination workspace to make its `dist/Hireva.app`
the canonical verified bundle.

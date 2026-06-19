# Rollback to a Known-Good Build

Rollback should preserve user data and produce a newly verified artifact from a
known source revision. Do not use destructive Git reset commands in a dirty
worktree.

## Find Stable Tags

```bash
git tag --list
```

Important milestone tag names for this project are:

- `phase2h-runtime-stability-gate-complete`
- `phase2i-release-packaging-complete`
- future `phase2j-local-distribution-prep-complete`

Verify that a named tag actually exists and points to the expected commit before
using it. At the start of Phase 2J, the repository's existing tags use older
`appstate-*` names, so absent milestone tags must not be invented or assumed.
Commits `7cf3f3b` (Phase 2H) and `b80faf6` (Phase 2I) are candidate source
revisions, not verified release tags.

```bash
git tag --list --sort=-creatordate
git tag --points-at HEAD
git show --no-patch --decorate phase2i-release-packaging-complete
```

If the recorded tag is absent, stop and obtain the intended commit/tag from the
release record. Never substitute the nearest tag silently.

## Inspect a Tag in Detached HEAD

Start from a clean worktree, or use a separate worktree/clone:

```bash
git switch --detach phase2i-release-packaging-complete
```

Detached HEAD is appropriate for inspection and rebuilding. Do not make lasting
changes there without creating a branch.

## Create a Recovery Branch

```bash
git switch -c recovery/phase2i-known-good
```

Use a clear recovery branch name and record the source tag/commit in the handoff
notes.

## Restore an Uncommitted Patch

First inspect the patch and confirm the target commit matches its original base:

```bash
git apply --check /path/to/uncommitted.patch
git apply /path/to/uncommitted.patch
git status --short
```

If untracked files were archived separately, extract them into a temporary
directory first, review the paths, and copy only the intended files. Do not
overwrite a newer worktree blindly.

## Verify the Rollback

Preserve the existing SQLite DB and runtime trace before replacing an app; do
not package or commit either file. Then rebuild the known-good source:

```bash
./scripts/verify_runtime_stability.sh
./script/build_and_run.sh --verify
```

Run any manual System Audio smoke required by the boundaries that changed.
Record the recovered commit, signing mode, bundle path, verification logs, and
whether the old artifact was removed from distribution.

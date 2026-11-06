# Local application artifacts

Use `./script/build_and_run.sh --build-only` for a build without launching, or
`./script/build_and_run.sh` to build and launch. Codex Run uses that same entry.
`python3 script/artifact_lifecycle.py paths` prints the absolute application path.
The default is `~/Developer/HirevaArtifacts/<repository-id>/development/dist/Hireva.app`.
Verification-only builds use a separate fixed `verification/dist/Hireva.app` under
the same root (`HIREVA_VERIFICATION_BUNDLE=1`). Neither location replaces an
installed application or the historical repository `dist/Hireva.app`.

The coordinator owns compilation caches, native helper output, task directories,
and publication. A nonblocking file lock rejects a competing build/package/test
with a clear busy error; it does not disable test concurrency. A running bundle or
an externally modified managed bundle is never replaced. Builds assemble and sign
in a fresh task directory. Publication records the previous receipt so a failed or
interrupted replacement can recover the previous bundle. Only task-owned staging
is reclaimed, after its writers have stopped. An unrecognized directory is retained
for inspection. SIGKILL recovery runs on the next entry after the inherited lock is free.
Cleanup checks for active group members before signalling. A signal denial is
accepted only after a fresh check confirms no active members remain; an inspection
failure or still-active denied group retains staging and reports incomplete cleanup.

`HIREVA_BUNDLE_OUTPUT_DIR` no longer accepts arbitrary historical output locations.
This prevents the old pattern of creating a complete app in every timestamped
acceptance folder. Existing historical scripts using that variable fail before
modifying their destinations. Update their bundle reference to the path printed by
`paths`; wrap a test/supervisor with `python3 script/artifact_lifecycle.py exec --
<command> ...` to keep its bundle stable while it runs. The wrapper exports
`HIREVA_APP_BUNDLE` and `HIREVA_SWIFTPM_BUILD_PATH`.

Build logs and receipts live in `logs/`; receipts record the full bundle digest,
source status, commit, signing mode and final absolute path. They are not full app
copies. The existing signing identity, Bundle ID and app version are unchanged.
Ad-hoc builds remain local developer builds, not notarized releases.

## Test and package

```sh
./scripts/runtime_smoke.sh --suite all
./scripts/verify_runtime_stability.sh
./scripts/package_local_release.sh --skip-verify
./scripts/package_dmg.sh
```

Both package commands build and validate without launching the GUI. The first
retains one `release/Hireva-local.zip`; `--skip-verify` skips the broader runtime
stability suite, not signature or archive integrity checks. The DMG command retains
one archive per version/architecture. Their expanded copies exist only in owned
staging. Ordinary build/test commands create no ZIP or DMG. The DMG entry does not
mount a volume. The explicitly invoked Developer ID publication/notarization
workflow under `script/release/` still retains its versioned signed app as required
by its notarization manifest; it is not invoked by build, smoke, or local packaging.

## Historical cleanup and recovery

`python3 scripts/cleanup_hireva_artifacts.py /absolute/reviewed-plan.json` is a dry
run. It reports each candidate, retained counterpart, reason, size, operation and
recovery method. `--apply` moves only allowlisted identical copies to a unique
Trash directory. It rechecks inode, full bundle content and extended attributes,
Bundle ID, active processes, protected paths and current entrypoint references.
It never deletes the reports surrounding an app. Moving to Trash frees no space.

Unique historical binaries require an explicitly approved plan and
`--archive-approved --output /absolute/results.json`. Each pinned ZIP is restored
in temporary staging and checked against the complete manifest and signature
before its original expanded app is retired. `baselines/*.json` records original
path, archive hash, bundle hash and retention status. There is no automatic expiry
for these baseline archives. Interrupted operations retain their archive and receipt.

Restore either a Trash receipt or a baseline receipt with:

```sh
python3 scripts/cleanup_hireva_artifacts.py /absolute/receipt.json --restore
```

Restoration refuses any occupied original path. It does not launch the application.
Historical report conclusions are unchanged; the receipt supplies the old-path to
archive mapping. Keep the receipt with its archive. Source/synchronization paths,
user data, models, installed apps and explicit protected baselines are excluded.

APFS sharing and snapshots mean summed application sizes are not measured space
savings. Record filesystem availability before and after, and distinguish net disk
change from logical bytes retired. System Storage can refresh later; inspect its
actual list before declaring the UI fixed. Do not reset global indexes or app registrations.

Implementation references only (no external code copied):
[Python flock](https://docs.python.org/3.14/library/fcntl.html),
[subprocess and inherited descriptors](https://docs.python.org/3.14/library/subprocess.html),
[Apple code-signing verification](https://developer.apple.com/library/archive/technotes/tn2206/),
[Apple APFS](https://developer.apple.com/documentation/foundation/about-apple-file-system),
and the installed macOS `ditto(1)`, `renameatx_np(2)` and `hdiutil(1)` manuals.

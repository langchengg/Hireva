#!/usr/bin/env python3
"""Dry-run by default. Recoverably move only reviewed, byte-identical Hireva copies."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
import artifact_lifecycle as lifecycle

ALLOWED_ROOTS = [Path.home() / 'Hireva-refactor-evidence',
                 Path.home() / 'Developer/HirevaVerificationArtifacts']


def identity(path):
    s = path.lstat()
    return [s.st_dev, s.st_ino, s.st_mtime_ns]


def validate(entry, protected, archive=False):
    path = lifecycle.safe_path(entry['path'])
    keep = lifecycle.safe_path(entry['keep']) if not archive else None
    if not any(root in path.parents for root in ALLOWED_ROOTS):
        raise ValueError('outside the project cleanup allowlist')
    if path == keep or str(path) in protected or (path.parent / '.hireva-retain').exists():
        raise ValueError('protected application')
    if identity(path) != entry['identity']:
        raise ValueError('source changed since review')
    for app in ((path, keep) if keep else (path,)):
        if app.suffix != '.app' or app.is_symlink():
            raise ValueError('expected a real application directory')
        metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if metadata.get('CFBundleIdentifier') != lifecycle.BUNDLE_ID:
            raise ValueError('bundle identity mismatch')
    if lifecycle.in_use(path):
        raise ValueError('application is running')
    commands = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True)
    if str(path) in commands:
        raise ValueError('active command references this bundle')
    if lifecycle.fingerprint(path) != entry['sha256'] or (keep and lifecycle.fingerprint(keep) != entry['sha256']):
        raise ValueError('complete bundles differ or changed; unique binaries must be retained')
    if not entry.get('reference_review'):
        raise ValueError('missing reviewed evidence that the duplicate is unreferenced')
    for root in [lifecycle.REPO / 'script', lifecycle.REPO / 'scripts', lifecycle.REPO / '.codex']:
        match = subprocess.run(['rg', '-l', '-F', str(path), str(root)], capture_output=True, text=True)
        if match.returncode == 0:
            raise ValueError('current project entrypoint still references this bundle: ' + match.stdout.strip())
        if match.returncode != 1:
            raise ValueError('could not check current entrypoint references')
    return path


def rename_exclusive(source, destination, expected):
    """Pin parent directories and refuse destination replacement at the kernel boundary."""
    lib = ctypes.CDLL(None, use_errno=True)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    srcfd, dstfd = os.open(source.parent, flags), os.open(destination.parent, flags)
    try:
        source_stat = os.stat(source.name, dir_fd=srcfd, follow_symlinks=False)
        if [source_stat.st_dev, source_stat.st_ino, source_stat.st_mtime_ns] != expected:
            raise ValueError('source replaced before move')
        if os.fstat(srcfd).st_ino != source.parent.stat().st_ino:
            raise ValueError('source parent replaced before move')
        # RENAME_EXCL is 0x4 in the macOS SDK's sys/stdio.h.
        if lib.renameatx_np(srcfd, os.fsencode(source.name), dstfd, os.fsencode(destination.name), 4):
            raise OSError(ctypes.get_errno(), 'exclusive rename failed')
        if identity(destination)[:2] != expected[:2]:
            if lib.renameatx_np(dstfd, os.fsencode(destination.name), srcfd, os.fsencode(source.name), 4):
                raise ValueError('source race detected; moved object retained for manual recovery')
            raise ValueError('source race detected; move reversed')
    finally:
        os.close(srcfd)
        os.close(dstfd)


def cleanup(plan, apply=False, trash=None):
    protected = plan['protected']
    results = []
    for entry in plan['allowlist']:
        result = {'path': entry['path'], 'keep': entry['keep'], 'reason': entry['reason'],
                  'method': 'exclusive rename of this app only to a unique Trash directory',
                  'recover': 'restore the move receipt; existing destination is never overwritten',
                  'risk': 'no space is freed until this specific trashed copy is permanently deleted'}
        try:
            path = validate(entry, protected)
            result.update(status='eligible', logical_bytes=entry['logical_bytes'])
            if apply:
                trash_root = trash or Path.home() / '.Trash'
                if trash_root.is_symlink() or not trash_root.is_dir():
                    raise ValueError('Trash is unavailable or is a symlink')
                destination_dir = trash_root / ('Hireva-duplicate-' + uuid.uuid4().hex)
                destination_dir.mkdir(mode=0o700)
                destination = destination_dir / 'Hireva.app'
                record = dict(entry, destination=str(destination), status='prepared')
                receipt = destination_dir / 'restore.json'
                lifecycle.save(receipt, record)
                validate(entry, protected)
                rename_exclusive(path, destination, entry['identity'])
                if lifecycle.fingerprint(destination) != entry['sha256']:
                    rename_exclusive(destination, path, identity(destination))
                    raise ValueError('post-move hash mismatch; restored original')
                record['status'] = 'moved'
                lifecycle.save(receipt, record)
                result.update(status='moved', destination=str(destination), receipt=str(receipt))
        except (ValueError, OSError, KeyError) as error:
            result.update(status='skipped', error=str(error))
        results.append(result)
    return {'dry_run': not apply, 'results': results, 'kept': plan['protected'],
            'permanently_deleted': 0, 'claimed_space_freed': 0}


def restore(receipt):
    record = json.loads(receipt.read_text())
    if 'archive' in record:
        return restore_archive(record, receipt)
    source = Path(record['destination'])
    target = lifecycle.safe_path(record['path'])
    if source != receipt.parent / 'Hireva.app' or source.is_symlink():
        raise ValueError('receipt does not own this quarantined bundle')
    if not any(root in target.parents for root in ALLOWED_ROOTS):
        raise ValueError('restore destination outside allowlist')
    if os.path.lexists(target):
        raise ValueError('restore destination is occupied; refusing overwrite')
    if lifecycle.active(source) or lifecycle.fingerprint(source) != record['sha256']:
        raise ValueError('quarantined application is active or changed')
    rename_exclusive(source, target, identity(source))
    record['status'] = 'restored'
    lifecycle.save(receipt, record)
    return {'restored': str(target), 'sha256': record['sha256']}


def restore_archive(record, receipt):
    target = lifecycle.safe_path(record['path'])
    if not any(root in target.parents for root in ALLOWED_ROOTS):
        raise ValueError('restore destination outside allowlist')
    if os.path.lexists(target):
        raise ValueError('restore destination is occupied; refusing overwrite')
    archive = Path(record['archive'])
    if archive.is_symlink() or lifecycle.digest(archive) != record['archive_sha256']:
        raise ValueError('archive is changed or missing')
    root = lifecycle.root_path()
    with lifecycle.task_directory(root, lifecycle.app_path(root)) as task:
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(task / 'restore')], check=True)
        restored = task / 'restore' / target.name
        if lifecycle.fingerprint(restored) != record['sha256']:
            raise ValueError('restored archive differs from the recorded bundle')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(restored)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        rename_exclusive(restored, target, identity(restored))
        record['status'] = 'restored'
        lifecycle.save(receipt, record)
    return {'restored': str(target), 'sha256': record['sha256']}


def archive_approved(plan, root, output):
    """One reviewed app at a time; a verified, pinned archive exists before retirement."""
    results = []
    archive_dir = root / 'baselines'
    archive_dir.mkdir(exist_ok=True)
    for entry in plan['allowlist']:
        result = {'path': entry['path']}
        try:
            path = validate(entry, plan['protected'], archive=True)
            token = lifecycle.hashlib.sha256(os.fsencode(path)).hexdigest()[:16]
            archive = archive_dir / (token + '.zip')
            receipt = archive_dir / (token + '.json')
            if archive.exists() or receipt.exists():
                raise ValueError('archive/receipt already exists; retained for review, never overwritten')
            with lifecycle.task_directory(root, lifecycle.app_path(root)) as task:
                temporary = task / 'baseline.zip'
                subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                                str(path), str(temporary)], check=True)
                subprocess.run(['/usr/bin/unzip', '-tq', str(temporary)], check=True,
                               stdout=subprocess.DEVNULL)
                subprocess.run(['/usr/bin/ditto', '-x', '-k', str(temporary), str(task / 'verify')], check=True)
                restored = task / 'verify' / path.name
                if lifecycle.fingerprint(restored) != entry['sha256']:
                    raise ValueError('archive round-trip changed bundle content or metadata')
                subprocess.run(['codesign', '--verify', '--deep', '--strict', str(restored)], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                record = dict(entry, archive=str(archive), archive_sha256=lifecycle.digest(temporary),
                              status='verified', retention='pinned: do not expire automatically')
                rename_exclusive(temporary, archive, identity(temporary))
                lifecycle.save(receipt, record)
                validate(entry, plan['protected'], archive=True)
                retired = task / 'retiring.app'
                lifecycle.save(task / 'retirement.json', dict(record, retired_path=str(retired), receipt=str(receipt)))
                rename_exclusive(path, retired, entry['identity'])
                if lifecycle.fingerprint(retired) != entry['sha256']:
                    rename_exclusive(retired, path, identity(retired))
                    raise ValueError('source changed while retiring; restored original')
                # This exact reviewed app is recoverable from the verified pinned archive.
                shutil.rmtree(retired)
                record['status'] = 'archived'
                lifecycle.save(receipt, record)
                result.update(status='archived', archive=str(archive), receipt=str(receipt),
                              logical_bytes=entry['logical_bytes'], archive_bytes=archive.stat().st_size)
        except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
            result.update(status='skipped', error=str(error))
        results.append(result)
        lifecycle.save(output, {'results': results, 'approved_count': len(plan['allowlist'])})
        print(json.dumps(result), flush=True)
    return {'results': results, 'approved_count': len(plan['allowlist'])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('plan', type=Path)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--restore', action='store_true')
    parser.add_argument('--archive-approved', action='store_true', help='execute an explicitly approved unique-binary archive plan')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if sum([args.apply, args.restore, args.archive_approved]) > 1:
        parser.error('select only one mutation mode')
    # Same cooperative lock as build/test/package; dry-run performs no artifact mutations.
    if args.restore or args.apply or args.archive_approved:
        root = lifecycle.root_path()
        with lifecycle.locked(root):
            lifecycle.recover(root)
            if args.archive_approved:
                if not args.output:
                    parser.error('--archive-approved requires --output for incremental receipts')
                result = archive_approved(json.loads(args.plan.read_text()), root, args.output)
            else:
                result = restore(args.plan) if args.restore else cleanup(json.loads(args.plan.read_text()), True)
    else:
        result = cleanup(json.loads(args.plan.read_text()))
    text = json.dumps(result, indent=2)
    if args.output:
        args.output.write_text(text + '\n')
    print(text)


if __name__ == '__main__':
    main()

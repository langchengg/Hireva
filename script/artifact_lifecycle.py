#!/usr/bin/env python3
"""Own Hireva's local build output; never adopt or replace an unmanaged bundle."""
import argparse
import contextlib
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

REPO = Path(__file__).resolve().parent.parent
REPO_KEY = hashlib.sha256(os.fsencode(REPO)).hexdigest()[:12]
BUNDLE_ID = 'com.langcheng.Hireva'


class WritersStillRunning(ValueError):
    def __init__(self, pgid):
        self.pgid = pgid
        super().__init__(f'owned writers in group {pgid} did not exit; task retained')


def group_active(pgid):
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pgid=,stat='], text=True)
    return any(int(row.split()[0]) == pgid and not row.split()[1].startswith('Z')
               for row in rows.splitlines())


def attributes(path):
    # macOS Python has no os.listxattr; use the platform's no-follow xattr API.
    lib = ctypes.CDLL(None, use_errno=True)
    lib.listxattr.restype = lib.getxattr.restype = ctypes.c_ssize_t
    raw = os.fsencode(path)
    size = lib.listxattr(raw, None, 0, 1)
    if size < 0:
        raise OSError(ctypes.get_errno(), f'listxattr: {path}')
    names = ctypes.create_string_buffer(size)
    if lib.listxattr(raw, names, size, 1) != size:
        raise OSError('xattrs changed while reading')
    result = {}
    for name in sorted(names.raw.rstrip(b'\0').split(b'\0')):
        if not name:
            continue
        length = lib.getxattr(raw, name, None, 0, 0, 1)
        if length < 0:
            raise OSError(ctypes.get_errno(), f'getxattr: {path}')
        value = ctypes.create_string_buffer(length)
        if lib.getxattr(raw, name, value, length, 0, 1) != length:
            raise OSError('xattr changed while reading')
        result[os.fsdecode(name)] = hashlib.sha256(value.raw).hexdigest()
    return result


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def manifest(path):
    """No symlink traversal or cloud-placeholder hydration; include all resources."""
    path = Path(path)
    if path.is_symlink() or not path.is_dir() or path.lstat().st_flags & 0x40000000:
        raise ValueError(f'not a local real directory: {path}')
    def walk_error(error):
        raise error
    rows = [['.', stat.S_IMODE(path.lstat().st_mode), 'directory', attributes(path)]]
    for directory, dirs, files in os.walk(path, followlinks=False, onerror=walk_error):
        for name in sorted(dirs + files):
            p = Path(directory) / name
            s = p.lstat()
            if s.st_flags & 0x40000000:
                raise ValueError(f'cloud placeholder: {p}')
            row = [str(p.relative_to(path)), stat.S_IMODE(s.st_mode)]
            if p.is_symlink():
                row += ['link', os.readlink(p)]
            elif p.is_file():
                row += ['file', s.st_size, digest(p)]
            elif p.is_dir():
                row += ['directory']
            else:
                raise ValueError(f'special file: {p}')
            # Resource forks and other attributes can change bundle semantics.
            row += [attributes(p)]
            rows.append(row)
    return sorted(rows)


def fingerprint(path):
    return hashlib.sha256(json.dumps(manifest(path), sort_keys=True).encode()).hexdigest()


def source_fingerprint():
    paths = subprocess.check_output(['git', '-C', str(REPO), 'ls-files', '-z', '--cached',
                                     '--others', '--exclude-standard']).split(b'\0')
    h = hashlib.sha256()
    for raw in sorted(set(paths)):
        if not raw:
            continue
        path = REPO / os.fsdecode(raw)
        h.update(raw + b'\0')
        if path.is_symlink():
            h.update(os.fsencode(os.readlink(path)))
        elif path.is_file():
            h.update(digest(path).encode())
        else:
            h.update(b'missing')
    return h.hexdigest()


def processes():
    lib = ctypes.CDLL('/usr/lib/libproc.dylib')
    result = {}
    for pid in subprocess.check_output(['/bin/ps', '-axo', 'pid='], text=True).split():
        buf = ctypes.create_string_buffer(4096)
        if lib.proc_pidpath(int(pid), buf, len(buf)) > 0:
            result[int(pid)] = os.fsdecode(buf.value)
    # A visible Hireva process whose executable could not be resolved blocks writes.
    hireva = subprocess.run(['/usr/bin/pgrep', '-x', 'Hireva'], capture_output=True, text=True)
    if hireva.returncode not in (0, 1):
        raise ValueError('cannot inspect Hireva processes')
    if any(int(pid) not in result for pid in hireva.stdout.split()):
        raise ValueError('Hireva executable path unavailable; keeping all bundles')
    return result


def active(path):
    prefix = str(path.resolve()) + '/'
    return {pid: exe for pid, exe in processes().items() if exe.startswith(prefix)}


def in_use(path):
    if not path.exists():
        return False
    if active(path):
        return True
    commands = subprocess.check_output(['/bin/ps', '-axo', 'command='], text=True)
    if str(path) in commands:
        return True
    opened = subprocess.run(['/usr/sbin/lsof', '-n', '-P', '+D', str(path)], capture_output=True)
    if opened.returncode not in (0, 1) or opened.stderr:
        raise ValueError(f'cannot establish whether files are in use: {path}')
    return opened.returncode == 0


def safe_path(path):
    path = Path(path)
    if not path.is_absolute() or path != path.resolve():
        raise ValueError(f'absolute path without symlink components required: {path}')
    text = str(path)
    if any(part in text for part in ('/CloudStorage/', '/Mobile Documents/', '/.Trash/',
                                     '/Application Support/', '/.ollama/')):
        raise ValueError(f'protected or synchronized path: {path}')
    forbidden_roots = ('/Applications', '/Volumes', str(Path.home() / 'Applications'))
    if any(text == p or text.startswith(p + '/') for p in forbidden_roots):
        raise ValueError(f'installed or mounted path: {path}')
    return path


def root_path():
    return safe_path(os.environ.get('HIREVA_ARTIFACT_ROOT',
                                   str(Path.home() / 'Developer/HirevaArtifacts' / REPO_KEY)))


def app_path(root):
    return root / ('verification' if os.environ.get('HIREVA_VERIFICATION_BUNDLE') == '1' else 'development') / 'dist/Hireva.app'


def save(path, value):
    fd, name = tempfile.mkstemp(prefix=path.name + '-', suffix='.partial', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextlib.contextmanager
def locked(root):
    if root == Path.home() or root == REPO or root in REPO.parents or REPO in root.parents:
        raise ValueError('artifact root must be separate from source and user data')
    root.mkdir(parents=True, exist_ok=True)
    owner = root / 'owner.json'
    expected = {'repository': str(REPO), 'schema': 1}
    inherited = os.environ.get('HIREVA_ARTIFACT_LOCK_FD')
    if inherited:
        fd = int(inherited)
        a, b = os.fstat(fd), (root / 'lifecycle.lock').stat()
        if (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
            raise ValueError('inherited lock does not own this artifact root')
        if json.loads(owner.read_text()) != expected:
            raise ValueError('artifact ownership mismatch')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        check_directories(root)
        yield fd
        return
    fd = os.open(root / 'lifecycle.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('artifact root busy: another build, test or package owns it; retry after it finishes')
        if owner.exists():
            if owner.is_symlink() or json.loads(owner.read_text()) != expected:
                raise ValueError('artifact ownership mismatch')
        else:
            if set(p.name for p in root.iterdir()) != {'lifecycle.lock'}:
                raise ValueError('refusing to adopt a nonempty artifact directory')
            save(owner, expected)
        check_directories(root)
        yield fd
    finally:
        # Closing, not LOCK_UN: surviving children must keep the inherited lock.
        os.close(fd)


def check_directories(root):
    for name in ('tasks', 'development/dist', 'verification/dist', 'logs', 'release',
                 'baselines', 'swiftpm', 'parakeet-helper', 'runtime', 'notices'):
        path = safe_path(root / name)
        if path.exists() and not path.is_dir():
            raise ValueError(f'expected managed directory: {path}')


def environment(root, fd):
    env = dict(os.environ)
    env.update(HIREVA_ARTIFACT_ROOT=str(root), HIREVA_ARTIFACT_LOCK_FD=str(fd),
               HIREVA_APP_BUNDLE=str(app_path(root)), HIREVA_SWIFTPM_BUILD_PATH=str(root / 'swiftpm'),
               HIREVA_PARAKEET_RUNTIME_BUILD_DIR=str(root / 'parakeet-helper'),
               HIREVA_RUNTIME_CACHE_DIR=str(root / 'runtime'), HIREVA_NOTICE_CACHE_DIR=str(root / 'notices'))
    return env


def run(command, env, fd, log=None):
    with contextlib.ExitStack() as stack:
        output = stack.enter_context(open(log, 'wb')) if log else None
        owns_group = env.get('HIREVA_ARTIFACT_GROUP') != '1'
        child_env = dict(env, HIREVA_ARTIFACT_GROUP='1')
        child = subprocess.Popen(command, env=child_env, pass_fds=(fd,), start_new_session=owns_group,
                                 stdout=output, stderr=subprocess.STDOUT if output else None)
        try:
            status = child.wait()
            if status:
                raise subprocess.CalledProcessError(status, command)
        except BaseException:
            if child.poll() is None:
                if owns_group:
                    os.killpg(child.pid, signal.SIGTERM)
                else:
                    child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    if owns_group:
                        os.killpg(child.pid, signal.SIGKILL)
                    else:
                        child.kill()
                    child.wait()
            raise
        finally:
            if owns_group:
                # A shell may exit before its children. Reap the entire owned group.
                try:
                    for sig in (signal.SIGTERM, signal.SIGKILL):
                        if not group_active(child.pid):
                            break
                        try:
                            os.killpg(child.pid, sig)
                        except ProcessLookupError:
                            break
                        except PermissionError:
                            # Darwin can return EPERM when only zombies remain.
                            if group_active(child.pid):
                                raise
                            break
                        for _ in range(100):
                            if not group_active(child.pid):
                                break
                            time.sleep(.05)
                        else:
                            continue
                        break
                    else:
                        raise WritersStillRunning(child.pid)
                except (OSError, subprocess.CalledProcessError) as error:
                    raise WritersStillRunning(child.pid) from error


def recover_publication(task):
    journal = task / 'publication.json'
    if not journal.exists():
        return
    record = json.loads(journal.read_text())
    target = safe_path(record['next']['path'])
    root = task.parent.parent
    if target not in (root / 'development/dist/Hireva.app', root / 'verification/dist/Hireva.app'):
        raise ValueError('invalid publication recovery path')
    if active(target):
        raise ValueError('interrupted publication is in use; retained for review')
    previous = task / 'previous.app'
    receipt = target.parent / 'artifact.json'
    if target.exists() and receipt.exists() and json.loads(receipt.read_text()) == record['next']:
        if fingerprint(target) != record['next']['sha256']:
            raise ValueError('committed bundle changed; retained for review')
        # A killed cleanup may leave only part of the old, already superseded bundle.
        if previous.exists():
            shutil.rmtree(previous)
        return
    if previous.exists():
        if not record['previous'] or fingerprint(previous) != record['previous']['sha256']:
            raise ValueError('rollback bundle changed; retained for review')
        if target.exists():
            if fingerprint(target) != record['next']['sha256']:
                raise ValueError('published bundle changed; retained for review')
            target.rename(task / 'unpublished.app')
        previous.rename(target)
        save(receipt, record['previous'])
    elif target.exists():
        current = fingerprint(target)
        if current == record['next']['sha256']:
            save(receipt, record['next'])
        elif not record['previous'] or current != record['previous']['sha256']:
            raise ValueError('publication state cannot be recovered safely')


def recover(root):
    check_directories(root)
    tasks = root / 'tasks'
    tasks.mkdir(exist_ok=True)
    for task in tasks.iterdir():
        if task.is_symlink() or not task.is_dir():
            raise ValueError(f'unrecognized staging entry: {task}')
        marker = task / 'owner.json'
        if not marker.is_file() or json.loads(marker.read_text()).get('repository') != str(REPO):
            raise ValueError(f'unowned task retained: {task}')
        if in_use(task):
            raise ValueError(f'staging is still in use: {task}')
        writers = task / 'writers-pending.json'
        if writers.exists() and group_active(json.loads(writers.read_text())['pgid']):
            raise ValueError(f'task writers still active: {task}')
        if (task / 'retiring.app').exists():
            raise ValueError(f'unfinished historical retirement retained; inspect {task / "retirement.json"}')
        recover_publication(task)
        # SIGKILL between the two publish renames leaves the previous valid bundle here.
        rollback = task / 'previous.app'
        if rollback.exists():
            target = Path(json.loads(marker.read_text())['target'])
            if target not in (root / 'development/dist/Hireva.app', root / 'verification/dist/Hireva.app'):
                raise ValueError('invalid recovery target')
            if not target.exists():
                rollback.rename(target)
            else:
                receipt = target.parent / 'artifact.json'
                if not receipt.exists() or json.loads(receipt.read_text())['sha256'] != fingerprint(target):
                    raise ValueError(f'interrupted publish needs review; previous bundle retained at {rollback}')
        shutil.rmtree(task)


@contextlib.contextmanager
def task_directory(root, target):
    task = Path(tempfile.mkdtemp(prefix='task-', dir=root / 'tasks'))
    save(task / 'owner.json', {'repository': str(REPO), 'target': str(target), 'pid': os.getpid()})
    failed = False
    retain = False
    try:
        yield task
    except BaseException as error:
        failed = True
        if isinstance(error, WritersStillRunning):
            retain = True
            save(task / 'writers-pending.json', {'pgid': error.pgid})
        raise
    finally:
        # Nested failures are recovered by the outer lock owner after its group exits.
        if task.exists() and not retain and not (task / 'previous.app').exists() and not (task / 'retiring.app').exists() and not (failed and os.environ.get('HIREVA_ARTIFACT_GROUP') == '1'):
            shutil.rmtree(task)


def build(root, fd):
    target = app_path(root)
    if target.exists() and in_use(target):
        raise ValueError(f'current bundle is running; it was not stopped or replaced: {target}')
    target.parent.mkdir(parents=True, exist_ok=True)
    receipt = target.parent / 'artifact.json'
    if target.exists():
        safe_path(target)
        if not receipt.exists() or json.loads(receipt.read_text())['sha256'] != fingerprint(target):
            raise ValueError('existing bundle is unowned or changed; refusing to replace it')
    with task_directory(root, target) as task:
        source_hash = source_fingerprint()
        stage = task / 'dist'
        env = environment(root, fd)
        env.update(HIREVA_ARTIFACT_WORKER='1', HIREVA_BUNDLE_OUTPUT_DIR=str(stage),
                   HIREVA_EXPECTED_BUNDLE_PATH=str(target))
        logs = root / 'logs'
        logs.mkdir(exist_ok=True)
        log = logs / (task.name + '.log')
        print(f'[build] log: {log}', flush=True)
        run(['/bin/bash', str(REPO / 'script/build_and_run.sh'), '--build-only'], env, fd, log)
        candidate = stage / 'Hireva.app'
        if source_fingerprint() != source_hash:
            raise ValueError('source changed during build; previous artifact retained')
        result = {'sha256': fingerprint(candidate), 'source_head': subprocess.check_output(
            ['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip(),
            'source_status': subprocess.check_output(['git', '-C', str(REPO), 'status', '--porcelain=v1', '-uall'], text=True),
            'path': str(target), 'log': str(log), 'created_at': time.time(),
            'signing_mode': env.get('HIREVA_SIGNING_MODE', 'adhoc'), 'source_sha256': source_hash,
            'build_configuration': env.get('HIREVA_BUILD_CONFIGURATION', 'debug'),
            'architecture': env.get('HIREVA_BUILD_ARCHS', 'arm64'),
            'prebuilt_input': env.get('HIREVA_PREBUILT_BINARY')}
        if in_use(target):
            raise ValueError('bundle became active during build; previous version retained')
        previous = task / 'previous.app'
        previous_receipt = json.loads(receipt.read_text()) if receipt.exists() else None
        save(task / 'publication.json', {'previous': previous_receipt, 'next': result})
        if target.exists():
            target.rename(previous)
        try:
            candidate.rename(target)
            save(receipt, result)
        except BaseException:
            recover_publication(task)
            raise
        if previous.exists():
            shutil.rmtree(previous)
        save(log.with_suffix('.json'), result)
        print(f'[build] verified managed bundle: {target}', flush=True)


def launch(root, fd, mode):
    target = app_path(root)
    if os.environ.get('HIREVA_VERIFICATION_BUNDLE') == '1':
        raise ValueError('verification bundle must use its isolated supervisor')
    existing = {pid: exe for pid, exe in processes().items() if '/Hireva.app/Contents/MacOS/' in exe}
    if existing:
        if all(exe == str(target / 'Contents/MacOS/Hireva') for exe in existing.values()):
            print(f'[launch] already running from exact path: {existing}')
            return
        raise ValueError(f'another Hireva session is running; no app was stopped: {existing}')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(target)], check=True)
    command = ['/usr/bin/open', '-n']
    if os.environ.get('HIREVA_FIXED_USER_HOME'):
        command += ['--env', 'CFFIXED_USER_HOME=' + os.environ['HIREVA_FIXED_USER_HOME']]
    command.append(str(target))
    run(command, environment(root, fd), fd)
    for _ in range(20):
        running = active(target)
        if running:
            print(f'[launch] actual executable paths: {running}')
            return
        time.sleep(.5)
    raise ValueError('launch did not produce a process from the expected absolute path')


def package(root, fd, kind, arguments):
    build(root, fd)
    with task_directory(root, app_path(root)) as task:
        env = environment(root, fd)
        env['HIREVA_PACKAGE_WORK_DIR'] = str(task)
        script = 'package_local_release.sh' if kind == 'package-local' else 'package_dmg.sh'
        run(['/bin/bash', str(REPO / 'scripts' / script)] + arguments, env, fd)
        archives = list(task.glob('*.zip' if kind == 'package-local' else '*.dmg'))
        if len(archives) != 1:
            raise ValueError('package did not produce exactly one archive')
        archive = archives[0]
        release = root / 'release'
        release.mkdir(exist_ok=True)
        target = release / ('Hireva-local.zip' if kind == 'package-local' else archive.name)
        receipt = target.with_suffix(target.suffix + '.json')
        if target.exists() and (not receipt.exists() or json.loads(receipt.read_text())['sha256'] != digest(target)):
            raise ValueError('existing release archive is unowned or changed; refusing replacement')
        if kind == 'package-local':
            subprocess.run(['/usr/bin/unzip', '-tq', str(archive)], check=True)
        record = {'sha256': digest(archive), 'bundle_sha256': fingerprint(app_path(root)),
                  'source_bundle': str(app_path(root)), 'created_at': time.time(),
                  'retention': 'latest local package; explicitly archive a baseline before replacing'}
        os.replace(archive, target)
        save(receipt, record)
        print(f'[package] retained archive only: {target}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['paths', 'build', 'exec', 'check-worker', 'check-package', 'package-local', 'package-dmg'])
    parser.add_argument('args', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    root = root_path()
    if args.action == 'paths':
        print(app_path(root))
        return
    if args.action == 'build' and os.environ.get('HIREVA_BUNDLE_OUTPUT_DIR'):
        raise ValueError('--build-only requires an absolute managed destination; independent fresh or empty historical directories are no longer allowed. Unset HIREVA_BUNDLE_OUTPUT_DIR; use the fixed managed output and an explicit archive for baselines.')
    if args.action in ('check-worker', 'check-package') and not os.environ.get('HIREVA_ARTIFACT_LOCK_FD'):
        raise ValueError('internal worker requires an inherited artifact lock')
    with locked(root) as fd:
        if args.action in ('check-worker', 'check-package'):
            task = (safe_path(os.environ['HIREVA_BUNDLE_OUTPUT_DIR']).parent if args.action == 'check-worker'
                    else safe_path(os.environ['HIREVA_PACKAGE_WORK_DIR']))
            marker = task / 'owner.json'
            if task.parent != root / 'tasks' or not marker.is_file() or marker.is_symlink() or json.loads(marker.read_text()).get('repository') != str(REPO):
                raise ValueError('worker is not in an owned task directory')
            return
        if not os.environ.get('HIREVA_ARTIFACT_LOCK_FD'):
            recover(root)
        if args.action == 'exec':
            command = args.args[1:] if args.args[:1] == ['--'] else args.args
            try:
                run(command, environment(root, fd), fd)
            finally:
                if not os.environ.get('HIREVA_ARTIFACT_LOCK_FD'):
                    recover(root)
            return
        if args.action.startswith('package-'):
            package(root, fd, args.action, args.args)
            return
        mode = args.args[0] if args.args else '--build-only'
        if mode in ('--relaunch', 'relaunch'):
            launch(root, fd, mode)
        elif mode in ('--identity-check', 'identity-check'):
            run(['codesign', '--verify', '--deep', '--strict', str(app_path(root))], environment(root, fd), fd)
        elif mode in ('run', '--build-only', '--verify', 'verify', '--debug', 'debug',
                      '--logs', 'logs', '--telemetry', 'telemetry'):
            if mode != '--build-only' and any('/Hireva.app/Contents/MacOS/' in p for p in processes().values()):
                raise ValueError('a Hireva session is running; quit it explicitly before rebuilding and launching')
            build(root, fd)
            if mode in ('--debug', 'debug'):
                run(['lldb', '--', str(app_path(root) / 'Contents/MacOS/Hireva')], environment(root, fd), fd)
            elif mode != '--build-only':
                launch(root, fd, mode)
                if mode in ('--logs', 'logs', '--telemetry', 'telemetry'):
                    predicate = 'subsystem == "com.langcheng.Hireva"' if 'telemetry' in mode else 'process == "Hireva"'
                    run(['/usr/bin/log', 'stream', '--info', '--style', 'compact', '--predicate', predicate], environment(root, fd), fd)
        else:
            raise ValueError(f'{mode} is not a managed build mode; use --build-only, run, --relaunch or --identity-check')


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f'signal {signum}')
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, KeyboardInterrupt) as error:
        print(f'[artifacts] ERROR: {error}', file=sys.stderr)
        sys.exit(130 if isinstance(error, KeyboardInterrupt) else 2)

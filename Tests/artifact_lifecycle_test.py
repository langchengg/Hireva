#!/usr/bin/env python3
"""Isolated filesystem/process regression tests; never launch Hireva or use user data."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

REPO = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path[:0] = [str(REPO / 'script'), str(REPO / 'scripts')]
import artifact_lifecycle as life
import cleanup_hireva_artifacts as clean


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='hireva-lifecycle-test-')
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'managed'
        self.allowed = self.base / 'history'
        self.allowed.mkdir()
        self.trash = self.base / 'trash'
        self.trash.mkdir()
        self.env = patch.dict(os.environ, {'HIREVA_ARTIFACT_ROOT': str(self.root)}, clear=False)
        self.env.start()
        self.roots = patch.object(clean, 'ALLOWED_ROOTS', [self.allowed])
        self.roots.start()

    def tearDown(self):
        self.roots.stop()
        self.env.stop()
        self.temp.cleanup()

    def bundle(self, name, content=b'original'):
        app = self.allowed / name / 'Hireva.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(
            {'CFBundleIdentifier': life.BUNDLE_ID, 'CFBundleExecutable': 'Hireva'}))
        (app / 'Contents/MacOS/Hireva').write_bytes(content)
        return app

    def plan(self, source, keep):
        return {'protected': [str(keep)], 'allowlist': [{
            'path': str(source), 'keep': str(keep), 'identity': clean.identity(source),
            'sha256': life.fingerprint(source), 'logical_bytes': 123,
            'reason': 'owned test duplicate', 'reference_review': 'owned fixtures only'}]}

    def test_dry_run_move_idempotence_and_restore_no_overwrite(self):
        keep, source = self.bundle('keep'), self.bundle('copy')
        plan = self.plan(source, keep)
        self.assertEqual(clean.cleanup(plan)['results'][0]['status'], 'eligible')
        self.assertTrue(source.exists())
        result = clean.cleanup(plan, True, self.trash)['results'][0]
        self.assertEqual(result['status'], 'moved')
        self.assertFalse(source.exists())
        self.assertEqual(clean.cleanup(plan, True, self.trash)['results'][0]['status'], 'skipped')
        source.mkdir()
        (source / 'canary').write_text('do not overwrite')
        with self.assertRaisesRegex(ValueError, 'occupied'):
            clean.restore(Path(result['receipt']))
        self.assertEqual((source / 'canary').read_text(), 'do not overwrite')
        shutil.rmtree(source)
        clean.restore(Path(result['receipt']))
        self.assertEqual(life.fingerprint(source), life.fingerprint(keep))

    def test_protected_different_and_replaced_bundles_are_kept(self):
        keep, source = self.bundle('keep'), self.bundle('copy')
        plan = self.plan(source, keep)
        plan['protected'].append(str(source))
        self.assertEqual(clean.cleanup(plan, True, self.trash)['results'][0]['status'], 'skipped')
        plan['protected'].remove(str(source))
        (source / 'Contents/MacOS/Hireva').write_bytes(b'different')
        self.assertEqual(clean.cleanup(plan, True, self.trash)['results'][0]['status'], 'skipped')
        shutil.rmtree(source)
        self.bundle('copy')
        self.assertEqual(clean.cleanup(plan, True, self.trash)['results'][0]['status'], 'skipped')
        self.assertTrue(source.exists())

    def test_symlink_sync_and_user_data_are_rejected(self):
        keep, source = self.bundle('keep'), self.bundle('copy')
        plan = self.plan(source, keep)
        alias = self.allowed / 'escape'
        alias.symlink_to(keep.parent, target_is_directory=True)
        for path in [alias / 'Hireva.app', self.allowed / 'CloudStorage/provider/Hireva.app',
                     self.allowed / 'Library/Application Support/Hireva/Hireva.app']:
            entry = dict(plan['allowlist'][0], path=str(path))
            with self.assertRaises((ValueError, FileNotFoundError)):
                clean.validate(entry, plan['protected'])
        self.assertTrue(source.exists())

    def test_actual_running_executable_is_kept(self):
        keep, source = self.bundle('keep'), self.bundle('copy')
        for app in (keep, source):
            shutil.copyfile('/bin/sleep', app / 'Contents/MacOS/Hireva')
            (app / 'Contents/MacOS/Hireva').chmod(0o755)
        plan = self.plan(source, keep)
        child = subprocess.Popen([str(source / 'Contents/MacOS/Hireva'), '30'])
        try:
            self.assertTrue(life.active(source))
            self.assertEqual(clean.cleanup(plan, True, self.trash)['results'][0]['status'], 'skipped')
            self.assertTrue(source.exists())
        finally:
            child.terminate()
            child.wait()

    def test_build_failure_and_interrupt_preserve_previous(self):
        with life.locked(self.root) as fd:
            life.recover(self.root)
            target = life.app_path(self.root)
            target.parent.mkdir(parents=True)
            shutil.copytree(self.bundle('previous'), target)
            before = life.fingerprint(target)
            life.save(target.parent / 'artifact.json', {'sha256': before})
            for error in (subprocess.CalledProcessError(9, ['fixture']), KeyboardInterrupt()):
                with patch.object(life, 'run', side_effect=error):
                    with self.assertRaises(type(error)):
                        life.build(self.root, fd)
                self.assertEqual(life.fingerprint(target), before)
                self.assertEqual(list((self.root / 'tasks').iterdir()), [])

    def test_recovery_restores_interrupted_publish_and_refuses_unknown_tasks(self):
        with life.locked(self.root):
            life.recover(self.root)
            target = life.app_path(self.root)
            target.parent.mkdir(parents=True)
            task = self.root / 'tasks/task-crash'
            task.mkdir()
            life.save(task / 'owner.json', {'repository': str(life.REPO), 'target': str(target)})
            shutil.copytree(self.bundle('old'), task / 'previous.app')
            life.recover(self.root)
            self.assertTrue(target.exists())
            unknown = self.root / 'tasks/unknown'
            unknown.mkdir()
            with self.assertRaisesRegex(ValueError, 'unowned'):
                life.recover(self.root)
            self.assertTrue(unknown.exists())

    def test_real_lock_competition_and_signal_release(self):
        command = [sys.executable, str(REPO / 'script/artifact_lifecycle.py'), 'exec', '--',
                   '/bin/sh', '-c', 'echo ready; sleep 30']
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'ready')
            blocked = subprocess.run(command[:-3] + ['/usr/bin/true'], capture_output=True, text=True)
            self.assertEqual(blocked.returncode, 2)
            self.assertIn('busy', blocked.stderr)
            child.terminate()
            child.communicate(timeout=15)
            self.assertEqual(child.returncode, 130)
            with life.locked(self.root):
                pass
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()

    def test_archive_round_trip_and_refusal_to_overwrite(self):
        source = self.bundle('archive')
        binary = source / 'Contents/MacOS/Hireva'
        shutil.copyfile('/bin/sleep', binary)
        binary.chmod(0o755)
        subprocess.run(['codesign', '--force', '--sign', '-', str(source)], check=True,
                       capture_output=True)
        before = life.fingerprint(source)
        plan = self.plan(source, source)
        plan['protected'] = []
        del plan['allowlist'][0]['keep']
        with life.locked(self.root):
            life.recover(self.root)
            result = clean.archive_approved(plan, self.root, self.base / 'result.json')['results'][0]
            self.assertEqual(result['status'], 'archived', result)
            self.assertFalse(source.exists())
            receipt = Path(result['receipt'])
            source.mkdir()
            with self.assertRaisesRegex(ValueError, 'occupied'):
                clean.restore(receipt)
            source.rmdir()
            clean.restore(receipt)
            self.assertEqual(life.fingerprint(source), before)

    def test_uncertain_retirement_is_never_removed_by_finally_or_recovery(self):
        with life.locked(self.root):
            life.recover(self.root)
            with self.assertRaises(OSError):
                with life.task_directory(self.root, life.app_path(self.root)) as task:
                    (task / 'retiring.app').mkdir()
                    (task / 'retiring.app/unique').write_text('must survive')
                    raise OSError('simulated post-move read failure')
            self.assertEqual((task / 'retiring.app/unique').read_text(), 'must survive')
            with self.assertRaisesRegex(ValueError, 'retirement retained'):
                life.recover(self.root)
            self.assertTrue((task / 'retiring.app/unique').exists())

    def test_staging_symlink_and_walk_errors_fail_closed(self):
        with life.locked(self.root):
            pass
        (self.root / 'tasks').symlink_to(self.allowed, target_is_directory=True)
        with self.assertRaises(ValueError):
            with life.locked(self.root):
                pass
        def denied(*args, **kwargs):
            kwargs['onerror'](PermissionError('synthetic unreadable resource'))
        with patch.object(life.os, 'walk', side_effect=denied):
            with self.assertRaises(PermissionError):
                life.manifest(self.bundle('unreadable'))

    def test_receipt_failure_rolls_back_the_previous_bundle(self):
        with life.locked(self.root) as fd:
            life.recover(self.root)
            target = life.app_path(self.root)
            target.parent.mkdir(parents=True)
            shutil.copytree(self.bundle('previous'), target)
            before = life.fingerprint(target)
            life.save(target.parent / 'artifact.json', {'sha256': before})
            original_save = life.save
            failed = False
            def fail_once(path, value):
                nonlocal failed
                if path == target.parent / 'artifact.json' and not failed:
                    failed = True
                    raise OSError('synthetic receipt write failure')
                original_save(path, value)
            def assemble(command, env, fd, log):
                candidate = Path(env['HIREVA_BUNDLE_OUTPUT_DIR']) / 'Hireva.app'
                candidate.parent.mkdir()
                shutil.copytree(self.bundle('next', b'next'), candidate)
            with patch.object(life, 'run', side_effect=assemble), patch.object(life, 'save', side_effect=fail_once):
                with self.assertRaisesRegex(OSError, 'receipt write failure'):
                    life.build(self.root, fd)
            self.assertEqual(life.fingerprint(target), before)
            self.assertEqual(json.loads((target.parent / 'artifact.json').read_text())['sha256'], before)

    def test_committed_publish_recovers_a_partially_deleted_previous_bundle(self):
        with life.locked(self.root):
            life.recover(self.root)
            target = life.app_path(self.root)
            target.parent.mkdir(parents=True)
            shutil.copytree(self.bundle('next'), target)
            next_receipt = {'sha256': life.fingerprint(target), 'path': str(target)}
            life.save(target.parent / 'artifact.json', next_receipt)
            task = self.root / 'tasks/task-committed'
            (task / 'previous.app').mkdir(parents=True)
            life.save(task / 'owner.json', {'repository': str(life.REPO), 'target': str(target)})
            life.save(task / 'publication.json', {'previous': {'sha256': 'now-partial'}, 'next': next_receipt})
            life.recover(self.root)
            self.assertFalse(task.exists())
            self.assertEqual(life.fingerprint(target), next_receipt['sha256'])

    def test_unconfirmed_writers_block_cleanup_until_their_group_exits(self):
        with life.locked(self.root):
            life.recover(self.root)
            with self.assertRaises(life.WritersStillRunning):
                with life.task_directory(self.root, life.app_path(self.root)) as task:
                    (task / 'canary').write_text('writer output')
                    raise life.WritersStillRunning(123456)
            with patch.object(life, 'group_active', return_value=True):
                with self.assertRaisesRegex(ValueError, 'writers still active'):
                    life.recover(self.root)
            self.assertTrue((task / 'canary').exists())
            with patch.object(life, 'group_active', return_value=False):
                life.recover(self.root)
            self.assertFalse(task.exists())

    def test_completed_command_does_not_signal_an_inactive_group(self):
        child = Mock(pid=123456)
        child.wait.return_value = 0
        with patch.object(life.subprocess, 'Popen', return_value=child), \
             patch.object(life, 'group_active', return_value=False), \
             patch.object(life.os, 'killpg', side_effect=PermissionError(1, 'no signalable members')) as kill:
            life.run(['synthetic'], {}, 0)
        kill.assert_not_called()

    def test_group_exiting_during_signal_is_rechecked_without_hiding_live_writers(self):
        for still_active in (False, True):
            with self.subTest(still_active=still_active):
                child = Mock(pid=123456)
                child.wait.return_value = 0
                with patch.object(life.subprocess, 'Popen', return_value=child), \
                     patch.object(life, 'group_active', side_effect=[True, still_active]), \
                     patch.object(life.os, 'killpg', side_effect=PermissionError(1, 'synthetic signal denial')):
                    if still_active:
                        with self.assertRaises(life.WritersStillRunning):
                            life.run(['synthetic'], {}, 0)
                    else:
                        life.run(['synthetic'], {}, 0)

    def test_group_inspection_failure_retains_staging_for_recovery(self):
        child = Mock(pid=123456)
        child.wait.return_value = 0
        with life.locked(self.root):
            life.recover(self.root)
            with patch.object(life.subprocess, 'Popen', return_value=child), \
                 patch.object(life, 'group_active', side_effect=subprocess.CalledProcessError(1, ['ps'])), \
                 patch.object(life.os, 'killpg', side_effect=ProcessLookupError):
                with self.assertRaises(life.WritersStillRunning):
                    with life.task_directory(self.root, life.app_path(self.root)) as task:
                        (task / 'canary').write_text('unconfirmed writer output')
                        life.run(['synthetic'], {}, 0)
            self.assertTrue((task / 'canary').exists())
            self.assertEqual(json.loads((task / 'writers-pending.json').read_text())['pgid'], child.pid)


if __name__ == '__main__':
    unittest.main()

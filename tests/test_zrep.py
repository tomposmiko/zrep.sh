"""Run with python3 -m unittest discover -s tests -v. No ZFS/SSH needed."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ZrepTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls'
        self.config = self.root / 'zrep.conf'
        self.config.write_text('host:vm:incus-kvm\n')
        # Isolate the scripts and replace only their production PATH assignment.
        for source in ROOT.glob('*.sh'):
            text = source.read_text()
            text = '\n'.join('PATH="$MOCK_PATH"' if line.startswith(('PATH=', 'export PATH=')) else line for line in text.splitlines()) + '\n'
            (self.root / source.name).write_text(text)
            (self.root / source.name).chmod(0o755)
        mock = self.bin / 'mock'
        mock.write_text('''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
with open(os.environ['CALL_LOG'], 'a') as stream:
    stream.write(json.dumps([name, *sys.argv[1:]]) + '\\n')
if name == os.environ.get('FAIL_COMMAND'):
    sys.exit(1)
if name == 'zfs':
    if 'snapshot' in sys.argv and os.environ.get('FAIL_SNAPSHOT_LIST'):
        sys.exit(1)
    if 'snapshot' in sys.argv:
        print(os.environ.get('SNAPSHOTS', ''), end='')
    elif sys.argv[1] == 'get':
        print('filesystem')
    elif sys.argv[1] == 'list':
        print(os.environ.get('DATASETS', 'tank/zrep/vm'))
''')
        mock.chmod(0o755)
        for name in ('zfs', 'ssh', 'syncoid'):
            (self.bin / name).symlink_to(mock)
        self.env = {**os.environ, 'MOCK_PATH': f'{self.bin}:/usr/bin:/bin', 'PATH': f'{self.bin}:/usr/bin:/bin', 'CALL_LOG': str(self.log)}

    def run_script(self, script='zrep.sh', args=None, **env):
        return subprocess.run([str(self.root / script), *(args if args is not None else ['-c', str(self.config), '-s', 'vm'])], env={**self.env, **env}, text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_vm_layout_for_both_platforms(self):
        for platform in ('incus', 'lxd'):
            with self.subTest(platform=platform):
                self.config.write_text(f'host:vm:{platform}-kvm\n')
                result = self.run_script()
                self.assertEqual(result.returncode, 0, result.stderr)
                transfers = [c for c in self.calls() if c[0] == 'syncoid'][-2:]
                self.assertEqual(transfers[0][-2:], [f'syncoid-backup@host:tank/{platform}/virtual-machines/vm', 'tank/zrep/vm/vm'])
                self.assertEqual(transfers[1][-1], 'tank/zrep/vm/vm.block')

    def test_symlink_chain_from_another_working_directory(self):
        links = self.root / 'installed'
        links.mkdir()
        (links / 'job').symlink_to('../zrep.sh')
        entry = links / 'zrep.sh'
        entry.symlink_to('job')
        result = subprocess.run(
            [str(entry), '-c', str(self.config), '-s', 'vm'],
            cwd=links, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len([c for c in self.calls() if c[0] == 'syncoid']), 2)

    def test_symlinked_batch_finds_real_child_script(self):
        entry = self.bin / 'zrep-all.sh'
        entry.symlink_to('../zrep-all.sh')
        result = self.run_script(str(entry), ['-c', str(self.config)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len([c for c in self.calls() if c[0] == 'syncoid']), 2)

    def test_missing_helpers_stop_before_any_external_commands(self):
        for helper in ('_zrep_common.sh', '_common.sh'):
            for script in ('zrep.sh', 'zrep-all.sh'):
                with self.subTest(helper=helper, script=script):
                    path = self.root / helper
                    saved = path.read_text()
                    path.unlink()
                    try:
                        result = self.run_script(script, ['-c', str(self.config), '-s', 'vm'] if script == 'zrep.sh' else ['-c', str(self.config)])
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(helper, result.stderr)
                        self.assertNotIn('command not found', result.stderr)
                        self.assertEqual(self.calls(), [])
                    finally:
                        path.write_text(saved)

    def test_snapshot_failure_stops_transfer(self):
        self.assertNotEqual(self.run_script(FAIL_COMMAND='ssh').returncode, 0)
        self.assertFalse(any(c[0] == 'syncoid' for c in self.calls()))

    def test_exact_matching_and_comments(self):
        self.config.write_text(' # host:vm:incus-ct\nhost:vm:incus-ct\nhost:vm2:incus-ct\n')
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(len([c for c in self.calls() if c[0] == 'ssh']), 1)

    def test_invalid_inputs_have_no_side_effects(self):
        for config, args in [('host:vm:incus-ct\nhost2:vm:incus-ct', []), ('host:vm:incus-ct:external', []), ('host:vm:incus-ct', ['-f', 'daily-evil']), ('host:vm:incus-ct', ['--bwlimit'])]:
            with self.subTest(config=config, args=args):
                self.config.write_text(config)
                result = self.run_script(args=['-c', str(self.config), '-s', 'vm', *args])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_extended_list_does_not_create_datasets(self):
        result = self.run_script(args=['-c', str(self.config), '-l', 'vm', '-E'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[0] in ('ssh', 'syncoid') or 'create' in c for c in self.calls()))

    def test_batch_continues_and_returns_failure(self):
        self.config.write_text('host:vm:incus-ct\nhost:vm2:incus-ct\n')
        result = self.run_script('zrep-all.sh', ['-c', str(self.config)], FAIL_COMMAND='ssh')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len([c for c in self.calls() if c[0] == 'ssh']), 2)
        self.assertFalse(any(c[0] == 'syncoid' for c in self.calls()))

    def test_gc_dry_run_literal_filter_and_date(self):
        snapshots = 'tank/zrep/vm@a.b\t1000\ntank/zrep/vm@axb\t2000\ntank/zrep/vm@a.b-new\t3000\n'
        result = self.run_script('zrep-gc.sh', ['-s', 'a.b', 'tank/zrep/vm', '1'], SNAPSHOTS=snapshots)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Would delete 'a.b'", result.stdout)
        self.assertNotIn("Would delete 'axb'", result.stdout)
        result = self.run_script('zrep-gc.sh', ['tank/zrep/vm', '1970-01-02'], SNAPSHOTS=snapshots)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count('Would delete'), 3)
        self.assertFalse(any('destroy' in c for c in self.calls()))

    def test_gc_listing_failure_is_error(self):
        result = self.run_script('zrep-gc.sh', ['tank/zrep/vm', '1'], FAIL_COMMAND='zfs')
        self.assertNotEqual(result.returncode, 0)

    def test_gc_snapshot_listing_failure_is_error(self):
        result = self.run_script('zrep-gc.sh', ['-f', 'tank/zrep/vm', '1'], FAIL_SNAPSHOT_LIST='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('destroy' in c for c in self.calls()))

    def test_gc_force_deletes_only_selected_snapshot(self):
        snapshots = 'tank/zrep/vm@old\t1000\ntank/zrep/vm@new\t2000\ntank/zrep/vm-child@unrelated\t500\n'
        result = self.run_script('zrep-gc.sh', ['-f', 'tank/zrep/vm', '1'], SNAPSHOTS=snapshots)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c for c in self.calls() if 'destroy' in c], [['zfs', 'destroy', 'tank/zrep/vm@old']])

    def test_check_noop_ignores_vm_wrapper(self):
        result = self.run_script('zrep-check.sh', ['--noop', '-d', '1'], DATASETS='tank/zrep\ntank/zrep/vm\ntank/zrep/vm/vm\ntank/zrep/vm/vm.block')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('*tank/zrep/vm*', result.stdout)
        self.assertIn('*tank/zrep/vm/vm.block*', result.stdout)


if __name__ == '__main__':
    unittest.main()

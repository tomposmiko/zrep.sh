"""Run with python3 -m unittest discover -s tests -v. No ZFS/SSH needed."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
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
if name == 'ssh' and os.environ.get('FAIL_CREATE') and ('create' in sys.argv or 'lxc' in sys.argv):
    print('Error: This "Instance_snapshot" entry already exists', file=sys.stderr)
    sys.exit(1)
if name == 'ssh' and 'get' in sys.argv:
    mode = os.environ.get('REMOTE_SNAPSHOT_MODE', '')
    if mode == 'query-fails':
        sys.exit(1)
    if mode:
        calls = [json.loads(line) for line in Path(os.environ['CALL_LOG']).read_text().splitlines()]
        created = next(call[-1] for call in reversed(calls) if call[0] == 'ssh' and ('create' in call or 'lxc' in call))
        dataset = sys.argv[-1]
        if mode == 'missing-block' and dataset.endswith('.block'):
            sys.exit(0)
        if mode == 'wrong-name':
            created += '-other'
        if mode == 'wrong-dataset':
            dataset += '-other'
        guid = 'invalid' if mode == 'invalid-guid' else '12345'
        print(f'{dataset}@snapshot-{created}\\tguid\\t{guid}\\t-')
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
                self.assertTrue(all('--no-clone-handling' in call for call in transfers))

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

    def test_zsr_help_and_missing_arguments_never_query_zfs(self):
        for args, code in [(['--help'], 0), (['-h'], 0), ([], 1)]:
            with self.subTest(args=args):
                result = self.run_script('zsr.sh', args)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertIn('Usage:', result.stdout + result.stderr)
                self.assertEqual(self.calls(), [])

    def test_zsr_invalid_arguments_never_query_zfs(self):
        for args in [ [''], ['.*'], ['.'], ['-f', 'zas'], ['--dataset'],
                      ['--dataset', 'tank', 'zas'], ['--dataset', 'tank/zrep/../other', 'zas'],
                      ['--dataset', 'tank/zrep-victim', 'zas'], ['zas', '--max-delete', '0'],
                      ['zas', '--max-delete', '-1'], ['zas', '--max-delete', '1000001'],
                      ['zas', '--delete'], ['zas', '--confirm', 'tank/zrep'],
                      ['zas', '--delete', '--confirm', 'tank/zrep'],
                      ['zas', '--delete', '--dataset', 'tank/zrep/ct', '--confirm', 'tank/zrep'] ]:
            with self.subTest(args=args):
                result = self.run_script('zsr.sh', args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_zsr_preview_matches_snapshot_names_literally(self):
        inventory = 'tank/zrep/vm@old.name\ntank/zrep/vm@oldXname\ntank/zrep/old.name@unrelated\n'
        result = self.run_script('zsr.sh', ['old.name'], SNAPSHOTS=inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('  tank/zrep/vm@old.name\n', result.stdout)
        self.assertNotIn('oldXname', result.stdout)
        self.assertNotIn('unrelated', result.stdout)
        self.assertIn('DRY RUN', result.stdout)
        self.assertFalse(any('destroy' in c for c in self.calls()))

    def test_zsr_delete_deduplicates_and_never_uses_recursive_flags(self):
        inventory = 'tank/zrep/vm@old.name\ntank/zrep/vm@old.name\ntank/zrep/vm/disk@old.disk\ntank/zrep/vm@new.name\n'
        result = self.run_script('zsr.sh', ['--dataset', 'tank/zrep/vm', '--delete', '--confirm', 'tank/zrep/vm', 'old.', 'name'], SNAPSHOTS=inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c for c in self.calls() if 'destroy' in c], [
            ['zfs', 'destroy', 'tank/zrep/vm@old.name'],
            ['zfs', 'destroy', 'tank/zrep/vm/disk@old.disk'],
            ['zfs', 'destroy', 'tank/zrep/vm@new.name']])

    def test_zsr_rejects_bad_inventory_before_any_deletion(self):
        for bad in ('tank/zrep/vm', 'tank/zrep/vm-other@old.name',
                    'tank/zrep/vm@old.name%new.name', 'tank/zrep/vm@old.name,new.name',
                    'tank/zrep/vm@old.name;id', 'tank/zrep/vm/../secret@old.name'):
            with self.subTest(bad=bad):
                result = self.run_script('zsr.sh', ['--dataset', 'tank/zrep/vm', '--delete', '--confirm', 'tank/zrep/vm', 'old'], SNAPSHOTS='tank/zrep/vm@old.name\n' + bad + '\n')
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any('destroy' in c for c in self.calls()))

    def test_zsr_caps_whole_plan_before_deletion(self):
        result = self.run_script('zsr.sh', ['--dataset', 'tank/zrep', '--delete', '--confirm', 'tank/zrep', '--max-delete', '1', 'old'], SNAPSHOTS='tank/zrep/vm@old.one\ntank/zrep/vm@old.two\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exceeds', result.stderr)
        self.assertFalse(any('destroy' in c for c in self.calls()))

    def test_zsr_default_cap_and_explicit_override(self):
        inventory = ''.join(f'tank/zrep/vm@old.{i}\n' for i in range(101))
        result = self.run_script('zsr.sh', ['--dataset', 'tank/zrep', '--delete', '--confirm', 'tank/zrep', 'old'], SNAPSHOTS=inventory)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('destroy' in c for c in self.calls()))
        result = self.run_script('zsr.sh', ['--max-delete', '101', 'old'], SNAPSHOTS=inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Selected snapshots: 101', result.stdout)
        self.assertFalse(any('destroy' in c for c in self.calls()))

    def test_zsr_listing_failure_and_empty_inventory_never_delete(self):
        result = self.run_script('zsr.sh', ['old'], FAIL_COMMAND='zfs')
        self.assertNotEqual(result.returncode, 0)
        result = self.run_script('zsr.sh', ['--dataset', 'tank/zrep', '--delete', '--confirm', 'tank/zrep', 'old'], SNAPSHOTS='')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('No matching snapshots', result.stdout)
        self.assertFalse(any('destroy' in c for c in self.calls()))

    def test_zsr_stops_on_failed_destroy(self):
        # Override the mock so a list succeeds and only destroy fails.
        mock = self.bin / 'mock'
        mock.write_text(mock.read_text().replace("if name == os.environ.get('FAIL_COMMAND'):", "if name == 'zfs' and sys.argv[1] == 'destroy':"))
        result = self.run_script('zsr.sh', ['--dataset', 'tank/zrep', '--delete', '--confirm', 'tank/zrep', 'old'], SNAPSHOTS='tank/zrep/vm@old.one\ntank/zrep/vm@old.two\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([c for c in self.calls() if 'destroy' in c], [['zfs', 'destroy', 'tank/zrep/vm@old.one']])

    def test_zsr_without_pattern_applies_retention_to_all_series(self):
        inventory = ('tank/zrep/vm@zas-daily-old\t1000\n'
                     'tank/zrep/vm@syncoid_helper\t2000\n'
                     'tank/zrep/vm@manual-new\t3000\n')
        result = self.run_script('zsr.sh', ['-d', 'tank/zrep/vm', '--before', '2024-08-01', '--keep-at-least', '1'], SNAPSHOTS=inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('  tank/zrep/vm@zas-daily-old\n', result.stdout)
        self.assertIn('  tank/zrep/vm@syncoid_helper\n', result.stdout)
        self.assertNotIn('manual-new', result.stdout)
        self.assertFalse(any('destroy' in c for c in self.calls()))

    def test_zsr_patternless_age_and_count_policies(self):
        for args in (['--older-than', '7d'], ['--keep-at-least', '1']):
            with self.subTest(args=args):
                inventory = 'tank/zrep/vm@old.one\t1000\ntank/zrep/vm@old.two\t2000\n'
                result = self.run_script('zsr.sh', args, SNAPSHOTS=inventory)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('  tank/zrep/vm@old.one\n', result.stdout)

    def test_zsr_patternless_delete_retains_minimum_per_dataset(self):
        inventory = ''.join(f'tank/zrep/{guest}@snapshot{i}\t{i*1000}\n' for guest in ('vm', 'other') for i in (1, 2))
        result = self.run_script('zsr.sh', ['--dataset', 'tank/zrep', '--delete', '--confirm', 'tank/zrep', '--keep-at-least', '1'], SNAPSHOTS=inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(c[-1] for c in self.calls() if 'destroy' in c), ['tank/zrep/other@snapshot1', 'tank/zrep/vm@snapshot1'])

    def test_zsr_no_pattern_and_no_policy_never_queries_zfs(self):
        for args in ([], ['--dataset', 'tank/zrep/vm'], ['--dataset', 'tank/zrep', '--delete', '--confirm', 'tank/zrep'], ['--max-delete', '100']):
            with self.subTest(args=args):
                result = self.run_script('zsr.sh', args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_zsr_absolute_cutoff_is_exclusive_and_uses_creation_time(self):
        inventory = ('tank/zrep/vm@old.label\t1727740799\n'
                     'tank/zrep/vm@old.boundary\t1727740800\n'
                     'tank/zrep/vm@old.newer\t1727740801\n')
        result = self.run_script('zsr.sh', ['--before', '2024-10-01T00:00:00Z', 'old'], SNAPSHOTS=inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('  tank/zrep/vm@old.label\n', result.stdout)
        self.assertNotIn('old.boundary', result.stdout)
        self.assertNotIn('old.newer', result.stdout)
        self.assertFalse(any('destroy' in c for c in self.calls()))

    def test_zsr_before_timezone_offsets_and_local_midnight(self):
        inventory = 'tank/zrep/vm@old.before\t1727740799\ntank/zrep/vm@old.boundary\t1727740800\n'
        for cutoff in ('2024-10-01', '2024-10-01 00:00', '2024-10-01 02:00:00+02:00'):
            with self.subTest(cutoff=cutoff):
                result = self.run_script('zsr.sh', ['--before', cutoff, 'old'], SNAPSHOTS=inventory, TZ='UTC')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('  tank/zrep/vm@old.before\n', result.stdout)
                self.assertNotIn('old.boundary', result.stdout)

    def test_zsr_age_units_and_exact_boundary(self):
        date = self.bin / 'date'
        date.write_text('#!/bin/bash\nif [[ $# == 1 && $1 == +%s ]]; then echo 1000000000; else exec /usr/bin/date "$@"; fi\n')
        date.chmod(0o755)
        for unit, seconds in [('s', 1), ('m', 60), ('h', 3600), ('d', 86400), ('w', 604800)]:
            with self.subTest(unit=unit):
                cutoff = 1000000000-seconds
                inventory = (f'tank/zrep/vm@old.before\t{cutoff-1}\n'
                             f'tank/zrep/vm@old.boundary\t{cutoff}\n'
                             f'tank/zrep/vm@old.after\t{cutoff+1}\n')
                result = self.run_script('zsr.sh', ['--older-than', '1'+unit, 'old'], SNAPSHOTS=inventory)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('  tank/zrep/vm@old.before\n', result.stdout)
                self.assertNotIn('old.boundary', result.stdout)
                self.assertNotIn('old.after', result.stdout)

    def test_zsr_relative_age_and_minimum_apply_per_dataset(self):
        now = int(time.time())
        inventory = ''.join(f'tank/zrep/{guest}@old.{i}\t{now-days*86400}\n'
                            for guest in ('vm', 'other')
                            for i, days in ((1, 30), (2, 20), (3, 10), (4, 1)))
        result = self.run_script('zsr.sh', ['--older-than', '7d', '--keep-at-least', '2', 'old'], SNAPSHOTS=inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        for guest in ('vm', 'other'):
            self.assertIn(f'  tank/zrep/{guest}@old.1\n', result.stdout)
            self.assertIn(f'  tank/zrep/{guest}@old.2\n', result.stdout)
            self.assertNotIn(f'@old.3', result.stdout)
            self.assertNotIn(f'@old.4', result.stdout)
        self.assertIn('Selected snapshots: 4', result.stdout)

    def test_zsr_minimum_counts_only_matching_series(self):
        inventory = ('tank/zrep/vm@old.one\t1000\n'
                     'tank/zrep/vm@old.two\t2000\n'
                     'tank/zrep/vm@unrelated.newer\t3000\n')
        result = self.run_script('zsr.sh', ['--keep-at-least', '2', 'old'], SNAPSHOTS=inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Selected snapshots: 0', result.stdout)
        # This remains true if a dataset has fewer matches than the minimum.
        result = self.run_script('zsr.sh', ['--keep-at-least', '5', 'old'], SNAPSHOTS=inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Selected snapshots: 0', result.stdout)

    def test_zsr_combined_cutoffs_choose_more_protective_date(self):
        now = int(time.time())
        cutoff = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now - 14*86400))
        inventory = f'tank/zrep/vm@old.one\t{now-20*86400}\ntank/zrep/vm@old.two\t{now-10*86400}\n'
        result = self.run_script('zsr.sh', ['--before', cutoff, '--older-than', '7d', 'old'], SNAPSHOTS=inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('  tank/zrep/vm@old.one\n', result.stdout)
        self.assertNotIn('old.two', result.stdout)
        newer = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now - 86400))
        result = self.run_script('zsr.sh', ['--before', newer, '--older-than', '14d', 'old'], SNAPSHOTS=inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('  tank/zrep/vm@old.one\n', result.stdout)
        self.assertNotIn('old.two', result.stdout)

    def test_zsr_retention_invalid_input_never_queries_zfs(self):
        for option, value in [('--before', 'yesterday'), ('--before', '2024-02-30'),
                              ('--before', '2099-01-01'), ('--before', '2024-01-01 25:00'),
                              ('--older-than', '0d'), ('--older-than', '-7d'),
                              ('--older-than', '7months'), ('--older-than', '1d;id'),
                              ('--keep-at-least', '-1'), ('--keep-at-least', '1.5')]:
            with self.subTest(option=option, value=value):
                result = self.run_script('zsr.sh', [option, value, 'old'])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_zsr_bad_creation_metadata_aborts_whole_plan(self):
        for row in ('tank/zrep/vm@old.two', 'tank/zrep/vm@old.two\tinvalid',
                    'tank/zrep/vm@old.two\t-1', 'tank/zrep/vm@old.two\t999999999999',
                    'tank/zrep/vm@old.one\t2000', 'tank/zrep/vm@old.two\t2000\textra'):
            with self.subTest(row=row):
                result = self.run_script('zsr.sh', ['--dataset', 'tank/zrep', '--delete', '--confirm', 'tank/zrep', '--older-than', '7d', 'old'], SNAPSHOTS='tank/zrep/vm@old.one\t1000\n'+row+'\n')
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any('destroy' in c for c in self.calls()))

    def test_zsr_retention_deletes_only_eligible_snapshots(self):
        result = self.run_script('zsr.sh', ['--dataset', 'tank/zrep', '--delete', '--confirm', 'tank/zrep', '--before', '2024-10-01', '--keep-at-least', '1', 'old'], SNAPSHOTS='tank/zrep/vm@old.one\t1000\ntank/zrep/vm@old.two\t2000\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c for c in self.calls() if 'destroy' in c], [['zfs', 'destroy', 'tank/zrep/vm@old.one']])

    def test_container_disables_traversal_to_image_origins(self):
        self.config.write_text('host:vm:incus-ct\n')
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        transfer = next(c for c in self.calls() if c[0] == 'syncoid')
        self.assertIn('--no-clone-handling', transfer)

    def test_snapshot_failure_stops_transfer(self):
        self.assertNotEqual(self.run_script(FAIL_COMMAND='ssh').returncode, 0)
        self.assertFalse(any(c[0] == 'syncoid' for c in self.calls()))

    def test_existing_hourly_snapshot_allows_replication(self):
        for kind in ('incus-ct', 'lxd-ct', 'incus-kvm', 'lxd-kvm'):
            with self.subTest(kind=kind):
                self.log.unlink(missing_ok=True)
                self.config.write_text(f'host:vm:{kind}\n')
                result = self.run_script(FAIL_CREATE='1', REMOTE_SNAPSHOT_MODE='exists')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('verified existing', result.stderr)
                calls = self.calls()
                queries = [call for call in calls if call[0] == 'ssh' and 'get' in call]
                transfers = [call for call in calls if call[0] == 'syncoid']
                self.assertEqual(len(queries), 2 if kind.endswith('kvm') else 1)
                self.assertEqual(len(transfers), len(queries))
                self.assertLess(max(calls.index(call) for call in queries), min(calls.index(call) for call in transfers))
                for query in queries:
                    self.assertEqual(query[4:-1], ['sudo', 'zfs', 'get', '-Hpd', '1', '-t', 'snapshot', 'guid,creation'])

    def test_unverified_existing_snapshot_stops_replication(self):
        for kind in ('incus-ct', 'incus-kvm'):
            for mode in ('', 'query-fails', 'wrong-name', 'wrong-dataset', 'invalid-guid', 'missing-block'):
                if kind.endswith('ct') and mode == 'missing-block':
                    continue
                with self.subTest(kind=kind, mode=mode):
                    self.log.unlink(missing_ok=True)
                    self.config.write_text(f'host:vm:{kind}\n')
                    result = self.run_script(FAIL_CREATE='1', REMOTE_SNAPSHOT_MODE=mode)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('existing snapshot could not be verified', result.stdout + result.stderr)
                    self.assertFalse(any(call[0] == 'syncoid' for call in self.calls()))

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
        self.assertEqual(len([c for c in self.calls() if c[0] == 'ssh' and 'create' in c]), 2)
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

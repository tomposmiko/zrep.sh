"""Exercise the Bash installer with isolated files and mocked host commands."""
import hashlib
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'client/source-install/install.sh'


class SourceInstallTest(unittest.TestCase):
    def shell(self, code):
        return subprocess.run(['bash', '-c', f'source {shlex.quote(str(INSTALLER))}\n' + code],
                              capture_output=True, text=True)

    def test_key_options_and_multiple_keys_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / 'key'
            for text, valid in (('ssh-ed25519 AAAATEST backup11\n', True),
                                ('', False), ('command="id" ssh-ed25519 AAAATEST\n', False),
                                ('ssh-ed25519 AAAATEST\nssh-ed25519 AAAATEST\n', False),
                                ('ssh-ed25519 $(id)\n', False)):
                key.write_text(text)
                result = self.shell('key_line ' + shlex.quote(str(key)))
                self.assertEqual(result.returncode == 0, valid, result.stderr)
                if valid:
                    self.assertTrue(result.stdout.startswith('restrict,command='))

    def test_extra_sudo_grants_fail_closed(self):
        prefix = 'User syncoid-backup may run the following commands on v201:\n'
        grant = '    (root) NOPASSWD: NOSETENV: /usr/local/sbin/pts-zrep-source *\n'
        for text, valid in ((prefix + grant, True), (prefix, False),
                            (prefix + grant + '    (ALL) ALL\n', False),
                            (prefix + grant.replace('(root)', '(ALL)'), False),
                            ('unrecognized output', False)):
            result = self.shell('verify_sudo <<\'POLICY\'\n' + text + '\nPOLICY\n')
            self.assertEqual(result.returncode == 0, valid, result.stderr)

    def test_effective_ssh_conflict_rejected(self):
        accepted = self.shell('printf "%s\\n" "${SSH_OPTIONS[@]}" | verify_ssh')
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        rejected = self.shell('printf "%s\\n" "${SSH_OPTIONS[@]}" | sed "s/permittty no/permittty yes/" | verify_ssh')
        self.assertNotEqual(rejected.returncode, 0)

    def test_untrusted_and_symlink_paths_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'policy'
            self.assertNotEqual(self.shell('trusted_path ' + shlex.quote(str(path))).returncode, 0)
            path.symlink_to('/etc/passwd')
            self.assertNotEqual(self.shell('trusted_path ' + shlex.quote(str(path))).returncode, 0)

    def exercise_install(self, apply=True, fail=''):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            copied = root / 'install.sh'
            # Only redirect the backup location. All managed policy paths below
            # are replaced after sourcing; production has no alternate-root flag.
            copied.write_text(INSTALLER.read_text().replace('/root/zrep-source-backup-', str(root / 'backup-')))
            for name in ('pts-zrep-source', 'pts-zrep-ssh'):
                (root / name).write_text('# bundled gateway\n')
            (root / 'key.pub').write_text('ssh-ed25519 AAAATEST backup11\n')
            (root / 'ssh_config').write_text('Port 22\n# original\n')
            (root / 'ssh_config').chmod(0o640)
            # Use nested paths to cover rollback of directories created by install.
            variables = {'GATEWAY': 'bin/gateway', 'LAUNCHER': 'bin/launcher',
                         'KEYS': 'auths/key', 'SSH_POLICY': 'ssh_policy',
                         'SSH_CONFIG': 'ssh_config', 'SUDO_POLICY': 'sudo_policy'}
            assignments = '\n'.join(f'{name}={shlex.quote(str(root / path))}' for name, path in variables.items())
            harness = f'''source {shlex.quote(str(copied))}
{assignments}
CALLS={shlex.quote(str(root / 'calls'))}
FAIL_CASE={shlex.quote(fail)}
SSH_OPTIONS=("forcecommand $LAUNCHER" 'permittty no')
platform_checks() {{ :; }}
trusted_path() {{ :; }}
getent() {{
    case "$1:${{2-}}" in
        passwd:*) printf 'syncoid-backup:x:123:123::/home/syncoid-backup:/bin/bash\\n' ;;
        group:123) printf 'syncoid-backup:x:123:\\n' ;;
        group:) printf 'syncoid-backup:x:123:\\nsudo:x:27:syncoid-backup\\n' ;;
    esac
}}
install() {{
    local -a args=()
    while (($#)); do
        case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
    done
    command install "${{args[@]}}"
}}
ssh-keygen() {{ :; }}
visudo() {{ :; }}
sshd() {{
    printf 'sshd %s\\n' "$*" >> "$CALLS"
    if [[ "$1" == -T ]]; then
        if [[ "$FAIL_CASE" == ssh && -f "$GATEWAY" ]]; then
            printf 'forcecommand unsafe\\npermittty yes\\n'
        else
            printf '%s\\n' "${{SSH_OPTIONS[@]}}"
        fi
    fi
}}
sudo() {{
    printf 'sudo %s\\n' "$*" >> "$CALLS"
    printf 'User syncoid-backup may run the following commands on v201:\\n'
    printf '    (root) NOPASSWD: NOSETENV: %s *\\n' "$GATEWAY"
    if [[ "$FAIL_CASE" == sudo ]]; then printf '    (ALL) ALL\\n'; fi
}}
usermod() {{ printf 'usermod %s\\n' "$*" >> "$CALLS"; }}
systemctl() {{
    printf 'systemctl %s\\n' "$*" >> "$CALLS"
    if [[ "$FAIL_CASE" == reload && "$1" == reload && ! -f {shlex.quote(str(root / 'failed-once'))} ]]; then
        touch {shlex.quote(str(root / 'failed-once'))}
        return 1
    fi
}}
main --key {shlex.quote(str(root / 'key.pub'))} --backup-address 192.0.2.1 {'--apply' if apply else ''}
'''
            result = subprocess.run(['bash', '-c', harness], capture_output=True, text=True)
            calls = (root / 'calls').read_text()
            if fail or not apply:
                self.assertEqual((root / 'ssh_config').read_text(), 'Port 22\n# original\n', result.stderr)
                self.assertEqual((root / 'ssh_config').stat().st_mode & 0o777, 0o640)
                for name, path in variables.items():
                    if name != 'SSH_CONFIG':
                        self.assertFalse((root / path).exists(), result.stderr)
                self.assertFalse((root / 'bin').exists(), result.stderr)
                self.assertFalse((root / 'auths').exists(), result.stderr)
            else:
                self.assertIn('\nMatch all\n    Include ', (root / 'ssh_config').read_text())
                self.assertTrue((root / 'auths/key').read_text().startswith('restrict,command='))
            return result, calls

    def test_apply_checks_policy_before_reload(self):
        result, calls = self.exercise_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(calls.index('sudo -l -U'), calls.index('systemctl reload'))

    def test_preview_never_changes_account_or_reloads(self):
        result, calls = self.exercise_install(apply=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('usermod ', calls)
        self.assertNotIn('systemctl reload', calls)

    def test_failed_policy_or_reload_restores_files_and_account(self):
        for failure in ('sudo', 'ssh', 'reload'):
            with self.subTest(failure=failure):
                result, calls = self.exercise_install(fail=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('restoring files and account settings', result.stderr)
                if failure != 'ssh':
                    self.assertIn('usermod -G sudo -s /bin/bash syncoid-backup', calls)
                self.assertTrue(calls.endswith('systemctl reload ssh\n'))

    def test_bundle_contains_exact_payload_and_rejects_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            puppet = root / 'puppet'
            source = puppet / 'modules/pts_only_shell/files/usr/local/sbin'
            source.mkdir(parents=True)
            for name in ('pts-zrep-source', 'pts-zrep-ssh'):
                (source / name).write_text('#!/bin/sh\nexit 0\n')
            fakebin = root / 'bin'
            fakebin.mkdir()
            (fakebin / 'git').write_text('#!/bin/sh\nprintf "test-revision\\n"\n')
            (fakebin / 'git').chmod(0o755)
            env = dict(os.environ, PATH=str(fakebin) + ':' + os.environ['PATH'])
            output = root / 'bundle.tar.gz'
            command = ['bash', str(ROOT / 'client/build-source-bundle.sh'),
                       '--puppet', str(puppet), '--output', str(output)]
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            with tarfile.open(output) as archive:
                payload = {item.name.split('/', 1)[1]: archive.extractfile(item).read()
                           for item in archive.getmembers() if item.isfile()}
            self.assertNotIn('install.py', payload)
            self.assertEqual(payload['install.sh'], INSTALLER.read_bytes())
            for line in payload['SHA256SUMS'].decode().splitlines():
                digest, name = line.split('  ')
                self.assertEqual(hashlib.sha256(payload[name]).hexdigest(), digest)
            for name in ('pts-zrep-source', 'pts-zrep-ssh'):
                self.assertEqual(payload[name], (source / name).read_bytes())
            self.assertNotEqual(subprocess.run(command, env=env, capture_output=True).returncode, 0)
            self.assertFalse(list(root.glob('.zrep-build-*')))


if __name__ == '__main__':
    unittest.main()

"""Transfer bundle boundaries and remote transport failures, without real SSH/network."""
import json
import shlex
import unittest

import test_installer
import test_scripts


class BundleTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    command = test_scripts.ShellTests.command
    file = test_scripts.ShellTests.file
    run_shell = test_scripts.ShellTests.run_shell
    assert_ok = test_scripts.ShellTests.assert_ok
    installer = test_installer.InstallerTests.installer
    args = test_installer.InstallerTests.args
    local_source = test_installer.InstallerTests.local_source

    def test_cache_replays_without_network_and_corruption_preserves_destination(self):
        data = self.file('payload', 'downloaded contents\n')
        self.file('destination', 'old')
        script = r'''
_MP_CACHE_WRITE="$TEST_ROOT/cache"
mp_cache_write 'https://example.invalid/private?token=secret' "$TEST_ROOT/payload" || exit 1
_MP_RESOURCE_DIR=$_MP_CACHE_WRITE
'''
        result = self.run_shell(script + 'download_file "https://example.invalid/private?token=secret" "$TEST_ROOT/destination"')
        self.assert_ok(result)
        self.assertEqual((self.root / 'destination').read_bytes(), data.read_bytes())
        (self.root / 'destination').write_text('old')
        for cache in (self.root / 'cache').iterdir():
            if cache.suffix != '.sha256': cache.write_text('corrupt contents')
        for url in ('https://example.invalid/private?token=secret', 'https://example.invalid/missing'):
            result = self.run_shell('_MP_RESOURCE_DIR="$TEST_ROOT/cache"\ndownload_file ' + shlex.quote(url) + ' "$TEST_ROOT/destination"')
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('unexpected-command', result.stderr)
            self.assertNotIn('secret', result.stdout + result.stderr)
            self.assertEqual((self.root / 'destination').read_text(), 'old')

    def test_manifest_rejects_modified_missing_extra_and_linked_files(self):
        self.file('bundle/repo/sh/test.sh', 'test code')
        payload = self.file('bundle/resources/data', 'test data')
        self.file('bundle/config.json', '{}')
        self.assert_ok(self.installer('inst_manifest "$TEST_ROOT/bundle" && inst_verify_bundle "$TEST_ROOT/bundle"'))
        for mutation in ('change', 'delete', 'extra', 'link'):
            with self.subTest(mutation=mutation):
                payload.unlink(missing_ok=True)
                payload.write_text('test data')
                extra = self.root / 'bundle/extra'
                extra.unlink(missing_ok=True)
                if mutation == 'change': payload.write_text('changed')
                elif mutation == 'delete': payload.unlink()
                elif mutation == 'extra': extra.write_text('unlisted')
                else:
                    payload.unlink(); payload.symlink_to('/etc/passwd')
                result = self.installer('inst_verify_bundle "$TEST_ROOT/bundle"')
                self.assertNotEqual(result.returncode, 0)

    def test_snapshot_copies_uncommitted_files_excludes_runtime_and_local_secrets(self):
        source = self.local_source()
        (source / 'domain/new.txt').write_text("payload:\n  - '+.new.test'\n")
        (source / 'sh/env.local.conf').write_text('SECRET=source')
        (source / 'sh/.schedule').mkdir()
        (source / 'sh/.schedule/local').write_text('local state')
        result = self.installer(self.args(['--source-dir', str(source), '--target', 'user@host']) + r'''
inst_validate || exit 1
_inst_tmp="$TEST_ROOT"
inst_snapshot "$TEST_ROOT/snapshot"
''')
        self.assert_ok(result)
        self.assertTrue((self.root / 'snapshot/domain/new.txt').is_file())
        self.assertFalse((self.root / 'snapshot/sh/env.local.conf').exists())
        self.assertFalse((self.root / 'snapshot/sh/.schedule').exists())

    def test_local_inference_and_remote_paths_are_on_different_machines(self):
        source = self.local_source()
        result = self.installer(self.args(['--local', '--target', 'root@host', '--install-dir', '/etc/proxy']) + 'inst_validate\nprintf "%s" "$_MP_SOURCE_DIR"', {'INST_ENTRY_ROOT': str(source)})
        self.assert_ok(result)
        self.assertTrue(result.stdout.endswith(str(source)))
        result = self.installer(self.args(['--local']) + 'inst_validate', {'INST_ENTRY_ROOT': ''})
        self.assertNotEqual(result.returncode, 0)

    def test_bundle_parameters_round_trip_without_evaluating_text(self):
        value = "https://example.invalid/$(touch PWNED)?a='b'\\test"
        result = self.installer(self.args() + r'''
MP_SUBSCRIBE_URL=$TEST_VALUE
INST_TARGET_OS=systemd; INST_TARGET_ARCH=x86_64
inst_save_config "$TEST_ROOT/config.json" || exit 1
MP_SUBSCRIBE_URL=
inst_load_config "$TEST_ROOT/config.json" || exit 1
printf '%s' "$MP_SUBSCRIBE_URL"
''', {'TEST_VALUE': value})
        self.assert_ok(result)
        self.assertEqual(result.stdout, value)
        self.assertFalse((self.root / 'PWNED').exists())
        data = json.loads((self.root / 'config.json').read_text())
        data['MP_PROXY'] = None
        (self.root / 'config.json').write_text(json.dumps(data))
        result = self.installer('inst_load_config "$TEST_ROOT/config.json"')
        self.assertNotEqual(result.returncode, 0)

    def test_remote_upload_failure_never_starts_installation(self):
        self.file('bundle/file', 'content')
        self.command('ssh', r'''
for arg do last=$arg; done
printf '%s\n' "$last" >> "$TEST_ROOT/ssh-commands"
case "$last" in
    *mktemp*) echo /tmp/myrule.TEST1234 ;;
    *'cat >'*) exit 42 ;;
    *) echo unexpected-execution >&2; exit 99 ;;
esac
''')
        result = self.installer(self.args(['--target', 'user@host']) + r'''
_inst_tmp="$TEST_ROOT"; INST_LIB=$TEST_LIB; INST_TARGET_UID=0
inst_deploy_remote "$TEST_ROOT/bundle"
''', {'TEST_LIB': str(test_installer.LIB)})
        self.assertNotEqual(result.returncode, 0)
        calls = (self.root / 'ssh-commands').read_text()
        self.assertNotIn('sudo sh', calls)
        self.assertNotIn('unexpected-execution', result.stderr)

    def test_ssh_auth_keeps_arguments_and_enables_native_password_or_key(self):
        self.command('ssh', 'printf "%s\\n" "$@"\n')
        key = self.file('key with spaces', 'fake key')
        for auth in ('auto', 'password', 'key'):
            result = self.installer(self.args(['--target', 'user@host', '--ssh-key', str(key), '--ssh-auth', auth, '--ssh-port', '2222']) + '\n_inst_tmp="$TEST_ROOT"\ninst_ssh -T "$INST_TARGET" true')
            self.assert_ok(result)
            args = result.stdout.splitlines()
            self.assertIn(str(key), args)
            self.assertIn('2222', args)
            self.assertNotIn('StrictHostKeyChecking=no', args)
            if auth == 'password': self.assertIn('PubkeyAuthentication=no', args)
            if auth == 'key': self.assertIn('PasswordAuthentication=no', args)

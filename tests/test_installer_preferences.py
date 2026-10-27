"""Persistent wizard defaults, private logs and macOS path aliases."""
import json
import shlex
import subprocess
import unittest

import test_installer
import test_scripts


class PreferencesTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    file = test_scripts.ShellTests.file
    command = test_scripts.ShellTests.command
    run_shell = test_scripts.ShellTests.run_shell
    assert_ok = test_scripts.ShellTests.assert_ok
    installer = test_installer.InstallerTests.installer
    local_source = test_installer.InstallerTests.local_source

    def test_entry_rejects_bad_options_before_network_or_package_changes(self):
        standalone = self.file('standalone/inst.sh', test_installer.SOURCE)
        self.command('curl', 'touch "$TEST_ROOT/network-used"; exit 99\n')
        cases = [(['--fill-file'], '未知参数'), (['--from-file'], '未知参数'),
                 (['--unknown=private-token'], '未知参数'),
                 (['--branch'], '参数缺少值'),
                 (['--subscribe-url', '--no-auth'], '参数缺少值'),
                 (['--ssh-key', '-h'], '参数缺少值'),
                 (['--branch=a', '--branch=b'], '重复参数'),
                 (['--no-auth=yes'], '参数')]
        for entry in (standalone, self.root/'sh/inst.sh'):
            for shell in ('sh', 'bash'):
                for args, message in cases:
                    with self.subTest(entry=entry, shell=shell, args=args):
                        result = subprocess.run([shell, str(entry), *args], env=self.env,
                                                capture_output=True, text=True, timeout=5)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(message, result.stdout+result.stderr)
                        self.assertNotIn('private-token', result.stdout+result.stderr)
                        self.assertFalse((self.root/'network-used').exists())

    def test_help_aliases_work_offline_without_touching_log(self):
        standalone = self.file('standalone/inst.sh', test_installer.SOURCE)
        log = self.file('myrule.inst.log', 'previous log')
        self.command('curl', 'touch "$TEST_ROOT/network-used"; exit 99\n')
        for entry in (standalone, self.root/'sh/inst.sh'):
            for flag in ('--help', '-h', 'help'):
                result = subprocess.run(['sh', str(entry), flag], env=self.env,
                                        capture_output=True, text=True, timeout=5)
                self.assert_ok(result)
                for option in ('--fill-from', '--branch', '--log-file', '--target'):
                    self.assertIn(option, result.stdout)
                self.assertFalse((self.root/'network-used').exists())
                self.assertEqual(log.read_text(), 'previous log')

    def test_entry_resets_default_and_custom_logs_each_run(self):
        standalone = self.file('standalone/inst.sh', test_installer.SOURCE)
        self.command('curl', 'exit 22\n')
        for entry in (standalone, self.root/'sh/inst.sh'):
            for custom in (False, True):
                log = entry.parent/'myrule.inst.log' if not custom else self.root/'custom.log'
                env = {key: value for key, value in self.env.items() if key != 'MP_LOG_FILE'}
                for iteration in range(2):
                    log.write_text('previous-run-marker\n')
                    args = ['--branch=main'] + (['--log-file', str(log)] if custom else [])
                    result = subprocess.run(['sh', str(entry), *args], env=env,
                                            capture_output=True, text=True, timeout=5)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn('previous-run-marker', log.read_text())
                    self.assertIn('安装入口', log.read_text())
                    self.assertEqual(log.stat().st_mode & 0o777, 0o600)

    def test_log_reset_keeps_subsequent_child_records_and_rejects_unsafe_path(self):
        self.file('custom.log', 'old-run')
        result = self.run_shell('''
mp_init_log "$TEST_ROOT/custom.log" reset || exit 1
mp_log_event entry
sh -c '. "$MP_INST_DIR/sh/common.sh"; mp_init_log "$MP_LOG_FILE"; mp_log_event child'
mp_log_event done
''')
        self.assert_ok(result)
        content = (self.root/'custom.log').read_text()
        self.assertNotIn('old-run', content)
        for marker in ('entry', 'child', 'done'):
            self.assertIn(marker, content)
        self.file('target', 'untouched')
        (self.root/'link.log').symlink_to(self.root/'target')
        result = self.run_shell('mp_init_log "$TEST_ROOT/link.log" reset')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root/'target').read_text(), 'untouched')

    def test_fill_flag_optional_path_and_log_option(self):
        entry = self.root / 'entry'
        entry.mkdir()
        cases = [([], '', 'interactive'), (['--subscribe-url', 'https://example.invalid'], '', 'silent'),
                 (['--fill-from'], str(entry/'myrule.inst.cfg'), 'interactive'),
                 (['--fill-from', 'custom.cfg'], 'custom.cfg', 'interactive'),
                 (['--fill-from=custom.cfg'], 'custom.cfg', 'interactive'),
                 (['--fill-from', '--log-file', 'custom.log'], str(entry/'myrule.inst.cfg'), 'interactive')]
        for args, expected, mode in cases:
            result = self.installer('inst_parse_args '+shlex.join(args)+' || exit 1\nprintf "%s|%s" "$INST_FILL_FILE" "$INSTALL_MODE"',
                                    {'INST_ENTRY_DIR': str(entry)})
            self.assert_ok(result)
            self.assertEqual(result.stdout, expected+'|'+mode)

    def prompts(self, config, answers, script, enabled=True):
        path = self.file('myrule.inst.cfg', json.dumps(config))
        self.file('answers', answers)
        # Separate input and output descriptors while exercising the real prompt function.
        source = test_installer.PREFIX.replace('read -r _p_val <&3', 'read -r _p_val <&4')
        return self.run_shell(source + '\ninst_colors\n'
                              + ('inst_parse_args --fill-from "$TEST_ROOT/myrule.inst.cfg"\n' if enabled else 'inst_parse_args\n')
                              + 'mp_fill_init || exit 1\nexec 3>"$TEST_ROOT/prompts"\nexec 4<"$TEST_ROOT/answers"\n'
                              + script, source=False)

    def test_saved_values_override_defaults_and_missing_keys_fall_back(self):
        result = self.prompts({'INST_TARGET':'saved@host', 'MP_PROXY':''}, '\n\nnew@host\n', '''
prompt_to INST_TARGET cli@host target
test "$INST_TARGET" = saved@host || exit 1
prompt_to MP_PROXY http://default.invalid proxy
test -z "$MP_PROXY" || exit 1
prompt_to INST_TARGET cli@host target
prompt_to UNUSED original unused </dev/null
'''.replace('prompt_to UNUSED original unused </dev/null', 'mp_fill_default absent original'))
        self.assert_ok(result)
        self.assertEqual(result.stdout, 'original\n')
        self.assertEqual(json.loads((self.root/'myrule.inst.cfg').read_text())['INST_TARGET'], 'new@host')
        self.assertEqual((self.root/'myrule.inst.cfg').stat().st_mode & 0o777, 0o600)

    def test_no_flag_does_not_read_or_rewrite_defaults(self):
        config={'INST_TARGET':'saved@host'}
        result=self.prompts(config, '\n', 'prompt_to INST_TARGET original target\nprintf "%s" "$INST_TARGET"', enabled=False)
        self.assert_ok(result)
        self.assertEqual(result.stdout, 'original')
        self.assertEqual(json.loads((self.root/'myrule.inst.cfg').read_text()),config)

    def test_input_is_saved_as_data_without_execution_or_logging_secret(self):
        value="https://example.invalid/$(touch PWNED)?a='secret'"
        result=self.prompts({}, value+'\n', 'prompt_to MP_SUBSCRIBE_URL empty sub')
        self.assert_ok(result)
        self.assertEqual(json.loads((self.root/'myrule.inst.cfg').read_text())['MP_SUBSCRIBE_URL'],value)
        self.assertFalse((self.root/'PWNED').exists())
        log=self.root/'myrule.inst.log'
        self.assertNotIn('secret',log.read_text() if log.exists() else '')

    def test_invalid_json_values_and_log_config_collision_preserve_file(self):
        for value in ('shell code', '[]', '{"key":4}', '{"key":"\\u0000"}'):
            config=self.file('bad.cfg',value)
            result=self.installer('INST_FILL_FILE="$TEST_ROOT/bad.cfg"\nmp_fill_init')
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(config.read_text(),value)
        config=self.file('bad.cfg','{}')
        result=self.installer('INST_FILL_FILE="$TEST_ROOT/bad.cfg"\nmp_init_log "$INST_FILL_FILE"')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(config.read_text(),'{}')

    def test_log_is_private_appended_and_failure_does_not_fall_back_to_console(self):
        result=self.run_shell('mp_init_log "$TEST_ROOT/custom.log" && mp_log_command curl --silent && mp_log_command curl --fail')
        self.assert_ok(result)
        self.assertEqual(result.stdout+result.stderr,'')
        log=self.root/'custom.log'
        self.assertEqual(log.stat().st_mode & 0o777,0o600)
        self.assertIn("'curl' '--silent'",log.read_text())
        self.assertIn("'curl' '--fail'",log.read_text())
        self.file('target','unchanged')
        (self.root/'link.log').symlink_to(self.root/'target')
        result=self.run_shell('mp_init_log "$TEST_ROOT/link.log"')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.root/'target').read_text(),'unchanged')

    def test_copy_from_symlinked_snapshot_still_rejects_real_escape(self):
        source=self.local_source()
        (self.root/'alias').symlink_to(source,target_is_directory=True)
        result=self.run_shell('download_file "$MP_REPO_RAW_URL/core/config.yaml" "$TEST_ROOT/result"',
                              extra={'_MP_SOURCE_DIR':str(self.root/'alias')})
        self.assert_ok(result)
        self.assertEqual((self.root/'result').read_bytes(),(source/'core/config.yaml').read_bytes())
        old=(self.root/'result').read_bytes()
        (source/'core/config.yaml').unlink()
        (source/'core/config.yaml').symlink_to(self.file('outside','outside content'))
        result=self.run_shell('download_file "$MP_REPO_RAW_URL/core/config.yaml" "$TEST_ROOT/result"',
                              extra={'_MP_SOURCE_DIR':str(self.root/'alias')})
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.root/'result').read_bytes(),old)

    def test_snapshot_excludes_default_and_custom_preferences_and_logs(self):
        source=self.local_source()
        for name in ('myrule.inst.cfg','myrule.inst.log','custom.cfg','custom.log'):
            (source/'sh'/name).write_text('private-secret')
        result=self.installer('''
_MP_SOURCE_DIR=$TEST_SOURCE; INST_TARGET=user@host; _inst_tmp=$TEST_ROOT
INST_FILL_FILE="$TEST_SOURCE/sh/custom.cfg"; MP_LOG_FILE="$TEST_SOURCE/sh/custom.log"
inst_snapshot "$TEST_ROOT/snapshot"
''',{'TEST_SOURCE':str(source)})
        self.assert_ok(result)
        for name in ('myrule.inst.cfg','myrule.inst.log','custom.cfg','custom.log'):
            self.assertFalse((self.root/'snapshot/sh'/name).exists())


if __name__=='__main__': unittest.main()

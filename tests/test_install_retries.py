"""Installer interaction and recovery contracts, no network or system mutation."""
import unittest
import test_installer
import test_scripts


class InstallRetryTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    file = test_scripts.ShellTests.file
    command = test_scripts.ShellTests.command
    run_shell = test_scripts.ShellTests.run_shell
    assert_ok = test_scripts.ShellTests.assert_ok
    installer = test_installer.InstallerTests.installer
    args = test_installer.InstallerTests.args

    def test_deprecated_proxy_and_auto_auth_rejected(self):
        for args in [['--proxy', 'http://example.invalid'], ['--download-proxy', 'http://example.invalid'], ['--ssh-auth', 'auto']]:
            result = self.installer(self.args(args) + 'inst_validate_basic')
            self.assertNotEqual(result.returncode, 0)

    def test_password_requires_interactive_and_silent_key_uses_batch_mode(self):
        result = self.installer(self.args(['--target','root@host','--ssh-auth','password']) + 'inst_validate_basic')
        self.assertNotEqual(result.returncode, 0)
        self.command('ssh', 'printf "%s\\n" "$@"')
        result = self.installer(self.args(['--target','root@host']) + '\n_inst_tmp="$TEST_ROOT"\ninst_ssh -T "$INST_TARGET" true')
        self.assert_ok(result)
        self.assertIn('BatchMode=yes', result.stdout)
        self.assertIn('PasswordAuthentication=no', result.stdout)

    def test_numeric_password_retries_before_other_inputs(self):
        result = self.installer(r'''
inst_parse_args --interactive
exec 3>/dev/null
n=0
prompt_to() {
    printf '%s\n' "$1" >> "$TEST_ROOT/order"
    case "$1" in
      INST_TARGET) INST_TARGET=root@host ;;
      INST_SSH_PORT) INST_SSH_PORT=22 ;;
      _is_auth_choice) _is_auth_choice=1 ;;
      _is_retry) _is_retry=y ;;
      *) exit 99 ;;
    esac
}
inst_require_tools() { :; }
inst_close_ssh() { echo close >> "$TEST_ROOT/order"; }
inst_probe_target() {
    test "$INST_SSH_AUTH" = password && test -z "$INST_SSH_KEY" || exit 98
    echo probe >> "$TEST_ROOT/order"
    n=$((n + 1)); [ "$n" -eq 2 ]
}
inst_collect_ssh || exit 1
test "$INST_SSH_READY" = 1
''')
        self.assert_ok(result)
        events=(self.root/'order').read_text().splitlines()
        self.assertEqual(events.count('probe'),2)
        self.assertEqual(events[events.index('probe')+1:events.index('probe')+3],['_is_retry','close'])
        self.assertNotIn('MP_SUBSCRIBE_URL',events)

    def test_remote_retry_reuses_bundle_and_propagates_failure(self):
        for mode, answer, expected, attempts in [('interactive','y',0,2),('interactive','n',9,1),('silent','y',9,1)]:
            (self.root/'attempts').unlink(missing_ok=True)
            result=self.installer(r'''
inst_parse_args --target root@host
INSTALL_MODE=$TEST_MODE
n=0
inst_deploy_remote() { echo "$1" >> "$TEST_ROOT/attempts"; n=$((n+1)); [ "$n" -ge 2 ] || return 9; }
inst_prepare() { exit 99; }
inst_clear_remote_attempt() { :; }
inst_close_ssh() { :; }
inst_collect_ssh() { :; }
prompt_to() { [ "$INSTALL_MODE" = interactive ] || exit 98; _ii_retry=$TEST_ANSWER; }
inst_install_with_retry "$TEST_ROOT/bundle"
''',{'TEST_MODE':mode,'TEST_ANSWER':answer})
            self.assertEqual(result.returncode,expected,result.stdout+result.stderr)
            self.assertEqual((self.root/'attempts').read_text().splitlines(),[str(self.root/'bundle')]*attempts)
            self.assertIn('安装可能已部分完成',result.stdout)

    def test_local_retry_preserves_original_bundle(self):
        entry=self.file('bundle/repo/sh/install-lib.sh', 'if [ ! -f "$TEST_ROOT/once" ]; then touch "$TEST_ROOT/once"; exit 7; fi\nexit 0\n')
        result=self.installer('''
inst_parse_args --interactive
prompt_to() { _ii_retry=y; }
inst_install_with_retry "$TEST_ROOT/bundle"
''')
        self.assert_ok(result)
        self.assertTrue(entry.exists())

    def test_disconnected_remote_attempt_is_not_deleted_while_it_may_run(self):
        result=self.installer('''
inst_parse_args --target root@host
_inst_remote_tmp=/tmp/myrule.test123; _inst_remote_uncertain=1
inst_ssh() { echo unexpected-ssh-delete; return 99; }
inst_clear_remote_attempt
''')
        self.assert_ok(result)
        self.assertIn('保留临时目录',result.stdout)
        self.assertNotIn('unexpected-ssh-delete',result.stdout)

    def test_apply_failure_reports_phase(self):
        result=self.installer('''
inst_parse_args --no-start
inst_verify_bundle() { return 4; }
inst_apply "$TEST_ROOT"
''')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('阶段：校验安装包及目标环境',result.stdout)
        self.assertIn('退出码',result.stdout)

    def test_apply_lock_rejects_concurrent_install_before_forward_changes(self):
        result=self.installer(r'''
inst_parse_args --no-start
inst_verify_bundle() { :; }
inst_load_config() { DIR_INST=$TEST_ROOT; INST_TARGET_OS=systemd; INST_TARGET_ARCH=$(uname -m); }
inst_validate_basic() { :; }
inst_is_root() { :; }
inst_detect_os() { os_type=systemd; }
inst_require_tools() { :; }
mp_require_tun() { :; }
inst_enable_forward() { echo unexpected-mutation; return 99; }
mkdir -p "$TEST_ROOT/sh/.install-state"
exec 8>"$TEST_ROOT/sh/.install-state/apply.lock"
flock -n 8 || exit 99
inst_apply "$TEST_ROOT"
''')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('已有安装正在执行',result.stdout)
        self.assertNotIn('unexpected-mutation',result.stdout)

    def test_script_and_config_default_intervals(self):
        result=self.installer('''
inst_parse_args --interactive
prompt_to() { eval "$1=\\$2"; }
prompt_cron_days cron_script_days scripts 7
prompt_cron_days cron_config_days configs
printf '%s/%s' "$cron_script_days" "$cron_config_days"
''')
        self.assert_ok(result)
        self.assertEqual(result.stdout,'7/3')

    def test_proxy_migration_preserves_other_lines_and_is_repeatable(self):
        p=self.file('sh/env.local.conf', "CUSTOM='keep'\nMP_PROXY='http://private.invalid'\n export MP_PROXY='old'\n")
        body=test_scripts.function_source(test_scripts.ROOT/'sh/migrate-legacy.sh','mp_migrate_legacy_proxy')
        for _ in range(2): self.assert_ok(self.run_shell(body+'\nmp_migrate_legacy_proxy'))
        self.assertEqual(p.read_text(),"CUSTOM='keep'\n")
        self.assertEqual(p.stat().st_mode&0o777,0o600)

    def test_required_subscription_color_blank_and_invalid_retry(self):
        self.file('answers','\nnot-a-url\nhttps://example.invalid/sub\n')
        source=test_installer.PREFIX.replace('read -r _p_val <&3','read -r _p_val <&4')
        result=self.run_shell(source+'''
inst_colors
inst_parse_args --interactive
T_RED=$(printf '\\033[31m'); T_R=$(printf '\\033[0m')
exec 3>"$TEST_ROOT/prompts"; exec 4<"$TEST_ROOT/answers"
inst_prompt_subscription || exit 1
printf '%s' "$MP_SUBSCRIBE_URL"
''',source=False)
        self.assert_ok(result)
        self.assertIn('此项不能为空',result.stdout)
        self.assertIn('必须为 http/https',result.stdout)
        self.assertIn('\x1b[31m节点订阅', (self.root/'prompts').read_text())
        self.assertTrue(result.stdout.endswith('https://example.invalid/sub'))

"""Dependency bootstrap with fake package managers; never install host packages."""
import subprocess
import unittest

import test_installer
import test_scripts


class DependencyTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    command = test_scripts.ShellTests.command
    file = test_scripts.ShellTests.file
    run_shell = test_scripts.ShellTests.run_shell
    assert_ok = test_scripts.ShellTests.assert_ok

    def installer(self, script, extra=None):
        return self.run_shell(test_installer.PREFIX + '\ninst_colors\n' + script,
                              source=False, extra=extra)

    def manager(self, name):
        self.command(name, r'''
printf '%s|%s|%s\n' "${0##*/}" "$*" "${DEBIAN_FRONTEND:-}" >> "$TEST_ROOT/packages"
if [ "$1" = "${FAIL_STEP:-never}" ]; then echo simulated-package-error >&2; exit 42; fi
case "$1" in install|add) : > "$TEST_ROOT/installed" ;; esac
''')

    def bootstrap(self, manager='apt-get', missing='curl jq', extra=None):
        self.manager(manager)
        # Only availability is simulated. Selection, mapping, execution and recheck are real.
        return self.installer(r'''
os_type=$TEST_OS; _inst_distro=debian; _inst_distro_like=
command() {
    case "$2" in
        apt-get|apk|opkg) [ "$2" = "$TEST_MANAGER" ] ;;
        *) type "$2" >/dev/null 2>&1 ;;
    esac
}
inst_dependency_present() {
    case " $TEST_MISSING " in
        *" $1 "*) [ -f "$TEST_ROOT/installed" ] && [ "${STILL_MISSING:-0}" = 0 ] ;;
        *) return 0 ;;
    esac
}
inst_require_tools "${TEST_MODE:-}"
''', {'TEST_OS': 'systemd' if manager == 'apt-get' else 'openwrt',
      'TEST_MANAGER': manager, 'TEST_MISSING': missing, **(extra or {})})

    def test_complete_dependencies_do_not_touch_package_manager(self):
        self.assert_ok(self.bootstrap(missing=''))
        self.assertFalse((self.root / 'packages').exists())

    def test_missing_packages_are_batched_deduplicated_and_rechecked(self):
        result = self.bootstrap(missing='curl jq gunzip gzip ip sysctl logger awk find cat cp ca-certificates')
        self.assert_ok(result)
        calls = (self.root / 'packages').read_text().splitlines()
        self.assertEqual(calls[0], 'apt-get|update|noninteractive')
        arguments = calls[1].split('|')[1].split()
        self.assertEqual(arguments[:3], ['install', '-y', '--no-install-recommends'])
        self.assertEqual(set(arguments[3:]), {'curl', 'jq', 'gzip', 'iproute2', 'procps',
                         'bsdutils', 'mawk', 'findutils', 'coreutils', 'ca-certificates'})
        self.assertEqual(len(arguments[3:]), len(set(arguments[3:])))
        self.assertIn('检查通过', result.stdout)
        log = (self.root / 'myrule.inst.log').read_text()
        self.assertIn("'apt-get' 'update'", log)
        self.assertIn("'apt-get' 'install' '-y' '--no-install-recommends'", log)

    def test_openwrt_opkg_and_apk(self):
        for manager, action in [('opkg', 'install'), ('apk', 'add')]:
            with self.subTest(manager=manager):
                (self.root / 'installed').unlink(missing_ok=True)
                (self.root / 'packages').unlink(missing_ok=True)
                result = self.bootstrap(manager, 'curl jq ca-certificates ip sysctl logger awk find head')
                self.assert_ok(result)
                calls = (self.root / 'packages').read_text().splitlines()
                self.assertEqual(calls[0], manager + '|update|')
                self.assertEqual(set(calls[1].split('|')[1].split()), {action, 'curl', 'jq',
                                 'ca-bundle', 'ip-tiny', 'procps-ng-sysctl', 'logger',
                                 'gawk', 'findutils-find', 'coreutils-head'})
                log = (self.root / 'myrule.inst.log').read_text()
                self.assertIn(f"'{manager}' 'update'", log)
                self.assertIn(f"'{manager}' '{action}'", log)

    def test_update_failure_stops_before_install(self):
        for manager in ('apt-get', 'opkg', 'apk'):
            with self.subTest(manager=manager):
                (self.root / 'packages').unlink(missing_ok=True)
                result = self.bootstrap(manager, extra={'FAIL_STEP': 'update'})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len((self.root / 'packages').read_text().splitlines()), 1)
                self.assertIn('退出码 42', result.stdout)
                self.assertIn('simulated-package-error', result.stderr)
                self.assertIn(manager + ' update &&', result.stdout)

    def test_install_failure_and_false_success_stop(self):
        for extra in ({'FAIL_STEP': 'install'}, {'STILL_MISSING': '1'}):
            with self.subTest(extra=extra):
                result = self.bootstrap(extra=extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('手动处理后重新运行安装器', result.stdout)
                if 'STILL_MISSING' in extra:
                    self.assertIn('安装后仍缺少依赖', result.stdout)

    def test_ca_bundle_is_required_even_when_commands_exist(self):
        source = test_installer.PREFIX.replace('/etc/ssl/certs/ca-certificates.crt',
                                              str(self.root / 'ca.crt'))
        source = source.replace('/etc/ssl/cert.pem', str(self.root / 'ca.pem'))
        script = source + '\ninst_dependency_present ca-certificates'
        self.assertNotEqual(self.run_shell(script, source=False).returncode, 0)
        self.file('ca.crt', '')
        self.assertNotEqual(self.run_shell(script, source=False).returncode, 0)
        self.file('ca.pem', 'test CA bundle')
        self.assert_ok(self.run_shell(script, source=False))

    def test_bootstrap_without_curl_jq_or_other_external_commands(self):
        # A shell loaded from a browser-downloaded file can reach the package manager
        # with no external tools on PATH. The fake manager creates executable stubs.
        minimal = self.root / 'minimal'
        minimal.mkdir()
        manager = minimal / 'apt-get'
        manager.write_text('''#!/bin/sh
printf '%s\n' "$*" >> "$TEST_ROOT/minimal-calls"
if [ "$1" = install ]; then
    for tool in curl jq tar gzip gunzip ip sysctl logger awk sed grep find cat chmod cp mv rm mkdir mktemp dirname basename readlink date sleep head sort tr wc ln uname id sha256sum; do
        printf '#!/bin/sh\nexit 0\n' > "$TEST_ROOT/minimal/$tool"
        /bin/chmod +x "$TEST_ROOT/minimal/$tool"
    done
fi
''')
        manager.chmod(0o755)
        source = test_installer.PREFIX.replace('/etc/ssl/certs/ca-certificates.crt',
                                              str(self.file('ca.crt', 'test CA')))
        script = source + '''
inst_colors
os_type=systemd; _inst_distro=debian; _inst_distro_like=
inst_require_tools
'''
        result = subprocess.run(['/bin/sh', '-c', script], env=self.env | {'PATH': str(minimal)},
                                capture_output=True, text=True, timeout=10)
        self.assert_ok(result)
        calls = (self.root / 'minimal-calls').read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertIn('curl', calls[1])
        self.assertIn('jq', calls[1])

    def test_optional_cron_mapping(self):
        for manager, package in [('apt-get', 'cron'), ('opkg', 'busybox'), ('apk', 'busybox')]:
            with self.subTest(manager=manager):
                (self.root / 'installed').unlink(missing_ok=True)
                (self.root / 'packages').unlink(missing_ok=True)
                self.assert_ok(self.bootstrap(manager, 'crontab', {'TEST_MODE': 'cron'}))
                calls = (self.root / 'packages').read_text().splitlines()
                self.assertEqual(calls[-1].split('|')[1].split()[-1], package)

    def test_skip_cron_does_not_install_or_write(self):
        result = self.installer('''
os_type=systemd; cron_script_days=n; cron_config_days=n
inst_require_tools() { echo unexpected-dependency-install; return 99; }
inst_apply_schedule
''')
        self.assert_ok(result)
        self.assertNotIn('unexpected', result.stdout + result.stderr)

    def test_chosen_cron_dependency_failure_prevents_writes(self):
        # Apply preflight checks cron dependencies before mkdir or configuration writes.
        apply = test_installer.APPLY
        apply = apply[apply.index('inst_apply() ('):]
        preflight = apply[apply.index('    inst_require_tools &&'):apply.index('    DIR_SH=')]
        result = self.installer('''
cron_script_days=3; cron_config_days=n
mp_require_tun() { :; }
inst_require_tools() { [ "$1" != cron ] || { echo dependency-install-failed; return 1; }; }
''' + preflight)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('dependency-install-failed', result.stdout)
        self.assertNotIn('unexpected', result.stdout + result.stderr)

    def test_help_invalid_input_and_nonroot_do_not_install(self):
        for args in (['--help'], ['--unknown'], ['--branch', 'dev']):
            result = subprocess.run(['sh', str(test_scripts.ROOT / 'sh/inst.sh'), *args],
                                    env=self.env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode == 0, args == ['--help'])
            self.assertNotIn('unexpected-command', result.stdout + result.stderr)
        self.command('id', 'echo 1000\n')
        result = subprocess.run(['sh', str(test_scripts.ROOT / 'sh/inst.sh'), *test_installer.REQUIRED],
                                env=self.env, capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('root', result.stdout)
        self.assertNotIn('unexpected-command', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()

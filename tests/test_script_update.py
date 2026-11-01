"""Script update activation with simulated service managers and no host writes."""
import unittest

import test_scripts


class ScriptUpdateTests(unittest.TestCase):
    setUp_base = test_scripts.ShellTests.setUp
    file = test_scripts.ShellTests.file
    command = test_scripts.ShellTests.command
    run_shell = test_scripts.ShellTests.run_shell
    add_common = test_scripts.ShellTests.add_common
    assert_ok = test_scripts.ShellTests.assert_ok

    def setUp(self):
        self.setUp_base()
        common = self.root/'sh/common.sh'
        common.write_text(common.read_text().replace('"/etc/$rel"', '"$TEST_ROOT/etc/$rel"'))
        self.file('core-running', 'yes')
        self.file('agh-running', 'yes')
        self.file('etc/systemd/system/proxy_core.service', 'core unit\n')
        self.command('systemctl', '''
[ "$1 $2" = 'is-active --quiet' ] || exit 99
case "$3" in proxy_core.service) test -f "$TEST_ROOT/core-running" ;;
agh.service) test -f "$TEST_ROOT/agh-running" ;; *) exit 99 ;; esac
''')
        self.command('service', '''
[ "$2" = running ] || exit 99
case "$1" in proxy_core) test -f "$TEST_ROOT/core-running" ;;
agh) test -f "$TEST_ROOT/agh-running" ;; *) exit 99 ;; esac
''')
        self.add_common('''
mp_detect_os() { echo "${TEST_OS:-systemd}"; }
mp_service_op() {
    printf '%s %s\\n' "$1" "$2" >> "$TEST_ROOT/events"
    [ "$2" != "${FAIL_SERVICE:-none}" ] || return 1
    if [ "$2" = proxy_core ]; then
        : > "$TEST_ROOT/core-running"
        [ "${TEST_OS:-systemd}" != systemd ] || rm -f "$TEST_ROOT/agh-running"
    else
        : > "$TEST_ROOT/agh-running"
    fi
}
mp_wait_core_ready() {
    echo ready >> "$TEST_ROOT/events"
    [ "${FAIL_READY:-0}" = 0 ]
}
''')
        self.stamp = self.root/'sh/.install-state/service-scripts.sha256'

    def activate(self, **extra):
        return self.run_shell('mp_restart_updated_services', extra=extra)

    def events(self):
        p = self.root/'events'
        return p.read_text().splitlines() if p.exists() else []

    def clear_events(self):
        (self.root/'events').unlink(missing_ok=True)

    def test_running_services_restart_in_order_on_both_platforms(self):
        for platform in ('systemd', 'openwrt'):
            self.stamp.unlink(missing_ok=True)
            self.clear_events()
            self.assert_ok(self.activate(TEST_OS=platform))
            self.assertEqual(self.events(), ['restart proxy_core', 'ready', 'restart agh'])
            self.assertEqual(self.stamp.stat().st_mode & 0o777, 0o600)

    def test_identical_update_and_unrelated_script_changes_skip_restart(self):
        self.assert_ok(self.activate())
        self.clear_events()
        self.assert_ok(self.activate())
        self.file('sh/update-bin.sh', '# unrelated update code\n')
        self.assert_ok(self.activate())
        self.assertEqual(self.events(), [])

    def test_watcher_and_service_file_changes_restart_without_reinstall(self):
        self.assert_ok(self.activate())
        for path in ('sh/setup-fake-ip-route.sh', 'etc/systemd/system/proxy_core.service'):
            self.clear_events()
            with (self.root/path).open('a') as f: f.write('\n# updated\n')
            self.assert_ok(self.activate())
            self.assertEqual(self.events(), ['restart proxy_core', 'ready', 'restart agh'])

    def test_stopped_services_remain_stopped(self):
        (self.root/'agh-running').unlink()
        self.assert_ok(self.activate())
        self.assertEqual(self.events(), ['restart proxy_core', 'ready'])
        self.stamp.unlink()
        self.clear_events()
        (self.root/'core-running').unlink()
        self.assert_ok(self.activate())
        self.assertEqual(self.events(), [])

    def test_failed_readiness_keeps_pending_and_retry_restores_agh(self):
        self.assertNotEqual(self.activate(FAIL_READY='1').returncode, 0)
        self.assertFalse(self.stamp.exists())
        self.assertFalse((self.root/'agh-running').exists())
        self.assertTrue(self.stamp.with_suffix('.sha256.pending').exists())
        self.clear_events()
        self.assert_ok(self.activate())
        self.assertEqual(self.events(), ['restart proxy_core', 'ready', 'restart agh'])
        self.assertFalse(self.stamp.with_suffix('.sha256.pending').exists())

    def test_restart_failure_is_not_recorded_as_success(self):
        for service in ('proxy_core', 'agh'):
            self.assertNotEqual(self.activate(FAIL_SERVICE=service).returncode, 0)
            self.assertFalse(self.stamp.exists())
        self.assert_ok(self.activate())

    def test_update_entry_does_not_restart_after_sync_failure(self):
        self.add_common('''
mp_sync_etc_files() { echo sync >> "$TEST_ROOT/events"; return "${FAIL_SYNC:-0}"; }
''')
        result = self.run_shell('sh "$MP_INST_DIR/sh/update-scripts.sh"',
                                extra={'_MP_REEXEC': '1', 'FAIL_SYNC': '1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(), ['sync'])
        self.clear_events()
        self.assert_ok(self.run_shell('sh "$MP_INST_DIR/sh/update-scripts.sh"',
                                     extra={'_MP_REEXEC': '1'}))
        self.assertEqual(self.events(), ['sync', 'restart proxy_core', 'ready', 'restart agh'])


if __name__ == '__main__':
    unittest.main()

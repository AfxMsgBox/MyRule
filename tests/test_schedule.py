"""Scheduled update fixtures; no network or real service operations."""
import unittest

import test_scripts


class ScheduleTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    command = test_scripts.ShellTests.command
    file = test_scripts.ShellTests.file
    run_shell = test_scripts.ShellTests.run_shell
    assert_ok = test_scripts.ShellTests.assert_ok

    def prepare(self):
        self.command('date', 'printf "%s\\n" "$TEST_NOW"\n')
        self.command('flock', '[ "${TEST_LOCKED:-0}" = 0 ]\n')
        for name in ('update-scripts.sh', 'update-all-configs-restart-services.sh'):
            self.file('sh/' + name, '''#!/bin/sh
test "$_MP_NONINTERACTIVE" = 1 || exit 99
printf '%s\n' "${0##*/}" >> "$TEST_ROOT/events"
test "${TEST_FAIL:-0}" = 0
''')

    def run_update(self, day, kind='scripts', extra=None):
        return self.run_shell('sh "$MP_INST_DIR/sh/run-scheduled-update.sh" ' + kind + ' 3',
                              source=False, extra={'TEST_NOW': str(day * 86400), **(extra or {})})

    def test_elapsed_days_success_and_independent_config_state(self):
        self.prepare()
        stamp = self.file('sh/.schedule/scripts.last', '20000\n')
        self.assert_ok(self.run_update(20002))
        self.assertFalse((self.root / 'events').exists())
        self.assert_ok(self.run_update(20003))
        self.assertEqual(stamp.read_text(), '20003\n')
        self.assert_ok(self.run_update(20003))
        self.assertEqual(len((self.root / 'events').read_text().splitlines()), 1)
        self.assert_ok(self.run_update(20003, 'configs'))
        self.assertEqual((self.root / 'sh/.schedule/configs.last').read_text(), '20003\n')

    def test_failure_lock_and_clock_rollback_preserve_last_success(self):
        self.prepare()
        stamp = self.file('sh/.schedule/scripts.last', '20000\n')
        self.assert_ok(self.run_update(19999))
        self.assert_ok(self.run_update(20003, extra={'TEST_LOCKED': '1'}))
        self.assertFalse((self.root / 'events').exists())
        self.assertNotEqual(self.run_update(20003, extra={'TEST_FAIL': '1'}).returncode, 0)
        self.assertEqual(stamp.read_text(), '20000\n')
        self.assert_ok(self.run_update(20004))
        self.assertEqual(stamp.read_text(), '20004\n')


if __name__ == '__main__':
    unittest.main()

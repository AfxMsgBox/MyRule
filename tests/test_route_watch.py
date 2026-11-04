"""Event-driven routing with a simulated ip/netlink; never alter host routes."""
import json
import os
import signal
import shutil
import subprocess
import sys
import time
import unittest

import test_scripts


class RouteWatchTests(unittest.TestCase):
    setUp_base = test_scripts.ShellTests.setUp
    file = test_scripts.ShellTests.file
    command = test_scripts.ShellTests.command
    assert_ok = test_scripts.ShellTests.assert_ok

    def setUp(self):
        self.setUp_base()
        self.env['TMPDIR'] = str(self.root)
        self.script = self.root / 'core/start.sh'
        self.script.write_text(self.script.read_text()
            .replace('/sys/class/net/', str(self.root / 'sys/class/net') + '/')
            .replace('/proc/sys/kernel/random/boot_id', str(self.root / 'boot'))
            .replace('/proc/net/netlink', str(self.root / 'netlink')))
        self.file('boot', '11111111-1111-1111-1111-111111111111\n')
        self.file('netlink', '')
        self.config()
        self.state(up=True, address=True, route='', index=7, connected='198.18.0.0/30')
        self.command('logger', 'printf "%s\\n" "$*" >> "$TEST_ROOT/log"\n')
        os.mkfifo(self.root / 'input')
        mock = self.file('commands/ip', '#!' + sys.executable + '\n' + r'''
import json, os, sys
from pathlib import Path
root = Path(os.environ['TEST_ROOT'])
args = sys.argv[1:]
with (root/'calls').open('a') as f: f.write(json.dumps(args)+'\n')
if args == ['-o', '-4', 'monitor', 'link', 'address', 'route']:
    (root/'monitor-pid').write_text(str(os.getpid()))
    (root/'netlink').write_text(f'0 0 {os.getpid()} 00000151\n')
    with (root/'input').open() as f:
        for event in f:
            if event.strip() == 'quit': break
            print(event.rstrip(), flush=True)
    sys.exit(0)
s = json.loads((root/'state').read_text())
if args[:4] == ['-o', 'link', 'show', 'dev']:
    if s.get('absent'): sys.exit(1)
    print(f'{s["index"]}: utun: <POINTOPOINT,{"UP" if s["up"] else "NOARP"}> mtu 9000')
elif args[:5] == ['-4', '-o', 'address', 'show', 'dev']:
    if s['address']: print(f'{s["index"]}: utun    inet 198.18.0.1/30 scope global utun')
elif args[:5] == ['-4', 'route', 'show', 'table', 'main'] and 'kernel' in args:
    cidr = s.get('connected', '')
    if cidr and ('exact' not in args or args[args.index('exact')+1] == cidr):
        print(cidr+' dev utun proto kernel scope link src 198.18.0.1')
elif args[:3] == ['-4', 'route', 'del']:
    if s.get('delete_fail'): sys.exit(2)
    s['connected'] = ''
    (root/'state').write_text(json.dumps(s))
elif args[:6] == ['-4', 'route', 'show', 'table', 'main', 'exact']:
    print(s['route'])
elif args[:3] == ['-4', 'route', 'replace']:
    if s.get('fail'): sys.exit(2)
    s['route'] = args[3]+' dev '+args[5]+' scope link'
    (root/'state').write_text(json.dumps(s))
elif args[:3] == ['link', 'show', 'dev']:
    sys.exit(int(s.get('absent', False)))
else:
    print('unexpected ip: '+repr(args), file=sys.stderr); sys.exit(99)
''')
        mock.chmod(0o755)

    def config(self, cidr='198.18.0.1/16'):
        self.file('core/config.yaml', f'tun:\n  device: utun\ndns:\n  fake-ip-range: {cidr}\n')

    def state(self, **changes):
        p = self.root / 'state'
        state = json.loads(p.read_text()) if p.exists() else {}
        state.update(changes)
        p.write_text(json.dumps(state))
        self.file('sys/class/net/utun/ifindex', str(state['index'])+'\n')

    def once(self, *args):
        return subprocess.run(['sh', str(self.script), *(args or ('--once',))], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def calls(self):
        p = self.root / 'calls'
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []

    def replacements(self):
        return [x for x in self.calls() if x[:3] == ['-4', 'route', 'replace']]

    def wait_for(self, condition):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if condition(): return
            time.sleep(.02)
        self.fail('timed out waiting for event processing')

    def watch(self):
        output = (self.root / 'output').open('w')
        proc = subprocess.Popen(['sh', str(self.script), '--watch'], env=self.env,
                                stdout=output, stderr=output, start_new_session=True)
        def cleanup():
            if proc.poll() is None:
                proc.terminate()
                try: proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL); proc.wait()
            output.close()
        self.addCleanup(cleanup)
        self.wait_for(lambda: (self.root/'monitor-pid').exists())
        # RDWR avoids a test-side FIFO open hanging when the listener fails.
        writer = os.open(self.root/'input', os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, writer)
        self.wait_for(lambda: (self.root/'log').exists() and
                      '监听已启动' in (self.root/'log').read_text())
        return proc, writer

    def test_once_idempotent_removes_covered_30_and_records_ownership(self):
        self.assert_ok(self.once())
        record = (self.root/'core/.fake-ip-route').read_text()
        self.assertTrue(record.startswith('198.18.0.0/16 utun 7 '))
        self.assert_ok(self.once('--once'))
        self.assertEqual(len(self.replacements()), 1)
        deletes = [x for x in self.calls() if 'del' in x]
        self.assertEqual(len(deletes), 1)
        self.assertIn('198.18.0.0/30', deletes[0])
        self.assertLess(self.calls().index(self.replacements()[0]), self.calls().index(deletes[0]))

    def test_uncovered_or_equal_prefix_is_preserved(self):
        for pool, connected in [('198.18.0.1/16', '192.0.2.0/30'), ('198.18.0.1/30', '198.18.0.0/30')]:
            self.config(pool)
            self.state(route='', connected=connected)
            self.assert_ok(self.once())
            self.assertEqual(json.loads((self.root/'state').read_text())['connected'], connected)
        self.assertFalse(any('del' in x for x in self.calls()))

    def test_failed_covering_route_does_not_delete_30(self):
        self.state(fail=True)
        self.assertNotEqual(self.once().returncode, 0)
        self.assertFalse(any('del' in x for x in self.calls()))

    def test_delete_failure_is_reported_and_retried(self):
        self.state(delete_fail=True)
        self.assertNotEqual(self.once().returncode, 0)
        self.state(delete_fail=False)
        self.assert_ok(self.once())
        self.assertEqual(json.loads((self.root/'state').read_text())['connected'], '')

    def test_watch_removes_recreated_connected_route(self):
        proc, writer = self.watch()
        self.wait_for(lambda: json.loads((self.root/'state').read_text())['connected'] == '')
        self.state(connected='198.18.0.0/30')
        os.write(writer, b'198.18.0.0/30 dev utun proto kernel scope link\n')
        self.wait_for(lambda: json.loads((self.root/'state').read_text())['connected'] == '')
        self.assertIsNone(proc.poll())

    def test_missing_down_or_unaddressed_interface_is_not_modified(self):
        for changes in ({'absent': True}, {'absent': False, 'up': False},
                        {'up': True, 'address': False}):
            self.state(**changes)
            self.assert_ok(self.once())
        self.assertEqual(self.replacements(), [])

    def test_external_correct_route_not_claimed(self):
        self.state(route='198.18.0.0/16 dev utun scope link')
        self.assert_ok(self.once())
        self.assertFalse((self.root/'core/.fake-ip-route').exists())

    def test_wrong_gateway_route_replaced_and_failure_reported(self):
        self.state(route='198.18.0.0/16 via 192.0.2.1 dev utun', fail=True)
        self.assertNotEqual(self.once().returncode, 0)
        self.assertFalse((self.root/'core/.fake-ip-route').exists())
        self.state(fail=False)
        self.assert_ok(self.once())

    def test_watch_recreates_routes_and_is_idle_without_events(self):
        proc, writer = self.watch()
        self.assertEqual(len(self.replacements()), 1)
        before = len(self.calls())
        time.sleep(.2)
        self.assertEqual(len(self.calls()), before)  # no polling
        os.write(writer, b'7: utun: <UP>\n198.18.0.0/16 dev utun scope link\n')
        time.sleep(.2)
        self.assertEqual(len(self.replacements()), 1)  # own events do not loop
        self.state(route='', index=8)
        os.write(writer, b'8: utun: <UP>\n')
        self.wait_for(lambda: len(self.replacements()) == 2)
        self.wait_for(lambda: 'utun 8 ' in (self.root/'core/.fake-ip-route').read_text())
        self.state(route='')
        os.write(writer, b'Deleted 198.18.0.0/16 dev utun\n')
        self.wait_for(lambda: len(self.replacements()) == 3)
        self.assertIsNone(proc.poll())

    def test_watch_waits_for_address_and_reads_changed_config(self):
        self.state(address=False)
        proc, writer = self.watch()
        self.assertEqual(self.replacements(), [])
        self.config('198.19.0.1/16')
        self.state(address=True)
        os.write(writer, b'7: utun    inet 198.18.0.1/30\n')
        self.wait_for(lambda: bool(self.replacements()))
        self.assertEqual(self.replacements()[-1][3], '198.19.0.0/16')

    def test_duplicate_watcher_rejected_and_sigterm_reaps_monitor(self):
        proc, writer = self.watch()
        self.assertNotEqual(self.once('--watch').returncode, 0)
        child = int((self.root/'monitor-pid').read_text())
        proc.terminate()
        self.assertEqual(proc.wait(timeout=3), 0)
        self.assertFalse(os.path.exists(f'/proc/{child}'))
        self.assertFalse(list(self.root.glob('tmp.*/events')))

    def test_monitor_eof_exits_nonzero_for_supervisor(self):
        proc, writer = self.watch()
        os.write(writer, b'quit\n')
        self.assertNotEqual(proc.wait(timeout=3), 0)

    def test_netlink_overflow_restarts_instead_of_silently_missing_events(self):
        proc, writer = self.watch()
        os.write(writer, b'recvmsg: No buffer space available\n')
        self.assertNotEqual(proc.wait(timeout=3), 0)

    def test_startup_subscription_failure_is_reported(self):
        self.command('ip', 'echo unsupported-monitor >&2; exit 1\n')
        self.command('sleep', 'exit 0\n')
        self.assertNotEqual(self.once('--watch').returncode, 0)
        self.assertIn('无法订阅', (self.root/'log').read_text())

    @unittest.skipUnless(os.environ.get('MYRULE_TEST_NETLINK') == '1',
                         'requires a real read-only Netlink socket')
    def test_real_netlink_subscription_and_shutdown(self):
        real_ip = shutil.which('ip')
        self.assertIsNotNone(real_ip)
        # 超过 Linux 接口名上限，保证此测试不可能写入任何真实路由。
        self.file('core/config.yaml', 'tun:\n  device: myrule_nonexistent_test_interface\n'
                  'dns:\n  fake-ip-range: 198.18.0.1/16\n')
        self.script.write_text(self.script.read_text().replace(str(self.root/'netlink'),
                                                               '/proc/net/netlink'))
        self.command('ip', f'exec {real_ip} "$@"\n')
        output = (self.root/'output').open('w')
        proc = subprocess.Popen(['sh', str(self.script), '--watch'], env=self.env,
                                stdout=output, stderr=output)
        try:
            self.wait_for(lambda: (self.root/'log').exists() and
                          '监听已启动' in (self.root/'log').read_text())
            self.assertIsNone(proc.poll())
            self.assertFalse((self.root/'core/.fake-ip-route').exists())
        finally:
            proc.terminate()
            proc.wait(timeout=3)
            output.close()
        self.assertEqual(proc.returncode, 0)

    def test_help_and_bad_options_do_not_touch_network(self):
        self.assert_ok(self.once('--help'))
        self.assertNotEqual(self.once('--unknown').returncode, 0)
        self.assertEqual(self.calls(), [])


if __name__ == '__main__':
    unittest.main()

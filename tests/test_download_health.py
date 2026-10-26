"""Download observability, fail-fast and target readiness contracts."""
import json
import shlex
import sys
import unittest

import test_installer
import test_scripts


class DownloadTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    command = test_scripts.ShellTests.command
    file = test_scripts.ShellTests.file
    run_shell = test_scripts.ShellTests.run_shell
    assert_ok = test_scripts.ShellTests.assert_ok
    tty = test_installer.InstallerTests.tty

    def fake_curl(self, replies):
        self.file('replies', json.dumps(replies))
        path = self.file('commands/curl', '#!' + sys.executable + '\n' + r'''
import json, os, pathlib, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
args = sys.argv[1:]
log = root / 'calls'
n = len(log.read_text().splitlines()) if log.exists() else 0
with log.open('a') as f: f.write(json.dumps(args)+'\n')
replies = json.loads((root / 'replies').read_text())
code, http, body = replies[min(n, len(replies)-1)]
pathlib.Path(args[args.index('-o')+1]).write_text(body)
if '--progress-bar' in args:
    sys.stderr.write('\r######## 50.0%\rcurl: private-secret must never leak\n\r################ 100.0%\r')
else:
    sys.stderr.write('curl: private-secret must never leak\n')
if '--write-out' in args: print(http, end='')
sys.exit(code)
''')
        path.chmod(0o755)
        self.command('sleep', 'exit 0\n')

    def download(self):
        return self.run_shell('_MP_NONINTERACTIVE=1\ndownload_file '
                              '"https://example.invalid/private-secret" "$TEST_ROOT/result" true 8 "版本信息" 60')

    def calls(self):
        return [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]

    def test_transient_retries_then_success(self):
        self.fake_curl([(22, '503', ''), (28, '000', ''), (0, '200', 'valid response')])
        result = self.download()
        self.assert_ok(result)
        self.assertEqual(len(self.calls()), 3)
        self.assertIn('HTTP 503', result.stderr)
        self.assertIn('30 秒无数据', result.stderr)
        self.assertIn('自动重试 2/2', result.stderr)
        self.assertNotIn('private-secret', result.stdout + result.stderr)
        args = self.calls()[0]
        for flag, value in [('--max-time', '60'), ('--speed-time', '30'), ('--speed-limit', '1')]:
            self.assertEqual(args[args.index(flag)+1], value)
        self.assertIn('--silent', args)
        self.assertNotIn('--progress-bar', args)

    def test_permanent_http_error_does_not_retry_or_replace_file(self):
        for status in ('403', '404'):
            with self.subTest(status=status):
                (self.root / 'calls').unlink(missing_ok=True)
                self.fake_curl([(22, status, 'not a valid file')])
                self.file('result', 'old')
                result = self.download()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(self.calls()), 1)
                self.assertEqual((self.root / 'result').read_text(), 'old')
                self.assertIn('HTTP '+status, result.stderr)
                self.assertFalse(list(self.root.glob('.download.*')))

    def test_transient_error_stops_after_three_rounds(self):
        self.fake_curl([(6, '000', '')])
        self.file('result', 'old')
        result = self.download()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 3)
        self.assertEqual((self.root / 'result').read_text(), 'old')
        self.assertIn('DNS 解析失败', result.stderr)

    def test_terminal_progress_is_visible_but_raw_errors_are_not(self):
        self.fake_curl([(0, '200', 'valid response')])
        result = self.tty('. "$MP_INST_DIR/sh/common.sh"\n_MP_NONINTERACTIVE=1\n'
                          'download_file https://example.invalid "$TEST_ROOT/result"')
        self.assert_ok(result)
        self.assertIn('50.0%', result.stdout)
        self.assertIn('100.0%', result.stdout)
        self.assertNotIn('private-secret', result.stdout)
        self.assertIn('--progress-bar', self.calls()[0])

    def test_standalone_transport_matches_shared_transport(self):
        def block(path):
            text = path.read_text()
            return text[text.index('# BEGIN shared HTTP'):text.index('# END shared HTTP')]
        root = test_scripts.ROOT / 'sh'
        self.assertEqual(block(root / 'portable.sh'), block(root / 'inst.sh'))


class ReadinessTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    command = test_scripts.ShellTests.command
    file = test_scripts.ShellTests.file
    run_shell = test_scripts.ShellTests.run_shell
    assert_ok = test_scripts.ShellTests.assert_ok

    def test_tun_preflight_requires_an_accessible_character_device(self):
        fn = test_scripts.function_source(test_scripts.ROOT / 'sh/portable.sh', 'mp_require_tun')
        regular = self.file('regular', 'not a device')
        for path, valid in [(str(self.root / 'missing'), False), (str(regular), False), ('/dev/null', True)]:
            result = self.run_shell(fn.replace('/dev/net/tun', path) + '\nmp_require_tun', source=False)
            self.assertEqual(result.returncode == 0, valid, result.stdout + result.stderr)

    def network(self, route, up=True):
        self.file('core/config.yaml', 'external-controller: :3721\ntun:\n  device: utun\ndns:\n  fake-ip-range: 198.18.0.1/16\n')
        self.file('route', route)
        self.command('ip', '''
case "$*" in
    'link show utun') ''' + ("echo '3: utun: <POINTOPOINT,UP,LOWER_UP> mtu 9000'" if up else 'exit 1') + ''' ;;
    '-4 route show 198.18.0.0/16') cat "$TEST_ROOT/route" ;;
    *) exit 99 ;;
esac
''')

    def test_exact_direct_route_and_live_interface_required(self):
        cases = [('', True, False), ('198.18.0.0/16 dev utun scope link\n', True, True),
                 ('198.18.0.0/16 dev other\n', True, False),
                 ('198.18.0.0/30 dev utun\n', True, False),
                 ('198.18.0.0/16 via 192.0.2.1 dev utun\n', True, False),
                 ('198.18.0.0/16 dev utun\n', False, False)]
        for route, up, valid in cases:
            self.network(route, up)
            result = self.run_shell('mp_core_network_ready')
            self.assertEqual(result.returncode == 0, valid, route)

    def test_api_success_cannot_hide_missing_tun_or_route(self):
        self.command('curl', 'exit 0\n')
        self.command('date', '''n=$(cat "$TEST_ROOT/clock" 2>/dev/null || echo 0)
n=$((n+1)); echo "$n" > "$TEST_ROOT/clock"; echo "$n"
''')
        self.command('sleep', 'exit 0\n')
        for up, valid, reason in [(False, False, 'TUN'), (True, False, 'fake-ip'), (True, True, '')]:
            (self.root / 'clock').unlink(missing_ok=True)
            self.network('198.18.0.0/16 dev utun\n' if valid else '', up)
            result = self.run_shell('mp_wait_core_ready 3')
            self.assertEqual(result.returncode == 0, valid, result.stdout)
            self.assertIn(reason, result.stdout)

    def test_target_check_stops_before_resource_preparation(self):
        script = test_installer.PREFIX + r'''
inst_detect_launcher() { :; }
inst_require_tools() { :; }
inst_is_root() { return 0; }
inst_detect_os() { os_type=systemd; }
mp_require_tun() { echo missing-tun >&2; return 1; }
inst_prepare() { echo BUG-prepared; }
inst_main --subscribe-url https://example.invalid/sub --no-auth
'''
        result = self.run_shell(script, source=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing-tun', result.stderr)
        self.assertNotIn('BUG-prepared', result.stdout)


class ResourceFailureTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    command = test_scripts.ShellTests.command
    file = test_scripts.ShellTests.file
    run_shell = test_scripts.ShellTests.run_shell
    assert_ok = test_scripts.ShellTests.assert_ok
    add_common = test_scripts.ShellTests.add_common
    make_binary_fixtures = test_scripts.ShellTests.make_binary_fixtures

    def test_invalid_version_does_not_download_any_component(self):
        self.make_binary_fixtures()
        self.file('fixtures/release.json', '{"message":"invalid metadata"}')
        result = self.run_shell('sh "$MP_INST_DIR/sh/update-bin.sh"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('tag_name', result.stdout)
        self.assertEqual(len((self.root / 'binary-downloads').read_text().splitlines()), 1)

    def test_binary_failure_does_not_download_ui_or_agh(self):
        self.make_binary_fixtures()
        self.file('fixtures/mihomo.gz', 'corrupt archive')
        result = self.run_shell('sh "$MP_INST_DIR/sh/update-bin.sh"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len((self.root / 'binary-downloads').read_text().splitlines()), 2)

    def test_ui_failure_does_not_download_agh(self):
        self.make_binary_fixtures()
        self.file('fixtures/ui.tgz', 'corrupt archive')
        result = self.run_shell('sh "$MP_INST_DIR/sh/update-bin.sh"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len((self.root / 'binary-downloads').read_text().splitlines()), 3)

    def test_provider_and_filter_failures_stop_their_lists(self):
        self.file('core/config.yaml', (test_scripts.ROOT / 'core/config.yaml').read_text()
                  .replace('{MP_SUBSCRIBE_URL}', 'https://example.invalid/sub'))
        self.file('agh/agh.yaml', (test_scripts.ROOT / 'agh/agh.yaml').read_text())
        for call in ('mp_fetch_core_providers "$MP_CORE_DIR/config.yaml"',
                     'mp_fetch_agh_filters "$MP_AGH_DIR/agh.yaml"'):
            (self.root / 'requests').unlink(missing_ok=True)
            result = self.run_shell('download_file() { echo request >> "$TEST_ROOT/requests"; return 1; }\n' + call)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((self.root / 'requests').read_text().splitlines(), ['request'])

    def test_domain_list_failure_preserves_dns_and_stops_downloads(self):
        self.file('core/config.yaml', 'dns:\n  listen: 127.0.0.1:253\n')
        self.file('agh/dns.conf', 'old DNS rules\n')
        self.add_common('download_file() { echo request >> "$TEST_ROOT/requests"; return 1; }')
        result = self.run_shell('sh "$MP_INST_DIR/sh/update-agh-config.sh"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / 'requests').read_text().splitlines(), ['request'])
        self.assertEqual((self.root / 'agh/dns.conf').read_text(), 'old DNS rules\n')
        self.assertFalse(list((self.root / 'agh').glob('dns.conf.tmp.*')))

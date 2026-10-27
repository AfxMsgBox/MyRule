"""Exact, replayable download commands in private logs; concise terminal output."""
import json
import shlex
import shutil
import subprocess
import sys
import unittest

import test_scripts
import test_download_health


class CommandLogTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    command = test_scripts.ShellTests.command
    file = test_scripts.ShellTests.file
    run_shell = test_scripts.ShellTests.run_shell
    assert_ok = test_scripts.ShellTests.assert_ok
    fake_curl = test_download_health.DownloadTests.fake_curl
    calls = test_download_health.DownloadTests.calls

    def logged(self, result, replay=False):
        log = (self.root / 'myrule.inst.log').read_text()
        self.assertNotIn('[命令，敏感值已脱敏]', result.stdout + result.stderr)
        commands = []; is_replay = False
        for line in log.splitlines():
            if line.startswith('['):
                is_replay = '调试重放命令' in line
            elif is_replay == replay and line.startswith(('  [命令，敏感值已脱敏] ', " '")):
                commands.append(shlex.split(line.split('] ', 1)[1] if line.startswith('  [命令，敏感值已脱敏] ') else line))
        return commands

    def test_curl_replay_runs_after_installer_temporary_directories_are_removed(self):
        real_curl = shutil.which('curl')
        self.assertIsNotNone(real_curl)
        self.command('curl', 'exec ' + shlex.quote(real_curl) + ' "$@"\n')
        payload = self.file('source with spaces.txt', 'downloaded content\n')
        temporary = self.root/'removed-install-dir'
        temporary.mkdir()
        args = ['curl', '--disable', '--fail', '-L', '--connect-timeout', '10',
                '--max-time', '60', '--proxy', '', '--noproxy', '*',
                '--write-out', '%{http_code}', '--dump-header', str(temporary/'headers'),
                payload.as_uri(), '-o', str(temporary/'download'), '--silent',
                '-H', "Authorization: Bearer a'b$(touch PWNED)"]
        result = self.run_shell('mp_log_download_command ' + shlex.join(args))
        self.assert_ok(result)
        self.assertEqual(self.logged(result), [args])
        replay = self.logged(result, replay=True)[0]
        self.assertNotIn('--silent', replay)
        self.assertIn('--show-error', replay)
        self.assertIn(args[-1], replay)
        self.assertIn(payload.as_uri(), replay)
        shutil.rmtree(temporary)
        original = self.run_shell(shlex.join(args), source=False)
        self.assertNotEqual(original.returncode, 0)
        log = (self.root/'myrule.inst.log').read_text().splitlines()
        command = next(log[i+1] for i, line in enumerate(log) if '调试重放命令' in line)
        for shell in ('sh', 'bash'):
            replayed = subprocess.run([shell, '-c', command], cwd=self.root, env=self.env,
                                      capture_output=True, text=True, timeout=5)
            self.assert_ok(replayed)
            self.assertEqual((self.root/'myrule-download.body').read_bytes(), payload.read_bytes())
            self.assertTrue((self.root/'myrule-download.headers').exists())
        self.assertFalse((self.root/'PWNED').exists())
        self.assertFalse(temporary.exists())

    def test_full_download_command_round_trips_secrets_and_shell_characters(self):
        recorder = self.file('record.py', 'import json,sys\nfrom pathlib import Path\n'
                             'Path("replayed.json").write_text(json.dumps(sys.argv[1:]))\n')
        args = [sys.executable, str(recorder),
                'https://user:password@example.invalid/private?token=secret#fragment',
                '--proxy', 'socks5h://user:proxy-password@proxy.invalid:1080',
                '-H', 'Authorization: Bearer api-secret', "a'b", '', 'path with spaces',
                '$(touch PWNED); `touch PWNED`']
        result = self.run_shell('mp_log_download_command ' + shlex.join(args))
        self.assert_ok(result)
        self.assertEqual(result.stdout+result.stderr, '')
        self.assertEqual(self.logged(result), [args])
        self.assertFalse((self.root/'replayed.json').exists())
        log = (self.root/'myrule.inst.log').read_text()
        command = next(line for line in log.splitlines() if line.startswith(" '"))
        replay = subprocess.run(['sh', '-c', command], cwd=self.root, capture_output=True, text=True)
        self.assert_ok(replay)
        self.assertEqual(json.loads((self.root/'replayed.json').read_text()), args[2:])
        self.assertFalse((self.root/'PWNED').exists())
        self.assertEqual((self.root/'myrule.inst.log').stat().st_mode & 0o777, 0o600)

    def test_package_download_logger_keeps_actual_arguments_and_exit_status(self):
        self.command('package-test', 'exit 7\n')
        args = ['package-test', '--repository', 'https://user:secret@example.invalid/path?token=value']
        result = self.run_shell('mp_run_download_command ' + shlex.join(args))
        self.assertEqual(result.returncode, 7)
        self.assertEqual(self.logged(result), [args])
        self.assertEqual(result.stdout+result.stderr, '')

    def test_command_arguments_are_quoted_without_evaluation(self):
        args = ['printf', '%s', "a'b", 'path with spaces', '', '$(touch PWNED); `id`']
        result = self.run_shell('mp_log_command ' + shlex.join(args))
        self.assert_ok(result)
        self.assertEqual(self.logged(result), [args])
        self.assertFalse((self.root / 'PWNED').exists())

    def test_public_paths_visible_private_paths_queries_and_auth_hidden(self):
        public = 'https://github.com/MetaCubeX/mihomo/releases/download/v1/file.gz'
        private = 'https://user:secret@example.invalid/secret-path?token=secret-query#secret-fragment'
        result = self.run_shell('mp_log_command ' + shlex.join([
            'curl', public, private, '--proxy', 'http://user:secret-proxy@proxy.invalid:8080',
            '-H', 'Authorization: Bearer secret-header']))
        self.assert_ok(result)
        logged = self.logged(result)[0]
        self.assertIn(public, logged)
        self.assertIn('https://<redacted>@example.invalid/<redacted>?<redacted>#<redacted>', logged)
        self.assertIn('http://<redacted>@proxy.invalid:8080', logged)
        self.assertIn('Authorization: <redacted>', logged)
        self.assertNotIn('secret', result.stdout + result.stderr)

    def test_each_channel_logs_its_actual_options_without_changing_request(self):
        self.file('core/config.yaml', 'mixed-port: 7890\n')
        self.fake_curl([(7, '000', ''), (0, '200', 'valid response')])
        url = 'https://example.invalid/secret-path?token=secret-query'
        proxy = 'socks5h://user:secret-proxy@proxy.invalid:1080'
        result = self.run_shell('_MP_NONINTERACTIVE=1\ndownload_file ' + shlex.quote(url)
                                + ' "$TEST_ROOT/result"', extra={'MP_PROXY': proxy})
        self.assert_ok(result)
        logs = self.logged(result)
        calls = self.calls()
        self.assertEqual(len(logs), len(calls))
        self.assertEqual(len(logs), 2)
        for logged, actual in zip(logs, calls):
            self.assertEqual(logged, ['curl', *actual])
            self.assertEqual(logged[logged.index('--noproxy')+1], actual[actual.index('--noproxy')+1])
            self.assertIn(url, actual)
            self.assertIn('--silent', logged)
        self.assertEqual(calls[1][calls[1].index('--proxy')+1], proxy)
        self.assertNotIn('secret', result.stdout + result.stderr)
        self.assertIn('下载完成', result.stderr)

    def test_core_refresh_reports_real_result_without_leaking_authorization(self):
        self.file('core/config.yaml', 'external-controller: :3721\nsecret: secret-header\nproxy-providers:\n  test-provider:\n    type: http\n')
        self.command('sleep', 'exit 0\n')
        self.command('curl', 'printf "%s\\n" "$@" > "$TEST_ROOT/api-args"\necho raw-secret >&2\nprintf 204\nexit "$TEST_STATUS"\n')
        for status in ('0', '7'):
            (self.root / 'myrule.inst.log').unlink(missing_ok=True)
            result = self.run_shell('sh "$MP_INST_DIR/sh/update-proxy-rule.sh"', extra={'TEST_STATUS': status})
            self.assertEqual(result.returncode == 0, status == '0', result.stdout + result.stderr)
            self.assertIn('由 Core 下载，等待 API 结果', result.stdout)
            self.assertIn('刷新 proxies/test-provider ' + ('OK' if status == '0' else '失败'), result.stdout)
            self.assertEqual(len(self.logged(result)), 1)
            self.assertIn('Authorization: Bearer secret-header', self.logged(result)[0])
            self.assertNotIn('secret', result.stdout + result.stderr)
            self.assertIn('Authorization: Bearer secret-header', (self.root / 'api-args').read_text())


if __name__ == '__main__':
    unittest.main()

"""Optional WireGuard rendering and installer propagation."""
import base64
import json
import shlex
import unittest
import test_scripts
import test_installer

WG = {
    'MP_WG_ENABLED': '1',
    'MP_WG_PRIVATE_KEY': base64.b64encode(bytes(range(32))).decode(),
    'MP_WG_PUBLIC_KEY': base64.b64encode(bytes(range(32, 64))).decode(),
    'MP_WG_IP': '10.77.0.2',
    'MP_WG_SERVER_IP': 'wg.example.com',
    'MP_WG_SERVER_PORT': '51820',
}


class WireGuardInstallTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    file = test_scripts.ShellTests.file
    command = test_scripts.ShellTests.command
    run_shell = test_scripts.ShellTests.run_shell
    assert_ok = test_scripts.ShellTests.assert_ok
    installer = test_installer.InstallerTests.installer
    args = test_installer.InstallerTests.args

    def render(self, extra=None, text=None):
        self.file('template', text if text is not None else
                  (test_scripts.ROOT/'core/config.yaml').read_text())
        return self.run_shell('mp_render_template "$TEST_ROOT/template" "$TEST_ROOT/result"',
                              extra=extra or {})

    def test_enabled_all_blocks_and_update_repeat(self):
        for _ in range(2):
            self.assert_ok(self.render(WG))
            result = (self.root/'result').read_text()
            self.assertIn('    private-key: '+WG['MP_WG_PRIVATE_KEY'], result)
            self.assertIn('    ip: 10.77.0.2', result)
            self.assertEqual(result.count('      - wg-Proxy'), 3)
            self.assertNotIn('{MP_WG_', result)
            self.assertIn('    remote-dns-resolve: true #', result)

    def test_disabled_preserves_comments_and_never_renders_keys(self):
        self.assert_ok(self.render(WG | {'MP_WG_ENABLED': '0'}))
        result = (self.root/'result').read_text()
        self.assertIn('#    private-key: {MP_WG_PRIVATE_KEY}', result)
        self.assertNotIn(WG['MP_WG_PRIVATE_KEY'], result)
        self.assertNotIn('\nproxies:', result)

    def test_bad_markers_or_missing_block_preserve_existing_file(self):
        for text in ('#wg proxy start\n#x\n', '#wg proxy end\n',
                     '#wg proxy start\n#wg proxy start\n#wg proxy end\n',
                     '#wg proxy start\nx\n#wg proxy end\n',
                     'mixed-port: 7890\n'):
            self.file('result', 'old')
            self.assertNotEqual(self.render(WG, text).returncode, 0)
            self.assertEqual((self.root/'result').read_text(), 'old')

    def test_invalid_fields_never_expose_private_key(self):
        for field, value in [('MP_WG_ENABLED','yes'), ('MP_WG_PRIVATE_KEY','bad-secret'),
                             ('MP_WG_PUBLIC_KEY',''), ('MP_WG_IP','10.0.0.256'),
                             ('MP_WG_IP','10.0.0.2/24'), ('MP_WG_SERVER_IP','host;id'),
                             ('MP_WG_SERVER_IP','999.1.1.1'), ('MP_WG_SERVER_PORT','65536'),
                             ('MP_WG_SERVER_PORT','0')]:
            params = WG | {field: value}
            result = self.render(params)
            self.assertNotEqual(result.returncode, 0, field)
            self.assertNotIn(params['MP_WG_PRIVATE_KEY'], result.stdout+result.stderr)

    def test_cli_and_bundle_roundtrip(self):
        options = ['--wireguard', '--wg-private-key', WG['MP_WG_PRIVATE_KEY'],
                   '--wg-public-key', WG['MP_WG_PUBLIC_KEY'], '--wg-ip', WG['MP_WG_IP'],
                   '--wg-server', WG['MP_WG_SERVER_IP'], '--wg-port', WG['MP_WG_SERVER_PORT']]
        result = self.installer(self.args(options)+'''
inst_validate_basic || exit 1
INST_TARGET_OS=OpenWrt; INST_TARGET_ARCH=x86_64
inst_save_config "$TEST_ROOT/config.json" || exit 1
MP_WG_PRIVATE_KEY=
inst_load_config "$TEST_ROOT/config.json" || exit 1
printf '%s' "$MP_WG_PRIVATE_KEY"
''')
        self.assert_ok(result)
        self.assertTrue(result.stdout.endswith(WG['MP_WG_PRIVATE_KEY']))
        config = json.loads((self.root/'config.json').read_text())
        for key, value in WG.items():
            self.assertEqual(config[key], value)

    def test_enable_requires_all_fields_and_flags_conflict(self):
        for options in (['--wireguard'], ['--wireguard', '--no-wireguard']):
            self.assertNotEqual(self.installer(self.args(options)+'inst_validate_basic').returncode, 0)

    def test_saved_env_is_used_by_update(self):
        text = '\n'.join(k+'='+shlex.quote(v) for k,v in WG.items())+'\n'
        self.file('sh/env.local.conf', text)
        self.assert_ok(self.render())
        self.assertIn('    ip: 10.77.0.2', (self.root/'result').read_text())

    def test_cli_beats_saved_defaults_and_input_beats_cli(self):
        self.file('defaults.json', json.dumps({'MP_WG_IP': '10.0.0.9'}))
        script = self.args(['--wg-ip', '10.0.0.8'])+"""
INSTALL_MODE=interactive
INST_FILL_FILE="$TEST_ROOT/defaults.json"
# 提示输出丢弃，fd3 仅承载模拟终端输入。
printf() { command printf "$@" 2>/dev/null || :; }
prompt_to MP_WG_IP "$MP_WG_IP" 'ip' 3<<'INPUT'

INPUT
test "$MP_WG_IP" = 10.0.0.8 || exit 1
prompt_to MP_WG_IP "$MP_WG_IP" 'ip' 3<<'INPUT'
10.0.0.7
INPUT
test "$MP_WG_IP" = 10.0.0.7
"""
        self.assert_ok(self.installer(script))

    def test_wizard_yes_and_no(self):
        assignments = '\n'.join(k+'='+shlex.quote(v) for k,v in WG.items())
        result = self.installer(assignments+'''
prompt_to() { MP_WG_ENABLED=yes; }
prompt_required() { :; }
INST_FILL_FILE=
inst_choose_wireguard || exit 1
test "$MP_WG_ENABLED" = 1 || exit 1
prompt_to() { MP_WG_ENABLED=no; }
inst_choose_wireguard || exit 1
test "$MP_WG_ENABLED" = 0
''')
        self.assert_ok(result)


if __name__ == '__main__':
    unittest.main()

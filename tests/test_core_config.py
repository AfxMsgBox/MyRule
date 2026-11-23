"""User-owned Core configurations: imports, read-only updates and optional features."""
import hashlib
import json
import os
import shlex
import subprocess
import time
import unittest

import test_installer
import test_scripts


class CoreConfigTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    file = test_scripts.ShellTests.file
    command = test_scripts.ShellTests.command
    run_shell = test_scripts.ShellTests.run_shell
    assert_ok = test_scripts.ShellTests.assert_ok
    configure_downloads = test_scripts.ShellTests.configure_downloads
    add_common = test_scripts.ShellTests.add_common
    installer = test_installer.InstallerTests.installer

    def import_config(self, text):
        self.file('input.yaml', text)
        return self.run_shell('mp_import_core_config "$TEST_ROOT/input.yaml" "$TEST_ROOT/result.yaml"')

    def test_empty_file_and_disabled_sections_stay_empty_or_disabled(self):
        for text in ('', '# no proxy yet\n', 'tun:\n  enable: false\ndns:\n  enable: false\n'):
            self.assert_ok(self.import_config(text))
            self.assertEqual((self.root/'result.yaml').read_text(), text or '{}\n')
            self.assertEqual((self.root/'result.yaml').stat().st_mode & 0o777, 0o600)

    def test_import_only_fills_enabled_sections_and_keeps_values(self):
        self.assert_ok(self.import_config('tun:\n  enable: true\ndns:\n  enable: true\n'))
        text = (self.root/'result.yaml').read_text()
        for item in ('device: utun', 'listen: 127.0.0.1:253', 'fake-ip-range: 198.18.0.1/16'):
            self.assertIn(item, text)
        custom = 'tun:\n    enable: true\n    device: mytun\ndns:\n    enable: true\n    listen: 127.0.0.1:5353\n    fake-ip-range: 198.19.0.1/24\n'
        self.assert_ok(self.import_config(custom))
        self.assertEqual((self.root/'result.yaml').read_text(), custom)
        self.assert_ok(self.import_config('tun:\n  enable: true\n  device: ""\ndns:\n  enable: false\n'))
        text = (self.root/'result.yaml').read_text()
        self.assertEqual(text.count('device:'), 1)
        self.assertNotIn('listen:', text)

    def test_bad_values_and_unsupported_yaml_never_replace_existing_file(self):
        for text in ('tun:\n  enable: invalid\n', 'dns:\n  listen: :65536\n',
                     'dns:\n  fake-ip-range: 999.18.0.1/16\n', 'mixed-port: nope\n',
                     'external-ui: ../outside\n', 'external-controller: broken\n',
                     'tun: {enable: true}\n', 'dns: *defaults\n',
                     'proxy-providers:\n  x: {type: http}\n',
                     'proxy-providers:\n  <<: *providers\n',
                     'mixed-port: 1\n---\nmixed-port: 2\n',
                     'url: {MP_SUBSCRIBE_URL}\n', 'not yaml\n',
                     '  proxy-providers:\n    x: {}\n', '"dns":\n  enable: true\n',
                     'dns:\n  "enable": true\n'):
            self.file('result.yaml', 'old')
            result = self.import_config(text)
            self.assertNotEqual(result.returncode, 0, text)
            self.assertEqual((self.root/'result.yaml').read_text(), 'old')

    def test_defaults_and_optional_flags(self):
        self.file('core/config.yaml', '')
        result = self.run_shell('mp_core_tun_device; mp_core_fake_ip_cidr; mp_core_dns_endpoint; '
                                '! mp_core_enabled tun && ! mp_core_route_enabled')
        self.assert_ok(result)
        self.assertEqual(result.stdout, 'utun\n198.18.0.0/16\n127.0.0.1:253\n')
        self.assert_ok(self.run_shell('mp_core_network_ready'))
        self.assert_ok(self.run_shell('mp_service_running() { return 0; }; mp_wait_core_ready 2'))

    def test_no_api_and_no_proxy_skip_without_network(self):
        self.file('core/config.yaml', '')
        for script in ('update-proxy-rule.sh', 'keeplive.sh'):
            result = self.run_shell('sh "$MP_INST_DIR/sh/'+script+'"')
            self.assert_ok(result)
            self.assertIn('跳过', result.stdout)
            self.assertNotIn('unexpected-command', result.stderr)

    def test_empty_config_agh_has_no_proxy_or_dead_dns_upstream(self):
        self.configure_downloads()
        self.file('core/config.yaml', '')
        self.assert_ok(self.run_shell('mp_prepare_agh_config "$MP_AGH_DIR/agh.yaml" && sh "$MP_INST_DIR/sh/update-agh-config.sh"'))
        self.assertIn('http_proxy: ""', (self.root/'agh/agh.yaml').read_text())
        dns = (self.root/'agh/dns.conf').read_text()
        self.assertNotIn(':253', dns)
        self.assertNotIn('[/',''.join(dns))
        self.assertIn('223.5.5.5', dns)
        self.assertNotIn('gfw.txt', (self.root/'downloads').read_text())

    def test_updates_and_legacy_entry_preserve_config_bytes_and_pending(self):
        self.configure_downloads()
        config = test_scripts.CORE_CONFIG + '\n# user WG\nproxies:\n  - name: wg\n    type: wireguard\n    private-key: user-owned-test-key\n'
        self.file('core/config.yaml', config)
        self.file('core/config.yaml.pending', 'user-pending')
        before = hashlib.sha256(config.encode()).digest()
        for script in ('update-core-config.sh', 'update-all-configs.sh'):
            self.assert_ok(self.run_shell('sh "$MP_INST_DIR/sh/'+script+'"'))
            self.assertEqual(hashlib.sha256((self.root/'core/config.yaml').read_bytes()).digest(), before)
            self.assertEqual((self.root/'core/config.yaml.pending').read_text(), 'user-pending')
        self.assertNotIn('/core/config.yaml', (self.root/'downloads').read_text())
        self.assertNotEqual(self.run_shell('sh "$MP_INST_DIR/sh/update-core-config.sh" output.yaml').returncode, 0)
        self.assertFalse((self.root/'output.yaml').exists())

    def test_provider_http_failure_and_missing_file_are_not_ignored(self):
        for text in ('proxy-providers:\n  test:\n    type: http\n    url: https://example.invalid/sub\n    path: proxy/sub.yaml\n',
                     'proxy-providers:\n  local:\n    type: file\n    path: proxy/local.yaml\n',
                     'proxy-providers:\n  no_path:\n    type: http\n    url: https://example.invalid/sub\n'):
            self.file('core/config.yaml', text)
            self.assertNotEqual(self.run_shell('download_file() { return 1; }; mp_fetch_core_providers').returncode, 0)
        self.file('core/config.yaml', '')
        self.assert_ok(self.run_shell('mp_fetch_core_providers'))

    def test_provider_path_cannot_overwrite_config_or_follow_symlinks(self):
        for path in ('config.yaml', 'config.yaml.pending', '../outside', '/tmp/outside', 'mihomo', '.fake-ip-route', 'ui/index.html', 'link/secret'):
            (self.root/'core/link').unlink(missing_ok=True)
            (self.root/'core/link').symlink_to(self.root, target_is_directory=True)
            text = f'external-ui: ui\nproxy-providers:\n  test:\n    type: http\n    url: https://example.invalid/sub\n    path: {path}\n'
            self.file('core/config.yaml', text)
            self.assertNotEqual(self.run_shell('download_file() { echo BUG-download; }; mp_fetch_core_providers').returncode, 0, path)
            self.assertEqual((self.root/'core/config.yaml').read_text(), text)

    def test_migration_removes_only_old_parameters(self):
        self.file('core/config.yaml', 'private-key: preserved\n')
        self.file('sh/env.local.conf', "MP_SUBSCRIBE_URL='old'\nexport MP_WG_PRIVATE_KEY='old'\nMP_WG_ENABLED=1\nCUSTOM='keep'\nMP_AGH_USER_NAME='admin'\n")
        fn = test_scripts.function_source(test_scripts.ROOT/'sh/migrate-legacy.sh', 'mp_migrate_legacy_config')
        for _ in range(2):
            self.assert_ok(self.run_shell(fn+'\nmp_migrate_legacy_config'))
        self.assertEqual((self.root/'core/config.yaml').read_text(), 'private-key: preserved\n')
        self.assertEqual((self.root/'sh/env.local.conf').read_text(), "CUSTOM='keep'\nMP_AGH_USER_NAME='admin'\n")
        self.assertEqual((self.root/'sh/env.local.conf').stat().st_mode & 0o777, 0o600)

    def prepare(self, source='', target=None, remote=False, extra_script=''):
        self.file('bundle/resources/.test', '')
        target = target or self.root/'target'
        self.file('unused', '')
        script = 'inst_parse_args --no-auth --install-dir '+shlex.quote(str(target))+'\n'
        script += 'INST_CORE_SOURCE='+shlex.quote(source)+'\n'
        script += '. "$TEST_ROOT/sh/common.sh"\n_inst_tmp="$TEST_ROOT"; _ip_bundle="$TEST_ROOT/bundle"\n'
        script += '_MP_CACHE_WRITE="$TEST_ROOT/bundle/resources"\nmp_require_tun() { :; }\n'
        if remote:
            script += 'INST_TARGET=fixture; INST_TARGET_UID=0\ninst_ssh() { shift 2; sh -c "$1"; }\n'
        script += extra_script+'\ninst_prepare_core || exit $?\n'
        script += 'printf "action=%s" "$INST_CORE_ACTION"\n'
        return self.installer(script)

    def test_prepare_empty_fresh_and_preserve_local_or_remote(self):
        for remote in (False, True):
            cfg = self.root/'target/core/config.yaml'
            cfg.unlink(missing_ok=True)
            result = self.prepare(remote=remote)
            self.assert_ok(result)
            self.assertIn('action=empty', result.stdout)
            self.assertEqual((self.root/'bundle/resources/core-config.yaml').read_bytes(), b'{}\n')
            cfg = self.file('target/core/config.yaml', '# already installed\ntun:\n  enable: false\n')
            before = cfg.read_bytes()
            result = self.prepare(remote=remote)
            self.assert_ok(result)
            self.assertIn('action=keep', result.stdout)
            self.assertEqual((self.root/'bundle/resources/core-config.yaml').read_bytes(), before)
            self.assertEqual(cfg.read_bytes(), before)

    def test_prepare_imports_local_file_provider_and_defaults(self):
        source = self.file('source/config.yaml', 'tun:\n  enable: true\nproxy-providers:\n  local:\n    type: file\n    path: proxy/nodes.yaml\n')
        data = self.file('source/proxy/nodes.yaml', 'proxies: []\n')
        result = self.prepare(str(source))
        self.assert_ok(result)
        self.assertIn('action=import', result.stdout)
        self.assertIn('device: utun', (self.root/'bundle/resources/core-config.yaml').read_text())
        self.assertEqual((self.root/'bundle/resources/core-files/proxy/nodes.yaml').read_bytes(), data.read_bytes())
        self.assertNotIn('device:', source.read_text())

    def test_remote_file_provider_is_uploaded_from_existing_install(self):
        self.file('target/core/config.yaml', 'proxy-providers:\n  local:\n    type: file\n    path: proxy/nodes.yaml\n')
        data = self.file('target/core/proxy/nodes.yaml', 'proxies: []\n')
        self.assert_ok(self.prepare(remote=True))
        self.assertEqual((self.root/'bundle/resources/core-files/proxy/nodes.yaml').read_bytes(), data.read_bytes())

    def test_source_download_or_target_read_failure_never_becomes_empty(self):
        for source, script in [('https://example.invalid/config', 'download_file() { return 1; }'),
                               ('', 'inst_read_target_file() { return 255; }'),
                               ('', 'inst_read_target_file() { return 1; }')]:
            self.assertNotEqual(self.prepare(source, extra_script=script).returncode, 0)

    def test_http_source_download_is_independent_of_repo(self):
        result = self.prepare('https://example.invalid/config', extra_script='download_file() { test -z "$_MP_SOURCE_DIR" && printf "dns:\\n  enable: true\\n" > "$2"; }\n_MP_SOURCE_DIR=repo')
        self.assert_ok(result)
        self.assertIn('listen: 127.0.0.1:253', (self.root/'bundle/resources/core-config.yaml').read_text())

    def test_keep_snapshot_detects_changes_before_apply(self):
        cfg = self.file('target/core/config.yaml', 'mixed-port: 7890\n')
        digest = hashlib.sha256(cfg.read_bytes()).hexdigest()
        script = f'DIR_INST="$TEST_ROOT/target"; INST_CORE_ACTION=keep; INST_CORE_SHA={digest}\ninst_check_core_snapshot'
        self.assert_ok(self.installer(script))
        cfg.write_text('mixed-port: 9999\n')
        self.assertNotEqual(self.installer(script).returncode, 0)
        self.assertEqual(cfg.read_text(), 'mixed-port: 9999\n')

    def test_empty_install_retry_keeps_generated_config_but_rejects_other_content(self):
        cfg=self.file('target/core/config.yaml', '{}\n')
        script='DIR_INST="$TEST_ROOT/target"; INST_CORE_ACTION=empty\ninst_check_core_snapshot && test "$INST_CORE_ACTION" = keep'
        self.assert_ok(self.installer(script))
        self.assertEqual(cfg.read_bytes(), b'{}\n')
        cfg.write_text('mixed-port: 7890\n')
        self.assertNotEqual(self.installer(script).returncode, 0)
        self.assertEqual(cfg.read_text(), 'mixed-port: 7890\n')

    def test_inline_dns_lists_and_empty_comment_values_import(self):
        text = 'dns:\n  enable: true\n  listen: # default\n  fake-ip-range: null\n  nameserver: [1.1.1.1, 8.8.8.8]\n'
        self.assert_ok(self.import_config(text))
        result=(self.root/'result.yaml').read_text()
        self.assertIn('listen: 127.0.0.1:253',result)
        self.assertIn('fake-ip-range: 198.18.0.1/16',result)
        self.assertIn('nameserver: [1.1.1.1, 8.8.8.8]',result)

    def test_source_is_never_saved_to_env_or_bundle_and_old_options_rejected(self):
        result = self.installer('inst_parse_args --no-auth --core-config /private/source.yaml\nINST_TARGET_OS=systemd; INST_TARGET_ARCH=x86_64\ninst_save_config "$TEST_ROOT/config.json"')
        self.assert_ok(result)
        data = (self.root/'config.json').read_text()
        self.assertNotIn('/private/source.yaml', data)
        for option in ('--subscribe-url', '--wireguard', '--wg-private-key'):
            self.assertNotEqual(self.installer('inst_parse_args '+option+' secret').returncode, 0)

    def test_invalid_mihomo_config_does_not_log_secret(self):
        self.file('core/config.yaml', '')
        self.file('core/mihomo', '#!/bin/sh\necho PRIVATE-CONFIG-SECRET >&2\nexit 1\n').chmod(0o755)
        result = self.run_shell('mp_init_log "$MP_LOG_FILE" && mp_check_core_binary_config')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('PRIVATE-CONFIG-SECRET', result.stdout+result.stderr+(self.root/'myrule.inst.log').read_text())

    def test_empty_config_launcher_runs_core_without_netlink(self):
        self.file('core/config.yaml', '')
        self.file('core/mihomo', '#!/bin/sh\nprintf started > "$TEST_ROOT/started"\nsleep 30\n').chmod(0o755)
        proc = subprocess.Popen(['sh', str(self.root/'core/start.sh')], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            deadline = time.monotonic()+3
            while not (self.root/'started').exists() and time.monotonic()<deadline:
                time.sleep(.02)
            self.assertTrue((self.root/'started').exists())
            self.assertIsNone(proc.poll())
        finally:
            import signal
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=3)

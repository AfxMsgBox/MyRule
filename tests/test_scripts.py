"""POSIX shell regression tests; fixtures never download or manage real services."""
import os
import gzip
import io
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import tarfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def function_source(path, name):
    """Read an installer function without executing its top-level system changes."""
    source = path.read_text()
    start = source.index(name + "() {")
    end = source.index("\n}", start) + 2
    return source[start:end]


class ShellTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / "sh", self.root / "sh")
        for directory in ("core", "agh", "fixtures", "commands"):
            (self.root / directory).mkdir()
        self.env = {"PATH": str(self.root / "commands") + os.pathsep + os.environ["PATH"],
                    "MP_INST_DIR": str(self.root), "TEST_ROOT": str(self.root),
                    "MP_SUBSCRIBE_URL": "https://example.invalid/sub?target=clash",
                    "MP_AGH_USER_NAME": "test", "MP_AGH_PASSWORD": "$2a$10$test"}
        self.command("logger", "exit 0\n")
        # Unexpected network/service use fails closed in every test.
        for command in ("curl", "systemctl", "service", "sysctl", "crontab", "ip",
                        "apt-get", "opkg", "apk"):
            self.command(command, "echo unexpected-command >&2; exit 99\n")

    def command(self, name, script):
        path = self.root / "commands" / name
        path.write_text("#!/bin/sh\n" + script)
        path.chmod(0o755)

    def run_shell(self, script, *, source=True, extra=None):
        prefix = '. "$MP_INST_DIR/sh/common.sh"\n' if source else ""
        return subprocess.run(["sh", "-c", prefix + script], env=self.env | (extra or {}),
                              cwd=self.root, text=True, capture_output=True, timeout=10)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def file(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def add_common(self, script):
        with (self.root / "sh/common.sh").open("a") as stream:
            stream.write("\n" + script + "\n")

    def configure_downloads(self):
        self.file("fixtures/core.yaml", (ROOT / "core/config.yaml").read_text())
        self.file("fixtures/agh.yaml", (ROOT / "agh/agh.yaml").read_text())
        self.file("fixtures/payload", "payload:\n  - '+.example.org'\n  - '+.bj'\n")
        self.add_common(r'''
download_file() {
    printf '%s\n' "$1" >> "$TEST_ROOT/downloads"
    case "$1" in
        */core/config.yaml) cp "$TEST_ROOT/fixtures/core.yaml" "$2" ;;
        */agh/agh.yaml) cp "$TEST_ROOT/fixtures/agh.yaml" "$2" ;;
        */myupstream.txt) printf '[/local.test/]1.1.1.1\n' > "$2" ;;
        *) cp "$TEST_ROOT/fixtures/payload" "$2" ;;
    esac
}
''')

    def configure_services(self):
        self.add_common(r'''
mp_service_op() {
    printf '%s %s\n' "$1" "$2" >> "$TEST_ROOT/events"
    if [ "$1 $2" = 'stop agh' ]; then
        cat "$MP_CORE_DIR/config.yaml" > "$TEST_ROOT/core-at-stop" 2>/dev/null || :
        cat "$MP_AGH_DIR/agh.yaml" > "$TEST_ROOT/agh-at-stop" 2>/dev/null || :
    fi
    [ "$1 $2" != "${TEST_SERVICE_FAIL:-}" ]
}
mp_wait_core_ready() {
    printf 'ready\n' >> "$TEST_ROOT/events"
    [ "${TEST_READY_FAIL:-0}" = 0 ]
}
mp_sync_etc_files() { printf 'sync %s\n' "$1" >> "$TEST_ROOT/events"; }
''')

    def test_dns_environment_priority_and_empty(self):
        for local, caller, expected in [
            (None, None, "223.5.5.5 119.29.29.29"),
            ("", None, ""), ("1.1.1.1", None, "1.1.1.1"),
            ("1.1.1.1", "", ""), ("1.1.1.1", "9.9.9.9", "9.9.9.9")
        ]:
            with self.subTest(local=local, caller=caller):
                path = self.root / "sh/env.local.conf"
                path.unlink(missing_ok=True)
                if local is not None:
                    path.write_text("MP_LOCAL_DNS=" + shlex.quote(local) + "\n")
                result = self.run_shell('printf "%s" "$MP_LOCAL_DNS"',
                                        extra={} if caller is None else {"MP_LOCAL_DNS": caller})
                self.assert_ok(result)
                self.assertEqual(result.stdout, expected)

    def test_agh_auth_rendering_and_escaping(self):
        self.file("template", (ROOT / "agh/agh.yaml").read_text())
        username = "a\"b\\c{MP_INST_DIR}"
        for password in ("", "$2b$10$test"):
            result = self.run_shell('mp_render_template "$TEST_ROOT/template" "$TEST_ROOT/rendered" agh',
                                    extra={"MP_AGH_PASSWORD": password, "MP_AGH_USER_NAME": username})
            self.assert_ok(result)
            rendered = (self.root / "rendered").read_text()
            users = next(line[7:] for line in rendered.splitlines() if line.startswith("users: "))
            self.assertEqual(json.loads(users), [] if not password else [{"name": username, "password": password}])
            self.assertNotIn("{MP_AGH_PASSWORD}", rendered)

    def test_agh_invalid_auth_or_users_block_preserves_destination(self):
        cases = [("users: []\n", "plaintext"), ("dns: {}\n", ""),
                 ("users: []\nusers: []\n", "")]
        for template, password in cases:
            self.file("template", template)
            self.file("rendered", "old configuration")
            result = self.run_shell('mp_render_template "$TEST_ROOT/template" "$TEST_ROOT/rendered" agh',
                                    extra={"MP_AGH_PASSWORD": password})
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((self.root / "rendered").read_text(), "old configuration")

    def test_agh_update_keeps_persisted_no_auth(self):
        self.configure_downloads()
        self.file("sh/env.local.conf", "MP_AGH_PASSWORD=''\nMP_AGH_USER_NAME='admin'\n")
        self.env.pop("MP_AGH_PASSWORD")
        self.env.pop("MP_AGH_USER_NAME")
        result = self.run_shell('sh "$MP_INST_DIR/sh/update-core-config.sh" && '
                                'mp_prepare_agh_config "$MP_AGH_DIR/agh.yaml" "$MP_CORE_DIR/config.yaml"')
        self.assert_ok(result)
        self.assertIn("users: []\n", (self.root / "agh/agh.yaml").read_text())

    def test_installer_dns_prompt_preserves_or_clears(self):
        source = (ROOT / "sh/install-lib.sh").read_text()
        start = source.index('    prompt_to MP_LOCAL_DNS')
        block = source[start:source.index('    return 0', start)]
        for current, answer, expected in [("", "", ""), ("1.1.1.1", "", "1.1.1.1"),
                                           ("1.1.1.1", "-", ""), ("", "9.9.9.9", "9.9.9.9")]:
            with self.subTest(current=current, answer=answer):
                result = self.run_shell(
                    'prompt_to() { MP_LOCAL_DNS="${TEST_ANSWER:-$2}"; }\n' + block
                    + '\nprintf "%s" "$MP_LOCAL_DNS"', source=False,
                    extra={"MP_LOCAL_DNS": current, "TEST_ANSWER": answer})
                self.assert_ok(result)
                self.assertEqual(result.stdout, expected)

    def test_config_persistence_preserves_quotes_backslashes_and_hash(self):
        value = "$2a$10$test'quoted\\text"
        result = self.run_shell(
            function_source(ROOT / "sh/install-lib.sh", "upsert_conf") + r'''
upsert_conf TEST_VALUE "$TEST_VALUE" "$TEST_ROOT/local.conf" || exit 1
upsert_conf TEST_VALUE "$TEST_VALUE" "$TEST_ROOT/local.conf" || exit 1
unset TEST_VALUE
. "$TEST_ROOT/local.conf"
printf '%s' "$TEST_VALUE"
''', source=False, extra={"TEST_VALUE": value})
        self.assert_ok(result)
        self.assertEqual(result.stdout, value)

    def test_branch_template_and_dns_sources_match(self):
        self.configure_downloads()
        result = self.run_shell('sh "$MP_INST_DIR/sh/update-core-config.sh" && '
                                'sh "$MP_INST_DIR/sh/update-agh-config.sh"',
                                extra={"MP_REPO_BRANCH": "feature/dev"})
        self.assert_ok(result)
        rendered = (self.root / "core/config.yaml").read_text()
        self.assertIn('url: "https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/feature/dev/domain/gpt.txt"', rendered)
        self.assertEqual((self.root / "downloads").read_text().count(
            "https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/feature/dev/domain/gpt.txt"), 2)

    def prepare_pending(self):
        self.file("core/config.yaml", "old-core")
        self.file("agh/agh.yaml", "old-agh")
        self.file("agh/dns.conf", "old-dns")
        self.file("core/config.yaml.pending", "new-core")
        self.file("agh/agh.yaml.pending", "new-agh")
        self.file("agh/dns.conf.pending", "new-dns")
        self.configure_services()

    def activate(self, extra=None):
        return self.run_shell('mp_activate_configs enable_restart '
                              '"$MP_CORE_DIR/config.yaml.pending" "$MP_AGH_DIR/dns.conf.pending"',
                              extra=extra)

    def test_activation_order(self):
        self.prepare_pending()
        self.assert_ok(self.activate())
        self.assertEqual((self.root / "events").read_text().splitlines(),
                         ["stop agh", "enable_restart proxy_core", "ready", "enable_restart agh"])
        self.assertEqual((self.root / "core-at-stop").read_text(), "old-core")
        self.assertEqual((self.root / "agh-at-stop").read_text(), "old-agh")
        self.assertEqual((self.root / "core/config.yaml").read_text(), "new-core")
        self.assertEqual((self.root / "agh/agh.yaml").read_text(), "new-agh")

    def test_activation_stop_failure_preserves_configs(self):
        self.prepare_pending()
        self.assertNotEqual(self.activate({"TEST_SERVICE_FAIL": "stop agh"}).returncode, 0)
        self.assertEqual((self.root / "core/config.yaml").read_text(), "old-core")
        self.assertEqual((self.root / "agh/agh.yaml").read_text(), "old-agh")
        self.assertEqual((self.root / "events").read_text(), "stop agh\n")

    def test_activation_missing_pending_does_not_stop_services(self):
        self.prepare_pending()
        (self.root / "agh/dns.conf.pending").unlink()
        self.assertNotEqual(self.activate().returncode, 0)
        self.assertFalse((self.root / "events").exists())

    def test_activation_commit_failure_does_not_restart(self):
        self.prepare_pending()
        self.command("mv", "exit 1\n")
        self.assertNotEqual(self.activate().returncode, 0)
        self.assertEqual((self.root / "events").read_text(), "stop agh\n")
        self.assertEqual((self.root / "core/config.yaml").read_text(), "old-core")

    def test_activation_core_failure_keeps_agh_stopped(self):
        self.prepare_pending()
        self.assertNotEqual(self.activate({"TEST_SERVICE_FAIL": "enable_restart proxy_core"}).returncode, 0)
        self.assertEqual((self.root / "events").read_text().splitlines(),
                         ["stop agh", "enable_restart proxy_core"])

    def test_activation_readiness_failure_keeps_agh_stopped(self):
        self.prepare_pending()
        self.assertNotEqual(self.activate({"TEST_READY_FAIL": "1"}).returncode, 0)
        self.assertNotIn("enable_restart agh", (self.root / "events").read_text())

    def test_binary_install_success(self):
        self.file("new-binary", "new")
        self.file("core/mihomo", "old")
        self.assert_ok(self.run_shell('mp_install_binary new-binary "$MP_CORE_DIR/mihomo"'))
        self.assertEqual((self.root / "core/mihomo").read_text(), "new")
        self.assertEqual((self.root / "core/mihomo").stat().st_mode & 0o777, 0o755)

    def test_binary_failures_preserve_old_file(self):
        self.file("new-binary", "new")
        for command in ("cp", "chmod", "mv", "mkdir"):
            with self.subTest(command=command):
                self.file("core/mihomo", "old")
                self.command(command, "exit 1\n")
                result = self.run_shell('mp_install_binary new-binary "$MP_CORE_DIR/mihomo"')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.root / "core/mihomo").read_text(), "old")
                (self.root / "commands" / command).unlink()

    def test_ui_copy_failure_preserves_old_directory(self):
        self.file("new-ui/index.html", "new")
        self.file("core/ui/index.html", "old")
        self.command("cp", "exit 1\n")
        result = self.run_shell('mp_install_ui new-ui "$MP_CORE_DIR/ui"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "core/ui/index.html").read_text(), "old")

    def test_ui_rename_failure_restores_old_directory(self):
        self.file("new-ui/index.html", "new")
        self.file("core/ui/index.html", "old")
        self.command("mv", 'case "$1" in */new) exit 1;; esac\nexec /bin/mv "$@"\n')
        result = self.run_shell('mp_install_ui new-ui "$MP_CORE_DIR/ui"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "core/ui/index.html").read_text(), "old")

    def test_ui_success_removes_stale_assets(self):
        self.file("new-ui/index.html", "new")
        self.file("core/ui/index.html", "old")
        self.file("core/ui/stale.js", "old")
        self.assert_ok(self.run_shell('mp_install_ui new-ui "$MP_CORE_DIR/ui"'))
        self.assertEqual((self.root / "core/ui/index.html").read_text(), "new")
        self.assertFalse((self.root / "core/ui/stale.js").exists())

    def test_dns_final_move_failure_propagates(self):
        self.configure_downloads()
        self.file("core/config.yaml", (ROOT / "core/config.yaml").read_text())
        self.file("agh/dns.conf", "old-dns")
        self.command("mv", 'case "$2" in */dns.conf) exit 1;; esac\nexec /bin/mv "$@"\n')
        result = self.run_shell('sh "$MP_INST_DIR/sh/update-agh-config.sh"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "agh/dns.conf").read_text(), "old-dns")
        self.assertNotIn("生成完成", result.stdout)

    def test_route_failure_and_missing_old_route(self):
        self.file("core/config.yaml", (ROOT / "core/config.yaml").read_text())
        self.file("sys/class/net/utun/ifindex", "7\n")
        self.file("proc/sys/kernel/random/boot_id", "11111111-1111-1111-1111-111111111111\n")
        script = self.root / "sh/setup-fake-ip-route.sh"
        script.write_text(script.read_text().replace("/sys/class/net/", str(self.root / "sys/class/net") + "/")
                          .replace("/proc/sys/kernel/random/boot_id", str(self.root / "proc/sys/kernel/random/boot_id")))
        self.command("ip", 'case "$1 $2" in "link show") exit 0;; "route del") exit 1;; '
                           '"route replace") exit "$TEST_ROUTE_RC";; esac\n')
        for status in ("0", "1"):
            with self.subTest(status=status):
                result = self.run_shell('sh "$MP_INST_DIR/sh/setup-fake-ip-route.sh"',
                                        extra={"TEST_ROUTE_RC": status})
                self.assertEqual(result.returncode, int(status), result.stderr)
                self.assertEqual((self.root / "core/.fake-ip-route").read_text(),
                                 "198.18.0.0/16 utun 7 11111111-1111-1111-1111-111111111111\n")

    def run_install_flow(self, *, reinstall, answer="Y", fail_download=False):
        self.configure_downloads()
        self.configure_services()
        if reinstall:
            self.file("core/config.yaml", "old-core")
            self.file("agh/agh.yaml", "old-agh")
            self.file("agh/dns.conf", "old-dns")
        # Binary deployment is covered separately; verify the installer supplies pending config.
        self.file("sh/update-bin.sh", 'test "$1" = "$MP_INST_DIR/core/config.yaml.pending"\n')
        if fail_download:
            self.add_common('download_file() { return 1; }')
        source = (ROOT / "sh/install-lib.sh").read_text()
        flow = source[source.index('# === 三份配置'):source.index('    inst_apply_schedule')]
        setup = r'''
DIR_INST="$MP_INST_DIR"; DIR_SH="$MP_INST_DIR/sh"
os_type=systemd; etc_rels='systemd/system/agh.service'
say_section() { :; }; say_step() { :; }; say_dim() { :; }
say_ok() { :; }; say_err() { echo "$*"; }
autostart="$TEST_AUTOSTART"
reinstall="$TEST_REINSTALL"
'''
        return self.run_shell(setup + flow, extra={"TEST_AUTOSTART": answer,
                                                  "TEST_REINSTALL": str(int(reinstall))})

    def test_reinstall_decline_keeps_three_formal_configs(self):
        self.assert_ok(self.run_install_flow(reinstall=True, answer="n"))
        for relative, old in [("core/config.yaml", "old-core"),
                              ("agh/agh.yaml", "old-agh"), ("agh/dns.conf", "old-dns")]:
            self.assertEqual((self.root / relative).read_text(), old)
            self.assertTrue((self.root / (relative + ".pending")).exists())
        self.assertFalse((self.root / "events").exists())

    def test_reinstall_accept_restarts_with_new_configs(self):
        self.assert_ok(self.run_install_flow(reinstall=True))
        self.assertEqual((self.root / "core-at-stop").read_text(), "old-core")
        self.assertEqual((self.root / "agh-at-stop").read_text(), "old-agh")
        self.assertIn("mixed-port: 7890", (self.root / "core/config.yaml").read_text())
        self.assertEqual((self.root / "events").read_text().splitlines(),
                         ["sync always", "stop agh", "enable_restart proxy_core", "ready", "enable_restart agh"])

    def test_fresh_install_decline_writes_configs_without_services(self):
        self.assert_ok(self.run_install_flow(reinstall=False, answer="n"))
        for relative in ("core/config.yaml", "agh/agh.yaml", "agh/dns.conf"):
            self.assertTrue((self.root / relative).is_file())
            self.assertFalse((self.root / (relative + ".pending")).exists())
        self.assertFalse((self.root / "events").exists())

    def test_fresh_install_accept_does_not_stop_nonexistent_service(self):
        self.assert_ok(self.run_install_flow(reinstall=False))
        self.assertEqual((self.root / "events").read_text().splitlines(),
                         ["sync always", "enable_start proxy_core", "ready", "enable_start agh"])

    def test_reinstall_download_failure_preserves_running_configs(self):
        result = self.run_install_flow(reinstall=True, fail_download=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "core/config.yaml").read_text(), "old-core")
        self.assertEqual((self.root / "agh/agh.yaml").read_text(), "old-agh")
        self.assertFalse((self.root / "events").exists())

    def test_download_only_update_has_documented_commit_boundary(self):
        self.configure_downloads()
        self.configure_services()
        self.file("core/config.yaml", "old-core")
        self.file("agh/agh.yaml", "old-agh")
        self.file("agh/dns.conf", "old-dns")
        self.assert_ok(self.run_shell('sh "$MP_INST_DIR/sh/update-all-configs.sh"'))
        self.assertIn("mixed-port: 7890", (self.root / "core/config.yaml").read_text())
        self.assertNotEqual((self.root / "agh/dns.conf").read_text(), "old-dns")
        self.assertEqual((self.root / "agh/agh.yaml").read_text(), "old-agh")
        self.assertTrue((self.root / "agh/agh.yaml.pending").is_file())
        self.assertFalse((self.root / "events").exists())

    def test_update_failure_skips_restart(self):
        self.configure_services()
        self.add_common('download_file() { return 1; }')
        self.file("core/config.yaml", "old-core")
        self.file("agh/agh.yaml", "old-agh")
        result = self.run_shell('sh "$MP_INST_DIR/sh/update-all-configs-restart-services.sh"')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "events").exists())
        self.assertEqual((self.root / "core/config.yaml").read_text(), "old-core")
        self.assertFalse((self.root / "core/config.yaml.pending").exists())

    def test_enable_restart_platform_dispatch(self):
        # Redirect the systemd unit directory in this test copy, never touching real /etc.
        common = self.root / "sh/common.sh"
        common.write_text(common.read_text().replace('/etc/systemd/system', str(self.root / "systemd")))
        self.file("systemd/proxy_core.service", "[Service]\n")
        for platform in ("systemd", "openwrt"):
            with self.subTest(platform=platform):
                result = self.run_shell(r'''
mp_detect_os() { printf '%s\n' "$TEST_PLATFORM"; }
systemctl() { printf 'systemctl %s\n' "$*"; }
service() { printf 'service %s\n' "$*"; }
mp_service_op enable_restart proxy_core
''', extra={"TEST_PLATFORM": platform})
                self.assert_ok(result)
                if platform == "systemd":
                    self.assertEqual(result.stdout, "systemctl restart proxy_core.service\n")
                    self.assertTrue((self.root / "systemd/multi-user.target.wants/proxy_core.service").is_symlink())
                else:
                    self.assertEqual(result.stdout, "service proxy_core enable\nservice proxy_core restart\n")

    def make_binary_fixtures(self):
        self.file("fixtures/release.json", '{"tag_name":"test-version"}')
        (self.root / "fixtures/mihomo.gz").write_bytes(gzip.compress(b"new-mihomo"))
        for archive, name, content in [("ui.tgz", "index.html", b"new-ui"),
                                       ("agh.tgz", "AdGuardHome/AdGuardHome", b"new-agh")]:
            with tarfile.open(self.root / "fixtures" / archive, "w:gz") as tar:
                info = tarfile.TarInfo(name)
                info.size = len(content)
                info.mode = 0o755
                tar.addfile(info, io.BytesIO(content))
        self.add_common(r'''
download_file() {
    case "$1" in
        */releases/latest) fixture=release.json ;;
        *mihomo-linux-*) fixture=mihomo.gz ;;
        */compressed-dist.tgz) fixture=ui.tgz ;;
        *AdGuardHome_linux_*) fixture=agh.tgz ;;
        *) return 1 ;;
    esac
    cp "$TEST_ROOT/fixtures/$fixture" "$2"
}
''')
        self.command("uname", "echo x86_64\n")
        self.file("core/config.yaml", "external-ui: old-ui\n")
        self.file("core/config.yaml.pending", "external-ui: next-ui\n")

    def test_binary_updater_uses_pending_ui_path(self):
        self.make_binary_fixtures()
        self.assert_ok(self.run_shell('sh "$MP_INST_DIR/sh/update-bin.sh" "$MP_CORE_DIR/config.yaml.pending"'))
        self.assertEqual((self.root / "core/mihomo").read_text(), "new-mihomo")
        self.assertEqual((self.root / "agh/AdGuardHome").read_text(), "new-agh")
        self.assertEqual((self.root / "core/next-ui/index.html").read_text(), "new-ui")
        self.assertFalse((self.root / "core/old-ui").exists())

    def test_binary_updater_install_failure_returns_nonzero(self):
        self.make_binary_fixtures()
        self.file("core/mihomo", "old-mihomo")
        self.command("mv", 'case "$2" in */mihomo) exit 1;; esac\nexec /bin/mv "$@"\n')
        result = self.run_shell('sh "$MP_INST_DIR/sh/update-bin.sh"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "core/mihomo").read_text(), "old-mihomo")
        self.assertNotIn("mihomo test-version / linux-amd64 已就位", result.stdout)


if __name__ == "__main__":
    unittest.main()

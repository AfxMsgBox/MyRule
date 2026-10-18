"""Run the uninstaller against fake /etc, /proc and service managers only."""
import os
import pty
import select
import shutil
import subprocess
import time
import unittest

import test_scripts


ROOT = test_scripts.ROOT


class UninstallTests(unittest.TestCase):
    setUp_base = test_scripts.ShellTests.setUp
    command = test_scripts.ShellTests.command
    file = test_scripts.ShellTests.file
    assert_ok = test_scripts.ShellTests.assert_ok
    run_shell = test_scripts.ShellTests.run_shell

    def setUp(self):
        self.setUp_base()
        self.target = self.root / "installed"
        self.etc = self.root / "etc"
        self.proc = self.root / "proc"
        self.file("proc/self/mountinfo", "")
        self.file("proc/sys/kernel/random/boot_id", "11111111-1111-1111-1111-111111111111\n")
        self.file("installed/sh/env.local.conf", f"MP_INST_DIR='{self.target}'\n")
        self.file("installed/core/config.yaml", "test config")
        self.file("installed/agh/agh.yaml", "test config")
        self.file("installed/keep.txt", "unrelated")
        source = (ROOT / "sh/uninstall.sh").read_text()
        source = source.replace('un_etc=/etc; un_proc=/proc',
                                'un_etc="$TEST_ROOT/etc"; un_proc="$TEST_ROOT/proc"')
        source = source.replace('un_sys=/sys', 'un_sys="$TEST_ROOT/sys"')
        self.script = self.file("uninstall.sh", source)
        self.file("installed/sh/uninstall.sh", source)
        self.command("id", "echo 0\n")
        self.command("systemctl", r'''
case "$1" in
    show)
        [ "${FAIL_SHOW:-0}" = 0 ] || exit 1
        for arg in "$@"; do svc=$arg; done
        unit="$TEST_ROOT/etc/systemd/system/$svc"
        if [ -f "$unit" ]; then
            printf 'LoadState=loaded\nFragmentPath=%s\nDropInPaths=%s\n' "${MOCK_FRAGMENT:-$unit}" "${MOCK_DROPINS:-}"
        else
            printf 'LoadState=not-found\nFragmentPath=\nDropInPaths=\n'
            exit 1
        fi
        ;;
    stop|daemon-reload)
        printf 'systemctl %s\n' "$*" >> "$TEST_ROOT/events"
        [ "$*" != "${FAIL_ACTION:-}" ] ;;
    *) echo unexpected-systemctl >&2; exit 99 ;;
esac
''')
        self.command("service", r'''
printf 'service %s\n' "$*" >> "$TEST_ROOT/events"
[ "$*" != "${FAIL_ACTION:-}" ]
''')
        self.command("crontab", r'''
if [ "$1" = -l ]; then
    if [ "${FAIL_CRON_READ:-0}" = 1 ]; then echo permission-denied >&2; exit 1; fi
    if [ ! -f "$TEST_ROOT/crontab" ]; then echo 'no crontab for root' >&2; exit 1; fi
    cat "$TEST_ROOT/crontab"
else
    printf 'crontab write\n' >> "$TEST_ROOT/events"
    [ "${FAIL_CRON_WRITE:-0}" = 0 ] || exit 1
    cp "$1" "$TEST_ROOT/crontab"
fi
''')
        self.platform("systemd")

    def forward_snapshot(self, *, platform="systemd", before=None, runtime="0"):
        relative = "etc/sysctl.conf" if platform == "openwrt" else "etc/sysctl.d/99-zz-myproxy.conf"
        config = self.root / relative
        if before is not None:
            self.file(relative, before)
        self.file("proc/sys/net/ipv4/ip_forward", runtime + "\n")
        source = test_scripts.function_source(ROOT / "sh/inst.sh", "inst_record_forward_state")
        source = source.replace("/proc/sys/net/ipv4/ip_forward", str(self.proc / "sys/net/ipv4/ip_forward"))
        # A new installation has not written env.local.conf yet.
        local = self.target / "sh/env.local.conf"
        contents = local.read_text()
        local.unlink()
        self.assert_ok(self.run_shell(source + '''
say_err() { echo "$*" >&2; }; say_warn() { echo "$*"; }
DIR_INST="$TEST_ROOT/installed"; DIR_SH="$DIR_INST/sh"; reinstall=0
os_type=$TEST_OS; sysctl_conf=$TEST_CONF
inst_record_forward_state
''', source=False, extra={"TEST_OS": platform, "TEST_CONF": str(config)}))
        local.write_text(contents)
        state = self.target / "sh/.install-state/forward"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_bytes((state / "after").read_bytes())
        self.file("proc/sys/net/ipv4/ip_forward", "1\n")
        self.command("sysctl", '''
printf 'sysctl %s\n' "$*" >> "$TEST_ROOT/events"
[ "${FAIL_SYSCTL:-0}" = 0 ] || exit 1
[ "$*" = '-w net.ipv4.ip_forward=0' ] || exit 99
printf '0\n' > "$TEST_ROOT/proc/sys/net/ipv4/ip_forward"
''')
        return config, state

    def test_restore_installer_sysctl_and_leave_packages_untouched(self):
        config, state = self.forward_snapshot()
        for manager in ("apk", "opkg", "apt-get"):
            self.command(manager, 'echo package-operation >> "$TEST_ROOT/events"; exit 99\n')
        self.assert_ok(self.run_uninstall())
        self.assertFalse(config.exists())
        self.assertTrue((state / "restored").exists())
        self.assertEqual((self.proc / "sys/net/ipv4/ip_forward").read_text(), "0\n")
        self.assertNotIn("package-operation", self.events())
        count = len(self.events())
        self.assert_ok(self.run_uninstall())
        self.assertNotIn("sysctl -w net.ipv4.ip_forward=0", self.events()[count:])

    def test_openwrt_restores_original_file_and_forwarding(self):
        self.platform("openwrt")
        original = "# original\nnet.ipv4.ip_forward = 0\nother=1\n"
        config, _ = self.forward_snapshot(platform="openwrt", before=original)
        self.assert_ok(self.run_uninstall("--purge"))
        self.assertEqual(config.read_text(), original)
        self.assertFalse((self.target / "sh").exists())
        self.assertNotIn("service cron stop", self.events())

    def test_forwarding_already_enabled_before_install_is_preserved(self):
        config, _ = self.forward_snapshot(before="net.ipv4.ip_forward=1\n", runtime="1")
        self.assert_ok(self.run_uninstall())
        self.assertEqual(config.read_text(), "net.ipv4.ip_forward=1\n")
        self.assertFalse(any(event.startswith("sysctl ") for event in self.events()))

    def test_reinstall_preserves_first_snapshot_and_rebases_after_uninstall(self):
        config, state = self.forward_snapshot()
        source = test_scripts.function_source(ROOT / "sh/inst.sh", "inst_record_forward_state")
        source = source.replace("/proc/sys/net/ipv4/ip_forward", str(self.proc / "sys/net/ipv4/ip_forward"))
        call = source + '''
say_err() { echo "$*" >&2; }; say_warn() { echo "$*"; }
DIR_INST="$TEST_ROOT/installed"; DIR_SH="$DIR_INST/sh"; reinstall=1
os_type=systemd; sysctl_conf=$TEST_CONF
inst_record_forward_state
'''
        self.assert_ok(self.run_shell(call, source=False, extra={"TEST_CONF": str(config)}))
        self.assertEqual((state / "runtime").read_text(), "0\n")
        self.assertEqual((state / "existed").read_text(), "0\n")
        self.assert_ok(self.run_uninstall())
        config.write_text("# new baseline\nnet.ipv4.ip_forward=1\n")
        self.file("proc/sys/net/ipv4/ip_forward", "1\n")
        self.assert_ok(self.run_shell(call, source=False, extra={"TEST_CONF": str(config)}))
        self.assertEqual((state / "before").read_text(), config.read_text())
        self.assertEqual((state / "runtime").read_text(), "1\n")
        self.assertFalse((state / "restored").exists())

    def test_modified_sysctl_aborts_before_service_changes(self):
        config, _ = self.forward_snapshot()
        config.write_text("net.ipv4.ip_forward=1\nuser_added=1\n")
        result = self.run_uninstall("--purge")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(), [])
        self.assertIn("user_added=1", config.read_text())
        self.assertTrue((self.target / "sh/env.local.conf").exists())

    def test_failed_forward_restore_keeps_record_and_data_for_retry(self):
        _, state = self.forward_snapshot()
        self.assertNotEqual(self.run_uninstall("--purge", extra={"FAIL_SYSCTL": "1"}).returncode, 0)
        self.assertTrue((state / "runtime").exists())
        self.assertFalse((state / "restored").exists())
        self.assertTrue((self.target / "sh/env.local.conf").exists())
        self.assert_ok(self.run_uninstall("--purge"))

    def test_only_recorded_route_on_same_interface_is_deleted(self):
        record = "198.18.0.0/16 utun 7 11111111-1111-1111-1111-111111111111\n"
        self.file("installed/core/.fake-ip-route", record)
        index = self.file("sys/class/net/utun/ifindex", "8\n")
        self.command("ip", '''
printf 'ip %s\n' "$*" >> "$TEST_ROOT/events"
case "$*" in
    '-4 route show exact 198.18.0.0/16 dev utun') echo '198.18.0.0/16 dev utun scope link' ;;
    '-4 route del 198.18.0.0/16 dev utun') ;;
    *) exit 99 ;;
esac
''')
        self.assert_ok(self.run_uninstall())
        self.assertFalse(any(event.startswith("ip ") for event in self.events()))
        self.file("installed/core/.fake-ip-route", record)
        index.write_text("7\n")
        self.assert_ok(self.run_uninstall())
        self.assertIn("ip -4 route del 198.18.0.0/16 dev utun", self.events())

    def test_route_record_from_previous_boot_does_not_delete_reused_interface(self):
        self.file("installed/core/.fake-ip-route", "198.18.0.0/16 utun 7 22222222-2222-2222-2222-222222222222\n")
        self.file("sys/class/net/utun/ifindex", "7\n")
        self.assert_ok(self.run_uninstall())
        self.assertFalse((self.target / "core/.fake-ip-route").exists())

    def test_no_arguments_asks_about_files_before_final_confirmation(self):
        source = self.script.read_text().replace("un_dir=/etc/proxy;", f"un_dir={self.target};")
        self.script.write_text(source)
        for choice, confirm in ((b"\n", b"y\n"), (b"y\n", b"\n"), (b"y\n", b"y\n")):
            events_before = self.events()
            pid, fd = pty.fork()
            if pid == 0:
                os.execvpe("sh", ["sh", str(self.script)], self.env)
            output = b""
            prompts = [("是否删除安装文件和数据？".encode(), choice), ("确认卸载？".encode(), confirm)]
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if select.select([fd], [], [], 0.1)[0]:
                        try:
                            data = os.read(fd, 65536)
                        except OSError:
                            break
                        if not data:
                            break
                        output += data
                    if prompts and prompts[0][0] in output:
                        os.write(fd, prompts.pop(0)[1])
                else:
                    os.kill(pid, 9)
                    self.fail("interactive uninstall timed out")
            finally:
                os.close(fd)
                _, status = os.waitpid(pid, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode())
            self.assertEqual(prompts, [])
            if confirm == b"\n":
                self.assertEqual(self.events(), events_before)
            self.assertEqual((self.target / "sh/env.local.conf").exists(),
                             not (choice == b"y\n" and confirm == b"y\n"))

    def platform(self, platform):
        if platform == "systemd":
            for service in ("agh", "proxy_core"):
                template = (ROOT / f"sh/etc/systemd/system/{service}.service").read_text()
                self.file(f"etc/systemd/system/{service}.service", template.replace("/etc/proxy", str(self.target)))
                link = self.etc / f"systemd/system/multi-user.target.wants/{service}.service"
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(f"../{service}.service")
        else:
            shutil.rmtree(self.etc / "systemd")
            self.file("etc/openwrt_release", "OpenWrt")
            for service in ("agh", "proxy_core"):
                template = (ROOT / f"sh/etc/init.d/{service}").read_text()
                self.file(f"etc/init.d/{service}", template.replace("/etc/proxy", str(self.target)))
                for prefix in ("S99", "K01"):
                    link = self.etc / f"rc.d/{prefix}{service}"
                    link.parent.mkdir(parents=True, exist_ok=True)
                    link.symlink_to(f"../init.d/{service}")
            template = (ROOT / "sh/etc/hotplug.d/net/99-meta-route").read_text()
            self.file("etc/hotplug.d/net/99-meta-route", template.replace("/etc/proxy", str(self.target)))

    def run_uninstall(self, *args, extra=None, yes=True, script=None, directory=None):
        command = ["sh", str(script or self.script), "--install-dir", str(directory or self.target)]
        if yes:
            command.append("--yes")
        return subprocess.run(command + list(args), env=self.env | (extra or {}), cwd=self.root,
                              capture_output=True, text=True, timeout=10, start_new_session=True)

    def events(self):
        path = self.root / "events"
        return path.read_text().splitlines() if path.exists() else []

    def test_systemd_default_keeps_data_and_forwarding(self):
        forward = self.file("etc/sysctl.d/99-zz-myproxy.conf", "net.ipv4.ip_forward=1\n")
        result = self.run_uninstall()
        self.assert_ok(result)
        self.assertEqual(self.events(), ["systemctl stop agh.service", "systemctl stop proxy_core.service",
                                         "systemctl daemon-reload"])
        self.assertTrue((self.target / "core/config.yaml").exists())
        self.assertTrue((self.target / "sh/env.local.conf").exists())
        self.assertEqual(forward.read_text(), "net.ipv4.ip_forward=1\n")
        self.assertFalse(list((self.etc / "systemd").rglob("*.service")))

    def test_openwrt_removes_services_links_hotplug_keeps_sysctl(self):
        self.platform("openwrt")
        sysctl = self.file("etc/sysctl.conf", "net.ipv4.ip_forward=1\nother=1\n")
        result = self.run_uninstall()
        self.assert_ok(result)
        self.assertEqual(self.events(), ["service agh stop", "service proxy_core stop",
                                         "service agh disable", "service proxy_core disable"])
        self.assertEqual(list((self.etc / "rc.d").iterdir()), [])
        self.assertFalse((self.etc / "init.d/agh").exists())
        self.assertFalse((self.etc / "hotplug.d/net/99-meta-route").exists())
        self.assertEqual(sysctl.read_text(), "net.ipv4.ip_forward=1\nother=1\n")

    def test_purge_deletes_only_managed_subdirectories_and_can_delete_itself(self):
        result = self.run_uninstall("--purge", script=self.target / "sh/uninstall.sh")
        self.assert_ok(result)
        self.assertEqual(sorted(path.name for path in self.target.iterdir()), ["keep.txt"])
        self.assertEqual((self.target / "keep.txt").read_text(), "unrelated")
        self.assert_ok(self.run_uninstall("--purge"))

    def test_no_terminal_requires_explicit_yes_before_mutation(self):
        result = self.run_uninstall("--purge", yes=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--yes", result.stderr)
        self.assertEqual(self.events(), [])
        self.assertTrue((self.etc / "systemd/system/agh.service").exists())

    def test_interactive_default_cancel_and_explicit_yes(self):
        for answer in (b"\n", b"y\n"):
            pid, fd = pty.fork()
            if pid == 0:
                os.execvpe("sh", ["sh", str(self.script), "--install-dir", str(self.target)], self.env)
            output = b""
            answered = False
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if select.select([fd], [], [], 0.1)[0]:
                        try:
                            data = os.read(fd, 65536)
                        except OSError:
                            break
                        if not data:
                            break
                        output += data
                    if not answered and '确认卸载？'.encode() in output:
                        os.write(fd, answer)
                        answered = True
                else:
                    os.kill(pid, 9)
                    self.fail("interactive uninstall timed out")
            finally:
                os.close(fd)
                _, status = os.waitpid(pid, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode())
            if answer == b"\n":
                self.assertEqual(self.events(), [])
                self.assertIn('已取消'.encode(), output)
            else:
                self.assertIn("systemctl stop agh.service", self.events())

    def test_cron_removes_only_generated_entries_for_target(self):
        managed = [f"0 3 */3 * * sh '{self.target}/sh/update-scripts.sh' # MyProxy:update-scripts",
                   f"5 3 */3 * * sh {self.target}/sh/update-all-configs-restart-services.sh # MyProxy:update-configs",
                   f"0 3 * * * sh '{self.target}/sh/run-scheduled-update.sh' scripts 3 # MyProxy:update-scripts",
                   f"5 3 * * * sh {self.target}/sh/run-scheduled-update.sh configs 7 # MyProxy:update-configs"]
        retained = ["MAILTO=root", "# keep comments", "# " + managed[0],
                    "0 3 * * * sh /other/sh/update-scripts.sh # MyProxy:update-scripts",
                    "0 3 * * * sh /other/sh/run-scheduled-update.sh scripts 3 # MyProxy:update-scripts",
                    f"*/5 * * * * sh {self.target}/sh/keeplive.sh", "0 0 * * * echo unrelated"]
        self.file("crontab", "\n".join(managed + retained) + "\n")
        self.assert_ok(self.run_uninstall())
        self.assertEqual((self.root / "crontab").read_text().splitlines(), retained)
        self.assertEqual(self.events()[0], "crontab write")

    def test_cron_read_or_write_failure_does_not_stop_services(self):
        self.file("crontab", f"0 3 * * * sh '{self.target}/sh/update-scripts.sh' # MyProxy:update-scripts\n")
        for flag in ("FAIL_CRON_READ", "FAIL_CRON_WRITE"):
            result = self.run_uninstall("--purge", extra={flag: "1"})
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any("stop" in event for event in self.events()))
            self.assertTrue((self.target / "core/config.yaml").exists())

    def test_foreign_service_or_link_aborts_before_mutations(self):
        unit = self.etc / "systemd/system/agh.service"
        original = unit.read_text()
        unit.write_text(original.replace(str(self.target), str(self.target) + "-other"))
        self.assertNotEqual(self.run_uninstall("--purge").returncode, 0)
        self.assertEqual(self.events(), [])
        unit.write_text(original)
        link = self.etc / "systemd/system/multi-user.target.wants/agh.service"
        link.unlink()
        link.symlink_to("../foreign.service")
        self.assertNotEqual(self.run_uninstall("--purge").returncode, 0)
        self.assertEqual(self.events(), [])

    def test_effective_unit_dropin_or_query_failure_aborts(self):
        for extra in ({"MOCK_FRAGMENT": "/usr/lib/systemd/system/agh.service"},
                      {"MOCK_DROPINS": "/etc/systemd/system/agh.service.d/custom.conf"}, {"FAIL_SHOW": "1"}):
            result = self.run_uninstall("--purge", extra=extra)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.events(), [])

    def test_stop_or_reload_failure_preserves_data(self):
        for action in ("stop agh.service", "stop proxy_core.service", "daemon-reload"):
            result = self.run_uninstall("--purge", extra={"FAIL_ACTION": action})
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((self.target / "core/config.yaml").exists())
            self.assertTrue((self.target / "sh/env.local.conf").exists())
            if action != "daemon-reload":
                self.assertTrue((self.etc / "systemd/system/agh.service").exists())

    def test_openwrt_disable_failure_preserves_files(self):
        self.platform("openwrt")
        result = self.run_uninstall("--purge", extra={"FAIL_ACTION": "agh disable"})
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.etc / "init.d/agh").exists())
        self.assertTrue((self.target / "sh/env.local.conf").exists())

    def test_service_file_removal_failure_prevents_data_purge(self):
        rm = shutil.which("rm")
        self.command("rm", f'''for path in "$@"; do
    case "$path" in */systemd/system/agh.service) exit 1 ;; esac
done
exec {rm} "$@"
''')
        result = self.run_uninstall("--purge")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.target / "sh/env.local.conf").exists())
        self.assertNotIn("卸载完成", result.stdout)

    def test_running_or_deleted_binary_blocks_removal(self):
        link = self.proc / "123/exe"
        link.parent.mkdir(parents=True)
        for suffix in ("", " (deleted)"):
            link.symlink_to(str(self.target / "core/mihomo") + suffix)
            result = self.run_uninstall("--purge")
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((self.etc / "systemd/system/agh.service").exists())
            self.assertTrue((self.target / "sh/env.local.conf").exists())
            link.unlink()

    def test_purge_refuses_unsafe_targets_missing_marker_symlinks_and_mounts(self):
        for directory in ("/", "/etc", "/usr/local", "/tmp", str(self.target / "../installed")):
            self.assertNotEqual(self.run_uninstall("--purge", directory=directory).returncode, 0)
        local = self.target / "sh/env.local.conf"
        original = local.read_text()
        local.unlink()
        self.assertNotEqual(self.run_uninstall("--purge").returncode, 0)
        local.write_text("MP_INST_DIR='/other'\n")
        self.assertNotEqual(self.run_uninstall("--purge").returncode, 0)
        local.write_text(original)
        shutil.rmtree(self.target / "core")
        (self.target / "core").symlink_to(self.root / "core")
        self.assertNotEqual(self.run_uninstall("--purge").returncode, 0)
        (self.target / "core").unlink()
        (self.target / "core").mkdir()
        self.file("proc/self/mountinfo", f"1 0 0:1 / {self.target}/core/cache rw - tmpfs tmpfs rw\n")
        self.assertNotEqual(self.run_uninstall("--purge").returncode, 0)
        self.assertEqual(self.events(), [])

    def test_local_configuration_is_not_executed(self):
        with (self.target / "sh/env.local.conf").open("a") as stream:
            stream.write(f"touch '{self.root}/executed'\n")
        self.assert_ok(self.run_uninstall("--purge"))
        self.assertFalse((self.root / "executed").exists())

    def test_arguments_and_help(self):
        for args in (("--yes",), ("--purge", "--purge"), ("--unknown",), ("--yes=1",)):
            self.assertNotEqual(self.run_uninstall(*args).returncode, 0)
        result = subprocess.run(["sh", str(self.script), "--help"], env=self.env,
                                capture_output=True, text=True, timeout=5)
        self.assert_ok(result)
        self.assertIn("--purge", result.stdout)
        self.assertEqual(self.events(), [])

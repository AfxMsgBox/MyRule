"""Installer contracts: real shell functions, fake HTTP and isolated pseudo terminals."""
import json
import os
import pty
import select
import shlex
import subprocess
import sys
import unittest
import shutil
import gzip
import io
import tarfile
import time

import test_scripts


ROOT = test_scripts.ROOT
SOURCE = (ROOT / "sh/inst.sh").read_text()
PREFIX = SOURCE.split("# === 主流程：", 1)[0]
REQUIRED = ["--subscribe-url", "https://example.invalid/sub?token=private",
            "--agh-user", "admin", "--agh-password", "$2b$10$private"]


class InstallerTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    command = test_scripts.ShellTests.command
    file = test_scripts.ShellTests.file
    run_shell = test_scripts.ShellTests.run_shell
    assert_ok = test_scripts.ShellTests.assert_ok

    def installer(self, script, extra=None):
        return self.run_shell(PREFIX + "\ninst_colors\n" + script, source=False, extra=extra)

    def args(self, options=()):
        return "inst_parse_args " + shlex.join(REQUIRED + list(options)) + " || exit 1\n"

    def local_source(self):
        source = self.root / "local repo"
        for directory in ("sh", "core", "agh", "domain"):
            shutil.copytree(ROOT / directory, source / directory)
        return source

    def test_local_source_arguments_validation_and_overlap(self):
        source = self.local_source()
        for target in (self.root / "installed", source, source / "nested/install"):
            result = self.installer(self.args(["--source-dir", str(source), "--install-dir", str(target)])
                                    + 'inst_validate')
            self.assertEqual(result.returncode == 0, target == self.root / "installed", result.stdout)
        result = self.installer(self.args(["--source-dir="]) + 'inst_validate')
        self.assertNotEqual(result.returncode, 0)
        (source / "sh/update-bin.sh").unlink()
        result = self.installer(self.args(["--source-dir", str(source)]) + 'inst_validate')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sh/update-bin.sh", result.stdout)

    def test_local_source_interaction_skips_branch_api(self):
        source = self.local_source()
        result = self.installer(r'''
DIR_INST="$TEST_ROOT/installed"
prompt_to() {
    case "$1" in
        _ics_mode) _ics_mode=2 ;;
        _MP_SOURCE_DIR) _MP_SOURCE_DIR="$TEST_SOURCE" ;;
        MP_REPO_BRANCH) MP_REPO_BRANCH=feature/local ;;
        *) return 99 ;;
    esac
}
inst_choose_branch() { echo unexpected-branch-api; return 99; }
inst_choose_source || exit 1
test "$_MP_SOURCE_DIR" = "$TEST_SOURCE" && test "$MP_REPO_BRANCH" = feature/local
''', {"TEST_SOURCE": str(source)})
        self.assert_ok(result)
        self.assertNotIn("unexpected", result.stdout)

    def test_local_repo_file_copy_and_no_network_fallback(self):
        source = self.local_source()
        self.file("result", "old")
        extra = {"_MP_SOURCE_DIR": str(source)}
        result = self.run_shell('download_file "$MP_REPO_RAW_URL/domain/gpt.txt" "$TEST_ROOT/result"', extra=extra)
        self.assert_ok(result)
        self.assertEqual((self.root / "result").read_bytes(), (source / "domain/gpt.txt").read_bytes())
        (source / "domain/gpt.txt").unlink()
        result = self.run_shell('download_file "$MP_REPO_RAW_URL/domain/gpt.txt" "$TEST_ROOT/result"', extra=extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("unexpected-command", result.stdout + result.stderr)
        self.assertFalse(list(self.root.glob(".local-copy.*")))

    def test_local_repo_copy_failure_and_escape_preserve_destination(self):
        source = self.local_source()
        self.file("result", "old")
        self.file("outside", "outside content")
        (source / "domain/link.txt").symlink_to(self.root / "outside")
        for relative in ("../outside", "domain/link.txt"):
            result = self.run_shell('download_file "$MP_REPO_RAW_URL/$RELATIVE" "$TEST_ROOT/result"',
                                    extra={"_MP_SOURCE_DIR": str(source), "RELATIVE": relative})
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((self.root / "result").read_text(), "old")
        self.command("cp", "exit 1\n")
        result = self.run_shell('download_file "$MP_REPO_RAW_URL/domain/gpt.txt" "$TEST_ROOT/result"',
                                extra={"_MP_SOURCE_DIR": str(source)})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "result").read_text(), "old")
        self.assertFalse(list(self.root.glob(".local-copy.*")))

    def test_external_download_still_uses_proxy_in_local_mode(self):
        source = self.local_source()
        self.curl_mock()
        proxy = "http://proxy.invalid:1080"
        result = self.run_shell('download_file https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt '
                                '"$TEST_ROOT/result"', extra={"_MP_SOURCE_DIR": str(source),
                                                            "MP_PROXY": proxy, "SUCCEED_PROXY": proxy})
        self.assert_ok(result)
        args = json.loads((self.root / "curl-args").read_text())
        self.assertEqual(args[args.index("--proxy") + 1], proxy)

    def test_local_script_sync_preserves_private_config(self):
        source = self.local_source()
        (source / "sh/env.local.conf").write_text("PRIVATE='source-secret'\n")
        for directory in (".install-state/forward", ".schedule"):
            (source / "sh" / directory).mkdir(parents=True, exist_ok=True)
            (source / "sh" / directory / "private-state").write_text("other-host-state\n")
        self.file("sh/env.local.conf", "CUSTOM='installed'\n")
        own_state = self.file("sh/.install-state/forward/owner", "this-host\n")
        result = self.run_shell('mp_fetch_repo_sh "$MP_INST_DIR/sh"', extra={"_MP_SOURCE_DIR": str(source)})
        self.assert_ok(result)
        self.assertEqual((self.root / "sh/env.local.conf").read_text(), "CUSTOM='installed'\n")
        self.assertEqual((self.root / "sh/inst.sh").read_bytes(), (source / "sh/inst.sh").read_bytes())
        self.assertEqual(own_state.read_text(), "this-host\n")
        self.assertFalse((self.root / "sh/.install-state/forward/private-state").exists())
        self.assertFalse((self.root / "sh/.schedule/private-state").exists())

    def test_local_install_end_to_end_with_external_downloads(self):
        source = self.local_source()
        # Only replace host mutations; run actual bootstrap, template rendering and resource deployment.
        safe = SOURCE[:SOURCE.index('# === 开启 IPv4 转发')] + SOURCE[SOURCE.index('# === 写 env.local.conf'):]
        script = self.file("safe-inst.sh", safe)
        with (source / "sh/common.sh").open("a") as stream:
            stream.write(r'''
mp_sync_etc_files() { printf 'sync %s\n' "$1" >> "$TEST_ROOT/events"; }
mp_service_op() { printf '%s %s\n' "$1" "$2" >> "$TEST_ROOT/events"; }
mp_wait_core_ready() { printf 'ready\n' >> "$TEST_ROOT/events"; }
''')
        self.file("fixtures/release.json", '{"tag_name":"test-version"}')
        self.file("fixtures/payload", "payload:\n  - '+.example.org'\n")
        (self.root / "fixtures/mihomo.gz").write_bytes(gzip.compress(b"test-mihomo"))
        for archive, name in [("ui.tgz", "index.html"), ("agh.tgz", "AdGuardHome/AdGuardHome")]:
            with tarfile.open(self.root / "fixtures" / archive, "w:gz") as tar:
                info = tarfile.TarInfo(name)
                info.size = len(b"test-binary")
                info.mode = 0o755
                tar.addfile(info, io.BytesIO(b"test-binary"))
        self.command("uname", "echo x86_64\n")
        self.command("id", "echo 0\n")
        self.command("curl", r'''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift ;;
        --proxy) proxy=$2; shift ;;
        https://*) url=$1 ;;
    esac
    shift
done
printf '%s %s\n' "$proxy" "$url" >> "$TEST_ROOT/downloads"
case "$url" in
    *AfxMsgBox/MyRule*) echo unexpected-repository-download >&2; exit 99 ;;
    */releases/latest) fixture=release.json ;;
    *mihomo-linux-*) fixture=mihomo.gz ;;
    */compressed-dist.tgz) fixture=ui.tgz ;;
    *AdGuardHome_linux_*) fixture=agh.tgz ;;
    *) fixture=payload ;;
esac
cp "$TEST_ROOT/fixtures/$fixture" "$out"
''')
        target = self.root / "installed"
        args = ["sh", str(script), *REQUIRED, "--source-dir", str(source), "--install-dir", str(target),
                "--proxy", "http://proxy.invalid:1080", "--branch", "feature/local"]
        result = subprocess.run(args, cwd=self.root, env=self.env, text=True, capture_output=True, timeout=10)
        self.assert_ok(result)
        self.assertTrue((target / "core/mihomo").exists())
        self.assertTrue((target / "core/ui/index.html").exists())
        self.assertTrue((target / "agh/AdGuardHome").exists())
        self.assertIn("feature/local/domain/gpt.txt", (target / "core/config.yaml").read_text())
        self.assertEqual((target / "core/ruleset/gpt.yaml").read_bytes(), (source / "domain/gpt.txt").read_bytes())
        self.assertNotIn("_MP_SOURCE_DIR", (target / "sh/env.local.conf").read_text())
        self.assertIn("MP_REPO_BRANCH='feature/local'", (target / "sh/env.local.conf").read_text())
        downloads = (self.root / "downloads").read_text().splitlines()
        self.assertTrue(any("/gfw.txt" in line for line in downloads))
        self.assertTrue(any("example.invalid/sub" in line for line in downloads))
        self.assertTrue(all(line.startswith("http://proxy.invalid:1080 ") for line in downloads))
        self.assertEqual((self.root / "events").read_text().splitlines(),
                         ["sync never", "sync always", "enable_start proxy_core", "ready", "enable_start agh"])
        # Subsequent independent updates must use the configured online branch, not the old source path.
        result = self.run_shell('download_file "$MP_REPO_RAW_URL/domain/gpt.txt" "$TEST_ROOT/later"',
                                extra={"MP_INST_DIR": str(target), "_MP_NONINTERACTIVE": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected-repository-download", result.stderr)
        self.assertIn("/refs/heads/feature/local/domain/gpt.txt", (self.root / "downloads").read_text().splitlines()[-1])

    def tty(self, script, extra=None):
        master, slave = pty.openpty()
        try:
            proc = subprocess.Popen(["sh", "-c", script], stdin=slave, stdout=slave, stderr=slave,
                                    env=self.env | {"TERM": "xterm"} | (extra or {}), cwd=self.root)
            os.close(slave)
            slave = None
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                self.fail("unexpected terminal prompt or hung command")
            chunks = []
            while True:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                chunks.append(chunk)
            return subprocess.CompletedProcess(proc.args, proc.returncode, b"".join(chunks).decode(), "")
        finally:
            os.close(master)
            if slave is not None:
                os.close(slave)

    def test_interactive_inputs_echo_paste_and_preserve_defaults(self):
        values = ["http://user:p%40ss@proxy.invalid:1080",
                  "https://example.invalid/sub?token=a'b&path=\\test",
                  "admin", "$2b$10$test'quoted\\hash", "1.1.1.1 9.9.9.9"]
        script = PREFIX + r'''
exec 3<&0
inst_colors
INSTALL_MODE=interactive
MP_PROXY=$TEST_PROXY; MP_SUBSCRIBE_URL=$TEST_SUB; MP_AGH_USER_NAME=$TEST_USER
MP_AGH_PASSWORD=$TEST_HASH; MP_LOCAL_DNS=$TEST_DNS
inst_choose_source() { return 0; }
inst_collect_inputs || exit 1
printf '%s\n' "$MP_PROXY" "$MP_SUBSCRIBE_URL" "$MP_AGH_USER_NAME" "$MP_AGH_PASSWORD" "$MP_LOCAL_DNS" > "$TEST_ROOT/inputs"
'''
        for retain_defaults in (False, True):
            with self.subTest(retain_defaults=retain_defaults):
                extra = dict(zip(('TEST_PROXY', 'TEST_SUB', 'TEST_USER', 'TEST_HASH', 'TEST_DNS'),
                                 values if retain_defaults else [''] * len(values)))
                master, slave = pty.openpty()
                proc = subprocess.Popen(['sh', '-c', script], stdin=slave, stdout=slave, stderr=slave,
                                        env=self.env | extra, cwd=self.root)
                os.close(slave)
                pending = b''

                def read_until(marker):
                    nonlocal pending
                    deadline = time.monotonic() + 3
                    while marker not in pending:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0 or not select.select([master], [], [], remaining)[0]:
                            self.fail('input was not echoed or prompt did not appear: ' + repr(pending))
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            self.fail('terminal closed before expected output: ' + repr(pending))
                        if not chunk:
                            self.fail('terminal reached EOF before expected output')
                        pending += chunk
                    before, pending = pending.split(marker, 1)
                    return before

                try:
                    read_until(b'] > ')
                    os.write(master, b'2')
                    read_until(b'2')  # Visible before submitting, not a later value dump.
                    os.write(master, b'\n')
                    for value in values:
                        prompt = read_until(b'] > ')
                        if retain_defaults:
                            self.assertIn(value.encode(), prompt)
                        else:
                            os.write(master, value.encode())  # Simulate pasting one line.
                            read_until(value.encode())
                        os.write(master, b'\n')
                    proc.wait(timeout=3)
                    self.assertEqual(proc.returncode, 0)
                    self.assertEqual((self.root / 'inputs').read_text().splitlines(), values)
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait()
                    os.close(master)

    def test_named_defaults_ignore_old_environment(self):
        result = self.installer(self.args() + 'inst_validate || exit 1\n'
                                'printf "%s\\n" "$INSTALL_MODE" "$DIR_INST" "$MP_REPO_BRANCH" '
                                '"$MP_LOCAL_DNS" "proxy=$MP_PROXY"',
                                {"MP_REPO_BRANCH": "old", "MP_PROXY": "http://old:99",
                                 "MP_INST_DIR": "/old", "MP_LOCAL_DNS": "old"})
        self.assert_ok(result)
        self.assertEqual(result.stdout.splitlines(),
                         ["silent", "/etc/proxy", "main", "223.5.5.5 119.29.29.29", "proxy="])

    def test_named_empty_and_equals_values(self):
        result = self.installer(self.args(["--branch=", "--dns=", "--proxy=", "--install-dir=custom"])
                                + 'inst_validate || exit 1\n'
                                'printf "%s|%s|%s|%s" "$MP_REPO_BRANCH" "$MP_LOCAL_DNS" "$MP_PROXY" "$DIR_INST"')
        self.assert_ok(result)
        self.assertEqual(result.stdout, "main|||" + str(self.root / "custom"))

    def test_invalid_options_and_values_fail_without_side_effects(self):
        cases = [["--branch"], ["--branch", "--dns", "x"], ["--unknown=private"],
                 ["/tmp/old-positional"], ["--branch=x", "--branch=y"],
                 ["--install-dir="], ["--install-dir=/path with space"],
                 ["--branch=https://example.invalid/a"], ["--branch=../bad"],
                 ["--branch=bad\nname"], ["--branch=a..b"], ["--branch=x/.hidden"],
                 ["--branch=x.lock"], ["--proxy=ftp://private"]]
        for options in cases:
            with self.subTest(options=options):
                result = self.installer(self.args(options) + "inst_validate")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("private", result.stdout + result.stderr)

    def test_required_values_cannot_be_filled_by_environment(self):
        for missing in range(0, len(REQUIRED), 2):
            args = REQUIRED[:missing] + REQUIRED[missing + 2:]
            result = self.installer("inst_parse_args " + shlex.join(args) + "\ninst_validate")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(REQUIRED[missing], result.stdout)
        for option in ("--subscribe-url", "--agh-user", "--agh-password"):
            args = REQUIRED.copy()
            args[args.index(option) + 1] = ""
            result = self.installer("inst_parse_args " + shlex.join(args) + "\ninst_validate")
            self.assertNotEqual(result.returncode, 0)

    def test_help_and_no_terminal_exit_before_install(self):
        for args in (["--help"], []):
            result = subprocess.run(["sh", str(ROOT / "sh/inst.sh"), *args], env=self.env,
                                    capture_output=True, text=True, timeout=5, start_new_session=True)
            if args:
                self.assert_ok(result)
                self.assertIn("--branch", result.stdout)
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("交互终端", result.stdout + result.stderr)

    def test_missing_tools_without_package_manager_has_actionable_error(self):
        result = self.installer('os_type=openwrt\ncommand() { return 1; }\ninst_require_tools')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("缺少依赖", result.stdout)
        self.assertIn("jq", result.stdout)
        self.assertIn("opkg/apk", result.stdout)

    def test_silent_with_terminal_never_prompts_or_changes_cron(self):
        cron = SOURCE[SOURCE.index("# === 定时更新"):SOURCE.index('say_section "安装完成"')]
        result = self.tty(PREFIX + self.args() + '\ninst_colors\n'
                          'prompt_to autostart Y "must-not-prompt"\n'
                          'test "$autostart" = Y || exit 1\n' + cron)
        self.assert_ok(result)
        self.assertNotIn("must-not-prompt", result.stdout)
        self.assertNotIn("unexpected-command", result.stdout)

    def test_persistence_removes_old_url_preserves_custom_lines_and_secrets(self):
        local = self.file("sh/env.local.conf", "# custom\nCUSTOM='keep'\n"
                          "MP_REPO_RAW_URL='https://old.invalid/a'\nexport MP_REPO_RAW_URL='old'\n"
                          "MP_PROXY='old'\n  export MP_PROXY='also-old'\n  export MP_REPO_BRANCH='old'\n")
        persist = SOURCE[SOURCE.index("# === 写 env.local.conf"):SOURCE.index("# === Bootstrap")]
        options = ["--install-dir", str(self.root), "--branch", "feature/quote'&name", "--dns", ""]
        result = self.installer(self.args(options) + 'inst_validate || exit 1\nDIR_SH="$DIR_INST/sh"\n'
                                + persist + '\n. "$DIR_SH/env.local.conf"\n'
                                'test "$MP_AGH_PASSWORD" = \'$2b$10$private\' && test -z "$MP_LOCAL_DNS" '
                                '&& test -z "$MP_PROXY" && test "$MP_REPO_BRANCH" != old')
        self.assert_ok(result)
        self.assertNotIn("MP_REPO_RAW_URL", local.read_text())
        self.assertIn("CUSTOM='keep'", local.read_text())
        self.assertEqual(local.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("private", result.stdout)

    def test_branch_derivation_and_legacy_url_ignored(self):
        self.file("sh/env.local.conf", "MP_REPO_RAW_URL='https://old.invalid/a'\nMP_REPO_BRANCH='old'\n")
        for branch, suffix in [("", "main"), ("feature/quote'&name", "feature/quote%27%26name")]:
            result = self.run_shell('printf "%s" "$MP_REPO_RAW_URL"',
                                    extra={"MP_REPO_BRANCH": branch, "MP_REPO_RAW_URL": "https://bad.invalid"})
            self.assert_ok(result)
            self.assertEqual(result.stdout, "https://raw.githubusercontent.com/AfxMsgBox/MyRule/refs/heads/" + suffix)

    def branch_mock(self, pages):
        for number, page in enumerate(pages, 1):
            self.file(f"fixtures/page{number}.json", json.dumps(page))
        return r'''
_inst_tmp="$TEST_ROOT/fixtures"
bootstrap_download() {
    printf '%s\n' "$1" >> "$TEST_ROOT/pages"
    cp "$TEST_ROOT/fixtures/page${1##*=}.json" "$2" 2>/dev/null
}
'''

    def test_branches_paginate_sort_and_preserve_slashes(self):
        pages = [[{"name": f"branch-{n}"} for n in range(100)],
                 [{"name": "feature/slash"}, {"name": "main"}]]
        result = self.installer(self.branch_mock(pages) + 'inst_fetch_branches')
        self.assert_ok(result)
        names = (self.root / "fixtures/branches.sorted").read_text().splitlines()
        self.assertEqual(names[0], "main")
        self.assertEqual(len(names), 102)
        self.assertIn("feature/slash", names)
        self.assertEqual((self.root / "pages").read_text().splitlines(), [
            "https://api.github.com/repos/AfxMsgBox/MyRule/branches?per_page=100&page=1",
            "https://api.github.com/repos/AfxMsgBox/MyRule/branches?per_page=100&page=2"])

    def test_branches_failure_discards_partial_list(self):
        pages = [[{"name": "main"}] + [{"name": f"b-{n}"} for n in range(99)]]
        result = self.installer(self.branch_mock(pages) + r'''
prompt_to() { _ib_retry=n; }
inst_choose_branch
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "fixtures/branches").exists())
        self.assertFalse((self.root / "fixtures/branches.sorted").exists())

    def test_branch_api_rejects_invalid_responses(self):
        for response in ({"message": "rate limited"}, [{"name": "bad\nmain"}],
                         [{"name": 5}], [], [{"name": "no-main"}]):
            with self.subTest(response=response):
                result = self.installer(self.branch_mock([response]) + 'inst_fetch_branches')
                self.assertNotEqual(result.returncode, 0)

    def test_branch_selection_default_and_invalid_number(self):
        mock = self.branch_mock([[{"name": "dev"}, {"name": "main"}]])
        for answers, expected in [("\n", "main"), ("999\n2\n", "dev")]:
            self.file("answers", answers)
            result = self.installer(mock + 'INSTALL_MODE=interactive\n'
                                    # A file cannot model simultaneous terminal input/output; isolate output.
                                    'prompt_to() { IFS= read -r _answer <&4; _ib_choice=${_answer:-1}; }\n'
                                    'exec 4<"$TEST_ROOT/answers"\nexec 3>/dev/null\n'
                                    'inst_choose_branch || exit 1\nprintf "chosen=%s" "$MP_REPO_BRANCH"')
            self.assert_ok(result)
            self.assertIn("chosen=" + expected, result.stdout)

    def curl_mock(self):
        path = self.root / "commands/curl"
        path.write_text("#!" + sys.executable + "\n" + '''import json, os, sys
args = sys.argv[1:]
with open(os.environ["TEST_ROOT"] + "/curl-args", "a") as out:
    out.write(json.dumps(args) + "\\n")
proxy = args[args.index("--proxy") + 1]
if proxy != os.environ.get("SUCCEED_PROXY", ""):
    sys.exit(7)
with open(args[args.index("-o") + 1], "w") as out:
    out.write("downloaded content")
''')
        path.chmod(0o755)

    def test_bootstrap_and_common_proxy_order_and_isolation(self):
        self.curl_mock()
        core = "socks5h://127.0.0.1:7890"
        external = "http://user:private@external.invalid:8080"
        cases = [(True, external, "", [core, external, ""]),
                 (True, "", core, [core]), (True, "", "", [core, ""]),
                 (False, external, external, [external]), (False, "", "", [""]),
                 (True, core, "", [core, ""])]
        for bootstrap in (True, False):
            for configured, proxy, succeeds, expected in cases:
                with self.subTest(bootstrap=bootstrap, configured=configured, proxy=proxy, succeeds=succeeds):
                    self.file("core/config.yaml", 'mixed-port: "7890" # comment\n' if configured else "")
                    (self.root / "curl-args").unlink(missing_ok=True)
                    script = '"https://example.invalid/sub?token=private" "$TEST_ROOT/result"'
                    extra = {"MP_PROXY": proxy, "SUCCEED_PROXY": succeeds, "HTTP_PROXY": "http://wrong",
                             "HTTPS_PROXY": "http://wrong", "ALL_PROXY": "http://wrong", "NO_PROXY": "*"}
                    if bootstrap:
                        result = self.installer('INSTALL_MODE=silent\nDIR_INST="$TEST_ROOT"\nbootstrap_download ' + script, extra)
                    else:
                        result = self.run_shell('_MP_NONINTERACTIVE=1\ndownload_file ' + script, extra=extra)
                    self.assert_ok(result)
                    calls = [json.loads(line) for line in (self.root / "curl-args").read_text().splitlines()]
                    self.assertEqual([args[args.index("--proxy") + 1] for args in calls], expected)
                    for args, used_proxy in zip(calls, expected):
                        self.assertEqual(args[0], "--disable")
                        self.assertIn("--silent", args)
                        self.assertEqual(args[args.index("--noproxy") + 1], "" if used_proxy else "*")
                    self.assertNotIn("private", result.stdout + result.stderr)

    def test_core_proxy_port_parsers_agree(self):
        for config, expected in [('mixed-port: 7890\nport: 7891\n', "socks5h://127.0.0.1:7890"),
                                 ('mixed-port: 0\nport: 8080\n', "http://127.0.0.1:8080"),
                                 ("socks-port: '1080' # comment\n", "socks5h://127.0.0.1:1080"),
                                 ('mixed-port: 65536\nport: invalid\n', "")]:
            self.file("core/config.yaml", config)
            result = self.run_shell(PREFIX + '\nDIR_INST="$TEST_ROOT"\n'
                                    'bootstrap_core_proxy || :\nmp_core_proxy_url || :')
            self.assert_ok(result)
            self.assertEqual(result.stdout.splitlines(), [expected, expected] if expected else [])

    def test_silent_download_failure_with_terminal_preserves_destination(self):
        self.curl_mock()
        self.file("result", "original")
        result = self.tty('. "$MP_INST_DIR/sh/common.sh"\n_MP_NONINTERACTIVE=1\n'
                          'download_file https://example.invalid "$TEST_ROOT/result"',
                          {"SUCCEED_PROXY": "none"})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("是否重试", result.stdout)
        self.assertEqual((self.root / "result").read_text(), "original")
        self.assertFalse(list(self.root.glob(".download.*")))

    def test_bootstrap_failure_with_terminal_preserves_destination(self):
        self.curl_mock()
        self.file("result", "original")
        result = self.tty(PREFIX + '\ninst_colors\nINSTALL_MODE=silent\nDIR_INST="$TEST_ROOT"\n'
                          'bootstrap_download https://example.invalid "$TEST_ROOT/result"',
                          {"SUCCEED_PROXY": "none"})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("重试", result.stdout)
        self.assertEqual((self.root / "result").read_text(), "original")
        self.assertFalse(list(self.root.glob("result.tmp.*")))

    def test_noninteractive_mode_reaches_child_scripts(self):
        # Run validation/export, stopping before project writes; package managers are mocked.
        entry = SOURCE[:SOURCE.index("say_section '安装概览'")]
        entry += '\nsh -c \'test "$_MP_NONINTERACTIVE" = 1 && test "$MP_PROXY" = "" && test "$MP_REPO_BRANCH" = main\'\n'
        script = self.file("safe-inst.sh", entry)
        result = subprocess.run(["sh", str(script), *REQUIRED], env=self.env | {"MP_PROXY": "http://old"},
                                cwd=self.root, text=True, capture_output=True, timeout=5)
        self.assert_ok(result)
        self.assertNotIn("private", result.stdout + result.stderr)

    def test_colors_are_terminal_only_and_syslog_is_plain(self):
        self.command("logger", 'printf "%s\\n" "$@" >> "$TEST_ROOT/syslog"\n')
        script = PREFIX + '\nexec 3<&0\ninst_colors\nsay_section test\n' \
                 '. "$MP_INST_DIR/sh/common.sh"\n_MP_INSTALL_OUTPUT=1\necho_log message'
        result = self.tty(script)
        self.assert_ok(result)
        self.assertIn("\x1b[", result.stdout)
        self.assertNotIn("\x1b[", (self.root / "syslog").read_text())
        for extra in ({"NO_COLOR": "1"}, {"TERM": "dumb"}):
            result = self.tty(script, extra)
            self.assert_ok(result)
            self.assertNotIn("\x1b[", result.stdout)
        result = self.run_shell(script, source=False)
        self.assert_ok(result)
        self.assertNotIn("\x1b[", result.stdout)

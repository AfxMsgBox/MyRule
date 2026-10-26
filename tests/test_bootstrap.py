"""Standalone entry regression tests with a controlling terminal and fake GitHub."""
import json
import os
import pty
import select
import signal
import tarfile
import time
import unittest

import test_installer
import test_scripts


class BootstrapTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    file = test_scripts.ShellTests.file
    command = test_scripts.ShellTests.command

    def bootstrap(self, pages, choice=b"2\n", args=()):
        entry = self.file("inst.sh", test_installer.SOURCE)
        # Real wizard; only stop before applying anything to the machine.
        library = 'shift\n' + test_installer.PREFIX + r'''
inst_parse_args "$@" || exit 1
exec 3<>/dev/tty
prompt_to() { eval "$1=\$2"; }
inst_choose_branch() { echo duplicate-branch-prompt >&2; return 1; }
inst_collect_inputs || exit 1
printf '%s\n' "$MP_REPO_BRANCH" > "$TEST_ROOT/selected"
'''
        self.file("fixtures/repo/sh/install-lib.sh", library)
        with tarfile.open(self.root / "fixtures/repo.tgz", "w:gz") as archive:
            archive.add(self.root / "fixtures/repo", arcname="MyRule-feature")
        for n, page in enumerate(pages, 1):
            self.file(f"fixtures/page{n}.json", json.dumps(page))
        self.command("curl", r'''
while [ "$#" -gt 0 ]; do
    case "$1" in -o) out=$2; shift ;; https://*) url=$1 ;; esac
    shift
done
printf '%s\n' "$url" >> "$TEST_ROOT/requests"
case "$url" in
    *branches\?*) cp "$TEST_ROOT/fixtures/page${url##*=}.json" "$out" ;;
    */refs/heads/feature%2Finstall) cp "$TEST_ROOT/fixtures/repo.tgz" "$out" ;;
    *) echo unexpected-download >&2; exit 99 ;;
esac
''')
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.root)
            os.execvpe("sh", ["sh", str(entry), *args], self.env | {"TERM": "dumb"})
        output = b""
        prompts = [("发起端下载代理".encode(), b"\n"), ("选择分支编号".encode(), choice)]
        deadline = time.monotonic() + 10
        finished = False
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
                    if prompts and prompts[0][0] in output:
                        _, answer = prompts.pop(0)
                        os.write(fd, answer)
            else:
                self.fail("standalone bootstrap hung: " + output.decode())
            _, status = os.waitpid(pid, 0)
            finished = True
            return os.waitstatus_to_exitcode(status), output.decode()
        finally:
            if not finished:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            os.close(fd)

    def test_choose_feature_before_archive_and_reuse_in_wizard(self):
        test_scripts.ShellTests.jq_without_regex(self)
        rc, output = self.bootstrap([[{"name": "main"}, {"name": "feature/install"}]], b"999\n2\n")
        self.assertEqual(rc, 0, output)
        self.assertEqual((self.root / "selected").read_text(), "feature/install\n")
        requests = (self.root / "requests").read_text().splitlines()
        self.assertIn("branches?", requests[0])
        self.assertTrue(requests[1].endswith("/feature%2Finstall"))
        self.assertEqual(len(requests), 2)
        self.assertNotIn("duplicate-branch-prompt", output)
        self.assertIn("分支编号超出范围", output)

    def test_all_pages_and_explicit_branch_default(self):
        first = [{"name": "main"}] + [{"name": f"z{i}"} for i in range(99)]
        rc, output = self.bootstrap([first, [{"name": "feature/install"}]], b"\n",
                                    ("--interactive", "--branch", "feature/install"))
        self.assertEqual(rc, 0, output)
        self.assertIn("选择分支编号 [2]", output)
        requests = (self.root / "requests").read_text().splitlines()
        self.assertEqual(len(requests), 3)
        self.assertIn("page=2", requests[1])
        self.assertEqual((self.root / "selected").read_text(), "feature/install\n")

    def test_invalid_api_never_downloads_archive(self):
        rc, output = self.bootstrap([{"message": "API rate limit exceeded"}])
        self.assertNotEqual(rc, 0)
        self.assertIn("无法获取完整分支列表", output)
        self.assertNotIn("codeload.github.com", (self.root / "requests").read_text())

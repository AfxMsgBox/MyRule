"""Common Core launcher: real child supervision with mocked kernel events."""
import os
import signal
import subprocess
import sys
import unittest

import test_route_watch


class CoreStartTests(unittest.TestCase):
    shell = os.environ.get("MYRULE_CORE_SHELL", "sh")
    for name in ('setUp_base','setUp','file','command','assert_ok','config','state','calls','replacements','wait_for'):
        locals()[name] = getattr(test_route_watch.RouteWatchTests, name)

    def start(self):
        if self.shell != 'sh' and '# test applet overrides' not in self.script.read_text():
            import shlex
            import shutil
            # Rescue BusyBox prefers internal applets; keep kernel/log mocks and
            # the math-capable awk used by the standard test fixture.
            prelude = ('# test applet overrides\nawk() { '+shlex.quote(shutil.which('awk'))+' "$@"; }\n'
                       'logger() { '+shlex.quote(str(self.root/'commands/logger'))+' "$@"; }\n')
            self.script.write_text(prelude + self.script.read_text())
        self.file('core/mihomo', '#!'+sys.executable+'\nimport os,signal,pathlib\n'
                  'pathlib.Path(os.environ["TEST_ROOT"],"core-pid").write_text(str(os.getpid()))\n'
                  'signal.signal(signal.SIGUSR1, lambda *_: exit(0))\nsignal.pause()\n').chmod(0o755)
        output = (self.root/'supervisor.log').open('w')
        proc = subprocess.Popen([self.shell, str(self.script)], env=self.env, stdout=output,
                                stderr=output, start_new_session=True)
        def cleanup():
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            output.close()
        self.addCleanup(cleanup)
        writer = os.open(self.root/'input', os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, writer)
        self.wait_for(lambda: (self.root/'core-pid').exists() and (self.root/'monitor-pid').exists() and bool(self.replacements()))
        core = int((self.root/'core-pid').read_text())
        monitor = int((self.root/'monitor-pid').read_text())
        return proc, writer, core, monitor

    def gone(self, *pids):
        for pid in pids:
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_stop_reaps_core_and_monitor_and_allows_restart(self):
        for _ in range(2):
            proc, _, core, monitor = self.start()
            proc.terminate()
            self.assertEqual(proc.wait(timeout=4), 0)
            self.gone(core, monitor)
            for f in ('core-pid','monitor-pid'):
                (self.root/f).unlink()
            self.state(route='')

    def test_core_crash_fails_service_and_reaps_monitor(self):
        proc, _, core, monitor = self.start()
        os.kill(core, signal.SIGKILL)
        self.assertNotEqual(proc.wait(timeout=4), 0)
        self.gone(core, monitor)
        self.assertFalse((self.root/"myrule.inst.log").exists())

    def test_monitor_exit_fails_service_and_reaps_core(self):
        proc, writer, core, monitor = self.start()
        os.write(writer, b'quit\n')
        self.assertNotEqual(proc.wait(timeout=4), 0)
        self.gone(core, monitor)

    def test_duplicate_launcher_rejected_without_stopping_original(self):
        proc, _, core, monitor = self.start()
        second = subprocess.run([self.shell, str(self.script)], env=self.env, capture_output=True, timeout=3)
        self.assertNotEqual(second.returncode, 0)
        self.assertIsNone(proc.poll())
        os.kill(core, 0)
        os.kill(monitor, 0)
        proc.terminate()
        proc.wait(timeout=4)

    def test_only_one_shell_with_core_and_monitor_as_direct_children(self):
        from pathlib import Path
        proc, _, core, monitor = self.start()
        children = Path(f'/proc/{proc.pid}/task/{proc.pid}/children')
        self.wait_for(lambda: set(children.read_text().split()) == {str(core), str(monitor)})
        self.assertEqual(set(children.read_text().split()), {str(core), str(monitor)})
        proc.terminate()
        proc.wait(timeout=4)
        self.gone(core, monitor)

    def test_unexpected_clean_core_exit_still_fails_service(self):
        proc, _, core, monitor = self.start()
        os.kill(core, signal.SIGUSR1)
        self.assertNotEqual(proc.wait(timeout=4), 0)
        self.gone(core, monitor)

    def test_missing_binary_does_not_start_listener(self):
        result = subprocess.run([self.shell, str(self.script)], env=self.env, capture_output=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root/'monitor-pid').exists())

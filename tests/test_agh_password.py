"""Standalone bcrypt tool: stdlib-only tests, no installed bcrypt required."""
import base64
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import pty
import select
import termios
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "sh/agh-password.py"
spec = importlib.util.spec_from_file_location("agh_password", SCRIPT)
agh_password = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agh_password)


class AGHPasswordTests(unittest.TestCase):
    def test_published_bcrypt_vectors(self):
        # Openwall / py-bcrypt vectors also shipped in Passlib 1.7.4.
        vectors = [
            ("U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"),
            ("U*U*", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK"),
            ("abc", "$2a$10$WvvTPHKwdBJ3uk0Z37EMR.hLA2W6N9AEBhEgrAOljy2Ae5MtaSIUi"),
        ]
        translate = bytes.maketrans(
            b"./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
        )
        for password, expected in vectors:
            with self.subTest(password=password):
                salt = base64.b64decode(expected[7:29].encode().translate(translate) + b"==")
                result = agh_password.hash_password(password, salt=salt, cost=int(expected[4:6]))
                self.assertEqual(result, "$2b$" + expected[4:])

    def test_utf8_boundaries_and_special_characters(self):
        # Independently generated/verified with pyca/bcrypt; fixed raw salt 00..0f.
        vectors = [
            ("password", "bqEtzdkvfegxfotQ8UAMQWLlq7JbHJW"),
            ("密码🔑", "KJ5MDfh5P4DzSGuxYlvvxS9Y4pe/Y7S"),
            ("a" * 71, "FX3M8ZaB8T23PcIG8hExbMypeo8IKIS"),
            ("a" * 72, "IbwKfymVuMfASrmYBUytUgog5Nvtojy"),
            ("密" * 24, "rz34wPjgwQc8o0MSqEfBTxHrEJkH77S"),
            ("  leading and trailing  ", "20JeP9AI1hUsrj.f523cEXzOwNEk0W6"),
            ("special'$`\\\n", "nmy1uuU1AyrMPJg4T9UcCUNytwPi8r."),
        ]
        for password, digest in vectors:
            with self.subTest(password=password):
                self.assertEqual(
                    agh_password.hash_password(password, salt=bytes(range(16)), cost=4),
                    "$2b$04$..CA.uOD/eaGAOmJB.yMBu" + digest,
                )

    def test_reject_invalid_password_without_truncation(self):
        for password in ("", "a" * 73, "密" * 25, "a\0b", "\ud800", b"bytes", None):
            with self.subTest(password=repr(password)), self.assertRaises(ValueError):
                agh_password.hash_password(password, cost=4)

    def test_reject_invalid_salt_and_cost(self):
        for salt in (b"", bytes(15), bytes(17), "1234567890123456"):
            with self.subTest(salt=salt), self.assertRaises(ValueError):
                agh_password.hash_password("test", salt=salt, cost=4)
        for cost in (3, 32, 4.0, True, "10"):
            with self.subTest(cost=cost), self.assertRaises(ValueError):
                agh_password.hash_password("test", cost=cost)

    def test_random_salts_and_no_shared_engine_state(self):
        first = agh_password.hash_password("test", cost=4)
        second = agh_password.hash_password("test", cost=4)
        self.assertNotEqual(first[7:29], second[7:29])
        # A subsequent invocation must not reuse a mutated P/S table.
        self.test_utf8_boundaries_and_special_characters()

    def invoke(self, args=(), data=""):
        return subprocess.run(
            [sys.executable, "-I", "-S", str(SCRIPT), *args], input=data,
            text=True, capture_output=True, timeout=60,
        )

    def test_single_file_without_site_packages_or_external_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            standalone = Path(directory) / SCRIPT.name
            shutil.copyfile(SCRIPT, standalone)
            result = subprocess.run(
                [sys.executable, "-I", "-S", str(standalone), "standalone-password"],
                text=True, capture_output=True, cwd=directory, timeout=60,
                env={**os.environ, "PATH": directory},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertRegex(result.stdout, r"^\$2b\$10\$[./A-Za-z0-9]{53}\n$")
            self.assertEqual(result.stderr, "")
            self.assertEqual(list(Path(directory).iterdir()), [standalone])

    def test_help_and_bad_arguments_do_not_prompt(self):
        for flag in ("-h", "--help"):
            result = self.invoke([flag])
            self.assertEqual(result.returncode, 0)
            self.assertIn("cost=10", result.stdout)
            self.assertNotIn("密码 >", result.stdout)
        for args in (["--unknown"], ["--cost", "4"], ["--help", "secret"]):
            result = self.invoke(args)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn("密码 >", result.stdout)
            self.assertNotIn("secret", result.stderr)

    def test_invalid_password_never_generates_hash(self):
        for password in ("", "密" * 25, "a\0b"):
            with patch.object(agh_password.getpass, "getpass", return_value=password) as prompt, \
                    contextlib.redirect_stdout(io.StringIO()) as out, \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(agh_password.main([]), 1)
            prompt.assert_called_once()
            self.assertEqual(out.getvalue(), "")

    def test_hidden_input_once_on_real_terminal(self):
        master, slave = pty.openpty()
        try:
            with subprocess.Popen(
                [sys.executable, "-I", "-S", str(SCRIPT)], stdin=slave,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
            ) as process:
                try:
                    self.assertTrue(select.select([process.stderr], [], [], 5)[0])
                    prompt = os.read(process.stderr.fileno(), 1024)
                    self.assertIn("密码 > ".encode(), prompt)
                    self.assertFalse(termios.tcgetattr(slave)[3] & termios.ECHO)
                    os.write(master, b"hidden-password\n")
                    out, err = process.communicate(timeout=60)
                    self.assertEqual(process.returncode, 0, err)
                    self.assertRegex(out.decode(), r"^\$2b\$10\$[./A-Za-z0-9]{53}\n$")
                    self.assertEqual(err.strip(), b"")
                    self.assertTrue(termios.tcgetattr(slave)[3] & termios.ECHO)
                    if select.select([master], [], [], 0)[0]:
                        self.assertNotIn(b"hidden-password", os.read(master, 1024))
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
        finally:
            os.close(master)
            os.close(slave)

    def test_command_line_preserves_password_and_never_prompts(self):
        for args, password in ((["  密码$'  "], "  密码$'  "), (["--", "--help"], "--help")):
            with patch.object(agh_password.getpass, "getpass") as prompt, \
                    patch.object(agh_password, "hash_password", return_value="hash") as hashed, \
                    contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(agh_password.main(args), 0)
            prompt.assert_not_called()
            hashed.assert_called_once_with(password)
            self.assertEqual(out.getvalue(), "hash\n")

    def test_eof_interrupt_and_invisible_input_failure(self):
        cases = [(EOFError, 130), (KeyboardInterrupt, 130),
                 (agh_password.getpass.GetPassWarning, 1)]
        for exception, code in cases:
            with patch.object(agh_password.getpass, "getpass", side_effect=exception), \
                    contextlib.redirect_stdout(io.StringIO()) as out, \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(agh_password.main([]), code)
            self.assertEqual(out.getvalue(), "")
            self.assertNotIn("Traceback", err.getvalue())

    def test_random_source_failure_does_not_emit_hash(self):
        with patch.object(agh_password.getpass, "getpass", return_value="secret"), \
                patch.object(agh_password.os, "urandom", side_effect=OSError("random unavailable")), \
                contextlib.redirect_stdout(io.StringIO()) as out, \
                contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(agh_password.main([]), 1)
        self.assertNotIn("MP_AGH_PASSWORD=", out.getvalue())
        self.assertNotIn("secret", err.getvalue())


if __name__ == "__main__":
    unittest.main()

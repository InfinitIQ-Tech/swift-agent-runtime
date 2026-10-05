#!/usr/bin/env python3
"""Test the CLI in a new synthetic PTY; never use owner input or send a request."""
import argparse
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, required=True)
args = parser.parse_args()
BINARY = args.binary.resolve()
SUITE_DEADLINE = time.monotonic() + 85
FIELDS = {"schemaVersion", "processID", "updatedAt", "stage", "requestStarted", "streamed", "failure", "httpStatus"}


def command(path):
    return [str(BINARY), "--manifest", str(ROOT / "Manifests/story-companion.agentconfig.json"),
            "--cloud-smoke-test", "--smoke-status-file", str(path)]


class OwnerFlowTests(unittest.TestCase):
    def test_non_tty_failure_has_safe_status(self):
        with tempfile.TemporaryDirectory(prefix="af80-cli-status-") as temp:
            path = Path(temp) / "status.json"
            result = subprocess.run(command(path), input="", text=True, capture_output=True, timeout=10)
            status = json.loads(path.read_text())
            self.assertEqual(result.returncode, 1)
            self.assertEqual(status["stage"], "failed")
            self.assertEqual(status["failure"], "credential_entry")
            self.assertFalse(status["requestStarted"])
            self.assertFalse(status["streamed"])
            self.assertLessEqual(set(status), FIELDS)

    def test_synthetic_hidden_entry_and_decline_never_start_request(self):
        fixture = b"AF80_SYNTHETIC_NON_SECRET_" + b"x" * 276
        with tempfile.TemporaryDirectory(prefix="af80-cli-owner-flow-") as temp:
            path = Path(temp) / "status.json"
            pid, fd = pty.fork()
            if pid == 0:
                for name in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY"):
                    os.environ.pop(name, None)
                os.execv(str(BINARY), command(path))
            output = b""
            entered = declined = reaped = False
            deadline = time.monotonic() + 12
            try:
                while time.monotonic() < deadline:
                    if select.select([fd], [], [], .05)[0]:
                        try:
                            output += os.read(fd, 4096)
                        except OSError:
                            break
                    if not entered and b"Anthropic key (in memory only):" in output:
                        self.assertFalse(termios.tcgetattr(fd)[3] & termios.ECHO)
                        os.write(fd, fixture + b"\n")
                        entered = True
                    if entered and not declined and b"Type SEND to send the request" in output:
                        for _ in range(20):
                            status = json.loads(path.read_text())
                            if status["stage"] == "awaiting_send":
                                break
                            time.sleep(.02)
                        self.assertEqual(status["stage"], "awaiting_send")
                        self.assertFalse(status["requestStarted"])
                        os.write(fd, b"STOP\n")
                        declined = True
                    done, code = os.waitpid(pid, os.WNOHANG)
                    if done:
                        reaped = True
                        self.assertEqual(os.waitstatus_to_exitcode(code), 0)
                        break
                if not reaped:
                    done, code = os.waitpid(pid, os.WNOHANG)
                    if done:
                        reaped = True
                        self.assertEqual(os.waitstatus_to_exitcode(code), 0)
                self.assertTrue(reaped and entered and declined, "synthetic flow did not complete")
                status = json.loads(path.read_text())
                self.assertEqual(status["stage"], "owner_declined")
                self.assertFalse(status["requestStarted"])
                self.assertFalse(status["streamed"])
                self.assertLessEqual(set(status), FIELDS)
                self.assertNotIn(fixture, output)
                self.assertNotIn("AF80_SYNTHETIC_NON_SECRET", path.read_text())
                for word in (b"budget", b"cost", b"ceiling", b"tax", b"paid", b"us$"):
                    self.assertNotIn(word, output.lower())
            finally:
                if not reaped:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    try:
                        os.waitpid(pid, 0)
                    except ChildProcessError:
                        pass
                os.close(fd)


    def _interrupted_flow(self, at_send, sent_signal=None, eof=False):
        # Each child owns a fresh PTY and receives only this synthetic fixture.
        # None of these paths ever sends the owner confirmation token.
        fixture = b"AF80_SYNTHETIC_NON_SECRET_" + b"x" * 276
        with tempfile.TemporaryDirectory(prefix="af80-cli-interruption-") as temp:
            path = Path(temp) / "status.json"
            pid, fd = pty.fork()
            if pid == 0:
                os.execv(str(BINARY), command(path))
            output = b""
            entered = acted = reaped = False
            exit_code = None
            restored_echo = False
            deadline = min(time.monotonic() + 14, SUITE_DEADLINE)
            try:
                while time.monotonic() < deadline:
                    if select.select([fd], [], [], .025)[0]:
                        try:
                            chunk = os.read(fd, 4096)
                            output += chunk
                        except OSError:
                            chunk = b""
                    if not entered and b"Anthropic key (in memory only):" in output:
                        self.assertFalse(termios.tcgetattr(fd)[3] & termios.ECHO)
                        entered = True
                        if at_send:
                            os.write(fd, fixture + b"\n")
                    ready = entered and (not at_send or b"Type SEND to send the request" in output)
                    if ready and not acted:
                        if eof:
                            os.write(fd, b"\x04")
                        else:
                            os.kill(pid, sent_signal)
                        acted = True
                    done, code = os.waitpid(pid, os.WNOHANG)
                    if done:
                        reaped = True
                        exit_code = os.waitstatus_to_exitcode(code)
                        restored_echo = bool(termios.tcgetattr(fd)[3] & termios.ECHO)
                        break
                self.assertTrue(entered and acted and reaped, "synthetic interruption did not finish within 14 seconds")
                self.assertTrue(restored_echo, "child did not restore terminal echo")
                status_text = path.read_text()
                status = json.loads(status_text)
                self.assertFalse(status["requestStarted"])
                self.assertFalse(status["streamed"])
                self.assertLessEqual(set(status), FIELDS)
                self.assertNotIn("AF80_SYNTHETIC_NON_SECRET", status_text)
                self.assertNotIn(fixture, output)
                if eof and at_send:
                    self.assertEqual(exit_code, 0)
                    self.assertEqual(status["stage"], "owner_declined")
                elif eof:
                    self.assertEqual(exit_code, 1)
                    self.assertEqual(status["stage"], "failed")
                    self.assertEqual(status["failure"], "credential_entry")
                else:
                    self.assertEqual(exit_code, 128 + sent_signal)
                    self.assertEqual(status["stage"], "failed")
                    self.assertEqual(status["failure"], "cancelled")
            finally:
                if not reaped:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    try:
                        os.waitpid(pid, 0)
                    except ChildProcessError:
                        pass
                os.close(fd)

    def test_sigint_during_hidden_entry_restores_echo_and_records_cancelled(self):
        for attempt in range(3):
            with self.subTest(attempt=attempt):
                self._interrupted_flow(at_send=False, sent_signal=signal.SIGINT)

    def test_sigint_at_send_records_cancelled_without_request(self):
        for attempt in range(3):
            with self.subTest(attempt=attempt):
                self._interrupted_flow(at_send=True, sent_signal=signal.SIGINT)

    def test_sigterm_during_hidden_entry_records_cancelled(self):
        for attempt in range(3):
            with self.subTest(attempt=attempt):
                self._interrupted_flow(at_send=False, sent_signal=signal.SIGTERM)

    def test_sighup_during_hidden_entry_records_cancelled(self):
        for attempt in range(3):
            with self.subTest(attempt=attempt):
                self._interrupted_flow(at_send=False, sent_signal=signal.SIGHUP)

    def test_sighup_at_send_records_cancelled(self):
        for attempt in range(3):
            with self.subTest(attempt=attempt):
                self._interrupted_flow(at_send=True, sent_signal=signal.SIGHUP)

    def test_sigterm_at_send_records_cancelled(self):
        for attempt in range(3):
            with self.subTest(attempt=attempt):
                self._interrupted_flow(at_send=True, sent_signal=signal.SIGTERM)

    def test_eof_during_hidden_entry_fails_without_request(self):
        self._interrupted_flow(at_send=False, eof=True)

    def test_eof_at_send_declines_without_request(self):
        self._interrupted_flow(at_send=True, eof=True)


if __name__ == "__main__":
    signal.alarm(90)
    unittest.main(argv=[__file__], verbosity=2)

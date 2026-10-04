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


if __name__ == "__main__":
    unittest.main(argv=[__file__], verbosity=2)

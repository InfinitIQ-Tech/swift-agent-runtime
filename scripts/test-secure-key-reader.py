#!/usr/bin/env python3
"""Test only a synthetic key-reader harness inside an isolated owned PTY.

The harness calls readSecureProviderKey and prints RESULT_LENGTH or a fixed
RESULT_ERROR. This script never runs the live CLI, types SEND, uses a real
credential, or prints the supplied synthetic input.
"""
import argparse
import errno
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, help="Optional existing synthetic-only harness")
args = parser.parse_args()

# Compile the real helper when no external harness is supplied. The harness
# checks the exact synthetic value internally and never prints that value.
build = tempfile.TemporaryDirectory(prefix="af80-secure-reader-")
if args.binary is None:
    directory = Path(build.name)
    source = directory / "main.swift"
    source.write_text('''import Foundation
do {
    let value = try readSecureProviderKey()
    let prefix = "synthetic-nonsecret-"
    let expected = prefix + String(repeating: "x", count: 300 - prefix.utf8.count)
    guard value == expected else {
        print("RESULT_ERROR=synthetic input changed")
        exit(2)
    }
    print("RESULT_LENGTH=\\(value.utf8.count)")
} catch {
    print("RESULT_ERROR=\\(error)")
    exit(1)
}
''')
    args.binary = directory / "reader"
    helper = Path(__file__).resolve().parents[1] / "Sources/agent-runtime-demo/SecureKeyReader.swift"
    subprocess.run(["swiftc", str(helper), str(source), "-o", str(args.binary)], check=True, timeout=30)


def run_synthetic_input(length):
    synthetic = b"synthetic-nonsecret-" + b"x" * (length - len(b"synthetic-nonsecret-"))
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(str(args.binary.resolve()), [str(args.binary.resolve())])
    output = bytearray()
    supplied = False
    deadline = time.monotonic() + 8
    exited = False
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if not ready:
                continue
            try:
                data = os.read(fd, 8192)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not data:
                break
            output.extend(data)
            if not supplied and b"Anthropic key (in memory only): " in output:
                os.write(fd, synthetic + b"\n")
                supplied = True
            if b"RESULT_" in output:
                break
        observed, status = os.waitpid(pid, os.WNOHANG)
        if observed:
            exited = True
        result = bytes(output)
        # Return only derived booleans and the fixed diagnostic/result suffix.
        suffix = result.split(b"RESULT_", 1)[1].decode("utf-8", errors="replace").strip() if b"RESULT_" in result else "TIMEOUT"
        return supplied, synthetic not in result, suffix
    finally:
        os.close(fd)
        if not exited:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)


class SecureKeyReaderTests(unittest.TestCase):
    def test_longer_than_getpass_input_is_preserved_without_echo(self):
        supplied, hidden, result = run_synthetic_input(300)
        self.assertTrue(supplied, result)
        self.assertTrue(hidden, "synthetic terminal input was echoed")
        self.assertEqual(result, "LENGTH=300")

    def test_full_buffer_input_is_rejected_without_echo(self):
        supplied, hidden, result = run_synthetic_input(1023)
        self.assertTrue(supplied, result)
        self.assertTrue(hidden, "synthetic terminal input was echoed")
        self.assertEqual(result, "ERROR=provider key input exceeds the supported length")


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)

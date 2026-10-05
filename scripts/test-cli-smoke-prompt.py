#!/usr/bin/env python3
"""Credential-free smoke CLI checks; never opens the interactive key prompt."""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, required=True, help="Built agent-runtime-demo executable")
args = parser.parse_args()


class CloudSmokePromptTests(unittest.TestCase):
    def test_owner_action_has_no_budget_or_cost_text(self):
        # Static check is deliberate: reaching this branch dynamically would
        # require opening the owner-only credential prompt.
        source = (ROOT / "Sources/agent-runtime-demo/main.swift").read_text()
        entry = source.index("readSecureProviderKey()")
        branch_end = source.index("} else if !dryRun", entry)
        branch = source[entry:branch_end]
        prompts = re.findall(r'print\("([^"\n]*)"', branch)
        self.assertTrue(prompts, "owner action prompt missing")
        self.assertTrue(any("SEND" in prompt for prompt in prompts))
        self.assertIsNone(re.search(r"budget|cost|price|paid|tax|ceiling|US\$", " ".join(prompts), re.I))
        self.assertIn('let confirmation = readLine()', branch)
        self.assertIn('guard confirmation == "SEND"', branch)

    def test_dry_run_bypasses_key_and_send_prompts(self):
        result = subprocess.run(
            [str(args.binary.resolve()), "--manifest", str(ROOT / "Manifests/story-companion.agentconfig.json"),
             "--cloud-smoke-test", "--dry-run"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        output = result.stdout + result.stderr
        self.assertIn("Dry run complete", output)
        self.assertNotIn("Anthropic key (in memory only):", output)
        self.assertNotIn("Type SEND", output)
        self.assertIsNone(re.search(r"budget|cost|price|paid|tax|ceiling|US\$", output, re.I))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)

"""Keep the helper's local-source policy aligned with the Nim cache layers.

Both language implementations consume this same classification corpus. No
Nix, filesystem, or process behavior is mocked by these pure policy checks.
"""
import json
from pathlib import Path
import runpy
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NixEvaluationPolicy(unittest.TestCase):
    def test_helper_matches_the_shared_classification_corpus(self):
        helper = runpy.run_path(str(ROOT / "tools/reprobuild-nix-daemon/reprobuild-nix-daemon"))
        classify = helper["is_mutable_local_nix_selector"]
        cases = json.loads((ROOT / "tests/fixtures/nix-evaluation-policy.json").read_text())
        for case in cases:
            with self.subTest(selector=case["selector"]):
                self.assertEqual(classify(case["selector"]), case["local"])


if __name__ == "__main__":
    unittest.main()

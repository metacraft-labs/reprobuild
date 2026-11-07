#!/usr/bin/env python3
"""Keep recorder execution free of the monitor without caching blind verdicts.

No mocks: inspect the real generator and recipe, with mutation controls proving
each guard rejects removal of the policy. The behavioral witness is the real
HCR replay gate through its execute edge; this small contract test diagnoses
policy regressions without building the recorder first.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
STEM = "t_e2e_hcr_linux_replay_of_patched_recording"


def assert_recorder_classified(text: str) -> None:
    table = re.search(r"const SelfInterposingTestStems = \[(.*?)\]", text, re.S)
    assert table and f'"{STEM}"' in table[1], "recorder gate is still monitored"


def assert_recorder_not_cached(text: str) -> None:
    assert re.search(
        r'let recordsHcrChild = spec.source ==\s*"tests/e2e/hcr-linux-direct/'
        + STEM + r'\.nim"', text
    ), "recorder exception must identify only this execute edge"
    execute = text[text.index("let executeEdge = edge.testBinary.run("):]
    execute = execute[:execute.index("reprobuildTestExecuteActions.add")]
    assert "cacheable = not recordsHcrChild" in execute, "blind verdict may be cached"
    assert "dependencyPolicy = executePolicy" in execute
    policy = text[text.index("let executePolicy ="):text.index("let executeEdge =")]
    assert "if spec.selfInterposes:" in policy
    assert "@[spec.binary] & @(requiredBinaries)" in policy
    assert "makeDepfilePolicy(testDepfile, suppressMonitorShimSeed = true)" in policy
    assert "else:\n          automaticMonitorPolicy()" in policy


class RecorderMonitorPolicy(unittest.TestCase):
    def test_recorder_is_classified_and_removal_is_detected(self):
        text = (ROOT / "scripts/generate_test_edges.nim").read_text()
        assert_recorder_classified(text)
        with self.assertRaisesRegex(AssertionError, "still monitored"):
            assert_recorder_classified(text.replace(f'"{STEM}"', '"removed"'))

    def test_execute_edge_is_narrow_noncacheable_and_seedless(self):
        text = (ROOT / "repro.nim").read_text()
        assert_recorder_not_cached(text)
        for before, after in [
            ("cacheable = not recordsHcrChild", "cacheable = true"),
            ("suppressMonitorShimSeed = true", "suppressMonitorShimSeed = false"),
            ("@[spec.binary] & @(requiredBinaries)", "@[spec.binary]"),
            ("else:\n          automaticMonitorPolicy()", "else:\n          makeDepfilePolicy(testDepfile)"),
        ]:
            with self.subTest(before=before), self.assertRaises(AssertionError):
                assert_recorder_not_cached(text.replace(before, after))


if __name__ == "__main__":
    unittest.main()

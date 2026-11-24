"""The execution-phase worker count never exceeds the RunQuota grant.

``scripts/test_parallelism.sh`` derives the test-runner worker count from the
host (cores, available memory) and caps it at eight, the best full-suite
execution measured. When the suite runs under ``runquota run`` the lease's
width reaches it as RUNQUOTA_RUN_WIDTH, and the count must then be
``min(host-derived, grant)``: never above the grant, unchanged when the grant
is eight or more, unchanged when there is no lease.

No mocks: the real script is sourced by a real bash and its real functions are
called with fixed cores and memory (the functions take them as arguments, so
the result does not depend on the machine running the test).
"""

import os
import subprocess
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "test_parallelism.sh"

# 32 cores, 143 GB available: the host the eight-thread measurement was made
# on. Its derived budget is 24 and its derived thread count is 8.
CORES, MEM_MB = "32", "143000"


def call(function: str, grant=None, cores=CORES, mem=MEM_MB) -> str:
    env = {k: v for k, v in os.environ.items() if k != "RUNQUOTA_RUN_WIDTH"}
    if grant is not None:
        env["RUNQUOTA_RUN_WIDTH"] = grant
    out = subprocess.run(
        ["bash", "-c", f'source "{SCRIPT}"; {function} "$@" local', "x", cores, mem],
        env=env, capture_output=True, text=True, check=True)
    return out.stdout.strip()


class GrantClampsExecutionThreads(unittest.TestCase):
    def test_no_lease_keeps_the_measured_eight(self):
        self.assertEqual(call("reprobuild_default_test_threads"), "8")

    def test_a_grant_below_the_default_lowers_the_threads(self):
        self.assertEqual(call("reprobuild_default_test_threads", "3"), "3")
        self.assertEqual(call("reprobuild_default_test_threads", "1"), "1")

    def test_a_grant_of_eight_or_more_loses_nothing(self):
        for grant in ("8", "9", "24", "64"):
            self.assertEqual(
                call("reprobuild_default_test_threads", grant), "8", grant)

    def test_a_grant_never_raises_the_threads_above_the_host_default(self):
        # 8 cores, 16 GB: budget 6, host default 2 threads.
        self.assertEqual(
            call("reprobuild_default_test_threads", "16", "8", "16000"), "2")

    def test_a_malformed_or_zero_grant_is_no_grant(self):
        for grant in ("", "0", "abc", "-2", "3.5"):
            self.assertEqual(
                call("reprobuild_default_test_threads", grant), "8", repr(grant))

    def test_the_nested_split_does_not_grow_when_the_grant_shrinks(self):
        # Without the grant: 24 / 8 = 3. A grant of 2 must not turn the freed
        # share into 12 nested workers each.
        self.assertEqual(call("reprobuild_default_nested_build_parallelism"), "3")
        self.assertEqual(
            call("reprobuild_default_nested_build_parallelism", "2"), "3")

    def test_the_grant_width_reader(self):
        self.assertEqual(call("reprobuild_granted_width", "5"), "5")
        self.assertEqual(call("reprobuild_granted_width"), "")


if __name__ == "__main__":
    unittest.main()

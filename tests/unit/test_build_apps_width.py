"""`just build` compiles at a width its caller can set, not the dev shell's.

`scripts/build_apps.sh` passes every `nim c` a `--parallelBuild:N`, the number
of C compilers one Nim compile may run at once. It used to take N from
`NIX_BUILD_CORES`. Inside `nix develop` that variable belongs to the shell:
the shell derives it from the Nix `cores` setting and overwrites whatever the
caller exported, and on a host whose `cores` is 0 it is the CPU count. So
`NIX_BUILD_CORES=8 nix develop --command just build` compiled with
`--parallelBuild:32` on a 32-core shared host, and nothing a caller could set
lowered it.

The rule, implemented and documented by `scripts/lib/build_width.sh`:
`REPRO_BUILD_JOBS`, then a RunQuota grant (`RUNQUOTA_RUN_WIDTH`), then
`NIX_BUILD_CORES` only when `IN_NIX_SHELL` is unset, then a default of
`min(cores / 2, MiB available / 1024, 8)`, at least 1.

No mocks: the real resolver is sourced by a real bash with a controlled
environment. The default's inputs (cores, memory) are passed as arguments so
the expected values do not depend on the machine running the test. The two
source cases pin that `build_apps.sh` takes its width from the resolver and
prints it. `tests/unit/t_build_apps_reports_failure.sh` (`just
test-build-apps-script`) drives the whole script against a fake `nim` and
checks the flag each compile actually receives.
"""

import os
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESOLVER = ROOT / "scripts" / "lib" / "build_width.sh"
BUILD_APPS = ROOT / "scripts" / "build_apps.sh"

# Every variable the resolver reads; each case states the ones it sets.
WIDTH_VARS = ("REPRO_BUILD_JOBS", "RUNQUOTA_RUN_WIDTH", "NIX_BUILD_CORES",
              "IN_NIX_SHELL")

# The default's fixed inputs: a 32-core host with plenty of
# memory free, so the default is the cap, 8.
CORES, MEM_MB = "32", "143000"


def resolve(cores=CORES, mem=MEM_MB, **env_vars):
    """Run `repro_build_width` and return (exit status, stdout, stderr)."""
    env = {k: v for k, v in os.environ.items() if k not in WIDTH_VARS}
    env.update(env_vars)
    out = subprocess.run(
        ["bash", "-c", 'source "$0"; repro_build_width "$@"',
         str(RESOLVER), cores, mem],
        env=env, capture_output=True, text=True)
    return out.returncode, out.stdout.strip(), out.stderr.strip()


def width(**kwargs):
    status, stdout, stderr = resolve(**kwargs)
    if status != 0:
        raise AssertionError(f"resolver failed ({status}): {stderr}")
    return stdout


class TheDevShellsCoreCountIsNotTheWidth(unittest.TestCase):
    """The failing conditions: the dev shell has set NIX_BUILD_CORES=32."""

    SHELL = {"IN_NIX_SHELL": "impure", "NIX_BUILD_CORES": "32"}

    def test_the_caller_knob_wins_inside_the_dev_shell(self):
        self.assertEqual(width(REPRO_BUILD_JOBS="8", **self.SHELL),
                         "8 REPRO_BUILD_JOBS")

    def test_without_the_knob_the_shell_core_count_is_ignored(self):
        self.assertEqual(width(**self.SHELL), "8 default")
        self.assertEqual(width(cores="8", mem="64000", **self.SHELL),
                         "4 default")

    def test_a_lease_grant_is_the_width_inside_the_dev_shell(self):
        self.assertEqual(width(RUNQUOTA_RUN_WIDTH="3", **self.SHELL),
                         "3 RUNQUOTA_RUN_WIDTH")


class Precedence(unittest.TestCase):
    def test_a_real_nix_build_passes_its_request_through_verbatim(self):
        for request in ("0", "1", "2", "16"):
            self.assertEqual(width(NIX_BUILD_CORES=request),
                             f"{request} NIX_BUILD_CORES", request)

    def test_the_knob_wins_over_a_nix_build_and_a_grant(self):
        self.assertEqual(
            width(REPRO_BUILD_JOBS="3", NIX_BUILD_CORES="16",
                  RUNQUOTA_RUN_WIDTH="2"),
            "3 REPRO_BUILD_JOBS")

    def test_a_grant_wins_over_a_nix_build(self):
        self.assertEqual(width(RUNQUOTA_RUN_WIDTH="2", NIX_BUILD_CORES="16"),
                         "2 RUNQUOTA_RUN_WIDTH")

    def test_no_request_at_all_is_the_default_not_nims_per_core_zero(self):
        self.assertEqual(width(), "8 default")

    def test_empty_values_are_unset(self):
        self.assertEqual(
            width(REPRO_BUILD_JOBS="", RUNQUOTA_RUN_WIDTH="",
                  NIX_BUILD_CORES=""),
            "8 default")

    def test_a_malformed_or_zero_grant_is_no_grant(self):
        for grant in ("0", "abc", "-2", "3.5"):
            self.assertEqual(width(RUNQUOTA_RUN_WIDTH=grant), "8 default",
                             repr(grant))

    def test_a_malformed_knob_is_refused_naming_the_variable(self):
        for bad in ("0", "abc", "-2", "3.5", "8 "):
            status, stdout, stderr = resolve(REPRO_BUILD_JOBS=bad)
            self.assertNotEqual(status, 0, repr(bad))
            self.assertEqual(stdout, "", repr(bad))
            self.assertIn("REPRO_BUILD_JOBS", stderr, repr(bad))
            self.assertIn("not a positive integer", stderr, repr(bad))

    def test_leading_zeros_are_decimal(self):
        self.assertEqual(width(REPRO_BUILD_JOBS="08"), "8 REPRO_BUILD_JOBS")
        self.assertEqual(width(RUNQUOTA_RUN_WIDTH="0003"),
                         "3 RUNQUOTA_RUN_WIDTH")
        self.assertEqual(width(NIX_BUILD_CORES="000"), "0 NIX_BUILD_CORES")

    def test_nine_digits_is_the_largest_count(self):
        self.assertEqual(width(REPRO_BUILD_JOBS="999999999"),
                         "999999999 REPRO_BUILD_JOBS")
        self.assertEqual(width(REPRO_BUILD_JOBS="000000000016"),
                         "16 REPRO_BUILD_JOBS")

    def test_a_value_bash_would_wrap_is_not_a_count(self):
        # 2^63 wraps to a negative number and 20 nines to 7766279631452241919
        # in bash arithmetic; neither may reach `nim`.
        for huge in ("9223372036854775808", "9" * 20, "1000000000"):
            status, stdout, stderr = resolve(REPRO_BUILD_JOBS=huge)
            self.assertNotEqual(status, 0, huge)
            self.assertEqual(stdout, "", huge)
            self.assertIn("not a positive integer", stderr, huge)
            self.assertEqual(width(RUNQUOTA_RUN_WIDTH=huge), "8 default", huge)
            self.assertEqual(width(NIX_BUILD_CORES=huge), "8 default", huge)


class TheDefault(unittest.TestCase):
    def test_capped_at_eight(self):
        self.assertEqual(width(cores="64", mem="500000"), "8 default")

    def test_half_the_cores(self):
        self.assertEqual(width(cores="8", mem="64000"), "4 default")

    def test_memory_binds_at_one_gib_per_compiler(self):
        self.assertEqual(width(cores="32", mem="6000"), "5 default")

    def test_never_below_one(self):
        self.assertEqual(width(cores="1", mem="64000"), "1 default")
        self.assertEqual(width(cores="32", mem="512"), "1 default")
        self.assertEqual(width(cores="abc", mem="64000"), "1 default")

    def test_unmeasurable_memory_leaves_cores_and_cap(self):
        self.assertEqual(width(cores="12", mem=""), "6 default")


class BuildAppsUsesTheResolver(unittest.TestCase):
    """The script's own wiring: what it hands `nim`, and what it prints."""

    def setUp(self):
        self.text = BUILD_APPS.read_text(encoding="utf-8")
        # Shell code only: comments may name the old expansion.
        self.code = "\n".join(
            line for line in self.text.splitlines()
            if not line.lstrip().startswith("#"))

    def test_the_width_flag_comes_from_the_resolver(self):
        self.assertIn("source scripts/lib/build_width.sh", self.code)
        self.assertRegex(self.code, r'build_width_resolved="\$\(repro_build_width\)"')
        flags = re.findall(r"--parallelBuild:[^\s)]*", self.code)
        self.assertEqual(sorted(flags),
                         ['--parallelBuild:"${build_width}"',
                          "--parallelBuild:${build_width}"],
                         "every --parallelBuild in build_apps.sh is the "
                         "resolved width (the log line and the flag)")
        self.assertNotIn("NIX_BUILD_CORES", self.code)

    def test_the_width_is_printed(self):
        self.assertIn(
            'echo "build_apps: C-compile width --parallelBuild:${build_width} '
            '(from ${build_width_resolved#* }', self.code)


if __name__ == "__main__":
    unittest.main()

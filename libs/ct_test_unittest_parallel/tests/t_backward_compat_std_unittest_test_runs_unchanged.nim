## M2 verification: backward compatibility — a test source written
## against ``std/unittest`` must run identically when the binary is
## NOT given protocol flags, regardless of whether the
## ``ct_test_unittest_parallel`` library is on ``--path``.
##
## Strategy: build a tiny fixture that imports ONLY ``std/unittest``
## (does NOT import ``ct_test_unittest_parallel``) and exercises
## ``suite``/``test``/``check``. Confirm that:
##
## 1. The binary compiles cleanly.
## 2. The binary's stdout in default mode matches the standard
##    ``std/unittest`` console-formatter output (``[Suite]`` /
##    ``[OK]`` / ``[FAILED]`` lines).
## 3. The binary's exit code is the standard ``std/unittest``
##    convention: 0 if all tests pass, 1 otherwise.
##
## This validates that the M1 reprobuild suite — whose ~385 test
## files all use ``import std/unittest`` — stays runnable without
## modifications.

import std/[os, osproc, strutils]
import std/unittest
from repro_test_support import ctShimFixturePath, requireBinary

# Graph-Owned-Test-Artifacts M3: the baseline fixture is built by edge
# ``reprobuild.test_fixtures.ct_shim_fixture_baseline`` and declared as a typed
# input on this test's execute edge (``testFixtureArtifacts`` in ``repro.nim``).
#
# ASSERTION 1 IN THE DOCSTRING ABOVE — "the binary compiles cleanly" — IS NOT
# DROPPED BY THIS CHANGE, it is RELOCATED. A ``nim c`` in a test body reports a
# broken fixture as a failing test; a build edge reports it as a failing build,
# before the suite runs at all. Both are red, the second is earlier and names
# the artifact. Assertions 2 and 3 are about the binary's stdout shape and its
# exit-code convention and are untouched.
#
# The old output path was ``build/test-bin/…``, which the suite runner
# enumerates; the graph edge writes under ``build/test-fixtures/`` instead so a
# fixture is never mistaken for a test of this repository.
proc buildFixture(): string =
  requireBinary(ctShimFixturePath("fixture_baseline_std_unittest"),
    "reprobuild.test_fixtures.ct_shim_fixture_baseline")

suite "t_backward_compat_std_unittest_test_runs_unchanged":
  test "fixture_runs_with_std_unittest_output_shape":
    let binary = buildFixture()
    let (output, exitCode) = execCmdEx(binary)
    check exitCode == 0
    check "[Suite]" in output
    check "[OK]" in output
    # Confirms the standard ``std/unittest`` console formatter was
    # the one that produced the output (i.e. our library did not
    # silently take over). With no protocol flags and no import of
    # ct_test_unittest_parallel, our library is not even linked into
    # the binary, so the standard formatter is the only one present.
    check "baseline_suite" in output
    check "baseline_test_passes" in output

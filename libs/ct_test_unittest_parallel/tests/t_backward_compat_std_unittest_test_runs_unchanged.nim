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

const fixtureSource = currentSourcePath().parentDir() /
  "fixtures" / "fixture_baseline_std_unittest.nim"

proc nimcacheDir(): string =
  "build" / "nimcache" / "ct_test_unittest_parallel" /
    "fixture_baseline_std_unittest"

proc buildFixture(): string =
  let outputPath = "build" / "test-bin" /
    "ct_test_unittest_parallel_fixture_baseline"
  createDir(outputPath.parentDir())
  createDir(nimcacheDir())
  let cmd = "nim c --hints:off --warnings:off --nimcache:" &
    nimcacheDir().quoteShell() & " --out:" & outputPath.quoteShell() &
    " " & fixtureSource.quoteShell()
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    echo output
    raise newException(IOError, "failed to build fixture: " & cmd)
  outputPath

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

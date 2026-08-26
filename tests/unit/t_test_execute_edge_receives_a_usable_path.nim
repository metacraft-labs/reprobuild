## A test binary the engine runs must be given a `PATH` it can use.
##
## ## WHY A TEST WHOSE ONLY SUBJECT IS ITS OWN ENVIRONMENT
##
## Every other test in this corpus asserts something about reprobuild.
## This one asserts something about the HARNESS: that the
## `reprobuild.test_execute.<stem>` edge which launches it composed a
## usable `PATH`. That is a strange thing to test from the inside, and
## it exists because there was no way to test it from the outside.
##
## `just test` runs `scripts/run_tests.sh`, which walks `build/test-bin/*`
## and executes each binary directly through `ct-test-runner`. Those
## processes inherit the dev shell's environment, so they see the dev
## shell's `PATH` no matter what the engine's execute edges compose. CI
## is therefore structurally blind to the entire class of defect where
## the engine hands a test binary the wrong environment — the binaries
## it exercises never went through an execute edge.
##
## `tests/integration/t_b3_repro_test_runs_through_engine.nim` DOES drive
## `repro build .#test#<name>`, but its target is
## `t_dsl_outputs_statement_basic_accepted`, a parse-only DSL test that
## touches no environment at all, so it too reports green under any
## `PATH` whatsoever.
##
## ## THE DEFECT THAT PASSED THROUGH THAT BLIND SPOT
##
## Three lowering sites in `repro_cli_support.nim` began emitting
## `PATH=` — an empty value — for every edge that resolved no tool
## directories. `prependPathDirsToArgvEnv`
## (`repro_build_engine.nim:3502-3551`) treats a declared `PATH` as a
## REPLACEMENT for the inherited one, so those actions ran with no
## `PATH`. MEASURED: 1372 of 2753 process actions on this repository's
## `test` graph, i.e. every `reprobuild.test_execute.*` edge.
##
## What that did to the corpus is worse than failing it. 504 of the 1372
## registered Nim test sources call
## `findExe`/`execCmdEx`/`execCmd`/`execProcess`/`startProcess`/`poUsePath`,
## and the corpus idiom is:
##
##     let gitBin = findExe("git")
##     if gitBin.len == 0: skip()
##
## With no `PATH`, `findExe` returns `""` and the test SKIPS. Measured
## end to end on `t_workspace_root_for_repo_managed_worktree`:
## `repro build '.#test#…'` reported `asSucceeded exit=0` with
## `[SKIPPED]` in its output, and the next invocation served that result
## from cache (`cdHit`, `asUpToDate`). A green, cacheable pass for a
## test that ran nothing.
##
## ## SO THIS TEST CANNOT SKIP
##
## It asserts, without a skip branch, the two things the harness owes a
## test binary. Run directly (the `just test` path) both are trivially
## true and this costs nothing. Run through an execute edge — which
## `tests/integration/t_execute_edge_gives_tests_a_usable_path.nim`
## does, deliberately and with `--force-rebuild` — they are exactly the
## property that was broken.
##
## `git` is the probe tool because it is the one the corpus actually
## depends on: it appears in 441 of the 504 sources' `findExe` literals,
## it is a declared dependency of this workspace (the repo tool manages
## the checkout), and `scripts/run_tests.sh` already runs inside a shell
## that has it.
##
## ## NO MOCKS
##
## There is nothing here to mock. The subject is the real process
## environment of the real running process.

import std/[os, osproc, strutils, unittest]

suite "a test binary is given a usable PATH":
  test "PATH is set and non-empty":
    # The direct form of the defect. `PATH=` (empty) and `PATH` unset
    # are different things to the launcher and the same thing to
    # `findExe`, so both fail here.
    let path = getEnv("PATH")
    checkpoint("PATH has " & $path.len & " bytes, " &
      $path.split($PathSep).len & " entries")
    check path.len > 0

  test "a bare-name host tool the corpus depends on resolves":
    # The consequence of the defect, stated the way 441 of this
    # corpus's sources state it. This one does NOT skip when the tool is
    # missing: skipping is the failure mode under test.
    let gitBin = findExe("git")
    checkpoint("findExe(\"git\") -> " & gitBin)
    check gitBin.len > 0

  test "the resolved tool actually runs":
    # Non-vacuity for the case above: `findExe` returning a path is not
    # the same as the process being able to execute it. An action whose
    # PATH names directories it cannot reach would satisfy the string
    # assertion and still be unable to run anything.
    let res = execCmdEx("git --version",
      options = {poStdErrToStdOut, poUsePath})
    checkpoint("git --version -> exit=" & $res.exitCode & " " &
      res.output.strip())
    check res.exitCode == 0
    check res.output.contains("git")

## A PATH-dependent test, driven through a REAL `reprobuild.test_execute.*`
## edge, must report OK — not SKIPPED, and not a green no-op.
##
## ## WHY THIS FILE EXISTS: THE TEST SURFACE COULD NOT SEE THE DEFECT
##
## `just test` -> `scripts/run_tests.sh` walks `build/test-bin/*` and
## runs each binary directly through `ct-test-runner`. Those processes
## inherit the dev shell's environment. Whatever the engine's execute
## edges compose into `action.env` is therefore never exercised by CI,
## so the whole class "the engine hands a test binary a broken
## environment" is structurally invisible to the suite.
##
## `t_b3_repro_test_runs_through_engine.nim` does drive
## `repro build .#test#<name>` through the engine, which is the right
## shape — but its target is `t_dsl_outputs_statement_basic_accepted`, a
## parse-only DSL test that reads no environment. It reports green under
## any `PATH`, including none.
##
## The consequence, measured. Three lowering sites in
## `repro_cli_support.nim` emitted `PATH=` (empty) for every edge that
## resolved no tool directories — 1372 of 2753 process actions on this
## repository's `test` graph, i.e. every `reprobuild.test_execute.*`
## edge. `prependPathDirsToArgvEnv` treats a declared `PATH` as a
## REPLACEMENT of the inherited one, so those actions ran with none.
## `t_workspace_root_for_repo_managed_worktree` answered
## `findExe("git") == ""` by calling `skip()`, and the edge reported
## `asSucceeded exit=0` and then `cdHit` — a green, CACHEABLE pass for a
## test that executed nothing. Every gate in the suite stayed green.
##
## ## WHAT THIS DRIVES, AND WHY WITH --force-rebuild
##
## `t_test_execute_edge_receives_a_usable_path` is a corpus test whose
## whole subject is the environment its execute edge gave it, and which
## deliberately has no skip branch. Driving it here through
## `repro build .#test#<stem>` is the only place in the suite where a
## PATH-dependent test binary is launched by the engine rather than by
## the shell.
##
## `--force-rebuild` is not belt and braces. The defect's signature
## outcome is a CACHED green: without forcing execution, a stale record
## from a run made while the defect was present would be served, the
## action would report `asUpToDate`, and this gate would assert nothing.
## The action must be `launched`, and that is checked.
##
## ## FAILURE IS FAILURE
##
## There is no classifier and no skip branch except the build-order one
## (`build/bin/repro` must exist). A missing `runquotad` is a hard
## fixture error, matching `t_b3_repro_test_runs_through_engine.nim`.
## The one thing this file must never do is convert an environment
## problem into a pass, since that is precisely the defect it guards.
##
## ## NO MOCKS
##
## Real `repro build`, real lowering, real engine scheduler, real
## execute edge, real forked test binary, real build report read back
## off disk.

import std/[json, os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support

const RepoMarker = "repro.nim"

const TargetTest = "t_test_execute_edge_receives_a_usable_path"
  ## The corpus test whose subject is its own `PATH`. See
  ## `tests/unit/t_test_execute_edge_receives_a_usable_path.nim`.

const ExecuteActionId = "reprobuild.test_execute." & TargetTest

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc runWithRunquotaOnPath(cmd, repoRoot: string): tuple[output: string;
    exitCode: int] =
  let runquotaBin = requireRunQuotaDaemonBin(repoRoot).parentDir
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["PATH"] = runquotaBin & $PathSep & env.getOrDefault("PATH")
  execCmdEx(cmd, env = env, workingDir = repoRoot)

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc lineWith(output, needle: string): string =
  for line in output.splitLines:
    if line.contains(needle):
      return line
  ""

suite "a real execute edge gives a test binary a usable PATH":

  test "the corpus fixture exists and declares no skip branch":
    ## Structural, and it runs without the engine. The engine arm below
    ## is only evidence if the fixture it drives would actually fail
    ## under an empty `PATH` — a fixture that had grown a `skip()` would
    ## make the whole file vacuous in exactly the way the defect did.
    let repoRoot = findRepoRoot()
    let fixture = repoRoot / "tests" / "unit" / (TargetTest & ".nim")
    check fileExists(fixture)
    let source = readFile(fixture)

    # No skip branch: the fixture must not be able to report green
    # without running.
    var skipCalls: seq[string] = @[]
    for line in source.splitLines:
      let stripped = line.strip()
      if stripped.startsWith("#") or stripped.startsWith("##"):
        continue
      if stripped.contains("skip()"):
        skipCalls.add(stripped)
    checkpoint("skip() calls in the fixture: " & $skipCalls)
    check skipCalls.len == 0

    # And it must actually depend on `PATH`, or it would pass under an
    # empty one.
    check source.contains("getEnv(\"PATH\")")
    check source.contains("findExe(")

    # The generator must have picked it up, or `.#test#<stem>` resolves
    # to nothing and the engine arm below cannot run.
    let reproTests = readFile(repoRoot / "repro_tests.nim")
    check reproTests.contains("tests/unit/" & TargetTest & ".nim")

  test "engine: the execute edge runs it, and it reports OK not SKIPPED":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    else:
      discard requireRunQuotaDaemonBin(repoRoot)
      let scratch = createTempDir("repro-d1-execute-path-", "")
      defer: removeDir(scratch)
      let reportPath = scratch / "report.json"

      # ISOLATED ROOTS, AND THIS IS THE PART THAT MAKES THE GATE REAL.
      #
      # `--force-rebuild` forces the ACTION to re-execute; it does not
      # force the GRAPH to be re-lowered. With the shared roots the
      # lowered graph is served from cache (`loweredGraphCache: hit`)
      # and the lowering never runs — MEASURED: with the D1 fix reverted
      # in `repro_cli_support.nim` and `build/bin/repro` rebuilt from
      # that source, this case still PASSED on the shared roots, because
      # the cached lowered graph still carried the good `PATH`. A gate
      # that cannot see its own subject is the defect this file exists
      # to end, so the roots are per-run.
      #
      # The price is a cold provider compile and a cold `nim c` of the
      # fixture on every run. That is the cost of the only place in the
      # suite where a PATH-dependent test binary is launched by the
      # engine rather than by the shell.
      let workRoot = scratch / "work"
      let cacheRoot = scratch / "cache"
      # `--no-runquota` because the property under test is the action's
      # ENVIRONMENT, not resource gating, and the auto-started daemon is
      # the one part of this invocation that can fail for reasons having
      # nothing to do with the subject (a loaded host times out the
      # `runquotad did not become reachable` wait). The RunQuota surface
      # has its own dedicated tests; borrowing it here would only add a
      # flake channel. `t_b3_repro_test_runs_through_engine.nim`'s flag
      # case does the same.
      let args = @[
        reproBin.quoteShell, "build", ".#test#" & TargetTest,
        "--tool-provisioning=path", "--daemon=off", "--no-runquota",
        "--force-rebuild",
        "--work-root=" & workRoot.quoteShell,
        "--action-cache-root=" & cacheRoot.quoteShell,
        "--write-report=" & reportPath.quoteShell,
        "--log=actions", "--progress=quiet"]
      let cmd = args.join(" ")
      checkpoint("running: " & cmd)
      let (output, exitCode) = runWithRunquotaOnPath(cmd, repoRoot)
      if exitCode != 0:
        checkpoint(output)
      check exitCode == 0

      # THE BUILD HEADER'S OWN CENSUS. `environmentInheritanceHeaderLine`
      # counts, per graph, how many process actions carry an empty
      # `PATH=`. It must be zero, and the line must be present at all —
      # a header that stopped reporting the number would otherwise
      # satisfy a `notin` check by saying nothing.
      let envLine = lineWith(output, "env: ")
      checkpoint("build header env line: " & envLine)
      check envLine.contains("PATH:")
      check envLine.contains("0 EMPTY")
      check "DEFECT" notin envLine

      check fileExists(reportPath)
      let report = parseFile(reportPath)
      var executeAction: JsonNode = nil
      let actions = report{"actions"}
      if not actions.isNil and actions.kind == JArray:
        for candidate in actions:
          if candidate{"id"}.getStr() == ExecuteActionId:
            executeAction = candidate
            break

      if executeAction.isNil:
        checkpoint("no " & ExecuteActionId & " in the build report; the " &
          "execute edge did not run through the engine")
        checkpoint(output)
        check not executeAction.isNil
      else:
        let status = executeAction{"status"}.getStr()
        let stdoutText = executeAction{"stdout"}.getStr()
        let stderrText = executeAction{"stderr"}.getStr()
        checkpoint(ExecuteActionId & " status=" & status &
          " cacheDecision=" & executeAction{"cacheDecision"}.getStr() &
          " launched=" & $executeAction{"launched"}.getBool())
        checkpoint("--- action stdout ---\n" & stdoutText)
        if stderrText.len > 0:
          checkpoint("--- action stderr ---\n" & stderrText)

        # It must have RUN. A cache hit here would make every assertion
        # below a statement about a previous run's environment, which is
        # the exact shape the defect produced.
        check executeAction{"launched"}.getBool()
        check status == "asSucceeded"

        # And it must have run its cases rather than skipping them. This
        # is the assertion the whole file exists for: under the defect
        # the action exited 0 with `[SKIPPED]` on its output.
        check "[SKIPPED]" notin stdoutText
        check "[FAILED]" notin stdoutText
        check stdoutText.contains("[OK]")

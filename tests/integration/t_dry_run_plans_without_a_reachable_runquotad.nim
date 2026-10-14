## t_dry_run_plans_without_a_reachable_runquotad — ``repro build --dry-run``
## reports its plan on a host where no RunQuota daemon can be reached.
##
## THE DEFECT (reprobuild-pm issue 2026-09-20, "``--dry-run`` is unspecified,
## and in practice requires a reachable runquotad").
## ``runBuildCommand``'s direct path called ``startAutoRunQuotaIfNeeded``
## before it entered the engine, for every build, and a dry run was a build as
## far as that call was concerned. A dry run launches nothing — the scheduler
## completes every action it reaches as ``asWouldRun`` without a lease, a
## process or an output — so there was nothing for RunQuota to admit, yet an
## unreachable ``runquotad`` ended the command with
##
##     repro build: error: runquotad did not become reachable at <endpoint>
##
## That gated the one command whose entire output is a plan on a daemon the
## plan never uses, on precisely the host the flag is most wanted on: one whose
## environment is not working yet. ``--no-runquota`` was the only way through.
## ``reprobuild-pm/spec/CLI/build.md`` §"Dry Run" now settles it: a dry run
## implies ``--no-runquota``, and an explicit ``--runquota`` still asks for
## the handshake.
##
## WHAT THIS RUNS. The real ``repro`` binary over a real one-action project,
## with the fault injected at the two places the product itself reads the
## environment for RunQuota:
##
##   * ``RUNQUOTAD_BIN`` — ``findRunQuotaDaemonBin``'s documented operator
##     override — names ``false``, a real executable that really is spawned and
##     really exits without binding an endpoint. It is the smallest possible
##     "runquotad that never becomes reachable", and it is not a fake daemon:
##     it implements no part of the RunQuota protocol and nothing here pretends
##     it does. The alternative — no ``runquotad`` anywhere — does NOT
##     reproduce the defect: an undiscoverable daemon returns nil silently and
##     the build falls through to the bypass. The defect needs a daemon that is
##     found and then fails to serve, which is what the reporter's host had.
##   * ``RUNQUOTA_SOCKET`` names a path nothing serves, so
##     ``isRunQuotaDaemonReachable``'s probe (which resolves it through
##     ``runquota_ipc.defaultEndpoint``) answers false on a host running the
##     shipped daemon and on a bare one alike. Without it both cases would be
##     decided by whatever daemon happens to be listening on the host-wide
##     endpoint.
##
## Nothing inside reprobuild is stubbed, and no diagnostic text is classified
## to decide an outcome.
##
## FALSIFIABILITY — the positive control is a CASE, not a comment. The same
## project and the same injection WITHOUT ``--dry-run`` must still fail, and
## must fail with that sentence, which the product raises only after it has
## really spawned the binary and really waited for it. So the dry run's green
## cannot come from the daemon having turned out to be unnecessary for a real
## build, from the injector never being reached, or from a host that quietly
## had a reachable daemon all along. Revert the ``dryRun`` implication in
## ``runBuildCommand`` and the first case fails with the control's message.
##
## POSIX ONLY, AND THE REASON IS IN THE PRODUCT, NOT IN THE FIX. The injection
## above reaches the spawn arm on Windows too — ``defaultEndpoint`` honours
## ``RUNQUOTA_SOCKET`` there as well, mapping a non-pipe path onto
## ``\\.\pipe\runquota-<token>``, so the probe answers false and the spawn
## happens. What is not deterministic is what comes AFTER the spawn: that arm
## deliberately clears ``RUNQUOTA_SOCKET`` and lets ``runquotad`` bind the
## host-wide pipe, so the reachability poll that follows consults the host-wide
## endpoint. On a Windows host already serving it, the poll succeeds, the
## handshake is satisfied by a daemon the test never injected, and the CONTROL
## case would pass with exit 0 — a green that proves nothing. The implication
## under test is parsed once in ``runBuildCommand`` and is
## platform-independent; what cannot be made deterministic on Windows is the
## fault, not the fix.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt))

const
  # The build report names the fixture's one edge by its target name, not by
  # the ``actionId`` the recipe passes.
  PlannedAction = "greet"
  Unreachable = "runquotad did not become reachable"

  # One ``sh`` action with a declared output: the plan then has exactly one
  # edge to report, and the control has exactly one edge it would have had to
  # take a lease for.
  Fixture = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package dryRunRunQuotaProbe:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    let greet = shell(
      command = "mkdir -p build && printf 'planned\\n' > build/greet.txt",
      actionId = "dry-run-runquota.greet",
      extraOutputs = @["build/greet.txt"])
    discard target("greet", greet)
"""

# One project, one action cache and one work root for the whole suite: a build
# of a fresh project compiles that project's provider first, which costs over a
# minute. The control never reaches the engine — it dies at the RunQuota
# handshake — so it writes nothing the other case could read, and a dry run
# records no action result, so neither case depends on the other's state.
let project = createTempDir("repro-dry-run-runquota-", "")
let cacheRoot = project / "action-cache"
let workRoot = project / "work"

type BuildRun = object
  exitCode: int
  output: string

proc unmeetableRunQuota() =
  ## Point the product's own two environment hooks at an endpoint that cannot
  ## be served, and clear the two switches that would pre-empt the fault. Set
  ## per case rather than once, so a case cannot pass because another one
  ## happened to set it.
  putEnv("RUNQUOTAD_BIN", findExe("false"))
  putEnv("RUNQUOTA_SOCKET", project / "nothing-serves-this.sock")
  # THE AMBIENT ENVIRONMENT CAN DISABLE WHAT THIS TEST MEASURES, so it is
  # removed rather than hoped about. Both of these make `repro build` skip the
  # handshake for EVERY build, which would leave the control case green
  # against a daemon it never met — the one failure mode that would make the
  # other cases prove nothing:
  #
  #   * `REPROBUILD_NO_RUNQUOTA` is the full-bypass switch, and the engine
  #     FORCES it into the environment of every action child (`launchChildEnv`)
  #     so a nested `repro` does not request a second lease. A test executed
  #     through a test-execute edge inherits it. Measured: with it set, the
  #     control case fails — correctly, because a bypassed build really does
  #     not require the daemon. This test is about the `--dry-run` implication,
  #     not about that switch.
  #   * `REPROBUILD_AUTO_RUNQUOTA=0` turns the auto-spawn off entirely, so
  #     `RUNQUOTAD_BIN` would never be consulted.
  delEnv("REPROBUILD_NO_RUNQUOTA")
  putEnv("REPROBUILD_AUTO_RUNQUOTA", "1")

proc runBuild(extra: openArray[string]): BuildRun =
  ## One build of the fixture project. ``--no-runquota`` is deliberately NOT
  ## passed: having to pass it is the defect.
  var args = @["build", "greet"]
  for arg in extra:
    args.add(arg)
  args.add(["--tool-provisioning=path", "--daemon=off", "--progress=quiet",
    "--measure=none", "--log=summary",
    "--action-cache-root=" & cacheRoot, "--work-root=" & workRoot])
  var command = quoteShell(reproBin)
  for arg in args:
    command.add(" " & quoteShell(arg))
  let res = execCmdEx(command, workingDir = project)
  BuildRun(exitCode: res.exitCode, output: res.output)

proc explain(run: BuildRun): string =
  "exit=" & $run.exitCode & "\n--- output ---\n" & run.output

proc plannedActions(reportPath: string): seq[string] =
  ## Every action the build report says the dry run WOULD have launched.
  let payload = parseJson(readFile(reportPath))
  if not payload.hasKey("actions"):
    return @[]
  for entry in payload["actions"]:
    if entry{"wouldLaunch"}.getBool(false):
      result.add(entry{"id"}.getStr(""))

proc missingPrerequisite(): string =
  if defined(windows):
    return "on Windows the spawn arm clears RUNQUOTA_SOCKET and binds the " &
      "host-wide pipe, so the poll after the spawn can be satisfied by a " &
      "daemon this test never injected and the control case would pass " &
      "vacuously; see this file's header"
  if not fileExists(reproBin):
    return reproBin & " is missing; run `just build` first"
  if findExe("sh").len == 0:
    return "the fixture's one action needs `sh` on PATH"
  if findExe("false").len == 0:
    return "the RunQuota fault injector needs `false` on PATH"
  ""

suite "repro build --dry-run without a reachable runquotad":

  test "a dry run reports its plan instead of failing the handshake":
    let missing = missingPrerequisite()
    if missing.len > 0:
      skip(missing)
    else:
      writeFile(project / "repro.nim", Fixture)
      createDir(cacheRoot)
      createDir(workRoot)
      unmeetableRunQuota()
      let reportPath = project / "dry-run-report.json"
      let run = runBuild(["--dry-run", "--write-report=" & reportPath])
      checkpoint(explain(run))
      check run.exitCode == 0
      check Unreachable notin run.output
      check fileExists(reportPath)
      if fileExists(reportPath):
        # Not merely "it exited 0": the dry run has to have produced the plan
        # the flag exists for.
        check PlannedAction in plannedActions(reportPath)

  test "a dry run under --strategy plans without the daemon too":
    ## `--strategy <s>` generates a HIDDEN lock and solves it before the build,
    ## and that solve starts a RunQuota daemon of its own
    ## (`solverInputsFromCompiledProvider`) through a code path that takes no
    ## flag — it reads only `REPROBUILD_NO_RUNQUOTA`. So the implication has to
    ## be EXPORTED, not merely held in a local: without that, this case fails
    ## with the handshake error raised from inside the solve, while the case
    ## above passes. It is the one path that distinguishes "the dry run does
    ## not require a daemon" from "the dry run's main graph does not".
    let missing = missingPrerequisite()
    if missing.len > 0:
      skip(missing)
    else:
      writeFile(project / "repro.nim", Fixture)
      createDir(cacheRoot)
      createDir(workRoot)
      unmeetableRunQuota()
      let run = runBuild(["--dry-run", "--strategy", "lowest"])
      checkpoint(explain(run))
      check run.exitCode == 0
      check Unreachable notin run.output

  test "the same build without --dry-run still requires the daemon":
    ## The control. It is what makes the case above an assertion about
    ## ``--dry-run`` rather than about this host.
    let missing = missingPrerequisite()
    if missing.len > 0:
      skip(missing)
    else:
      writeFile(project / "repro.nim", Fixture)
      createDir(cacheRoot)
      createDir(workRoot)
      unmeetableRunQuota()
      let run = runBuild([])
      checkpoint(explain(run))
      check run.exitCode != 0
      check Unreachable in run.output

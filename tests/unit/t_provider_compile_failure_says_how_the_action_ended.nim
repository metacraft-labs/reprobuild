## A FAILED PROVIDER COMPILE MUST SAY HOW IT ENDED.
##
## A provider compile run under `repro exec` crashed before writing a byte (a
## hook library preloaded into every monitored process recursed until the
## stack overflowed), and the whole report `repro exec` gave was
##
##     repro exec: error: __repro_provider_compile asFailed
##
## The report is built from the action's captured output, and a process killed
## by a signal leaves none. It has to carry the signal or exit status the
## engine recorded, and say plainly that the action wrote nothing, so the
## failure can be read from the output the caller keeps. A blocked action
## names the action that blocked it.
##
## NO MOCKS. A real engine run (`runBuild`) of real `sh` actions, one of which
## kills itself with SIGSEGV without writing a byte, read through the shipped
## `providerCompileFailure` (repro_dev_env_engine) and `describeFailedAction`
## (repro_build_engine), which the dev-env and profile-compile edges share.

import std/[os, strutils, tempfiles, unittest]
when defined(posix):
  import std/posix
import repro_test_support/reasoned_skip

import repro_build_engine
import repro_core
import repro_dev_env_engine

const NoShell = "no `sh` on PATH; the actions under test are shell scripts"

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc shellAction(sh, root, id, script: string;
                 deps: openArray[string] = []): BuildAction =
  action(id, [sh, "-c", script], cwd = root, deps = deps,
    weakFingerprint = weakFingerprintFromText("provider-failure." & id),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc build(root: string; actions: openArray[BuildAction]): BuildRunResult =
  var config = defaultBuildEngineConfig(root / "cache")
  config.bypassRunQuota = true
  config.maxParallelism = 1'u32
  runBuild(graph(actions), config)

suite "a failed provider compile says how it ended":

  test "a silent crash names the signal and its empty output":
    when not defined(posix):
      skip("a process killed by a signal is a POSIX outcome")
    else:
      let sh = findExe("sh")
      if sh.len == 0:
        skip(NoShell)
      else:
        let root = createTempDir("repro-provider-failure-", "")
        defer: removeDir(root)
        let res = build(root, [
          shellAction(sh, root, "__repro_provider_compile", "kill -SEGV $$"),
          shellAction(sh, root, "after", "true",
            deps = ["__repro_provider_compile"])])
        let crashed = res.byId("__repro_provider_compile")
        checkpoint("status=" & $crashed.status & " exit=" & $crashed.exitCode &
          " signal=" & $crashed.termSignal)
        require crashed.status == asFailed
        require crashed.launched
        require crashed.stdout.len == 0 and crashed.stderr.len == 0
        # The launch reports a signal death as exit code -1, so the signal is
        # the only part of the result that says the process crashed.
        require crashed.termSignal == int(SIGSEGV)

        let report = providerCompileFailure(res)
        checkpoint(report)
        # Before the fix the report was exactly this line and nothing else.
        check report != "__repro_provider_compile asFailed"
        check report.startsWith("__repro_provider_compile asFailed")
        check ("killed by signal " & $int(SIGSEGV)) in report
        check "wrote nothing to stdout or stderr" in report

        let blocked = describeFailedAction(res.byId("after"))
        checkpoint(blocked)
        check res.byId("after").status == asBlocked
        check "blocked by __repro_provider_compile" in blocked

  test "an action that wrote output is reported with that output":
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    else:
      let root = createTempDir("repro-provider-failure-", "")
      defer: removeDir(root)
      let res = build(root, [shellAction(sh, root, "__repro_provider_compile",
        "echo 'Error: undeclared identifier' >&2; exit 3")])
      let report = providerCompileFailure(res)
      checkpoint(report)
      check "exit code 3" in report
      check "killed by signal" notin report
      check "Error: undeclared identifier" in report
      check "wrote nothing" notin report

suite "a failure that never launched still says why":

  test "an unlaunched failure reports its recorded cause, not just the id":
    # The shape of the reported `__repro_provider_compile asFailed`: the
    # engine failed the action before launching it, so there is no exit code
    # and no output; the cause lives in `missingOutputs`, the evidence
    # diagnostics or `reason`.
    let missing = ActionResult(id: "__repro_provider_compile",
      status: asFailed, missingOutputs: @["/o/provider"])
    check "/o/provider" in describeFailedAction(missing)
    var evidence = ActionResult(id: "__repro_provider_compile",
      status: asFailed)
    evidence.evidence.diagnostics.add("dependency report missing: /x.iomon")
    check "dependency report missing: /x.iomon" in describeFailedAction(evidence)
    let reasoned = ActionResult(id: "__repro_provider_compile",
      status: asFailed, reason: "monitor-plan-refused")
    check "monitor-plan-refused" in describeFailedAction(reasoned)
    let bare = describeFailedAction(ActionResult(
      id: "__repro_provider_compile", status: asFailed))
    check bare != "__repro_provider_compile asFailed"
    check "did not launch" in bare

  test "a failed edge leaves a log and the report names it":
    let root = createTempDir("repro-provider-failure-", "")
    defer: removeDir(root)
    let outDir = root / "dev-env"
    let report = recordEdgeFailure(outDir, "provider-compile-failure",
      "__repro_provider_compile asFailed (exit code 1)\nboom")
    let logPath = outDir / "provider-compile-failure.log"
    check fileExists(logPath)
    check "boom" in readFile(logPath)
    check ("full report: " & logPath) in report

  test "an unwritable log directory does not replace the failure":
    let root = createTempDir("repro-provider-failure-", "")
    defer: removeDir(root)
    writeFile(root / "file", "")
    let report = recordEdgeFailure(root / "file" / "sub", "x", "the failure")
    check report.startsWith("the failure")
    check "could not be written" in report

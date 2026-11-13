## `repro exec` does not hand the user's command the source root the engine
## derived for ITSELF.
##
## ## The defect this locks out
##
## Recorded 2026-09-30 (reprobuild-pm issue
## `2026-09-30-exec-leaks-the-engines-own-source-root-to-the-command.md`): a
## suite run of checkout A entered through checkout B's build,
##
##     cd A && B/build/bin/repro exec -- bash scripts/run_tests.sh
##
## saw `REPROBUILD_SOURCE_ROOT=B` inside the command although nobody set it.
## `resolveMonitorShimLibPath` found the shim beside the running image and
## `putEnv`-ed B as the source root, a process-global seed that `repro exec`
## then passed on with the rest of its environment. A's own engine, started
## inside the command, preferred that ambient value over its own location and
## compiled every recipe against B's `libs/`.
##
## Distribution-And-Packaging §5 ("Discovery without a wrapper") says an
## image's self-seeded roots fill only unset variables and are withdrawn before
## the user's environment is captured. The two cases below are both halves of
## that sentence, end to end through the real binary:
##
## 1. a caller that sets no source root gets none: the command sees neither
##    `REPROBUILD_SOURCE_ROOT` nor the private provenance record
##    (`REPRO_BOOTSTRAP_SOURCE_ENV`) the seeding keeps;
## 2. a caller that DOES set `REPROBUILD_SOURCE_ROOT` gets exactly its own
##    value back -- the withdrawal removes seeds, never explicit values, even
##    one equal to the root the engine would have derived.
##
## A third case runs the same probe as a dev-env task through `repro run`, the
## other activation surface that launches a user's command after the engine
## has compiled the dev env (POSIX only: the task line is handed to `$SHELL`).
##
## The shim has to be found beside the engine (`build/lib`), not through
## `REPRO_MONITOR_SHIM_LIB`: the override arm returns before the seed is made,
## so a case that set it would pass on unfixed code. The shared M74 fixture
## sets both the override and `REPROBUILD_SOURCE_ROOT`, and
## `scripts/run_tests.sh` pins the latter for the whole suite, so this file
## removes them from the child's environment AND from its own for the call.
##
## Mocking: none. The user's command is this test binary, re-executed, so the
## `repro exec` cases need no shell on any platform.

import std/[os, strtabs, strutils, unittest]

import repro_test_support
import ./dev_env_export_helper

const
  printEnvFlag = "--repro-test-print-source-root-env"
  sourceRootVar = "REPROBUILD_SOURCE_ROOT"
  provenanceVar = "REPRO_BOOTSTRAP_SOURCE_ENV"
  printedNames = [sourceRootVar, provenanceVar]
  # Every variable that would steer the engine to a source root other than
  # the one beside its own image, plus the shim override that would skip the
  # seeding arm altogether.
  scrubbedNames = [sourceRootVar, provenanceVar, "REPROBUILD_REPO_ROOT",
    "REPROBUILD_LIBS_DIR", "REPRO_MONITOR_SHIM_LIB"]

block:
  let params = commandLineParams()
  if params.len == 1 and params[0] == printEnvFlag:
    for name in printedNames:
      echo "SOURCE-ROOT-ENV ", name, "=",
        (if existsEnv(name): "[" & getEnv(name) & "]" else: "<unset>")
    quit(0)

proc execEnv(c: M74Case): StringTableRef =
  result = c.envFor()
  for name in scrubbedNames:
    if result.hasKey(name):
      result.del(name)
  # RunQuota is not what this file is about; keep it off the host daemon.
  result["REPROBUILD_NO_RUNQUOTA"] = "1"
  result["REPROBUILD_PROGRESS"] = "quiet"

proc runRepro(c: M74Case; env: StringTableRef; name: string;
               reproArgs: seq[string]; cwd: string): CmdResult =
  var overlay: seq[tuple[name, value: string]]
  for key, value in env:
    overlay.add((name: key, value: value))
  # ``runShell`` OVERLAYS ``overlay`` on this process's own environment, so a
  # name deleted from ``env`` is still inherited from here -- and the suite
  # runner exports ``REPROBUILD_SOURCE_ROOT`` for every test. Take each
  # scrubbed name the case does not set out of this process for the call.
  var saved: seq[tuple[name, value: string]]
  for scrubbed in scrubbedNames:
    if env.hasKey(scrubbed):
      continue
    if existsEnv(scrubbed):
      saved.add((name: scrubbed, value: getEnv(scrubbed)))
      delEnv(scrubbed)
  try:
    result = runShell(shellCommand(@[c.reproBin] & reproArgs, overlay), cwd,
      timeoutMs = 15 * 60 * 1000)
  finally:
    for entry in saved:
      putEnv(entry.name, entry.value)
  let logPath = getTempDir() /
    ("t_e2e_repro_exec_does_not_leak_engine_source_root-" & name & "-" &
      $getCurrentProcessId() & ".log")
  writeFile(logPath, result.output)
  checkpoint name & ": exit " & $result.code & "; full output: " & logPath &
    " (" & $result.output.len & " bytes)"

proc runExec(c: M74Case; env: StringTableRef; name: string): CmdResult =
  runRepro(c, env, name,
    @["exec", c.projectRoot, "--", getAppFilename(), printEnvFlag],
    c.repoRoot)

proc removeScratch(dir: string) =
  ## Best-effort, as in ``t_e2e_repro_exec_recipe_compiler``: a background
  ## writer the activation started can still be finishing when the case ends.
  for _ in 0 ..< 20:
    try:
      removeDir(dir)
      return
    except OSError:
      sleep(250)

proc prepareExecCase(prefix: string): M74Case =
  ## The shared M74 fixture with the smallest recipe that still needs a
  ## provider compile (the M74 recipe declares a Nix-provisioned ``nim``,
  ## which a Windows host cannot realise).
  ##
  ## On POSIX the dev env also declares a ``printenv`` task that runs the
  ## same probe, for the ``repro run`` case.
  result = prepareCase(prefix)
  var taskDecl = ""
  when not defined(windows):
    let taskCommand = quoteShell(getAppFilename()) & " " & printEnvFlag
    doAssert '"' notin taskCommand and '\\' notin taskCommand,
      "the probe's path cannot be written into a Nim string literal: " &
        taskCommand
    taskDecl = "    task \"printenv\", command = \"" & taskCommand & "\"\n"
  writeFile(result.projectRoot / "reprobuild.nim", """
import repro_project_dsl

package fixture:
  defaultToolProvisioning "path"
  devEnv:
    activity "default"
    setEnv "FIXTURE_MODE", "dev"
""" & taskDecl)

when isIoMonitorSupported:
  suite "the source root repro exec derives for itself":

    test "does not reach the command of a caller that set none":
      let c = prepareExecCase("repro-exec-source-root-unset")
      defer: removeScratch(c.tempRoot)
      # The seed fires only when the shim is found beside the engine; without
      # it this case would pass whatever the engine did with the seed.
      require fileExists(monitorShimPath(c.repoRoot))
      let res = runExec(c, execEnv(c), "unset")
      check res.code == 0
      check "SOURCE-ROOT-ENV " & sourceRootVar & "=" in res.output
      check ("SOURCE-ROOT-ENV " & sourceRootVar & "=<unset>") in res.output
      check ("SOURCE-ROOT-ENV " & sourceRootVar & "=[" & c.repoRoot & "]") notin
        res.output
      check ("SOURCE-ROOT-ENV " & provenanceVar & "=<unset>") in res.output

    test "a caller's own value reaches the command unchanged":
      let c = prepareExecCase("repro-exec-source-root-explicit")
      defer: removeScratch(c.tempRoot)
      var env = execEnv(c)
      # The same root the engine would derive: the withdrawal must tell an
      # explicit value from a seed by provenance, not by comparing paths.
      env[sourceRootVar] = c.repoRoot
      let res = runExec(c, env, "explicit")
      check res.code == 0
      check ("SOURCE-ROOT-ENV " & sourceRootVar & "=[" & c.repoRoot & "]") in
        res.output
      check ("SOURCE-ROOT-ENV " & provenanceVar & "=<unset>") in res.output

    when not defined(windows):
      test "does not reach a dev-env task that repro run starts":
        let c = prepareExecCase("repro-run-source-root-unset")
        defer: removeScratch(c.tempRoot)
        require fileExists(monitorShimPath(c.repoRoot))
        let res = runRepro(c, execEnv(c), "run-task", @["run", "task:printenv"],
          c.projectRoot)
        check res.code == 0
        check ("SOURCE-ROOT-ENV " & sourceRootVar & "=<unset>") in res.output
        check ("SOURCE-ROOT-ENV " & provenanceVar & "=<unset>") in res.output

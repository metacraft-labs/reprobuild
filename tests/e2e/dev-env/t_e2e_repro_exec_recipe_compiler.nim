## `repro exec` compiles the recipe with a compiler it chose on purpose, says
## so when that compiler is broken, and keeps its own toolchain out of the
## user's command.
##
## ## The defect this locks out
##
## Measured 2026-09-23 in `D:\ah\dev\agent-harbor`, whose Justfile runs every
## recipe through `repro exec`: every recipe died compiling the project DSL with
##
##     capi.c:1: stddef.h: No such file or directory
##
## from `gcc.exe` -- FPC's 1999-era i386 gcc 2.95, first on the Machine PATH,
## which Windows searches before the User PATH. The recipe compile passed Nim
## no `--gcc.exe`, so Nim took whatever `gcc.exe` PATH offered, silently. The
## documented escape, `REPRO_BOOTSTRAP_CC`, only worked because this entry
## point never ran the bootstrap that would otherwise have overwritten it.
##
## The three cases below are the three halves of the fix, end to end through
## the real binary:
##
## 1. with a `gcc.exe` that cannot compile anything FIRST on PATH, and no
##    override exported, `repro exec` still succeeds -- the recipe is compiled
##    with the pinned bootstrap compiler, never with the PATH one;
## 2. that pinned toolchain (`CC`, `REPRO_BOOTSTRAP_CC`, `REPRO_NIM_COMPILER`)
##    is reprobuild's own and does not reach the command: before the fix the
##    command inherited `CC=<tool-store MinGW gcc>`, which cc-rs honours even
##    for an MSVC target;
## 3. (Windows) an override that cannot compile is refused up front, naming the
##    compiler, where it came from, and the remedy -- not reported as a failure
##    in one of reprobuild's own C files.
##
## Mocking: none beyond the broken "compiler", which is a file that is not a
## program -- the portable stand-in for FPC's gcc.

import std/[os, strtabs, strutils, unittest]

import repro_test_support
import ./dev_env_export_helper

const
  printEnvFlag = "--repro-test-print-toolchain-env"
  toolchainNames = ["CC", "REPRO_BOOTSTRAP_CC", "REPRO_NIM_COMPILER"]

# The user command is this test binary, re-executed: it prints the toolchain
# variables it inherited, so the case needs no shell on any platform.
block:
  let params = commandLineParams()
  if params.len == 1 and params[0] == printEnvFlag:
    for name in toolchainNames:
      echo "TOOLCHAIN-ENV ", name, "=",
        (if existsEnv(name): "[" & getEnv(name) & "]" else: "<unset>")
    quit(0)

proc writeBrokenCompiler(dir: string): string =
  createDir(dir)
  result = dir / addFileExt("gcc", ExeExt)
  writeFile(result, "this is not a compiler\n")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc execEnv(c: M74Case; brokenDir: string): StringTableRef =
  result = c.envFor()
  for name in toolchainNames:
    if result.hasKey(name):
      result.del(name)
  # RunQuota is not what this file is about; keep it off the host daemon.
  result["REPROBUILD_NO_RUNQUOTA"] = "1"
  result["REPROBUILD_PROGRESS"] = "quiet"
  # The broken compiler goes FIRST, where FPC's gcc 2.95 was.
  result["PATH"] = brokenDir & $PathSep & result.getOrDefault("PATH")

proc runExec(c: M74Case; env: StringTableRef; name: string): CmdResult =
  var overlay: seq[tuple[name, value: string]]
  for key, value in env:
    overlay.add((name: key, value: value))
  result = runShell(shellCommand(@[c.reproBin, "exec", c.projectRoot, "--",
    getAppFilename(), printEnvFlag], overlay), c.repoRoot,
    timeoutMs = 15 * 60 * 1000)
  let logPath = getTempDir() / ("t_e2e_repro_exec_recipe_compiler-" & name &
    "-" & $getCurrentProcessId() & ".log")
  writeFile(logPath, result.output)
  checkpoint name & ": exit " & $result.code & "; full output: " & logPath &
    " (" & $result.output.len & " bytes)"

proc removeScratch(dir: string) =
  ## Best-effort: a background writer the activation started (the action
  ## cache's hot-record flush) can still be finishing when the case ends, and
  ## a scratch directory that outlives its test is not a test failure.
  for _ in 0 ..< 20:
    try:
      removeDir(dir)
      return
    except OSError:
      sleep(250)

proc prepareExecCase(prefix: string): M74Case =
  ## The shared M74 fixture, with its recipe replaced by the smallest one that
  ## still needs a provider compile: no tool uses, so nothing but the recipe
  ## compile itself runs before the user's command (the M74 recipe declares a
  ## Nix-provisioned ``nim``, which a Windows host cannot realise).
  result = prepareCase(prefix)
  writeFile(result.projectRoot / "reprobuild.nim", """
import repro_project_dsl

package fixture:
  defaultToolProvisioning "path"
  devEnv:
    activity "default"
    setEnv "FIXTURE_MODE", "dev"
""")

when isIoMonitorSupported:
  suite "the compiler repro exec compiles the recipe with":

    test "a broken gcc first on PATH is not used, and no toolchain leaks":
      let c = prepareExecCase("repro-exec-recipe-cc")
      defer: removeScratch(c.tempRoot)
      let broken = writeBrokenCompiler(c.tempRoot / "broken-bin")
      let res = runExec(c, execEnv(c, broken.parentDir), "path-gcc")
      # (1) It worked: the recipe was compiled, the command ran.
      check res.code == 0
      check "TOOLCHAIN-ENV CC=" in res.output
      check "stddef.h" notin res.output
      # (2) And the command saw the caller's environment, which set none of
      # the three -- not the toolchain reprobuild used for itself.
      for name in toolchainNames:
        check ("TOOLCHAIN-ENV " & name & "=<unset>") in res.output

  when defined(windows):
    suite "an explicit REPRO_BOOTSTRAP_CC":

      test "that cannot compile is refused by name, before any work":
        let c = prepareExecCase("repro-exec-recipe-cc-override")
        defer: removeScratch(c.tempRoot)
        let broken = writeBrokenCompiler(c.tempRoot / "broken-override")
        var env = execEnv(c, c.tempRoot / "empty-bin")
        env["REPRO_BOOTSTRAP_CC"] = broken
        let res = runExec(c, env, "override")
        check res.code != runShellTimedOutCode
        check res.code != 0
        check broken in res.output
        check "REPRO_BOOTSTRAP_CC (set in the environment)" in res.output
        check "cannot compile a trivial C file" in res.output
        check "remedy:" in res.output
        # Refused before the command could run.
        check "TOOLCHAIN-ENV" notin res.output

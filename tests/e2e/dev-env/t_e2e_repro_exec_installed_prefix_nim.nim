## `repro exec` run from an installed prefix compiles the recipe with the Nim
## the prefix ships, and refuses a recipe whose own `uses: nim` range
## excludes that compiler (reprobuild-pm Distribution-And-Packaging.md §5.3,
## amendment N3, approved by Zahary Karadjov, 2026-11-04).
##
## ## The defect this locks out
##
## Substituted on rpi2, the armv7 prefix's `repro exec -- true` ignored the
## fork it ships under `nim/` and built stock Nim 2.2.10 from source
## (2026-11-04). The A15 re-review then found that a recipe's own `uses: nim`
## range was never consulted against that compiler (2026-11-05).
##
## The cases run the real `repro` through an installed-prefix layout:
## `REPRO_PUBLIC_CLI_PATH` names `<prefix>/bin/reprobuild` (the anchor the
## portable launcher sets), and `<prefix>/nim/` is this host's own fork
## installation, linked in, with the record N3 checks. The recipe declares
## `uses: nim`, so the check reads a real project's interface:
##
## 1. a range that admits the fork: the command runs;
## 2. a range that excludes it: refused before the command, naming the
##    release, the range and the prefix's compiler;
## 3. a prefix whose revision file disagrees with its record: refused,
##    naming both -- the prefix route really was taken;
## 4. `repro build`, whose interface edge is cached: an edge recorded while
##    the compiler was named explicitly (no prefix route, nothing checked)
##    does not answer a later run that reaches the compiler by the prefix
##    route; that run is refused.
##
## Mocking: none. The layout is links to real files; the compiler that runs
## is the real fork the dev shell provides.

import std/[os, strtabs, strutils, unittest]

import repro_test_support
import ./dev_env_export_helper

const ForkRev = "197089cda27f656f8010e2b31b40e0e12f3f209b"

proc forkTree(): string =
  ## The installation directory of the `nim` on PATH: the dev shell's fork.
  let nim = findExe("nim")
  if nim.len == 0:
    return ""
  expandFilename(nim).parentDir.parentDir

proc installedPrefix(c: M74Case; revision = ForkRev): string =
  result = c.tempRoot / "prefix"
  createDir(result / "bin")
  for name in ["repro", "reprobuild"]:
    let image = c.reproBin.parentDir / addFileExt(name, ExeExt)
    if fileExists(image):
      createSymlink(image, result / "bin" / addFileExt(name, ExeExt))
  let tree = forkTree()
  createDir(result / "nim")
  for sub in ["bin", "lib", "config"]:
    if dirExists(tree / sub):
      createSymlink(tree / sub, result / "nim" / sub)
  writeFile(result / "nim" / ".nim-fork-revision", revision & "\n")
  createDir(result / "share" / "repro")
  writeFile(result / "share" / "repro" / "cross-build-info",
    "nim_fork=" & ForkRev & "\n")

proc recipe(c: M74Case; usesNim: string) =
  writeFile(c.projectRoot / "reprobuild.nim", """
import repro_project_dsl

package fixture:
  defaultToolProvisioning "path"
  uses:
    """" & usesNim & """"
  devEnv:
    activity "default"
    setEnv "FIXTURE_MODE", "dev"
""")

proc runRepro(c: M74Case; prefix, name: string; args: seq[string];
               explicitNim = ""): CmdResult =
  ## The prefix's `bin/repro` (a link to this checkout's thin client) with
  ## `args`, from a clean toolchain environment, the engine image named as
  ## the portable launcher names it. `explicitNim`, when set, is the
  ## caller's own `REPRO_NIM_COMPILER`, which takes the provider compiler
  ## off the prefix route (the bootstrap keeps an explicit choice).
  var env = c.envFor()
  for drop in ["REPRO_NIM_COMPILER", "REPRO_BOOTSTRAP_CC", "CC",
               "REPRO_INSTALLED_PREFIX_NIM"]:
    if env.hasKey(drop):
      env.del(drop)
  env["REPROBUILD_NO_RUNQUOTA"] = "1"
  env["REPROBUILD_PROGRESS"] = "quiet"
  # The engine image, as the portable launcher names it.
  env["REPRO_PUBLIC_CLI_PATH"] =
    prefix / "bin" / addFileExt("reprobuild", ExeExt)
  if explicitNim.len > 0:
    env["REPRO_NIM_COMPILER"] = explicitNim
  var overlay: seq[tuple[name, value: string]]
  for key, value in env:
    overlay.add((name: key, value: value))
  var saved: seq[tuple[name, value: string]]
  for name in ["REPRO_NIM_COMPILER", "REPRO_INSTALLED_PREFIX_NIM"]:
    if existsEnv(name):
      saved.add((name: name, value: getEnv(name)))
      delEnv(name)
  try:
    result = runShell(shellCommand(@[c.reproBin] & args, overlay),
      c.repoRoot, timeoutMs = 15 * 60 * 1000)
  finally:
    for entry in saved:
      putEnv(entry.name, entry.value)
  let logPath = getTempDir() / ("t_e2e_repro_exec_installed_prefix_nim-" &
    name & "-" & $getCurrentProcessId() & ".log")
  writeFile(logPath, result.output)
  checkpoint name & ": exit " & $result.code & "; full output: " & logPath

proc runExec(c: M74Case; prefix, name: string): CmdResult =
  runRepro(c, prefix, name, @["exec", c.projectRoot, "--", "true"])

proc runBuild(c: M74Case; prefix, name, actionCacheRoot: string;
              explicitNim = ""): CmdResult =
  runRepro(c, prefix, name, @["build", "--daemon=off",
    "--tool-provisioning=path", "--action-cache-root=" & actionCacheRoot,
    "--progress=quiet", "--log=actions", c.projectRoot], explicitNim)

when isIoMonitorSupported and not defined(windows):
  suite "repro exec from an installed prefix uses the Nim it ships":

    test "a recipe whose uses: admits the fork runs":
      let c = prepareCase("prefix-nim-exec-ok")
      defer: removeDir(c.tempRoot)
      require forkTree().len > 0
      recipe(c, "nim >=2.2 <3.0")
      let res = runExec(c, installedPrefix(c), "admitted")
      check res.code == 0

    test "a recipe whose uses: excludes the fork is refused by name":
      let c = prepareCase("prefix-nim-exec-range")
      defer: removeDir(c.tempRoot)
      require forkTree().len > 0
      recipe(c, "nim >=2.0 <2.3")
      let prefix = installedPrefix(c)
      let res = runExec(c, prefix, "excluded")
      check res.code != 0
      check "nim >=2.0 <2.3" in res.output
      check "excludes Nim 2.3.1" in res.output
      check (prefix / "nim" / "bin") in res.output

    test "a prefix whose Nim is not its recorded fork is refused":
      let c = prepareCase("prefix-nim-exec-rev")
      defer: removeDir(c.tempRoot)
      require forkTree().len > 0
      recipe(c, "nim >=2.2 <3.0")
      let res = runExec(c, installedPrefix(c, revision = repeat('b', 40)),
        "mismatch")
      check res.code != 0
      check "not the fork it records" in res.output
      check repeat('b', 40) in res.output

    test "a recorded interface edge does not answer a prefix-route run":
      # The build engine's interface edge is cached. Run 1 names the
      # prefix's compiler explicitly, which takes it off the prefix route:
      # no `REPRO_INSTALLED_PREFIX_NIM`, nothing checked, the edge recorded.
      # Run 2 reaches the same compiler by the prefix route. The record from
      # run 1 must not answer it: the extraction reads the variable, so the
      # monitor keyed the record on it, the edge re-runs, and the
      # extractor's check refuses the recipe.
      let c = prepareCase("prefix-nim-build-hit")
      defer: removeDir(c.tempRoot)
      require forkTree().len > 0
      recipe(c, "nim >=2.0 <2.3")
      let prefix = installedPrefix(c)
      let cache = c.tempRoot / "action-cache"
      createDir(cache)
      let first = runBuild(c, prefix, "build-explicit", cache,
        explicitNim = prefix / "nim" / "bin" / addFileExt("nim", ExeExt))
      check "excludes Nim" notin first.output
      let second = runBuild(c, prefix, "build-prefix-route", cache)
      check second.code != 0
      check "nim >=2.0 <2.3" in second.output
      check "excludes Nim 2.3.1" in second.output

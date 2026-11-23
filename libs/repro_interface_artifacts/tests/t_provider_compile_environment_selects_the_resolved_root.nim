## The provider compile's environment makes the recipe's own `config.nims`
## select, for every package the source resolver displaced a stale sibling
## for, the root the resolver chose -- so that compile, too, has exactly one
## root per package.
##
## Spec: Unified-Locking-And-Hooks.md §13.5, "The sources a recipe compile
## reads" (each package gets exactly one root). Measured with `repro exec`
## in the reprobuild checkout: the provider compile's main module is the recipe, so Nim
## evaluates the recipe's `config.nims` ITSELF -- the extraction's remedy,
## dropping the replayed paths, cannot reach it. Measured 2026-11-23 on the
## dev env's real provider compile of the reprobuild checkout (its argv and
## environment recorded through a wrapper `$REPRO_NIM_COMPILER`): its
## command named only the pinned trees, but `nim dump` under its exact
## environment named `<ws>/nim-shm-gset/src` and `<ws>/nim-shm-queue/src`
## too. Its `PATH` holds no `git`, so `config.nims` cannot see that those
## siblings are stale and keeps them although `$SHM_GSET_SRC` /
## `$SHM_QUEUE_SRC` name the pinned trees. The remedy is the compile child's
## environment (`providerCompileSourceEnvironment`): `$<PKG>_SRC` = the
## root the resolver chose for every package whose sibling it displaced --
## found where the RECIPE's configuration looks, the workspace beside the
## recipe (`recipeConfigurationWorkspaceRoots`) -- and, for the
## sibling-first ones, `$REPRO_SIBLING_PINNED`.
##
## Fixture, shaped as the dev env's provider compile runs: the SDK the
## compile resolves against is a reprobuild-shaped source tree OUTSIDE the
## workspace and NOT a checkout, this engine's own (the seeded
## `$REPROBUILD_SOURCE_ROOT`, as the package's wrapper names it) -- the store
## copy of the sources; the compile runs from a scratch directory outside the
## workspace; so the resolver sees no sibling and takes the trees the engine
## was built with. The RECIPE is a checkout in the workspace, beside real
## sibling repositories of io-mon, runquota and nim-shm-gset checked out
## behind their pins, and its directory holds a
## `config.nims` that resolves both exactly as reprobuild's does --
## `$IO_MON_SRC` (holding `io_mon.nim`) else `../io-mon/src`; `$RUNQUOTA_SRC`
## (a checkout root) else `../runquota`; and the sibling-first
## `nim-shm-gset`, chosen by the SHARED policy routine reprobuild's file
## calls (`siblingPolicyFor` / `chooseSiblingSource`, imported by absolute
## path), observed as the provider compile observes it: without `git`
## (that compile's `PATH` has none), so the sibling's state is "cannot
## tell". It is a fixture configuration of the same shape, not reprobuild's
## file, which reaches the shared routine by a path relative to the
## reprobuild tree and probes git. Everything else is real: the resolver, the environment it yields,
## the child launch (`runCommand`'s ``withEnv``) and `nim dump`, the
## compiler's own evaluation of the configuration. The pinned trees are
## this binary's build-time `$IO_MON_SRC` / `$RUNQUOTA_SRC`, real trees the
## development shell exports. No mocks. The process environment and working
## directory are mutated, so this binary runs on its own.
##
## Unfixed (the recipe's workspace not consulted, so nothing displaced and
## no environment handed over): the seeded `$IO_MON_SRC` / `$RUNQUOTA_SRC`
## already win in the plain-order branches, but the shm-gset sibling wins
## the sibling-first one, since the file cannot see it is stale -- measured
## the same way on the real provider compile of the reprobuild checkout,
## whose recorded environment carried the seeded roots and whose `nim dump`
## named `<ws>/nim-shm-gset/src` and `<ws>/nim-shm-queue/src`.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_core/sibling_source_policy
import repro_test_support/reasoned_skip

const
  IoMonMarker = "io_mon.nim"
  RunquotaMarker = "libs" / "runquota_core" / "src" / "runquota_core.nim"
  ClearedVariables = ["IO_MON_SRC", "RUNQUOTA_SRC", "SHM_GSET_SRC",
    "REPRO_SIBLING_PINNED", "REPRO_SIBLING_POLICY",
    "REPROBUILD_SOURCE_ROOT", "REPROBUILD_REPO_ROOT", "REPROBUILD_LIBS_DIR",
    SeededSourceEnvironmentVar]
  builtIoMonEnv = static(getEnv("IO_MON_SRC"))
  builtRunquota = static(getEnv("RUNQUOTA_SRC"))
  builtGsetEnv = static(getEnv("SHM_GSET_SRC"))
  GsetMarker = "shm_gset.nim"
  PolicyModule = currentSourcePath().parentDir.parentDir.parentDir /
    "repro_core" / "src" / "repro_core" / "sibling_source_policy"

proc builtGset(): string =
  if builtGsetEnv.len > 0 and fileExists(builtGsetEnv / GsetMarker):
    builtGsetEnv
  elif builtGsetEnv.len > 0 and fileExists(builtGsetEnv / "src" / GsetMarker):
    builtGsetEnv / "src"
  else: ""

proc normal(dir: string): string = normalizedPath(absolutePath(dir))

proc builtIoMon(): string =
  if builtIoMonEnv.len > 0 and fileExists(builtIoMonEnv / IoMonMarker):
    builtIoMonEnv
  elif builtIoMonEnv.len > 0 and
      fileExists(builtIoMonEnv / "src" / IoMonMarker):
    builtIoMonEnv / "src"
  else: ""

proc sh(cmd, cwd: string) =
  let res = execCmdEx(cmd, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(OSError, cmd & " failed: " & res.output)

proc staleSibling(dir, marker: string): string =
  ## A repository with base -> pin on main and `stale` off base, left at
  ## `stale`; answers the pin.
  createDir(parentDir(dir / marker))
  sh("git init -q -b main", dir)
  sh("git config user.email tester@example.invalid", dir)
  sh("git config user.name Tester", dir)
  sh("git config commit.gpgsign false", dir)
  proc commit(content, message: string): string =
    writeFile(dir / marker, content)
    sh("git add -A", dir)
    sh("git commit -q -m " & quoteShell(message), dir)
    execCmdEx("git rev-parse HEAD", workingDir = dir).output.strip()
  let base = commit("# base\n", "base")
  result = commit("# pin\n", "pin")
  sh("git checkout -q -b side " & base, dir)
  discard commit("# stale\n", "stale")

proc node(repo, rev: string): string =
  "{ \"locked\": { \"owner\": \"metacraft-labs\", \"repo\": \"" & repo &
    "\", \"rev\": \"" & rev & "\", \"type\": \"github\" } }"

suite "the provider compile environment selects the resolved root":
  var root, savedDir: string
  var saved: seq[(string, string)]

  setup:
    savedDir = getCurrentDir()
    saved = @[]
    for name in ClearedVariables:
      if existsEnv(name): saved.add((name, getEnv(name)))
      delEnv(name)
    clearSeededSourcePackageEnvironment()

  teardown:
    for name in ClearedVariables: delEnv(name)
    for (name, value) in saved: putEnv(name, value)
    setCurrentDir(savedDir)
    if root.len > 0: removeDir(root)

  test "config.nims takes the pinned trees, not the stale siblings":
    if builtIoMon().len == 0 or builtRunquota.len == 0 or
        not fileExists(builtRunquota / RunquotaMarker) or builtGset().len == 0:
      skip("this binary was built without $IO_MON_SRC / $RUNQUOTA_SRC " &
        "trees (build it in the development shell, which exports them)")
    else:
      root = createTempDir("repro-provider-env-", "")
      let ws = root / "ws"
      let sdk = root / "store-copy"
      let recipeTree = ws / "reprobuild"
      let ioMon = ws / "io-mon"
      let runquota = ws / "runquota"
      let gset = ws / "nim-shm-gset"
      let ioMonPin = staleSibling(ioMon, "src" / IoMonMarker)
      let runquotaPin = staleSibling(runquota, RunquotaMarker)
      let gsetPin = staleSibling(gset, "src" / GsetMarker)
      createDir(sdk / "libs" / "repro_project_dsl" / "src")
      writeFile(sdk / "libs" / "repro_project_dsl" / "src" /
        "repro_project_dsl.nim", "")
      createDir(recipeTree)
      writeFile(sdk / "flake.lock", "{ \"nodes\": { \"io-mon-src\": " &
        node("io-mon", ioMonPin) & ", \"runquota-src\": " &
        node("runquota", runquotaPin) & ", \"nim-shm-gset-src\": " &
        node("nim-shm-gset", gsetPin) & ", \"root\": { \"inputs\": { " &
        "\"io-mon-src\": \"io-mon-src\", \"runquota-src\": " &
        "\"runquota-src\", \"nim-shm-gset-src\": \"nim-shm-gset-src\" " &
        "} } }, \"root\": \"root\", \"version\": 7 }\n")
      writeFile(recipeTree / "config.nims", """
let ioMonEnv = getEnv("IO_MON_SRC")
if ioMonEnv.len > 0 and fileExists(ioMonEnv & "/io_mon.nim"):
  switch("path", ioMonEnv)
else:
  switch("path", thisDir() & "/../io-mon/src")
let runquotaEnv = getEnv("RUNQUOTA_SRC")
let runquotaRoot =
  if runquotaEnv.len > 0: runquotaEnv else: thisDir() & "/../runquota"
switch("path", runquotaRoot & "/libs/runquota_core/src")
let gsetEnv = getEnv("SHM_GSET_SRC")
let gsetSibling = thisDir() & "/../nim-shm-gset/src"
if fileExists(gsetSibling & "/shm_gset.nim"):
  let policy = siblingPolicyFor("SHM_GSET_SRC", getEnv(SiblingPolicyEnvVar),
    getEnv(SiblingPinnedPackagesEnvVar))
  let choice = chooseSiblingSource(policy, SiblingObservation(
    siblingPresent: true,
    envPinPresent: gsetEnv.len > 0 and fileExists(gsetEnv & "/shm_gset.nim")))
  if choice.kind == sskEnvPin: switch("path", gsetEnv)
  else: switch("path", gsetSibling)
elif gsetEnv.len > 0:
  switch("path", gsetEnv)
""".replace("let ioMonEnv", "import \"" & PolicyModule & "\"\nlet ioMonEnv"))
      let recipe = recipeTree / "repro.nim"
      writeFile(recipe, "")
      # Seeded as the package's wrapper seeds them: the source tree, and the
      # roots the engine was built with. The provider launch declares these
      # by value (`providerCompileLaunchEnv`), so the compile child sees them.
      seedSourcePackageEnvironment([("REPROBUILD_SOURCE_ROOT", sdk),
        ("IO_MON_SRC", builtIoMon()), ("RUNQUOTA_SRC", builtRunquota),
        ("SHM_GSET_SRC", builtGset())])
      # The compile's own scratch directory, outside the workspace.
      createDir(root / "scratch")
      setCurrentDir(root / "scratch")

      proc searchPathUnder(env: openArray[(string, string)]): seq[string] =
        ## The compiler's own evaluation of the configuration, in a child
        ## given ``env``.
        let dump = runCommand(@[findExe("nim"), "dump", "--dump.format:json",
          "--hints:off", "--warnings:off", recipe], cwd = root / "scratch",
          raiseOnFailure = false, withEnv = env)
        check dump.exitCode == 0
        let first = dump.output.find('{')
        let last = dump.output.rfind('}')
        check first >= 0 and last > first
        if first >= 0 and last > first:
          for item in parseJson(dump.output[first .. last]){"lib_paths"}.getElems():
            result.add(normal(item.getStr()))

      let env = providerCompileSourceEnvironment(sdk, recipe)
      checkpoint("environment: " & $env)
      # The control: the variables WITHOUT the pinned list -- what the
      # provider launch already carried for a seeded engine -- leave the
      # shm-gset sibling selected, since the file cannot see it is stale.
      var withoutPinned: seq[(string, string)]
      for entry in env:
        if entry[0] != SiblingPinnedPackagesEnvVar: withoutPinned.add(entry)
      check (gset / "src") in searchPathUnder(withoutPinned)
      let paths = searchPathUnder(env)
      checkpoint("search path: " & $paths)
      for dir in paths:
        check not (dir == ioMon or dir.startsWith(ioMon & "/"))
        check not (dir == runquota or dir.startsWith(runquota & "/"))
        check not (dir == gset or dir.startsWith(gset & "/"))
      var ioMonRoots, runquotaRoots, gsetRoots: seq[string]
      for dir in paths:
        if fileExists(dir / IoMonMarker): ioMonRoots.add(dir)
        if fileExists(dir / "runquota_core.nim"): runquotaRoots.add(dir)
        if fileExists(dir / GsetMarker): gsetRoots.add(dir)
      check gsetRoots == @[normal(builtGset())]
      check ioMonRoots == @[normal(builtIoMon())]
      check runquotaRoots ==
        @[normal(builtRunquota / "libs" / "runquota_core" / "src")]
      # Handed to the child only: this process's environment is untouched.
      check getEnv("SHM_GSET_SRC") == builtGset()
      check not existsEnv(SiblingPinnedPackagesEnvVar)

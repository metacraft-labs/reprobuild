## An interface extraction's search path names no directory inside a sibling
## checkout the source resolver displaced, so each package it decided has
## exactly one root in the launched command and its search-path script.
##
## Spec: Unified-Locking-And-Hooks.md §13.5, "The sources a recipe compile
## reads" (each package gets exactly one root). Measured with `repro exec`
## in the reprobuild checkout: once the resolver used the pinned io-mon instead of a stale
## `../io-mon` sibling, the extraction STILL carried `<ws>/io-mon/src`
## (measured 2026-11-23, `repro exec` in the reprobuild checkout). The
## recipe's own configuration put it there: the extraction replays the
## search paths of the recipe's `config.nims` (`nim dump`,
## `recipeConfigSearchPathFlags`), and reprobuild's falls back to the
## sibling when no `$IO_MON_SRC` is exported. The pinned root came later and
## won for every module it has, but a module only the stale sibling has
## would still resolve from the sibling: one library from two revisions.
##
## Fixture: a reprobuild-shaped source tree that is NOT a checkout (the store
## copy of the sources a packaged engine compiles against) and is this
## engine's own (named by the seeded `$REPROBUILD_SOURCE_ROOT`, as the
## package's wrapper names it), whose `flake.lock` pins `io-mon`; a real
## `io-mon` sibling repository checked out BEHIND the pin; and, in the tree,
## a `config.nims` that adds the sibling's `src` the way reprobuild's does.
## The steps are the extraction's own: the real resolver
## (`bootstrapSiblingPackagePathFlagsFor`), the real configuration replay
## (`recipeConfigSearchPathFlags`, which runs the real `nim dump`), the
## extraction's last search-path step (`applyRecipeConfigurationSearchPaths`)
## and the launch split (`splitSearchPathReassertion`). The pinned io-mon is
## this binary's build-time `$IO_MON_SRC`, a real tree the development shell
## exports. No mocks. The process environment and working directory are
## mutated, so this binary runs on its own.
##
## Unfixed (the displaced checkout not dropped): the launch argv's search
## path holds `<ws>/io-mon/src` beside the pinned root.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_interface_artifacts/nim_search_path_script
import repro_test_support/reasoned_skip

const
  IoMonMarker = "io_mon.nim"
  ModuleArg = "\x00extract-runner\x00"
  ClearedVariables = ["IO_MON_SRC", "RUNQUOTA_SRC", "REPRO_SIBLING_POLICY",
    "REPROBUILD_SOURCE_ROOT", "REPROBUILD_REPO_ROOT", "REPROBUILD_LIBS_DIR",
    SeededSourceEnvironmentVar]
  builtIoMonEnv = static(getEnv("IO_MON_SRC"))

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

proc commit(dir, content, message: string): string =
  writeFile(dir / "src" / IoMonMarker, content)
  sh("git add -A", dir)
  sh("git commit -q -m " & quoteShell(message), dir)
  execCmdEx("git rev-parse HEAD", workingDir = dir).output.strip()

proc normal(dir: string): string =
  ## Configuration files spell paths as they like (`<tree>/../io-mon/src`).
  normalizedPath(absolutePath(dir))

proc searchPathDirs(args: openArray[string]): seq[string] =
  for arg in args:
    if arg.startsWith("--path:"): result.add(normal(arg["--path:".len .. ^1]))

proc scriptPathDirs(script: string): seq[string] =
  ## The directories the search-path script's `switch("path", ...)` adds.
  for line in script.splitLines():
    let head = "switch(\"path\", \""
    if line.startsWith(head):
      result.add(normal(line[head.len ..< line.rfind('"')]))

suite "the extraction search path drops a displaced sibling":
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

  test "a stale sibling the recipe configuration names is not on the path":
    if builtIoMon().len == 0:
      skip("this binary was built without a $IO_MON_SRC holding " &
        IoMonMarker & " (build it in the development shell, which exports it)")
    else:
      root = createTempDir("repro-displaced-sibling-", "")
      let ws = root / "ws"
      let sdk = ws / "reprobuild"
      let ioMon = ws / "io-mon"
      # The sibling: base -> pin on main, `stale` on a side branch off base.
      createDir(ioMon / "src")
      sh("git init -q -b main", ioMon)
      sh("git config user.email tester@example.invalid", ioMon)
      sh("git config user.name Tester", ioMon)
      sh("git config commit.gpgsign false", ioMon)
      let base = commit(ioMon, "# base\n", "base")
      let pin = commit(ioMon, "# pin\n", "pin")
      sh("git checkout -q -b side " & base, ioMon)
      discard commit(ioMon, "# stale\n", "stale")
      # The source tree: no `.git`, the DSL marker, a flake.lock pin, and the
      # configuration that reaches for the sibling.
      createDir(sdk / "libs" / "repro_project_dsl" / "src")
      writeFile(sdk / "libs" / "repro_project_dsl" / "src" /
        "repro_project_dsl.nim", "")
      writeFile(sdk / "flake.lock", "{ \"nodes\": { \"io-mon-src\": " &
        "{ \"locked\": { \"owner\": \"metacraft-labs\", \"repo\": " &
        "\"io-mon\", \"rev\": \"" & pin & "\", \"type\": \"github\" } }, " &
        "\"root\": { \"inputs\": { \"io-mon-src\": \"io-mon-src\" } } }, " &
        "\"root\": \"root\", \"version\": 7 }\n")
      writeFile(sdk / "config.nims",
        "switch(\"path\", thisDir() & \"/../io-mon/src\")\n")
      writeFile(sdk / "repro.nim", "")
      seedSourcePackageEnvironment([("REPROBUILD_SOURCE_ROOT", sdk)])
      setCurrentDir(sdk)

      let packagePaths = bootstrapSiblingPackagePathFlagsFor(sdk, ws,
        runningEngineSourceIdentity())
      checkpoint("displaced: " & $packagePaths.displaced)
      check (ioMon / "src") notin searchPathDirs(packagePaths.flags)
      let recipeConfig = recipeConfigSearchPathFlags(sdk / "repro.nim",
        cwd = root)
      checkpoint("recipe configuration: " & $recipeConfig)
      # The control: the configuration really does name the sibling.
      check (ioMon / "src") in searchPathDirs(recipeConfig)

      var command = @["nim", "c"] & packagePaths.flags & @[ModuleArg]
      applyRecipeConfigurationSearchPaths(command, sdk, ModuleArg,
        recipeConfig, packagePaths)
      let launch = splitSearchPathReassertion(command, ModuleArg)
      let everyDir = searchPathDirs(launch.argv) & scriptPathDirs(launch.script)
      checkpoint("search path: " & $everyDir)
      for dir in everyDir:
        check not (dir == ioMon or dir.startsWith(ioMon & "/"))
      var ioMonRoots: seq[string]
      for dir in everyDir:
        if fileExists(dir / IoMonMarker) and dir notin ioMonRoots:
          ioMonRoots.add(dir)
      check ioMonRoots == @[normal(builtIoMon())]

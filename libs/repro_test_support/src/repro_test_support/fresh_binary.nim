## A helper binary a test runs from ``build/bin`` must be built from the
## tree under test.
##
## A test that spawns ``build/bin/<name>`` (the Evidence sink, the engine,
## a daemon) runs whatever binary is there. When nothing rebuilt it since
## its sources changed, the test reports on an old build, and a red case
## reads green: the A11 round-4 review found the sink's redaction case
## green only because ``build/bin/repro-evidence-sink`` predated the change
## that broke it (reprobuild-pm issue 2026-11-07-addon-allow-listed-source-
## field-turns-the-sinks-redaction-case-red-masked-by-a-stale-sink).
##
## ``freshRepoBinary`` refuses such a binary. ``scripts/build_apps.sh``
## compiles every app with its own nimcache (``build/nimcache/<name>/``),
## where Nim's build record (``<name>.json``) names every object it links
## -- one generated per Nim module, named after the module -- and every C
## file the last run compiled, a library's own C among them. A binary is
## fresh when each such source of the tree still exists and none is newer
## than the binary. (A library's C file is known only from the run that
## compiled it: after an incremental build that compiled nothing, Nim's
## record no longer names it, and an edit to it alone is not seen.) Anything
## else raises ``StaleHelperBinary`` naming the first offending file and
## the command that rebuilds it: the test fails, it never silently runs an
## old build.
##
## Falsifying build: ``-d:reproAddonMutation=stale-helper-accepted``
## accepts a binary older than its sources
## (``t_fresh_helper_binary_refuses_a_stale_build`` goes red).
##
## Mocks: none -- this is test support; it reads the real build outputs.

import std/[json, os, strutils, times]

const FreshMutation {.strdefine: "reproAddonMutation".} = ""
  ## A falsifying build's name (``repro_addon/mutations``); "" otherwise.

type
  StaleHelperBinary* = object of CatchableError
    ## ``build/bin/<name>`` is missing, has no dependency list, or is older
    ## than a source it was compiled from.

proc helperRebuildHint(name: string): string =
  "rebuild it from this tree first (`just build`, or " &
    "`bash scripts/build_apps.sh`)"

proc helperBuildDir*(repoRoot: string): string =
  ## Where the helper binaries are: ``build/`` of the tree, or
  ## ``$REPRO_TEST_BUILD_DIR`` (the Nim 2.2.4 lane builds its own there,
  ## ``scripts/run_nim224_lane.sh``).
  let d = getEnv("REPRO_TEST_BUILD_DIR")
  if d.len > 0: absolutePath(d, repoRoot) else: repoRoot / "build"

proc moduleSearchRoots(repoRoot: string): seq[string] =
  ## Where a module the build record names by package path can live in the
  ## tree: every library's ``src`` and every app, then the tree itself.
  for kind, d in walkDir(repoRoot / "libs"):
    if kind in {pcDir, pcLinkToDir} and dirExists(d / "src"): result.add(d / "src")
  for kind, d in walkDir(repoRoot / "apps"):
    if kind in {pcDir, pcLinkToDir}: result.add(d)
  result.add(repoRoot)

proc helperDependencies*(repoRoot, name: string): seq[string] =
  ## The tree's source files ``build/bin/<name>`` was compiled from, read
  ## from Nim's build record, ``build/nimcache/<name>/<name>.json``: each C
  ## file it compiled that is not generated (a library's C), and each
  ## module whose generated object it linked, named by Nim's mangling
  ## (``@p<package>@s<path>.nim.c``, ``@m<path>.nim.c``) and found in the
  ## tree. A module outside the tree (the standard library, the Nix store)
  ## is immutable for this purpose and left out. Raises
  ## ``StaleHelperBinary`` when there is no build record.
  let cache = helperBuildDir(repoRoot) / "nimcache" / name
  let record = cache / (name & ".json")
  if not fileExists(record):
    raise newException(StaleHelperBinary, "build/bin/" & name & " has no " &
      "build record (" & record & "): nothing shows what it was built " &
      "from; " & helperRebuildHint(name))
  let j = try: parseJson(readFile(record))
          except CatchableError as e:
            raise newException(StaleHelperBinary, record & " is not a " &
              "Nim build record (" & e.msg & "); " & helperRebuildHint(name))
  let roots = moduleSearchRoots(repoRoot)
  proc addModule(generated: string; into: var seq[string]) =
    var mangled = extractFilename(generated)
    if not mangled.endsWith(".nim.c") or mangled.len < 3: return
    mangled = mangled[2 ..< mangled.len - 2]          # drop "@p"/"@m", ".c"
    let rel = mangled.replace("@s", "/")
    for root in roots:
      if fileExists(root / rel):
        if root / rel notin into: into.add(root / rel)
        return
  # "compile" lists only what this run compiled -- empty after an
  # incremental build that changed no C -- so the modules are read from
  # "link", which names every object of every build. A library's own C
  # appears by its source path only in "compile".
  for c in j{"compile"}.getElems():
    let src = c[0].getStr()
    if src.len == 0: continue
    if src.startsWith(cache): addModule(src, result)
    elif src.startsWith(repoRoot) and src notin result: result.add(src)
  for o in j{"link"}.getElems():
    let obj = o.getStr()
    if obj.startsWith(cache) and obj.endsWith(".c.o"):
      addModule(obj[0 ..< obj.len - 2], result)

proc freshRepoBinary*(repoRoot, name: string): string =
  ## ``<repoRoot>/build/bin/<name>`` when it is at least as new as every
  ## source it was compiled from; raises ``StaleHelperBinary`` otherwise.
  result = helperBuildDir(repoRoot) / "bin" / addFileExt(name, ExeExt)
  if not fileExists(result):
    raise newException(StaleHelperBinary, result & " does not exist; " &
      helperRebuildHint(name))
  let built = getLastModificationTime(result)
  for dep in helperDependencies(repoRoot, name):
    if dep.startsWith("/nix/store/"): continue        # immutable inputs
    if not fileExists(dep):
      raise newException(StaleHelperBinary, result & " was built from " &
        dep & ", which no longer exists; " & helperRebuildHint(name))
    if FreshMutation != "stale-helper-accepted" and
        getLastModificationTime(dep) > built:
      raise newException(StaleHelperBinary, result & " is older than " &
        dep & " (" & $getLastModificationTime(dep) & " > " & $built &
        "); the test would run an old build; " & helperRebuildHint(name))

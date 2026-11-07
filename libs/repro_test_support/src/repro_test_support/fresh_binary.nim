## A helper binary a test runs from ``build/bin`` must be built from the
## tree under test.
##
## A test that spawns ``build/bin/<name>`` (the Evidence sink, the binary
## cache) runs whatever binary is there. When nothing rebuilt it since its
## sources changed, the test reports on an old build, and a red case reads
## green: the A11 round-4 review found the sink's redaction case green only
## because ``build/bin/repro-evidence-sink`` predated the change that broke
## it (reprobuild-pm issue 2026-11-07-addon-allow-listed-source-field-turns-
## the-sinks-redaction-case-red-masked-by-a-stale-sink).
##
## ``freshRepoBinary`` refuses such a binary. Its sources are the list Nim
## itself writes with ``--genDeps`` (``scripts/write_helper_deps.sh``, which
## ``scripts/build_apps.sh`` runs for each helper it builds, into
## ``build/nimcache/<name>/<name>.deps``): every file the compiler read,
## files a module ``include``s and modules from outside the tree (a sibling
## checkout such as ``../io-mon``) among them (reprobuild-pm issue
## 2026-11-08-fresh-binary-does-not-see-included-files-or-modules-outside-
## the-tree; §13 decision 65 of the ReproOS Add-On Mode spec). A file under
## ``/nix/store`` cannot change and is skipped. The binary is fresh when
## every other listed file still exists and none is newer than the binary,
## checked when the test runs. Anything else raises ``StaleHelperBinary``
## naming the first offending file and the command that rebuilds it: the
## test fails, it never silently runs an old build.
##
## Falsifying builds (``-d:reproAddonMutation=...``), each turning its case
## of ``t_fresh_helper_binary_refuses_a_stale_build`` red:
## ``stale-helper-accepted`` (a binary older than its sources is accepted),
## ``fresh-skips-included`` (an included file is not checked),
## ``fresh-skips-outside-tree`` (a module from outside the tree is not
## checked).
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

proc linkedModules(repoRoot, name: string): seq[string] =
  ## The tree's modules that have an object in Nim's build record
  ## (``<name>.json``'s ``link``): what the round-4 guard checked. Used only
  ## by the ``fresh-skips-included`` falsifier, to drop what it misses.
  let record = helperBuildDir(repoRoot) / "nimcache" / name / (name & ".json")
  if not fileExists(record): return
  var roots: seq[string]
  for kind, d in walkDir(repoRoot / "libs"):
    if kind in {pcDir, pcLinkToDir} and dirExists(d / "src"): roots.add(d / "src")
  for kind, d in walkDir(repoRoot / "apps"):
    if kind in {pcDir, pcLinkToDir}: roots.add(d)
  roots.add(repoRoot)
  for o in parseJson(readFile(record)){"link"}.getElems():
    var m = extractFilename(o.getStr())
    if not m.endsWith(".nim.c.o"): continue
    m = m[2 ..< m.len - 4].replace("@s", "/")
    for r in roots:
      if fileExists(r / m):
        result.add(r / m)
        break

proc helperDependencies*(repoRoot, name: string): seq[string] =
  ## Every source ``build/bin/<name>`` was compiled from that can change:
  ## the paths of ``build/nimcache/<name>/<name>.deps`` not under
  ## ``/nix/store``. Raises ``StaleHelperBinary`` when there is no list.
  let list = helperBuildDir(repoRoot) / "nimcache" / name / (name & ".deps")
  if not fileExists(list):
    raise newException(StaleHelperBinary, "build/bin/" & name & " has no " &
      "dependency list (" & list & "): nothing shows what it was built " &
      "from; " & helperRebuildHint(name))
  let root = absolutePath(repoRoot)
  when FreshMutation == "fresh-skips-included":
    let linked = linkedModules(repoRoot, name)
  for raw in readFile(list).splitLines():
    let dep = raw.strip()
    if dep.len == 0 or dep.startsWith("/nix/store/"): continue
    when FreshMutation == "fresh-skips-outside-tree":
      if not dep.startsWith(root & "/"): continue
    when FreshMutation == "fresh-skips-included":
      if dep.startsWith(root & "/") and dep notin linked: continue
    result.add(dep)

proc freshRepoBinary*(repoRoot, name: string): string =
  ## ``<build>/bin/<name>`` when it is at least as new as every source it
  ## was compiled from; raises ``StaleHelperBinary`` otherwise.
  result = helperBuildDir(repoRoot) / "bin" / addFileExt(name, ExeExt)
  if not fileExists(result):
    raise newException(StaleHelperBinary, result & " does not exist; " &
      helperRebuildHint(name))
  let built = getLastModificationTime(result)
  for dep in helperDependencies(repoRoot, name):
    if not fileExists(dep):
      raise newException(StaleHelperBinary, result & " was built from " &
        dep & ", which no longer exists; " & helperRebuildHint(name))
    if FreshMutation != "stale-helper-accepted" and
        getLastModificationTime(dep) > built:
      raise newException(StaleHelperBinary, result & " is older than " &
        dep & " (" & $getLastModificationTime(dep) & " > " & $built &
        "); the test would run an old build; " & helperRebuildHint(name))

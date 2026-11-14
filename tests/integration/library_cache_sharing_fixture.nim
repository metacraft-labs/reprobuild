## Shared fixture for the tests that ask whether a static library built the
## same way is built once: two checkouts of one project, or two projects that
## compile one library source with the same flags, at different absolute
## paths on one host.
##
## Not a test (no `t_` prefix), so the suite generator never compiles it on
## its own. The three tests that import it are
## `t_two_checkouts_share_a_static_library_edge`,
## `t_two_projects_share_a_library_built_with_the_same_flags` and
## `t_library_outputs_are_path_free_with_debug_info`.
##
## Everything here is real: the built `repro`, the C compiler and archiver on
## `PATH` (the dev shell's), real Git checkouts in fresh temporary
## directories, the engine's monitor and action cache, and the build report
## the engine writes with `--write-report`. Nothing is mocked. The evidence a
## test asserts on is the engine's own: each action's `launched` flag and
## cache decision, and the `portable-*` events of the report's trace, which
## say per edge why a record was or was not reused.

import std/[json, os, osproc, streams, strtabs, strutils, tables, tempfiles]

import repro_test_support

const
  ReprobuildRoot* = currentSourcePath().parentDir().parentDir().parentDir()

proc reproBinary*(): string =
  requireBinary(ReprobuildRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  TraceEvent* = object
    event*: string
    detail*: string

  EdgeOutcome* = object
    ## One action of one build, as the engine reported it.
    id*: string
    launched*: bool
    cacheDecision*: string
    cacheMissReason*: string
    cachePublishSkipReason*: string
    trace*: seq[TraceEvent]

  BuildRun* = object
    code*: int
    output*: string
    reportPath*: string
    edges*: OrderedTable[string, EdgeOutcome]

  SharedHost* = object
    ## What two builds on one host share: the action cache (where the
    ## portable memo records live, beside it) and the reprobuild store.
    scratch*: string
    actionCacheRoot*: string
    storeRoot*: string
    reportCount: int

proc newSharedHost*(prefix: string): SharedHost =
  result.scratch = createTempDir(prefix, "")
  result.actionCacheRoot = result.scratch / "action-cache"
  result.storeRoot = result.scratch / "store"
  createDir(result.actionCacheRoot)
  createDir(result.storeRoot)

proc cleanup*(host: SharedHost) =
  if host.scratch.len > 0 and dirExists(host.scratch):
    removeDir(host.scratch)

proc runChecked(cmd: string; workingDir: string) =
  let res = execCmdEx(cmd, workingDir = workingDir)
  if res.exitCode != 0:
    raise newException(OSError, "`" & cmd & "` failed in " & workingDir &
      " (exit " & $res.exitCode & "):\n" & res.output)

proc commitCheckout*(dir: string) =
  ## Make `dir` a Git checkout with one commit, as a developer's clone is.
  ## The engine walks up to the nearest `.git` to name the repository root,
  ## so a checkout without one would not be the layout under test.
  runChecked("git init -q", dir)
  runChecked("git add -A", dir)
  runChecked("git -c user.email=fixture@example.invalid " &
    "-c user.name=fixture -c commit.gpgsign=false commit -q -m fixture", dir)

proc copyCheckout*(source, dest: string) =
  ## A fresh checkout of `source`'s tree at `dest`, without any build state
  ## the source may carry.
  createDir(dest.parentDir)
  copyDir(source, dest)
  if dirExists(dest / ".repro"):
    removeDir(dest / ".repro")
  if dirExists(dest / ".git"):
    removeDir(dest / ".git")
  commitCheckout(dest)

proc parseReport(path: string): OrderedTable[string, EdgeOutcome] =
  let report = parseJson(readFile(path))
  for action in report["actions"]:
    let id = action["id"].getStr()
    result[id] = EdgeOutcome(id: id,
      launched: action{"launched"}.getBool(),
      cacheDecision: action{"cacheDecision"}.getStr(),
      cacheMissReason: action{"cacheMissReason"}.getStr(),
      cachePublishSkipReason: action{"cachePublishSkipReason"}.getStr())
  for entry in report{"trace"}.getElems():
    let id = entry{"actionId"}.getStr()
    if id in result:
      result[id].trace.add(TraceEvent(event: entry{"event"}.getStr(),
        detail: entry{"detail"}.getStr()))

proc build*(host: var SharedHost; project: string; portable: bool):
    BuildRun =
  ## `repro build` of `project` against the host's shared action cache and
  ## store, with the engine's cache evidence and trace collected and written
  ## to a report. `portable` turns the portable (path-independent) identity
  ## on, which is what lets a record made in one checkout be found from
  ## another.
  inc host.reportCount
  result.reportPath = host.scratch / ("report-" & $host.reportCount & ".json")
  let env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["REPRO_STORE_ROOT"] = host.storeRoot
  # Same-host sharing only: no remote binary cache is consulted and nothing
  # is published, whatever cache endpoint and publisher key the invoking
  # shell configures. Reuse between the two checkouts must come from what
  # the first build left on this host.
  env["REPRO_CACHE_DISABLE"] = "1"
  var remoteCacheVars: seq[string] = @[]
  for key, _ in env.pairs:
    if key.startsWith("REPRO_BINARY_CACHE_"):
      remoteCacheVars.add(key)
  for key in remoteCacheVars:
    env.del(key)
  if portable:
    env["REPRO_PORTABLE_CACHE"] = "1"
  elif env.hasKey("REPRO_PORTABLE_CACHE"):
    env.del("REPRO_PORTABLE_CACHE")
  let args = @["build", "--daemon=off", "--no-runquota",
    "--tool-provisioning=path",
    "--action-cache-root=" & host.actionCacheRoot,
    "--measure=trace,cache-evidence", "--log=actions",
    "--write-report=" & result.reportPath]
  let process = startProcess(reproBinary(), workingDir = project,
    args = args, env = env, options = {poStdErrToStdOut})
  result.output = process.outputStream.readAll()
  result.code = process.waitForExit()
  process.close()
  if fileExists(result.reportPath):
    result.edges = parseReport(result.reportPath)

proc engineReasons*(run: BuildRun; id: string): string =
  ## The engine's own account of one edge: whether it ran, its cache
  ## decision, and every portable-identity event the trace recorded for it.
  if id notin run.edges:
    return "edge " & id & ": not in the build report " & run.reportPath
  let edge = run.edges[id]
  result = "edge " & id & ": launched=" & $edge.launched &
    " cache=" & edge.cacheDecision
  if edge.cacheMissReason.len > 0:
    result.add(" miss=\"" & edge.cacheMissReason & "\"")
  if edge.cachePublishSkipReason.len > 0:
    result.add(" publish-skip=\"" & edge.cachePublishSkipReason & "\"")
  for event in edge.trace:
    if event.event.startsWith("portable") or
        event.event.startsWith("determinism") or
        event.event.startsWith("cache-restore"):
      result.add("\n    " & event.event & ": " & event.detail)

proc allEngineReasons*(run: BuildRun): string =
  for id in run.edges.keys:
    result.add(engineReasons(run, id) & "\n")

proc hasEdge*(run: BuildRun; id: string): bool =
  ## Whether the build report lists the edge at all. A test that asserts an
  ## edge did NOT launch must require this first: an edge missing from the
  ## report (a renamed id, a report that was never written) also reads as
  ## "not launched".
  id in run.edges

proc launched*(run: BuildRun; id: string): bool =
  id in run.edges and run.edges[id].launched

proc cacheDecision*(run: BuildRun; id: string): string =
  ## The engine's cache decision for the edge (`cdHit`, `cdMiss`, ...), or ""
  ## when the report does not list it.
  if id in run.edges: run.edges[id].cacheDecision else: ""

proc nonEmptyFile*(path: string): bool =
  fileExists(path) and getFileSize(path) > 0

proc sameBytes*(a, b: string): bool =
  fileExists(a) and fileExists(b) and readFile(a) == readFile(b)

# ---------------------------------------------------------------------------
# A project that builds a static library with flags the test chooses.
# ---------------------------------------------------------------------------

const
  LibraryCompileEdge* = "mathlib-compile-add"
  LibraryArchiveEdge* = "mathlib-archive"
  AppCompileEdge* = "app-compile-main"
  AppLinkEdge* = "app-link"
  LibraryObject* = ".repro/build/mathlib/obj/add.o"
  LibraryArchive* = ".repro/build/mathlib/libmathlib.a"

proc writeLibraryProject*(dest, packageName: string;
                          libFlags: openArray[string];
                          mapPrefix: bool; greeting: string) =
  ## A project whose build file declares the `mathlib` static library from
  ## its own copy of one library source, plus an application that links it.
  ##
  ## The C convention for a project with no build file of its own compiles
  ## with fixed flags, so a test that varies them (`-g`, a prefix map, `-O1`)
  ## declares the four edges itself, in the shape that convention uses: a
  ## depfile-policy `gcc -c` per source, a monitored `ar rcs`, a monitored
  ## link. `libFlags` are the library compile's flags; `mapPrefix` adds
  ## `-ffile-prefix-map=<project root>=.`, spelled from the root the provider
  ## runs in, which is how a build file would write it. `greeting` makes two
  ## projects' applications differ while their libraries do not.
  createDir(dest / "vendor" / "mathlib" / "src")
  createDir(dest / "vendor" / "mathlib" / "include" / "mathlib")
  createDir(dest / "app")
  writeFile(dest / "vendor" / "mathlib" / "src" / "add.c",
    "#include \"mathlib/add.h\"\n\nint add(int a, int b) {\n" &
    "    return a + b;\n}\n")
  writeFile(dest / "vendor" / "mathlib" / "include" / "mathlib" / "add.h",
    "#ifndef MATHLIB_ADD_H\n#define MATHLIB_ADD_H\n" &
    "int add(int a, int b);\n#endif\n")
  writeFile(dest / "app" / "main.c",
    "#include <stdio.h>\n#include \"mathlib/add.h\"\n\n" &
    "int main(void) {\n    printf(\"%s %d\\n\", " & escape(greeting) &
    ", add(2, 3));\n    return 0;\n}\n")
  var flags = "@["
  for i, flag in libFlags:
    if i > 0:
      flags.add(", ")
    flags.add(escape(flag))
  flags.add("]")
  if mapPrefix:
    flags.add(" & @[\"-ffile-prefix-map=\" & root & \"=.\"]")
  writeFile(dest / "repro.nim", """import std/os
import repro_project_dsl

package PACKAGE:
  defaultToolProvisioning "path"
  uses:
    "gcc >=11"

  build:
    let root = activeProviderProjectRoot()
    let libFlags: seq[string] = FLAGS
    let libObj = root / "LIBOBJ"
    let libDep = libObj & ".d"
    let libArchive = root / "LIBARCHIVE"
    let appObj = root / ".repro/build/app/obj/main.o"
    let appDep = appObj & ".d"
    let appBin = root / ".repro/build/app/app"
    createDir(libObj.parentDir)
    createDir(appObj.parentDir)
    let libCompile = buildAction(id = "LIBCOMPILE",
      call = inlineExecCall(@["gcc", "-c"] & libFlags & @["-MD", "-MF", libDep,
        "-I", root / "vendor/mathlib/include", "-o", libObj,
        root / "vendor/mathlib/src/add.c"], root),
      inputs = @[root / "vendor/mathlib/src/add.c"],
      outputs = @[libObj], pool = "compile", depfile = libDep,
      dependencyPolicy = makeDepfilePolicy(libDep),
      toolIdentityRefs = @["gcc"])
    let libArchiveAction = buildAction(id = "LIBARCHIVEEDGE",
      call = inlineExecCall(@["ar", "rcs", libArchive, libObj], root),
      deps = @[libCompile.id], inputs = @[libObj], outputs = @[libArchive],
      pool = "compile", dependencyPolicy = automaticMonitorPolicy(),
      toolIdentityRefs = @["ar"])
    let appCompile = buildAction(id = "APPCOMPILE",
      call = inlineExecCall(@["gcc", "-c", "-O2", "-MD", "-MF", appDep,
        "-I", root / "vendor/mathlib/include", "-o", appObj,
        root / "app/main.c"], root),
      inputs = @[root / "app/main.c"], outputs = @[appObj], pool = "compile",
      depfile = appDep, dependencyPolicy = makeDepfilePolicy(appDep),
      toolIdentityRefs = @["gcc"])
    let appLink = buildAction(id = "APPLINK",
      call = inlineExecCall(@["gcc", "-o", appBin, appObj, libArchive], root),
      deps = @[appCompile.id, libArchiveAction.id],
      inputs = @[appObj, libArchive], outputs = @[appBin], pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      toolIdentityRefs = @["gcc"])
    defaultBuildAction(appLink)
""".multiReplace(("PACKAGE", packageName), ("FLAGS", flags),
    ("LIBOBJ", LibraryObject), ("LIBARCHIVEEDGE", LibraryArchiveEdge),
    ("LIBARCHIVE", LibraryArchive), ("LIBCOMPILE", LibraryCompileEdge),
    ("APPCOMPILE", AppCompileEdge), ("APPLINK", AppLinkEdge)))
  commitCheckout(dest)

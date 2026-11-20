## Shared fixture for the tests that ask whether a static library built the
## same way is built once: two checkouts of one project, or two projects that
## compile one library source with the same flags, at different absolute
## paths on one host.
##
## Not a test (no `t_` prefix), so the suite generator never compiles it on
## its own. The tests that import it are
## `t_two_checkouts_share_a_static_library_edge`,
## `t_two_projects_share_a_library_built_with_the_same_flags`,
## `t_library_outputs_are_path_free_with_debug_info`,
## `t_a_read_outside_the_logical_roots_stays_local`,
## `t_restored_outputs_match_the_recorded_digests`,
## `t_a_compiler_environment_difference_is_a_miss_not_a_wrong_hit`,
## `t_an_archive_rebuilt_in_another_checkout_is_byte_identical`,
## `t_same_library_two_feature_sets_two_artifacts`,
## `t_key_difference_explanation_names_the_cause` and, on macOS,
## `t_two_checkouts_share_a_static_library_edge_macos`.
##
## Everything here is real: the built `repro`, the C compiler and archiver
## (the dev shell's on `PATH`, or the toolchain the engine realizes into the
## store root under `--tool-provisioning=tarball`), real Git checkouts in fresh temporary
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
    dependencyPolicyKind*: string
    monitorReads*: seq[string]
      ## The paths the monitor observed the action read (the report's
      ## `evidence.monitorReads`): empty for an edge whose evidence is a
      ## depfile, or one the monitor never entered.
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
  ## A fresh action cache and store in a new temporary directory.
  ##
  ## The store is where `--tool-provisioning=tarball` realizes the C
  ## toolchain (`<store root>/tool-store`), which costs a 102 MB download and
  ## 240 MB of extraction per realized view. Like the catalog conformance sweep
  ## (`t_stdlib_catalog_tarball_arms_realize`), a test run pays that once per
  ## pin rather than once per case when `REPRO_CONFORMANCE_STORE` names a
  ## directory that survives between runs; the store is content-addressed and
  ## each case still gets its own action cache, so nothing a case asserts on
  ## carries over. Without the variable every case uses a store of its own.
  result.scratch = createTempDir(prefix, "")
  result.actionCacheRoot = result.scratch / "action-cache"
  let persistentStore = getEnv("REPRO_CONFORMANCE_STORE")
  result.storeRoot =
    if persistentStore.len > 0: absolutePath(persistentStore)
    else: result.scratch / "store"
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
      cachePublishSkipReason: action{"cachePublishSkipReason"}.getStr(),
      dependencyPolicyKind: action{"dependencyPolicyKind"}.getStr())
    for path in action{"evidence"}{"monitorReads"}.getElems():
      result[id].monitorReads.add(path.getStr())
  for entry in report{"trace"}.getElems():
    let id = entry{"actionId"}.getStr()
    if id in result:
      result[id].trace.add(TraceEvent(event: entry{"event"}.getStr(),
        detail: entry{"detail"}.getStr()))

proc build*(host: var SharedHost; project: string; portable: bool;
            provisioning = "path";
            extraEnv: openArray[(string, string)] = [];
            dropEnv: openArray[string] = [];
            target = ""): BuildRun =
  ## `repro build` of `project` against the host's shared action cache and
  ## store, with the engine's cache evidence and trace collected and written
  ## to a report. `portable` turns the portable (path-independent) identity
  ## on, which is what lets a record made in one checkout be found from
  ## another. `provisioning` is the `--tool-provisioning` mode: `path` takes
  ## the C toolchain from `PATH`, `tarball` has the engine realize its Linux
  ## C toolchain into the store root. `extraEnv` sets variables on top of
  ## the invoking environment (after `portable` has applied), for a test
  ## that gives one checkout's build an environment the other's lacks;
  ## `dropEnv` removes variables the invoking environment may carry.
  ## `target` is a selector to build instead of the project's default (a
  ## CMake build directory's `build#all`), relative to `project`.
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
  for key in dropEnv:
    if env.hasKey(key):
      env.del(key)
  for (key, value) in extraEnv:
    env[key] = value
  let args = @["build", "--daemon=off", "--no-runquota",
    "--tool-provisioning=" & provisioning,
    "--action-cache-root=" & host.actionCacheRoot,
    "--measure=trace,cache-evidence", "--log=actions",
    "--write-report=" & result.reportPath] &
    (if target.len > 0: @[target] else: @[])
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

# ---------------------------------------------------------------------------
# macOS: the same library built with a store-provisioned toolchain, or with
# the system's.
# ---------------------------------------------------------------------------

type
  MacosToolchain* = enum
    mtStoreZig
      ## `zig cc` and `zig ar`, realized into the reprobuild store root by
      ## `--tool-provisioning=tarball`: the only C compiler and archiver the
      ## catalog provisions into the store root on Apple Silicon.
    mtSystemUsrBin
      ## `/usr/bin/gcc` and `/usr/bin/ar`, the platform's own tools, which
      ## sit under the system integrity protection prefix.

proc writeMacosLibraryProject*(dest, packageName: string;
                               toolchain: MacosToolchain) =
  ## A project that declares the `mathlib` static library's compile and
  ## archive edges (and an application that links it), spelled for one of
  ## the two macOS toolchains.
  ##
  ## Both toolchains get the same edges: a compile whose evidence is the
  ## automatic monitor (what a content-checked compile gets under the
  ## portable identity), and a monitored archive, both under the `hybrid`
  ## input-check policy, which an edge states itself because no macOS
  ## provisioning declares it for the tool. The compile takes no `-MD`
  ## depfile flags: `zig cc -c -MD -MF` re-executes its own image and the
  ## monitor accounts for that as an unmonitored exec (the limit recorded in
  ## the test that uses this). `-g0` keeps the object free of the checkout
  ## path, so the two checkouts' bytes can be compared. For `mtStoreZig` the
  ## compiler's cache directories are inside the project, not `~/.cache/zig`.
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
    "int main(void) {\n    printf(\"%d\\n\", add(2, 3));\n    return 0;\n}\n")
  let (provisioning, uses, cc, ar, refs, env) =
    case toolchain
    of mtStoreZig:
      ("tarball", "  uses:\n    \"zig >=0.14 <0.15\"\n",
       "@[\"zig\", \"cc\", \"-target\", \"aarch64-macos\"]",
       "@[\"zig\", \"ar\"]", "@[\"zig\"]",
       "      env = zigEnv,\n")
    of mtSystemUsrBin:
      ("path", "", "@[\"/usr/bin/gcc\"]", "@[\"/usr/bin/ar\"]", "@[]", "")
  writeFile(dest / "repro.nim", """import std/os
import repro_project_dsl

package PACKAGE:
  defaultToolProvisioning "PROVISIONING"
USES
  build:
    let root = activeProviderProjectRoot()
    let cc: seq[string] = CC
    let ar: seq[string] = AR
    let zigEnv = @[("ZIG_GLOBAL_CACHE_DIR", root / ".repro/zig-cache"),
      ("ZIG_LOCAL_CACHE_DIR", root / ".repro/zig-cache/local")]
    let libObj = root / "LIBOBJ"
    let libArchive = root / "LIBARCHIVE"
    let appObj = root / ".repro/build/app/obj/main.o"
    let appBin = root / ".repro/build/app/app"
    createDir(libObj.parentDir)
    createDir(appObj.parentDir)
    let libCompile = buildAction(id = "LIBCOMPILE",
      call = inlineExecCall(cc & @["-c", "-O2", "-g0",
        "-I", root / "vendor/mathlib/include", "-o", libObj,
        root / "vendor/mathlib/src/add.c"], root),
      inputs = @[root / "vendor/mathlib/src/add.c"],
      outputs = @[libObj], pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      actionCachePolicy = acfpHybrid,
ENV      toolIdentityRefs = REFS)
    let libArchiveAction = buildAction(id = "LIBARCHIVEEDGE",
      call = inlineExecCall(ar & @["rcs", libArchive, libObj], root),
      deps = @[libCompile.id], inputs = @[libObj], outputs = @[libArchive],
      pool = "compile", dependencyPolicy = automaticMonitorPolicy(),
      actionCachePolicy = acfpHybrid,
ENV      toolIdentityRefs = REFS)
    let appCompile = buildAction(id = "APPCOMPILE",
      call = inlineExecCall(cc & @["-c", "-O2", "-g0",
        "-I", root / "vendor/mathlib/include", "-o", appObj,
        root / "app/main.c"], root),
      inputs = @[root / "app/main.c"], outputs = @[appObj], pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
ENV      toolIdentityRefs = REFS)
    let appLink = buildAction(id = "APPLINK",
      call = inlineExecCall(cc & @["-o", appBin, appObj, libArchive], root),
      deps = @[appCompile.id, libArchiveAction.id],
      inputs = @[appObj, libArchive], outputs = @[appBin], pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
ENV      toolIdentityRefs = REFS)
    defaultBuildAction(appLink)
""".multiReplace(("PACKAGE", packageName), ("PROVISIONING", provisioning),
    ("USES", uses), ("CC", cc), ("AR", ar), ("ENV", env), ("REFS", refs),
    ("LIBOBJ", LibraryObject), ("LIBARCHIVEEDGE", LibraryArchiveEdge),
    ("LIBARCHIVE", LibraryArchive), ("LIBCOMPILE", LibraryCompileEdge),
    ("APPCOMPILE", AppCompileEdge), ("APPLINK", AppLinkEdge)))
  commitCheckout(dest)

# ---------------------------------------------------------------------------
# A library with a compile-time feature, and applications that select it.
# ---------------------------------------------------------------------------

const
  MathlibFeature* = "MATHLIB_WITH_MUL"
    ## The library's compile-time feature: with it defined, the library also
    ## defines `mul`, and an application built with it prints `mul(2, 3)`.
  AppBinary* = ".repro/build/app/app"

proc writeFeatureLibraryProject*(dest, packageName: string;
                                 features: openArray[string];
                                 libFlags: openArray[string] = ["-O2"];
                                 addend = 0) =
  ## An application whose build file compiles the `mathlib` static library
  ## from its own copy of the library source, selecting the library's
  ## compile-time `features` (each passed as `-D<feature>` to the library's
  ## compile AND the application's, as a build that configures a vendored
  ## library does), then links and builds the application.
  ##
  ## The edges have the shape and ids of `writeLibraryProject`: a compile and
  ## a monitored archive for the library, a compile and a link for the
  ## application, none stating an input-check policy (the `gcc` and `ar`
  ## tools declare `hybrid`). `libFlags` are the library compile's other
  ## flags; `addend` changes the library source's bytes (`add` returns
  ## `a + b + addend`) for a test that needs another source.
  createDir(dest / "vendor" / "mathlib" / "src")
  createDir(dest / "vendor" / "mathlib" / "include" / "mathlib")
  createDir(dest / "app")
  writeFile(dest / "vendor" / "mathlib" / "src" / "add.c",
    "#include \"mathlib/add.h\"\n\nint add(int a, int b) {\n" &
    "    return a + b" & (if addend != 0: " + " & $addend else: "") &
    ";\n}\n\n#ifdef " & MathlibFeature & "\n" &
    "int mul(int a, int b) {\n    return a * b;\n}\n#endif\n")
  writeFile(dest / "vendor" / "mathlib" / "include" / "mathlib" / "add.h",
    "#ifndef MATHLIB_ADD_H\n#define MATHLIB_ADD_H\n" &
    "int add(int a, int b);\n#ifdef " & MathlibFeature & "\n" &
    "int mul(int a, int b);\n#endif\n#endif\n")
  writeFile(dest / "app" / "main.c",
    "#include <stdio.h>\n#include \"mathlib/add.h\"\n\n" &
    "int main(void) {\n#ifdef " & MathlibFeature & "\n" &
    "    printf(\"%d %d\\n\", add(2, 3), mul(2, 3));\n#else\n" &
    "    printf(\"%d\\n\", add(2, 3));\n#endif\n    return 0;\n}\n")
  proc nimSeq(items: openArray[string]): string =
    result = "@["
    for i, item in items:
      if i > 0:
        result.add(", ")
      result.add(escape(item))
    result.add("]")
  writeFile(dest / "repro.nim", """import std/os
import repro_project_dsl

package PACKAGE:
  defaultToolProvisioning "tarball"
  uses:
    "gcc >=11"

  build:
    let root = activeProviderProjectRoot()
    # The library features this application selects.
    let features: seq[string] = FEATURES
    var defines: seq[string] = @[]
    for feature in features:
      defines.add("-D" & feature)
    let libFlags: seq[string] = FLAGS
    let libObj = root / "LIBOBJ"
    let libArchive = root / "LIBARCHIVE"
    let appObj = root / ".repro/build/app/obj/main.o"
    let appBin = root / "APPBIN"
    createDir(libObj.parentDir)
    createDir(appObj.parentDir)
    let libCompile = buildAction(id = "LIBCOMPILE",
      call = inlineExecCall(@["gcc", "-c"] & libFlags & defines &
        @["-I", root / "vendor/mathlib/include", "-o", libObj,
        root / "vendor/mathlib/src/add.c"], root),
      inputs = @[root / "vendor/mathlib/src/add.c"],
      outputs = @[libObj], pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      toolIdentityRefs = @["gcc"])
    let libArchiveAction = buildAction(id = "LIBARCHIVEEDGE",
      call = inlineExecCall(@["ar", "rcs", libArchive, libObj], root),
      deps = @[libCompile.id], inputs = @[libObj], outputs = @[libArchive],
      pool = "compile", dependencyPolicy = automaticMonitorPolicy(),
      toolIdentityRefs = @["ar"])
    let appCompile = buildAction(id = "APPCOMPILE",
      call = inlineExecCall(@["gcc", "-c", "-O2"] & defines &
        @["-I", root / "vendor/mathlib/include", "-o", appObj,
        root / "app/main.c"], root),
      inputs = @[root / "app/main.c"], outputs = @[appObj], pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      toolIdentityRefs = @["gcc"])
    let appLink = buildAction(id = "APPLINK",
      call = inlineExecCall(@["gcc", "-o", appBin, appObj, libArchive], root),
      deps = @[appCompile.id, libArchiveAction.id],
      inputs = @[appObj, libArchive], outputs = @[appBin], pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      toolIdentityRefs = @["gcc"])
    defaultBuildAction(appLink)
""".multiReplace(("PACKAGE", packageName), ("FEATURES", nimSeq(features)),
    ("FLAGS", nimSeq(libFlags)), ("LIBOBJ", LibraryObject),
    ("LIBARCHIVEEDGE", LibraryArchiveEdge), ("LIBARCHIVE", LibraryArchive),
    ("LIBCOMPILE", LibraryCompileEdge), ("APPCOMPILE", AppCompileEdge),
    ("APPLINK", AppLinkEdge), ("APPBIN", AppBinary)))
  commitCheckout(dest)

proc traceDetails*(run: BuildRun; id, event: string): seq[string] =
  ## The details of every `event` the build's trace recorded for edge `id`.
  if id in run.edges:
    for entry in run.edges[id].trace:
      if entry.event == event:
        result.add(entry.detail)

proc traceField(details: openArray[string]; field: string): string =
  for detail in details:
    for word in detail.split(' '):
      if word.startsWith(field & "="):
        return word[field.len + 1 .. ^1]
  ""

proc recordedPortableKey*(run: BuildRun; id: string): tuple[weak, strong: string] =
  ## The portable weak and strong keys the engine computed for `id` when it
  ## EXECUTED the edge (its `portable-fingerprint` event); "" when it did
  ## not execute it or the edge has no portable record.
  let details = run.traceDetails(id, "portable-fingerprint")
  (weak: traceField(details, "weak"), strong: traceField(details, "strong"))

proc resolvedPortableKey*(run: BuildRun; id: string): string =
  ## The strong key of the record the engine resolved `id` from without
  ## executing it (`portable-resolved local strong=...`), or "".
  traceField(run.traceDetails(id, "portable-resolved"), "strong")

proc archiveSymbols*(path: string): seq[string] =
  ## The symbol names a System V / GNU `ar` archive's symbol index lists
  ## (its first member, named `/`): a 4-byte big-endian count, that many
  ## 4-byte offsets, then the names, each NUL-terminated
  ## (https://sourceware.org/binutils/docs/binutils/ar.html, and the format
  ## in FreeBSD's ar(5)).
  let data = readFile(path)
  if not data.startsWith("!<arch>\n") or data.len < 8 + 60:
    raise newException(ValueError, path & " is not an ar archive")
  let header = data[8 ..< 8 + 60]
  if header[0 ..< 16].strip() != "/":
    raise newException(ValueError, path & " has no symbol index")
  let size = parseInt(header[48 ..< 58].strip())
  let body = data[8 + 60 ..< 8 + 60 + size]
  let count = (ord(body[0]) shl 24) or (ord(body[1]) shl 16) or
    (ord(body[2]) shl 8) or ord(body[3])
  var at = 4 + 4 * count
  for _ in 0 ..< count:
    let stop = body.find('\0', at)
    result.add(body[at ..< stop])
    at = stop + 1

proc runApplication*(project: string): string =
  ## What the application `writeFeatureLibraryProject` built prints.
  let res = execCmdEx(quoteShell(project / AppBinary))
  if res.exitCode != 0:
    raise newException(OSError, project / AppBinary & " exited " &
      $res.exitCode & ": " & res.output)
  res.output.strip()

proc reproKeyCommand*(host: SharedHost; args: openArray[string];
                      provisioning = "tarball"): tuple[code: int,
                        output, stderr: string] =
  ## `repro cache <args> --json` against the host's store and action cache:
  ## the same configuration `build` runs with, so the keys it computes are
  ## the ones a build of the same projects is keyed by.
  let env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["REPRO_STORE_ROOT"] = host.storeRoot
  env["REPRO_CACHE_DISABLE"] = "1"
  # As `build` runs with `--no-runquota`: planning the graph starts no lease
  # daemon of its own.
  env["REPROBUILD_NO_RUNQUOTA"] = "1"
  if env.hasKey("REPRO_PORTABLE_CACHE"):
    env.del("REPRO_PORTABLE_CACHE")
  # Stdout is the JSON document; stderr (notes, a runquotad notice) goes to
  # a file, so neither can fill a pipe the other is waiting on.
  let errPath = host.scratch / "repro-cache-stderr.txt"
  let command = quoteShellCommand(@[reproBinary(), "cache"] & @args &
    @["--json", "--tool-provisioning=" & provisioning,
      "--action-cache-root=" & host.actionCacheRoot]) & " 2> " &
    quoteShell(errPath)
  let res = execCmdEx(command, env = env, workingDir = host.scratch)
  result.code = res.exitCode
  result.output = res.output
  result.stderr = if fileExists(errPath): readFile(errPath) else: ""

proc explainKeys*(host: SharedHost; first, second: string;
                  provisioning = "tarball"): JsonNode =
  ## The `reprobuild.key-explanation.v1` document `repro cache explain`
  ## prints for two operands (selectors `<project>#<action>` or key files).
  let res = reproKeyCommand(host, ["explain", first, second], provisioning)
  if res.code != 0:
    raise newException(OSError, "repro cache explain " & first & " " &
      second & " exited " & $res.code & ":\n" & res.stderr & res.output)
  parseJson(res.output)

proc actionKeyDocument*(host: SharedHost; selector, dest: string;
                        provisioning = "tarball"): JsonNode =
  ## `repro cache key <selector> --json`, also written to `dest`.
  let res = reproKeyCommand(host, ["key", selector], provisioning)
  if res.code != 0:
    raise newException(OSError, "repro cache key " & selector & " exited " &
      $res.code & ":\n" & res.stderr & res.output)
  writeFile(dest, res.output)
  parseJson(res.output)

proc cacheSharing*(host: SharedHost; selector: string;
                   provisioning = "tarball"): JsonNode =
  ## The `reprobuild.cache-sharing.v1` document `repro cache sharing`
  ## prints for `selector` (a project directory, or `<project>#<target>`).
  let res = reproKeyCommand(host, ["sharing", selector], provisioning)
  if res.code != 0:
    raise newException(OSError, "repro cache sharing " & selector &
      " exited " & $res.code & ":\n" & res.stderr & res.output)
  parseJson(res.output)

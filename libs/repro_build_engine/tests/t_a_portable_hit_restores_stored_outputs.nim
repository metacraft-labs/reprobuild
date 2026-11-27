## A portable cache hit in a second checkout on the same host restores the
## outputs from bytes the first checkout's build stored, with no remote
## restorer configured (Caching-Architecture.md "Design for XPC-AREQ1", D6),
## and puts in place what the build needs (D7).
##
## The graph has the shape of a library build: `t-compile` writes
## `out/obj/add.o` from `src/add.c`; `t-archive` reads it and writes
## `out/libmathlib.a` (the library target, declared as a typed output the way
## the C convention declares a member's library); `t-app` reads the library
## and writes `out/app`. Every edge declares the `checksum` input-check
## policy, so each record may be served across checkouts. Checkout A builds
## it; checkout B, at another absolute path, sharing A's action-cache root,
## builds it with the portable pre-pass on and no `portableMemoRestorer`.
##
## What each case pins:
## * D6: B executes nothing, and `out/app` and `out/libmathlib.a` are A's
##   bytes. A's build stored them under `<action-cache root>/portable-outputs`.
## * D7 item 3: `libmathlib.a` is put in place although its only consumer
##   resolved too, because its action declares the library as a typed
##   output. The control without the typed output leaves it out (so the
##   first case does not pass merely because everything is restored).
## * D7, the intermediate: `add.o` is not put in place when nothing needs
##   it; when a stale `add.o` is present, it is replaced by the recorded
##   bytes.
## * The pre-pass's per-lookup memo of on-disk identities is per pre-pass:
##   a checkout whose copy of a shared input (a stand-in for a toolchain
##   file every compile reads) differs misses, even when the same process
##   looked the same logical path up for another checkout just before.
## * D6, the check: a stored blob whose bytes were altered is refused (the
##   trace names the output and "digest mismatch"), removed, and the edge
##   executes and produces the right bytes; a record made under the
##   `timestamp` policy stored no bytes and restores nothing. The edge that
##   re-ran reproduced the recorded bytes, so its dependent, un-resolved with
##   it, is served at dispatch against them.
##
## No mocks: real builtin actions run by the engine, real files, the real
## portable memo plane and output store under a fresh action-cache root.

import std/[options, os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core
import repro_local_store

let TmpDir = absolutePath(
  "build/test-tmp/t_a_portable_hit_restores_stored_outputs-" &
  testCaseScratchSlug())

const
  CompileId = "t-compile"
  ArchiveId = "t-archive"
  AppId = "t-app"

proc newCheckout(path: string): string =
  result = TmpDir / path / "proj"
  createDir(result / "src")
  createDir(result / "out" / "obj")
  writeFile(result / "src" / "add.c", "int add(int a, int b);\n")

proc graphOf(project: string; typedLibrary = true;
             policy = ffpChecksum): seq[BuildAction] =
  let p = project
  let compile = builtinAction(bakWriteText, CompileId, cwd = p,
    inputs = [p / "src" / "add.c"], outputs = [p / "out" / "obj" / "add.o"],
    text = "object code of add\n", actionCachePolicy = policy,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  # A `write-text` builtin stands in for `ar`: its record may cross
  # checkouts (a `copy-file` builtin's may not, Edge-Derived-Identities.md
  # §10 decision 23), and its output differs from the object's bytes.
  var archive = builtinAction(bakWriteText, ArchiveId, cwd = p,
    deps = [CompileId], inputs = [p / "out" / "obj" / "add.o"],
    outputs = [p / "out" / "libmathlib.a"], actionCachePolicy = policy,
    text = "archive holding add.o\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  if typedLibrary:
    archive.typedOutputs = @[EngineTypedOutput(fieldName: "library",
      types: @["StaticLibrary"], path: p / "out" / "libmathlib.a")]
  let app = builtinAction(bakWriteText, AppId, cwd = p,
    deps = [ArchiveId], inputs = [p / "out" / "libmathlib.a"],
    outputs = [p / "out" / "app"], text = "linked app\n",
    actionCachePolicy = policy,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  @[compile, archive, app]

proc configFor(project, shared: string; lookup: bool;
               contentCheckedOnly = true): BuildEngineConfig =
  result = defaultBuildEngineConfig(project.parentDir / "cache")
  result.maxParallelism = 1
  result.actionCacheRoot = shared
  result.portableRoots = @[
    LogicalRoot(label: "project", path: project, kind: lrkTracked)]
  result.portableContentCheckedOnly = contentCheckedOnly
  result.portableLookup = lookup

proc resultOf(run: BuildRunResult; id: string): ActionResult =
  for r in run.results:
    if r.id == id:
      return r
  raise newException(KeyError, "no result for " & id)

proc details(run: BuildRunResult; id, event: string): seq[string] =
  for item in run.trace:
    if item.actionId == id and item.event == event:
      result.add(item.detail)

proc build(project, shared: string; lookup: bool; typedLibrary = true;
           policy = ffpChecksum; contentCheckedOnly = true): BuildRunResult =
  result = runBuild(graph(graphOf(project, typedLibrary, policy),
    newSeq[BuildPool]()), configFor(project, shared, lookup,
    contentCheckedOnly))
  for r in result.results:
    checkpoint(r.id & ": " & $r.status & " launched=" & $r.launched & " " &
      r.reason & " " & r.portableReason)
  for item in result.trace:
    if item.event.startsWith("portable"):
      checkpoint(item.actionId & " " & item.event & ": " & item.detail)
  for r in result.results:
    require r.status in {asSucceeded, asCacheHit, asUpToDate}

proc blobHolding(shared, content: string): string =
  ## The stored blob whose bytes are `content`, found by its bytes.
  let store = shared / PortableOutputsDirName
  if not dirExists(store):
    return ""
  for path in walkDirRec(store):
    if readFile(path) == content:
      return path
  ""

suite "a portable hit restores the outputs a checkout on this host stored":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "the second checkout executes nothing and gets the library and the app":
    let shared = TmpDir / "shared"
    let a = newCheckout("a")
    let first = build(a, shared, lookup = false)
    # Vacuity guard: A executed every edge, and stored their bytes.
    for id in [CompileId, ArchiveId, AppId]:
      require first.resultOf(id).launched
      require first.resultOf(id).portable
    require first.details(ArchiveId, "portable-outputs-stored").len == 1
    require blobHolding(shared, readFile(a / "out" / "libmathlib.a")).len > 0

    let b = newCheckout("somewhere/else/b")
    let second = build(b, shared, lookup = true)
    for id in [CompileId, ArchiveId, AppId]:
      check second.details(id, "portable-resolved").len == 1
      check not second.resultOf(id).launched
      check second.resultOf(id).status == asCacheHit
    check readFile(b / "out" / "app") == readFile(a / "out" / "app")
    check readFile(b / "out" / "libmathlib.a") ==
      readFile(a / "out" / "libmathlib.a")
    # The intermediate nothing consumes here is not put in place.
    check not fileExists(b / "out" / "obj" / "add.o")

  test "without the typed output the resolved library is not put in place":
    let shared = TmpDir / "shared-untyped"
    let a = newCheckout("a")
    discard build(a, shared, lookup = false, typedLibrary = false)
    let b = newCheckout("b")
    let second = build(b, shared, lookup = true, typedLibrary = false)
    for id in [CompileId, ArchiveId, AppId]:
      check not second.resultOf(id).launched
    check fileExists(b / "out" / "app")
    check not fileExists(b / "out" / "libmathlib.a")

  test "a stale intermediate present in the second checkout is replaced":
    let shared = TmpDir / "shared-stale"
    let a = newCheckout("a")
    discard build(a, shared, lookup = false)
    let b = newCheckout("b")
    writeFile(b / "out" / "obj" / "add.o", "stale bytes from another build\n")
    let second = build(b, shared, lookup = true)
    check not second.resultOf(CompileId).launched
    check readFile(b / "out" / "obj" / "add.o") ==
      readFile(a / "out" / "obj" / "add.o")

  test "an altered stored blob is refused, removed, and the edge rebuilds":
    let shared = TmpDir / "shared-altered"
    let a = newCheckout("a")
    discard build(a, shared, lookup = false)
    let recorded = readFile(a / "out" / "libmathlib.a")
    let blob = blobHolding(shared, recorded)
    require blob.len > 0
    writeFile(blob, "altered library bytes\n")
    let b = newCheckout("b")
    let second = build(b, shared, lookup = true)
    let failures = second.details(ArchiveId, "portable-restore-failed")
    check failures.len == 1
    check failures.len == 1 and
      failures[0] == "project:out/libmathlib.a: digest mismatch"
    check second.resultOf(ArchiveId).launched
    # The archive's re-run reproduced the recorded library, so the app,
    # un-resolved with it, is looked up again at dispatch against those bytes
    # and served from its record (`latePortableLookup`).
    check not second.resultOf(AppId).launched
    # Resolved by the pre-pass, un-resolved with the archive, resolved
    # again at dispatch.
    check second.details(AppId, "portable-resolved").len == 2
    check second.details(AppId, "portable-unresolved").len == 1
    check readFile(b / "out" / "libmathlib.a") == recorded
    check readFile(b / "out" / "app") == readFile(a / "out" / "app")
    # The altered blob was removed, and B's own run stored the right bytes.
    check blobHolding(shared, "altered library bytes\n").len == 0
    check blobHolding(shared, recorded).len > 0

  test "a timestamp record stores no bytes and restores nothing":
    let shared = TmpDir / "shared-timestamp"
    let a = newCheckout("a")
    let first = build(a, shared, lookup = false, policy = ffpTimestamp,
      contentCheckedOnly = false)
    require first.resultOf(ArchiveId).portable
    check first.details(ArchiveId, "portable-outputs-not-stored").len == 1
    check blobHolding(shared, readFile(a / "out" / "libmathlib.a")).len == 0
    let b = newCheckout("b")
    let second = build(b, shared, lookup = true, policy = ffpTimestamp,
      contentCheckedOnly = false)
    check second.resultOf(ArchiveId).launched
    check second.resultOf(AppId).launched
    # The library target is the first output the pre-pass puts in place.
    let failed = second.details(ArchiveId, "portable-restore-failed")
    check failed.len == 1
    check failed.len == 1 and "not stored on this host" in failed[0]

  test "a differing shared input misses after another checkout's lookup read it":
    # `t-compile` here also reads `tool/cc1.bin`, as every compile reads its
    # compiler. Checkout B has the same bytes and resolves; checkout C, in
    # the same process right after, has other bytes there and must not.
    let shared = TmpDir / "shared-tool"
    proc toolGraph(project: string): seq[BuildAction] =
      result = graphOf(project)
      result[0].inputs.add(project / "tool" / "cc1.bin")
    proc toolCheckout(path, toolBytes: string): string =
      result = newCheckout(path)
      createDir(result / "tool")
      writeFile(result / "tool" / "cc1.bin", toolBytes)
    proc toolBuild(project: string; lookup: bool): BuildRunResult =
      result = runBuild(graph(toolGraph(project), newSeq[BuildPool]()),
        configFor(project, shared, lookup))
      for r in result.results:
        require r.status in {asSucceeded, asCacheHit, asUpToDate}
    let a = toolCheckout("a", "compiler v1\n")
    let first = toolBuild(a, lookup = false)
    require first.resultOf(CompileId).portable
    let b = toolCheckout("b", "compiler v1\n")
    let second = toolBuild(b, lookup = true)
    check second.details(CompileId, "portable-resolved").len == 1
    check not second.resultOf(CompileId).launched
    let c = toolCheckout("c", "compiler v2\n")
    let third = toolBuild(c, lookup = true)
    check third.details(CompileId, "portable-resolved").len == 0
    check third.resultOf(CompileId).launched

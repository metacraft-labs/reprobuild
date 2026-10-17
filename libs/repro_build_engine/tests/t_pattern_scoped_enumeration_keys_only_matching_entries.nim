## A directory scanned for ONE pattern keys an edge on the entries that match
## it, and on nothing else in the directory.
##
## Spec: `Incremental-Invalidation.md` §"Validation Criteria", the paragraph
## on pattern-scoped enumerations. glob(3) keeps only the entries that match
## one component of its pattern, and io-mon reports such a scan with the
## component (`io_mon.globScanPattern`). Nim's compiler searches each module's
## directory for `*.nimble` that way, so before this every entry created in a
## project's root (the first build's own `build/` among them) re-ran every
## Nim compile in it (reprobuild-pm issue 2026-10-17-nimble-glob-keys-nim-
## edges-on-the-full-membership-of-tracked-directories).
##
## WHAT IS GRADED, all through the whole engine (real `runBuild`, real
## records on disk, real revalidation):
##   * unrelated entries added to the scanned directory are a HIT;
##   * a matching entry added, or one removed, is a MISS, including a hidden
##     name, which glob itself skips unless the pattern starts with `.`: the
##     key errs toward a superset of what glob could have matched;
##   * the scoped directory's own deletion is a MISS;
##   * the record names the scoped enumeration and carries its digest, and a
##     reader that does not know the convention sees the directory's full
##     listing (the soundness argument in `pattern_scoped_enumeration.nim`);
##   * NOT VACUOUS: the same scan reported WITHOUT a pattern misses on the
##     same unrelated entry, so the hit above is the scope working and not a
##     directory that never reached the key;
##   * a portable lookup answers a scoped listing of a directory an upstream
##     action PRODUCES from that action's output manifest, filtered as the
##     recorder filtered the disk, so it resolves instead of always missing.
##
## NO MOCKS of the engine, the cache or the filesystem. The one synthetic
## input is the monitor capture, a literal io-mon record stream written with
## io-mon's own `encodeCanonical`: the shape every enumeration test here uses
## (`t_untracked_ancestor_change_does_not_re_run_an_edge.nim`), because this
## file is about what the engine does with a scoped enumeration, not about
## how the monitor reports one (io-mon's
## `tests/linux/test_io_mon_shim_glob_directory_scans.nim` grades that). The
## portable case also stands a copying restorer in for the binary-cache
## transport, as `t_directory_listing_above_outputs_is_the_graph_view` does:
## what is graded is the lookup's identity of the listing, not how outputs
## travel between hosts.

import std/[options, os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core
import repro_local_store
import io_mon/[capabilities, types, writer]

let TmpDir = absolutePath(
  "build/test-tmp/t_pattern_scoped_enumeration-" & testCaseScratchSlug())

const EdgeId = "t-globbing-edge"

proc enumeration(path, detail: string): MonitorRecord =
  MonitorRecord(kind: mrDirectoryEnumerate,
    observationKind: moDirectoryEnumerate,
    osPid: 4242, threadId: 4242, path: path, detail: detail)

proc readRecord(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
    osPid: 4242, threadId: 4242, path: path)

proc writeCapture(path: string; records: seq[MonitorRecord]) =
  let raw = encodeCanonical(profileRecords(defaultHooksMonitorProfile()) &
    records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

type Fixture = object
  root: string
  project: string     ## scanned for `*.nimble`, as Nim's compiler does
  outputs: string

proc newFixture(name: string): Fixture =
  result.root = TmpDir / name
  result.project = result.root / "proj"
  result.outputs = result.root / "outputs"
  createDir(result.project / "src")
  createDir(result.outputs)
  writeFile(result.project / "src" / "main.nim", "echo 1\n")
  writeFile(result.project / "proj.nimble", "# package\n")

proc graphOf(f: Fixture; scoped: bool): seq[BuildAction] =
  let capture = f.root / "edge.rdep"
  # The detail as the Linux shim writes it, including the run token the
  # writer appends to every record.
  let detail =
    if scoped: GlobPatternDetailPrefix & "*.nimble run=17.5-4242-1"
    else: "glob run=17.5-4242-1"
  writeCapture(capture, @[
    readRecord(f.project / "src" / "main.nim"),
    enumeration(f.project, detail)])
  var edge = builtinAction(bakWriteText, EdgeId, cwd = f.project,
    inputs = [f.project / "src" / "main.nim"],
    outputs = [f.outputs / "out.txt"],
    text = "built\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  edge.monitorDepfile = capture
  @[edge]

proc configFor(f: Fixture): BuildEngineConfig =
  result = defaultBuildEngineConfig(f.root / "cache")
  result.maxParallelism = 1
  result.filesystemRoots = declaredFilesystemRoots(f.project, f.root / "work")

proc build(f: Fixture; scoped = true): ActionResult =
  let run = runBuild(graph(f.graphOf(scoped), newSeq[BuildPool]()),
    f.configFor())
  for item in run.results:
    if item.id == EdgeId:
      checkpoint(item.id & ": " & $item.status & " " & $item.cacheDecision &
        " reason=" & item.reason & " miss=" & item.cacheMissReason)
      return item
  raise newException(KeyError, "no result for " & EdgeId)

proc recordOf(f: Fixture): ActionResultRecord =
  let path = dependencyEvidencePath(f.root / "cache", EdgeId)
  require fileExists(path)
  decodeActionResultRecord(cast[seq[byte]](readFile(path)))

proc hits(item: ActionResult): bool =
  item.status == asCacheHit and item.cacheDecision == cdHit and
    not item.launched

proc misses(item: ActionResult): bool =
  item.launched and item.cacheDecision == cdMiss

suite "a pattern-scoped enumeration keys only the entries that match":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "the record names the scoped enumeration and carries its digest":
    let f = newFixture("record")
    require f.build().launched
    let scoped = patternScopedEnumerationPath(f.project, "*.nimble")
    var found = false
    for input in f.recordOf().inputs:
      if input.path == scoped:
        found = true
        check input.metadata.kind == ffkDirectory
        check input.metadata.membershipTrackedDirectory()
        # The digest covers the matching entries: here only `proj.nimble`,
        # so it is not the full listing's (`src/` is there too).
        check input.metadata ==
          fingerprintDirectoryMembership(scoped)
        check input.metadata != fingerprintDirectoryMembership(f.project)
      # The unscoped directory carries no membership of its own.
      if input.path == f.project:
        check not input.metadata.membershipTrackedDirectory()
    check found

  test "unrelated entries in the scanned directory are a HIT":
    let f = newFixture("unrelated")
    require f.build().launched
    check f.build().hits()
    # What a first build, an editor or a user typically leaves beside the
    # sources: none of it can match `*.nimble`.
    createDir(f.project / "build")
    createDir(f.project / "nimcache")
    writeFile(f.project / "unused.nim", "const unused = true\n")
    writeFile(f.project / "proj.nimble.bak", "# not a match\n")
    check f.build().hits()

  test "a matching entry added is a MISS":
    let f = newFixture("added")
    require f.build().launched
    writeFile(f.project / "other.nimble", "# second package\n")
    let second = f.build()
    check second.misses()
    check second.cacheMissReason.contains(f.project)

  test "a matching entry removed is a MISS":
    let f = newFixture("removed")
    require f.build().launched
    removeFile(f.project / "proj.nimble")
    check f.build().misses()

  test "a hidden matching entry is a MISS":
    # glob skips `.hidden.nimble` for `*.nimble`; the key does not, because
    # erring toward more names is the safe direction.
    let f = newFixture("hidden")
    require f.build().launched
    writeFile(f.project / ".hidden.nimble", "")
    check f.build().misses()

  test "the scanned directory's deletion is a MISS":
    let f = newFixture("deleted")
    require f.build().launched
    removeDir(f.project)
    createDir(f.project / "src")
    writeFile(f.project / "src" / "main.nim", "echo 1\n")
    # Recreated without `proj.nimble`: same sources, different match set.
    check f.build().misses()

  test "a reader that ignores the scope keys on the full listing":
    # The name ends the directory at a NUL byte, so code that does not know
    # the convention, an older `repro` among it, reads the directory itself.
    # Its digest is then the FULL listing's: a superset of the scoped key,
    # which can only miss where the scoped key hits.
    let f = newFixture("unaware")
    let scoped = patternScopedEnumerationPath(f.project, "*.nimble")
    var walked = 0'i64
    check directoryMembershipDigest(scoped, walked) ==
      directoryMembershipDigest(f.project, walked)
    check dirExists(scoped)

  test "the same unrelated entry MISSES when the scan carries no pattern":
    # The anti-vacuity case: an unscoped glob is a full enumeration, so the
    # entry the HIT case above ignores re-runs this edge. If the scoped name
    # ever stopped reaching the record, that case would pass for the wrong
    # reason and this one would go red.
    let f = newFixture("unscoped")
    require f.build(scoped = false).launched
    check f.build(scoped = false).hits()
    writeFile(f.project / "unused.nim", "const unused = true\n")
    let third = f.build(scoped = false)
    check third.misses()
    check third.cacheMissReason.contains(f.project)

# The portable tier. A downstream action globs a directory its upstream
# PRODUCES. A portable lookup answers that listing from the upstream's record
# (its output manifest), not from disk, and it must filter the manifest the
# way the recorder filtered the disk, or the scoped listing never resolves.
const
  GenId = "t-gen"
  UseId = "t-use"

proc portableGraphOf(project, capture: string): seq[BuildAction] =
  let gen = project / "gen"
  writeCapture(capture, @[
    readRecord(gen / "a.nimble"),
    enumeration(gen, GlobPatternDetailPrefix & "*.nimble run=17.5-4242-1")])
  var producer = builtinAction(bakWriteText, GenId, cwd = project,
    inputs = [project / "src" / "main.nim"],
    outputs = [gen / "a.nimble"],
    text = "# generated\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  producer.declaredOutputs = @[gen]
  var consumer = builtinAction(bakWriteText, UseId, cwd = project,
    deps = [GenId],
    inputs = [gen / "a.nimble"],
    outputs = [project / "out" / "use.txt"],
    text = "used\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  consumer.monitorDepfile = capture
  @[producer, consumer]

proc portableConfig(root, project, shared: string): BuildEngineConfig =
  result = defaultBuildEngineConfig(root / "cache")
  result.maxParallelism = 1
  result.actionCacheRoot = shared
  result.portableRoots = @[
    LogicalRoot(label: "project", path: project, kind: lrkTracked)]

proc runPortable(root: string; config: BuildEngineConfig): BuildRunResult =
  let project = root / "proj"
  result = runBuild(graph(portableGraphOf(project, root / "use.rdep"),
    newSeq[BuildPool]()), config)
  for r in result.results:
    checkpoint(r.id & ": " & $r.status & " " & r.reason & " " &
      r.portableReason)
    require r.status in {asSucceeded, asCacheHit, asUpToDate}

proc newPortableCheckout(root: string) =
  createDir(root / "proj" / "src")
  writeFile(root / "proj" / "src" / "main.nim", "echo 1\n")

proc copyingRestorer(source: string): PortableMemoRestorer =
  ## Places a record's outputs by copying them from the checkout that
  ## recorded it, the role the binary-cache transport plays across hosts
  ## (the same helper as `t_directory_listing_above_outputs_is_the_graph_view`).
  result = proc (roots: seq[LogicalRoot];
                 record: PortableMemoRecord): string {.gcsafe.} =
    {.cast(gcsafe).}:
      let origin = @[LogicalRoot(label: "project", path: source,
                               kind: lrkTracked)]
      for output in record.outputs:
        let src = toPhysicalPath(origin, output.path)
        let dst = toPhysicalPath(roots, output.path)
        if src.isNone or dst.isNone:
          return "cannot place " & output.path
        if output.directory:
          copyDir(src.get(), dst.get())
        else:
          createDir(dst.get().parentDir)
          copyFile(src.get(), dst.get())
    ""

suite "a scoped listing of a produced directory resolves portably":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "the pre-pass answers it from the producer's manifest":
    let shared = TmpDir / "shared"
    let publisher = TmpDir / "publisher"
    newPortableCheckout(publisher)
    let published = runPortable(publisher,
      portableConfig(publisher, publisher / "proj", shared))
    var recorded = ""
    for r in published.results:
      if r.id == UseId:
        require r.launched
        require r.portable
        recorded = r.portableStrongHex
    let lookup = TmpDir / "lookup"
    newPortableCheckout(lookup)
    var config = portableConfig(lookup, lookup / "proj", shared)
    config.portableLookup = true
    config.portableMemoRestorer = copyingRestorer(publisher / "proj")
    let run = runPortable(lookup, config)
    var resolved, missed = 0
    for item in run.trace:
      if item.actionId == UseId:
        if item.event.startsWith("portable-resolved"): inc resolved
        if item.event.startsWith("portable-miss"): inc missed
    check resolved == 1
    check missed == 0
    for r in run.results:
      if r.id == UseId:
        check not r.launched
        check r.portableStrongHex == recorded

## Cache-Scope P3.4b: a portable record DERIVED from a local cache hit is the
## record the live recorder produces for the same observations.
##
## A local hit does not run the action, so the portable record has to come
## from what was stored when it last ran. The local action record cannot say
## it: it keeps each input's file kind and metadata, not how the action
## accessed it. Classifying by file kind made every probed directory an
## enumeration (outside every logical root that made the whole record
## non-portable: the MSVC `bin\HostX64\x64` directory a warm gemini-cli build
## reported), every probed file a read, every failed read a probe, and kept
## paths the live recorder drops (reads inside the action's own output
## directory, its own transient writes). Each of those gives the same action
## two path sets -- one when it runs, another when it hits -- and the warm path
## published the one the live path never produces.
##
## Every case below runs an action once (the live record), then hits it (the
## derived record) and asserts the two are the same record: same strong
## fingerprint, and nothing published twice.

import std/[os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core/paths
import repro_local_store
import io_mon/[capabilities, types, writer]

let TmpDir = absolutePath("build/test-tmp/t_portable_record_from_local_hit-" &
  testCaseScratchSlug())

proc observed(kind: MonitorRecordKind; observation: MonitorObservationKind;
              path: string): MonitorRecord =
  MonitorRecord(kind: kind, observationKind: observation,
    osPid: 4242, threadId: 4242, path: path, detail: "")

proc fileRead(path: string): MonitorRecord =
  observed(mrFileRead, moFileRead, path)

proc pathProbe(path: string): MonitorRecord =
  observed(mrPathProbe, moPathProbe, path)

proc dirEnumerate(path: string): MonitorRecord =
  observed(mrDirectoryEnumerate, moDirectoryEnumerate, path)

proc fileWrite(path: string): MonitorRecord =
  observed(mrFileWrite, moFileWrite, path)

proc writeCapture(path: string; records: varargs[MonitorRecord]) =
  ## The shape io-mon really writes: the backend profile and its capability
  ## gaps first, then the observations (as
  ## test_s5_own_output_is_not_a_cache_input writes them).
  let raw = encodeCanonical(profileRecords(defaultHooksMonitorProfile()) &
    @records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

type Built = object
  result: ActionResult
  published: seq[PortableMemoRecord]

proc build(project, cacheRoot, capture: string;
           declaredOutputs: seq[string] = @[]): Built =
  ## One build of a builtin whose monitor capture is `capture`. Every case
  ## runs this twice on one cache root: the first run records the live
  ## portable record, the second is a local hit and derives one.
  var action = builtinAction(bakWriteText, "t-local-hit-derivation",
    cwd = project,
    inputs = [project / "src" / "main.c"],
    outputs = [project / "out" / "result.txt"],
    cacheable = true,
    text = "built\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  action.declaredOutputs = declaredOutputs
  action.monitorDepfile = capture
  var config = defaultBuildEngineConfig(cacheRoot)
  config.maxParallelism = 1
  config.portableRoots = @[
    LogicalRoot(label: "project", path: project, kind: lrkTracked)]
  var published: ref seq[PortableMemoRecord]
  new(published)
  config.portableMemoPublisher = proc (roots: seq[LogicalRoot];
      record: PortableMemoRecord; withOutputs: bool): string {.gcsafe.} =
    {.cast(gcsafe).}:
      published[].add(record)
    ""
  let run = runBuild(graph(@[action], newSeq[BuildPool]()), config)
  require run.results.len == 1
  checkpoint(run.results[0].reason)
  require run.results[0].status in {asSucceeded, asCacheHit, asUpToDate}
  result.result = run.results[0]
  result.published = published[]

proc newProject(name: string): string =
  result = TmpDir / name / "proj"
  createDir(result / "src")
  createDir(result / "out")
  writeFile(result / "src" / "main.c", "int main;\n")

proc accessSidecars(cacheRoot: string): seq[string] =
  for path in walkDirRec(cacheRoot):
    if path.endsWith(InputAccessFileExt):
      result.add(path)

suite "P3.4b: a portable record derived from a local hit is the live one":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "a directory PROBED outside every root stays a probe":
    # The observed defect: a tool resolving itself probes a directory beside
    # the checkout (the MSVC bin directory on the measured host). The live
    # recorder keys that probe relative to the root's ancestry; a derivation
    # that made it an enumeration found it outside every root and gave up.
    let project = newProject("outside")
    let toolDir = TmpDir / "outside" / "msvc-bin"
    createDir(toolDir)
    writeFile(toolDir / "cl.exe", "compiler bytes")
    let capture = TmpDir / "outside" / "capture.rdep"
    writeCapture(capture,
      fileRead(project / "src" / "main.c"),
      pathProbe(toolDir))
    let cacheRoot = TmpDir / "outside" / "cache"
    let live = build(project, cacheRoot, capture)
    checkpoint(live.result.portableReason)
    require live.result.launched
    require live.result.portable
    let warm = build(project, cacheRoot, capture)
    checkpoint(warm.result.portableReason)
    check not warm.result.launched
    check warm.result.portable
    check warm.result.portableWeakHex == live.result.portableWeakHex
    check warm.result.portableStrongHex == live.result.portableStrongHex
    check warm.published.len == 0

  test "every in-root access keeps the kind the action observed":
    let project = newProject("inside")
    createDir(project / "include")                 # probed only
    createDir(project / "lib")                     # enumerated
    writeFile(project / "lib" / "a.lib", "a")
    writeFile(project / "src" / "config.h", "#define X 1\n")   # probed only
    createDir(project / "prefix" / "bin")          # the declared output dir
    writeFile(project / "prefix" / "bin" / "tool", "tool bytes")
    let transient = project / "out" / "result.txt.DELETE.1234"
    let capture = TmpDir / "inside" / "capture.rdep"
    writeCapture(capture,
      fileRead(project / "src" / "main.c"),
      pathProbe(project / "include"),
      dirEnumerate(project / "lib"),
      pathProbe(project / "src" / "config.h"),
      # A failed open: node's module resolution makes these by the hundred.
      fileRead(project / "src" / "missing.h"),
      # Inside the action's own declared output directory.
      fileRead(project / "prefix" / "bin" / "tool"),
      # Written, probed and gone by the time the action finished.
      fileWrite(transient),
      pathProbe(transient))
    let cacheRoot = TmpDir / "inside" / "cache"
    let live = build(project, cacheRoot, capture,
      declaredOutputs = @[project / "prefix"])
    checkpoint(live.result.portableReason)
    require live.result.launched
    require live.result.portable
    require live.published.len == 1
    let warm = build(project, cacheRoot, capture,
      declaredOutputs = @[project / "prefix"])
    checkpoint(warm.result.portableReason)
    check not warm.result.launched
    check warm.result.portable
    check warm.result.portableStrongHex == live.result.portableStrongHex
    # The warm run republishes nothing: its record IS the live one.
    check warm.published.len == 0

  test "an enumerated directory whose membership changed misses":
    # The derivation must not be looser than what was observed: an
    # enumeration stays an enumeration, so a new entry is a miss locally
    # (and would be one portably).
    let project = newProject("membership")
    createDir(project / "lib")
    writeFile(project / "lib" / "a.lib", "a")
    let capture = TmpDir / "membership" / "capture.rdep"
    writeCapture(capture,
      fileRead(project / "src" / "main.c"),
      dirEnumerate(project / "lib"))
    let cacheRoot = TmpDir / "membership" / "cache"
    let live = build(project, cacheRoot, capture)
    require live.result.portable
    writeFile(project / "lib" / "b.lib", "b")
    let after = build(project, cacheRoot, capture)
    check after.result.launched
    check after.result.portable
    check after.result.portableStrongHex != live.result.portableStrongHex

  test "a hit on a record without its access record derives nothing":
    # A record written before access kinds were kept (or whose sidecar was
    # lost) cannot say how its inputs were accessed. Guessing from file kinds
    # is what produced records the live path never does, so the hit leaves
    # the portable record to the next run of the action.
    let project = newProject("no-sidecar")
    createDir(project / "include")
    let capture = TmpDir / "no-sidecar" / "capture.rdep"
    writeCapture(capture,
      fileRead(project / "src" / "main.c"),
      pathProbe(project / "include"))
    let cacheRoot = TmpDir / "no-sidecar" / "cache"
    let live = build(project, cacheRoot, capture)
    require live.result.portable
    let sidecars = accessSidecars(cacheRoot)
    require sidecars.len == 1
    # Extended-length: the edge directory is deeper than MAX_PATH here, and
    # a plain `removeFile` of a path it cannot reach reports nothing.
    removeFile(extendedPath(sidecars[0]))
    require not fileExists(extendedPath(sidecars[0]))
    let warm = build(project, cacheRoot, capture)
    check not warm.result.launched
    check not warm.result.portable
    check warm.result.portableStrongHex == ""
    check "access" in warm.result.portableReason
    check warm.published.len == 0

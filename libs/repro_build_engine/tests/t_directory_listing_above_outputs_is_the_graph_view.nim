## A directory that holds build-graph outputs is identified by the graph,
## not by whichever outputs happen to be on disk (reprobuild-specs issue
## 2026-10-10 "directory listings above graph outputs are recorded with other
## actions' outputs").
##
## gemini-cli's bundle step enumerates `.repro/build/node`, which holds its
## own `dist/` and, once the downstream install step has run, that step's
## `out/`. Keyed by the on-disk listing, the record made where the install
## had run named an entry a fresh host can never reproduce (so cross-host
## lookup always missed), and the determinism probe's key moved between a
## cold first run and every later run (three runs to verify, not two).
##
## The rule the recorder, the determinism probe and the pre-pass resolver now
## share: such a directory lists what no graph action declares as it is on
## disk, plus what the action's ANCESTORS produce -- never its own outputs nor
## a downstream or unrelated action's. A directory holding no declared path
## keeps its plain on-disk listing.
##
## The graph below is that shape: `t-vendor` (an ancestor) writes
## `build/up/vendor.txt`; `t-bundle` writes `build/node/dist/` and enumerates
## `build/node`, `build` and the project root; `t-install` (downstream) writes
## `build/node/out/`.

import std/[options, os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core
import repro_local_store
import io_mon/[capabilities, types, writer]

let TmpDir = absolutePath(
  "build/test-tmp/t_directory_listing_above_outputs_is_the_graph_view-" &
  testCaseScratchSlug())

proc observed(kind: MonitorRecordKind; observation: MonitorObservationKind;
              path: string; detail = ""): MonitorRecord =
  MonitorRecord(kind: kind, observationKind: observation,
    osPid: 4242, threadId: 4242, path: path, detail: detail)

proc writeCapture(path: string; records: seq[MonitorRecord]) =
  let raw = encodeCanonical(profileRecords(defaultHooksMonitorProfile()) &
    records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

const
  VendorId = "t-vendor"
  BundleId = "t-bundle"
  InstallId = "t-install"

type Checkout = object
  root: string      ## holds the project, its capture and its caches
  project: string

proc newCheckout(name: string): Checkout =
  result.root = TmpDir / name
  result.project = result.root / "proj"
  createDir(result.project / "src")
  createDir(result.project / "lib")
  writeFile(result.project / "src" / "main.c", "int main;\n")
  writeFile(result.project / "lib" / "a.lib", "a")

proc leaveInstallOutput(c: Checkout) =
  ## What a checkout where the downstream install step has run holds: its
  ## output, beside the bundle step's.
  createDir(c.project / "build" / "node" / "out")
  writeFile(c.project / "build" / "node" / "out" / "installed.txt",
    "installed\n")

proc graphOf(c: Checkout; entropy = false;
             coldOnly: seq[string] = @[]): seq[BuildAction] =
  let p = c.project
  let capture = c.root / "bundle.rdep"
  var records = @[
    observed(mrFileRead, moFileRead, p / "src" / "main.c"),
    observed(mrFileRead, moFileRead, p / "build" / "up" / "vendor.txt"),
    observed(mrDirectoryEnumerate, moDirectoryEnumerate, p / "build" / "node"),
    observed(mrDirectoryEnumerate, moDirectoryEnumerate, p / "build"),
    observed(mrDirectoryEnumerate, moDirectoryEnumerate, p),
    observed(mrDirectoryEnumerate, moDirectoryEnumerate, p / "lib"),
    observed(mrPathProbe, moPathProbe, p / "build" / "node")]
  for path in coldOnly:
    records.add(observed(mrPathProbe, moPathProbe, path))
  if entropy:
    records.add(observed(mrNonDeterministic, moNonDeterministic,
      "BCryptGenRandom", "entropy source=BCryptGenRandom caller=program"))
  writeCapture(capture, records)
  let vendor = builtinAction(bakWriteText, VendorId, cwd = p,
    inputs = [p / "src" / "main.c"],
    outputs = [p / "build" / "up" / "vendor.txt"],
    text = "vendored\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  var bundle = builtinAction(bakWriteText, BundleId, cwd = p,
    deps = [VendorId],
    inputs = [p / "src" / "main.c"],
    outputs = [p / "build" / "node" / "dist" / "bundle.txt"],
    text = "bundle\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  bundle.declaredOutputs = @[p / "build" / "node" / "dist"]
  bundle.monitorDepfile = capture
  if entropy:
    bundle.nonDeterminism = ndpUnblessed
  var install = builtinAction(bakWriteText, InstallId, cwd = p,
    deps = [BundleId],
    inputs = [p / "build" / "node" / "dist" / "bundle.txt"],
    outputs = [p / "build" / "node" / "out" / "installed.txt"],
    text = "installed\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  install.declaredOutputs = @[p / "build" / "node" / "out"]
  @[vendor, bundle, install]

proc configFor(c: Checkout; sharedRoot = ""): BuildEngineConfig =
  result = defaultBuildEngineConfig(c.root / "cache")
  result.maxParallelism = 1
  result.actionCacheRoot =
    if sharedRoot.len > 0: sharedRoot else: c.root / "shared"
  result.portableRoots = @[
    LogicalRoot(label: "project", path: c.project, kind: lrkTracked)]

proc resultOf(run: BuildRunResult; id: string): ActionResult =
  for r in run.results:
    if r.id == id:
      return r
  raise newException(KeyError, "no result for " & id)

proc events(run: BuildRunResult; id, prefix: string): seq[string] =
  for item in run.trace:
    if item.actionId == id and item.event.startsWith(prefix):
      result.add(item.event)

proc build(c: Checkout; config: BuildEngineConfig; entropy = false;
           coldOnly: seq[string] = @[]): BuildRunResult =
  result = runBuild(graph(c.graphOf(entropy, coldOnly), newSeq[BuildPool]()),
    config)
  for r in result.results:
    checkpoint(r.id & ": " & $r.status & " " & r.reason & " " &
      r.portableReason)
    require r.status in {asSucceeded, asCacheHit, asUpToDate}

proc bundleStrong(c: Checkout): string =
  let r = c.build(c.configFor()).resultOf(BundleId)
  require r.launched
  require r.portable
  r.portableStrongHex

proc copyingRestorer(source: string): PortableMemoRestorer =
  ## Places a record's outputs by copying them from the checkout that
  ## recorded it (the role the binary-cache transport plays across hosts).
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

suite "a directory above graph outputs is identified by the graph":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "a downstream output on disk does not change the record":
    # Cold: the install step has never run here. Warm: it has, and its
    # `out/` sits in the directory the bundle step lists.
    let cold = newCheckout("cold")
    let warm = newCheckout("somewhere/deeper/warm")
    warm.leaveInstallOutput()
    check cold.bundleStrong() == warm.bundleStrong()

  test "an undeclared entry in that directory still moves the record":
    # Not looser than observed: what no graph action declares is keyed as
    # it is on disk, beside the outputs.
    let plain = newCheckout("plain")
    let stray = newCheckout("stray")
    createDir(stray.project / "build" / "node")
    writeFile(stray.project / "build" / "node" / "notes.txt", "left here")
    check plain.bundleStrong() != stray.bundleStrong()

  test "a directory holding no graph output keeps its on-disk listing":
    let plain = newCheckout("plain-lib")
    let more = newCheckout("more-lib")
    writeFile(more.project / "lib" / "b.lib", "b")
    check plain.bundleStrong() != more.bundleStrong()

  test "the pre-pass resolves a warm record from a cold checkout":
    let shared = TmpDir / "shared-warm-first"
    let warm = newCheckout("publisher-warm")
    warm.leaveInstallOutput()
    let published = warm.build(warm.configFor(shared))
    require published.resultOf(BundleId).portable
    let cold = newCheckout("lookup-cold")
    var config = cold.configFor(shared)
    config.portableLookup = true
    config.portableMemoRestorer = copyingRestorer(warm.project)
    let run = cold.build(config)
    check run.events(BundleId, "portable-resolved").len == 1
    check run.events(BundleId, "portable-miss").len == 0
    check not run.resultOf(BundleId).launched
    check run.resultOf(BundleId).portableStrongHex ==
      published.resultOf(BundleId).portableStrongHex

  test "the pre-pass resolves a cold record from a warm checkout":
    let shared = TmpDir / "shared-cold-first"
    let cold = newCheckout("publisher-cold")
    let published = cold.build(cold.configFor(shared))
    require published.resultOf(BundleId).portable
    let warm = newCheckout("lookup-warm")
    warm.leaveInstallOutput()
    var config = warm.configFor(shared)
    config.portableLookup = true
    config.portableMemoRestorer = copyingRestorer(cold.project)
    let run = warm.build(config)
    check run.events(BundleId, "portable-resolved").len == 1
    check run.events(BundleId, "portable-miss").len == 0
    check not run.resultOf(BundleId).launched

  test "the determinism probe verifies on the second run":
    # Run 1 is cold: the bundle step lists `build/node` before the install
    # step has ever written `out/` there. Run 2 lists it after. Both must
    # key the probe alike, or it records a second candidate.
    let c = newCheckout("probe")
    let config = c.configFor()
    # On Windows the cold run also probes `dist.exe`: MSYS `rm -rf dist`
    # tries the `.exe` and `.lnk` spellings of a path that is missing, and
    # the bundle step's own `dist` is missing only on a cold run.
    var coldOnly: seq[string] = @[]
    when defined(windows):
      coldOnly.add(c.project / "build" / "node" / "dist.exe")
    let first = c.build(config, entropy = true, coldOnly = coldOnly)
    check first.events(BundleId, "determinism-probe-") ==
      @["determinism-probe-candidate"]
    require fileExists(c.project / "build" / "node" / "out" / "installed.txt")
    removeFile(c.project / "build" / "node" / "dist" / "bundle.txt")
    let second = c.build(config, entropy = true)
    check second.resultOf(BundleId).launched
    check second.events(BundleId, "determinism-probe-") ==
      @["determinism-probe-verified"]

  test "an action's output parents exist before it runs":
    # The graph view lists the parents of the action's own outputs as
    # present; the engine makes that true on every host, so a tool never
    # observes them missing on a cold run only (MSYS `mkdir -p` probes
    # `<dir>.lnk` while `<dir>` is absent).
    let c = newCheckout("parents")
    let action = c.graphOf()[1]
    let parent = c.project / "build" / "node"
    require not dirExists(parent)
    action.ensureOutputParents()
    check dirExists(parent)
    # The outputs themselves are the action's to create.
    check not dirExists(parent / "dist")

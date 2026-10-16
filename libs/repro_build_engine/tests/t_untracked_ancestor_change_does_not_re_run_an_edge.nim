## A change ABOVE the outermost tracked root does not re-run an edge; a change
## INSIDE one still does.
##
## Spec: `Incremental-Invalidation.md` §"Validation Criteria", the second
## mandatory exemption. `t_untracked_scope_membership_is_not_an_input.nim`
## pins the fold that decides it; this file drives the whole engine — real
## `runBuild`, real action-cache records on disk, real revalidation — and
## reads the answer off the RECORD as well as off the decision.
##
## WHY BOTH. The fold could be right and the mechanism still dead: the
## enumerated set has to reach `recordActionResult`, the record has to be
## written with `mtimeNs = 0` for the exempt entries, and
## `fingerprintRecordedMetadata` has to stop re-listing them. Each of those
## is a separate hand-off and only a build exercises all three.
##
## WHICH ARM ANSWERED, stated rather than hoped for. `asCacheHit` is produced
## at exactly one place in the engine — the scheduler's per-edge
## `completeSuccess(id, asCacheHit, cdHit, ...)`. The whole-graph fast-noop
## prefix never produces it: it reports `asUpToDate` with reason
## `outputs-present` / `no-declared-outputs` (see `fastNoopReuseReason`, whose
## comment records that it used to report `asCacheHit` and that this was
## wrong). The prefix is additionally unreachable here, because it bails out
## unless `rebuildMissingOutputsOnCacheHit` is set and
## `defaultBuildEngineConfig` leaves it false. So a hit asserted below is the
## per-edge action cache answering, not the graph being declared up to date.
##
## NOT VACUOUS, which for this property needs its own case rather than an
## argument. A test that mutates a directory and observes a hit cannot tell
## "the exemption worked" from "that directory was never in the key at all".
## The last case therefore runs the SAME mutation with no classification
## declared and requires a MISS. If the ancestor enumeration ever stops
## reaching the record, that case goes red and says so.
##
## NO MOCKS of the engine, the cache or the filesystem. The one synthetic
## input is the monitor capture: a literal io-mon record stream, written with
## io-mon's own `encodeCanonical` and consumed by the engine's real depfile
## reader. That is the established shape for an enumeration test here
## (`t_directory_listing_above_outputs_is_the_graph_view.nim`) and the reason
## is the same — a real monitored child cannot be made to enumerate `/` on
## demand, and this file is about what the engine does with an enumeration,
## not about how the monitor reports one.

import std/[os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core
import repro_local_store
import io_mon/[capabilities, types, writer]

let TmpDir = absolutePath(
  "build/test-tmp/t_untracked_ancestor_change-" & testCaseScratchSlug())

const EdgeId = "t-enumerating-edge"

proc observed(path: string): MonitorRecord =
  MonitorRecord(kind: mrDirectoryEnumerate,
    observationKind: moDirectoryEnumerate,
    osPid: 4242, threadId: 4242, path: path)

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
  root: string        ## the ancestor ABOVE every declared root
  project: string
  work: string
  store: string
  outputs: string
  outside: string
  home: string        ## an exempt ancestor with a tracked root beneath it

proc newFixture(name: string): Fixture =
  result.root = TmpDir / name
  result.project = result.root / "proj"
  result.work = result.root / "work"
  result.home = result.root / "home"
  # The shape of the measured host: the store root is a per-user cache path,
  # so it is a tracked root with two exempt ancestors above it.
  result.store = result.home / ".cache" / "repro" / "store"
  result.outputs = result.root / "outputs"
  result.outside = result.root / "outside"
  createDir(result.project / "src")
  createDir(result.project / "lib")
  createDir(result.work / "nimcache")
  createDir(result.store / "prefixes")
  createDir(result.outputs)
  createDir(result.outside)
  createDir(result.home / ".cache")
  writeFile(result.project / "src" / "main.c", "int main;\n")
  writeFile(result.project / "lib" / "a.lib", "a")

proc enumerationsOf(f: Fixture): seq[string] = @[
  # Above the outermost tracked root: what an upward search walks through.
  f.root,
  f.home,
  f.home / ".cache",
  # Under no declared root, and not an ancestor of one.
  f.outside,
  # Inside the declared roots.
  f.project,
  f.project / "lib",
  f.work / "nimcache",
  # A tracked root under two exempt ancestors, and a directory inside it.
  f.store,
  f.store / "prefixes",
]

proc graphOf(f: Fixture): seq[BuildAction] =
  let capture = f.root / "edge.rdep"
  var records = @[readRecord(f.project / "src" / "main.c")]
  for dir in f.enumerationsOf():
    records.add(observed(dir))
  writeCapture(capture, records)
  # The output deliberately lives in NEITHER an enumerated directory nor the
  # project: the self-written derivation elides the directory a declared
  # output sits in (`enumerationIgnoredRoots`), and an enumeration elided for
  # that reason would make every case here pass for the wrong one.
  var edge = builtinAction(bakWriteText, EdgeId, cwd = f.project,
    inputs = [f.project / "src" / "main.c"],
    outputs = [f.outputs / "out.txt"],
    text = "built\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  edge.monitorDepfile = capture
  @[edge]

proc configFor(f: Fixture; declareRoots = true): BuildEngineConfig =
  result = defaultBuildEngineConfig(f.root / "cache")
  result.maxParallelism = 1
  if declareRoots:
    result.filesystemRoots = declaredFilesystemRoots(f.project, f.work,
      f.store)

proc runOf(f: Fixture; config: BuildEngineConfig): BuildRunResult =
  runBuild(graph(f.graphOf(), newSeq[BuildPool]()), config)

proc counterOf(run: BuildRunResult; name: string): int =
  ## The count a stats COUNTER row carries, or `-1` when the row is absent.
  ## Absent and zero are different claims: `addCounterMetric` emits nothing
  ## for a count of zero, and this mechanism deliberately emits nothing when
  ## it exempted nothing.
  for metric in run.stats.metrics:
    if metric.name == name:
      return metric.count
  -1

proc build(f: Fixture; config: BuildEngineConfig): ActionResult =
  let run = f.runOf(config)
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

proc membershipOf(record: ActionResultRecord; dir: string): int =
  ## `1` when `dir` is recorded as a directory carrying a membership digest,
  ## `0` when it is recorded without one, `-1` when it is not recorded at all.
  ##
  ## The three answers are kept apart because two of them are easy to
  ## confuse and the confusion is the whole hazard: `membershipTrackedDirectory`
  ## is false BOTH for an exempt enumeration and for a directory that was only
  ## probed — `fingerprintMetadata` forces `mtimeNs` to 0 for every directory
  ## — and it is also false for a path the record never mentions. A test that
  ## read "no digest" as "exempt" would pass on a record that had simply
  ## dropped the path.
  let wanted = dir.replace('\\', '/')
  for input in record.inputs:
    if input.path.replace('\\', '/') != wanted:
      continue
    if input.metadata.kind != ffkDirectory:
      return -1
    return (if input.metadata.membershipTrackedDirectory(): 1 else: 0)
  -1

suite "a change above the outermost tracked root does not re-run an edge":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "the record carries membership for the declared roots and not above":
    # Read off the RECORD, which is stronger than any timing: the exempt
    # entries are present (so deletion is still detected) and carry no
    # digest, while the tracked ones carry a live one.
    let f = newFixture("record")
    let first = f.build(f.configFor())
    require first.launched
    let record = f.recordOf()

    check record.membershipOf(f.root) == 0
    check record.membershipOf(f.home) == 0
    check record.membershipOf(f.home / ".cache") == 0
    check record.membershipOf(f.outside) == 0
    check record.membershipOf(f.project) == 1
    check record.membershipOf(f.project / "lib") == 1
    check record.membershipOf(f.work / "nimcache") == 1
    # "The individual package directories INSIDE the store stay tracked",
    # under two ancestors this same record shows exempt.
    check record.membershipOf(f.store) == 1
    check record.membershipOf(f.store / "prefixes") == 1

  test "without a classification every one of them carries membership":
    # The same record, from the same capture, with no roots declared. This
    # is what makes the case above a measurement rather than a tautology:
    # every path it calls exempt is one this engine otherwise keys on.
    let f = newFixture("record-undeclared")
    require f.build(f.configFor(declareRoots = false)).launched
    let record = f.recordOf()
    for dir in f.enumerationsOf():
      check record.membershipOf(dir) == 1

  test "an ancestor's membership moving is a HIT on the per-edge arm":
    let f = newFixture("hit")
    let config = f.configFor()
    require f.build(config).launched

    # Exactly the churn the issue measured: another process adds an entry to
    # a directory above the build. Three of them, including the filesystem
    # root's stand-in.
    writeFile(f.root / "someone-elses-file.txt", "unrelated\n")
    createDir(f.home / "Downloads")
    writeFile(f.outside / "stray.txt", "stray\n")

    let second = f.build(config)
    check second.status == asCacheHit
    check second.cacheDecision == cdHit
    check not second.launched

  test "the same mutation MISSES when no classification is declared":
    # The anti-vacuity case. If the ancestor enumerations ever stop reaching
    # the record, the case above would pass for the wrong reason and this one
    # goes red.
    let f = newFixture("hit-undeclared")
    let config = f.configFor(declareRoots = false)
    require f.build(config).launched

    writeFile(f.root / "someone-elses-file.txt", "unrelated\n")

    let second = f.build(config)
    check second.launched
    check second.cacheDecision == cdMiss
    # The ancestor is NAMED, not merely "something changed": that is what
    # distinguishes "the exemption worked" from "that directory was never in
    # the key", which is the only thing this case is here to tell apart.
    check second.cacheMissReason.contains("input changed: " & f.root & " ")

  test "a change INSIDE a tracked root still re-runs the edge":
    # The other direction, which is the one that must never regress: the
    # exemption may not be allowed to grow into the declared roots.
    let f = newFixture("miss")
    let config = f.configFor()
    require f.build(config).launched
    check f.build(config).status == asCacheHit

    writeFile(f.project / "lib" / "b.lib", "b")

    let third = f.build(config)
    check third.launched
    check third.cacheDecision == cdMiss
    check third.cacheMissReason.contains(f.project / "lib")

  test "the build REPORTS how many enumerations the exemption dropped":
    # The mechanism has to be readable off a build and not only off a record,
    # because a record cannot distinguish an exempt enumeration from a
    # probe-only directory (`membershipTrackedDirectory` is false for both).
    # This row is the count that was dropped on the way to the record.
    #
    # It is also the literal that proves a BINARY carries this change: it is
    # emitted from nowhere else.
    let f = newFixture("stats")
    var config = f.configFor()
    config.statsEnabled = true
    let run = f.runOf(config)
    let dropped = run.counterOf("repro enumeration membership exempt")
    checkpoint("dropped=" & $dropped)
    # `f.root`, `f.home`, `f.home/.cache` and `f.outside` — the four the
    # first case reads back as `membership=0`.
    check dropped == 4

    # And it reports NOTHING when it exempted nothing, so a row that is
    # present is a measurement rather than a zero.
    let g = newFixture("stats-undeclared")
    var plain = g.configFor(declareRoots = false)
    plain.statsEnabled = true
    check g.runOf(plain).counterOf("repro enumeration membership exempt") == -1

  test "a tracked root spelled through a symlink still tracks what is under it":
    # THE FAIL-OPEN SPELLING CLIFF, closed rather than documented. A declared
    # root's spelling and the spelling the kernel reports are routinely not
    # the same string — `ignoredInputRoots` and `declaredWriteRootPrefixes`
    # both emit BOTH spellings for exactly this reason — and here the
    # mismatch points the dangerous way: a root that matches nothing
    # classifies the entire tree it was declared to track as untracked, so
    # the project's own source directories lose their membership digests.
    # That is a false hit INSIDE the declared roots, which is strictly worse
    # than the miss the exemption exists to fix.
    #
    # Live on macOS without any symlink of the test's own: `$TMPDIR` is
    # `/var/folders/...` while every enumeration under it is reported as
    # `/private/var/folders/...`, and `/tmp` / `/private/tmp` are the same
    # pair. THE SYMLINK HERE IS THE TEST'S OWN, deliberately, so the case is
    # live on every platform that has symlinks rather than only on the host
    # whose layout happens to supply one — the shape a reviewer caught in
    # this campaign was a pin that was live on macOS and vacuous on Linux.
    when not defined(windows):
      let f = newFixture("symlinked-root")
      createSymlink("proj", f.root / "proj-alias")
      var config = f.configFor(declareRoots = false)
      config.filesystemRoots = declaredFilesystemRoots(
        f.root / "proj-alias", f.work, f.store)
      require f.build(config).launched
      let record = f.recordOf()
      # The project tree, reached through the alias, keeps its digests.
      check record.membershipOf(f.project) == 1
      check record.membershipOf(f.project / "lib") == 1
      # …and the ancestor above every declared root is still exempt, so this
      # passes because the spelling was resolved and not because the
      # classification stopped exempting anything.
      check record.membershipOf(f.root) == 0
      check record.membershipOf(f.outside) == 0

  test "a tracked root nested under exempt ancestors still re-runs the edge":
    # The store-root shape end to end: `$HOME` and `$HOME/.cache` are exempt,
    # and the store beneath them is not.
    let f = newFixture("nested")
    let config = f.configFor()
    require f.build(config).launched
    check f.build(config).status == asCacheHit

    writeFile(f.store / "newly-published", "x")

    let third = f.build(config)
    check third.launched
    check third.cacheDecision == cdMiss
    check third.cacheMissReason.contains(f.store)

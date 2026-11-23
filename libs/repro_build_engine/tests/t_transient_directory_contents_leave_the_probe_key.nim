## A directory the action made and removed takes everything it observed
## beneath it out of the determinism-probe key and the portable record.
##
## rustc links a binary through a randomly named temporary directory,
## `out/rustcXXXXXX/`, and passes `-L <tmp>/raw-dylibs` to the linker. The
## linker probes that directory for every `-l` library, finds nothing, and
## rustc removes the directory when the link finishes. `transientOwnWrites`
## held only the directory itself (the path the action WROTE), so the
## sixteen missing-file probes beneath it stayed in the key. Their random
## parent differed on every run, no two runs shared a key, and a Rust link
## edge with byte-identical inputs and outputs was never admitted.
##
## The decision for a path beneath such a directory covers every kind of
## access, not only misses and listings. Once the directory is gone nothing
## beneath it exists, so a read of a file there would be keyed `absent`
## whatever it held: keeping the entry adds the temporary's random name and
## no content. Content the action brought in from elsewhere is keyed where
## the monitor saw it read, which is not beneath the temporary.
##
## What must NOT happen is that such a directory hides a real input:
## a sibling whose name merely starts with the directory's name, the
## contents of a written directory that still exists, the contents of a
## directory the action only REMOVED (removing is no evidence of having
## made it), a file the action removed from beneath a temporary without
## having written it (it was there before the action ran), and a path that
## walks back out of the temporary through `..` all stay in the key.
##
## Mocks: none. The capture is the record shapes io-mon emits, read by the
## engine's own fold; the action runs through `runBuild`, and the temporary
## directory is absent from disk, as it is once rustc has removed it.

import std/[options, os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core
import repro_local_store
import io_mon/[capabilities, types, writer]

let TmpDir = absolutePath(
  "build/test-tmp/t_transient_directory_contents_leave_the_probe_key-" &
  testCaseScratchSlug())

const LinkId = "t-rust-link"

const LinkerProbes = ["libc.a", "libc.so", "libdl.a", "libdl.so",
  "libgcc.a", "libgcc.so", "libgcc_s.a", "libgcc_s.so", "libm.a",
  "libm.so", "libpthread.a", "libpthread.so", "librt.a", "librt.so",
  "libutil.a", "libutil.so"]

proc observed(kind: MonitorRecordKind; observation: MonitorObservationKind;
              path: string; detail = ""): MonitorRecord =
  MonitorRecord(kind: kind, observationKind: observation,
    osPid: 4242, threadId: 4242, path: path, detail: detail)

proc mutation(path, detail: string): MonitorRecord =
  observed(mrPathMutation, moPathMutation, path, detail & " run=1-4242-1")

proc fold(records: openArray[MonitorRecord]; cwd: string): PathSetEvidence =
  var seen: EvidenceSeenSets
  discard foldMonitorRecordsEvidence(records, cwd, result, seen)

proc writeCapture(path: string; records: seq[MonitorRecord]) =
  let raw = encodeCanonical(profileRecords(defaultHooksMonitorProfile()) &
    records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

proc rustTemporaryRecords(temporary: string): seq[MonitorRecord] =
  ## What rustc and its linker leave in the capture for one link: the
  ## directory made, its `raw-dylibs` subdirectory listed and probed for
  ## every library on the link line, then both removed.
  let rawDylibs = temporary / "raw-dylibs"
  result = @[
    mutation(temporary, "mkdir"),
    mutation(rawDylibs, "mkdir"),
    observed(mrDirectoryEnumerate, moDirectoryEnumerate, rawDylibs)]
  for name in LinkerProbes:
    result.add(observed(mrPathProbe, moPathProbe, rawDylibs / name))
  result.add(mutation(rawDylibs, "rmdir"))
  result.add(mutation(temporary, "rmdir"))

proc linkGraph(root, project, tempSuffix: string;
               extra: seq[MonitorRecord] = @[]): BuildGraph =
  ## One link edge that read entropy (so only the determinism probe can
  ## admit it) and went through the temporary directory
  ## `out/rustc<tempSuffix>`, which is gone when the action finishes.
  let capture = root / "link.rdep"
  let temporary = project / "out" / ("rustc" & tempSuffix)
  var records = @[
    observed(mrFileRead, moFileRead, project / "src" / "main.rs")]
  records.add(rustTemporaryRecords(temporary))
  records.add(extra)
  records.add(observed(mrNonDeterministic, moNonDeterministic,
    "getrandom", "entropy source=getrandom caller=program"))
  writeCapture(capture, records)
  var link = builtinAction(bakWriteText, LinkId, cwd = project,
    inputs = [project / "src" / "main.rs"],
    outputs = [project / "out" / "hello"],
    text = "image\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  link.monitorDepfile = capture
  link.nonDeterminism = ndpUnblessed
  graph(@[link], newSeq[BuildPool]())

proc freshRoot(name: string): string =
  ## A scratch root with nothing left in it by an earlier run: a candidate
  ## an earlier run recorded would decide this run's probe.
  result = TmpDir / name
  removeDir(result)
  createDir(result)

proc freshProject(root: string): string =
  result = root / "proj"
  createDir(result / "src")
  createDir(result / "out")
  writeFile(result / "src" / "main.rs", "fn main() {}\n")

proc configFor(root: string): BuildEngineConfig =
  result = defaultBuildEngineConfig(root / "cache")
  result.maxParallelism = 1
  result.actionCacheRoot = root / "shared"

proc accessSidecars(root: string): seq[InputAccesses] =
  ## The input accesses stored beside each published record, decoded: what
  ## the portable record of that action is derived from.
  for path in walkDirRec(root):
    if path.endsWith(InputAccessFileExt):
      let raw = readFile(path)
      let decoded = decodeInputAccesses(raw.toOpenArrayByte(0, raw.high),
        path.extractFilename[0 ..< ^InputAccessFileExt.len])
      require decoded.isSome
      result.add(decoded.get)

proc probeEvents(run: BuildRunResult): seq[string] =
  for r in run.results:
    checkpoint(r.id & ": " & $r.status & " " & r.reason)
    require r.status in {asSucceeded, asCacheHit, asUpToDate}
  for item in run.trace:
    if item.actionId == LinkId and
        item.event.startsWith("determinism-probe-"):
      result.add(item.event)

suite "the contents of a directory the action made and removed":

  test "are the action's own transient paths":
    let root = freshRoot("unit")
    let temporary = root / "out" / "rustcdSnTDZ"
    let evidence = fold(rustTemporaryRecords(temporary), root)
    let transient = transientOwnPaths(evidence)
    check transientOwnPath(transient, temporary)
    check transientOwnPath(transient, temporary / "raw-dylibs")
    check transientOwnPath(transient, temporary / "raw-dylibs" / "libc.a")
    check transientOwnPath(transient,
      temporary / "raw-dylibs" / "deeper" / "libm.so")
    # A name that merely starts with the temporary's is another file.
    check not transientOwnPath(transient, temporary & "x")
    check not transientOwnPath(transient, temporary & "x" / "libc.a")
    check not transientOwnPath(transient, root / "out")
    check not transientOwnPath(transient, root / "out" / "hello")
    check not transientOwnPath(TransientOwnPaths(), temporary / "libc.a")

  test "a written directory that still exists hides nothing beneath it":
    let root = freshRoot("surviving")
    let made = root / "out" / "kept"
    createDir(made)
    let evidence = fold([mutation(made, "mkdir")], root)
    let transient = transientOwnPaths(evidence)
    check not transientOwnPath(transient, made)
    check not transientOwnPath(transient, made / "libc.a")

  test "a directory the action only removed hides nothing beneath it":
    ## Deleting a directory is no evidence of having made it: what was in
    ## it may be an input the action consumed and then deleted.
    let root = freshRoot("removed-only")
    let gone = root / "gen"
    let evidence = fold([
      observed(mrFileRead, moFileRead, gone / "input.txt"),
      mutation(gone / "input.txt", "unlink"),
      mutation(gone, "rmdir")], root)
    let transient = transientOwnPaths(evidence)
    check not transientOwnPath(transient, gone)
    check not transientOwnPath(transient, gone / "input.txt")

  test "a directory emptied of what was there, then made and removed, hides nothing it held":
    ## `rm -rf gen; mkdir gen; ...; rmdir gen` after reading `gen/input.txt`:
    ## `gen` is a temporary the action made and removed, but the file it
    ## held was there before the action ran, and the action read it. Only
    ## what the action itself wrote beneath `gen` is its own.
    let root = freshRoot("emptied-and-remade")
    let gone = root / "gen"
    let evidence = fold([
      observed(mrFileRead, moFileRead, gone / "input.txt"),
      mutation(gone / "input.txt", "unlink"),
      mutation(gone, "rmdir"),
      mutation(gone, "mkdir"),
      mutation(gone / "scratch.o", "mkdir"),
      observed(mrPathProbe, moPathProbe, gone / "libc.a"),
      mutation(gone / "scratch.o", "rmdir"),
      mutation(gone, "rmdir")], root)
    let transient = transientOwnPaths(evidence)
    check transientOwnPath(transient, gone)
    check transientOwnPath(transient, gone / "scratch.o")
    check transientOwnPath(transient, gone / "libc.a")
    check not transientOwnPath(transient, gone / "input.txt")

  test "a path that walks out of the temporary is not beneath it":
    ## The kernel resolved `out/rustcX/../../src/main.rs` while the
    ## temporary existed, to the real source outside it.
    let root = freshRoot("parent-walk")
    let temporary = root / "out" / "rustcdSnTDZ"
    let transient = transientOwnPaths(fold(rustTemporaryRecords(temporary),
      root))
    check not transientOwnPath(transient,
      temporary & "/../../src/main.rs")
    check not transientOwnPath(transient, temporary & "/raw-dylibs/..")
    check transientOwnPath(transient, temporary & "/raw-dylibs/libc.a")

  test "do not move the determinism-probe key between runs":
    let root = freshRoot("probe")
    let project = freshProject(root)
    let config = configFor(root)
    let first = runBuild(linkGraph(root, project, "dSnTDZ"), config)
    check first.probeEvents() == @["determinism-probe-candidate"]
    # Same inputs, same output bytes; only the temporary directory's random
    # name differs, as it does on every real rustc link.
    removeFile(project / "out" / "hello")
    let second = runBuild(linkGraph(root, project, "paK8NC"), config)
    check second.probeEvents() == @["determinism-probe-verified"]
    # The admitted record's input accesses keep the source and drop
    # everything beneath either temporary.
    let sidecars = accessSidecars(root)
    check sidecars.len == 1
    for accesses in sidecars:
      check project / "src" / "main.rs" in accesses.reads
      for path in accesses.reads & accesses.probes & accesses.enumerations:
        check "/rustc" notin path.replace('\\', '/')

  test "a removed directory whose name prefixes a real input's does not hide it":
    ## `proj/sr` made and removed must not take `proj/src/main.rs` out of
    ## the key: a changed source must not be admitted as a verified rerun.
    let root = freshRoot("prefix")
    let project = freshProject(root)
    let config = configFor(root)
    let sibling = project / "sr"
    let extra = @[mutation(sibling, "mkdir"), mutation(sibling, "rmdir")]
    let first = runBuild(linkGraph(root, project, "dSnTDZ", extra), config)
    check first.probeEvents() == @["determinism-probe-candidate"]
    removeFile(project / "out" / "hello")
    writeFile(project / "src" / "main.rs", "fn main() { std::process::exit(1) }\n")
    let second = runBuild(linkGraph(root, project, "paK8NC", extra), config)
    check second.probeEvents() == @["determinism-probe-candidate"]

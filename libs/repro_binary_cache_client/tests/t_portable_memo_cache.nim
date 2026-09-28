## Cache-Scope P3.3 — the remote memoization plane, against a live binary
## cache server.
##
## The properties: a record the ENGINE publishes from one checkout is found
## from a checkout at a different absolute path and its outputs restored there
## with nothing executed; a content change misses; an entry whose bytes are not
## the ones its record names is refused, and a host will not publish one; and
## several candidate path sets for one weak fingerprint are all discoverable,
## with a republish reusing its slot.

import std/[net, options, os, osproc, strutils, times, unittest]

import repro_build_engine
import repro_core/paths
import repro_hash
import repro_local_store

import ../src/repro_binary_cache_client
import ../src/repro_binary_cache_client/portable_memo_cache
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

const ServerBinary = "build/test-bin" / addFileExt("repro_binary_cache", ExeExt)

let TmpDir = absolutePath("build/test-tmp/t_portable_memo_cache-" &
  $getCurrentProcessId())

proc pickPort(): int =
  var sock = newSocket()
  sock.bindAddr(Port(0), "127.0.0.1")
  let local = sock.getLocalAddr()
  sock.close()
  int(local[1])

proc waitForListener(srvProc: Process; port: int): bool =
  for _ in 0 ..< 2400:
    if not srvProc.running():
      checkpoint("server exited before listening; exit=" &
        $srvProc.peekExitCode())
      return false
    var sock: Socket
    try:
      sock = newSocket()
      sock.connect("127.0.0.1", Port(port))
      return true
    except CatchableError:
      sleep(50)
    finally:
      if not sock.isNil:
        try: sock.close() except CatchableError: discard
  false

proc stopServer(p: Process) =
  try:
    if p.peekExitCode() == -1:
      try: p.terminate() except CatchableError: discard
      let deadline = epochTime() + 5.0
      while p.peekExitCode() == -1 and epochTime() < deadline:
        sleep(20)
      if p.peekExitCode() == -1:
        try: p.kill() except CatchableError: discard
    discard p.waitForExit()
  finally:
    try: p.close() except CatchableError: discard

proc project(parent, source: string): string =
  result = TmpDir / parent / "proj"
  createDir(result / "src")
  writeFile(result / "src" / "main.c", source)

proc rootsOf(project: string): seq[LogicalRoot] =
  @[LogicalRoot(label: "project", path: project, kind: lrkTracked)]

proc fingerprintForPayload(payload: string): ContentDigest =
  casDigest(payload.toOpenArrayByte(0, payload.high),
            domain = hdActionFingerprint)

proc buildIn(projectRoot: string; publisher: PortableMemoPublisher):
    tuple[result: ActionResult, trace: string] =
  let action = BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakWriteText,
    id: "t-pmc-write",
    deps: @[],
    inputs: @[projectRoot / "src" / "main.c"],
    outputs: @[projectRoot / "out" / "result.txt"],
    cwd: projectRoot,
    cacheable: true,
    publishToBinaryCache: true,
    actionCachePolicy: ffpTimestamp,
    weakFingerprint: fingerprintForPayload("t-pmc-write"),
    builtinText: "built from " & readFile(projectRoot / "src" / "main.c"))
  createDir(projectRoot / "out")
  var config = defaultBuildEngineConfig(projectRoot.parentDir / "cache")
  config.maxParallelism = 1
  config.portableRoots = rootsOf(projectRoot)
  config.portableMemoPublisher = publisher
  let run = runBuild(graph(@[action], newSeq[BuildPool]()), config)
  require run.results.len == 1
  require run.results[0].status == asSucceeded
  var trace = ""
  for event in run.trace:
    trace.add($event & "\n")
  (run.results[0], trace)

proc recordFor(project, weakHex: string; output: string;
               reads: seq[string] = @[]; probes: seq[string] = @[]):
    PortableMemoRecord =
  ## A record whose strong fingerprint is what `lookupRemoteMemo` will
  ## compute on `project` as it stands now.
  let roots = rootsOf(project)
  var inputs: seq[PortableInput] = @[]
  for r in reads:
    inputs.add(PortableInput(kind: pikRead, path: "project:" & r,
      digest: fileContentHex(project / r)))
  for p in probes:
    inputs.add(PortableInput(kind: pikProbe, path: "project:" & p,
      digest: if fileExists(project / p): "present" else: "absent"))
  let pathSet = pathSetOf(inputs)
  let strong = strongForPathSet(roots, weakHex, pathSet).get()
  let outs = portableOutputs(roots, [project / output])
  doAssert outs.portable
  PortableMemoRecord(weakHex: weakHex, pathSet: pathSet, strongHex: strong,
    outputs: outs.outputs)

var srvProc: Process
var baseUrl = ""
let kp = peerAuth.generateKeypair()

proc remote(label: string): MemoRemote =
  MemoRemote(
    endpoints: @[SubstituteEndpoint(baseUrl: baseUrl,
      trustedSigners: @[kp.publicKey], priority: 30)],
    publishEndpoint: baseUrl, keypair: kp, canPublish: true,
    scratchRoot: TmpDir / ("scratch-" & label))

suite "Cache-Scope P3.3 — remote memoization plane":

  setup:
    if baseUrl.len == 0:
      if dirExists(TmpDir):
        removeDir(extendedPath(TmpDir))
      createDir(TmpDir)
      let port = pickPort()
      srvProc = startProcess(absolutePath(ServerBinary),
        args = @["--root=" & TmpDir / "server",
                 "--listen=127.0.0.1:" & $port],
        options = {poStdErrToStdOut})
      require waitForListener(srvProc, port)
      baseUrl = "http://127.0.0.1:" & $port

  test "the engine publishes; another checkout finds and restores it":
    let a = project("host-a", "int main;\n")
    let remoteA = remote("a")
    let publisher: PortableMemoPublisher =
      proc (roots: seq[LogicalRoot]; record: PortableMemoRecord): string =
        {.cast(gcsafe).}:
          let attempt = publishMemo(remoteA, roots, record)
          result = if attempt.ok: "" else: attempt.reason
    let built = buildIn(a, publisher)
    require built.result.portable
    checkpoint(built.trace)
    check "portable-memo-published" in built.trace

    # Host B: a different checkout path, nothing built, no local cache.
    let b = project("host-b/at/another/depth", "int main;\n")
    check not fileExists(b / "out" / "result.txt")
    let found = lookupRemoteMemo(remote("b"), rootsOf(b),
      built.result.portableWeakHex)
    checkpoint(found.reason)
    require found.hit.isSome
    let hit = found.hit.get()
    defer: discardHit(hit)
    check hit.record.strongHex == built.result.portableStrongHex
    check hit.record.outputs == built.result.portableOutputs
    check restoreMemoOutputs(hit, rootsOf(b)) == ""
    check readFile(b / "out" / "result.txt") ==
      readFile(a / "out" / "result.txt")

  test "a checkout whose input differs misses":
    let a = project("miss-a", "int main;\n")
    let remoteA = remote("miss-a")
    let publisher: PortableMemoPublisher =
      proc (roots: seq[LogicalRoot]; record: PortableMemoRecord): string =
        {.cast(gcsafe).}:
          let attempt = publishMemo(remoteA, roots, record)
          result = if attempt.ok: "" else: attempt.reason
    let built = buildIn(a, publisher)
    require built.result.portable
    let c = project("miss-c", "int changed;\n")
    let found = lookupRemoteMemo(remote("miss-c"), rootsOf(c),
      built.result.portableWeakHex)
    check found.hit.isNone
    check found.reason.len > 0

  test "an entry whose bytes are not the ones its record names is refused":
    let a = project("tamper", "int main;\n")
    createDir(a / "out")
    writeFile(a / "out" / "x.txt", "good")
    let weak = repeat('a', 64)
    let record = recordFor(a, weak, "out/x.txt", reads = @["src/main.c"])
    let r = remote("tamper")
    # This host will not publish a record its outputs do not match.
    writeFile(a / "out" / "x.txt", "changed after recording")
    let refused = publishMemo(r, rootsOf(a), record)
    check not refused.ok
    check "refusing to publish" in refused.reason
    writeFile(a / "out" / "x.txt", "good")
    # A dishonest producer stages it properly, then swaps the bytes.
    let stage = TmpDir / "tamper-stage"
    check stageMemoEntry(record, rootsOf(a), stage) == ""
    writeFile(stage / StagedOutputsDir / "0", "evil")
    let recordId = memoRecordIdentity(r, weak, pathSetHash(record.pathSet),
      record.strongHex)
    check publishInProcess(PublishInProcessRequest(
      entryKeyHex: deriveCacheEntryKeyHex(recordId), prefixDir: stage,
      identity: recordId, endpoint: baseUrl, keypair: kp)).ok
    let slotStage = TmpDir / "tamper-slot"
    createDir(slotStage)
    let pathSetBytes = encodePathSet(record.pathSet)
    writeFile(slotStage / StagedPathSetName, pathSetBytes)
    let slotId = pathSetSlotIdentity(r, weak, 0)
    check publishInProcess(PublishInProcessRequest(
      entryKeyHex: deriveCacheEntryKeyHex(slotId), prefixDir: slotStage,
      identity: slotId, endpoint: baseUrl, keypair: kp)).ok
    let found = lookupRemoteMemo(remote("tamper-consumer"), rootsOf(a), weak)
    check found.hit.isNone
    checkpoint(found.reason)
    check "not the content its record names" in found.reason

  test "several path sets for one weak fingerprint are all discoverable":
    let p = project("multi", "int main;\n")
    createDir(p / "out")
    writeFile(p / "out" / "o.txt", "first")
    let weak = repeat('b', 64)
    let r = remote("multi")
    # Execution 1 looked for a header and found none — an include search.
    let first = recordFor(p, weak, "out/o.txt", reads = @["src/main.c"],
      probes = @["src/main.h"])
    let pub1 = publishMemo(r, rootsOf(p), first)
    checkpoint(pub1.reason)
    check pub1.ok
    check pub1.slot == 0
    # Execution 2 found it, read it, and wrote other bytes.
    writeFile(p / "src" / "main.h", "")
    writeFile(p / "out" / "o.txt", "second")
    let second = recordFor(p, weak, "out/o.txt",
      reads = @["src/main.c", "src/main.h"])
    let pub2 = publishMemo(r, rootsOf(p), second)
    check pub2.ok
    check pub2.slot == 1
    check remoteCandidatePathSets(r, weak).len == 2
    # Republishing reuses the slot instead of taking a third.
    check publishMemo(r, rootsOf(p), second).slot == 1
    check remoteCandidatePathSets(r, weak).len == 2
    # With the header present only execution 2 matches...
    let withHeader = lookupRemoteMemo(remote("multi-c1"), rootsOf(p), weak)
    require withHeader.hit.isSome
    check withHeader.hit.get().record.strongHex == second.strongHex
    discardHit(withHeader.hit.get())
    # ...and without it, execution 1 does.
    removeFile(p / "src" / "main.h")
    let without = lookupRemoteMemo(remote("multi-c2"), rootsOf(p), weak)
    require without.hit.isSome
    check without.hit.get().record.strongHex == first.strongHex
    discardHit(without.hit.get())

if baseUrl.len > 0:
  stopServer(srvProc)
  try: removeDir(extendedPath(TmpDir))
  except CatchableError: discard

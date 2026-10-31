## Campaign M17 (ReproOS-Campaign-Completion.milestones.org),
## `t_portable_memo_refuses_timestamp_records`: Edge-Derived-Identities.md
## §3.3a and its 2026-10-27 rider (§10 decision 11, conflict C2), on the
## Cache-Scope Phase 3 portable memo publisher, against a live binary cache
## server.
##
## With portable caching on (what `REPRO_PORTABLE_CACHE=1` wires: logical
## roots and the signed remote memo plane), an edge recorded under
## `ffpTimestamp` publishes nothing. Its portable record is still computed
## and kept in the LOCAL memo store, which serves this host, but no record
## reaches the server, the trace names the policy, and a second checkout
## looking the edge up misses and executes it. The same edge under
## `ffpHybrid` publishes, and a second checkout substitutes it: restored,
## not executed, byte-identical. Publication never hashes the timestamp
## record's inputs to make it publishable: the refusal happens in
## `finishPortableRecord` before the publisher is called, and the record it
## would have published is exactly the one the hybrid case publishes.
##
## Falsifier: removing the check in `finishPortableRecord` publishes the
## timestamp record, and the second checkout substitutes it.
##
## MOCK POLICY: none. A real `repro_binary_cache` server process, the real
## engine, the real publisher/lookup/restorer the CLI wires
## (`portable_memo_cache`), ECDSA-signed manifests, real files.

import std/[net, options, os, osproc, strutils, times, unittest]

import repro_build_engine
import repro_core/paths
import repro_hash
import repro_local_store

import ../src/repro_binary_cache_client
import ../src/repro_binary_cache_client/portable_memo_cache
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

const ServerBinary = "build/test-bin" / addFileExt("repro_binary_cache", ExeExt)

let TmpDir = absolutePath(
  "build/test-tmp/t_portable_memo_refuses_timestamp_records-" &
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

var srvProc: Process
var baseUrl = ""
let kp = peerAuth.generateKeypair()

proc ensureServer() =
  if baseUrl.len > 0:
    return
  if dirExists(TmpDir):
    removeDir(extendedPath(TmpDir))
  createDir(TmpDir)
  let port = pickPort()
  srvProc = startProcess(absolutePath(ServerBinary),
    args = @["--root=" & TmpDir / "server",
             "--listen=127.0.0.1:" & $port],
    options = {poStdErrToStdOut})
  doAssert waitForListener(srvProc, port), "binary cache server did not start"
  baseUrl = "http://127.0.0.1:" & $port

proc remote(label: string): MemoRemote =
  MemoRemote(
    endpoints: @[SubstituteEndpoint(baseUrl: baseUrl,
      trustedSigners: @[kp.publicKey], priority: 30)],
    publishEndpoint: baseUrl, keypair: kp, canPublish: true,
    scratchRoot: TmpDir / ("scratch-" & label))

proc publisherFor(target: MemoRemote): PortableMemoPublisher =
  result = proc (roots: seq[LogicalRoot]; record: PortableMemoRecord;
                 withOutputs: bool): string =
    {.cast(gcsafe).}:
      let attempt = publishMemo(target, roots, record, withOutputs)
      result = if attempt.ok: "" else: attempt.reason

proc lookupFor(target: MemoRemote): PortableMemoLookup =
  result = proc (roots: seq[LogicalRoot]; weakHex: string;
                 resolve: IdentityResolver): Option[PortableMemoRecord] =
    {.cast(gcsafe).}:
      result = lookupRemoteMemo(target, roots, weakHex, resolve).hit

proc restorerFor(target: MemoRemote): PortableMemoRestorer =
  result = proc (roots: seq[LogicalRoot]; record: PortableMemoRecord):
      string =
    {.cast(gcsafe).}:
      result = restoreMemoOutputs(target, record, roots)

proc rootsOf(project: string): seq[LogicalRoot] =
  @[LogicalRoot(label: "project", path: project, kind: lrkTracked)]

proc project(parent, source: string): string =
  result = TmpDir / parent / "proj"
  createDir(result / "src")
  createDir(result / "out")
  writeFile(result / "src" / "main.c", source)

type Built = object
  result: ActionResult
  trace: string

proc build(projectRoot: string; policy: FileFingerprintPolicy;
           publisher: PortableMemoPublisher = nil;
           lookup: PortableMemoLookup = nil;
           restorer: PortableMemoRestorer = nil): Built =
  ## The edge: tagged, so its bytes are published with its record. Its weak
  ## fingerprint is the same in every checkout and under either policy, so
  ## the timestamp and hybrid runs ask the server about the same edge.
  let source = readFile(projectRoot / "src" / "main.c")
  let action = BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakWriteText,
    id: "t-m17-portable-edge",
    deps: @[],
    inputs: @[projectRoot / "src" / "main.c"],
    outputs: @[projectRoot / "out" / "result.txt"],
    cwd: projectRoot,
    cacheable: true,
    publishToBinaryCache: true,
    actionCachePolicy: policy,
    weakFingerprint: weakFingerprintFromText("t-m17-portable-edge"),
    builtinText: "built from " & source)
  var config = defaultBuildEngineConfig(projectRoot.parentDir / "cache")
  config.maxParallelism = 1
  config.portableRoots = rootsOf(projectRoot)
  config.portableMemoPublisher = publisher
  config.portableLookup = lookup != nil
  config.portableMemoLookup = lookup
  config.portableMemoRestorer = restorer
  let run = runBuild(graph(@[action], newSeq[BuildPool]()), config)
  require run.results.len == 1
  require run.results[0].status in {asSucceeded, asCacheHit, asUpToDate}
  result.result = run.results[0]
  for event in run.trace:
    result.trace.add(event.event & ": " & event.detail & "\n")

proc events(trace, event: string): seq[string] =
  for line in trace.splitLines():
    if line.startsWith(event & ": "):
      result.add(line)

suite "M17: the portable memo publisher refuses timestamp-policy records":

  setup:
    ensureServer()

  test "t_portable_memo_refuses_timestamp_records":
    # -- Producer, under ffpTimestamp --------------------------------------
    let a = project("ts-producer", "int shared;\n")
    let ts = build(a, ffpTimestamp, publisher = publisherFor(remote("ts-a")))
    checkpoint(ts.trace)
    require ts.result.launched
    # The portable record exists and serves this host...
    check ts.result.portable
    check ts.result.portableStrongHex.len == 64
    let local = lookupMemo(a.parentDir / "cache" / "portable-memo",
      rootsOf(a), ts.result.portableWeakHex)
    check local.isSome
    check local.isSome and
      local.get().strongHex == ts.result.portableStrongHex
    # ...but it was not published, and the trace says why.
    check events(ts.trace, "portable-memo-published").len == 0
    let refused = events(ts.trace, "portable-memo-publish-refused")
    check refused.len == 1
    check refused.len == 1 and "ffpTimestamp input-check policy" in refused[0]
    # Nothing for this edge is on the server.
    let probe = project("ts-probe/elsewhere", "int shared;\n")
    let found = lookupRemoteMemo(remote("ts-probe"), rootsOf(probe),
      ts.result.portableWeakHex)
    check found.hit.isNone
    # A second checkout looking it up misses and executes.
    let b = project("ts-consumer/at/depth", "int shared;\n")
    let consumed = build(b, ffpTimestamp,
      lookup = lookupFor(remote("ts-b")), restorer = restorerFor(remote("ts-b")))
    checkpoint(consumed.trace)
    check consumed.result.launched
    check events(consumed.trace, "portable-resolved").len == 0

    # -- The same edge under ffpHybrid -------------------------------------
    let c = project("hy-producer", "int shared;\n")
    let hy = build(c, ffpHybrid, publisher = publisherFor(remote("hy-c")))
    checkpoint(hy.trace)
    require hy.result.launched
    check events(hy.trace, "portable-memo-publish-refused").len == 0
    check events(hy.trace, "portable-memo-published").len == 1
    # The timestamp run computed the very record the hybrid run published:
    # the refusal withheld it, it did not change it.
    check hy.result.portableWeakHex == ts.result.portableWeakHex
    check hy.result.portableStrongHex == ts.result.portableStrongHex
    # A second checkout substitutes it: restored, not executed.
    let d = project("hy-consumer/at/depth", "int shared;\n")
    check not fileExists(d / "out" / "result.txt")
    let served = build(d, ffpHybrid,
      lookup = lookupFor(remote("hy-d")), restorer = restorerFor(remote("hy-d")))
    checkpoint(served.trace)
    check not served.result.launched
    check events(served.trace, "portable-resolved").len == 1
    check readFile(d / "out" / "result.txt") ==
      readFile(c / "out" / "result.txt")

if baseUrl.len > 0:
  stopServer(srvProc)
  try: removeDir(extendedPath(TmpDir))
  except CatchableError: discard

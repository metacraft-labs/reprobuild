## Cache-Scope P3.3 — the remote memoization plane, against a live binary
## cache server.
##
## The properties: a record the ENGINE publishes from one checkout is found
## from a checkout at a different absolute path and its outputs restored there
## with nothing executed; an untagged action publishes its record (metadata,
## for resolving downstream inputs) but not its bytes; a content change misses;
## outputs whose bytes are not the ones their record names are refused, and a
## host will not publish them; and
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

proc buildIn(projectRoot: string; publisher: PortableMemoPublisher;
             tagged = true): tuple[result: ActionResult, trace: string] =
  let action = BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakWriteText,
    id: "t-pmc-write",
    deps: @[],
    inputs: @[projectRoot / "src" / "main.c"],
    outputs: @[projectRoot / "out" / "result.txt"],
    cwd: projectRoot,
    cacheable: true,
    publishToBinaryCache: tagged,
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

proc publisherFor(target: MemoRemote): PortableMemoPublisher =
  ## The engine hook as the CLI wires it.
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

proc failingRestorer(): PortableMemoRestorer =
  result = proc (roots: seq[LogicalRoot]; record: PortableMemoRecord):
      string =
    "restore refused by the test"

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

type ChainRun = object
  compile, link: ActionResult
  trace: string

proc buildChain(projectRoot: string; publisher: PortableMemoPublisher = nil;
                lookup: PortableMemoLookup = nil;
                restorer: PortableMemoRestorer = nil): ChainRun =
  ## compile (untagged: its record is published, its bytes are not) ->
  ## link (tagged: record and bytes).
  let compile = BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakWriteText, id: "t-pmc-compile", deps: @[],
    inputs: @[projectRoot / "src" / "main.c"],
    outputs: @[projectRoot / "obj" / "main.o"],
    cwd: projectRoot, cacheable: true, publishToBinaryCache: false,
    actionCachePolicy: ffpTimestamp,
    weakFingerprint: fingerprintForPayload("t-pmc-compile"),
    builtinText: "object of " & readFile(projectRoot / "src" / "main.c"))
  let link = BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakWriteText, id: "t-pmc-link", deps: @["t-pmc-compile"],
    inputs: @[projectRoot / "obj" / "main.o"],
    outputs: @[projectRoot / "bin" / "app"],
    cwd: projectRoot, cacheable: true, publishToBinaryCache: true,
    actionCachePolicy: ffpTimestamp,
    weakFingerprint: fingerprintForPayload("t-pmc-link"),
    builtinText: "linked app\n")
  createDir(projectRoot / "obj")
  createDir(projectRoot / "bin")
  var config = defaultBuildEngineConfig(projectRoot.parentDir / "cache")
  config.maxParallelism = 1
  config.portableRoots = rootsOf(projectRoot)
  config.portableMemoPublisher = publisher
  config.portableLookup = lookup != nil
  config.portableMemoLookup = lookup
  config.portableMemoRestorer = restorer
  let run = runBuild(graph(@[compile, link], newSeq[BuildPool]()), config)
  require run.results.len == 2
  for r in run.results:
    require r.status in {asSucceeded, asCacheHit, asUpToDate}
    if r.id == "t-pmc-compile": result.compile = r
    else: result.link = r
  for event in run.trace:
    result.trace.add($event & "\n")

suite "Cache-Scope P3.3 — remote memoization plane":

  setup:
    ensureServer()

  test "the engine publishes; another checkout finds and restores it":
    let a = project("host-a", "int main;\n")
    let built = buildIn(a, publisherFor(remote("a")))
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
    let record = found.hit.get()
    check record.strongHex == built.result.portableStrongHex
    check record.outputs == built.result.portableOutputs
    # The lookup placed nothing; restoring does.
    check not fileExists(b / "out" / "result.txt")
    check restoreMemoOutputs(remote("b"), record, rootsOf(b)) == ""
    check readFile(b / "out" / "result.txt") ==
      readFile(a / "out" / "result.txt")

  test "an untagged action publishes its record but not its bytes":
    let a = project("meta-a", "int meta;\n")
    let built = buildIn(a, publisherFor(remote("meta-a")), tagged = false)
    require built.result.portable
    check "portable-memo-published" in built.trace
    let b = project("meta-b", "int meta;\n")
    let found = lookupRemoteMemo(remote("meta-b"), rootsOf(b),
      built.result.portableWeakHex)
    require found.hit.isSome
    # The record is enough to resolve a downstream action's inputs...
    check found.hit.get().outputs == built.result.portableOutputs
    # ...but there are no bytes to restore.
    check "no outputs published" in
      restoreMemoOutputs(remote("meta-b"), found.hit.get(), rootsOf(b))
    check not fileExists(b / "out" / "result.txt")

  test "a checkout whose input differs misses":
    let a = project("miss-a", "int main;\n")
    let built = buildIn(a, publisherFor(remote("miss-a")))
    require built.result.portable
    let c = project("miss-c", "int changed;\n")
    let found = lookupRemoteMemo(remote("miss-c"), rootsOf(c),
      built.result.portableWeakHex)
    check found.hit.isNone
    check found.reason.len > 0

  test "outputs whose bytes are not the ones their record names are refused":
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
    # A dishonest producer publishes an honest record, and outputs staged
    # properly with the bytes swapped afterwards.
    check publishMemo(r, rootsOf(a), record, withOutputs = false).ok
    let stage = TmpDir / "tamper-stage"
    check stageMemoOutputs(record, rootsOf(a), stage) == ""
    writeFile(stage / StagedOutputsDir / "0", "evil")
    let outputsId = memoOutputsIdentity(r, weak,
      pathSetHash(record.pathSet), record.strongHex)
    check publishInProcess(PublishInProcessRequest(
      entryKeyHex: deriveCacheEntryKeyHex(outputsId), prefixDir: stage,
      identity: outputsId, endpoint: baseUrl, keypair: kp)).ok
    # The consumer finds the record, and refuses the bytes.
    let c = project("tamper-consumer", "int main;\n")
    let found = lookupRemoteMemo(remote("tamper-c"), rootsOf(c), weak)
    require found.hit.isSome
    let restored = restoreMemoOutputs(remote("tamper-c"), found.hit.get(),
      rootsOf(c))
    checkpoint(restored)
    check "not the content its record names" in restored
    check not fileExists(c / "out" / "x.txt")

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
    check withHeader.hit.get().strongHex == second.strongHex
    # ...and without it, execution 1 does.
    removeFile(p / "src" / "main.h")
    let without = lookupRemoteMemo(remote("multi-c2"), rootsOf(p), weak)
    require without.hit.isSome
    check without.hit.get().strongHex == first.strongHex

suite "Cache-Scope P3.4 — lookup without materialization":

  setup:
    ensureServer()

  test "another checkout gets the result without running or fetching the rest":
    let a = project("chain-a", "int main;\n")
    let built = buildChain(a, publisher = publisherFor(remote("chain-a")))
    require built.compile.portable
    require built.link.portable
    check built.compile.launched
    check built.link.launched

    # Host B, elsewhere, with no local caches: nothing executes. The compile
    # is resolved from its RECORD alone — its object file is never fetched,
    # because the link that consumes it is served as well — and the link's
    # output is restored.
    let b = project("chain-b/at/another/depth", "int main;\n")
    let served = buildChain(b, lookup = lookupFor(remote("chain-b")),
      restorer = restorerFor(remote("chain-b")))
    checkpoint(served.trace)
    check not served.compile.launched
    check not served.link.launched
    check served.compile.status == asCacheHit
    check served.compile.reason == "portable-resolved"
    check served.link.status == asCacheHit
    check served.link.reason == "portable-restored"
    check not fileExists(b / "obj" / "main.o")
    check readFile(b / "bin" / "app") == readFile(a / "bin" / "app")
    check served.link.portableStrongHex == built.link.portableStrongHex

  test "a source change executes the chain; nothing stale is served":
    let a = project("chg-a", "int main;\n")
    discard buildChain(a, publisher = publisherFor(remote("chg-a")))
    let c = project("chg-c", "int different;\n")
    # A stale object file from some earlier build must not key a hit either.
    createDir(c / "obj")
    writeFile(c / "obj" / "main.o", "object of int main;\n")
    let run = buildChain(c, lookup = lookupFor(remote("chg-c")),
      restorer = restorerFor(remote("chg-c")))
    checkpoint(run.trace)
    check run.compile.launched
    check run.link.launched
    check readFile(c / "obj" / "main.o") == "object of int different;\n"

  test "reads inside a produced directory resolve from its manifest":
    proc treeGraph(p: string): seq[BuildAction] =
      # The source tree the builtin copies from, identical on both hosts.
      createDir(p / "tree-src" / "sub")
      writeFile(p / "tree-src" / "a.txt", "A\n")
      writeFile(p / "tree-src" / "sub" / "b.txt", "B\n")
      # Produces a directory; its only FILE output is its manifest, so a
      # read under `tree/` can only be identified through the directory's
      # listing in the record.
      let tree = BuildAction(
        governingLockIdentity: lockIdentityOutsideSolvedGraph(),
        kind: bakPreserveTree, id: "t-pmc-tree", deps: @[],
        inputs: @[p / "tree-src" / "a.txt", p / "tree-src" / "sub" / "b.txt"],
        outputs: @[p / ".repro" / "preserve-tree" / "t-pmc-tree.manifest"],
        declaredOutputs: @[p / "tree"],
        cwd: p, cacheable: true, publishToBinaryCache: false,
        actionCachePolicy: ffpTimestamp,
        weakFingerprint: fingerprintForPayload("t-pmc-tree"),
        builtinText: "tree-src\ntree",
        builtinEntries: @["a.txt", "sub/b.txt"])
      let use = BuildAction(
        governingLockIdentity: lockIdentityOutsideSolvedGraph(),
        kind: bakWriteText, id: "t-pmc-use", deps: @["t-pmc-tree"],
        inputs: @[p / "tree" / "a.txt", p / "tree" / "sub" / "b.txt"],
        outputs: @[p / "bin" / "use"],
        cwd: p, cacheable: true, publishToBinaryCache: true,
        actionCachePolicy: ffpTimestamp,
        weakFingerprint: fingerprintForPayload("t-pmc-use"),
        builtinText: "used the tree\n")
      createDir(p / "bin")
      @[tree, use]
    proc run(p: string; publisher: PortableMemoPublisher = nil;
             lookup: PortableMemoLookup = nil;
             restorer: PortableMemoRestorer = nil):
        tuple[results: seq[ActionResult], trace: string] =
      var config = defaultBuildEngineConfig(p.parentDir / "cache")
      config.maxParallelism = 1
      config.portableRoots = rootsOf(p)
      config.portableMemoPublisher = publisher
      config.portableLookup = lookup != nil
      config.portableMemoLookup = lookup
      config.portableMemoRestorer = restorer
      let built = runBuild(graph(treeGraph(p), newSeq[BuildPool]()), config)
      for event in built.trace:
        result.trace.add($event & "\n")
      result.results = built.results

    let a = project("tree-a", "int main;\n")
    let first = run(a, publisher = publisherFor(remote("tree-a")))
    checkpoint(first.trace)
    for r in first.results:
      require r.status == asSucceeded
      require r.portable
    let b = project("tree-b/elsewhere", "int main;\n")
    let served = run(b, lookup = lookupFor(remote("tree-b")),
      restorer = restorerFor(remote("tree-b")))
    checkpoint(served.trace)
    for r in served.results:
      check not r.launched
      check r.status == asCacheHit
    # The directory was never fetched; the file read inside it, one level
    # down, was identified from the tree action's record.
    check not dirExists(b / "tree")
    check readFile(b / "bin" / "use") == "used the tree\n"

  test "an output that cannot be restored falls back to executing":
    let a = project("fail-a", "int main;\n")
    discard buildChain(a, publisher = publisherFor(remote("fail-a")))
    let d = project("fail-d", "int main;\n")
    let run = buildChain(d, lookup = lookupFor(remote("fail-d")),
      restorer = failingRestorer())
    checkpoint(run.trace)
    # The link cannot be put in place, so it executes; that makes the
    # compile's object file needed, which has no published bytes either.
    check "portable-restore-failed" in run.trace
    check run.compile.launched
    check run.link.launched
    check fileExists(d / "obj" / "main.o")
    check fileExists(d / "bin" / "app")

if baseUrl.len > 0:
  stopServer(srvProc)
  try: removeDir(extendedPath(TmpDir))
  except CatchableError: discard

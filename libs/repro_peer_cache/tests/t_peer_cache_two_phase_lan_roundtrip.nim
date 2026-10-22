## Distributed-Execution M0 gate: two-phase peer-cache round trip over real
## TCP between two workspace checkouts at different roots.
##
## Two separate OS PROCESSES, each a full peer-cache node (`PeerCacheHost`,
## the same object `repro-daemon` hosts) bound to the interface its policy
## declares — loopback here, as no `bind=` is given; never a wildcard
## (Distributed-Execution M7, FLOW-6) — on its own port, authenticated by
## its own host CA over TLS (M7: the memoization plane only accepts entries
## whose issuer attestation verifies), and backed by its own disk stores, build the same C program from two
## checkouts of one workspace that sit under DIFFERENT parent directories at
## different depths (`.../pa/x/ws-a`, `.../pb/ws-b`). `main.c` includes
## `config.h`, which the compiler's depfile reports — a DYNAMIC input the
## static weak fingerprint does not see — and the build script also reports
## the walk up its working directory's parents, as a monitored compile does,
## so each record carries its own checkout's ancestors by absolute path.
##
##   1. Node A (child process) builds in ws-a and publishes through the
##      two-phase memo store: PathSet blob + output blob into its CAS, memo
##      entry under (WeakFingerprint, StrongFingerprint).
##   2. Node B (this process) builds the same action in ws-b. Its local
##      cache is empty; the engine asks the peer cache, which runs Steps
##      1–4 against A over TCP: selectors, PathSet blob (BLAKE3-verified),
##      strong fingerprint recomputed from ws-b's own files, memo entry,
##      output blob (BLAKE3-verified). The record's `$WORKSPACE/...` paths
##      are rebased onto ws-b and the binary is restored there without
##      running the compiler.
##   3. B edits `config.h` (main.c and the weak fingerprint unchanged). The
##      peer lookup finds A's selector but the recomputed strong fingerprint
##      differs: a strong-fingerprint miss, not a false hit. B rebuilds and
##      publishes a SECOND selector under the same weak fingerprint; A's
##      entry is untouched and both are served side by side.
##   4. B reverts `config.h`. The original execution is still served — from
##      B's own records or, because the timestamp policy sees a fresh mtime,
##      through A's selector again — and the v1 binary is restored over the
##      v2 one without running the compiler.
##
## Throughout, no content-plane reply fails verification, so no peer is
## ever marked suspect.
##
## TRUST PROFILES (Distributed-Execution M7): the gate runs twice — with
## hardened nodes (one-hour host-CA leaves) and with trusted nodes (pinned
## long-lived host keys, the product default) — every node of a run in the
## same profile.
##
## MOCK POLICY — none. Real sockets (no in-process `TableRef` peer table),
## real processes, the real build engine, a real C compiler, real CAS /
## action-cache / memo stores on disk. The roots are unique per run under
## the test TMPDIR rather than the literal `/tmp/ws-a` / `/tmp/ws-b` so
## concurrent suite runs cannot collide; they are distinct, unrelated
## directories, which is the property the gate is about.

import std/[algorithm, asyncdispatch, options, os, osproc, strutils, tables,
            times, unittest]

import repro_build_engine
import repro_hash
import repro_local_store
import repro_peer_cache
import repro_cli_support/peer_cache_wiring

import ./m7_test_pki

const
  ConfigV1 = "#define GREETING \"hello from config v1\"\n"
  ConfigV2 = "#define GREETING \"hello from config v2\"\n"
  MainSource = """
#include <stdio.h>
#include "config.h"
int main(void) {
  printf("%s\n", GREETING);
  return 0;
}
"""
  ActionId = "two-phase-hello"
  BuildScript = """#!/bin/sh
# Compile, then report what a monitored compile reports beyond the depfile:
# the walk up the parent chain of the working directory (every shell and
# compiler that resolves its cwd performs it). The build engine records each
# ancestor as an existence-only directory input, by absolute path.
set -eu
"$1" -O1 -MD -MF out/hello.d -o "$2" main.c
d=$(pwd -P)
printf '%s:' "$2" >> out/hello.d
while [ "$d" != "/" ]; do
  d=$(dirname "$d")
  printf ' %s' "$d" >> out/hello.d
done
printf '\n' >> out/hello.d
"""

type AssertionFailure = object of CatchableError

template ensure(cond: bool) =
  ## `require` without its `quit`: unittest's `require` exits the process on
  ## failure, which skips the `defer` that stops the processes this test
  ## started. Raising instead fails the test AND runs the cleanup.
  let ok = cond
  check ok
  if not ok:
    raise newException(AssertionFailure, "precondition failed: " & astToStr(cond))

proc ccPath(): string =
  result = findExe("cc")
  if result.len == 0:
    result = findExe("clang")

proc normalizedRoot(path: string): string =
  normalizedPath(absolutePath(path))


proc writeWorkspace(ws: string; config: string) =
  createDir(ws / "out")
  writeFile(ws / "main.c", MainSource)
  writeFile(ws / "config.h", config)
  writeFile(ws / "build.sh", BuildScript)

proc helloGraph(ws: string): BuildGraph =
  ## One compile+link action. Absolute output path (so the record names a
  ## path INSIDE the workspace that must be rebased), relative inputs, and
  ## a depfile that reports `config.h`.
  let output = ws / "out" / "hello"
  let compile = action(ActionId,
    ["/bin/sh", "build.sh", ccPath(), output],
    cwd = ws,
    inputs = ["main.c", "build.sh"],
    outputs = [output],
    depfile = "out/hello.d",
    cacheable = true,
    weakFingerprint = weakFingerprintFromText("t-peer-cache-two-phase.hello"),
    actionCachePolicy = ffpTimestamp,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  graph([compile])

proc nodeEngineConfig(cacheRoot, ws: string;
                      hooks: PeerCacheEngineHooks): BuildEngineConfig =
  ## The configuration `repro build` runs with (warm in-place mode), plus
  ## portable caching over the workspace root — what
  ## `REPRO_PORTABLE_CACHE=1` wires — and the peer-cache hooks.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 1'u32
  result.portableRoots = @[LogicalRoot(label: "project", path: ws,
    kind: lrkTracked)]
  wireEngineConfig(result, hooks, ws)

proc traceOf(res: BuildRunResult): string =
  for event in res.trace:
    result.add("\n    " & event.event & ": " & event.detail)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc nodePeerId(tag: char): PeerId =
  var raw: array[32, byte]
  raw[0] = byte(ord(tag))
  let pid = uint64(getCurrentProcessId())
  for k in 0 ..< 8:
    raw[1 + k] = byte((pid shr uint64(k * 8)) and 0xff'u64)
  peerIdFromBytes(raw)

# ---------------------------------------------------------------------------
# Node A: the producer process.
# ---------------------------------------------------------------------------

proc runProducerNode(ws, cacheRoot, stateDir, readyFile, stopFile: string;
                     profile: TrustProfile): int =
  ## Child-process entry. Starts a node serving `cacheRoot`, builds in `ws`
  ## (publishing attested entries through the hooks), reports its port, then
  ## serves until the parent drops `stopFile`. Its host CA was minted by the
  ## parent under `<base>/a` (the base is `stateDir`'s parent).
  let node = newTestNode(stateDir.parentDir, "a")
  let host = startPeerCacheHost(tlsConfig(node, profile = profile),
    nodePeerId('A'),
    cacheRoot = cacheRoot, stateDir = stateDir)
  let hooks = newPeerCacheEngineHooks(host.client,
    openPeerCacheStorage(cacheRoot), host.registry, host.attestorFor())
  let res = runBuild(helloGraph(ws), nodeEngineConfig(cacheRoot, ws, hooks))
  let item = res.byId(ActionId)
  if item.status != asSucceeded or hooks.stats.publishes != 1:
    stderr.writeLine("node A: build status=" & $item.status & " reason=" &
      item.reason & " publishes=" & $hooks.stats.publishes &
      " publishSkip=" & hooks.stats.lastPublishReason)
    host.stop()
    return 1
  writeFile(readyFile & ".tmp", $int(host.actualPort) & "\n")
  moveFile(readyFile & ".tmp", readyFile)
  let deadline = epochTime() + 300.0
  while not fileExists(stopFile) and epochTime() < deadline:
    host.tick(20)
  host.stop()
  0

if paramCount() >= 8 and paramStr(1) == "--producer-node":
  # The child's output goes to a log file the parent reads on failure; a
  # pipe nobody drains could block the child mid-build.
  discard reopen(stdout, paramStr(7), fmWrite)
  discard reopen(stderr, paramStr(7), fmAppend)
  quit(runProducerNode(paramStr(2), paramStr(3), paramStr(4), paramStr(5),
    paramStr(6), (if paramStr(8) == $tpTrusted: tpTrusted else: tpHardened)))

# ---------------------------------------------------------------------------
# Node B (this process) + assertions.
# ---------------------------------------------------------------------------

proc readStatus(stateDir: string): Table[string, string] =
  result = initTable[string, string]()
  let path = stateDir / PeerCacheStatusFileName
  if not fileExists(path):
    return
  for line in readFile(path).splitLines():
    let eq = line.find('=')
    if eq > 0:
      result[line[0 ..< eq]] = line[eq + 1 .. ^1]

proc statusInt(status: Table[string, string]; key: string): int =
  try: parseInt(status.getOrDefault(key, "0")) except ValueError: 0

proc waitForFile(path: string; process: Process; timeoutSeconds: float): bool =
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    if fileExists(path):
      return true
    if not process.running:
      return fileExists(path)
    sleep(50)
  false

proc runTwoPhaseRoundtrip(profile: TrustProfile): bool =
  ## The gate, run once per trust profile (Distributed-Execution M7): the
  ## producer child, node B and the third-party querier all run `profile`.
  ## Every step `check`s its own property; true once the whole round trip
  ## ran to its end.
  if ccPath().len == 0:
    # The gate is about a real C build; without a compiler it proves
    # nothing, so it fails rather than skipping into a vacuous pass.
    checkpoint("no C compiler (cc or clang) on PATH")
    fail()
  else:
    let base = normalizedRoot(getTempDir() / ("repro-m0-two-phase-" &
      $profile & "-" & $getCurrentProcessId()))
    if dirExists(base):
      removeDir(base)
    # Different parents AT DIFFERENT DEPTHS: the cross-host shape, where
    # every ancestor of the workspace differs between the two checkouts.
    let wsA = base / "pa" / "x" / "ws-a"
    let wsB = base / "pb" / "ws-b"
    let cacheA = base / "node-a-cache"
    let cacheB = base / "node-b-cache"
    let stateA = base / "node-a-state"
    let readyFile = base / "node-a.ready"
    let stopFile = base / "node-a.stop"
    let logA = base / "node-a.log"
    createDir(base)
    # Host CAs for A, B and the third-party querier Q, all pinning each
    # other (M7: authenticated peers, attested memo entries).
    let nodeA = newTestNode(base, "a")
    let nodeB = newTestNode(base, "b")
    let nodeQ = newTestNode(base, "q")
    mutualTrust([nodeA, nodeB, nodeQ])
    writeWorkspace(wsA, ConfigV1)
    writeWorkspace(wsB, ConfigV1)
    check wsA != wsB

    # -- Node A: a separate process --------------------------------------
    let producer = startProcess(getAppFilename(),
      args = ["--producer-node", wsA, cacheA, stateA, readyFile, stopFile,
              logA, $profile],
      options = {})
    var hostB: PeerCacheHost = nil
    var hostQ: PeerCacheHost = nil
    var queryClient: PeerCacheClient = nil
    defer:
      writeFile(stopFile, "stop\n")
      if not hostQ.isNil:
        hostQ.stop()
      elif not queryClient.isNil:
        try: waitFor queryClient.stop() except CatchableError: discard
      if not hostB.isNil:
        hostB.stop()
      let exitDeadline = epochTime() + 30.0
      while producer.running and epochTime() < exitDeadline:
        sleep(50)
      if producer.running:
        producer.terminate()
      discard producer.waitForExit()
      producer.close()
      if fileExists(logA):
        checkpoint("node A log:\n" & readFile(logA))
      removeDir(base)

    let producerReady = waitForFile(readyFile, producer, 240.0)
    if not producerReady:
      checkpoint("node A output: " &
        (if fileExists(logA): readFile(logA) else: "<no log>"))
    ensure producerReady
    let portA = Port(parseInt(readFile(readyFile).strip()))
    check fileExists(wsA / "out" / "hello")
    # Node A's build REPORTED its checkout's ancestors (the build script
    # appends the parent walk to the depfile), so the evidence the engine
    # folded names them by absolute path — the shape that made checkouts
    # under different parents miss. Whether the LOCAL record keeps them is
    # the engine's business (it drops existence probes of an output's
    # ancestors, `outputAncestorDirectoryKeys`); what the gate needs is that
    # they were observed and that the PUBLISHED record (checked below)
    # carries none of them.
    var reportedAncestors = 0
    for token in readFile(wsA / "out" / "hello.d").splitWhitespace():
      if token.isAbsolute and isWorkspaceAncestor(token, wsA):
        inc reportedAncestors
    checkpoint("node A depfile ancestor entries: " & $reportedAncestors)
    check reportedAncestors >= 3
    # Cross-host, node A's checkout path does not exist on node B's machine
    # at all. Both nodes share one filesystem here, so make that true: hide
    # A's checkout (A keeps serving from its cache root, outside it). B
    # evaluating any of A's ancestor paths now sees them ABSENT, which is
    # what a consumer on another host sees.
    let wsAResolved = expandFilename(wsA)
    moveDir(base / "pa", base / "pa-hidden")
    check not dirExists(wsA)

    # -- Node B: this process, seeded with A ------------------------------
    hostB = startPeerCacheHost(
      tlsConfig(nodeB, seeds = @[initEndpoint("127.0.0.1", portA)],
        profile = profile),
      nodePeerId('B'), cacheRoot = cacheB)
    # The declared interface (none given: loopback), never a wildcard.
    check hostB.server.listenAddr == "127.0.0.1"
    check hostB.bindResolution.isLoopback
    ensure hostB.client.connectedPeers().len == 1
    let peerA = hostB.client.connectedPeers()[0]
    let storageB = openPeerCacheStorage(cacheB)
    let hooksB = newPeerCacheEngineHooks(hostB.client, storageB,
      hostB.registry, hostB.attestorFor())
    let configB = nodeEngineConfig(cacheB, wsB, hooksB)

    # ---- (2) peer hit across roots ---------------------------------------
    check not fileExists(wsB / "out" / "hello")
    let first = runBuild(helloGraph(wsB), configB)
    let hit = first.byId(ActionId)
    checkpoint("first B build: status=" & $hit.status & " reason=" &
      hit.reason & " fetch=" & hooksB.stats.lastFetchReason & " install=" &
      hooksB.stats.lastInstallReason & traceOf(first))
    check hooksB.stats.hits == 1
    check hooksB.stats.installs == 1
    check hit.cacheDecision == cdHit
    check not hit.launched
    check fileExists(wsB / "out" / "hello")
    check execProcess(wsB / "out" / "hello").strip() == "hello from config v1"
    # Both blobs (PathSet + binary) crossed the wire, content-addressed.
    check hostB.client.fetchRoundTripCount >= 2
    check hostB.client.memoRoundTripCount >= 2

    # The weak fingerprint peers agreed on, and what A served for it.
    let weaks = storageB.memo.weakFingerprints()
    ensure weaks.len == 1
    let weak = weaks[0]
    let selectorsAfterHit = storageB.memo.listSelectors(weak)
    ensure selectorsAfterHit.len == 1
    let selectorA = selectorsAfterHit[0]
    let entryA = storageB.memo.readMemoEntry(weak,
      selectorA.strongFingerprint).get()
    # The entry B re-serves still carries A's attestation (M7): who
    # computed it survives the hop.
    check entryA.issuerHostId == nodeA.identity.hostId
    # The published record is workspace-normalized: it names
    # `$WORKSPACE/...`, never node A's checkout path.
    let recordA = decodeActionResultRecord(entryA.recordBytes)
    check recordA.outputs.len == 1
    check recordA.outputs[0].path == WorkspaceMarker & "/out/hello"
    var sawWorkspaceInput = false
    for input in recordA.inputs:
      check not input.path.contains(wsA)
      if input.path == WorkspaceMarker & "/config.h":
        sawWorkspaceInput = true
    check sawWorkspaceInput
    # The PUBLISHED record carries none of A's ancestors.
    for input in recordA.inputs:
      check not (input.path.isAbsolute and
        isWorkspaceAncestor(input.path, wsAResolved))
      check not input.path.contains(base)
      check not input.path.contains(expandFilename(base))
    # A advertised both its selector set (memo key) and its CAS blobs.
    check peerA in hostB.registry.findPeersWithBlob(memoAdvertKey(weak))
    check peerA in hostB.registry.findPeersWithBlob(entryA.pathSetDigest)
    check peerA in hostB.registry.findPeersWithBlob(entryA.outputDigests[0])

    # ---- (3) dynamic header edit: strong-fingerprint miss ---------------
    sleep(20)  # a fresh mtime for the timestamp policy
    writeFile(wsB / "config.h", ConfigV2)
    let missesBefore = hooksB.stats.strongMisses
    let hitsBefore = hooksB.stats.hits
    let second = runBuild(helloGraph(wsB), configB)
    let rebuilt = second.byId(ActionId)
    checkpoint("second B build: status=" & $rebuilt.status & " reason=" &
      rebuilt.reason & " fetch=" & hooksB.stats.lastFetchReason &
      " publish=" & hooksB.stats.lastPublishReason & traceOf(second))
    check hooksB.stats.strongMisses > missesBefore
    check hooksB.stats.hits == hitsBefore           # no false hit
    check rebuilt.status == asSucceeded
    check rebuilt.launched
    check execProcess(wsB / "out" / "hello").strip() == "hello from config v2"
    check hooksB.stats.publishes == 1

    # Two selectors under ONE weak fingerprint on B; A's is byte-identical.
    let selectorsB = storageB.memo.listSelectors(weak)
    check selectorsB.len == 2
    check selectorA in selectorsB
    var selectorBOwn: MemoSelector
    for sel in selectorsB:
      if sel != selectorA:
        selectorBOwn = sel
    check selectorBOwn.strongFingerprint != selectorA.strongFingerprint
    check storageB.memo.readMemoEntryBytes(weak,
      selectorA.strongFingerprint).get() == encodeMemoEntry(entryA)
    # A's own store still holds exactly its one entry.
    let storageA = openPeerCacheStorage(cacheA)
    check storageA.memo.listSelectors(weak) == @[selectorA]

    # Both nodes serve their selector sets over TCP to a third party.
    if profile == tpHardened:
      let queryLeaf = mintLeaf(nodeQ.identity, lrDaemon)
      queryClient = newPeerCacheClient(nodeQ.identity.hostId, 0'u16,
        newPeerRegistry(nodeQ.identity.hostId,
          initEndpoint("127.0.0.1", Port(0))),
        @[initEndpoint("127.0.0.1", portA),
          initEndpoint("127.0.0.1", hostB.actualPort)],
        @[parseCidrV4("127.0.0.0/8")], trustMode = tmTls,
        ourCert = queryLeaf.cert,
        trustAnchorSet = loadTrustAnchorDir(nodeQ.anchorsDir))
      queryClient.leafProvider = proc(): LeafCredential {.gcsafe.} =
        queryLeaf
      queryClient.requireShortLivedLeaves = true
      waitFor queryClient.start()
    else:
      # Trusted (the default profile): the third party is a trusted node
      # presenting its pinned long-lived host key.
      hostQ = startPeerCacheHost(tlsConfig(nodeQ,
        seeds = @[initEndpoint("127.0.0.1", portA),
                  initEndpoint("127.0.0.1", hostB.actualPort)],
        profile = tpTrusted), nodeQ.identity.hostId,
        cacheRoot = base / "node-q-cache")
      queryClient = hostQ.client
    check queryClient.connectedPeers().len == 2
    var servedCounts: seq[int] = @[]
    for peerId in queryClient.connectedPeers():
      let answer = waitFor queryClient.requestSelectorsFrom(peerId, weak)
      check answer.isSome
      if answer.isSome:
        check selectorA in answer.get()
        servedCounts.add(answer.get().len)
    servedCounts.sort()
    check servedCounts == @[1, 2]

    # ---- (4) revert: the original execution is served again ------------
    sleep(20)
    writeFile(wsB / "config.h", ConfigV1)
    let third = runBuild(helloGraph(wsB), configB)
    let again = third.byId(ActionId)
    checkpoint("third B build: status=" & $again.status & " reason=" &
      again.reason & traceOf(third))
    check again.cacheDecision in {cdHit, cdHybridCutoff}
    check not again.launched
    check execProcess(wsB / "out" / "hello").strip() == "hello from config v1"

    # ---- no markSuspect false positives, and A really served -------------
    check hostB.client.suspectMarks == 0
    check queryClient.suspectMarks == 0
    check not hostB.registry.entries[peerA].suspect
    # A writes its counters on its store-scan interval; give it a moment.
    var statusA = readStatus(stateA)
    let statusDeadline = epochTime() + 10.0
    while (statusInt(statusA, "memo_requests_served") < 3 or
        statusInt(statusA, "fetch_hits_served") < 2) and
        epochTime() < statusDeadline:
      sleep(50)
      statusA = readStatus(stateA)
    checkpoint("node A status: " & $statusA)
    check statusInt(statusA, "memo_requests_served") >= 3
    check statusInt(statusA, "fetch_hits_served") >= 2
    result = true

suite "Distributed-Execution M0: two-phase peer cache over real LAN sockets":

  test "t_peer_cache_two_phase_lan_roundtrip":
    # Hardened nodes (one-hour host-CA leaves).
    check runTwoPhaseRoundtrip(tpHardened)

  test "t_peer_cache_two_phase_lan_roundtrip (trusted profile, the default)":
    # Trusted nodes (pinned long-lived host keys) — the product default.
    check runTwoPhaseRoundtrip(tpTrusted)

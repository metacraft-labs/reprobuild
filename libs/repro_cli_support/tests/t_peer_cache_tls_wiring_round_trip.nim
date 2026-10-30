## `--peer-cache=lan://…?tls=1` is honoured by the peer-cache nodes the CLI
## and `repro daemon serve` start (reprobuild-pm issue
## 2026-10-16-peer-cache-runtime-ignores-tls-trust-mode).
##
## Each node is configured exactly the way the CLI configures one:
## `parsePeerCache` on a `lan://…?tls=1` spec (certificate, key and anchor
## paths under `$XDG_STATE_HOME/repro-peer-cache/tls/`), then
## `startPeerCacheHost` — the constructor `startPeerCacheServices`,
## `buildPeerCacheWiringFor` and the daemon's background service all use.
##
##   * a node mints its HOST CA on first use (Distributed-Execution M7:
##     the persistent credential is the per-host CA; the wire carries a
##     short-lived leaf it mints, `identity.nim`);
##   * two nodes that trust each other's host CA complete a BearSSL TLS
##     1.2 mutual-auth handshake plus the leaf identity proof, and a real
##     build on one is served to the other through the two-phase lookup
##     INSIDE the tunnel (memo requests, an attested memo entry, and
##     BLAKE3-verified blob fetches);
##   * the nodes bind the declared interface — loopback, as none is
##     declared — never a wildcard (FLOW-6);
##   * a third node whose certificate is not in the producer's anchors is
##     refused at the handshake and gets nothing;
##   * a TLS spec with no trust anchors refuses to start rather than falling
##     back to CIDR-only trust.
##
## The built edge is MONITORED by the engine's io-monitor (owner decision
## 2026-10-29, Edge-Derived-Identities.md §3.4 item 1 rider: only a monitored
## or builtin record crosses hosts; until then it was evidenced by a make
## depfile it wrote, which the engine now keeps local). On a platform where
## io-mon cannot prove detached-descendant quiescence (`NoTreeLifetimeGuard`,
## macOS) no monitored edge is published, so the build round trip is skipped
## there with that reason.
##
## MOCK POLICY — none: real loopback sockets, real BearSSL, real
## certificates on disk, the real build engine and disk stores.

import std/[asyncdispatch, os, strutils, tables, tempfiles, unittest]

import repro_build_engine
import repro_cli_support
import repro_cli_support/peer_cache_wiring
import repro_hash
import repro_local_store
import repro_peer_cache
import repro_test_support/reasoned_skip
from repro_test_support import prepareMonitorTools, ReprobuildRepoRoot
from repro_test_support/descendant_guard_expectations import
  NoTreeLifetimeGuard

proc tlsConfigFor(stateHome: string; seeds = ""): PeerCacheConfig =
  ## The CLI's own parse of a `?tls=1` spec, with the node's state home.
  let previous = getEnv("XDG_STATE_HOME")
  putEnv("XDG_STATE_HOME", stateHome)
  defer: putEnv("XDG_STATE_HOME", previous)
  var spec = "lan://127.0.0.0/8?multicast=0&tls=1"
  if seeds.len > 0:
    spec.add("&seeds=" & seeds)
  let parsed = parsePeerCache(spec)
  doAssert parsed.ok and parsed.kind == pcsLan
  doAssert parsed.config.trustMode == tmTls
  parsed.config

proc trust(config: PeerCacheConfig; other: PeerCacheConfig; name: string) =
  ## Put `other`'s certificate in `config`'s anchor directory.
  createDir(config.tlsTrustAnchorsPath)
  copyFile(other.tlsCertPath, config.tlsTrustAnchorsPath / (name & ".crt"))

proc copyAction(ws: string): BuildGraph =
  createDir(ws / "out")
  graph([action("tls-copy",
    ["/bin/sh", "-c", "cat in.txt > out/o.txt"],
    cwd = ws,
    inputs = ["in.txt"],
    outputs = [ws / "out" / "o.txt"],
    cacheable = true,
    weakFingerprint = weakFingerprintFromText("t-peer-cache-tls-wiring"),
    actionCachePolicy = ffpChecksum,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())])

proc engineConfig(cacheRoot, ws: string;
                  hooks: PeerCacheEngineHooks): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.bypassRunQuota = true
  result.maxParallelism = 1'u32
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.portableRoots = @[LogicalRoot(label: "project", path: ws,
    kind: lrkTracked)]
  # The engine's own io-monitor over the launch (the graph-built `repro`
  # driver and monitor shim), through the direct RunQuota-bypass path.
  let tools = prepareMonitorTools(ReprobuildRepoRoot, getTempDir(),
    "tls-wiring")
  putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
  result.runQuotaCliPath = tools.monitorCliPath
  result.monitorCliPath = tools.monitorCliPath
  result.monitorCliArgs = tools.monitorCliArgs
  wireEngineConfig(result, hooks, ws)

proc nodeId(tag: char): PeerId =
  var raw: array[32, byte]
  raw[0] = byte(ord(tag))
  peerIdFromBytes(raw)

suite "peer-cache TLS through the CLI/daemon wiring":

  test "a ?tls=1 node with no trust anchors refuses to start":
    let base = createTempDir("m0-tls-noanchor-", "")
    defer: removeDir(base)
    let config = tlsConfigFor(base / "lonely")
    expect CatchableError:
      discard startPeerCacheHost(config, nodeId('L'), cacheRoot = base / "c")
    # The certificate was minted on the way (first start), the key beside it.
    check fileExists(config.tlsCertPath)
    check fileExists(config.tlsKeyPath)

  test "two trusting nodes serve a build over TLS; a stranger is refused":
    if NoTreeLifetimeGuard:
      skip("io-mon cannot prove detached-descendant quiescence on this " &
        "platform, so every monitored capture fails closed and no monitored " &
        "edge is published; since the owner decision of 2026-10-29 a " &
        "depfile-evidenced edge does not cross hosts either " &
        "(Edge-Derived-Identities.md §3.4 item 1 rider), so this build has " &
        "nothing to exchange here")
    else:
      let base = createTempDir("m0-tls-", "")
      var hosts: seq[PeerCacheHost] = @[]
      defer:
        for host in hosts:
          host.stop()
        removeDir(base)
      let cfgA0 = tlsConfigFor(base / "a")
      let cfgB0 = tlsConfigFor(base / "b")
      let cfgC0 = tlsConfigFor(base / "c")
      for cfg in [cfgA0, cfgB0, cfgC0]:
        discard loadOrCreateHostIdentity(cfg.tlsCertPath, cfg.tlsKeyPath)
      cfgA0.trust(cfgB0, "b")
      cfgB0.trust(cfgA0, "a")
      cfgC0.trust(cfgA0, "a")       # C trusts A, but A does not trust C

      let hostA = startPeerCacheHost(cfgA0, nodeId('A'),
        cacheRoot = base / "a-cache")
      hosts.add(hostA)
      check hostA.server.trustMode == tmTls
      check hostA.server.listenAddr == "127.0.0.1"   # declared: loopback
      let seedA = "127.0.0.1:" & $int(hostA.actualPort)
      let hostB = startPeerCacheHost(tlsConfigFor(base / "b", seedA),
        nodeId('B'), cacheRoot = base / "b-cache")
      hosts.add(hostB)
      # The identity is the certificate's, not the caller-supplied id.
      check hostA.selfPeerId == derivePeerIdFromPublicKey(
        loadCertAndKey(cfgA0.tlsCertPath, cfgA0.tlsKeyPath).keypair.publicKey)
      check hostB.client.tlsConnsByPeerId.hasKey(hostA.selfPeerId)
      check hostB.client.connections.len == 0      # no plaintext connection

      # Producer A builds and publishes.
      let wsA = base / "ws-a"
      let wsB = base / "ws-b"
      for ws in [wsA, wsB]:
        createDir(ws)
        writeFile(ws / "in.txt", "over tls\n")
      let hooksA = newPeerCacheEngineHooks(hostA.client,
        openPeerCacheStorage(base / "a-cache"), hostA.registry,
        hostA.attestorFor())
      let built = runBuild(copyAction(wsA),
        engineConfig(base / "a-cache", wsA, hooksA))
      checkpoint("producer: " & built.results[0].reason & " " &
        built.results[0].stderr)
      check built.results[0].status == asSucceeded
      check hooksA.stats.publishes == 1

      # Consumer B gets it through the tunnel.
      let hooksB = newPeerCacheEngineHooks(hostB.client,
        openPeerCacheStorage(base / "b-cache"), hostB.registry,
        hostB.attestorFor())
      let fetched = runBuild(copyAction(wsB),
        engineConfig(base / "b-cache", wsB, hooksB))
      checkpoint("fetch: " & hooksB.stats.lastFetchReason & " install: " &
        hooksB.stats.lastInstallReason)
      check hooksB.stats.hits == 1
      check fetched.results[0].cacheDecision == cdHit
      check not fetched.results[0].launched
      check readFile(wsB / "out" / "o.txt") == "over tls\n"
      check hostB.client.memoRoundTripCount >= 2
      check hostB.client.fetchRoundTripCount >= 2
      check hostB.client.suspectMarks == 0
      check hostA.server.memoRequestsServed >= 2
      check hostA.server.tlsHandshakeRejectedCount == 0

      # Stranger C: its certificate is not among A's anchors.
      let hostC = startPeerCacheHost(tlsConfigFor(base / "c", seedA),
        nodeId('C'), cacheRoot = base / "c-cache")
      hosts.add(hostC)
      for _ in 0 ..< 40:
        if hostA.server.tlsHandshakeRejectedCount > 0: break
        hostA.tick(25)
      check hostA.server.tlsHandshakeRejectedCount >= 1
      check not hostC.client.isConnected(hostA.selfPeerId)
      check (waitFor hostC.client.requestSelectors(
        blobDigestFromBytes(weakFingerprintFromText("x").bytes))).len == 0

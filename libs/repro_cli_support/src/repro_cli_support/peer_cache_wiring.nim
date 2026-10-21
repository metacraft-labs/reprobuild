## Peer-cache wiring for builds and for `repro-daemon` — Distributed-Execution
## M0 (Catches #2 and #3).
##
## Two things live here, both shared by the CLI (`repro_cli_support.nim`) and
## the M0 verification tests so the tests drive the production wiring rather
## than a copy of it:
##
## * `PeerCacheStorage` + `newPeerCacheEngineHooks` — the engine closures
##   (`PeerCacheActionFetcher` / `Publisher` / `BundleInstaller`) backed by
##   the REAL disk stores: the build's CAS (`<action-cache-root>/cas`) is the
##   content plane, `<action-cache-root>/peer-memo` the memoization plane. The
##   fetcher runs the two-phase lookup of `repro_peer_cache/two_phase.nim`;
##   nothing here keeps state only in memory, so whatever a build publishes
##   is servable by any process that opens the same root.
##
## * `PeerCacheHost` — the long-lived node: `PeerCacheServer` bound on
##   `0.0.0.0` (LAN) with its readers wired to the disk stores,
##   `PeerCacheClient`, multicast/seed membership, advertisement refresh. A
##   transient CLI build starts one for its own lifetime; `repro-daemon`
##   hosts one for ITS lifetime (`daemonPeerCacheService` in
##   `repro_cli_support.nim`), which is what keeps artifacts servable after
##   the CLI that built them exits.
##
## Daemon-hosted builds run in a forked worker (POSIX). The worker inherits
## the host object; `releaseInheritedHost` drops the worker's copies of the
## host's descriptors and gives it a fresh async dispatcher, and the worker's
## build talks to peers through its own short-lived client seeded with the
## host's membership view. What the worker publishes lands on disk; the
## parent's host picks the root up through a registration file and serves it.

import std/[asyncdispatch, nativesockets, options, os, sets, strutils, tables,
            times]

import repro_build_engine
import repro_cas_store
import repro_hash
import repro_local_store
import repro_peer_cache

const
  PeerMemoDirName* = "peer-memo"
    ## Memo store directory under an action-cache root.
  PeerCacheRootsDirName* = "peer-cache-roots"
    ## Under a daemon state dir: one file per action-cache root the daemon's
    ## host must serve (written by build workers, read by the host).
  PeerCacheEndpointFileName* = "peer-cache-endpoint"
    ## Under a daemon state dir: `host:port` the host's server is bound to.
  PeerCacheStatusFileName* = "peer-cache.status"
    ## Under a daemon state dir: `key=value` counters, for inspection.
  DefaultStoreScanIntervalMs = 250
  DefaultMembershipIntervalMs = 1_000
  SeedDialBudgetMs = 3_000
    ## How long starting a node (or a build worker's client) waits for its
    ## seed dials before going on.

type
  PeerCacheTlsIdentity* = object
    ## What a `tmTls` node needs: its own certificate and key, and the trust
    ## anchors its peers' certificates must be among.
    cert*: CertAndKey
    anchors*: TrustAnchorSet

  PeerCacheStorage* = ref object
    ## The disk-backed stores of one action-cache root.
    root*: string
    casView*: CasStore
      ## Read-only view (`openCasStoreReadOnly`): serving reads never opens
      ## the SQLite index, so a daemon can hold this across forks.
    memo*: PeerMemoStore

  PeerCacheWiringStats* = ref object
    ## Per-build counters of the engine hooks, for diagnostics and tests.
    fetches*: int
    hits*: int
    misses*: int
    strongMisses*: int
    installs*: int
    installFailures*: int
    publishes*: int
    publishSkips*: int
    lastFetchReason*: string
    lastPublishReason*: string
    lastInstallReason*: string

  PeerCacheEngineHooks* = object
    fetcher*: PeerCacheActionFetcher
    publisher*: PeerCacheActionPublisher
    installer*: PeerCacheActionBundleInstaller
    stats*: PeerCacheWiringStats

  PeerCacheHost* = ref object
    ## A long-lived peer-cache node (see the module doc).
    config*: PeerCacheConfig
    selfPeerId*: PeerId
    storages*: seq[PeerCacheStorage]
      ## Every action-cache root this node serves. The first is the one it
      ## was started with; daemon-hosted builds register more.
    registry*: PeerRegistry
    server*: PeerCacheServer
    client*: PeerCacheClient
    ownerPid*: int
      ## Process that started the host. A different `getCurrentProcessId()`
      ## means we are in a forked child and must not touch the sockets.
    stateDir*: string
      ## Daemon state dir (empty for a CLI-owned host): where the endpoint
      ## and status files and the root registrations live.
    listenAddr*: string
    tls*: PeerCacheTlsIdentity
      ## Set when `config.trustMode == tmTls`.
    lastStoreScanMs: int64
    lastMembershipMs: int64
    lastStatus: string
    membershipRound: Future[int]
    refreshRound: Future[int]
    running*: bool

var inheritedParentDispatchers: seq[PDispatcher]
  ## Dispatchers a forked child replaced. Kept alive ON PURPOSE and never
  ## destroyed: the parent's dispatcher wraps a kqueue/epoll descriptor whose
  ## number may already be reused in the child, and its destructor would
  ## close whatever descriptor now carries that number.

proc nowMs(): int64 =
  int64(epochTime() * 1000.0)

# ---------------------------------------------------------------------------
# Storage.
# ---------------------------------------------------------------------------

proc openPeerCacheStorage*(root: string): PeerCacheStorage =
  ## The stores of action-cache root `root` (the directory the engine opens
  ## its CAS on — `BuildEngineConfig.actionCacheRoot`, or `cacheRoot` when
  ## that is empty).
  PeerCacheStorage(root: root,
                   casView: openCasStoreReadOnly(root),
                   memo: openPeerMemoStore(root / PeerMemoDirName))

proc readBlob*(storage: PeerCacheStorage;
               digest: BlobDigest): Option[seq[byte]] =
  ## A CAS blob by BLAKE3-256 digest, verified on read (`casGet`), or
  ## `none`. Never raises.
  try:
    let hash = toContentHash(bytes(digest))
    if not storage.casView.casExists(hash):
      return none(seq[byte])
    some(storage.casView.casGet(hash))
  except CatchableError:
    none(seq[byte])

proc readBlobFrom*(storages: seq[PeerCacheStorage];
                   digest: BlobDigest): Option[seq[byte]] =
  for storage in storages:
    let found = storage.readBlob(digest)
    if found.isSome:
      return found
  none(seq[byte])

proc localReaderFor*(storages: seq[PeerCacheStorage]): LocalStoreReader =
  let captured = storages
  result = proc(digest: BlobDigest): Option[seq[byte]] {.gcsafe.} =
    {.cast(gcsafe).}:
      readBlobFrom(captured, digest)

proc selectorReaderFor*(host: PeerCacheHost): MemoSelectorReader =
  let h = host
  result = proc(weak: BlobDigest): seq[MemoSelector] {.gcsafe.} =
    {.cast(gcsafe).}:
      for storage in h.storages:
        for sel in storage.memo.listSelectors(weak):
          if sel notin result:
            result.add(sel)

proc entryReaderFor*(host: PeerCacheHost): MemoEntryReader =
  let h = host
  result = proc(weak, strong: BlobDigest): Option[seq[byte]] {.gcsafe.} =
    {.cast(gcsafe).}:
      for storage in h.storages:
        let found = storage.memo.readMemoEntryBytes(weak, strong)
        if found.isSome:
          return found
      none(seq[byte])

proc advertiseStorage*(registry: PeerRegistry;
                       storage: PeerCacheStorage): int =
  ## Adds every key `storage` backs to `registry`'s self-advertised set.
  ## Returns how many were new (the sequence number only moves for those).
  if registry.isNil:
    return 0
  for key in storage.memo.advertisedKeys():
    if key notin registry.selfAdvertised:
      registry.selfAddBlob(key)
      inc result

# ---------------------------------------------------------------------------
# Engine hooks.
# ---------------------------------------------------------------------------

proc twoPhaseContextOf*(query: PeerCacheActionQuery): TwoPhaseContext =
  TwoPhaseContext(peerKey: blobDigestFromBytes(query.peerKey),
                  cwd: query.cwd,
                  workspaceRoot: query.workspaceRoot,
                  portable: query.portable)

proc newPeerCacheEngineHooks*(client: PeerCacheClient;
                              storage: PeerCacheStorage;
                              registry: PeerRegistry = nil):
                              PeerCacheEngineHooks =
  ## Engine closures over a peer-cache client and one disk storage.
  ##
  ## * fetcher — Steps 1–4 of the two-phase lookup against the client's
  ##   peers; PathSet and output blobs are read from the local CAS first.
  ##   Blocks on the async client (`waitFor`), which also lets a co-hosted
  ##   server answer peers while the build waits.
  ## * installer — `installTwoPhaseBundle` into the engine's own CAS and
  ##   action cache, then re-publishes the fetched memo entry into this
  ##   root's memo store so this node serves it onward.
  ## * publisher — `publishTwoPhase` into this root's memo store and the
  ##   engine's CAS.
  ##
  ## `registry`, when given, learns every newly published/installed key at
  ## once so a co-hosted server advertises it without waiting for a scan.
  ## Every closure is soft-fail: a peer-cache problem degrades to a miss or
  ## an unpublished result, never to a failed build.
  let stats = PeerCacheWiringStats()
  result.stats = stats
  let c = client
  let st = storage
  let reg = registry
  result.fetcher = proc(query: PeerCacheActionQuery): Option[seq[byte]]
      {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      inc stats.fetches
      if c.isNil:
        inc stats.misses
        stats.lastFetchReason = "no peer-cache client"
        return none(seq[byte])
      try:
        let outcome = waitFor fetchTwoPhase(c, twoPhaseContextOf(query),
          localReaderFor(@[st]))
        stats.strongMisses += outcome.strongMisses
        if outcome.hit:
          inc stats.hits
          stats.lastFetchReason = ""
          return some(encodeTwoPhaseBundle(outcome.bundle))
        inc stats.misses
        stats.lastFetchReason = outcome.reason
      except CatchableError as err:
        inc stats.misses
        stats.lastFetchReason = "peer-cache fetch failed: " & err.msg
      none(seq[byte])
  result.installer = proc(query: PeerCacheActionQuery; bundleBytes: seq[byte];
                          engineCas: var CasStore; engineCache: ptr ActionCache):
                          tuple[ok: bool; reason: string] {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      let bundle =
        try:
          decodeTwoPhaseBundle(bundleBytes)
        except CatchableError as err:
          inc stats.installFailures
          stats.lastInstallReason = "decode failed: " & err.msg
          return (false, stats.lastInstallReason)
      let ctx = twoPhaseContextOf(query)
      let installed = installTwoPhaseBundle(engineCas, engineCache[], bundle,
        query.weakFingerprint, query.policy, ctx)
      if not installed.ok:
        inc stats.installFailures
        stats.lastInstallReason = installed.reason
        return installed
      inc stats.installs
      stats.lastInstallReason = ""
      try:
        for key in republishInstalled(st.memo, engineCas, bundle):
          if not reg.isNil and key notin reg.selfAdvertised:
            reg.selfAddBlob(key)
      except CatchableError:
        discard
      installed
  result.publisher = proc(query: PeerCacheActionQuery;
                          record: ActionResultRecord;
                          engineCas: var CasStore) {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      try:
        let outcome = publishTwoPhase(st.memo, engineCas, record,
          twoPhaseContextOf(query))
        if not outcome.published:
          inc stats.publishSkips
          stats.lastPublishReason = outcome.reason
          return
        inc stats.publishes
        stats.lastPublishReason = ""
        if not reg.isNil:
          for key in outcome.advertKeys:
            if key notin reg.selfAdvertised:
              reg.selfAddBlob(key)
      except CatchableError as err:
        inc stats.publishSkips
        stats.lastPublishReason = "peer-cache publish failed: " & err.msg

proc peerCacheSummaryLine*(stats: PeerCacheWiringStats): string =
  ## One line for the build log when a peer cache was attached.
  if stats.isNil:
    return ""
  "peerCache: fetches=" & $stats.fetches & " hits=" & $stats.hits &
    " misses=" & $stats.misses & " strongMisses=" & $stats.strongMisses &
    " installs=" & $stats.installs & " installFailures=" &
    $stats.installFailures & " publishes=" & $stats.publishes &
    " publishSkips=" & $stats.publishSkips

proc wireEngineConfig*(config: var BuildEngineConfig;
                       hooks: PeerCacheEngineHooks;
                       workspaceRoot: string) =
  ## Attaches `hooks` to an engine configuration and keeps output payloads
  ## in the CAS (the publisher serves them by digest).
  config.peerCacheActionFetcher = hooks.fetcher
  config.peerCacheActionPublisher = hooks.publisher
  config.peerCacheActionInstaller = hooks.installer
  config.peerCacheWorkspaceRoot = workspaceRoot

# ---------------------------------------------------------------------------
# Long-lived host.
# ---------------------------------------------------------------------------

proc ensurePeerCacheTlsCert*(config: PeerCacheConfig): CertAndKey =
  ## This node's TLS certificate: loaded from `config.tlsCertPath` /
  ## `tlsKeyPath`, or — on first start, when neither file exists — a fresh
  ## self-signed ECDSA-P256 certificate (`pki.generateSelfSignedCert`, valid
  ## `config.tlsCertValidityDays`, default 365) written there. The
  ## certificate's subject is the peer id derived from its public key, the
  ## same identity the trust-anchor directory keys peers by. A half-present
  ## pair (cert without key or the reverse) is refused rather than
  ## overwritten.
  if config.tlsCertPath.len == 0 or config.tlsKeyPath.len == 0:
    raise newException(ValueError,
      "peer-cache TLS needs a certificate and key path")
  let haveCert = fileExists(config.tlsCertPath)
  let haveKey = fileExists(config.tlsKeyPath)
  if haveCert and haveKey:
    return loadCertAndKey(config.tlsCertPath, config.tlsKeyPath)
  if haveCert != haveKey:
    raise newException(ValueError,
      "peer-cache TLS: found only one of " & config.tlsCertPath & " and " &
      config.tlsKeyPath & "; refusing to replace it")
  let keypair = generateKeypair()
  let days =
    if config.tlsCertValidityDays > 0: config.tlsCertValidityDays else: 365
  result = generateSelfSignedCert(keypair,
    subjectCn = $derivePeerIdFromPublicKey(keypair.publicKey),
    validityDays = days)
  createDir(config.tlsCertPath.parentDir)
  createDir(config.tlsKeyPath.parentDir)
  writeCertAndKey(result, config.tlsCertPath, config.tlsKeyPath)

proc loadPeerCacheTlsIdentity*(config: PeerCacheConfig): PeerCacheTlsIdentity =
  ## Certificate (see `ensurePeerCacheTlsCert`) plus the anchor directory
  ## `config.tlsTrustAnchorsPath`. A node with NO anchors could talk to no
  ## one, and silently falling back to CIDR-only trust is exactly what
  ## `?tls=1` exists to prevent, so a missing or empty anchor directory is
  ## an error naming it.
  result.cert = ensurePeerCacheTlsCert(config)
  if config.tlsTrustAnchorsPath.len == 0:
    raise newException(ValueError, "peer-cache TLS needs a trust-anchor directory")
  result.anchors = loadTrustAnchorDir(config.tlsTrustAnchorsPath)
  if result.anchors.byPeerId.len == 0:
    raise newException(ValueError,
      "peer-cache TLS trust-anchor directory has no certificates: " &
      config.tlsTrustAnchorsPath & " (copy each peer's .crt there)")

proc tlsPeerIdOf*(identity: PeerCacheTlsIdentity): PeerId =
  derivePeerIdFromPublicKey(identity.cert.keypair.publicKey)

proc allowlistOf(config: PeerCacheConfig): seq[CidrV4] =
  for cidr in config.cidrAllowlistRaw:
    result.add(parseCidrV4(cidr))

proc addStorage*(host: PeerCacheHost; root: string): bool {.discardable.} =
  ## Starts serving action-cache root `root` (idempotent). Returns `true`
  ## when the root was new.
  let normalized = normalizedPath(absolutePath(root))
  for storage in host.storages:
    if storage.root == normalized:
      return false
  let storage = openPeerCacheStorage(normalized)
  host.storages.add(storage)
  discard advertiseStorage(host.registry, storage)
  true

proc rootRegistrationPath(stateDir, root: string): string =
  ## One file per root, named by the BLAKE3 of the normalized path.
  let normalized = normalizedPath(absolutePath(root))
  stateDir / PeerCacheRootsDirName /
    ($digestOf(normalized.toOpenArrayByte(0, normalized.high)) & ".root")

proc registerServedRoot*(stateDir, root: string) =
  ## Asks the daemon whose state dir is `stateDir` to serve action-cache
  ## root `root` too. Written by daemon-hosted build workers (separate
  ## processes after the fork), read by the host's store scan. Atomic.
  if stateDir.len == 0 or root.len == 0:
    return
  let path = rootRegistrationPath(stateDir, root)
  createDir(path.parentDir)
  let tmp = path & ".tmp." & $getCurrentProcessId()
  writeFile(tmp, normalizedPath(absolutePath(root)) & "\n")
  moveFile(tmp, path)

proc scanRegisteredRoots(host: PeerCacheHost) =
  if host.stateDir.len == 0:
    return
  let dir = host.stateDir / PeerCacheRootsDirName
  if not dirExists(dir):
    return
  for kind, path in walkDir(dir):
    if kind != pcFile or not path.endsWith(".root"):
      continue
    try:
      let root = readFile(path).strip()
      if root.len > 0 and dirExists(root):
        host.addStorage(root)
    except CatchableError:
      discard

proc writeStatus(host: PeerCacheHost) =
  if host.stateDir.len == 0:
    return
  var lines = @[
    "peer_id=" & $host.selfPeerId,
    "trust=" & (if host.config.trustMode == tmTls: "tls" else: "cidr"),
    "listen=" & host.listenAddr & ":" & $int(host.server.actualPort),
    "peers_known=" & $host.registry.peerCount(),
    "peers_connected=" & $host.client.connectedPeers().len,
    "advertised_keys=" & $host.registry.selfAdvertised.len,
    "memo_requests_served=" & $host.server.memoRequestsServed]
  if not host.server.metrics.isNil:
    lines.add("fetch_requests_served=" & $host.server.metrics.fetchRequestsTotal)
    lines.add("fetch_hits_served=" & $host.server.metrics.fetchHitsLocal)
  for storage in host.storages:
    lines.add("root=" & storage.root)
  let text = lines.join("\n") & "\n"
  if text == host.lastStatus:
    return
  host.lastStatus = text
  try:
    let path = host.stateDir / PeerCacheStatusFileName
    let tmp = path & ".tmp"
    writeFile(tmp, text)
    moveFile(tmp, path)
  except CatchableError:
    discard

proc startPeerCacheHost*(config: PeerCacheConfig; selfPeerId: PeerId;
                         cacheRoot: string; listenAddr = "0.0.0.0";
                         stateDir = ""): PeerCacheHost =
  ## Boots a peer-cache node serving `cacheRoot`: server bound on
  ## `listenAddr:config.listenPort` (0 = ephemeral) with its content and
  ## memo readers on the disk stores, multicast receiver/broadcaster unless
  ## disabled, and a client dialled to the configured seeds. Raises on a
  ## bind failure; a seed that does not answer is simply not connected yet
  ## (the membership loop in `tick` keeps trying).
  result = PeerCacheHost(config: config, selfPeerId: selfPeerId,
    ownerPid: getCurrentProcessId(), stateDir: stateDir,
    listenAddr: listenAddr, running: true)
  if config.trustMode == tmTls:
    # `?tls=1`: BearSSL TLS 1.2 mutual auth on every accept and dial
    # (Peer-Cache-BearSSL.md). The node's identity is its certificate's.
    result.tls = loadPeerCacheTlsIdentity(config)
    result.selfPeerId = tlsPeerIdOf(result.tls)
  let selfPeerId = result.selfPeerId
  result.registry = newPeerRegistry(selfPeerId,
    initEndpoint(listenAddr, Port(config.listenPort)))
  let allowlist = allowlistOf(config)
  let maxBlob =
    if config.maxBlobBytes > 0: config.maxBlobBytes else: DefaultMaxBlobBytes
  result.server = newPeerCacheServer(
    selfPeerId = selfPeerId,
    listenAddr = listenAddr,
    listenPort = Port(config.listenPort),
    registry = result.registry,
    cidrAllowlist = allowlist,
    maxBlobBytes = maxBlob,
    trustMode = config.trustMode,
    ourCert = result.tls.cert,
    trustAnchorSet = result.tls.anchors,
    metrics = newPeerCacheMetrics())
  if cacheRoot.len > 0:
    result.addStorage(cacheRoot)
  let host = result
  result.server.localStoreReader = proc(digest: BlobDigest): Option[seq[byte]]
      {.gcsafe.} =
    {.cast(gcsafe).}:
      readBlobFrom(host.storages, digest)
  result.server.memoSelectorReader = selectorReaderFor(result)
  result.server.memoEntryReader = entryReaderFor(result)
  result.server.start()
  let useMulticast =
    config.discoveryMode == pdmMulticast and not config.multicastDisabled
  if useMulticast:
    result.server.multicastListen(config.multicastGroup)
  result.client = newPeerCacheClient(
    selfPeerId = selfPeerId,
    listenPort = uint16(result.server.actualPort),
    registry = result.registry,
    seedPeers = config.seedPeers,
    cidrAllowlist = allowlist,
    advertiseIntervalMs =
      if config.advertiseIntervalMs > 0: config.advertiseIntervalMs
      else: DefaultAdvertiseIntervalMs,
    trustMode = config.trustMode,
    ourCert = result.tls.cert,
    trustAnchorSet = result.tls.anchors)
  if useMulticast:
    result.client.multicastBroadcast(config.multicastGroup)
  # Bounded: a seed that is down can hold a TCP connect for over a minute,
  # and a daemon must not take that long to start. A dial still in flight
  # completes in the background; the membership loop re-dials the rest.
  discard waitFor withTimeout(result.client.start(), SeedDialBudgetMs)
  result.scanRegisteredRoots()
  result.lastStoreScanMs = nowMs()
  result.lastMembershipMs = nowMs()
  if stateDir.len > 0:
    createDir(stateDir)
    let endpointPath = stateDir / PeerCacheEndpointFileName
    let tmp = endpointPath & ".tmp"
    writeFile(tmp, listenAddr & ":" & $int(result.server.actualPort) & "\n")
    moveFile(tmp, endpointPath)
    result.writeStatus()

proc actualPort*(host: PeerCacheHost): Port =
  host.server.actualPort

proc isForkedChild*(host: PeerCacheHost): bool =
  not host.isNil and host.ownerPid != getCurrentProcessId()

proc pump*(host: PeerCacheHost; maxWaitMs: int) =
  ## Drives the async dispatcher for at most `maxWaitMs`.
  if hasPendingOperations():
    try:
      poll(max(0, maxWaitMs))
    except ValueError:
      # "No handles or timers registered" — nothing to do.
      discard
  elif maxWaitMs > 0:
    sleep(maxWaitMs)

proc tick*(host: PeerCacheHost; maxWaitMs: int) =
  ## One service iteration: serve sockets for up to `maxWaitMs`, pick up
  ## newly published memo entries and registered roots, and on the
  ## membership interval dial newly discovered peers and refresh their
  ## advertisements.
  if host.isNil or not host.running or host.isForkedChild:
    return
  host.pump(maxWaitMs)
  let now = nowMs()
  if now - host.lastStoreScanMs >= DefaultStoreScanIntervalMs:
    host.lastStoreScanMs = now
    host.scanRegisteredRoots()
    for storage in host.storages:
      discard advertiseStorage(host.registry, storage)
    host.writeStatus()
  let membershipInterval =
    if host.config.advertiseIntervalMs > 0:
      min(host.config.advertiseIntervalMs, DefaultMembershipIntervalMs)
    else: DefaultMembershipIntervalMs
  if now - host.lastMembershipMs >= membershipInterval:
    host.lastMembershipMs = now
    # One round of each in flight at a time: a dial to an unresponsive peer
    # can outlast the interval, and overlapping rounds would open duplicate
    # connections to it.
    if host.membershipRound.isNil or host.membershipRound.finished:
      host.membershipRound = host.client.connectKnownPeers()
    if host.refreshRound.isNil or host.refreshRound.finished:
      host.refreshRound = host.client.requestAdvertisementRefresh()

proc stop*(host: PeerCacheHost) =
  ## Graceful shutdown (Goodbye to peers, sockets closed). Only in the
  ## owning process; a forked child uses `releaseInheritedHost`.
  if host.isNil or not host.running:
    return
  host.running = false
  if host.isForkedChild:
    return
  try:
    waitFor host.client.stop()
  except CatchableError:
    discard
  host.server.stop()
  if host.stateDir.len > 0:
    try: removeFile(host.stateDir / PeerCacheEndpointFileName)
    except CatchableError: discard

proc membershipEndpoints*(host: PeerCacheHost): seq[Endpoint] =
  ## The peers this host knows how to reach: registry entries with a listen
  ## port, plus configured seeds. A forked build worker seeds its own
  ## short-lived client with this.
  if host.isNil:
    return @[]
  for peerId, entry in host.registry.entries.pairs:
    if entry.endpoint.port != Port(0) and entry.endpoint notin result:
      result.add(entry.endpoint)
  for seed in host.config.seedPeers:
    if seed notin result:
      result.add(seed)

proc releaseInheritedHost*(host: PeerCacheHost) =
  ## In a forked child of the host's owner: close the child's copies of the
  ## host's descriptors without touching the parent's dispatcher, and give
  ## the child a fresh dispatcher (keeping the inherited one alive — see
  ## `inheritedParentDispatchers`). Idempotent; a no-op in the owner.
  if host.isNil or not host.isForkedChild or not host.running:
    return
  host.running = false
  host.server.abandonAfterFork()
  host.client.abandonAfterFork()
  inheritedParentDispatchers.add(getGlobalDispatcher())
  setGlobalDispatcher(newDispatcher())

proc startWorkerPeerCacheClient*(config: PeerCacheConfig;
                                 members: seq[Endpoint];
                                 selfPeerId: PeerId;
                                 daemonListenPort = 0'u16): PeerCacheClient =
  ## A short-lived client for one build in a daemon worker: no server (the
  ## daemon serves), dialled to `members` (the daemon's membership view)
  ## and returned once every dial has completed or failed.
  ##
  ## Under `tmTls` the worker presents the DAEMON's certificate (it is the
  ## daemon's process family and the peers' anchors trust exactly that), so
  ## its Hello carries the daemon's peer id and listen port: a peer that
  ## records it simply refreshes its entry for the daemon.
  var peerId = selfPeerId
  var listenPort = 0'u16
  var tlsIdentity: PeerCacheTlsIdentity
  if config.trustMode == tmTls:
    tlsIdentity = loadPeerCacheTlsIdentity(config)
    peerId = tlsPeerIdOf(tlsIdentity)
    listenPort = daemonListenPort
  let registry = newPeerRegistry(peerId, initEndpoint("0.0.0.0", Port(0)))
  result = newPeerCacheClient(
    selfPeerId = peerId,
    listenPort = listenPort,
    registry = registry,
    seedPeers = members,
    cidrAllowlist = allowlistOf(config),
    trustMode = config.trustMode,
    ourCert = tlsIdentity.cert,
    trustAnchorSet = tlsIdentity.anchors)
  discard waitFor withTimeout(result.start(), SeedDialBudgetMs)

proc stopPeerCacheClient*(client: PeerCacheClient) =
  if client.isNil:
    return
  try:
    waitFor client.stop()
  except CatchableError:
    discard

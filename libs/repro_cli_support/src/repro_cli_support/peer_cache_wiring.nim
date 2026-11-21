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
## * `PeerCacheHost` — the long-lived node: `PeerCacheServer` bound on the
##   interface the peer-cache policy DECLARES (`bind=`, loopback when none;
##   never a wildcard — Distributed-Execution M7, FLOW-6) with its readers
##   wired to the disk stores, `PeerCacheClient`, seed (and opt-in
##   multicast) membership, advertisement refresh. A transient CLI build
##   starts one for its own lifetime; `repro-daemon` hosts one for ITS
##   lifetime (`installUserDaemonPeerCacheService` in
##   `repro_cli_support.nim`), which is what keeps artifacts servable after
##   the CLI that built them exits.
##
## Distributed-Execution M7 made the node a Boundary in the sense of
## deployment-security-architecture.md:
##
## * a non-loopback listener requires `tls=1` (network adjacency is not
##   authorization) and an off-host evidence sink (`evidence=`); every frame
##   passes the receiver gate (`boundary.nim`) and is audited there;
## * under `tls=1` the persistent credential is a per-host CA and what goes
##   on the wire is a leaf of at most one hour, re-minted before expiry
##   (`identity.nim`, CRED-1/CRED-4);
## * memo entries are published attested by the node's leaf and accepted
##   only with a verified attestation (`memo_attestation.nim`);
## * detections and heartbeats go to the evidence sink (`evidence.nim`).
##
## Daemon-hosted builds run in a forked worker (POSIX). The worker inherits
## the host object; `releaseInheritedHost` drops the worker's copies of the
## host's descriptors and gives it a fresh async dispatcher, and the worker's
## build talks to peers through its own short-lived session
## (`startWorkerPeerCacheSession`). The daemon's private keys — its host CA
## and its `daemon` leaf, and every TLS connection's reference to them —
## live in `secret_key.SecretKey` pages that a forked child does not
## inherit (threat model G16), so the build worker never holds them, not
## even as a stale copy. What it presents instead is a `build-worker` leaf
## the DAEMON minted for its build workers ahead of the fork
## (`buildWorkerLeaf`, the only inheritable key), capped to the cache
## plane. What the worker publishes lands on disk; the parent's host picks
## the root up through a registration file and serves it.
##
## Revocation (threat model G17) is a file: `<tls dir>/revoked` (one host id
## per line) and the trust-anchor directory itself are re-read on change,
## within a store-scan interval; a revoked or un-anchored host is refused on
## its next frame, its memo attestations are refused, and this node drops
## its own connection to it.

import std/[algorithm, asyncdispatch, hashes, nativesockets, options, os, sets,
            strutils, tables, times]

import repro_build_engine
import repro_cas_store
import repro_hash
import repro_local_store
import repro_peer_cache

export netif
export identity

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
  LocalLogSweepIntervalMs* = 3_600_000'i64
    ## How often a node applies the EVID-6 age rules to its local logs
    ## (`evidence_record.sweepLocalLog`) — hourly; the first sweep runs at
    ## the first tick.
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
    bindResolution*: BindResolution
      ## How the declared interface resolved (FLOW-6).
    tls*: PeerCacheTlsIdentity
      ## Set when `config.trustMode == tmTls`: `cert` is the CURRENT leaf.
    identity*: HostIdentity
      ## The per-host CA (tmTls only). Held by the owning process; wiped in
      ## a forked build worker once it minted its own leaf.
    leaf*: LeafCredential
      ## The node's current `daemon` leaf, renewed in `tick`.
    appender*: EvidenceAppender
      ## The off-host evidence sink connection (nil without `evidence=`).
    auditLogPath*: string
      ## Loopback-only nodes without a sink keep audit lines here (in the
      ## daemon state dir), so the record is not lost entirely.
    grantsPath*: string
      ## The grants file the receiver gate's policy came from; re-read when
      ## it changes, so a withdrawn grant takes effect on the NEXT frame of
      ## an existing connection (FLOW-4 per message, not per peer).
    grantsStamp: string
    grantsVersion*: int
    revokedPath*: string
      ## `<tls dir>/revoked` (threat model G17).
    revokedStamp: string
    revocationVersion*: int
    anchorsStamp: string
    anchorsVersion*: int
    buildWorkerLeaf*: LeafCredential
      ## The `build-worker` leaf this daemon's forked build workers present
      ## (pre-minted, renewed in `tick`; the only inheritable private key —
      ## see the module doc).
    workerStatus*: proc(): seq[string] {.gcsafe, closure.}
      ## Set by the worker role: `key=value` lines (goals executed and
      ## refused, certificates issued and withheld) for the status file.
    localLogs*: seq[string]
      ## The local logs this node writes (trusted profile: detections and
      ## audit; the worker role adds its own) — swept for retention on a
      ## timer (`LocalLogSweepIntervalMs`), so a quiet node's old entries
      ## are deleted too (EVID-6).
    lastLogSweepMs: int64
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
                  portable: query.portable,
                  declaredInputs: query.declaredInputs)

proc newPeerCacheEngineHooks*(client: PeerCacheClient;
                              storage: PeerCacheStorage;
                              registry: PeerRegistry = nil;
                              attestor: LeafProvider = nil):
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
  ## `attestor` is the identity published entries are attested with
  ## (Distributed-Execution M7); without one nothing is published, because
  ## an unattested entry is one every consumer refuses.
  ## Every closure is soft-fail: a peer-cache problem degrades to a miss or
  ## an unpublished result, never to a failed build.
  let stats = PeerCacheWiringStats()
  result.stats = stats
  let c = client
  let st = storage
  let reg = registry
  let att = attestor
  result.fetcher = proc(query: PeerCacheActionQuery): Option[seq[byte]]
      {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      inc stats.fetches
      if c.isNil:
        inc stats.misses
        stats.lastFetchReason = "no peer-cache client"
        return none(seq[byte])
      try:
        let reportedBefore = c.detectionsReported
        let outcome = waitFor fetchTwoPhase(c, twoPhaseContextOf(query),
          localReaderFor(@[st]))
        if c.detectionsReported > reportedBefore:
          # DET-6: what the lookup detected leaves the host now, before the
          # engine goes back to synchronous work.
          c.flushDetections()
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
          twoPhaseContextOf(query), att, query.evidenceLevel,
          query.evidenceSource)
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
    " publishSkips=" & $stats.publishSkips &
    (if stats.misses > 0 and stats.lastFetchReason.len > 0:
       " lastMiss=\"" & stats.lastFetchReason & "\"" else: "") &
    (if stats.publishSkips > 0 and stats.lastPublishReason.len > 0:
       " lastPublishSkip=\"" & stats.lastPublishReason & "\"" else: "")

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

proc loadPeerCacheHostIdentity*(config: PeerCacheConfig):
    tuple[identity: HostIdentity; anchors: TrustAnchorSet] =
  ## The host CA (minted on first start, `identity.loadOrCreateHostIdentity`)
  ## plus the anchor directory `config.tlsTrustAnchorsPath`. A node with NO
  ## anchors could talk to no one, and silently falling back to CIDR-only
  ## trust is exactly what `?tls=1` exists to prevent, so a missing or empty
  ## anchor directory is an error naming it.
  result.identity = loadOrCreateHostIdentity(config.tlsCertPath,
    config.tlsKeyPath)
  if config.tlsTrustAnchorsPath.len == 0:
    raise newException(ValueError, "peer-cache TLS needs a trust-anchor directory")
  if not dirExists(config.tlsTrustAnchorsPath):
    raise newException(ValueError,
      "peer-cache TLS trust-anchor directory does not exist: " &
      config.tlsTrustAnchorsPath & " (copy each peer's host-ca.crt there)")
  result.anchors = loadTrustAnchorDir(config.tlsTrustAnchorsPath)
  # Trust profile: which identities the anchors admit (pinned host keys in
  # the trusted profile, one-hour host-CA leaves in the hardened one).
  result.anchors.identityPolicy = identityPolicyOf(config.trustProfile)
  if result.anchors.byPeerId.len == 0:
    raise newException(ValueError,
      "peer-cache TLS trust-anchor directory has no certificates: " &
      config.tlsTrustAnchorsPath & " (copy each peer's host-ca.crt there)")

proc allowlistOf(config: PeerCacheConfig): seq[CidrV4] =
  for cidr in config.cidrAllowlistRaw:
    result.add(parseCidrV4(cidr))

proc tlsDirOf(config: PeerCacheConfig): string =
  if config.tlsTrustAnchorsPath.len > 0: config.tlsTrustAnchorsPath.parentDir
  else: ""

proc evidenceSinkCaPathOf*(config: PeerCacheConfig): string =
  ## The ONE certificate the evidence appender trusts: the sink's host CA,
  ## `<tls dir>/evidence-sink.crt` — deliberately outside the peer anchor
  ## directory, so the sink is not a cache peer and no peer can pose as
  ## the sink (threat model G28).
  let dir = tlsDirOf(config)
  if dir.len == 0: "" else: dir / "evidence-sink.crt"

proc signerCaPathOf*(config: PeerCacheConfig): string =
  ## The certificate signer's host CA, `<tls dir>/cert-signer.crt` (threat
  ## model D5).
  let dir = tlsDirOf(config)
  if dir.len == 0: "" else: dir / "cert-signer.crt"

proc revokedPathOf*(config: PeerCacheConfig): string =
  let dir = tlsDirOf(config)
  if dir.len == 0: "" else: dir / "revoked"

proc pinnedAnchors*(caPath, what: string): tuple[anchors: TrustAnchorSet;
                                                 hostId: PeerId] =
  ## A trust-anchor set holding exactly the CA at `caPath`, and that CA's
  ## host id. Raises when it is missing (a pinned service is never reached
  ## on the strength of the general peer trust set).
  if caPath.len == 0 or not fileExists(caPath):
    raise newException(ValueError, what & ": its CA certificate is not " &
      "provisioned at " & caPath)
  result.anchors = loadTrustAnchorFile(caPath)
  result.hostId = derivePeerIdFromPublicKey(certPublicKey(certPemToDer(
    readFile(caPath))))

proc grantsPathOf*(config: PeerCacheConfig): string =
  ## `grants=` when given, else `<tls dir>/grants`.
  if config.grantsPath.len > 0:
    return config.grantsPath
  if config.tlsTrustAnchorsPath.len > 0:
    return config.tlsTrustAnchorsPath.parentDir / "grants"
  ""

proc authorizationPolicyFor*(config: PeerCacheConfig): AuthorizationPolicy =
  ## The receiver's FLOW-4 table: every authenticated host is a cache peer
  ## unless the grants file says otherwise; worker roles only by grant;
  ## hosts designated `edge` may not open connections here (FLOW-1).
  result = defaultAuthorizationPolicy()
  let path = grantsPathOf(config)
  if path.len > 0 and fileExists(path):
    let file = loadGrants(path)
    result.grants = file.grants
    result.edgeHosts = file.edgeHosts

proc fileStamp(path: string): string =
  if path.len == 0 or not fileExists(path):
    return "absent"
  try:
    let info = getFileInfo(path)
    $info.lastWriteTime.toUnixFloat & "/" & $info.size & "/" &
      $hash(readFile(path))
  except CatchableError:
    "unreadable"

proc reloadGrants*(host: PeerCacheHost): bool =
  ## Re-reads the grants file when it changed. A grants file that fails to
  ## parse revokes every grant and the default cache-peer role (fail
  ## closed) rather than keeping stale ones — until it parses again, when
  ## the default comes back (it used to stay revoked until a restart).
  let stamp = fileStamp(host.grantsPath)
  if stamp == host.grantsStamp:
    return false
  host.grantsStamp = stamp
  try:
    var file = GrantsFile(grants: initTable[PeerId, set[BoundaryRole]](),
      edgeHosts: initHashSet[PeerId]())
    if fileExists(host.grantsPath):
      file = loadGrants(host.grantsPath)
    host.server.gate.policy.grants = file.grants
    host.server.gate.policy.edgeHosts = file.edgeHosts
    host.server.gate.policy.authenticatedDefault = {brCachePeer}
  except CatchableError:
    host.server.gate.policy.grants = initTable[PeerId, set[BoundaryRole]]()
    host.server.gate.policy.authenticatedDefault = {}
  inc host.grantsVersion
  true

proc applyRevocations(host: PeerCacheHost; revoked: HashSet[PeerId];
                      unknown: bool) =
  host.server.gate.policy.revoked = revoked
  host.server.gate.policy.revocationUnknown = unknown
  host.client.gate.policy.revoked = revoked
  host.client.gate.policy.revocationUnknown = unknown
  host.client.revokedIssuers = revoked
  host.client.revokedPeers = revoked

proc reloadRevocations*(host: PeerCacheHost): bool =
  ## Re-reads `<tls dir>/revoked` when it changed (threat model G17). A list
  ## that exists but does not parse revokes EVERY caller until it is fixed
  ## (fail closed), and says so to the evidence sink.
  if host.revokedPath.len == 0:
    return false
  let stamp = fileStamp(host.revokedPath)
  if stamp == host.revokedStamp:
    return false
  host.revokedStamp = stamp
  if not fileExists(host.revokedPath):
    host.applyRevocations(initHashSet[PeerId](), false)
  else:
    try:
      host.applyRevocations(loadRevokedFile(host.revokedPath), false)
    except CatchableError as err:
      host.applyRevocations(initHashSet[PeerId](), true)
      if not host.appender.isNil:
        host.appender.append(newEvidenceRecord(ecDetection, "boundary-gate",
          "revocation-list-invalid", [("reason", err.msg)]))
  inc host.revocationVersion
  true

proc dirStamp(path: string): string =
  if path.len == 0 or not dirExists(path):
    return "absent"
  var parts: seq[string] = @[]
  for kind, f in walkDir(path):
    if kind == pcFile:
      parts.add(f & "@" & fileStamp(f))
  parts.sort()
  parts.join("|")

proc anchoredHostsOf(anchors: TrustAnchorSet): HashSet[PeerId] =
  result = initHashSet[PeerId]()
  for id, entry in anchors.byPeerId.pairs:
    if entry.isCa:
      result.incl(id)

proc reloadAnchors*(host: PeerCacheHost): bool =
  ## Re-reads the trust-anchor directory when it changed (threat model
  ## G17): a host whose CA was removed cannot complete a new handshake, and
  ## its open connections are refused on their next frame
  ## (`AuthorizationPolicy.requireAnchored`). An anchor directory that no
  ## longer loads keeps the previous set but anchors nobody new.
  if host.config.trustMode != tmTls:
    return false
  let stamp = dirStamp(host.config.tlsTrustAnchorsPath)
  if stamp == host.anchorsStamp:
    return false
  host.anchorsStamp = stamp
  var anchors: TrustAnchorSet
  try:
    anchors = loadTrustAnchorDir(host.config.tlsTrustAnchorsPath)
  except CatchableError:
    anchors = TrustAnchorSet()
  anchors.identityPolicy = identityPolicyOf(host.config.trustProfile)
  host.tls.anchors = anchors
  host.server.trustAnchorSet = anchors
  host.client.trustAnchorSet = anchors
  let anchored = anchoredHostsOf(anchors)
  host.server.gate.policy.anchoredHosts = anchored
  host.client.gate.policy.anchoredHosts = anchored
  inc host.anchorsVersion
  true

proc auditRecordOf*(event: AuditEvent): EvidenceRecord =
  ## One audit event as an evidence record. Admitted frames are `audit`
  ## records (their payload reduced to digest and size by the redaction
  ## allow-list); refusals are `frame-refused` detections with the frame
  ## captured (EVID-1: refusal classes legitimate clients do not produce).
  ## A summary of refusals counted but not recorded one by one carries
  ## their number in `suppressed` (threat model G18).
  var fields = @[
    ("peer", (if event.caller.authenticated: $event.caller.hostId
              else: "anonymous")),
    ("leafRole", $event.caller.leafRole),
    ("peerAddress", event.caller.address),
    ("messageKind", event.message),
    ("direction", event.direction),
    ("size", $event.payloadLen)]
  if event.decision.allowed:
    newEvidenceRecord(ecAudit, "boundary-gate", event.message, fields,
      event.payload)
  else:
    if event.suppressed > 0:
      fields.add(("suppressed", $event.suppressed))
    newEvidenceRecord(ecDetection, "boundary-gate", "frame-refused",
      fields & @[("refusal", $event.decision.refusal),
                 ("reason", event.decision.reason)], event.payload)

const
  PeerCacheDetectors* = ["boundary-gate", "peer-cache-content",
                         "peer-cache-memo", "peer-suspicion"]
    ## The detectors every peer-cache node runs, each heartbeating (DET-5).
  DefaultHeartbeatIntervalMs = 60_000

proc heartbeatIntervalOf(config: PeerCacheConfig): int =
  if config.heartbeatIntervalMs > 0: config.heartbeatIntervalMs
  else: DefaultHeartbeatIntervalMs

proc currentLeaf*(host: PeerCacheHost): LeafCredential =
  ## The node's leaf, re-minted when it is close to expiry (CRED-1).
  if host.config.trustMode == tmTls and host.identity.canMint and
      host.leaf.needsRenewal:
    host.leaf = mintNodeCredential(host.identity, lrDaemon,
      identityPolicyOf(host.config.trustProfile))
    host.tls.cert = host.leaf.cert
  host.leaf

proc renewBuildWorkerLeaf*(host: PeerCacheHost) =
  ## Keeps the pre-minted `build-worker` leaf fresh. Renewed while more
  ## than three quarters of an hour remain, so a build worker forked at any
  ## moment holds a leaf good for at least 45 minutes.
  if host.config.trustMode != tmTls or not host.identity.canMint:
    return
  if host.buildWorkerLeaf.cert.certDer.len == 0 or
      host.buildWorkerLeaf.needsRenewal or
      host.buildWorkerLeaf.cert.notAfter - getTime().toUnix <
        int64(MaxLeafTtlSeconds * 3 div 4):
    host.buildWorkerLeaf = mintNodeCredential(host.identity, lrBuildWorker,
      identityPolicyOf(host.config.trustProfile), inheritable = true)

proc entryReaderFor*(host: PeerCacheHost): MemoEntryReader =
  ## The memo entries this node serves. Consumers judge an attestation at
  ## THEIR clock (threat model G15), so: an entry this host issued is
  ## re-attested with the current leaf when its attestation is close to
  ## expiry (and the refreshed entry stored), and an entry another host
  ## issued is served only while its attestation is still fresh — an
  ## honest node never serves what a consumer must refuse.
  let h = host
  result = proc(weak, strong: BlobDigest): Option[seq[byte]] {.gcsafe.} =
    {.cast(gcsafe).}:
      for storage in h.storages:
        let found = storage.memo.readMemoEntryBytes(weak, strong)
        if found.isNone:
          continue
        var entry: MemoEntry
        var record: ActionResultRecord
        try:
          entry = decodeMemoEntry(found.get())
          record = decodeActionResultRecord(entry.recordBytes)
        except CatchableError:
          continue
        # Campaign M17 (Edge-Derived-Identities.md §3.3a, §3.4 item 1,
        # §3.6): what this node serves, it publishes, so it serves only what
        # the publisher would publish now. A memo store outlives the build
        # that wrote it: an entry a pre-M17 build of this host published (a
        # timestamp-policy record, no stated level), or one an older build
        # sharing the root still writes, is not served -- and not
        # re-attested below, which would sign it again as this host's.
        # Since M17 chunk 2 that includes every entry from before the
        # published-trace record (versions 1-3, `memoEntryRefusal`).
        if memoEntryRefusal(entry, record).len > 0:
          continue
        if h.config.trustMode == tmTls and
            entry.issuerHostId == h.selfPeerId and h.identity.canMint:
          if reattestIfStale(entry, h.currentLeaf()):
            try: discard storage.memo.writeMemoEntry(entry, replace = true)
            except CatchableError: discard
            return some(encodeMemoEntry(entry))
          return found
        if not attestationFresh(entry):
          continue
        return found
      none(seq[byte])

proc leafProviderFor*(host: PeerCacheHost): LeafProvider =
  let h = host
  result = proc(): LeafCredential {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      h.currentLeaf()

proc attestorFor*(host: PeerCacheHost): LeafProvider =
  ## What a build publishing through this host attests memo entries with;
  ## nil without a host identity (CIDR-only), which publishes nothing.
  if host.isNil or host.config.trustMode != tmTls:
    return nil
  host.leafProviderFor()

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

proc deleteExecutionRecordBlob*(casRoot: string; digest: array[32, byte]):
    bool =
  ## EVID-6: removes a worker's execution record from the CAS at `casRoot`
  ## (the daemon's action-cache root) and says whether it is gone — the
  ## `deleteRecord` the worker role hands `sweepExecutionRecords`. The CAS
  ## handle is opened per call and closed at once (a CAS handle holds a
  ## SQLite connection, which must never sit on the far side of the
  ## daemon's build-worker fork()).
  var cas = openCasStore(casRoot)
  defer: cas.close()
  let path = cas.casPath(toContentHash(digest))
  if fileExists(path):
    try: removeFile(path) except CatchableError: return false
  not fileExists(path)

type
  WorkerRepos* = object
    caches*: seq[(string, string)]
      ## `repoId` -> local repository cache.
    remotes*: seq[(string, string)]
      ## `repoId` -> the remote a missing base commit is fetched from.

proc parseWorkerRepos*(text: string): WorkerRepos =
  ## The daemon's `repos=` file: one repository per line,
  ## `<repoId> <cache path> [<remote>]` — the remote (a URL or a path) is
  ## where the worktree pool fetches a base commit the cache lacks
  ## (Distributed-Execution M1). Blank lines and `#` comments are skipped;
  ## a line with another number of fields is ignored.
  for raw in text.splitLines:
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let parts = line.splitWhitespace()
    if parts.len in 2 .. 3:
      result.caches.add((parts[0], parts[1]))
      if parts.len == 3:
        result.remotes.add((parts[0], parts[2]))

proc writeStatus(host: PeerCacheHost) =
  if host.stateDir.len == 0:
    return
  var lines = @[
    "peer_id=" & $host.selfPeerId,
    "trust=" & (if host.config.trustMode == tmTls: "tls" else: "cidr"),
    "listen=" & host.listenAddr & ":" & $int(host.server.actualPort),
    "interface=" & host.bindResolution.interfaceName,
    "peers_known=" & $host.registry.peerCount(),
    "peers_connected=" & $host.client.connectedPeers().len,
    "advertised_keys=" & $host.registry.selfAdvertised.len,
    "memo_requests_served=" & $host.server.memoRequestsServed,
    "frames_admitted=" & $host.server.gate.admittedCount,
    "grants_version=" & $host.grantsVersion,
    "evidence_appended=" &
      (if host.appender.isNil: "0" else: $host.appender.appended),
    # DET-6: what never reached the sink is visible on the node too.
    "evidence_dropped=" &
      (if host.appender.isNil: "0" else: $host.appender.dropped),
    "evidence_queued=" &
      (if host.appender.isNil: "0" else: $host.appender.pending)]
  for refusal in RefusalClass:
    if host.server.gate.refusedCount[refusal] > 0:
      lines.add("frames_refused_" & $refusal & "=" &
        $host.server.gate.refusedCount[refusal])
  if not host.workerStatus.isNil:
    lines.add(host.workerStatus())
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

proc localDetectionReporter(path: string): DetectionReporter =
  ## Trusted profile: where a node's DET triggers go when there is no
  ## evidence sink — its local detection log: one allow-listed line each,
  ## owner-only, rotated and deleted on the EVID-6 schedule
  ## (`evidence_record.appendLocalLog`).
  let p = path
  result = proc(record: EvidenceRecord) {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      appendLocalLog(p, localLogEntry(record))

proc auditSinkFor(host: PeerCacheHost): AuditSink =
  let h = host
  result = proc(event: AuditEvent) {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      let record = auditRecordOf(event)
      if not h.appender.isNil:
        h.appender.append(record)
      elif h.auditLogPath.len > 0:
        # Same EVID-6 rules as the detection log (allow-list, 0600,
        # rotation and deletion).
        appendLocalLog(h.auditLogPath, localLogEntry(record))

proc validateListenerPolicy*(config: PeerCacheConfig;
                             resolution: BindResolution) =
  ## The rules a listener must meet before it binds: authenticated callers
  ## only, on EVERY interface, and — off loopback — an off-host evidence
  ## sink.
  ##
  ## CIDR-only trust is refused on loopback too (Distributed-Execution M7
  ## closed deviation D3): on a shared host, "the caller connected from
  ## 127.0.0.1" admits every local user, not the node's owner. With TLS the
  ## admission is the host CA, whose key is readable by the owning user
  ## only (`identity.loadOrCreateHostIdentity` writes it 0600).
  if not resolution.ok:
    raise newException(ValueError, "peer-cache bind: " & resolution.reason)
  if config.trustMode != tmTls:
    raise newException(ValueError,
      "peer-cache bind=" & resolution.interfaceName & ": CIDR-only trust " &
      "is removed — neither network adjacency nor a loopback address is " &
      "authorization (deployment-security-architecture.md §3); every " &
      "peer-cache node authenticates its callers with its host CA (tls=1)")
  if resolution.isLoopback:
    return
  # Trust profiles (M7, operator decision 2026-10-20): the declared
  # interface and authenticated callers hold in BOTH profiles; the off-host
  # evidence sink is a HARDENED control. A trusted node audits every
  # message to its local audit log instead (`auditSinkFor`).
  if config.trustProfile == tpHardened and config.evidenceSinkSpec.len == 0:
    raise newException(ValueError,
      "peer-cache bind=" & resolution.interfaceName & ": a listener on a " &
      "LAN or overlay interface audits every message to an off-host " &
      "evidence sink (FLOW-2) in the hardened profile; add " &
      "evidence=<host:port>")

proc startPeerCacheHost*(config: PeerCacheConfig; selfPeerId: PeerId;
                         cacheRoot: string; listenAddr = "";
                         stateDir = "";
                         diagnosticLog: proc(line: string) {.gcsafe,
                           closure.} = nil): PeerCacheHost =
  ## Boots a peer-cache node serving `cacheRoot`: server bound on the
  ## declared interface (`config.bindSpec`, or `listenAddr` when given —
  ## either way never a wildcard) and `config.listenPort` (0 = ephemeral),
  ## with its content and memo readers on the disk stores, the receiver
  ## gate and its audit, the evidence appender and detector heartbeats,
  ## multicast only when opted in, and a client dialled to the configured
  ## seeds. Raises on a policy violation or a bind failure; a seed that does
  ## not answer is simply not connected yet (the membership loop in `tick`
  ## keeps trying).
  let resolution = resolveBindSpec(
    if listenAddr.len > 0: listenAddr else: config.bindSpec)
  validateListenerPolicy(config, resolution)
  if config.trustProfile == tpTrusted and
      (config.evidenceSinkSpec.len > 0 or config.signerSpec.len > 0):
    # The append-only evidence sink and the certificate signer are
    # HARDENED-profile controls (operator decision 2026-10-20). A trusted
    # node records detections locally and in execution records; asking it
    # for a sink or signer is a configuration error, not a silent no-op.
    raise newException(ValueError,
      "evidence= and signer= are hardened-profile controls; add " &
      "profile=hardened (or --trust-profile=hardened) to use them")
  result = PeerCacheHost(config: config, selfPeerId: selfPeerId,
    ownerPid: getCurrentProcessId(), stateDir: stateDir,
    listenAddr: resolution.address, bindResolution: resolution,
    running: true)
  if stateDir.len > 0:
    createDir(stateDir)
    result.auditLogPath = stateDir / "peer-cache-audit.log"
    result.localLogs = @[result.auditLogPath,
      stateDir / "peer-cache-detections.log"]
  if config.trustMode == tmTls:
    let loaded = loadPeerCacheHostIdentity(config)
    result.identity = loaded.identity
    result.tls.anchors = loaded.anchors
    result.leaf = mintNodeCredential(result.identity, lrDaemon,
      identityPolicyOf(config.trustProfile))
    result.tls.cert = result.leaf.cert
    result.selfPeerId = result.identity.hostId
    result.renewBuildWorkerLeaf()
  let host = result
  if config.evidenceSinkSpec.len > 0:
    if config.trustMode != tmTls:
      raise newException(ValueError,
        "an evidence sink authenticates its appenders; it needs tls=1")
    # The appender trusts the SINK's CA and nothing else, and checks the
    # sink is that very host (threat model G28).
    let pin = pinnedAnchors(evidenceSinkCaPathOf(config), "the evidence sink")
    result.appender = newEvidenceAppender(
      parseSinkEndpoint(config.evidenceSinkSpec), host.leafProviderFor(),
      pin.anchors,
      maxQueue = (if config.evidenceQueueMax > 0: config.evidenceQueueMax
                  else: 100_000),
      expectedSink = pin.hostId)
    if stateDir.len > 0:
      result.appender.receiptPath = stateDir / "evidence-receipt"
    for detector in PeerCacheDetectors:
      result.appender.registerDetector(detector, heartbeatIntervalOf(config))
  let selfPeerId = result.selfPeerId
  result.registry = newPeerRegistry(selfPeerId,
    initEndpoint(resolution.address, Port(config.listenPort)))
  let allowlist = allowlistOf(config)
  let maxBlob =
    if config.maxBlobBytes > 0: config.maxBlobBytes else: DefaultMaxBlobBytes
  result.server = newPeerCacheServer(
    selfPeerId = selfPeerId,
    listenAddr = resolution.address,
    listenPort = Port(config.listenPort),
    registry = result.registry,
    cidrAllowlist = allowlist,
    maxBlobBytes = maxBlob,
    trustMode = config.trustMode,
    ourCert = result.tls.cert,
    trustAnchorSet = result.tls.anchors,
    metrics = newPeerCacheMetrics(),
    gate = newReceiverGate(authorizationPolicyFor(config),
                           host.auditSinkFor()))
  result.grantsPath = grantsPathOf(config)
  result.grantsStamp = fileStamp(result.grantsPath)
  result.revokedPath = revokedPathOf(config)
  if config.trustMode == tmTls:
    result.server.leafProvider = host.leafProviderFor()
    result.server.requireShortLivedLeaves = true
    result.server.gate.policy.requireAnchored = true
    result.server.gate.policy.anchoredHosts = anchoredHostsOf(
      result.tls.anchors)
  if not result.appender.isNil:
    result.server.reporter = result.appender.reporter()
  elif stateDir.len > 0:
    result.server.reporter = localDetectionReporter(
      stateDir / "peer-cache-detections.log")
  if cacheRoot.len > 0:
    result.addStorage(cacheRoot)
  result.server.localStoreReader = proc(digest: BlobDigest): Option[seq[byte]]
      {.gcsafe.} =
    {.cast(gcsafe).}:
      readBlobFrom(host.storages, digest)
  result.server.memoSelectorReader = selectorReaderFor(result)
  result.server.memoEntryReader = entryReaderFor(result)
  # Operator diagnostics: the daemon passes its log (its stderr is
  # /dev/null); a CLI-owned node keeps stderr.
  result.server.diagnosticLog = diagnosticLog
  result.server.start()
  let useMulticast =
    config.discoveryMode == pdmMulticast and not config.multicastDisabled
  var group = config.multicastGroup
  if useMulticast and not resolution.isLoopback:
    # Multicast (opt-in) joins on the declared interface only (FLOW-6).
    group.interfaceIp = parseIpAddress(resolution.address)
  if useMulticast:
    result.server.multicastListen(group)
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
  if config.trustMode == tmTls:
    result.client.leafProvider = host.leafProviderFor()
    result.client.requireShortLivedLeaves = true
    result.client.gate.policy.requireAnchored = true
    result.client.gate.policy.anchoredHosts = anchoredHostsOf(
      result.tls.anchors)
  # Frames on this node's OWN outbound connections are gated and audited
  # like inbound ones (threat model G29).
  result.client.gate.audit = host.auditSinkFor()
  discard result.reloadRevocations()
  result.anchorsStamp = dirStamp(config.tlsTrustAnchorsPath)
  if result.appender.isNil and stateDir.len > 0:
    result.client.reporter = localDetectionReporter(
      stateDir / "peer-cache-detections.log")
  if not result.appender.isNil:
    result.client.reporter = result.appender.reporter()
    let app = result.appender
    result.client.reportFlusher = proc() {.gcsafe, closure.} =
      {.cast(gcsafe).}:
        discard app.drain(3_000)
  if useMulticast:
    result.client.multicastBroadcast(group)
  # Bounded: a seed that is down can hold a TCP connect for over a minute,
  # and a daemon must not take that long to start. A dial still in flight
  # completes in the background; the membership loop re-dials the rest.
  discard waitFor withTimeout(result.client.start(), SeedDialBudgetMs)
  result.scanRegisteredRoots()
  result.lastStoreScanMs = nowMs()
  result.lastMembershipMs = nowMs()
  if not result.appender.isNil:
    result.appender.tickHeartbeats()
  if stateDir.len > 0:
    let endpointPath = stateDir / PeerCacheEndpointFileName
    let tmp = endpointPath & ".tmp"
    writeFile(tmp, resolution.address & ":" &
      $int(result.server.actualPort) & "\n")
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
  ## newly published memo entries and registered roots, renew the leaf,
  ## heartbeat the detectors, and on the membership interval dial newly
  ## discovered peers and refresh their advertisements.
  if host.isNil or not host.running or host.isForkedChild:
    return
  host.pump(maxWaitMs)
  let now = nowMs()
  if now - host.lastStoreScanMs >= DefaultStoreScanIntervalMs:
    host.lastStoreScanMs = now
    host.scanRegisteredRoots()
    for storage in host.storages:
      discard advertiseStorage(host.registry, storage)
    discard host.currentLeaf()
    host.renewBuildWorkerLeaf()
    discard host.reloadGrants()
    discard host.reloadRevocations()
    discard host.reloadAnchors()
    for endpoint in host.server.discoveredEndpoints:
      if endpoint notin host.client.discoveredEndpoints:
        host.client.discoveredEndpoints.add(endpoint)
    if not host.appender.isNil:
      host.appender.tickHeartbeats(now)
    host.writeStatus()
  if now - host.lastLogSweepMs >= LocalLogSweepIntervalMs:
    host.lastLogSweepMs = now
    for path in host.localLogs:
      discard sweepLocalLog(path)
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
      # G15/G17: connections whose leaf (ours or the peer's) is about to
      # expire, and connections to revoked peers, are closed first; the
      # round re-dials what may be re-dialled with the current leaf.
      host.membershipRound = (proc(): Future[int] {.async.} =
        discard await host.client.rotateExpiringConnections()
        return await host.client.connectKnownPeers())()
    if host.refreshRound.isNil or host.refreshRound.finished:
      host.refreshRound = host.client.requestAdvertisementRefresh()

proc stop*(host: PeerCacheHost) =
  ## Graceful shutdown (Goodbye to peers, sockets closed, evidence drained).
  ## Only in the owning process; a forked child uses `releaseInheritedHost`.
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
  if not host.appender.isNil:
    discard host.appender.drain(2_000)
    host.appender.close()
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

proc buildWorkerSeedsFor*(host: PeerCacheHost): seq[Endpoint] =
  ## What a forked build worker seeds its short-lived client with.
  ##
  ## On a node with the worker role: the operator-declared seeds and
  ## nothing else (FLOW-1, threat model D4). Its registry holds every
  ## requester and orchestrator whose Hello it accepted — developer
  ## workstations and Interior hosts that must never be dialled by a
  ## worker — so a build it hosts may not reach them through
  ## `membershipEndpoints` either; what such a build needs from a caller
  ## comes over the caller's own connection. Elsewhere: the host's whole
  ## membership view.
  if host.isNil:
    return @[]
  if host.config.workerEnabled:
    return host.config.seedPeers
  host.membershipEndpoints()

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
  # The parent's evidence connection is the parent's: never write on it.
  host.appender = nil
  inheritedParentDispatchers.add(getGlobalDispatcher())
  setGlobalDispatcher(newDispatcher())
  # The daemon's private keys were never inherited (their pages are wiped
  # on fork). What the parent computed with them a moment before the fork
  # may still lie in its stale stack frames below ours: zero them.
  scrubStackBelow()

type
  WorkerPeerCacheSession* = ref object
    ## What one daemon-hosted build talks to peers through.
    client*: PeerCacheClient
    leaf*: LeafCredential
      ## The worker's OWN `build-worker` leaf (tmTls); never the daemon's.
    appender*: EvidenceAppender
      ## The worker's own evidence connection (presenting its own leaf).

proc workerLeafProvider*(session: WorkerPeerCacheSession): LeafProvider =
  if session.isNil or session.leaf.cert.certDer.len == 0:
    return nil
  let s = session
  result = proc(): LeafCredential {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      s.leaf

proc startWorkerPeerCacheSession*(host: PeerCacheHost;
                                  members: seq[Endpoint];
                                  fallbackPeerId: PeerId): WorkerPeerCacheSession =
  ## A short-lived client for one build in a daemon worker: no server (the
  ## daemon serves), dialled to `members` (`buildWorkerSeedsFor`: the
  ## daemon's membership view, or only its declared seeds on a worker-role
  ## node) and returned once every dial has completed or failed.
  ##
  ## Under `tmTls` the worker presents the `build-worker` leaf the daemon
  ## minted for its build workers before the fork (`buildWorkerLeaf`). It
  ## never held the host CA key or the daemon's leaf key: both live in
  ## pages a forked child does not inherit (threat model G16; CRED-4 within
  ## a host: a compromised build worker holds a credential of at most an
  ## hour capped to the cache plane, not the daemon's identity or the means
  ## to mint more). Its Hello carries the host id and the daemon's listen
  ## port, so a peer that records it refreshes its entry for this host.
  result = WorkerPeerCacheSession()
  let config = host.config
  var peerId = fallbackPeerId
  var listenPort = 0'u16
  var anchors: TrustAnchorSet
  if config.trustMode == tmTls:
    result.leaf = host.buildWorkerLeaf
    if result.leaf.key.isNil or not result.leaf.key.available:
      raise newException(ValueError,
        "the daemon handed this build worker no usable build-worker leaf")
    peerId = result.leaf.hostId
    listenPort = uint16(host.actualPort)
    anchors = host.tls.anchors
  let registry = newPeerRegistry(peerId, initEndpoint(host.listenAddr, Port(0)))
  result.client = newPeerCacheClient(
    selfPeerId = peerId,
    listenPort = listenPort,
    registry = registry,
    seedPeers = members,
    cidrAllowlist = allowlistOf(config),
    trustMode = config.trustMode,
    ourCert = result.leaf.cert,
    trustAnchorSet = anchors)
  if config.workerEnabled:
    # FLOW-1 (threat model D4): on a worker-role node a hosted build dials
    # its declared seeds only — never a peer some advertisement or
    # discovery put in its registry.
    result.client.dialDiscovered = false
  if config.trustMode == tmTls:
    result.client.leafProvider = result.workerLeafProvider()
    result.client.requireShortLivedLeaves = true
    if config.evidenceSinkSpec.len > 0:
      let pin = pinnedAnchors(evidenceSinkCaPathOf(config),
        "the evidence sink")
      result.appender = newEvidenceAppender(
        parseSinkEndpoint(config.evidenceSinkSpec),
        result.workerLeafProvider(), pin.anchors,
        expectedSink = pin.hostId)
      result.client.reporter = result.appender.reporter()
      let app = result.appender
      result.client.reportFlusher = proc() {.gcsafe, closure.} =
        {.cast(gcsafe).}:
          discard app.drain(3_000)
  discard waitFor withTimeout(result.client.start(), SeedDialBudgetMs)

proc stopWorkerPeerCacheSession*(session: WorkerPeerCacheSession) =
  if session.isNil:
    return
  if not session.client.isNil:
    try:
      waitFor session.client.stop()
    except CatchableError:
      discard
  if not session.appender.isNil:
    discard session.appender.drain(2_000)
    session.appender.close()

proc stopPeerCacheClient*(client: PeerCacheClient) =
  if client.isNil:
    return
  try:
    waitFor client.stop()
  except CatchableError:
    discard

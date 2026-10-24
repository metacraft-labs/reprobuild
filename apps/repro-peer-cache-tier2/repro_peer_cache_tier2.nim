## Peer-Cache-Scale M2 tier-2 cache daemon.
##
## Long-lived "fat peer" cache node. Boots a `PeerCacheServer` with
## `cap_tier2 = true`, mounts a disk-backed content-addressed store
## under `--store-dir`, advertises the store contents on the rack-
## local SWIM group (default `pdmUnicastSeed` for M2), and falls
## through to an upstream central remote cache on local miss when
## `--upstream-cache=<url>` is configured.
##
## See `Peer-Cache-Scale.md` §"Tier-2 cache hierarchy" and
## `Peer-Cache-Scale.milestones.org` §M2.
##
## Distributed-Execution M7 (threat model G27) made it a Boundary node like
## every other peer-cache node:
##
## * its identity is a per-host CA (`--tls-cert`/`--tls-key` name
##   `host-ca.crt`/`host-ca.key`) and it presents short-lived leaves; legacy
##   long-lived certificates are refused from peers too
##   (`requireShortLivedLeaves`);
## * every frame passes the receiver gate and is AUDITED — to the off-host
##   evidence sink (`--evidence=host:port`, its CA pinned at
##   `<tls dir>/evidence-sink.crt`), which a listener off loopback requires;
## * the CIDR allow-list defaults to loopback, and a listener off loopback
##   needs an explicit `--cidr` (it used to default to `0.0.0.0/0`).

import std/[asyncdispatch, os, parseopt, random, sets, strutils, tables, times]

import repro_peer_cache

const
  DefaultListen = "127.0.0.1:0"
    ## Loopback unless the operator names the rack interface's address
    ## (`--listen=<addr>:<port>`); a wildcard is refused
    ## (deployment-security-architecture.md FLOW-6).
  DefaultMaxStoreBytes = 10_737_418_240'u64  # 10 GiB
  DefaultCidr = "127.0.0.0/8"
    ## Defence in depth beside TLS: loopback unless the operator names the
    ## rack's range (`--cidr`), which a non-loopback listener requires.
  DefaultHeartbeatMs = 60_000

type
  Tier2DaemonConfig* = object
    listenHost*: string
    listenPort*: Port
    seeds*: seq[Endpoint]
    cidrs*: seq[string]
    storeDir*: string
    maxStoreBytes*: uint64
    upstreamCacheUrl*: string
    peerIdPath*: string
    tlsCertPath*: string
      ## Peer-Cache-BearSSL M4: PEM-encoded X.509 leaf cert for `tmTls`.
      ## When this, `tlsKeyPath`, and `tlsTrustAnchorsPath` are all
      ## non-empty (and the files exist), the daemon runs in `tmTls`.
      ## Otherwise it refuses to start (CIDR-only trust is removed).
    tlsKeyPath*: string
      ## Peer-Cache-BearSSL M4: ECDSA-P256 private-key file for `tmTls`
      ## (M1 `ecdsa-p256:<hex>` format).
    tlsTrustAnchorsPath*: string
      ## Peer-Cache-BearSSL M4: directory of PEM-encoded trust-anchor
      ## certs (one `*.crt` file per anchor).
    evidenceSpec*: string
      ## Distributed-Execution M7 (G27): `host:port` of the evidence sink
      ## every audit record goes to. Required off loopback.
    evidenceCaPath*: string
      ## The sink's host CA; default `<tls dir>/evidence-sink.crt`.
    explicitCidr*: bool
    heartbeatMs*: int

  Tier2DaemonError* = object of CatchableError

# ---------------------------------------------------------------------------
# CLI helpers.
# ---------------------------------------------------------------------------

proc xdgCacheHome(): string =
  let xdg = getEnv("XDG_CACHE_HOME")
  if xdg.len > 0: xdg
  else: getHomeDir() / ".cache"

proc defaultStoreDir(): string =
  xdgCacheHome() / "repro-peer-cache-tier2"

proc parseHostPort(spec: string): Endpoint =
  ## Parses `host:port`. Raises `Tier2DaemonError` on malformed input.
  let colon = spec.rfind(':')
  if colon <= 0:
    raise newException(Tier2DaemonError,
      "expected host:port, got '" & spec & "'")
  let host = spec[0 ..< colon]
  let portStr = spec[colon + 1 .. ^1]
  let portNum =
    try: parseInt(portStr)
    except ValueError:
      raise newException(Tier2DaemonError,
        "port is not an integer: '" & portStr & "'")
  if portNum < 0 or portNum > 65535:
    raise newException(Tier2DaemonError,
      "port out of range: " & $portNum)
  initEndpoint(host, Port(portNum))

proc xdgStateHome(): string =
  let xdg = getEnv("XDG_STATE_HOME")
  if xdg.len > 0: xdg
  else: getHomeDir() / ".local" / "state"

proc defaultTlsDir(): string =
  xdgStateHome() / "repro-peer-cache" / "tls"

proc defaultConfig*(): Tier2DaemonConfig =
  let storeDir = defaultStoreDir()
  let tlsDir = defaultTlsDir()
  let envCert = getEnv("REPRO_PEER_CACHE_TLS_CERT")
  let envKey  = getEnv("REPRO_PEER_CACHE_TLS_KEY")
  let envAnch = getEnv("REPRO_PEER_CACHE_TLS_ANCHORS")
  # The default listener is DefaultListen (loopback), never a wildcard
  # (FLOW-6). It used to be "0.0.0.0" here while the constant above said
  # loopback, so a daemon started without `--listen` bound every interface.
  let listen = parseHostPort(DefaultListen)
  Tier2DaemonConfig(
    listenHost: listen.host,
    listenPort: listen.port,
    seeds: @[],
    cidrs: @[DefaultCidr],
    storeDir: storeDir,
    maxStoreBytes: DefaultMaxStoreBytes,
    upstreamCacheUrl: "",
    peerIdPath: storeDir / "peer-id",
    tlsCertPath: (if envCert.len > 0: envCert
                  else: tlsDir / "host-ca.crt"),
    tlsKeyPath:  (if envKey.len > 0: envKey
                  else: tlsDir / "host-ca.key"),
    tlsTrustAnchorsPath: (if envAnch.len > 0: envAnch
                          else: tlsDir / "anchors"),
    heartbeatMs: DefaultHeartbeatMs)

proc parseConfig*(argv: openArray[string]): Tier2DaemonConfig =
  result = defaultConfig()
  # An empty `argv` means "no options", not "this process's options":
  # `std/parseopt` substitutes `commandLineParams()` for an empty
  # sequence, so a caller passing `[]` (a test, an embedding) would
  # otherwise be configured from whatever its own command line holds.
  if argv.len == 0:
    return
  var explicitCidr = false
  var p = initOptParser(@argv)
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "listen":
        let ep = parseHostPort(p.val)
        if isWildcard(ep.host):
          raise newException(Tier2DaemonError,
            "--listen=" & p.val & ": a wildcard bind is refused; name the " &
            "address of the interface peers reach this node on (FLOW-6)")
        result.listenHost = ep.host
        result.listenPort = ep.port
      of "seed":
        result.seeds.add(parseHostPort(p.val))
      of "cidr":
        if not explicitCidr:
          result.cidrs = @[]
          explicitCidr = true
          result.explicitCidr = true
        result.cidrs.add(p.val)
      of "evidence":
        result.evidenceSpec = p.val
      of "evidence-ca":
        result.evidenceCaPath = p.val
      of "heartbeat":
        result.heartbeatMs = parseInt(p.val)
      of "store-dir":
        result.storeDir = p.val
        if result.peerIdPath == defaultConfig().peerIdPath:
          result.peerIdPath = p.val / "peer-id"
      of "max-store-bytes":
        result.maxStoreBytes = uint64(parseBiggestUInt(p.val))
      of "upstream-cache":
        result.upstreamCacheUrl = p.val
      of "peer-id-path":
        result.peerIdPath = p.val
      of "tls-cert":
        result.tlsCertPath = p.val
      of "tls-key":
        result.tlsKeyPath = p.val
      of "tls-anchors":
        result.tlsTrustAnchorsPath = p.val
      else:
        raise newException(Tier2DaemonError,
          "unknown option: --" & p.key)
    of cmdArgument:
      raise newException(Tier2DaemonError,
        "unexpected positional argument: " & p.key)

# ---------------------------------------------------------------------------
# Peer ID load / generate.
# ---------------------------------------------------------------------------

proc randomPeerId(): PeerId =
  ## Cheap deterministic-on-seed PeerID for M2. Production code paths
  ## use `nimcrypto.sysrand`; M2 ships with this stand-in so the
  ## daemon's CLI works without pulling in the random source.
  var rng = initRand(int64(epochTime() * 1_000_000) xor int64(getCurrentProcessId()))
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte(rng.rand(255))
  peerIdFromBytes(raw)

proc loadOrCreatePeerId*(path: string): PeerId =
  ## Loads a 32-byte peer ID from `path` if present; otherwise
  ## generates a fresh one and persists it (creating intermediate
  ## directories as needed). Raises `Tier2DaemonError` on filesystem
  ## errors.
  if fileExists(path):
    let raw = readFile(path)
    if raw.len < 32:
      raise newException(Tier2DaemonError,
        "peer-id file too short: " & path)
    var bytes: array[32, byte]
    for i in 0 ..< 32:
      bytes[i] = byte(ord(raw[i]))
    return peerIdFromBytes(bytes)
  let parent = path.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  let pid = randomPeerId()
  let raw = bytes(pid)
  var asString = newString(32)
  for i, b in raw:
    asString[i] = char(b)
  writeFile(path, asString)
  pid

# ---------------------------------------------------------------------------
# Daemon plumbing.
# ---------------------------------------------------------------------------

type
  Tier2Daemon* = ref object
    config*: Tier2DaemonConfig
    selfPeerId*: PeerId
    diskStore*: DiskStore
    registry*: PeerRegistry
    server*: PeerCacheServer
    client*: PeerCacheClient
    tier2*: Tier2Cache
    identity*: HostIdentity
    leaf*: LeafCredential
      ## The current short-lived leaf, re-minted before expiry.
    appender*: EvidenceAppender
      ## Nil only for a loopback-only daemon without `--evidence`; its
      ## audit lines then go to `<store dir>/audit.log`.

proc resolveTrustMode*(config: Tier2DaemonConfig): TrustMode =
  ## Peer-Cache-BearSSL M4: tier-2 daemon TLS auto-defaulting.
  ##
  ## When `tlsCertPath`, `tlsKeyPath`, and `tlsTrustAnchorsPath` are
  ## all configured (non-empty) AND all three files / directories
  ## exist on disk, the daemon defaults `trustMode` to `tmTls` and
  ## logs the selection. If any of the three paths is configured but
  ## the on-disk file is missing, `bootDaemon` raises so the daemon
  ## refuses to start (a half-configured TLS surface is a configuration
  ## bug; we fail loudly rather than silently degrading).
  ##
  ## When none of the three TLS paths is configured (the defaults
  ## resolve to `XDG_STATE_HOME/repro-peer-cache/tls/...` but the
  ## operator hasn't placed any files there), this returns `tmCidr` and
  ## `bootDaemon` refuses to start: CIDR-only trust is removed
  ## (Distributed-Execution M7, deviation D3).
  let havePaths = config.tlsCertPath.len > 0 and
                  config.tlsKeyPath.len > 0 and
                  config.tlsTrustAnchorsPath.len > 0
  if not havePaths:
    return tmCidr
  let haveFiles = fileExists(config.tlsCertPath) and
                  fileExists(config.tlsKeyPath) and
                  dirExists(config.tlsTrustAnchorsPath)
  if haveFiles: tmTls else: tmCidr

proc bootDaemon*(config: Tier2DaemonConfig;
                 upstream: UpstreamCacheClient = nil;
                 silent: bool = false): Tier2Daemon =
  ## Constructs (but does not yet start) the daemon. The upstream
  ## closure is injected by callers so tests can stub it; the binary
  ## entry point builds a default closure from `--upstream-cache=<url>`.
  ##
  ## Peer-Cache-BearSSL M4: emits a one-line trust-mode banner to
  ## stderr unless `silent = true` (tests pass `silent = true`).
  # Refused here too, not only in `parseConfig`: a config built in code
  # never passes through the flag parser (FLOW-6).
  if isWildcard(config.listenHost):
    raise newException(Tier2DaemonError,
      "listen address " & config.listenHost & " is a wildcard; name the " &
      "address of the interface peers reach this node on (FLOW-6)")
  if not dirExists(config.storeDir):
    createDir(config.storeDir)
  # Peer-Cache-BearSSL M4: TLS-mode auto-defaulting + loud failure on
  # half-configured paths.
  let trustMode = resolveTrustMode(config)
  if trustMode != tmTls:
    # If any TLS path is configured (non-default) but the file is
    # missing, say which (operator typos in the `--tls-*` flags).
    if not fileExists(config.tlsCertPath) and fileExists(config.tlsKeyPath):
      raise newException(Tier2DaemonError,
        "configured --tls-cert path does not exist: " & config.tlsCertPath)
    if not dirExists(config.tlsTrustAnchorsPath) and
        fileExists(config.tlsCertPath):
      raise newException(Tier2DaemonError,
        "configured --tls-anchors directory does not exist: " &
        config.tlsTrustAnchorsPath)
    # CIDR-only trust is removed (Distributed-Execution M7, deviation D3):
    # a node that admits callers by source address serves its store to
    # every user of every host that can reach it.
    raise newException(Tier2DaemonError,
      "no host CA and trust anchors are configured (--tls-cert, --tls-key, " &
      "--tls-anchors); CIDR-only trust is removed and the tier-2 daemon " &
      "does not start without TLS")
  let loopback = config.listenHost.startsWith("127.") or
    config.listenHost == "localhost"
  if not loopback and not config.explicitCidr:
    raise newException(Tier2DaemonError,
      "a listener on " & config.listenHost & " needs --cidr naming the " &
      "rack's address range (the default allow-list is loopback)")
  if not loopback and config.evidenceSpec.len == 0:
    raise newException(Tier2DaemonError,
      "a listener on " & config.listenHost & " audits every frame to an " &
      "off-host evidence sink (FLOW-2); add --evidence=host:port")
  # G27: a per-host CA and short-lived leaves, never a long-lived cert.
  let identity = loadOrCreateHostIdentity(config.tlsCertPath,
    config.tlsKeyPath)
  let anchorSet = loadTrustAnchorDir(config.tlsTrustAnchorsPath)
  if not silent:
    stderr.writeLine("peer-cache: tmTls trust mode (host CA " &
      config.tlsCertPath & ", anchors " & config.tlsTrustAnchorsPath & ")")
  let diskStore = newDiskStore(config.storeDir, config.maxStoreBytes)
  let endpoint = initEndpoint(config.listenHost, config.listenPort)
  # The node's id is its host CA's (G27), not a random peer-id file.
  let registry = newPeerRegistry(identity.hostId, endpoint)
  let tier2 = newTier2Cache(diskStore, registry, upstream)
  var allowlist: seq[CidrV4] = @[]
  for cidr in config.cidrs:
    allowlist.add(parseCidrV4(cidr))

  let daemon = Tier2Daemon(config: config, selfPeerId: identity.hostId,
    diskStore: diskStore, registry: registry, tier2: tier2,
    identity: identity, leaf: mintLeaf(identity, lrDaemon))
  let leafProvider = proc(): LeafCredential {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      if daemon.leaf.needsRenewal:
        daemon.leaf = mintLeaf(daemon.identity, lrDaemon)
      daemon.leaf
  if config.evidenceSpec.len > 0:
    let caPath =
      if config.evidenceCaPath.len > 0: config.evidenceCaPath
      else: config.tlsTrustAnchorsPath.parentDir / "evidence-sink.crt"
    if not fileExists(caPath):
      raise newException(Tier2DaemonError,
        "the evidence sink's CA is not provisioned at " & caPath)
    daemon.appender = newEvidenceAppender(parseSinkEndpoint(config.evidenceSpec),
      leafProvider, loadTrustAnchorFile(caPath),
      expectedSink = derivePeerIdFromPublicKey(certPublicKey(certPemToDer(
        readFile(caPath)))))
    for detector in ["boundary-gate", "peer-cache-content", "peer-suspicion"]:
      daemon.appender.registerDetector(detector, config.heartbeatMs)
  let auditLog = config.storeDir / "audit.log"
  let app = daemon.appender
  let auditSink = proc(event: AuditEvent) {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      let fields = @[
        ("peer", (if event.caller.authenticated: $event.caller.hostId
                  else: "anonymous")),
        ("leafRole", $event.caller.leafRole),
        ("peerAddress", event.caller.address),
        ("messageKind", event.message), ("direction", event.direction),
        ("size", $event.payloadLen)]
      let record =
        if event.decision.allowed:
          newEvidenceRecord(ecAudit, "boundary-gate", event.message, fields,
            event.payload)
        else:
          newEvidenceRecord(ecDetection, "boundary-gate", "frame-refused",
            fields & @[("refusal", $event.decision.refusal),
                       ("reason", event.decision.reason),
                       ("suppressed", $event.suppressed)], event.payload)
      if not app.isNil:
        app.append(record)
      else:
        try:
          let f = open(auditLog, fmAppend)
          defer: f.close()
          f.writeLine($getTime().toUnix & " " & describe(redact(record)))
        except CatchableError:
          discard
  var policy = defaultAuthorizationPolicy()
  policy.requireAnchored = true
  for id, entry in anchorSet.byPeerId.pairs:
    if entry.isCa: policy.anchoredHosts.incl(id)
  daemon.server = newPeerCacheServer(
    selfPeerId = identity.hostId,
    listenAddr = config.listenHost,
    listenPort = config.listenPort,
    registry = registry,
    cidrAllowlist = allowlist,
    maxBlobBytes = DefaultMaxBlobBytes,
    localStoreReader = makeTier2StoreReader(tier2),
    capTier2 = true,
    trustMode = tmTls,
    trustAnchorSet = anchorSet,
    gate = newReceiverGate(policy, auditSink))
  daemon.server.leafProvider = leafProvider
  daemon.server.requireShortLivedLeaves = true
  if not app.isNil:
    daemon.server.reporter = app.reporter()
  daemon.client = newPeerCacheClient(
    selfPeerId = identity.hostId,
    listenPort = uint16(config.listenPort),
    registry = registry,
    seedPeers = config.seeds,
    cidrAllowlist = allowlist,
    localStoreWriter = makeTier2StoreWriter(tier2),
    capTier2 = true,
    trustMode = tmTls,
    trustAnchorSet = anchorSet)
  daemon.client.leafProvider = leafProvider
  daemon.client.requireShortLivedLeaves = true
  daemon.client.gate.policy = policy
  daemon.client.gate.audit = auditSink
  if not app.isNil:
    daemon.client.reporter = app.reporter()
  result = daemon

proc start*(daemon: Tier2Daemon) {.async.} =
  daemon.server.start()
  await daemon.client.start()

proc stop*(daemon: Tier2Daemon) {.async.} =
  await daemon.client.stop()
  daemon.server.stop()

# ---------------------------------------------------------------------------
# Binary entry point.
# ---------------------------------------------------------------------------

when isMainModule:
  var argv: seq[string] = @[]
  for i in 1 .. paramCount():
    argv.add(paramStr(i))
  let config =
    try: parseConfig(argv)
    except Tier2DaemonError as err:
      stderr.writeLine("repro-peer-cache-tier2: " & err.msg)
      quit(2)
  let daemon = bootDaemon(config, upstream = nil)
  echo "repro-peer-cache-tier2: peer-id=", $daemon.selfPeerId,
       " listen=", config.listenHost, ":", $config.listenPort.int,
       " store=", config.storeDir,
       " max-bytes=", $config.maxStoreBytes
  waitFor daemon.start()
  # Block until interrupted; the SWIM/multicast loops drive
  # discovery + advertisement on the running async dispatcher.
  while true:
    try: poll(1000) except ValueError: sleep(1000)
    if not daemon.appender.isNil:
      daemon.appender.tickHeartbeats()

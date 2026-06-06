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

import std/[asyncdispatch, options, os, parseopt, random, strutils, times]

import repro_peer_cache

const
  DefaultListen = "0.0.0.0:0"
  DefaultMaxStoreBytes = 10_737_418_240'u64  # 10 GiB
  DefaultCidr = "0.0.0.0/0"

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

proc defaultConfig*(): Tier2DaemonConfig =
  let storeDir = defaultStoreDir()
  Tier2DaemonConfig(
    listenHost: "0.0.0.0",
    listenPort: Port(0),
    seeds: @[],
    cidrs: @[DefaultCidr],
    storeDir: storeDir,
    maxStoreBytes: DefaultMaxStoreBytes,
    upstreamCacheUrl: "",
    peerIdPath: storeDir / "peer-id")

proc parseConfig*(argv: openArray[string]): Tier2DaemonConfig =
  result = defaultConfig()
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
        result.listenHost = ep.host
        result.listenPort = ep.port
      of "seed":
        result.seeds.add(parseHostPort(p.val))
      of "cidr":
        if not explicitCidr:
          result.cidrs = @[]
          explicitCidr = true
        result.cidrs.add(p.val)
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

proc bootDaemon*(config: Tier2DaemonConfig;
                 upstream: UpstreamCacheClient = nil): Tier2Daemon =
  ## Constructs (but does not yet start) the daemon. The upstream
  ## closure is injected by callers so tests can stub it; the binary
  ## entry point builds a default closure from `--upstream-cache=<url>`.
  if not dirExists(config.storeDir):
    createDir(config.storeDir)
  let peerId = loadOrCreatePeerId(config.peerIdPath)
  let diskStore = newDiskStore(config.storeDir, config.maxStoreBytes)
  let endpoint = initEndpoint(config.listenHost, config.listenPort)
  let registry = newPeerRegistry(peerId, endpoint)
  let tier2 = newTier2Cache(diskStore, registry, upstream)
  var allowlist: seq[CidrV4] = @[]
  for cidr in config.cidrs:
    allowlist.add(parseCidrV4(cidr))
  let server = newPeerCacheServer(
    selfPeerId = peerId,
    listenAddr = config.listenHost,
    listenPort = config.listenPort,
    registry = registry,
    cidrAllowlist = allowlist,
    maxBlobBytes = DefaultMaxBlobBytes,
    localStoreReader = makeTier2StoreReader(tier2),
    capTier2 = true)
  let client = newPeerCacheClient(
    selfPeerId = peerId,
    listenPort = uint16(config.listenPort),
    registry = registry,
    seedPeers = config.seeds,
    cidrAllowlist = allowlist,
    localStoreWriter = makeTier2StoreWriter(tier2),
    capTier2 = true)
  result = Tier2Daemon(
    config: config,
    selfPeerId: peerId,
    diskStore: diskStore,
    registry: registry,
    server: server,
    client: client,
    tier2: tier2)

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
    poll(1000)

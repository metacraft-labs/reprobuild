## A binary cache for the A8 substitution gates: the real
## ``repro-binary-cache`` daemon on the test host's loopback (reached by a
## QEMU user-network guest at ``HostFromGuest``), and publishers that put
## build-action outputs into it -- through the client's own publish path
## for a well-formed tree, and as hand-built ``rbcarc-v2`` bytes for an
## archive no well-formed tree can produce (a link, then an entry beneath
## it).
##
## The daemon is this tree's (``cacheServerExe``). It runs permissive
## (any key may publish): what the gates test is which publisher keys the
## HOST trusts, so the cache accepting a key the host does not anchor is
## the point.
##
## *Mocking.* None: the real daemon, the real publish protocol, real
## signatures.

import std/[httpclient, os, osproc, strutils, times]

import blake3
import repro_binary_cache_client
import repro_binary_cache_client/in_process
import repro_binary_cache_server/types as bcsTypes
import repro_binary_cache_server/manifest_codec as serverCodec
import repro_profile
import repro_profile_compile/binary_cache_build_actions
import repro_peer_cache/auth as peerAuth
import repro_test_support/fresh_binary

import ./addon_testbed
import ./agent_e2e_support

type CacheServer* = ref object
  port*: int
  root*: string
  process: Process
  logPath*: string

proc cacheServerExe(): string =
  ## The daemon of THIS tree: ``REPRO_ADDON_CACHE_SERVER``, else the one in
  ## the engine closure the gate was given (``REPRO_ADDON_ENGINE_CLOSURE``),
  ## else ``build/bin`` of the checkout, built from it as it is now. Never
  ## a ``repro`` found on PATH: a pinned older daemon is another program
  ## than the one under test.
  result = getEnv("REPRO_ADDON_CACHE_SERVER")
  if result.len > 0: return
  let engine = getEnv("REPRO_ADDON_ENGINE_CLOSURE")
  if engine.len > 0 and fileExists(engine / "bin" / "repro-binary-cache"):
    return engine / "bin" / "repro-binary-cache"
  # ``build/bin``'s only when built from this tree as it is now: a daemon
  # older than its sources is refused (``StaleHelperBinary``), not run.
  if fileExists(reproRoot() / "build" / "bin" / "repro-binary-cache"):
    return freshRepoBinary(reproRoot(), "repro-binary-cache")
  raise newException(TestBedError, "no repro-binary-cache of this tree: set " &
    "REPRO_ADDON_CACHE_SERVER or REPRO_ADDON_ENGINE_CLOSURE, or build it")

proc startCache*(g: Guest): CacheServer =
  ## Start the cache on a port the kernel picks (``127.0.0.1:0``) and wait
  ## for the line the daemon prints once its listener is bound, which
  ## names that port. There is no deadline: the wait ends when the daemon
  ## reports it is listening or when it exits (then with its status and
  ## log). A port probed free and handed over to bind later could be taken
  ## in between by another gate's listener on a busy host, and a deadline
  ## on startup turned a slow start under load into a failure.
  result = CacheServer(root: g.runDir / "cache")
  createDir(result.root)
  result.logPath = g.runDir / "cache.log"
  result.process = startProcess("/bin/sh", args = ["-c",
    "exec " & quoteShell(cacheServerExe()) & " --root=" &
    quoteShell(result.root) & " --listen=127.0.0.1:0 >> " &
    quoteShell(result.logPath) & " 2>&1"])
  const Marker = "repro-binary-cache listening on 127.0.0.1:"
  while true:
    if fileExists(result.logPath):
      for line in readFile(result.logPath).splitLines():
        if line.startsWith(Marker):
          result.port = parseInt(line[Marker.len .. ^1].split(' ')[0])
          if result.port == 0:
            raise newException(TestBedError, "the binary cache reports " &
              "port 0: it predates reporting the bound port")
          return
    let code = result.process.peekExitCode()
    if code != -1:
      raise newException(TestBedError, "the binary cache exited (status " &
        $code & ") before listening: " &
        (if fileExists(result.logPath): readFile(result.logPath) else: ""))
    sleep(50)

proc stop*(c: CacheServer) =
  if c != nil and c.process != nil:
    try:
      c.process.terminate()
      discard c.process.waitForExit(5000)
      c.process.close()
    except CatchableError: discard

proc guestUrl*(c: CacheServer): string =
  "http://" & HostFromGuest & ":" & $c.port

proc hostUrl*(c: CacheServer): string = "http://127.0.0.1:" & $c.port

proc publishCount*(c: CacheServer): int =
  ## How many publishes the daemon logged (its stderr names each).
  if not fileExists(c.logPath): return 0
  for line in readFile(c.logPath).splitLines():
    if "publish" in line.toLowerAscii() and "POST" in line: inc result

const GuestPlatform* = PlatformTriple(cpu: "x86_64", os: "linux", abi: "gnu",
                                      libcVariant: "")
  ## What an amd64 guest's apply keys its build-action entries by
  ## (``compat_check.detectLocalPlatform``).

proc guestPlatformFor*(debArch: string): PlatformTriple =
  ## What a guest of ``debArch`` keys its build-action entries by: the cpu
  ## family ``compat_check.detectLocalPlatform`` names for the add-on
  ## binary built for that architecture (``armv7`` for every armhf host).
  let cpu = case debArch
    of "amd64": "x86_64"
    of "arm64": "aarch64"
    of "armhf": "armv7"
    else: raise newException(TestBedError, "no cache platform for " & debArch)
  PlatformTriple(cpu: cpu, os: "linux", abi: "gnu", libcVariant: "")

proc publishTree*(c: CacheServer; kp: PeerKeypair; action: ProfileBuildAction;
                  tree: string; platform = GuestPlatform): string =
  ## Publish ``tree`` (the action's declared outputs, relative to it) as
  ## the action's entry for ``platform``, signed by ``kp``; returns the
  ## ``blake3:`` digest a manifest pins for it.
  let idy = buildActionCacheIdentity(action, platform)
  let r = publishInProcess(PublishInProcessRequest(
    entryKeyHex: cacheEntryKeyHex(deriveCacheEntryKey(idy)), prefixDir: tree,
    identity: idy, endpoint: c.hostUrl, keypair: kp))
  if not r.ok:
    raise newException(TestBedError, "publish failed: " & r.error)
  "blake3:" & r.rawArchiveDigestHex

proc u32(v: int): string =
  for i in 0 ..< 4: result.add(char((v shr (8 * i)) and 0xff))

proc u64(v: int): string =
  for i in 0 ..< 8: result.add(char((v shr (8 * i)) and 0xff))

type RawEntry* = tuple[path: string; kind: int; mode: int; data: string]
  ## ``kind``: 0 file, 1 directory, 2 symbolic link (``ArchiveEntryKind``).

proc rbcarcV2*(entries: seq[RawEntry]): string =
  ## An ``rbcarc-v2`` archive holding exactly ``entries``, in order.
  result = "RBCA" & u32(2) & u32(entries.len)
  for e in entries:
    result.add(u32(e.path.len) & e.path & char(e.kind) & u32(e.mode) &
               u64(e.data.len) & e.data)

proc publishRawArchive*(c: CacheServer; kp: PeerKeypair;
                        action: ProfileBuildAction; archive: string): string =
  ## Publish ``archive`` bytes as the action's entry, signed by ``kp``, the
  ## way ``publishInProcess`` does for a packed tree (uncompressed); returns
  ## its pinned digest.
  let idy = buildActionCacheIdentity(action, GuestPlatform)
  let key = deriveCacheEntryKey(idy)
  let d = blake3.digest(archive)
  var h: bcsTypes.Blake3Hash
  for i in 0 ..< 32: h[i] = d[i]
  let payload = bcsTypes.PayloadObject(kind: bcsTypes.pkPrefixArchive,
    compression: bcsTypes.ckNone, declaredSize: uint64(archive.len),
    uncompressedSize: uint64(archive.len), digest: h, name: "prefix.rbcarc")
  var m = bcsTypes.BinaryCacheManifest(
    formatVersion: bcsTypes.BinaryCacheFormatVersion, entryKey: key,
    payloads: @[payload], realizedPrefixDigest: h,
    relocationPolicy: bcsTypes.rpOptional, createdAtUnix: getTime().toUnix())
  serverCodec.signManifest(kp, m)
  let mb = serverCodec.encodeManifest(m)
  var ms = newString(mb.len)
  for i, b in mb: ms[i] = char(b)
  let mp = newMultipartData()
  mp.add("manifest", ms)
  mp.add("payload", archive, "prefix.rbcarc", "application/octet-stream",
         useStream = false)
  let client = newHttpClient(timeout = 30_000)
  defer: client.close()
  let resp = client.post(c.hostUrl & "/publish", multipart = mp)
  if not resp.code.is2xx:
    raise newException(TestBedError, "raw publish failed: " & $resp.code &
      " " & resp.body)
  "blake3:" & d.toHex()

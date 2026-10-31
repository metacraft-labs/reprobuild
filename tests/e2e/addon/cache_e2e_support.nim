## A binary cache for the A8 substitution gates: the real
## ``repro-binary-cache`` daemon on the test host's loopback (reached by a
## QEMU user-network guest at ``HostFromGuest``), and publishers that put
## build-action outputs into it -- through the client's own publish path
## for a well-formed tree, and as hand-built ``rbcarc-v2`` bytes for an
## archive no well-formed tree can produce (a link, then an entry beneath
## it).
##
## The daemon is the one ``REPRO_ADDON_CACHE_SERVER`` names, else the
## ``repro-binary-cache`` beside ``repro`` on ``PATH``. It runs permissive
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

import ./addon_testbed
import ./agent_e2e_support

type CacheServer* = ref object
  port*: int
  root*: string
  process: Process
  logPath*: string

proc cacheServerExe(): string =
  result = getEnv("REPRO_ADDON_CACHE_SERVER")
  if result.len > 0: return
  let repro = findExe("repro")
  if repro.len > 0:
    let real = if symlinkExists(repro): expandSymlink(repro) else: repro
    for cand in [real.parentDir / "repro-binary-cache",
                 repro.parentDir / "repro-binary-cache"]:
      if fileExists(cand): return cand
  raise newException(TestBedError, "no repro-binary-cache: set " &
    "REPRO_ADDON_CACHE_SERVER")

proc startCache*(g: Guest): CacheServer =
  result = CacheServer(root: g.runDir / "cache")
  createDir(result.root)
  let (o, _) = execCmdEx("python3 -c 'import socket; s=socket.socket(); " &
    "s.bind((\"127.0.0.1\",0)); print(s.getsockname()[1]); s.close()'")
  result.port = parseInt(o.strip())
  result.logPath = g.runDir / "cache.log"
  result.process = startProcess("/bin/sh", args = ["-c",
    "exec " & quoteShell(cacheServerExe()) & " --root=" &
    quoteShell(result.root) & " --listen=127.0.0.1:" & $result.port &
    " >> " & quoteShell(result.logPath) & " 2>&1"])
  for _ in 0 ..< 100:
    let (_, c) = execCmdEx("curl -sf -o /dev/null http://127.0.0.1:" &
                           $result.port & "/healthz")
    if c == 0: return
    sleep(100)
  raise newException(TestBedError, "the binary cache did not start: " &
    readFile(result.logPath))

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

proc publishTree*(c: CacheServer; kp: PeerKeypair; action: ProfileBuildAction;
                  tree: string): string =
  ## Publish ``tree`` (the action's declared outputs, relative to it) as
  ## the action's entry, signed by ``kp``; returns the ``blake3:`` digest a
  ## manifest pins for it.
  let idy = buildActionCacheIdentity(action, GuestPlatform)
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
  mp.add("payload", archive, "prefix.rbcarc", "application/octet-stream")
  let client = newHttpClient(timeout = 30_000)
  defer: client.close()
  let resp = client.post(c.hostUrl & "/publish", multipart = mp)
  if not resp.code.is2xx:
    raise newException(TestBedError, "raw publish failed: " & $resp.code &
      " " & resp.body)
  "blake3:" & d.toHex()

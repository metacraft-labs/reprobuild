## Windows-Runner-Binary-Cache-Deploy M2 — cross-host publish→substitute driver.
##
## This is the client-side driver for the M2 gate
## ``t_cross_host_publish_substitute``. It runs on the *client* NixOS node
## and talks to a *server* node running ``services.mcl-repro-binary-cache``
## (the M1 systemd unit) over the VM network — a genuinely distinct routable
## endpoint, NOT 127.0.0.1.
##
## It generalises the loopback-only ``t_a3_p2_cli_substitute`` gate to a real
## two-host TCP path, and reuses the 5-member closure shape of
## ``t_a3_p6_closure_walk_r4`` (hex0 → stage0-posix → mescc-tools → mes → tcc)
## so the substitute walks a genuine multi-member deployment prefix.
##
## Phases (all against ``$REPRO_BINARY_CACHE_URL``, e.g.
## ``http://server:7878``):
##
##   1. PUBLISH — build 5 on-disk prefix directories with deterministic,
##      per-member multi-file contents (incl. a binary blob with NULs), derive
##      each member's cache-entry key with the previous member(s) threaded as
##      ``--dep`` references, and POST each signed manifest + payload to the
##      REMOTE server via ``publishInProcess``. Every payload therefore crosses
##      the wire on the way *up*.
##
##   2. SUBSTITUTE — from a FRESH, EMPTY local store (so nothing can be a local
##      cache hit), call ``substituteInProcess`` on the root (tcc) entry key.
##      This fetches the whole 5-member closure back over the wire.
##
##   3. ASSERT cross-host reality + byte-identity:
##        * plan length == 5 (the full closure was walked);
##        * every outcome ok, none ``skipped`` (skipped==true would mean a
##          local cache hit, not a network fetch);
##        * every outcome reports ``bytesFetched > 0`` — payload bytes actually
##          traversed the socket from the remote server;
##        * total bytes fetched across the closure > 0;
##        * for every member, the CAS blob materialised locally decodes as the
##          ``rbcarc-v1`` archive and re-extracts BYTE-IDENTICAL to the original
##          on-disk prefix tree that was published on the client before upload.
##
## Exit 0 on success; non-zero (with a diagnostic on stderr) on any failure.
## The NixOS test asserts exit 0.

import std/[algorithm, os, sequtils, strutils, tables]

import ../../libs/repro_binary_cache_client/src/repro_binary_cache_client
import ../../libs/repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes
import ../../libs/repro_peer_cache/src/repro_peer_cache/auth as peerAuth

const
  ArchiveMagic = "RBCA"
  ArchiveVersion = 1'u32

type
  Member = object
    name: string
    version: string
    prefixDir: string
    entryHex: string
    ## Absolute paths (relative to prefixDir) → original bytes, so the
    ## substitute-side re-extraction can be compared byte-for-byte.
    files: Table[string, string]

# ---------------------------------------------------------------------------
# rbcarc-v1 reader (mirror of the CLI/library archive layout) — used to prove
# the materialised CAS blob decodes back to the exact published tree.
# ---------------------------------------------------------------------------

proc readU32LE(buf: openArray[byte]; pos: var int): uint32 =
  if pos + 4 > buf.len:
    raise newException(IOError, "rbcarc truncated reading u32")
  result = 0'u32
  for i in 0 ..< 4:
    result = result or (uint32(buf[pos + i]) shl uint32(i * 8))
  inc pos, 4

proc readU64LE(buf: openArray[byte]; pos: var int): uint64 =
  if pos + 8 > buf.len:
    raise newException(IOError, "rbcarc truncated reading u64")
  result = 0'u64
  for i in 0 ..< 8:
    result = result or (uint64(buf[pos + i]) shl uint64(i * 8))
  inc pos, 8

proc decodeArchive(archive: openArray[byte]): Table[string, string] =
  ## Returns rel-path → bytes for every entry in the rbcarc-v1 archive.
  result = initTable[string, string]()
  if archive.len < 4 + 4 + 4:
    raise newException(IOError, "rbcarc too short: " & $archive.len)
  for i in 0 ..< 4:
    if archive[i] != byte(ArchiveMagic[i]):
      raise newException(IOError, "rbcarc magic mismatch at byte " & $i)
  var pos = 4
  let ver = readU32LE(archive, pos)
  if ver != ArchiveVersion:
    raise newException(IOError, "rbcarc version mismatch: got " & $ver)
  let count = readU32LE(archive, pos)
  for _ in 0 ..< count:
    let pathLen = int(readU32LE(archive, pos))
    if pos + pathLen > archive.len:
      raise newException(IOError, "rbcarc truncated reading path")
    var rel = newString(pathLen)
    for i in 0 ..< pathLen:
      rel[i] = char(archive[pos + i])
    inc pos, pathLen
    discard readU32LE(archive, pos)          # mode (unused for byte-compare)
    let size = readU64LE(archive, pos)
    if pos + int(size) > archive.len:
      raise newException(IOError, "rbcarc truncated reading body for " & rel)
    var data = newString(int(size))
    for i in 0 ..< int(size):
      data[i] = char(archive[pos + i])
    inc pos, int(size)
    result[rel] = data

# ---------------------------------------------------------------------------
# Member construction: on-disk prefix trees with deterministic content.
# ---------------------------------------------------------------------------

proc localPlatform(): PlatformTriple =
  let local = detectLocalPlatform("")
  PlatformTriple(cpu: local.cpu, os: local.os, abi: local.abi,
                 libcVariant: "")

proc buildPrefix(root, name, version: string; seed: int): Member =
  ## Populates a multi-file prefix tree (bin/text/binary) with content
  ## derived deterministically from ``seed`` so the substitute-side
  ## comparison has something concrete to assert.
  let prefixDir = root / ("prefix_" & name)
  removeDir(prefixDir)
  createDir(prefixDir / "bin")
  createDir(prefixDir / "share")
  createDir(prefixDir / "lib")

  let execBytes = "exec-" & name & "-v" & version & "\n"
  let readmeBytes = "package " & name & "\nversion " & version &
                    "\nseed " & $seed & "\n"
  var blob = newString(512 + seed * 13)
  for i in 0 ..< blob.len:
    blob[i] = char((i * (seed + 1) + seed) and 0xff)

  writeFile(prefixDir / "bin" / (name & ".bin"), execBytes)
  writeFile(prefixDir / "share" / "readme.txt", readmeBytes)
  writeFile(prefixDir / "lib" / "data.bin", blob)

  result.name = name
  result.version = version
  result.prefixDir = prefixDir
  result.files = {
    "bin/" & name & ".bin": execBytes,
    "share/readme.txt": readmeBytes,
    "lib/data.bin": blob,
  }.toTable

proc identityFor(name, version: string; seed: int;
                 deps: seq[string]): CacheEntryIdentity =
  result = newCacheEntryIdentity(
    packageName = name, packageVersion = version,
    platform = localPlatform(),
    toolchain = ToolchainIdentity(name: "stub", version: "1",
                                  hostLdSoAbi: "", extraFingerprint: ""),
    providerRevision = "m2-crosshost-rev-" & name)
  result.addOption("seed", $seed)
  for depHex in deps:
    result.addDep(depHex)

proc die(msg: string) =
  stderr.writeLine("t_cross_host_publish_substitute: " & msg)
  quit(1)

proc main() =
  let url = getEnv("REPRO_BINARY_CACHE_URL", "")
  if url.len == 0:
    die("REPRO_BINARY_CACHE_URL must be set to the remote server (e.g. http://server:7878)")
  if url.contains("127.0.0.1") or url.contains("localhost"):
    die("REPRO_BINARY_CACHE_URL points at loopback (" & url &
        "); M2 requires a genuinely remote endpoint")

  let work = getEnv("REPRO_M2_WORKDIR",
                    getTempDir() / "m2-crosshost")
  removeDir(work)
  createDir(work)
  let prefixRoot = work / "prefixes"
  createDir(prefixRoot)

  # A producer keypair on the client. The server accepts any signer (publish
  # authz is logged-only pre-M6) and substitute trusts any signer (v1), so a
  # client-generated key is sufficient to prove the transport path.
  let keyDir = work / "keys"
  createDir(keyDir)
  let keyPath = keyDir / "producer.key"
  let certPath = keyDir / "producer.cert"
  let kp = peerAuth.loadOrGenerateKeypair(certPath, keyPath)

  # ---- Phase 1: build + publish a 5-member closure to the REMOTE server ----
  # Chain: hex0 → stage0-posix → mescc-tools → mes → tcc (tcc depends on both
  # mes and mescc-tools, matching t_a3_p6). Deps are threaded as entry-key hex
  # so the published manifests carry real depReferences.
  var members: seq[Member] = @[]

  proc publishMember(name, version: string; seed: int;
                     depMembers: seq[int]): int =
    ## depMembers indexes into ``members`` (already published). Returns the
    ## index of the newly-published member.
    var depHexes: seq[string] = @[]
    for idx in depMembers:
      depHexes.add(members[idx].entryHex)
    var m = buildPrefix(prefixRoot, name, version, seed)
    let idy = identityFor(name, version, seed, depHexes)
    m.entryHex = deriveCacheEntryKeyHex(idy)
    let res = publishInProcess(PublishInProcessRequest(
      entryKeyHex: m.entryHex,
      prefixDir: m.prefixDir,
      identity: idy,
      endpoint: url,
      keypair: kp))
    if not res.ok:
      die("publish of " & name & " to " & url & " failed (status=" &
          $res.statusCode & "): " & res.error)
    if res.bytesUploaded <= 0:
      die("publish of " & name & " uploaded 0 bytes (nothing crossed the wire)")
    stderr.writeLine("published " & name & " (" & m.entryHex &
                     ") — uploaded " & $res.bytesUploaded & " bytes to " & url)
    members.add(m)
    return members.len - 1

  let iHex0   = publishMember("hex0", "stage0-posix-r1.9", 1, @[])
  let iStage0 = publishMember("stage0-posix", "r1.9", 3, @[iHex0])
  let iMescc  = publishMember("mescc-tools", "r1.9", 5, @[iStage0])
  let iMes    = publishMember("mes", "0.27.1", 7, @[iMescc])
  let iTcc    = publishMember("tinycc-bootstrappable", "ea3900f6", 11,
                              @[iMes, iMescc])
  discard iTcc

  let rootHex = members[iTcc].entryHex

  # ---- Phase 2: substitute the whole closure from a FRESH local store ----
  let clientStore = work / "client-store"
  removeDir(clientStore)
  createDir(clientStore)

  let endpoints = @[SubstituteEndpoint(
    baseUrl: url,
    trustedSigners: @[kp.publicKey],
    priority: 0)]
  let res = substituteInProcess(rootHex, clientStore, endpoints)
  if not res.ok:
    die("substitute of root " & rootHex & " from " & url & " failed: " &
        res.reason)

  # ---- Phase 3: assertions ----
  if res.plan.len != members.len:
    die("plan length " & $res.plan.len & " != expected " & $members.len &
        " (closure not fully walked)")

  if res.outcomes.len != members.len:
    die("outcome count " & $res.outcomes.len & " != expected " & $members.len)

  var totalFetched = 0'i64
  for outcome in res.outcomes:
    if not outcome.ok:
      die("substitute outcome not ok: " & outcome.reason)
    if outcome.skipped:
      die("a closure member was served from the LOCAL cache (skipped=true); " &
          "M2 requires every payload to come from the remote server")
    if outcome.bytesFetched <= 0:
      die("a closure member reported bytesFetched<=0; nothing crossed the " &
          "wire for it")
    totalFetched += outcome.bytesFetched
  if totalFetched <= 0:
    die("total bytesFetched across the closure was 0")

  # Byte-identity: every member's materialised CAS blob must re-extract to the
  # exact bytes we published. Map each plan step's entry-key hex to the member
  # we built, decode the CAS archive, compare every file.
  var hexToMember = initTable[string, int]()
  for i, m in members:
    hexToMember[m.entryHex.toLowerAscii()] = i

  var verified = 0
  for i, step in res.plan:
    let outcome = res.outcomes[i]
    let keyHex = step.entryKeyHex.toLowerAscii()
    if keyHex notin hexToMember:
      die("plan step " & keyHex & " does not correspond to any published member")
    let member = members[hexToMember[keyHex]]
    if outcome.casPath.len == 0 or not fileExists(outcome.casPath):
      die("member " & member.name & " has no materialised CAS path")
    let raw = readFile(outcome.casPath)
    var asBytes = newSeq[byte](raw.len)
    for j, ch in raw:
      asBytes[j] = byte(ch)
    let extracted =
      try: decodeArchive(asBytes)
      except IOError as e:
        die("member " & member.name & " CAS blob is not a valid rbcarc: " & e.msg)
        return
    # Same set of files.
    var wantKeys = toSeq(member.files.keys)
    var gotKeys = toSeq(extracted.keys)
    wantKeys.sort()
    gotKeys.sort()
    if wantKeys != gotKeys:
      die("member " & member.name & " file set mismatch: published " &
          $wantKeys & " but materialised " & $gotKeys)
    for rel, want in member.files:
      if extracted[rel] != want:
        die("member " & member.name & " file " & rel &
            " is NOT byte-identical after cross-host substitute")
    inc verified

  if verified != members.len:
    die("only verified " & $verified & "/" & $members.len & " members")

  echo "OK cross-host publish→substitute: url=" & url &
       " members=" & $members.len &
       " root=" & rootHex &
       " total_bytes_fetched=" & $totalFetched
  quit(0)

when isMainModule:
  main()

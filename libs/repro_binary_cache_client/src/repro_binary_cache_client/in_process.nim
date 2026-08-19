## ReproOS-Generations-And-Foreign-Packages A2.5 — single-user wrapper.
##
## Per the spec § Multi-user vs single-user mode: when a build tool
## opts out of the daemon (CI runners, container builds), it calls
## ``substituteInProcess`` directly. The wrapper builds a per-call
## ``ClientContext`` + ``HttpPool`` + ``ClientIndex``, walks the
## closure, and tears them down. No IPC, no daemon, same code path.
##
## Trades pool reuse + cache-info warm-cache for zero daemon
## management overhead. Appropriate when:
##
##   * One-shot CI runs (each job spawns a fresh ``repro build``).
##   * Container builds (the daemon would never amortise its
##     cost across builds).
##   * Test fixtures (the tests themselves run in this mode).
##
## M9.L.4-refactor Step A: ``publishInProcess`` lifts the publish
## pipeline (pack prefix → BLAKE3 → build + sign manifest → multipart
## POST) out of ``apps/repro-binary-cache-client/`` so the engine's
## new ``binaryCachePublisher`` closure can call it directly without
## shelling out to the CLI. The CLI's ``cmdPublish`` is refactored to
## a thin wrapper that builds a ``PublishInProcessRequest`` from CLI
## flags and forwards.

import std/[algorithm, httpclient, httpcore, net, os,
            sequtils, strutils, tempfiles, times]

when defined(ssl):
  import wrappers/openssl

import blake3

import ./types
import ./http_pool
import ./scheduler_executor
import ./closure_walk
import ./index
import ./cache_key

import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes
import ../../../repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec as serverCodec
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

export peerAuth.PeerKeypair

type
  InProcessOutcome* = object
    plan*: seq[SubstitutePlan]
    outcomes*: seq[SubstituteOutcome]
    ok*: bool
    reason*: string

  PublishInProcessRequest* = object
    ## M9.L.4-refactor Step A. Self-contained request carrying every
    ## byte the publish pipeline needs. Mirrors the CLI's flag set so
    ## a CLI caller can build one from its parsed args without any
    ## drift.
    ##
    ## Fields:
    ##   * ``entryKeyHex`` — 64-char lowercase hex; the caller-asserted
    ##     entry key. The publisher re-derives the key from
    ##     ``identity`` and HARD-FAILS if they disagree (drift guard
    ##     ported from ``cmdPublish``).
    ##   * ``prefixDir`` — absolute path to the staging tree to pack.
    ##     The publisher tolerates a single-file prefix (the v1 CLI
    ##     also does) by wrapping it into a one-entry archive.
    ##   * ``identity`` — full ``CacheEntryIdentity`` used both for
    ##     the drift-guard re-derivation and to sign the manifest.
    ##     Callers MUST populate every field they want reflected in
    ##     the entry key; missing fields produce a DIFFERENT key
    ##     (intentional — the canonical encoder is injective).
    ##   * ``endpoint`` — base URL like ``http://localhost:7878``.
    ##     The publisher appends ``/publish`` to this.
    ##   * ``keypair`` — ECDSA-P256 signing key + matching pubkey, in
    ##     the shape the ``repro_peer_cache.auth`` module supplies.
    ##     Required; the publisher refuses to run without one.
    entryKeyHex*: string
    prefixDir*: string
    identity*: CacheEntryIdentity
    endpoint*: string
    keypair*: peerAuth.PeerKeypair
    ## Zero selects the protocol maximum. Positive values may lower it.
    maxArchiveBytes*: int64

  PublishInProcessResult* = object
    ## Outcome of a single ``publishInProcess`` call.
    ##   * ``ok``  — true iff the server responded 2xx.
    ##   * ``statusCode`` — HTTP status from ``/publish``; ``0`` when
    ##     the call short-circuited before issuing the request
    ##     (e.g. drift-guard failed).
    ##   * ``error`` — populated on ``!ok`` with the diagnostic.
    ##     Empty on success.
    ##   * ``bytesUploaded`` — wire-bytes of the multipart body
    ##     uploaded (manifest + payload + framing); 0 on early
    ##     short-circuit.
    ##   * ``responseBody`` — server-side echo (the published
    ##     entry-key hex on success). Kept so CLI callers can keep
    ##     printing the same diagnostic line.
    ok*: bool
    statusCode*: int
    error*: string
    bytesUploaded*: int
    responseBody*: string

const
  ArchiveMagic = "RBCA"
  ArchiveVersion = 2'u32
  ArchiveVersionV1 = 1'u32
  # The server accepts 1 GiB request bodies. Reserve ample room for the
  # signed manifest and multipart framing before deciding a payload fits.
  MaxPublishBodyBytes = 1024'i64 * 1024 * 1024
  MultipartFramingAllowance = 1024'i64 * 1024
  DefaultMaxPublishArchiveBytes* =
    MaxPublishBodyBytes - MultipartFramingAllowance
  ArchiveCopyBufferBytes = 256 * 1024

type
  ArchiveEntryKind = enum
    aekFile = 0
    aekDirectory = 1
    aekSymlink = 2

  ArchiveEntry = object
    path: string
    kind: ArchiveEntryKind

  PrefixArchivePlan = object
    root: string
    rootIsDirectory: bool
    entries: seq[ArchiveEntry]
    size: int64

  ArchiveFileWriter = object
    output: File
    hasher: Blake3Hasher
    bytesWritten: int64

# ---------------------------------------------------------------------------
# Archive writer (the shared deterministic ``rbcarc-v2`` writer).
#
# Kept in the library so engine-side callers don't pay the cost of
# shelling out to the CLI; the CLI's local copy delegates here.
# ---------------------------------------------------------------------------

proc writeU32LE(buf: var seq[byte]; v: uint32) =
  for shift in countup(0, 24, 8):
    buf.add(byte((v shr uint32(shift)) and 0xff'u32))

proc writeU64LE(buf: var seq[byte]; v: uint64) =
  for shift in countup(0, 56, 8):
    buf.add(byte((v shr uint64(shift)) and 0xff'u64))

proc normaliseSep(p: string): string =
  result = p.replace('\\', '/')

proc collectPrefixEntries(current, relativeBase: string;
                          entries: var seq[ArchiveEntry]) =
  for component, path in walkDir(current, skipSpecial = true):
    let name = extractFilename(path)
    let relativePath =
      if relativeBase.len == 0: name else: relativeBase / name
    case component
    of pcFile:
      entries.add(ArchiveEntry(
        path: normaliseSep(relativePath), kind: aekFile))
    of pcDir:
      entries.add(ArchiveEntry(
        path: normaliseSep(relativePath), kind: aekDirectory))
      collectPrefixEntries(path, relativePath, entries)
    of pcLinkToFile, pcLinkToDir:
      entries.add(ArchiveEntry(
        path: normaliseSep(relativePath), kind: aekSymlink))

proc walkPrefix(prefix: string): seq[ArchiveEntry] =
  let prefixAbs = absolutePath(prefix)
  collectPrefixEntries(prefixAbs, "", result)
  result.sort(proc(a, b: ArchiveEntry): int = cmp(a.path, b.path))

proc filePermissionsMode*(permissions: set[FilePermission]): uint32 =
  if fpUserRead in permissions: result = result or 0o400'u32
  if fpUserWrite in permissions: result = result or 0o200'u32
  if fpUserExec in permissions: result = result or 0o100'u32
  if fpGroupRead in permissions: result = result or 0o040'u32
  if fpGroupWrite in permissions: result = result or 0o020'u32
  if fpGroupExec in permissions: result = result or 0o010'u32
  if fpOthersRead in permissions: result = result or 0o004'u32
  if fpOthersWrite in permissions: result = result or 0o002'u32
  if fpOthersExec in permissions: result = result or 0o001'u32

proc modeFilePermissions*(mode: uint32): set[FilePermission] =
  if (mode and 0o400'u32) != 0: result.incl(fpUserRead)
  if (mode and 0o200'u32) != 0: result.incl(fpUserWrite)
  if (mode and 0o100'u32) != 0: result.incl(fpUserExec)
  if (mode and 0o040'u32) != 0: result.incl(fpGroupRead)
  if (mode and 0o020'u32) != 0: result.incl(fpGroupWrite)
  if (mode and 0o010'u32) != 0: result.incl(fpGroupExec)
  if (mode and 0o004'u32) != 0: result.incl(fpOthersRead)
  if (mode and 0o002'u32) != 0: result.incl(fpOthersWrite)
  if (mode and 0o001'u32) != 0: result.incl(fpOthersExec)

proc fileModeOctal*(path: string): uint32 =
  ## Preserves POSIX permission bits. Windows has no equivalent metadata,
  ## so executable-looking extensions retain the portable 0o755 fallback.
  when defined(windows):
    let lower = path.toLowerAscii()
    if lower.endsWith(".exe") or lower.endsWith(".com") or
       lower.endsWith(".bat") or lower.endsWith(".ps1") or
       lower.endsWith(".sh"):
      return 0o755'u32
    return 0o644'u32
  else:
    filePermissionsMode(getFilePermissions(path))

proc archiveEntryPath(plan: PrefixArchivePlan;
                      entry: ArchiveEntry): string =
  if plan.rootIsDirectory: plan.root / entry.path else: plan.root

proc archiveEntryPayloadSize(plan: PrefixArchivePlan;
                             entry: ArchiveEntry): int64 =
  let path = archiveEntryPath(plan, entry)
  case entry.kind
  of aekFile: getFileSize(path)
  of aekDirectory: 0
  of aekSymlink: int64(expandSymlink(path).len)

proc planPrefixArchive(prefix: string): PrefixArchivePlan =
  result.root = absolutePath(prefix)
  result.rootIsDirectory = dirExists(prefix)
  result.entries =
    if result.rootIsDirectory:
      walkPrefix(result.root)
    else:
      @[ArchiveEntry(path: extractFilename(result.root), kind: aekFile)]
  if uint64(result.entries.len) > uint64(high(uint32)):
    raise newException(IOError, "rbcarc contains too many entries")
  result.size = 12 # magic, version, and entry count
  for entry in result.entries:
    if uint64(entry.path.len) > uint64(high(uint32)):
      raise newException(IOError, "rbcarc path is too long: " & entry.path)
    let payloadSize = archiveEntryPayloadSize(result, entry)
    if payloadSize < 0:
      raise newException(IOError,
        "cannot determine rbcarc payload size: " & entry.path)
    let entrySize = 4'i64 + int64(entry.path.len) + 1 + 4 + 8 + payloadSize
    if result.size > high(int64) - entrySize:
      raise newException(IOError, "rbcarc size exceeds int64 capacity")
    result.size += entrySize

proc littleEndianBytes(value: uint64; width: int): string =
  result = newString(width)
  for i in 0 ..< width:
    result[i] = char((value shr uint64(i * 8)) and 0xff'u64)

proc writeArchiveBytes(writer: var ArchiveFileWriter;
                       data: pointer; dataLen: int) =
  if dataLen == 0:
    return
  if writer.output.writeBuffer(data, dataLen) != dataLen:
    raise newException(IOError, "short write while creating rbcarc")
  writer.hasher.update(data, dataLen)
  writer.bytesWritten += int64(dataLen)

proc writeArchiveString(writer: var ArchiveFileWriter; data: string) =
  if data.len > 0:
    writer.writeArchiveBytes(unsafeAddr data[0], data.len)

proc writeArchiveFile(plan: PrefixArchivePlan; output: File): Blake3Digest =
  var writer = ArchiveFileWriter(output: output, hasher: initHasher())
  defer: writer.hasher.close()
  writer.writeArchiveString(ArchiveMagic)
  writer.writeArchiveString(littleEndianBytes(uint64(ArchiveVersion), 4))
  writer.writeArchiveString(littleEndianBytes(uint64(plan.entries.len), 4))
  for entry in plan.entries:
    let path = archiveEntryPath(plan, entry)
    writer.writeArchiveString(littleEndianBytes(uint64(entry.path.len), 4))
    writer.writeArchiveString(entry.path)
    writer.writeArchiveString($char(ord(entry.kind)))
    let mode =
      if entry.kind == aekSymlink: 0'u32 else: fileModeOctal(path)
    writer.writeArchiveString(littleEndianBytes(uint64(mode), 4))
    let payloadSize = archiveEntryPayloadSize(plan, entry)
    writer.writeArchiveString(littleEndianBytes(uint64(payloadSize), 8))
    case entry.kind
    of aekFile:
      var input: File
      if not open(input, path, fmRead):
        raise newException(IOError, "cannot open rbcarc input: " & path)
      try:
        var buffer = newString(ArchiveCopyBufferBytes)
        while true:
          let bytesRead = input.readBuffer(addr buffer[0], buffer.len)
          if bytesRead == 0:
            break
          writer.writeArchiveBytes(addr buffer[0], bytesRead)
      finally:
        close(input)
    of aekDirectory:
      discard
    of aekSymlink:
      writer.writeArchiveString(expandSymlink(path))
  if writer.bytesWritten != plan.size:
    raise newException(IOError,
      "rbcarc size changed while archiving: expected " & $plan.size &
      ", wrote " & $writer.bytesWritten)
  result = writer.hasher.finalize()

proc packPrefix*(prefix: string): seq[byte] =
  ## Builds the deterministic archive bytes for the prefix tree. Same
  ## ``rbcarc-v2`` layout the CLI documents at the top of
  ## ``repro_binary_cache_client_cli.nim``.
  let entries = walkPrefix(prefix)
  result = newSeqOfCap[byte](4096)
  for ch in ArchiveMagic:
    result.add(byte(ch))
  writeU32LE(result, ArchiveVersion)
  writeU32LE(result, uint32(entries.len))
  for entry in entries:
    let absPath = prefix / entry.path
    let mode =
      if entry.kind == aekSymlink: 0'u32 else: fileModeOctal(absPath)
    let pathBytes = entry.path
    let payload =
      case entry.kind
      of aekFile: readFile(absPath)
      of aekDirectory: ""
      of aekSymlink: expandSymlink(absPath)
    writeU32LE(result, uint32(pathBytes.len))
    for ch in pathBytes:
      result.add(byte(ch))
    result.add(byte(ord(entry.kind)))
    writeU32LE(result, mode)
    writeU64LE(result, uint64(payload.len))
    for ch in payload:
      result.add(byte(ch))

proc packSingleFilePrefix*(prefixPath: string): seq[byte] =
  ## Wraps a single-file prefix into a one-entry archive so the
  ## substitute path can extract uniformly. Mirrors the
  ## ``not dirExists`` branch in ``cmdPublish``.
  var pref = absolutePath(prefixPath)
  let name = extractFilename(pref)
  result = @[]
  for ch in ArchiveMagic:
    result.add(byte(ch))
  writeU32LE(result, ArchiveVersion)
  writeU32LE(result, 1'u32)
  writeU32LE(result, uint32(name.len))
  for ch in name: result.add(byte(ch))
  result.add(byte(ord(aekFile)))
  writeU32LE(result, fileModeOctal(pref))
  let body = readFile(pref)
  writeU64LE(result, uint64(body.len))
  for ch in body: result.add(byte(ch))

# ---------------------------------------------------------------------------
# Archive reader (mirror of the CLI's ``extractPrefix``).
#
# Windows-Runner-Binary-Cache-Deploy M4: the apply-time build-action
# substitute path (``repro_profile_compile.apply_build_actions``) needs
# to MATERIALISE a substituted prefix archive from CAS back into a
# target directory, byte-identically, the same way the CLI's
# ``substitute`` command does. Keeping the reader in the library next to
# ``packPrefix`` lets every verifier and apply dispatcher share the exact
# version-aware extraction logic without shelling out to the CLI.
# ---------------------------------------------------------------------------

proc readU32LE(buf: openArray[byte]; pos: var int): uint32 =
  result = 0
  for shift in countup(0, 24, 8):
    result = result or (uint32(buf[pos]) shl uint32(shift))
    inc pos

proc readU64LE(buf: openArray[byte]; pos: var int): uint64 =
  result = 0
  for shift in countup(0, 56, 8):
    result = result or (uint64(buf[pos]) shl uint64(shift))
    inc pos

proc extractPrefix*(archive: openArray[byte]; outDir: string) =
  ## Extract an ``rbcarc-v1`` or ``rbcarc-v2`` archive into ``outDir``.
  ## v2 preserves regular files, directory entries, and symbolic links;
  ## v1 remains accepted so already-published cache entries keep working.
  ## Raises
  ## ``IOError`` on a malformed / truncated archive.
  if archive.len < 4 + 4 + 4:
    raise newException(IOError, "rbcarc too short: " & $archive.len)
  for i in 0 ..< 4:
    if archive[i] != byte(ArchiveMagic[i]):
      raise newException(IOError, "rbcarc magic mismatch at byte " & $i)
  var pos = 4
  let ver = readU32LE(archive, pos)
  if ver notin {ArchiveVersionV1, ArchiveVersion}:
    raise newException(IOError, "rbcarc version mismatch: got " & $ver)
  let count = readU32LE(archive, pos)
  createDir(outDir)
  var directoryModes: seq[(string, uint32)] = @[]
  for _ in 0 ..< count:
    let pathLen = int(readU32LE(archive, pos))
    if pos + pathLen > archive.len:
      raise newException(IOError, "rbcarc truncated reading path")
    var rel = newString(pathLen)
    for i in 0 ..< pathLen:
      rel[i] = char(archive[pos + i])
    inc pos, pathLen
    let normalizedRel = normaliseSep(rel)
    if normalizedRel.len == 0 or normalizedRel.startsWith("/") or
        normalizedRel.split('/').anyIt(it.len == 0 or it == "." or it == ".."):
      raise newException(IOError, "rbcarc rejected unsafe path: " & rel)
    let entryKind =
      if ver == ArchiveVersionV1:
        aekFile
      else:
        if pos >= archive.len:
          raise newException(IOError, "rbcarc truncated reading entry kind")
        let rawKind = archive[pos]
        inc pos
        if rawKind > byte(ord(high(ArchiveEntryKind))):
          raise newException(IOError, "rbcarc invalid entry kind: " & $rawKind)
        ArchiveEntryKind(rawKind)
    let mode = readU32LE(archive, pos)
    let size = readU64LE(archive, pos)
    if pos + int(size) > archive.len:
      raise newException(IOError,
        "rbcarc truncated reading file body for " & rel)
    let absOut = outDir / rel
    createDir(parentDir(absOut))
    var data = newString(int(size))
    for i in 0 ..< int(size):
      data[i] = char(archive[pos + i])
    inc pos, int(size)
    case entryKind
    of aekFile:
      writeFile(absOut, data)
      when not defined(windows):
        setFilePermissions(absOut, modeFilePermissions(mode))
    of aekDirectory:
      if data.len != 0:
        raise newException(IOError,
          "rbcarc directory entry has a non-empty payload: " & rel)
      createDir(absOut)
      directoryModes.add((absOut, mode))
    of aekSymlink:
      if data.len == 0:
        raise newException(IOError,
          "rbcarc symlink entry has an empty target: " & rel)
      createSymlink(data, absOut)
  when not defined(windows):
    if directoryModes.len > 0:
      for i in countdown(directoryModes.high, 0):
        setFilePermissions(
          directoryModes[i][0], modeFilePermissions(directoryModes[i][1]))

# ---------------------------------------------------------------------------
# Multipart body builder.
# ---------------------------------------------------------------------------

proc buildMultipartBody*(boundary: string;
                         manifestBytes: openArray[byte];
                         payload: openArray[byte]): string =
  result = ""
  result.add("--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"manifest\"\r\n\r\n")
  for b in manifestBytes:
    result.add(char(b))
  result.add("\r\n")
  result.add("--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"payload\"\r\n\r\n")
  for b in payload:
    result.add(char(b))
  result.add("\r\n")
  result.add("--" & boundary & "--\r\n")

# ---------------------------------------------------------------------------
# substituteInProcess.
# ---------------------------------------------------------------------------

proc substituteInProcess*(rootEntryKeyHex: string;
                          storeRoot: string;
                          endpoints: seq[SubstituteEndpoint]):
                            InProcessOutcome =
  ## Walk + materialise a closure rooted at ``rootEntryKeyHex`` via
  ## the first endpoint that successfully returns the root manifest.
  ## On any endpoint failure the wrapper records the reason and tries
  ## the next configured endpoint.
  result.ok = false
  if endpoints.len == 0:
    result.reason = "no substitute endpoints configured"
    return

  let cfg = defaultConfig(storeRoot, endpoints)
  let ctx = newClientContext(cfg)
  defer: ctx.close()
  let pool = newHttpPool(maxConnections = cfg.maxConnectionsPerHost * endpoints.len)
  defer: pool.close()
  let idx = openClientIndex(storeRoot)

  for endpoint in endpoints:
    try:
      let plan = planClosure(ctx, pool, endpoint, rootEntryKeyHex)
      var allOk = true
      var outcomes: seq[SubstituteOutcome] = @[]
      for step in plan:
        let req = SubstituteRequest(
          entryKeyHex: step.entryKeyHex,
          endpoint: endpoint)
        let outcome = executeSubstituteAction(ctx, pool, req, idx)
        outcomes.add(outcome)
        if not outcome.ok:
          allOk = false
          break
      if allOk:
        result.ok = true
        result.plan = plan
        result.outcomes = outcomes
        try: idx.flush() except CatchableError: discard
        return
      else:
        result.outcomes = outcomes
        result.reason = "one or more substitutes failed on " & endpoint.baseUrl
    except CatchableError as e:
      result.reason = "endpoint " & endpoint.baseUrl & ": " & e.msg
      continue
  # Fall-through: every endpoint failed.
  if result.reason.len == 0:
    result.reason = "no endpoint produced a usable manifest"

# ---------------------------------------------------------------------------
# publishInProcess.
# ---------------------------------------------------------------------------

proc publishInProcess*(req: PublishInProcessRequest): PublishInProcessResult =
  ## M9.L.4-refactor Step A. Lifts the body of
  ## ``cmdPublish`` (apps/repro-binary-cache-client/repro_binary_cache_
  ## client_cli.nim §cmdPublish 461-543) into the library so the
  ## engine's ``binaryCachePublisher`` closure can call it directly.
  ##
  ## Pipeline:
  ##
  ##   1. Drift-guard: derive the entry key from ``identity`` and
  ##      compare against ``entryKeyHex``; hard-fail on mismatch.
  ##      Without this gate, a stale baked-in hex on the caller side
  ##      would silently publish under the wrong key.
  ##   2. Plan the deterministic ``rbcarc-v2`` archive and reject payloads
  ##      that cannot fit within the server's publish-request limit.
  ##   3. Stream the archive to a temporary file while calculating its
  ##      BLAKE3-256 digest; populate the ``PayloadObject``
  ##      descriptor + ``realizedPrefixDigest`` (placeholder == payload
  ##      digest for v1).
  ##   4. Build + sign the ``BinaryCacheManifest`` (key, payloads,
  ##      depReferences, relocationPolicy=optional, createdAtUnix).
  ##   5. Stream the manifest + payload as multipart/form-data to
  ##      ``<endpoint>/publish`` without retaining the archive in memory.
  ##
  ## Soft-fail semantics: every error populates ``result.error`` and
  ## leaves ``result.ok == false``. The caller decides whether a
  ## publish failure aborts its workflow (the CLI: yes; the engine
  ## hook: no, per spec).
  result.ok = false

  # Drift-guard: confirm the supplied hex matches the identity-derived
  # hex BEFORE we touch the network. Without this check, a stale baked-
  # in hex would silently publish under the wrong key.
  let derivedKey = deriveCacheEntryKey(req.identity)
  let derivedHex = cacheEntryKeyHex(derivedKey)
  if derivedHex != req.entryKeyHex:
    result.error = "publish: identity-derived key does not match " &
      "supplied entry-key hex.\n" &
      "  supplied:  " & req.entryKeyHex & "\n" &
      "  derived:   " & derivedHex
    return

  # Prefix path must exist.
  if not dirExists(req.prefixDir) and not fileExists(req.prefixDir):
    result.error = "publish: prefix path does not exist: " & req.prefixDir
    return

  let archivePlan =
    try:
      planPrefixArchive(req.prefixDir)
    except CatchableError as e:
      result.error = "publish: cannot plan prefix archive: " & e.msg
      return
  if req.maxArchiveBytes < 0:
    result.error = "publish: maxArchiveBytes cannot be negative"
    return
  let maxArchiveBytes =
    if req.maxArchiveBytes == 0:
      DefaultMaxPublishArchiveBytes
    else:
      min(req.maxArchiveBytes, DefaultMaxPublishArchiveBytes)
  if archivePlan.size > maxArchiveBytes:
    result.error = "publish skipped: prefix archive is " &
      $archivePlan.size & " bytes, exceeding the " & $maxArchiveBytes &
      "-byte /publish payload limit"
    return

  var archiveFile: File
  var archivePath = ""
  var archiveOpen = false
  defer:
    if archiveOpen:
      try: close(archiveFile)
      except CatchableError: discard
    if archivePath.len > 0 and fileExists(archivePath):
      try: removeFile(archivePath)
      except CatchableError: discard
  var rawDigest: Blake3Digest
  try:
    let temp = createTempFile("repro-publish-", ".rbcarc")
    archiveFile = temp.cfile
    archivePath = temp.path
    archiveOpen = true
    rawDigest = writeArchiveFile(archivePlan, archiveFile)
    close(archiveFile)
    archiveOpen = false
  except CatchableError as e:
    result.error = "publish: cannot create prefix archive: " & e.msg
    return
  var payloadDigest: bcsTypes.Blake3Hash
  for i in 0 ..< 32:
    payloadDigest[i] = rawDigest[i]
  # Realized prefix digest: re-use the payload hash as v1 placeholder.
  var realizedDigest: bcsTypes.Blake3Hash = payloadDigest

  # Build dep-references (32-byte digests) from the identity's
  # dep-closure list. The closure is already lowercased + validated by
  # ``addDep`` so we just hex-decode each entry.
  var depRefs: seq[bcsTypes.Blake3Hash] = @[]
  for depHex in req.identity.depClosure:
    depRefs.add(hexToDigest(depHex))

  let payloadObj = bcsTypes.PayloadObject(
    kind: bcsTypes.pkPrefixArchive,
    compression: bcsTypes.ckNone,
    declaredSize: uint64(archivePlan.size),
    uncompressedSize: uint64(archivePlan.size),
    digest: payloadDigest,
    name: "prefix.rbcarc")
  var manifest = bcsTypes.BinaryCacheManifest(
    formatVersion: bcsTypes.BinaryCacheFormatVersion,
    entryKey: derivedKey,
    payloads: @[payloadObj],
    realizedPrefixDigest: realizedDigest,
    depReferences: depRefs,
    relocationPolicy: bcsTypes.rpOptional,
    createdAtUnix: getTime().toUnix())
  serverCodec.signManifest(req.keypair, manifest)
  let manifestBytes = serverCodec.encodeManifest(manifest)

  var manifestContent = newString(manifestBytes.len)
  for i, value in manifestBytes:
    manifestContent[i] = char(value)
  let multipart = newMultipartData()
  multipart.add("manifest", manifestContent)
  discard multipart.addFiles({"payload": archivePath})
  let baseUrl =
    if req.endpoint.len > 0: req.endpoint
    else: "http://localhost:7878"
  let url = baseUrl & "/publish"
  # Windows-Runner-Binary-Cache-Deploy M6 — publish over HTTPS when the
  # endpoint is https://. Under -d:ssl we hand newHttpClient an SSL
  # context resolved from the same env knobs the GET path uses
  # (REPRO_BINARY_CACHE_CA_FILE / REPRO_BINARY_CACHE_TLS_INSECURE);
  # otherwise std/httpclient's getDefaultSSL() would reject verification
  # of a self-signed server cert.
  when defined(ssl):
    var openSslInitialized {.global.} = false
    if not openSslInitialized:
      discard SSL_library_init()
      openSslInitialized = true
  let client =
    when defined(ssl):
      if baseUrl.toLowerAscii().startsWith("https://"):
        let caFile = getEnv("REPRO_BINARY_CACHE_CA_FILE", "")
        let insecure = getEnv("REPRO_BINARY_CACHE_TLS_INSECURE", "") in
          ["1", "true", "yes"]
        let ctx =
          if insecure: newContext(verifyMode = CVerifyNone)
          elif caFile.len > 0: newContext(verifyMode = CVerifyPeer, caFile = caFile)
          else: newContext(verifyMode = CVerifyPeer)
        newHttpClient(timeout = 60_000, sslContext = ctx)
      else:
        newHttpClient(timeout = 60_000, sslContext = nil)
    else:
      newHttpClient(timeout = 60_000)
  defer: client.close()
  try:
    let resp = client.request(url, HttpPost, multipart = multipart)
    result.bytesUploaded = int(parseBiggestInt(client.headers["Content-Length"]))
    result.statusCode = int(resp.code)
    result.responseBody = resp.body
    if result.statusCode >= 300:
      result.error = "publish failed: HTTP " & $resp.code & " " &
        result.responseBody
      return
    result.ok = true
  except CatchableError as e:
    result.error = "publish failed: " & e.msg

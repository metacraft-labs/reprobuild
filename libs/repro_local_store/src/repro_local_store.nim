import std/[algorithm, options, os, osproc, sets, strutils, tables, times]

when defined(posix):
  import std/posix

when defined(windows):
  import std/winlean

when defined(posix):
  # Nim's `std/posix` does not expose `flock(2)` uniformly across macOS and
  # Linux, so bind the small `sys/file.h` surface directly (mirrors
  # repro_home_generations/locks.nim). Used to serialize the durable
  # per-cache-root write-sequence counter (AC-1b: deterministic newest-wins
  # record ordering) across concurrent build engine processes.
  const
    SeqLockExclusive = 2.cint

  proc cFlockSeq(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}

import repro_core
import repro_hash
import repro_shm_index

# Re-export the new M56 content-addressed local store API. The pre-M56
# `LocalCas` and `ActionCache` types below remain for the action-cache
# code path the M9 build engine still consumes; the M56 entry points
# live in `repro_local_store/store.nim` and
# `repro_local_store/sqlite3_binding.nim`.
import ./repro_local_store/sqlite3_binding
import ./repro_local_store/store
import ./repro_local_store/lru_eviction
import ./repro_local_store/sandbox_manifest
export sqlite3_binding
export store
export lru_eviction
export sandbox_manifest

type
  LocalStoreError* = object of CatchableError
  CacheIntegrityError* = object of LocalStoreError
  ActionRecordError* = object of LocalStoreError

  FileFingerprintPolicy* = enum
    ffpTimestamp
    ffpChecksum
    ffpHybrid

  FingerprintedFileKind* = enum
    ffkMissing
    ffkRegular
    ffkDirectory
    ffkOther

  FileMetadata* = object
    kind*: FingerprintedFileKind
    sizeBytes*: uint64
    mtimeNs*: uint64

  FileFingerprint* = object
    path*: string
    policy*: FileFingerprintPolicy
    metadata*: FileMetadata
    hasLocalHash*: bool
    localHash*: LocalInvalidationHash

  CasBlobRef* = object
    digest*: ContentDigest
    sizeBytes*: uint64

  OutputPayloadKind* = enum
    opkCasBlobs
    opkMetadataOnly

  OutputBlob* = object
    path*: string
    metadata*: FileMetadata
    blob*: CasBlobRef
    permissions*: set[FilePermission]

  ActionResultRecord* = object
    weakFingerprint*: ContentDigest
    policy*: FileFingerprintPolicy
    inputs*: seq[FileFingerprint]
    strongFingerprint*: ContentDigest
    outputPayloadKind*: OutputPayloadKind
    outputs*: seq[OutputBlob]

  LocalCas* = object
    root*: string

  ShmTier* = ref object
    ## The engine's attached view of the shared-memory hot tier (AC-2c) for one
    ## cache root. A `ref` so an `ActionCache` VALUE can be copied (the warm
    ## handle in the engine is copied in/out of a process-wide table) without
    ## duplicating the mapped fds / double-attaching / double-closing — every
    ## copy shares the one attached index. `enabled` gates the whole tier: when
    ## false (non-POSIX, no atomics, attach failed, or opted out) every read is
    ## pure Tier-1 disk and every record is Tier-1-only — exactly AC-1b behavior.
    enabled*: bool
    idx*: ShmIndex
    readerSlot*: int

  ActionCache* = object
    root*: string
    shm*: ShmTier
      ## The optional shared-memory accelerator (AC-2c). nil / disabled ⇒ pure
      ## Tier-1 disk-only (the AC-1b path). The DECISION (hit/miss/strong-fp) is
      ## identical either way; shm only changes where a metadata record is
      ## SOURCED (shm-first, warm-on-miss) and adds a ring submit on record.
    # Root holding the authoritative per-edge record store. Each edge (keyed
    # by its weak fingerprint via `perEdgeDirName`) owns a DIRECTORY
    # `hot-records/<key>/` containing one `<nonce>.rec` file per observed
    # path-set (AC-1b, Action-Cache-Per-Edge-Store.md §3, §8). There is no
    # global append-only log; every write is a temp-file + atomic-rename
    # publish of a SINGLE path-set's `.rec` file, so cross-edge contention is
    # impossible AND two independent concurrent builds of the same edge that
    # saw DIFFERENT path-sets never clobber each other (last-rename-wins
    # affected only the single AC-1 file; here they target distinct `.rec`
    # nonces). Identical path-sets converge on the same nonce file. A
    # pre-existing AC-1 single `hot-records/<key>` FILE is still read for
    # back-compat.
    hotRoot: string

  FileMetadataCache* = object
    entries: Table[string, FileMetadata]
    stats: FileMetadataCacheStats

  FileMetadataCacheStats* = object
    currentRunHits*: int
    coldStats*: int
    warmEntries*: int
    warmRevalidated*: int
    warmUnchanged*: int
    warmChanged*: int

  ActionCacheLookupStatus* = enum
    aclMissNoRecord
    aclMissInputChanged
    aclMissNoOutputPayload
    aclHit
    aclHybridCutoff
    aclRejectedCorruptOutput

  ActionCacheLookup* = object
    status*: ActionCacheLookupStatus
    record*: ActionResultRecord
    message*: string
    changedInputPath*: string

  HotMetadataProbe* = object
    weakFingerprint*: ContentDigest
    policy*: FileFingerprintPolicy

  HotMetadataScanStatus* = enum
    hmssUnavailable
    hmssHit
    hmssMissingRecord
    hmssInputChanged
    hmssCorrupt

  HotMetadataScan* = object
    status*: HotMetadataScanStatus
    recordCount*: int
    inputCount*: int
    checkedInputCount*: int

const
  ActionRecordMagic = "RBAR"
  ActionRecordVersion = 3'u16
  # Per-edge record file: a small self-describing container holding the
  # edge's bounded record set. Each contained record is the existing
  # `RBAR` full-record frame, so producers/consumers (incl. the peer cache)
  # stay byte-compatible with `encodeActionResultRecord`.
  PerEdgeFileMagic = "RBPE"
  # v1: header {magic, version, recordCount} then the record frames.
  # v2 (AC-1b fix): inserts a durable u64 `writeSequence` immediately after
  # the version, BEFORE the record count. The sequence is a strictly
  # monotonic per-cache-root counter (see `nextWriteSequence`) stamped at
  # write time, so the union read can order the split `.rec` files by TRUE
  # write recency (newest-wins / newest-corrupt-rejects) rather than by racy
  # filesystem mtime. v1 files and legacy AC-1 single files decode fine and
  # are assigned sequence 0 (treated as oldest), then re-stamped on next write.
  PerEdgeFileVersion = 2'u16
  PerEdgeFileVersionLegacy = 1'u16
  # Filename of the durable, flock-serialized write-sequence counter, kept at
  # the `hot-records/` root (a SIBLING of the per-edge `<key>/` directories).
  # It is never a `<key>/` directory and never a `.rec` file, so no per-edge
  # dir listing or record read path ever mistakes it for an edge or a record.
  WriteSequenceFileName = ".seq"
  RecordTailMask = 0xffff_ffff'u64
  MaxActionRecordFrameBytes = 64 * 1024 * 1024
  MaxRecordsPerWeakFingerprint = 2
  # AC-1b: Tier-1 is a DIRECTORY per edge (`hot-records/<key>/`) with one
  # `<nonce>.rec` file per observed path-set, so two independent concurrent
  # builds of the same edge that saw DIFFERENT path-sets (different strong
  # fingerprints) never clobber each other's record via last-rename-wins
  # (Action-Cache-Per-Edge-Store.md §3, §8). Distinct path-sets are few, so
  # the directory is capped at `MaxRecFilesPerEdge` files (oldest by durable
  # write sequence evicted beyond the cap), keeping the disk store small.
  PerEdgeRecFileExt = ".rec"
  MaxRecFilesPerEdge = 8
  AllFilePermissions {.used.} = {fpUserExec, fpUserWrite, fpUserRead,
    fpGroupExec, fpGroupWrite, fpGroupRead,
    fpOthersExec, fpOthersWrite, fpOthersRead}
    # Windows: marked {.used.} because readPermissions only iterates this set
    # on POSIX hosts; on Windows we discard the recorded mask entirely.

var processWarmFileMetadataEntries = initTable[string, FileMetadata]()

proc byteString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc bytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc readByte(data: openArray[byte]; pos: var int): byte =
  if pos >= data.len:
    raiseEnvelopeError(eeMalformed, "truncated byte")
  result = data[pos]
  inc pos

proc writeDigest(outp: var seq[byte]; digest: ContentDigest) =
  outp.add(byte(ord(digest.algorithm)))
  outp.add(byte(ord(digest.domain)))
  outp.add(digest.bytes)

proc readDigest(data: openArray[byte]; pos: var int): ContentDigest =
  let algorithm = readByte(data, pos)
  let domain = readByte(data, pos)
  if algorithm > byte(ord(haXxh3_64)):
    raiseEnvelopeError(eeMalformed, "invalid digest algorithm")
  if domain > byte(ord(hdMetadataEnvelope)):
    raiseEnvelopeError(eeMalformed, "invalid digest domain")
  if pos + 32 > data.len:
    raiseEnvelopeError(eeMalformed, "truncated digest bytes")
  result.algorithm = HashAlgorithm(algorithm)
  result.domain = HashDomain(domain)
  for i in 0 ..< 32:
    result.bytes[i] = data[pos + i]
  pos += 32

proc writeLocalHash(outp: var seq[byte]; value: LocalInvalidationHash) =
  outp.add(byte(ord(value.algorithm)))
  outp.add(byte(ord(value.domain)))
  outp.writeU64Le(value.value)

proc readLocalHash(data: openArray[byte]; pos: var int): LocalInvalidationHash =
  let algorithm = readByte(data, pos)
  let domain = readByte(data, pos)
  if algorithm > byte(ord(haXxh3_64)):
    raiseEnvelopeError(eeMalformed, "invalid local hash algorithm")
  if domain > byte(ord(hdMetadataEnvelope)):
    raiseEnvelopeError(eeMalformed, "invalid local hash domain")
  result.algorithm = HashAlgorithm(algorithm)
  result.domain = HashDomain(domain)
  result.value = readU64Le(data, pos)

proc writeMetadata(outp: var seq[byte]; metadata: FileMetadata) =
  outp.add(byte(ord(metadata.kind)))
  outp.writeU64Le(metadata.sizeBytes)
  outp.writeU64Le(metadata.mtimeNs)

proc readMetadata(data: openArray[byte]; pos: var int): FileMetadata =
  let kind = readByte(data, pos)
  if kind > byte(ord(ffkOther)):
    raiseEnvelopeError(eeMalformed, "invalid file metadata kind")
  result.kind = FingerprintedFileKind(kind)
  result.sizeBytes = readU64Le(data, pos)
  result.mtimeNs = readU64Le(data, pos)

proc writePermissions(outp: var seq[byte]; permissions: set[FilePermission]) =
  # Windows: the POSIX rwx model does not apply to NTFS (NTFS uses ACLs).
  # For the first round of the Windows port, serialize 0 so cached records
  # round-trip without applying nonsensical permissions on restore. Proper
  # ACL / SetFileAttributes preservation is a follow-up.
  when defined(windows):
    outp.writeU16Le(0'u16)
  else:
    var mask = 0'u16
    for permission in permissions:
      mask = mask or (1'u16 shl ord(permission))
    outp.writeU16Le(mask)

proc readPermissions(data: openArray[byte]; pos: var int): set[FilePermission] =
  let mask = readU16Le(data, pos)
  let knownMask = (1'u16 shl (ord(fpOthersRead) + 1)) - 1
  if (mask and not knownMask) != 0:
    raiseEnvelopeError(eeMalformed, "invalid file permission mask")
  # Windows: any mask we encounter (whether 0 from a Windows writer or
  # a non-zero mask from a POSIX writer) is intentionally discarded — the
  # rwx bits have no Windows equivalent and we don't try to translate them
  # onto NTFS ACLs yet.
  when defined(windows):
    discard mask
    result = {}
  else:
    for permission in AllFilePermissions:
      if (mask and (1'u16 shl ord(permission))) != 0:
        result.incl(permission)

proc writeFingerprint(outp: var seq[byte]; fp: FileFingerprint) =
  outp.writeString(fp.path)
  outp.add(byte(ord(fp.policy)))
  outp.writeMetadata(fp.metadata)
  outp.add(if fp.hasLocalHash: 1'u8 else: 0'u8)
  if fp.hasLocalHash:
    outp.writeLocalHash(fp.localHash)

proc readFingerprint(data: openArray[byte]; pos: var int): FileFingerprint =
  result.path = readString(data, pos)
  let policy = readByte(data, pos)
  if policy > byte(ord(ffpHybrid)):
    raiseEnvelopeError(eeMalformed, "invalid fingerprint policy")
  result.policy = FileFingerprintPolicy(policy)
  result.metadata = readMetadata(data, pos)
  case readByte(data, pos)
  of 0:
    result.hasLocalHash = false
  of 1:
    result.hasLocalHash = true
    result.localHash = readLocalHash(data, pos)
  else:
    raiseEnvelopeError(eeMalformed, "invalid local hash presence flag")

proc digestKey(digest: ContentDigest): string =
  $ord(digest.algorithm) & ":" & $ord(digest.domain) & ":" & toHex(digest.bytes)

proc digestFileName(digest: ContentDigest): string =
  $ord(digest.algorithm) & "-" & $ord(digest.domain) & "-" &
    toHex(digest.bytes) & ".rbar"

proc perEdgeDirName(weak: ContentDigest): string =
  ## Name of the per-edge DIRECTORY for `weak` inside `hot-records/`. The
  ## directory holds one `<nonce>.rec` file per observed path-set (AC-1b).
  digestFileName(weak)

proc recFileNameForStrong(strong: ContentDigest): string =
  ## Nonce for a path-set's `.rec` file, derived from its STRONG fingerprint
  ## so identical path-sets converge on the SAME filename (an atomic overwrite,
  ## never an accumulation) while distinct path-sets get distinct files that
  ## never clobber each other.
  toHex(strong.bytes) & PerEdgeRecFileExt

proc perEdgeRecordFileName*(weak: ContentDigest): string =
  ## Name of the per-edge record DIRECTORY for `weak` inside the cache's
  ## `hot-records/` directory. Exposed so callers (GC/retention, tooling,
  ## tests) can locate an individual edge's store without duplicating the
  ## naming scheme. (AC-1b: this is now a directory of `<nonce>.rec` files,
  ## not a single file.)
  perEdgeDirName(weak)

when defined(windows):
  # Minimal binding to GetFileAttributesExW so fingerprintMetadata can collect
  # kind+size+mtime in ONE syscall. The stdlib path (fileExists + dirExists +
  # getFileInfo) was three calls -- two GetFileAttributesW plus a much heavier
  # CreateFile/GetFileInformationByHandle/CloseHandle round trip -- and noop
  # cache hits stat hundreds of inputs/outputs per build.
  type
    Win32FileAttributeData = object
      dwFileAttributes: int32
      ftCreationTime: FILETIME
      ftLastAccessTime: FILETIME
      ftLastWriteTime: FILETIME
      nFileSizeHigh: int32
      nFileSizeLow: int32

  proc getFileAttributesExW(lpFileName: WideCString;
                            fInfoLevelId: int32;
                            lpFileInformation: pointer): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "GetFileAttributesExW",
    sideEffect.}

  const
    GetFileExInfoStandard = 0'i32
    FileTimeEpochDiff100Ns = 116_444_736_000_000_000'i64

proc fingerprintMetadata(path: string): FileMetadata =
  let fsPath = extendedPath(path)
  when defined(linux):
    var stat: Stat
    if lstat(fsPath.cstring, stat) != 0:
      return FileMetadata(kind: ffkMissing)
    result.kind =
      if S_ISREG(stat.st_mode):
        ffkRegular
      elif S_ISDIR(stat.st_mode):
        ffkDirectory
      elif S_ISLNK(stat.st_mode):
        try:
          let info = getFileInfo(fsPath, followSymlink = false)
          case info.kind
          of pcFile, pcLinkToFile:
            ffkRegular
          of pcDir, pcLinkToDir:
            ffkDirectory
        except OSError:
          ffkMissing
      else:
        ffkOther
    result.sizeBytes =
      if stat.st_size < 0: 0'u64 else: uint64(stat.st_size)
    result.mtimeNs = uint64(cast[int64](stat.st_mtim.tv_sec)) *
      1_000_000_000'u64 + uint64(stat.st_mtim.tv_nsec)
  elif defined(windows):
    var data: Win32FileAttributeData
    let wide = newWideCString(fsPath)
    if getFileAttributesExW(wide, GetFileExInfoStandard, addr data) == 0:
      return FileMetadata(kind: ffkMissing)
    if (data.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) != 0:
      result.kind = ffkDirectory
    else:
      result.kind = ffkRegular
      result.sizeBytes = (uint64(cast[uint32](data.nFileSizeHigh)) shl 32) or
        uint64(cast[uint32](data.nFileSizeLow))
      # FILETIME is 100-ns ticks since 1601-01-01 UTC; convert to ns since
      # the Unix epoch so the value matches what the Linux stat path emits.
      let ft100Ns = (int64(cast[uint32](data.ftLastWriteTime.dwHighDateTime)) shl 32) or
        int64(cast[uint32](data.ftLastWriteTime.dwLowDateTime))
      let unixNs100 = ft100Ns - FileTimeEpochDiff100Ns
      if unixNs100 > 0:
        result.mtimeNs = uint64(unixNs100) * 100'u64
  else:
    if not fileExists(fsPath) and not dirExists(fsPath):
      return FileMetadata(kind: ffkMissing)
    let info = getFileInfo(fsPath, followSymlink = false)
    result.kind =
      case info.kind
      of pcFile, pcLinkToFile:
        ffkRegular
      of pcDir, pcLinkToDir:
        ffkDirectory
    result.sizeBytes = uint64(max(info.size, 0))
    let mtime = info.lastWriteTime
    result.mtimeNs = uint64(mtime.toUnix) * 1_000_000_000'u64 +
      uint64(mtime.nanosecond)
  if result.kind == ffkDirectory:
    # Existing-directory probes depend on the fact that a directory exists,
    # not on the physical directory inode mtime. Directory enumeration needs a
    # membership fingerprint; the transitional monitor path stores those
    # observations as probes, so recording directory mtimes would make actions
    # miss whenever their own output directory is touched.
    result.sizeBytes = 0
    result.mtimeNs = 0

proc initFileMetadataCache*(): FileMetadataCache =
  FileMetadataCache(entries: initTable[string, FileMetadata]())

proc clear*(cache: var FileMetadataCache) =
  cache.entries.clear()

proc invalidate*(cache: var FileMetadataCache; path: string) =
  cache.entries.del(path)

proc metadataStats*(cache: FileMetadataCache): FileMetadataCacheStats =
  cache.stats

proc fingerprintMetadata(path: string;
                         cache: ptr FileMetadataCache): FileMetadata =
  if cache.isNil:
    return fingerprintMetadata(path)
  if cache[].entries.hasKey(path):
    inc cache[].stats.currentRunHits
    return cache[].entries[path]
  let hadWarmEntry = processWarmFileMetadataEntries.hasKey(path)
  let priorMetadata =
    if hadWarmEntry: processWarmFileMetadataEntries[path]
    else: FileMetadata()
  if hadWarmEntry:
    inc cache[].stats.warmEntries
    inc cache[].stats.warmRevalidated
  else:
    inc cache[].stats.coldStats
  result = fingerprintMetadata(path)
  if hadWarmEntry:
    if result == priorMetadata:
      inc cache[].stats.warmUnchanged
    else:
      inc cache[].stats.warmChanged
  cache[].entries[path] = result
  processWarmFileMetadataEntries[path] = result

proc fingerprintRecordedMetadata(path: string; recorded: FileMetadata;
                                 cache: ptr FileMetadataCache): FileMetadata =
  if cache.isNil:
    return fingerprintMetadata(path)
  if cache[].entries.hasKey(path):
    inc cache[].stats.currentRunHits
    return cache[].entries[path]
  inc cache[].stats.warmEntries
  inc cache[].stats.warmRevalidated
  result = fingerprintMetadata(path)
  if result == recorded:
    inc cache[].stats.warmUnchanged
  else:
    inc cache[].stats.warmChanged
  cache[].entries[path] = result
  processWarmFileMetadataEntries[path] = result

proc fileBytesForHash(path: string; metadata: FileMetadata): seq[byte] =
  if metadata.kind != ffkRegular:
    return @[]
  bytes(readFile(extendedPath(path)))

proc isDirectRegularFile(path: string): bool =
  when defined(linux):
    var stat: Stat
    lstat(extendedPath(path).cstring, stat) == 0 and S_ISREG(stat.st_mode)
  else:
    let info = getFileInfo(extendedPath(path), followSymlink = false)
    info.kind == pcFile

proc observeFileWithMetadata(path: string; policy: FileFingerprintPolicy;
                             metadata: FileMetadata): FileFingerprint =
  result.path = path
  result.policy = policy
  result.metadata = metadata
  if policy in {ffpChecksum, ffpHybrid}:
    result.hasLocalHash = true
    result.localHash = localHash(fileBytesForHash(path, result.metadata))

proc observeFile*(path: string; policy: FileFingerprintPolicy): FileFingerprint =
  observeFileWithMetadata(path, policy, fingerprintMetadata(path))

proc observeFile*(path: string; policy: FileFingerprintPolicy;
                  cache: ptr FileMetadataCache): FileFingerprint =
  observeFileWithMetadata(path, policy, fingerprintMetadata(path, cache))

proc isVolatileDevicePath(path: string): bool =
  let normalized = path.replace('\\', '/')
  normalized == "/dev" or normalized.startsWith("/dev/") or
    normalized == "/proc" or normalized.startsWith("/proc/") or
    normalized == "/sys" or normalized.startsWith("/sys/") or
    normalized == "/run" or normalized.startsWith("/run/")

proc isRecordableInput(input: FileFingerprint): bool =
  if input.path.isVolatileDevicePath():
    return false
  input.metadata.kind != ffkOther

proc digestHex*(digest: ContentDigest): string =
  toHex(digest.bytes)

proc openLocalCas*(root: string): LocalCas =
  result.root = root
  createDir(extendedPath(result.root))
  createDir(extendedPath(result.root / "tmp"))

proc blobPath*(cas: LocalCas; digest: ContentDigest): string =
  let hex = digestHex(digest)
  cas.root / hex[0 .. 1] / hex[2 .. ^1]

proc blobRef*(digest: ContentDigest; sizeBytes: uint64): CasBlobRef =
  CasBlobRef(digest: digest, sizeBytes: sizeBytes)

proc readBlob*(cas: LocalCas; blob: CasBlobRef): seq[byte] =
  let path = cas.blobPath(blob.digest)
  if not fileExists(extendedPath(path)):
    raise newException(CacheIntegrityError, "missing CAS object " &
      digestHex(blob.digest))
  result = bytes(readFile(extendedPath(path)))
  if uint64(result.len) != blob.sizeBytes:
    raise newException(CacheIntegrityError, "CAS size mismatch for " &
      digestHex(blob.digest))
  let actual = casDigest(result)
  if actual != blob.digest:
    raise newException(CacheIntegrityError, "CAS digest mismatch for " &
      digestHex(blob.digest))

proc verifyBlob*(cas: LocalCas; blob: CasBlobRef) =
  let path = cas.blobPath(blob.digest)
  if not fileExists(extendedPath(path)):
    raise newException(CacheIntegrityError, "missing CAS object " &
      digestHex(blob.digest))
  let info = getFileInfo(extendedPath(path), followSymlink = false)
  if uint64(info.size) != blob.sizeBytes:
    raise newException(CacheIntegrityError, "CAS size mismatch for " &
      digestHex(blob.digest))
  let actual = casFileDigest(extendedPath(path), blob.sizeBytes)
  if actual != blob.digest:
    raise newException(CacheIntegrityError, "CAS digest mismatch for " &
      digestHex(blob.digest))

proc storeBlob*(cas: LocalCas; payload: openArray[byte]): CasBlobRef =
  result.digest = casDigest(payload)
  result.sizeBytes = uint64(payload.len)
  let finalPath = cas.blobPath(result.digest)
  if fileExists(extendedPath(finalPath)):
    cas.verifyBlob(result)
    return
  createDir(extendedPath(finalPath.splitPath.head))
  let now = getTime()
  let tmpPath = cas.root / "tmp" / (digestHex(result.digest) & "." &
    $getCurrentProcessId() & "." & $now.toUnix & "." & $now.nanosecond)
  writeFile(extendedPath(tmpPath), byteString(payload))
  try:
    moveFile(extendedPath(tmpPath), extendedPath(finalPath))
  except OSError:
    if fileExists(extendedPath(tmpPath)):
      removeFile(extendedPath(tmpPath))
    if fileExists(extendedPath(finalPath)):
      cas.verifyBlob(result)
    else:
      raise

proc storeFileBlob*(cas: LocalCas; path: string; sizeBytes: uint64): CasBlobRef =
  result.digest = casFileDigest(extendedPath(path), sizeBytes)
  result.sizeBytes = sizeBytes
  let finalPath = cas.blobPath(result.digest)
  let finalFsPath = extendedPath(finalPath)
  if fileExists(finalFsPath):
    cas.verifyBlob(result)
    return
  createDir(extendedPath(finalPath.splitPath.head))
  let now = getTime()
  let tmpPath = cas.root / "tmp" / (digestHex(result.digest) & "." &
    $getCurrentProcessId() & "." & $now.toUnix & "." & $now.nanosecond)
  let tmpFsPath = extendedPath(tmpPath)
  copyFile(extendedPath(path), tmpFsPath)
  try:
    moveFile(tmpFsPath, finalFsPath)
  except OSError:
    if fileExists(tmpFsPath):
      removeFile(tmpFsPath)
    if fileExists(finalFsPath):
      cas.verifyBlob(result)
    else:
      raise

proc materialPath(root, path: string): string =
  if path.isAbsolute or root.len == 0:
    path
  else:
    root / path

proc restoreOutputs*(cas: LocalCas; record: ActionResultRecord;
                     outputRoot = "") =
  if record.outputPayloadKind != opkCasBlobs:
    raise newException(CacheIntegrityError,
      "cache record does not contain output payloads")
  var payloads: seq[seq[byte]] = @[]
  for output in record.outputs:
    payloads.add(cas.readBlob(output.blob))
  for i, output in record.outputs:
    let destination = materialPath(outputRoot, output.path)
    createDir(extendedPath(destination.splitPath.head))
    let tmpPath = destination & ".reprotmp." & $getCurrentProcessId()
    writeFile(extendedPath(tmpPath), byteString(payloads[i]))
    # Windows: rwx permissions are not preserved (see writePermissions);
    # applying setFilePermissions with an empty set would clobber the file's
    # NTFS ACLs in unhelpful ways, so we skip it entirely. Follow-up:
    # preserve ACLs / read-only attribute via icacls / SetFileAttributes.
    when not defined(windows):
      setFilePermissions(extendedPath(tmpPath), output.permissions)
    if fileExists(extendedPath(destination)):
      removeFile(extendedPath(destination))
    moveFile(extendedPath(tmpPath), extendedPath(destination))
    when not defined(windows):
      setFilePermissions(extendedPath(destination), output.permissions)

proc strongIdentityPayload(weak: ContentDigest;
                           inputs: openArray[FileFingerprint]): seq[byte] =
  result.add(byte(ord('R')))
  result.add(byte(ord('B')))
  result.add(byte(ord('S')))
  result.add(byte(ord('F')))
  result.writeDigest(weak)
  result.writeU32Le(uint32(inputs.len))
  for input in inputs:
    result.writeString(input.path)
    result.add(byte(ord(input.policy)))
    case input.policy
    of ffpTimestamp:
      result.writeMetadata(input.metadata)
    of ffpChecksum, ffpHybrid:
      if not input.hasLocalHash:
        raise newException(ActionRecordError,
          "content fingerprint missing for " & input.path)
      result.writeLocalHash(input.localHash)

proc computeStrongFingerprint*(weak: ContentDigest;
                               inputs: openArray[FileFingerprint]): ContentDigest =
  blake3DomainDigest(strongIdentityPayload(weak, inputs), hdActionFingerprint)

proc encodeRecord(record: ActionResultRecord): seq[byte] =
  result.add(byte(ord(ActionRecordMagic[0])))
  result.add(byte(ord(ActionRecordMagic[1])))
  result.add(byte(ord(ActionRecordMagic[2])))
  result.add(byte(ord(ActionRecordMagic[3])))
  result.writeU16Le(ActionRecordVersion)
  result.writeDigest(record.weakFingerprint)
  result.add(byte(ord(record.policy)))
  result.writeU32Le(uint32(record.inputs.len))
  for input in record.inputs:
    result.writeFingerprint(input)
  result.writeDigest(record.strongFingerprint)
  result.add(byte(ord(record.outputPayloadKind)))
  result.writeU32Le(uint32(record.outputs.len))
  for output in record.outputs:
    result.writeString(output.path)
    result.writeMetadata(output.metadata)
    result.writePermissions(output.permissions)
    case record.outputPayloadKind
    of opkCasBlobs:
      result.writeDigest(output.blob.digest)
      result.writeU64Le(output.blob.sizeBytes)
    of opkMetadataOnly:
      discard

proc decodeRecord(payload: openArray[byte]): ActionResultRecord =
  if payload.len < 6:
    raiseEnvelopeError(eeMalformed, "truncated action record")
  for i in 0 ..< 4:
    if payload[i] != byte(ord(ActionRecordMagic[i])):
      raiseEnvelopeError(eeUnknownMagic, "unknown action record magic")
  var pos = 4
  let version = readU16Le(payload, pos)
  if version notin {2'u16, ActionRecordVersion}:
    raiseEnvelopeError(eeUnsupportedVersion, "unsupported action record version")
  result.weakFingerprint = readDigest(payload, pos)
  let policy = readByte(payload, pos)
  if policy > byte(ord(ffpHybrid)):
    raiseEnvelopeError(eeMalformed, "invalid record policy")
  result.policy = FileFingerprintPolicy(policy)
  let inputCount = int(readU32Le(payload, pos))
  result.inputs = newSeq[FileFingerprint](inputCount)
  for i in 0 ..< inputCount:
    result.inputs[i] = readFingerprint(payload, pos)
  result.strongFingerprint = readDigest(payload, pos)
  if version >= 3'u16:
    let outputPayloadKind = readByte(payload, pos)
    if outputPayloadKind > byte(ord(opkMetadataOnly)):
      raiseEnvelopeError(eeMalformed, "invalid output payload kind")
    result.outputPayloadKind = OutputPayloadKind(outputPayloadKind)
  else:
    result.outputPayloadKind = opkCasBlobs
  let outputCount = int(readU32Le(payload, pos))
  result.outputs = newSeq[OutputBlob](outputCount)
  for i in 0 ..< outputCount:
    result.outputs[i].path = readString(payload, pos)
    if version >= 3'u16:
      result.outputs[i].metadata = readMetadata(payload, pos)
      result.outputs[i].permissions = readPermissions(payload, pos)
      case result.outputPayloadKind
      of opkCasBlobs:
        let digest = readDigest(payload, pos)
        let size = readU64Le(payload, pos)
        result.outputs[i].blob = blobRef(digest, size)
      of opkMetadataOnly:
        discard
    else:
      let digest = readDigest(payload, pos)
      let size = readU64Le(payload, pos)
      result.outputs[i].blob = blobRef(digest, size)
      result.outputs[i].permissions = readPermissions(payload, pos)
  if pos != payload.len:
    raiseEnvelopeError(eeMalformed, "trailing action record bytes")

proc writeActionResultRecordFile*(path: string; record: ActionResultRecord) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), byteString(encodeRecord(record)))

proc encodeActionResultRecord*(record: ActionResultRecord): seq[byte] =
  ## Public wrapper over the on-disk record codec. Used by the peer-cache
  ## action-bundle (`repro_peer_cache/action_bundle.nim`) so producer and
  ## consumer agree byte-for-byte with the on-disk action-cache encoding.
  encodeRecord(record)

proc decodeActionResultRecord*(payload: openArray[byte]): ActionResultRecord =
  ## Public wrapper over the on-disk record codec. Inverse of
  ## `encodeActionResultRecord`. Raises `EnvelopeError` on malformed
  ## input.
  decodeRecord(payload)

proc metadataOnly(input: FileFingerprint): FileFingerprint =
  FileFingerprint(
    path: input.path,
    policy: input.policy,
    metadata: input.metadata,
    hasLocalHash: false)

proc perEdgeDirPath(cache: ActionCache; weak: ContentDigest): string =
  ## Directory holding the edge's `<nonce>.rec` path-set files (AC-1b).
  cache.hotRoot / perEdgeDirName(weak)

proc legacyHotRecordPath(cache: ActionCache; weak: ContentDigest): string =
  ## Pre-AC-1b single-file location `hot-records/<key>`. Read for back-compat;
  ## never written by AC-1b (writes go to the per-edge directory).
  cache.hotRoot / perEdgeDirName(weak)

proc hotMetadataRecord(record: ActionResultRecord): ActionResultRecord =
  result = record
  result.inputs.setLen(0)
  for input in record.inputs:
    result.inputs.add(metadataOnly(input))
  result.outputs.setLen(0)
  result.outputPayloadKind = opkMetadataOnly
  result.strongFingerprint = ContentDigest()

proc recordTail(payload: openArray[byte]): uint32 =
  uint32(localHash(payload).value and RecordTailMask)

proc encodePerEdgeFile(records: openArray[ActionResultRecord];
                       writeSequence: uint64): seq[byte] =
  ## Serialize an edge's bounded record set into its per-edge container (v2).
  ## The header + record frames are byte-identical to v1 (magic, version,
  ## record count, then each `RBAR` full-record frame — the RBAR frame stays
  ## at the same offset); v2 only bumps the version and appends an 8-byte
  ## `writeSequence` TRAILER after the last record frame. Keeping the sequence
  ## in a trailer preserves the header layout for structural readers while
  ## still carrying the durable, strictly-monotonic per-cache-root counter the
  ## union read orders `.rec` files by (descending = newest first) so
  ## newest-wins / newest-corrupt-rejects is deterministic regardless of
  ## filesystem mtime resolution.
  result.add(byte(ord(PerEdgeFileMagic[0])))
  result.add(byte(ord(PerEdgeFileMagic[1])))
  result.add(byte(ord(PerEdgeFileMagic[2])))
  result.add(byte(ord(PerEdgeFileMagic[3])))
  result.writeU16Le(PerEdgeFileVersion)
  result.writeU32Le(uint32(records.len))
  for record in records:
    let payload = encodeRecord(record)
    result.writeU32Le(uint32(payload.len))
    result.add(payload)
    result.writeU32Le(recordTail(payload))
  result.writeU64Le(writeSequence)

proc decodePerEdgeFileWithSeq(raw: openArray[byte]):
    tuple[records: seq[ActionResultRecord]; writeSequence: uint64] =
  ## Inverse of `encodePerEdgeFile`. Tolerates a truncated tail (a crashed
  ## writer that lost the rename race leaves either the old file or a
  ## complete new file; a torn body is treated as "stop at the last intact
  ## record" rather than raising, matching the pre-existing frame reader).
  ## Back-compat: a v1 file (pre-fix `.rec`, no sequence trailer) decodes with
  ## `writeSequence = 0` so it sorts as OLDEST and is re-stamped on next write.
  if raw.len < 10:
    return
  for i in 0 ..< 4:
    if raw[i] != byte(ord(PerEdgeFileMagic[i])):
      return
  var pos = 4
  let version = readU16Le(raw, pos)
  if version notin {PerEdgeFileVersionLegacy, PerEdgeFileVersion}:
    return
  let count = int(readU32Le(raw, pos))
  for _ in 0 ..< count:
    if pos + 8 > raw.len:
      break
    let length = int(readU32Le(raw, pos))
    if length < 0 or length > MaxActionRecordFrameBytes or pos + length + 4 > raw.len:
      break
    let payload = raw[pos .. pos + length - 1]
    pos += length
    let tail = readU32Le(raw, pos)
    if tail != recordTail(payload):
      break
    try:
      result.records.add(decodeRecord(payload))
    except EnvelopeError:
      break
  # v2 trailer: the 8-byte write sequence follows the last complete frame.
  # Read it only if the whole body decoded intactly AND exactly 8 trailing
  # bytes remain (a torn body already `break`ed above and leaves no trailer).
  if version >= PerEdgeFileVersion and pos + 8 == raw.len:
    result.writeSequence = readU64Le(raw, pos)

proc decodePerEdgeFile(raw: openArray[byte]): seq[ActionResultRecord] =
  ## Records-only view over `decodePerEdgeFileWithSeq` for callers that don't
  ## need the write sequence (legacy migration + intactness probes).
  decodePerEdgeFileWithSeq(raw).records

proc perEdgeRecordFileIsIntact*(raw: openArray[byte]): bool =
  ## Strict validator: true iff `raw` is a byte-complete per-edge file — a
  ## valid RBPE header whose declared record count is fully present and every
  ## contained RBAR frame decodes with a matching tail, followed only by the
  ## optional 8-byte v2 write-sequence trailer. Unlike `decodePerEdgeFile`
  ## (which stops at the first torn frame), this rejects a torn/interleaved
  ## file. Used to prove atomicity: an atomic rename never publishes a file
  ## that fails this check; a truncate-then-write can. An empty file is treated
  ## as "not yet an intact record file". Accepts both v1 (no trailer) and v2
  ## (durable write-sequence trailer) files.
  if raw.len == 0:
    return false
  if raw.len < 10:
    return false
  for i in 0 ..< 4:
    if raw[i] != byte(ord(PerEdgeFileMagic[i])):
      return false
  var pos = 4
  let version = readU16Le(raw, pos)
  if version notin {PerEdgeFileVersionLegacy, PerEdgeFileVersion}:
    return false
  let count = int(readU32Le(raw, pos))
  for _ in 0 ..< count:
    if pos + 8 > raw.len:
      return false
    let length = int(readU32Le(raw, pos))
    if length < 0 or length > MaxActionRecordFrameBytes or
        pos + length + 4 > raw.len:
      return false
    let payload = raw[pos .. pos + length - 1]
    pos += length
    if readU32Le(raw, pos) != recordTail(payload):
      return false
    try:
      discard decodeRecord(payload)
    except EnvelopeError:
      return false
  if version >= PerEdgeFileVersion:
    # A complete v2 file ends with exactly the 8-byte sequence trailer.
    pos + 8 == raw.len
  else:
    pos == raw.len

proc loadLegacyPerEdgeFile(cache: ActionCache; weak: ContentDigest):
    seq[ActionResultRecord] =
  ## Read a pre-AC-1b single `hot-records/<key>` FILE if one exists (an
  ## un-migrated AC-1 cache). Returns empty when the path is a directory (the
  ## AC-1b layout) or absent.
  let path = cache.legacyHotRecordPath(weak)
  let ep = extendedPath(path)
  if not fileExists(ep) or dirExists(ep):
    return
  try:
    result = decodePerEdgeFile(bytes(readFile(ep)))
  except OSError, IOError:
    result = @[]

proc writeSequenceFilePath(cache: ActionCache): string =
  ## The durable write-sequence counter, a SIBLING of the per-edge directories
  ## at the `hot-records/` root (never a `<key>/` dir, never a `.rec`).
  cache.hotRoot / WriteSequenceFileName

proc readSequenceValue(path: string): uint64 =
  ## Best-effort read of the persisted u64 counter (decimal text). A missing,
  ## empty, or unparseable file reads as 0 (fresh cache / legacy layout).
  let ep = extendedPath(path)
  if not fileExists(ep):
    return 0'u64
  try:
    let text = readFile(ep).strip()
    if text.len == 0:
      return 0'u64
    result = parseBiggestUInt(text).uint64
  except CatchableError:
    result = 0'u64

proc nextWriteSequence(cache: ActionCache): uint64 =
  ## Allocate the next value of the durable, strictly-monotonic per-cache-root
  ## write-sequence counter. The counter is serialized across concurrent build
  ## engine processes by an exclusive `flock` (POSIX) / exclusive-open retry
  ## (Windows) on the `hot-records/.seq` file, so two records written
  ## microseconds apart — in one process OR across processes sharing one cache
  ## root — always receive distinct, increasing sequences. This is the total,
  ## race-free order the union read uses for newest-wins / newest-corrupt-
  ## rejects, replacing the racy nanosecond-mtime tie-break.
  createDir(extendedPath(cache.hotRoot))
  let path = cache.writeSequenceFilePath()
  when defined(posix):
    # Serialize the read-modify-write across processes with an exclusive
    # `flock` held on a dedicated lock fd for the duration of the bump. The
    # value itself is (re)written with `writeFile` (truncating) while the lock
    # is held, so a concurrent process blocks on the flock and observes the
    # committed value on its next read.
    let fd = posix.open(path.cstring, O_RDWR or O_CREAT, Mode(0o600))
    if fd < 0:
      # Counter fd unavailable: fall back to a monotonic value from the
      # persisted counter + 1. Never 0 for a real write, so it still outranks
      # a legacy/seq-0 record.
      return readSequenceValue(path) + 1'u64
    var acquired = false
    while true:
      if cFlockSeq(fd, SeqLockExclusive) == 0:
        acquired = true
        break
      if errno != EINTR:
        break
    if not acquired:
      discard posix.close(fd)
      return readSequenceValue(path) + 1'u64
    result = readSequenceValue(path) + 1'u64
    try:
      writeFile(extendedPath(path), $result)
    except CatchableError:
      discard
    # Closing the fd releases the exclusive flock.
    discard posix.close(fd)
  else:
    # Windows / other: no flock. The build model has one engine process per
    # build touching the cache serially; cross-build contention on one cache
    # root is the concern, and a truncating rewrite keeps the counter strictly
    # increasing for the common single-writer case.
    result = readSequenceValue(path) + 1'u64
    writeFile(extendedPath(path), $result)

proc loadPerEdgeRecords*(cache: ActionCache; weak: ContentDigest):
    seq[ActionResultRecord] =
  ## Union-read every path-set the edge has on disk: all `<nonce>.rec` files
  ## in `hot-records/<key>/` PLUS any pre-AC-1b single-file record for
  ## back-compat. Cost is O(records for THIS edge) — it lists exactly one
  ## edge's directory, NEVER a whole-cache scan (the anti-wedge invariant).
  ## Records are deduped by strong fingerprint (a legacy file and a migrated
  ## `.rec` for the same path-set converge). Ordered OLDEST→NEWEST by each
  ## `.rec` file's DURABLE write sequence (a `.seq`-backed monotonic counter),
  ## with the strong-fingerprint hex as a total-order tie-break, so a caller
  ## iterating in reverse (as `lookupActionResult` does) considers the truly
  ## newest path-set first — preserving AC-1's "newest record wins /
  ## newest-corrupt rejects immediately" semantics deterministically across the
  ## multi-file split (mtime is NOT used: it is racy at sub-microsecond writes).
  let dirPath = cache.perEdgeDirPath(weak)
  var seenStrong = initHashSet[string]()
  if dirExists(extendedPath(dirPath)):
    # (writeSequence, strongHex) is a TOTAL, STABLE key: each `.rec` file gets a
    # distinct durable sequence at write time, and the strong-fp hex is unique
    # per file, so no two distinct files ever compare equal.
    var recFiles: seq[tuple[seq: uint64; strongHex: string;
        recs: seq[ActionResultRecord]]] = @[]
    for kind, path in walkDir(extendedPath(dirPath)):
      if kind != pcFile or not path.endsWith(PerEdgeRecFileExt):
        continue
      var decoded: tuple[records: seq[ActionResultRecord]; writeSequence: uint64]
      try:
        decoded = decodePerEdgeFileWithSeq(bytes(readFile(path)))
      except OSError, IOError:
        continue
      # Tie-break key from the file's own strong-fp nonce (its base name), so
      # even legacy/seq-0 files or a hypothetical duplicate sequence still sort
      # deterministically.
      let strongHex = path.splitFile.name
      recFiles.add((seq: decoded.writeSequence, strongHex: strongHex,
        recs: decoded.records))
    recFiles.sort(proc (a, b: tuple[seq: uint64; strongHex: string;
        recs: seq[ActionResultRecord]]): int =
      result = cmp(a.seq, b.seq)
      if result == 0:
        result = cmp(a.strongHex, b.strongHex))
    for entry in recFiles:
      for rec in entry.recs:
        let key = digestKey(rec.strongFingerprint)
        if key notin seenStrong:
          seenStrong.incl(key)
          result.add(rec)
  else:
    # No directory: an AC-1 single file may still live at this path.
    for rec in cache.loadLegacyPerEdgeFile(weak):
      let key = digestKey(rec.strongFingerprint)
      if key notin seenStrong:
        seenStrong.incl(key)
        result.add(rec)

proc writeRecFileAtomically(cache: ActionCache; dirPath, finalName: string;
                            records: openArray[ActionResultRecord]) =
  ## Encode `records` (one path-set's bounded set) to a fresh temp file and
  ## atomically `rename()` it to `dirPath/finalName`. fsync-less: a cache needs
  ## consistency, not durability. Never clobbers a sibling `.rec` of a distinct
  ## path-set — only the same-named (same strong fp) file, which is convergence.
  ## Stamps a FRESH durable write sequence so a convergent rewrite of the same
  ## path-set becomes strictly newest (higher sequence) than every sibling.
  createDir(extendedPath(dirPath))
  let writeSequence = cache.nextWriteSequence()
  let now = getTime()
  let tmpPath = dirPath / (finalName & ".tmp." &
    $getCurrentProcessId() & "." & $now.toUnix & "." & $now.nanosecond)
  writeFile(extendedPath(tmpPath),
    byteString(encodePerEdgeFile(records, writeSequence)))
  try:
    moveFile(extendedPath(tmpPath), extendedPath(dirPath / finalName))
  except OSError:
    if fileExists(extendedPath(tmpPath)):
      removeFile(extendedPath(tmpPath))
    raise

proc capRecFiles(cache: ActionCache; dirPath: string) =
  ## Bound the per-edge directory: keep at most `MaxRecFilesPerEdge` `.rec`
  ## files, evicting the OLDEST by DURABLE write sequence beyond the cap (the
  ## same total order the lookup uses, so eviction never drops a record the
  ## lookup would have considered newest). Distinct path-sets are few, so this
  ## rarely fires; it guarantees the disk store stays small even if an
  ## adversarial stream of distinct path-sets accumulates.
  var entries: seq[tuple[seq: uint64; strongHex, path: string]] = @[]
  for kind, path in walkDir(extendedPath(dirPath)):
    if kind == pcFile and path.endsWith(PerEdgeRecFileExt):
      var writeSequence = 0'u64
      try:
        writeSequence = decodePerEdgeFileWithSeq(bytes(readFile(path))).writeSequence
      except OSError, IOError:
        discard
      entries.add((seq: writeSequence, strongHex: path.splitFile.name,
        path: path))
  if entries.len <= MaxRecFilesPerEdge:
    return
  entries.sort(proc (a, b: tuple[seq: uint64; strongHex, path: string]): int =
    result = cmp(a.seq, b.seq)
    if result == 0:
      result = cmp(a.strongHex, b.strongHex))
  for i in 0 ..< entries.len - MaxRecFilesPerEdge:
    try:
      removeFile(entries[i].path)
    except OSError:
      discard

proc migrateLegacyFile(cache: ActionCache; weak: ContentDigest) =
  ## If a pre-AC-1b single FILE sits at `hot-records/<key>` (the same path the
  ## AC-1b directory needs), fold its records into per-path-set `.rec` files and
  ## remove the file, so the directory layout can take over cleanly.
  let legacyPath = cache.legacyHotRecordPath(weak)
  let ep = extendedPath(legacyPath)
  if not fileExists(ep) or dirExists(ep):
    return
  var legacyRecords: seq[ActionResultRecord]
  try:
    legacyRecords = decodePerEdgeFile(bytes(readFile(ep)))
  except OSError, IOError:
    legacyRecords = @[]
  # Remove the file FIRST so `createDir` on the same path can succeed; the
  # records are held in memory and re-published as `.rec` files below.
  try:
    removeFile(ep)
  except OSError:
    return
  let dirPath = cache.perEdgeDirPath(weak)
  var byStrong = initTable[string, seq[ActionResultRecord]]()
  for rec in legacyRecords:
    byStrong.mgetOrPut(digestKey(rec.strongFingerprint), @[]).add(rec)
  for strongKey, recs in byStrong:
    cache.writeRecFileAtomically(dirPath,
      recFileNameForStrong(recs[0].strongFingerprint), recs)

proc submitToShm(cache: ActionCache; record: ActionResultRecord) =
  ## AC-2c engine WRITE path (§4.4): submit `record`'s METADATA-ONLY encoding to
  ## the MPSC ring so the single-writer daemon publishes it to the shared table
  ## for OTHER concurrently-running builds (live cross-build sharing). The engine
  ## NEVER writes the shared table itself — only the daemon does. Best-effort:
  ## a full ring (signalled drop) or oversized metadata (> the inline slot cap)
  ## just leaves the record Tier-1-only; its future lookups fall through to disk
  ## — still correct. The keyDigest is the weak fingerprint's 32 bytes.
  ##
  ## We submit the FULL encoded record (same bytes the engine just wrote to
  ## Tier-1). This keeps the STRONG fingerprint + inputs intact so (a) the
  ## daemon's Tier-1 persist round-trips byte-identically (never downgrading the
  ## durable record) and (b) a shm-served read reconstructs the SAME record the
  ## disk read would — the decision is unchanged. Records whose full encoding
  ## exceeds the inline slot cap are simply not shm-cached (Tier-1-only).
  if cache.shm == nil or not cache.shm.enabled: return
  let enc = encodeActionResultRecord(record)
  discard cache.shm.idx.submitRecord(record.weakFingerprint.bytes, enc)

proc writePerEdgeRecord(cache: ActionCache; record: ActionResultRecord) =
  ## Publish ONE path-set's record into its edge directory
  ## `hot-records/<key>/<strongFp>.rec` via temp-file + atomic rename, WITHOUT
  ## touching any sibling `.rec` from a distinct concurrent path-set (AC-1b).
  ## Same strong fingerprint → same filename → convergence (an overwrite, never
  ## an accumulation). Bounded by `MaxRecFilesPerEdge`.
  ##
  ## AC-2c: the DURABLE Tier-1 write is unchanged (the backstop); we ALSO submit
  ## the metadata record to the shm ring so the daemon warms other live builds.
  cache.migrateLegacyFile(record.weakFingerprint)
  let dirPath = cache.perEdgeDirPath(record.weakFingerprint)
  cache.writeRecFileAtomically(dirPath,
    recFileNameForStrong(record.strongFingerprint), @[record])
  cache.capRecFiles(dirPath)
  cache.submitToShm(record)

proc writePerEdgeRecords*(cache: ActionCache; weak: ContentDigest;
                         records: openArray[ActionResultRecord]) =
  ## Publish a set of records for `weak`, grouping by strong fingerprint so each
  ## path-set lands in its own `<nonce>.rec` file (temp + atomic rename). This
  ## NEVER clobbers a sibling path-set written by a concurrent build; distinct
  ## strong fingerprints target distinct files and identical ones converge on
  ## the same file. Used by the AC-2b daemon persist bridge and by internal
  ## record installs. Bounded by `MaxRecFilesPerEdge`.
  cache.migrateLegacyFile(weak)
  let dirPath = cache.perEdgeDirPath(weak)
  var byStrong = initOrderedTable[string, seq[ActionResultRecord]]()
  for rec in records:
    if rec.weakFingerprint != weak:
      continue
    byStrong.mgetOrPut(digestKey(rec.strongFingerprint), @[]).add(rec)
  for _, recs in byStrong:
    cache.writeRecFileAtomically(dirPath,
      recFileNameForStrong(recs[0].strongFingerprint), recs)
  if byStrong.len > 0:
    cache.capRecFiles(dirPath)

proc hotInputKey(input: FileFingerprint): string =
  input.path & "\0" & $ord(input.policy) & "\0" &
    $ord(input.metadata.kind) & "\0" & $input.metadata.sizeBytes & "\0" &
    $input.metadata.mtimeNs

proc scanHotIndexMetadataInputsUnchanged*(cache: ActionCache;
                                          probes: openArray[HotMetadataProbe];
                                          metadataCache: ptr FileMetadataCache = nil):
                                          HotMetadataScan =
  ## Batch "are all these edges still cache hits" check, now served by
  ## reading each probe's single authoritative `hot-records/<key>` file
  ## instead of scanning a global index. Cost is O(probes), page-cached,
  ## never a whole-cache scan. Result semantics match the former index
  ## scan: hmssHit iff every probe has a matching record whose inputs are
  ## all metadata-unchanged; hmssMissingRecord if any probe has no matching
  ## record; hmssInputChanged if a matched record's input changed.
  if probes.len == 0:
    return HotMetadataScan(status: hmssHit)
  var checkedInputs = 0
  var totalRecords = 0
  for probe in probes:
    let records = cache.loadPerEdgeRecords(probe.weakFingerprint)
    var matched = false
    for record in records:
      inc totalRecords
      if record.weakFingerprint == probe.weakFingerprint and
          record.policy == probe.policy:
        matched = true
    if not matched:
      return HotMetadataScan(status: hmssMissingRecord,
        recordCount: totalRecords)
    for record in records:
      if record.weakFingerprint == probe.weakFingerprint and
          record.policy == probe.policy:
        for input in record.inputs:
          inc checkedInputs
          if fingerprintRecordedMetadata(input.path, input.metadata,
              metadataCache) != input.metadata:
            return HotMetadataScan(status: hmssInputChanged,
              recordCount: totalRecords, checkedInputCount: checkedInputs)
  HotMetadataScan(status: hmssHit, recordCount: totalRecords,
    checkedInputCount: checkedInputs)

proc shmReadRecord(cache: ActionCache; weak: ContentDigest):
    tuple[found: bool; record: ActionResultRecord] =
  ## AC-2c engine READ path (§4.3): lock-free seqlock read of the shm slot for
  ## `weak` on the current generation. On a hit the inline bytes decode to the
  ## FULL record another build submitted (byte-identical to what it wrote to
  ## Tier-1), so this is a genuine shm-SERVED record — visible the instant the
  ## daemon publishes it, independent of THIS process's Tier-1 view. A miss /
  ## torn-after-retries / disabled tier returns not-found and the caller reads
  ## Tier-1 disk (the decision is unchanged; shm is purely an accelerator).
  if cache.shm == nil or not cache.shm.enabled:
    return (found: false, record: ActionResultRecord())
  var rec: seq[byte]
  if not cache.shm.idx.lookupMetadata(weak.bytes, cache.shm.readerSlot, rec):
    return (found: false, record: ActionResultRecord())
  try:
    let decoded = decodeActionResultRecord(rec)
    if decoded.weakFingerprint == weak:
      return (found: true, record: decoded)
  except CatchableError:
    discard
  (found: false, record: ActionResultRecord())

proc warmShmFromDisk(cache: ActionCache; record: ActionResultRecord) =
  ## AC-2c warm-on-miss (§4.3): the record was found on Tier-1 disk but the shm
  ## slot missed (a fresh daemon / evicted slot / another build's record we saw
  ## on disk first). Submit it so the daemon publishes it to the shared table
  ## for the NEXT lookup / other live builds. Best-effort (same submit path as
  ## record).
  cache.submitToShm(record)

proc readHotRecord*(cache: var ActionCache; weak: ContentDigest):
    tuple[found: bool; record: ActionResultRecord] =
  ## Read the newest metadata-only view of the edge's record.
  ##
  ## AC-2c: shm-first for the SHARED case, but Tier-1 disk stays authoritative
  ## for the edge's NEWEST record so the decision is provably identical to
  ## AC-1b. Concretely:
  ##   * Read the edge's Tier-1 records (union of all path-sets, newest-ordered).
  ##     If ANY match, return the disk newest exactly as AC-1b did AND — if the
  ##     shm slot missed — warm it (submit) so future reads hit in shm. This
  ##     NEVER lets a stale shm slot override the disk newest (no false miss).
  ##   * Only when the edge has NO Tier-1 record at all do we consult shm: a
  ##     genuine live-sharing rescue (another build's in-flight record the daemon
  ##     published to shm but that THIS process has not yet read from disk). Such
  ##     a shm hit is a valid record for `weak`; the caller re-checks input
  ##     freshness, so it can only become a correct hit — never a false one.
  let records = cache.loadPerEdgeRecords(weak)
  for i in countdown(records.high, 0):
    if records[i].weakFingerprint == weak:
      # Disk has the edge: warm shm if it was cold, then return the disk newest.
      let shmHit = cache.shmReadRecord(weak)
      if not shmHit.found:
        cache.warmShmFromDisk(records[i])
      return (found: true, record: hotMetadataRecord(records[i]))
  # Disk miss: the only possible hit is a live-shared record served from shm.
  let shmHit = cache.shmReadRecord(weak)
  if shmHit.found:
    return (found: true, record: hotMetadataRecord(shmHit.record))
  (found: false, record: ActionResultRecord())

proc appendActionResultRecord*(cache: var ActionCache;
                               record: ActionResultRecord) {.gcsafe.} =
  ## Public bridge so the peer-cache reader can install a peer-fetched
  ## record into the local action cache. Writes the edge's per-edge file
  ## (temp + atomic rename), never an append. Idempotency is bounded by
  ## `MaxRecordsPerWeakFingerprint`; re-installing an identical record
  ## leaves the file's record set unchanged.
  {.cast(gcsafe).}:
    cache.writePerEdgeRecord(record)

proc loadRecordsForWeak(cache: ActionCache; weak: ContentDigest):
    seq[ActionResultRecord] =
  ## Full-record lookup for one edge: UNION-read every path-set the edge has on
  ## disk (all `<nonce>.rec` files under `hot-records/<key>/`), keeping only
  ## records whose weak fingerprint matches (defensive against a hash collision
  ## on the directory name). O(records for THIS edge) — never a whole-cache
  ## scan. All distinct concurrent path-sets are considered, so the normal
  ## strong-fingerprint match can hit whichever path-set matches the current
  ## inputs (AC-1b). Bounded by `MaxRecFilesPerEdge` (the disk cap).
  ##
  ## AC-2c (§4.3): the shm slot for `weak` is UNIONED in as an ADDITIONAL
  ## candidate (a live-shared record another build published that this process
  ## has not yet read from disk). This is DECISION-SAFE: every candidate — disk
  ## or shm — is run through the SAME weak→strong / input-freshness / output-
  ## verify check by `lookupActionResult`, so a shm candidate can only turn a
  ## MISS into a HIT (live sharing) or be a no-op (deduped / rejected). It can
  ## never produce a FALSE hit (the strong-fp + output check still gate it) nor
  ## a FALSE miss (every disk record is still present). The shm candidate is
  ## appended LAST so the reverse-iterating decision considers the freshest
  ## cross-build record FIRST; on a shm miss the result is exactly AC-1b's disk
  ## union. Warm-on-miss: if disk has records but shm was cold, re-publish the
  ## newest so the next lookup / other live builds hit in shm.
  var seenStrong = initHashSet[string]()
  for record in cache.loadPerEdgeRecords(weak):
    if record.weakFingerprint == weak:
      result.add(record)
      seenStrong.incl(digestKey(record.strongFingerprint))
      if result.len > MaxRecFilesPerEdge:
        result = result[result.len - MaxRecFilesPerEdge .. ^1]
  let shmHit = cache.shmReadRecord(weak)
  if shmHit.found and shmHit.record.weakFingerprint == weak and
      not seenStrong.contains(digestKey(shmHit.record.strongFingerprint)):
    # A live-shared record this process's disk union does not have yet: consider
    # it FIRST (append last → reverse iteration hits it first).
    result.add(shmHit.record)
    if result.len > MaxRecFilesPerEdge:
      result = result[result.len - MaxRecFilesPerEdge .. ^1]
  elif not shmHit.found and result.len > 0:
    # Disk hit but shm cold: warm the slot for the next lookup / other builds.
    cache.warmShmFromDisk(result[^1])

const LegacyGlobalStoreFiles = [
  "action-results.records",
  "action-results.hot.records",
  "action-results.hot.index"]

proc removeLegacyGlobalStore(root: string) =
  ## One-time ignore-then-delete of the pre-existing global append-log files
  ## (Action-Cache-Per-Edge-Store.md §3). Best-effort: a busy concurrent
  ## reader on another host/process may still hold one open; a failed unlink
  ## is harmless because the per-edge store is authoritative and the global
  ## files are never read.
  for name in LegacyGlobalStoreFiles:
    let path = root / name
    if fileExists(extendedPath(path)):
      try:
        removeFile(extendedPath(path))
      except OSError:
        discard

# --- Tier-2 shared-memory accelerator wiring (AC-2c) ----------------------
#
# The shm tier is OPTIONAL and BEST-EFFORT (Action-Cache-Per-Edge-Store.md §4.6,
# §4.7). `openActionCache` attempts to attach the shm index for the root and to
# ensure a cache daemon owns it; ANY failure (non-POSIX, no atomics, permission,
# opted out via env) leaves `cache.shm` disabled and the engine runs pure Tier-1
# disk-only — exactly the AC-1b behavior. A build NEVER fails or blocks because
# the shm tier is unavailable.

const
  ShmDisableEnv = "REPRO_ACTION_CACHE_SHM"
    ## Set to "0"/"off"/"false"/"no" to force pure Tier-1 (disable the shm
    ## accelerator) — used by the fallback subtest and by callers on hosts where
    ## shared memory is undesirable.
  CacheDaemonEnv = "REPRO_CACHE_DAEMON_BIN"
    ## Optional override of the `repro-cache-daemon` binary path the engine
    ## auto-spawns. Defaults to a sibling of the current executable.
  CacheDaemonIdleEnv = "REPRO_CACHE_DAEMON_IDLE_MS"
    ## Optional override of the auto-spawned daemon's self-reap idle window (ms).
    ## Hermetic tests set a small value so an isolated-root daemon exits promptly
    ## and does not linger holding the temp cache root; the daemon's own default
    ## (30 s, §4.7) applies when unset.

proc shmTierEnabledByEnv(): bool =
  ## The shm tier is on by default; an explicit falsey env var forces it off.
  let v = getEnv(ShmDisableEnv, "1").toLowerAscii()
  v notin ["0", "off", "false", "no"]

proc cacheDaemonBinPath(): string =
  ## Locate the `repro-cache-daemon` binary: an explicit override, else a
  ## sibling of the current executable (both are installed into the same
  ## `build/bin` / package `bin`). Empty if none is found (⇒ no auto-spawn; the
  ## engine still reads/submits shm, and any co-running engine that DID spawn a
  ## daemon services the table — else pure Tier-1).
  let overridePath = getEnv(CacheDaemonEnv, "")
  if overridePath.len > 0 and fileExists(overridePath):
    return overridePath
  try:
    let selfDir = getAppDir()
    for name in ["repro-cache-daemon", "repro_cache_daemon"]:
      let p = selfDir / name
      if fileExists(p):
        return p
  except CatchableError:
    discard
  ""

proc ensureCacheDaemon(root: string; idx: ShmIndex) =
  ## Best-effort: if no live daemon owns the shm control region for `root`,
  ## spawn `repro-cache-daemon` DETACHED for it. The control-region
  ## pid/heartbeat election makes a redundant spawn harmless (only one wins), so
  ## we never coordinate — we just spawn when the region looks unowned. A failed
  ## spawn is swallowed: the engine's reads/submits still work (a co-running
  ## engine may have spawned the owner) and, worst case, records stay Tier-1.
  when shmIndexSupported:
    if not idx.available: return
    if not ownerLooksStale(idx): return        # a live owner already runs
    let bin = cacheDaemonBinPath()
    if bin.len == 0: return
    var args = @["--action-cache-root=" & root]
    let idleMs = getEnv(CacheDaemonIdleEnv, "")
    if idleMs.len > 0:
      args.add("--idle-exit-ms=" & idleMs)
    try:
      let p = startProcess(bin, args = args,
        options = {poDaemon, poStdErrToStdOut})
      # Detach: we do not wait on it. `poDaemon` puts it in its own session so
      # it outlives this engine (and services other concurrent builds).
      close(p)
    except CatchableError, OSError:
      discard
  else:
    discard

proc attachShmTier(root: string): ShmTier =
  ## Attach the shm index for `root` and ensure a daemon owns it. Best-effort:
  ## returns a DISABLED tier (engine runs pure Tier-1) on any failure or opt-out.
  result = ShmTier(enabled: false, readerSlot: 0)
  when shmIndexSupported:
    if not shmIndexSupported: return
    if not shmTierEnabledByEnv(): return
    var idx = openShmIndex(root)               # create ctl + gen-0 if absent
    if not idx.available:
      return
    result.idx = idx
    result.readerSlot = readerSlotForPid()
    result.enabled = true
    ensureCacheDaemon(root, idx)

proc openActionCache*(root: string; attachShm = true): ActionCache =
  ## Open the per-edge Tier-1 store for `root`. When `attachShm` (the default,
  ## the ENGINE path) it also attaches the OPTIONAL shared-memory hot tier and
  ## ensures its daemon (AC-2c). The DAEMON opens its OWN store with
  ## `attachShm = false` — it manages the shm table directly and must not
  ## recursively auto-spawn itself nor submit its persisted records back into
  ## the ring it drains.
  result.root = root
  result.hotRoot = root / "hot-records"
  createDir(extendedPath(result.root))
  createDir(extendedPath(result.hotRoot))
  # One-time cleanup: the old global append-log store is gone. Ignore any
  # pre-existing `action-results.*` files and delete them on open so a
  # migrated cache root stops growing without a re-init.
  removeLegacyGlobalStore(result.root)
  # Attach the OPTIONAL shared-memory hot tier (AC-2c) + ensure its daemon. On
  # any failure (or `attachShm = false`) this is a disabled tier and the cache
  # is pure Tier-1 (AC-1b).
  if attachShm:
    result.shm = attachShmTier(root)
  else:
    result.shm = ShmTier(enabled: false)

proc flushHotIndex*(cache: var ActionCache) =
  ## Retained as a public no-op for callers that flushed the former
  ## write-behind hot index. Per-edge records are now written synchronously
  ## and atomically at record time, so there is nothing to flush. (The
  ## shared-memory write-back tier is AC-2; this proc gains real work there.)
  discard

proc closeShmTier*(cache: var ActionCache) =
  ## Detach the optional shm hot tier (unmap + close fds). Best-effort; safe to
  ## call on a disabled/nil tier. The engine's process-long warm handle need not
  ## call this (process exit reclaims the mappings); hermetic tests that open +
  ## discard many caches call it to avoid fd growth. Does NOT stop the daemon —
  ## the daemon self-reaps after its idle window (§4.7).
  if cache.shm != nil and cache.shm.enabled:
    cache.shm.idx.close()
    cache.shm.enabled = false

proc lookupHotMetadataRecord*(cache: var ActionCache; weak: ContentDigest;
                              policy: FileFingerprintPolicy):
    Option[ActionResultRecord] =
  ## Metadata-only lookup served from the edge's single per-edge file.
  if policy notin {ffpTimestamp, ffpHybrid}:
    return none(ActionResultRecord)
  let hot = cache.readHotRecord(weak)
  if not hot.found or hot.record.policy != policy:
    return none(ActionResultRecord)
  some(hot.record)

proc hotMetadataInputsUnchanged*(cache: var ActionCache;
                                 metadataCache: ptr FileMetadataCache = nil): bool =
  ## Retained for API compatibility. There is no whole-cache hot-input set
  ## to scan anymore; per-edge input freshness is checked by the batch
  ## `scanHotIndexMetadataInputsUnchanged` / per-record helpers. With no
  ## global set to iterate, this trivially holds.
  true

proc hotMetadataRecordCount*(cache: var ActionCache): int =
  ## The former whole-cache count is meaningless without a global hot store.
  ## Returning 0 makes the build engine's `actions.len == count` shortcut
  ## never fire, so it always takes the per-record path (which reads each
  ## edge's file) — semantics-preserving, no whole-cache scan.
  0

proc hotMetadataRecordInputsUnchanged*(records: openArray[ActionResultRecord];
                                       metadataCache: ptr FileMetadataCache = nil): bool =
  var seen = initHashSet[string]()
  for record in records:
    for input in record.inputs:
      let inputKey = hotInputKey(input)
      if seen.contains(inputKey):
        continue
      seen.incl(inputKey)
      if fingerprintRecordedMetadata(input.path, input.metadata,
          metadataCache) != input.metadata:
        return false
  true

proc recordActionResult*(cache: var ActionCache; cas: LocalCas;
                         weak: ContentDigest; policy: FileFingerprintPolicy;
                         inputPaths, outputPaths: openArray[string];
                         outputRoot = "";
                         storeOutputBlobs = true;
                         metadataCache: ptr FileMetadataCache = nil):
                         ActionResultRecord =
  result.weakFingerprint = weak
  result.policy = policy
  for path in inputPaths:
    let input = observeFile(path, policy, metadataCache)
    if input.isRecordableInput():
      result.inputs.add(input)
  result.strongFingerprint = computeStrongFingerprint(weak, result.inputs)
  result.outputPayloadKind =
    if storeOutputBlobs: opkCasBlobs else: opkMetadataOnly
  for path in outputPaths:
    let source = materialPath(outputRoot, path)
    let sourceMetadata = fingerprintMetadata(source, metadataCache)
    # Windows: getFilePermissions returns a synthetic POSIX set derived from
    # the read-only attribute; we don't preserve it (see writePermissions),
    # so emit an empty set here. The cache record still round-trips cleanly.
    when defined(windows):
      let perms: set[FilePermission] = {}
    else:
      let perms = getFilePermissions(extendedPath(source))
    let blob =
      if storeOutputBlobs:
        if sourceMetadata.kind == ffkRegular and isDirectRegularFile(source):
          cas.storeFileBlob(source, sourceMetadata.sizeBytes)
        else:
          cas.storeBlob(bytes(readFile(extendedPath(source))))
      else:
        CasBlobRef()
    result.outputs.add(OutputBlob(path: path, metadata: sourceMetadata,
      blob: blob, permissions: perms))
  cache.writePerEdgeRecord(result)

proc refreshedInputs(record: ActionResultRecord; changed: var bool;
                     hybridCutoff: var bool;
                     changedInputPath: var string;
                     metadataCache: ptr FileMetadataCache):
                     tuple[inputs: seq[FileFingerprint],
                           reusedRecordedInputs: bool] =
  result.reusedRecordedInputs = true
  for i, recorded in record.inputs:
    let currentMetadata = fingerprintRecordedMetadata(recorded.path,
      recorded.metadata, metadataCache)
    case recorded.policy
    of ffpTimestamp:
      if currentMetadata != recorded.metadata:
        changed = true
        changedInputPath = recorded.path
        return
      if not result.reusedRecordedInputs:
        result.inputs[i] = recorded
    of ffpChecksum:
      let current = observeFileWithMetadata(recorded.path, recorded.policy,
        currentMetadata)
      if (not recorded.hasLocalHash) or (not current.hasLocalHash) or
          current.localHash != recorded.localHash:
        changed = true
        changedInputPath = recorded.path
        return
      if not result.reusedRecordedInputs:
        result.inputs[i] = recorded
    of ffpHybrid:
      if currentMetadata == recorded.metadata:
        if not result.reusedRecordedInputs:
          result.inputs[i] = recorded
        continue
      if not recorded.hasLocalHash:
        changed = true
        changedInputPath = recorded.path
        return
      let current = observeFileWithMetadata(recorded.path, recorded.policy,
        currentMetadata)
      if not current.hasLocalHash:
        changed = true
        changedInputPath = recorded.path
        return
      if current.localHash == recorded.localHash:
        if result.reusedRecordedInputs:
          result.inputs = newSeq[FileFingerprint](record.inputs.len)
          for prior in 0 ..< i:
            result.inputs[prior] = record.inputs[prior]
          result.reusedRecordedInputs = false
        result.inputs[i] = current
        hybridCutoff = true
      else:
        changed = true
        changedInputPath = recorded.path
        return

proc verifyOutputs(cas: LocalCas; record: ActionResultRecord) =
  if record.outputPayloadKind != opkCasBlobs:
    raise newException(CacheIntegrityError,
      "cache record does not contain output payloads")
  for output in record.outputs:
    cas.verifyBlob(output.blob)

proc lookupActionResult*(cache: var ActionCache; cas: LocalCas;
                         weak: ContentDigest; policy: FileFingerprintPolicy;
                         verifyOutputBlobs = true;
                         allowMetadataOnlyHit = false;
                         metadataCache: ptr FileMetadataCache = nil): ActionCacheLookup =
  if allowMetadataOnlyHit and not verifyOutputBlobs and policy in {ffpTimestamp, ffpHybrid}:
    let hot = cache.readHotRecord(weak)
    if hot.found and hot.record.policy == policy:
      var changed = false
      var changedInput = ""
      for input in hot.record.inputs:
        if fingerprintRecordedMetadata(input.path, input.metadata,
            metadataCache) != input.metadata:
          changed = true
          changedInput = input.path
          break
      if not changed:
        return ActionCacheLookup(status: aclHit, record: hot.record)
      return ActionCacheLookup(
        status: aclMissInputChanged,
        record: hot.record,
        message: "input metadata changed: " & changedInput,
        changedInputPath: changedInput)

  let records = cache.loadRecordsForWeak(weak)
  if records.len == 0:
    return ActionCacheLookup(status: aclMissNoRecord,
      message: "no cache record for weak fingerprint")
  var sawInputChange = false
  var firstChangedInput = ""
  for i in countdown(records.high, 0):
    let record = records[i]
    if record.policy != policy:
      continue
    var changed = false
    var hybridCutoff = false
    var changedInput = ""
    let refreshed = refreshedInputs(record, changed, hybridCutoff,
      changedInput, metadataCache)
    if changed:
      sawInputChange = true
      if firstChangedInput.len == 0:
        firstChangedInput = changedInput
      continue
    var candidate = record
    if not refreshed.reusedRecordedInputs:
      candidate.inputs = refreshed.inputs
      candidate.strongFingerprint = computeStrongFingerprint(weak,
        candidate.inputs)
      if candidate.strongFingerprint != record.strongFingerprint:
        sawInputChange = true
        if firstChangedInput.len == 0:
          firstChangedInput = "strong fingerprint"
        continue
    if verifyOutputBlobs:
      if candidate.outputPayloadKind != opkCasBlobs:
        return ActionCacheLookup(status: aclMissNoOutputPayload,
          record: candidate,
          message: "cache record does not contain output payloads")
      try:
        cas.verifyOutputs(candidate)
      except CacheIntegrityError as err:
        return ActionCacheLookup(status: aclRejectedCorruptOutput,
          record: candidate, message: err.msg)
    if hybridCutoff:
      cache.writePerEdgeRecord(candidate)
      return ActionCacheLookup(status: aclHybridCutoff, record: candidate)
    return ActionCacheLookup(status: aclHit, record: candidate)
  if sawInputChange:
    ActionCacheLookup(
      status: aclMissInputChanged,
      message:
        if firstChangedInput.len > 0:
          "input changed: " & firstChangedInput
        else:
          "input changed",
      changedInputPath: firstChangedInput)
  else:
    ActionCacheLookup(status: aclMissNoRecord,
      message: "no matching cache record for policy")

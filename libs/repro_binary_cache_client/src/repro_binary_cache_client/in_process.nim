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

import std/[algorithm, httpclient, httpcore, net, os, sets, tempfiles,
            sequtils, strutils, tempfiles, times]
when defined(posix):
  # rename(2) directly: Nim's moveDir falls back to copy-and-remove when the
  # rename fails, which is exactly the partial state extractPrefixInto refuses.
  proc cRename(oldPath, newPath: cstring): cint {.importc: "rename", header: "<stdio.h>".}

when defined(ssl):
  import wrappers/openssl

import blake3

import ./types
import ./http_pool
import ./scheduler_executor
import ./closure_walk
import ./index
import ./cache_key
import ./compress
import ./decompress

import repro_core/link_target
import repro_core/paths
import repro_core/target_object_check

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
    trustRejected*: bool
      ## At least one endpoint refused the root (or a member) on TRUST. OR-ed
      ## across every endpoint tried, so a trust refusal on a higher-priority
      ## cache followed by a plain miss on a lower one is still reported as a
      ## trust refusal; `reason` alone keeps only the last endpoint's text.

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
    ##   * ``rawArchiveDigestHex`` — BLAKE3 hex of the raw (uncompressed)
    ##     prefix archive, set as soon as the archive is written (so it is
    ##     present on a failed upload too); what a profile pins as
    ##     ``expectedOutputDigest = "blake3:<hex>"``.
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
    rawArchiveDigestHex*: string

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
  ArchiveEntryKind* = enum
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
  # Extended-length form throughout the walk. A published prefix is an
  # upstream tree, and upstream trees on Windows routinely run past
  # MAX_PATH -- PostgreSQL's bundled pgAdmin nests SQL templates twelve
  # directories deep. Without this, ``walkDir`` stops at the first such
  # directory and the archive is silently short, or the size probe below
  # fails with "the system cannot find the path specified" and the publish
  # is skipped for a reason that says nothing about path length.
  #
  # ``extendedPath`` is idempotent on an already-extended path, so the
  # recursion below re-applying it costs nothing.
  for component, path in walkDir(extendedPath(current), skipSpecial = true):
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
  of aekFile: getFileSize(extendedPath(path))
  of aekDirectory: 0
  of aekSymlink: int64(readSymlinkTarget(extendedPath(path)).len)

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
  # A nil `output` is the hash-only writer: the archive is streamed through
  # the hasher and written nowhere, which is how a consumer checks present
  # outputs against a pinned digest without a 40 MB temporary file.
  if writer.output != nil and
      writer.output.writeBuffer(data, dataLen) != dataLen:
    raise newException(IOError, "short write while creating rbcarc")
  writer.hasher.update(data, dataLen)
  writer.bytesWritten += int64(dataLen)

proc writeArchiveString(writer: var ArchiveFileWriter; data: string) =
  if data.len > 0:
    writer.writeArchiveBytes(unsafeAddr data[0], data.len)

proc hashFileBlake3(path: string): bcsTypes.Blake3Hash =
  ## BLAKE3 of a file's bytes, read in fixed-size chunks.
  ##
  ## The publish path needs this only for a COMPRESSED payload: the plain
  ## archive is hashed as it is written, but the compressor writes its output
  ## through libzstd where no hasher is in the loop. Streaming here keeps a
  ## multi-gigabyte payload out of memory, which is the whole reason the
  ## archive was written to a file rather than a buffer in the first place.
  var hasher = initHasher()
  defer: hasher.close()
  var f = open(path, fmRead)
  defer: close(f)
  var buffer = newSeq[byte](ArchiveCopyBufferBytes)
  while true:
    let read = f.readBuffer(addr buffer[0], buffer.len)
    if read <= 0:
      break
    hasher.update(addr buffer[0], read)
  let digest = hasher.finalize()
  for i in 0 ..< 32:
    result[i] = digest[i]

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
      if entry.kind == aekSymlink: 0'u32
      else: fileModeOctal(extendedPath(path))
    writer.writeArchiveString(littleEndianBytes(uint64(mode), 4))
    let payloadSize = archiveEntryPayloadSize(plan, entry)
    writer.writeArchiveString(littleEndianBytes(uint64(payloadSize), 8))
    case entry.kind
    of aekFile:
      var input: File
      if not open(input, extendedPath(path), fmRead):
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
      writer.writeArchiveString(readSymlinkTarget(extendedPath(path)))
  if writer.bytesWritten != plan.size:
    raise newException(IOError,
      "rbcarc size changed while archiving: expected " & $plan.size &
      ", wrote " & $writer.bytesWritten)
  result = writer.hasher.finalize()

proc prefixArchiveDigestHex*(prefix: string): string =
  ## BLAKE3 hex of the raw archive `publishInProcess` would write for
  ## `prefix` — by the SAME planner and writer, so a consumer that hashes
  ## its present outputs with this gets the digest the publisher printed
  ## (`expectedOutputDigest`), and not a near-identical archive from a
  ## second implementation. Streamed through the hasher; nothing is written.
  writeArchiveFile(planPrefixArchive(prefix), nil).toHex()

proc prefixSubsetArchiveDigestHex*(root: string;
                                   members: openArray[string]): string =
  ## The digest `prefixArchiveDigestHex` would give for a prefix holding
  ## only `members` (root-relative paths, each a file or a directory) of
  ## `root` — what the publisher's staging of an edge's declared outputs
  ## produces, computed in place over `root` without copying anything.
  ## The staged tree holds the members' regular files and the directories
  ## that lead to them, and nothing else, so: an entry outside every member
  ## is dropped, a directory with no kept file beneath it is dropped (the
  ## stage never creates it), and a symbolic link is refused as the
  ## publisher refuses to stage one.
  var want: seq[string] = @[]
  for m in members:
    let n = m.replace('\\', '/').strip(chars = {'/'})
    if n.len > 0: want.add(n)
  proc covered(path: string): bool =
    for w in want:
      if path == w or path.startsWith(w & "/"): return true
    false
  var plan: PrefixArchivePlan
  plan.root = absolutePath(root)
  plan.rootIsDirectory = true
  var kept: seq[ArchiveEntry] = @[]
  var fileDirs = initHashSet[string]()
  for entry in walkPrefix(plan.root):
    case entry.kind
    of aekSymlink:
      if covered(entry.path):
        raise newException(IOError,
          "output tree holds a symbolic link, which a publisher refuses to " &
          "stage: " & entry.path)
    of aekFile:
      if covered(entry.path):
        kept.add(entry)
        var d = entry.path
        while true:
          let i = d.rfind('/')
          if i < 0: break
          d = d[0 ..< i]
          fileDirs.incl(d)
    of aekDirectory:
      # Every directory is a candidate: a member may be a FILE below a
      # directory that is not itself a member (`bin/x`), and the stage
      # creates that directory on the way to the file.
      kept.add(entry)
  var entries: seq[ArchiveEntry] = @[]
  for e in kept:
    if e.kind == aekDirectory and e.path notin fileDirs: continue
    entries.add(e)
  plan.entries = entries
  for entry in plan.entries:
    plan.size += 4'i64 + int64(entry.path.len) + 1 + 4 + 8 +
      archiveEntryPayloadSize(plan, entry)
  plan.size += 12
  writeArchiveFile(plan, nil).toHex()

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
    let absPath = extendedPath(prefix / entry.path)
    let mode =
      if entry.kind == aekSymlink: 0'u32 else: fileModeOctal(absPath)
    let pathBytes = entry.path
    let payload =
      case entry.kind
      of aekFile: readFile(absPath)
      of aekDirectory: ""
      of aekSymlink: readSymlinkTarget(absPath)
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

type
  ExtractedEntry* = tuple[path: string, kind: ArchiveEntryKind]
    ## One archive entry as extracted: its POSIX-style relative path and
    ## kind. ``extractPrefix`` returns the list so a consumer can tell an
    ## explicit directory entry from a directory that merely exists because
    ## a file beneath it was created.

proc extractPrefixRaw(archive: openArray[byte]; outDir: string): seq[ExtractedEntry]

proc rawArchiveBytes*(archive: openArray[byte]): seq[byte] =
  ## The raw ``rbcarc`` bytes of a payload as its producer wrote them:
  ## ``archive`` itself, or its zstd frame decompressed. The CAS stores
  ## each payload exactly as its producer signed it, so a blob read back
  ## carries no manifest to say which codec produced it -- but ``rbcarc``
  ## begins with ``RBCA`` and a zstd frame with its own magic, so the two
  ## never collide. This is also the byte string whose BLAKE3 a profile
  ## pins as ``expectedOutputDigest`` and ``repro cache publish`` prints:
  ## one hash of one representation, whatever the transport did.
  if isZstdFrame(archive):
    var plain: seq[byte] = @[]
    let decomp =
      try:
        newDecompressor(ckZstd)
      except DecompressUnavailable as e:
        raise newException(IOError,
          "rbcarc is zstd-compressed but this host cannot decompress it: " &
          e.msg)
    defer: decomp.close()
    let sink: ChunkSink = proc(data: openArray[byte]) =
      if data.len > 0:
        let at = plain.len
        plain.setLen(at + data.len)
        copyMem(addr plain[at], unsafeAddr data[0], data.len)
    try:
      decomp.feed(archive, sink)
      decomp.finish(sink)
    except DecompressError as e:
      raise newException(IOError, "rbcarc zstd decode failed: " & e.msg)
    return plain
  @archive

proc extractPrefix*(archive: openArray[byte]; outDir: string): seq[ExtractedEntry] {.discardable.} =
  ## Extract an ``rbcarc-v1`` or ``rbcarc-v2`` archive into ``outDir``.
  ## v2 preserves regular files, directory entries, and symbolic links;
  ## v1 remains accepted so already-published cache entries keep working.
  ## Raises ``IOError`` on a malformed / truncated archive.
  ##
  ## A zstd-compressed archive is decompressed first. The CAS stores each
  ## payload exactly as its producer signed it, so a blob read back carries
  ## no manifest to say which codec produced it -- but ``rbcarc`` begins with
  ## ``RBCA`` and a zstd frame with its own magic, so the two never collide.
  ## Sniffing here rather than at each call site means every consumer of a
  ## substituted prefix -- the tool store, the provider-compile cache, the
  ## build-action apply path, the CLI -- handles compressed entries without
  ## knowing they exist.
  extractPrefixRaw(rawArchiveBytes(archive), outDir)

const ExtractMutation {.strdefine: "reproAddonMutation".} = ""
  ## Only a falsifying test build of the static ReproOS add-on binary sets
  ## this (``-d:reproAddonMutation=agent-extract-follows-links``); see
  ## ``repro_addon/mutations``. Empty in every product build.

proc refuseWriteThroughSymlink*(outDir, rel: string) =
  ## Raise unless writing the entry ``rel`` under ``outDir`` stays inside
  ## ``outDir``.
  ##
  ## Rejecting absolute paths and ``..`` components (done by the caller) only
  ## constrains the entry's *text*. ``rbcarc-v2`` also carries symbolic links,
  ## and every primitive used below (``createDir``, ``writeFile``,
  ## ``createSymlink`` into a parent) follows a link already on the path. An
  ## archive holding ``d -> /etc`` and then ``d/cron.d/job`` would therefore
  ## write ``/etc/cron.d/job``; one holding ``f -> /etc/passwd`` and then a
  ## file ``f`` would overwrite ``/etc/passwd``. Prefixes are materialised by
  ## privileged applies, so either is a write anywhere as root.
  ##
  ## The rule: no component of the entry's path that already exists may be a
  ## symbolic link, the entry itself included. Links the archive creates are
  ## still extracted -- real prefixes carry ``libfoo.so -> libfoo.so.1`` --
  ## but nothing is ever written *through* one. The extraction directory is
  ## private to the extracting process, so nothing else can add a link
  ## between this check and the write.
  ##
  ## Exported so every consumer that copies substituted bytes onward (the
  ## build-action apply path writes them into an action's working
  ## directory) applies the same rule to its own destination.
  when ExtractMutation == "agent-extract-follows-links":
    # Falsifying build of the ReproOS add-on gate
    # `e2e_addon_hostile_archive_cannot_escape_staging`: the check is gone.
    return
  var cur = outDir
  for part in rel.split('/'):
    cur = cur / part
    if symlinkExists(cur):
      raise newException(IOError,
        "rbcarc rejected entry written through a symbolic link: " & rel &
        " (" & cur & " is a link)")

proc extractPrefixRaw(archive: openArray[byte]; outDir: string): seq[ExtractedEntry] =
  result = @[]
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
  createDir(extendedPath(outDir))
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
    if size > uint64(archive.len - pos):
      raise newException(IOError,
        "rbcarc truncated reading file body for " & rel)
    let absOut = outDir / rel
    refuseWriteThroughSymlink(outDir, normalizedRel)
    result.add((path: normalizedRel, kind: entryKind))
    # Same MAX_PATH argument as the walk on the publish side: a tree deep
    # enough to archive is deep enough to fail to restore.
    createDir(extendedPath(parentDir(absOut)))
    var data = newString(int(size))
    for i in 0 ..< int(size):
      data[i] = char(archive[pos + i])
    inc pos, int(size)
    case entryKind
    of aekFile:
      writeFile(extendedPath(absOut), data)
      when not defined(windows):
        setFilePermissions(absOut, modeFilePermissions(mode))
    of aekDirectory:
      if data.len != 0:
        raise newException(IOError,
          "rbcarc directory entry has a non-empty payload: " & rel)
      createDir(extendedPath(absOut))
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

proc extractPrefixInto*(archive: openArray[byte]; outDir: string) =
  ## Extract into ``outDir`` all or nothing. The archive is extracted into a
  ## fresh staging directory beside ``outDir`` first and renamed into place
  ## only when every entry was accepted, so a refused or malformed archive
  ## (including one ``refuseWriteThroughSymlink`` rejects) leaves no partial
  ## tree behind. ``outDir`` must be absent or an empty directory, and not a
  ## symbolic link: extracting over existing content would mix the cache's
  ## bytes with whatever was there, and a link would make the rename land
  ## wherever it points. Raises ``IOError`` on every refusal and failure.
  ##
  ## The staging directory has a random name and is created with mkdir
  ## semantics that fail when the name exists (``createTempDir``), so nothing
  ## planted beside ``outDir`` can be mistaken for it. This proc never removes
  ## a path it did not create: an earlier version staged under the predictable
  ## ``.<name>.repro-extract-<pid>`` and began by removing it, and ``removeDir``
  ## follows a symbolic link, so a link planted at that name made a privileged
  ## caller empty the directory it pointed at.
  if symlinkExists(outDir):
    raise newException(IOError,
      "substitute output path is a symbolic link: " & outDir)
  if dirExists(outDir):
    for _ in walkDir(outDir):
      raise newException(IOError,
        "substitute output directory is not empty: " & outDir)
  elif fileExists(outDir):
    raise newException(IOError,
      "substitute output path exists and is not a directory: " & outDir)
  let outAbs = absolutePath(outDir)
  let parent = parentDir(outAbs)
  createDir(parent)
  let tmp =
    try:
      createTempDir(".repro-extract-", "", parent)
    except CatchableError as e:
      raise newException(IOError,
        "cannot create a staging directory beside " & outDir & ": " & e.msg)
  try:
    extractPrefix(archive, tmp)
    when defined(posix):
      # rename(2) replaces an empty directory atomically and never follows
      # a link at the destination; Nim's moveDir would fall back to copying
      # when the rename fails, which is exactly the partial state refused here.
      if cRename(tmp.cstring, outAbs.cstring) != 0:
        raise newException(IOError,
          "cannot move the extracted prefix into place at " & outDir & ": " &
          osErrorMsg(osLastError()))
    else:
      if dirExists(outAbs):
        removeDir(outAbs)
      moveDir(tmp, outAbs)
  except CatchableError as e:
    try: removeDir(tmp) except CatchableError: discard
    if e of IOError: raise
    raise newException(IOError, e.msg)

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
          if outcome.trustRejected:
            result.trustRejected = true
          break
      if allOk:
        result.ok = true
        result.plan = plan
        result.outcomes = outcomes
        try: idx.flush() except CatchableError: discard
        return
      else:
        result.outcomes = outcomes
        # Name the substitute that failed and why: "failed" alone leaves an
        # operator nothing to act on.
        result.reason = "one or more substitutes failed on " & endpoint.baseUrl &
          (if outcomes.len > 0 and outcomes[^1].reason.len > 0:
             ": " & outcomes[^1].reason else: "")
    except ClosureWalkTrustError as e:
      result.trustRejected = true
      result.reason = "endpoint " & endpoint.baseUrl & ": " & e.msg
      continue
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

  # The object check at the publication boundary: a prefix published under
  # another platform's identity must hold that platform's objects
  # (CLI/build.md §"Cross Targets: `--target`"). This is the route by which
  # cross-built bytes reach a cache (Binary-Caches.md §"Publishing for a host
  # that cannot build"), so host bytes are refused here whoever publishes.
  let p = req.identity.platform
  let mismatches =
    try:
      targetObjectMismatchesForPublication(req.prefixDir, p.cpu, p.os, p.abi,
        p.libcVariant, decodeTargetObjectExemptions(
          getEnv(TargetObjectExemptionsEnvVar)))
    except UnknownTargetCpu, ValueError:
      @[getCurrentExceptionMsg()]
  if mismatches.len > 0:
    result.error = "publish: " & $mismatches.len & " object(s) under " &
      req.prefixDir & " are not for the platform it is published under (" &
      p.cpu & "/" & p.os & "/" & p.abi & "/" & p.libcVariant &
      "), so nothing is published (the object check):\n  " &
      mismatches.join("\n  ")
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
  # NOTE: the limit is checked against the bytes actually UPLOADED, below,
  # not against ``archivePlan.size``. Those differ once the payload is
  # compressed, and checking the uncompressed size here is what kept every
  # prefix over 1 GiB out of the cache even when its compressed form would
  # have fit comfortably.

  var archiveFile: File
  var archivePath = ""
  var archiveOpen = false
  var compressedPath = ""
  defer:
    if archiveOpen:
      try: close(archiveFile)
      except CatchableError: discard
    if archivePath.len > 0 and fileExists(archivePath):
      try: removeFile(archivePath)
      except CatchableError: discard
    if compressedPath.len > 0 and fileExists(compressedPath):
      try: removeFile(compressedPath)
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
    # The digest a profile pins as `expectedOutputDigest`: of the RAW
    # archive, before compression, which is also what a consumer hashes
    # after it has decompressed the payload (`rawArchiveBytes`).
    result.rawArchiveDigestHex = rawDigest.toHex()
  except CatchableError as e:
    result.error = "publish: cannot create prefix archive: " & e.msg
    return

  # Compress the archive when this host can, and upload whichever form is
  # smaller. Compression is opportunistic on both counts: a host without
  # libzstd publishes the plain archive (the payload declares its own codec,
  # so consumers are unaffected), and an already-compressed prefix whose
  # zstd form came out no smaller is published plain rather than paying a
  # decompression step for nothing.
  var uploadPath = archivePath
  var uploadCompression = bcsTypes.ckNone
  var uploadSize = archivePlan.size
  var payloadDigest: bcsTypes.Blake3Hash
  for i in 0 ..< 32:
    payloadDigest[i] = rawDigest[i]

  if getEnv("REPRO_PUBLISH_NO_COMPRESSION").len == 0 and
      supportsCompressor(bcsTypes.ckZstd):
    try:
      let candidate = archivePath & ".zst"
      let compressedSize = compressFileToFile(archivePath, candidate,
        bcsTypes.ckZstd)
      compressedPath = candidate
      if compressedSize > 0 and compressedSize < archivePlan.size:
        uploadPath = candidate
        uploadCompression = bcsTypes.ckZstd
        uploadSize = compressedSize
        # The manifest's ``digest`` is over the bytes as transferred and
        # stored -- the compressed ones -- because that is what the CAS
        # holds and what the consumer can verify without first trusting
        # the codec. See ``payload_sink``'s hash check.
        payloadDigest = hashFileBlake3(candidate)
    except CatchableError:
      # Any compression failure is a soft one: fall through with the plain
      # archive rather than losing the entry entirely.
      discard

  if uploadSize > maxArchiveBytes:
    result.error = "publish skipped: prefix archive is " &
      $uploadSize & " bytes" &
      (if uploadCompression == bcsTypes.ckZstd:
         " compressed (" & $archivePlan.size & " uncompressed)"
       else: "") &
      ", exceeding the " & $maxArchiveBytes &
      "-byte /publish payload limit"
    return
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
    compression: uploadCompression,
    declaredSize: uint64(uploadSize),
    uncompressedSize: uint64(archivePlan.size),
    digest: payloadDigest,
    name: if uploadCompression == bcsTypes.ckZstd: "prefix.rbcarc.zst"
          else: "prefix.rbcarc")
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
  discard multipart.addFiles({"payload": uploadPath})
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
  # Socket timeout for the upload. The old 60 s was sized for the small
  # build-action outputs this path originally carried; a toolchain prefix is
  # three orders of magnitude larger, and a stall partway through a
  # multi-hundred-megabyte POST surfaced as an opaque gateway error rather
  # than as a timeout. Overridable so an operator on a slow link can raise it
  # without a rebuild.
  let publishTimeoutMs =
    try:
      max(parseInt(getEnv("REPRO_BINARY_CACHE_PUBLISH_TIMEOUT_MS", "600000")),
        1000)
    except ValueError:
      600_000
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
        newHttpClient(timeout = publishTimeoutMs, sslContext = ctx)
      else:
        newHttpClient(timeout = publishTimeoutMs, sslContext = nil)
    else:
      newHttpClient(timeout = publishTimeoutMs)
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

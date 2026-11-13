## Intent-snapshot packed tree writer/reader (M62 —
## Home-Profile-Generations-And-State.md "Intent Snapshot").
##
## At apply time, the resolved intent files (`home.nim` plus any
## sibling helper/predicate modules it imports) are packed into a
## single binary blob, stored in the local CAS, and the resulting
## BLAKE3-256 digest becomes the pointer envelope's
## `intentSnapshotDigest`. Two generations whose intent layer is
## byte-identical share one CAS blob.
##
## Binary on-disk shape (little-endian throughout):
##
##   offset 0   :  magic                       4 bytes ASCII "RBSN"
##                 ("Reprobuild Snapshot of iNtent")
##   offset 4   :  schemaVersion               u16 LE
##   offset 6   :  bodyLength                  u32 LE
##   offset 10  :  body                        bodyLength bytes
##   trailing   :  trailingChecksum            32 bytes BLAKE3-256
##
## Body shape:
##
##   u32 LE count
##   per file:
##     u32 LE path-byte-length + path bytes (UTF-8, forward-slash-
##                                          normalized)
##     u64 LE content-byte-length + content bytes (verbatim, NO
##                                                truncation)
##
## The reader/writer are bit-exact: a file's bytes go in 1:1. Empty
## files are allowed; their content-length is 0.
##
## Schema version 2 (GM4) adds one byte per file, after the path, naming
## the file's ROLE: 0 = a profile source file (`home.nim` and its sibling
## modules), 1 = a plan-time data file the profile's `data:` section
## declares, stored with the exact bytes the planner expanded. The data
## files make the snapshot — and so the generation id — record the data a
## generation was planned from: a rollback never depends on the live file,
## and `repro home history` reports each generation's data digests from
## here. A snapshot holding source files only is still written as version
## 1, byte-identical to before, so a profile without data files keeps its
## generation ids across the upgrade.
##
## M62 only requires the framed-blob protocol; the M63 apply pipeline
## populates it from a real scan of the profile directory.

import std/[os, algorithm, strutils]

import blake3
import repro_core

import ./errors
import ./pointer

const
  SnapshotMagic* = "RBSN"
  SnapshotSchemaVersion*: uint16 = 2
    ## The newest version this build reads and writes (see the header).
  SnapshotSourceOnlyVersion*: uint16 = 1
    ## The version written when every entry is a source file.
  SnapshotHeaderSize = 4 + 2 + 4
  SnapshotTrailerSize = 32

type
  IntentFileRole* = enum
    ## Why a file is in the snapshot (schema 2; see the header).
    ifrSource = 0  ## a profile source file
    ifrData = 1    ## a plan-time data file, as the planner read it

  IntentFileEntry* = object
    ## One file in the snapshot. `path` is the file's path relative to
    ## the profile directory, with forward slashes (so the encoding is
    ## portable across hosts).
    path*: string
    content*: seq[byte]
    role*: IntentFileRole

  IntentSnapshot* = object
    schemaVersion*: uint16
    files*: seq[IntentFileEntry]

# ---------------------------------------------------------------------------
# Public seam: walk the profile directory.
# ---------------------------------------------------------------------------

type
  WalkProfileFiles* = proc (profileDir: string): seq[IntentFileEntry]
    {.gcsafe.}
    ## Hook used by the apply pipeline (M63) to populate the snapshot
    ## from the live profile directory. M62 ships only a minimal
    ## default that bundles `*.nim` files in the directory non-
    ## recursively; M63 may refine to follow imports precisely.

proc normalizePath(rel: string): string =
  result = rel
  for i in 0 ..< result.len:
    if result[i] == '\\':
      result[i] = '/'

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc defaultWalkProfileFiles*(profileDir: string): seq[IntentFileEntry] =
  ## Default walker: bundles every `*.nim` file directly under
  ## `profileDir` (non-recursive). Sorted by path so two equivalent
  ## profile directories produce byte-identical snapshots regardless
  ## of OS readdir order.
  if not dirExists(extendedPath(profileDir)):
    return @[]
  var paths: seq[string]
  for kind, entry in walkDir(extendedPath(profileDir), relative = true):
    if kind notin {pcFile, pcLinkToFile}:
      continue
    if not entry.endsWith(".nim"):
      continue
    paths.add(entry)
  paths.sort()
  for rel in paths:
    let abs = profileDir / rel
    let content = readFile(extendedPath(abs))
    result.add(IntentFileEntry(path: normalizePath(rel),
      content: bytesOf(content)))

proc observedProfileFiles*(profileDir: string; observed: openArray[string]):
    seq[string] =
  ## The profile-relative paths (forward slashes, sorted, unique) of the
  ## files among `observed` -- the absolute paths the profile compile edge
  ## was seen reading -- that lie under `profileDir` at any depth and still
  ## exist as regular files. `profileDir` is matched both as given and
  ## through its resolved real path, since the monitor reports the path the
  ## compiler opened. A read of something that is gone (the helper's
  ## temporary `config.nims`) or is a directory is not a source file.
  var roots = @[absolutePath(profileDir)]
  try:
    let real = expandFilename(profileDir)
    if real notin roots:
      roots.add real
  except OSError:
    discard
  for raw in observed:
    if not raw.isAbsolute:
      continue
    for root in roots:
      if not raw.startsWith(root & DirSep):
        continue
      let rel = normalizePath(raw.relativePath(root))
      if rel notin result and fileExists(extendedPath(raw)) and
          not dirExists(extendedPath(raw)):
        result.add rel
      break
  result.sort()

proc profileSourceFiles*(profileDir: string; compiledFrom: openArray[string]):
    seq[IntentFileEntry] =
  ## The source files of a generation's intent snapshot: every `*.nim`
  ## directly under `profileDir` (`defaultWalkProfileFiles`) plus every
  ## file under `profileDir` the profile compile was observed reading
  ## (`compiledFrom`; `observedProfileFiles`) -- helper modules the profile
  ## imports from subdirectories, and files it reads at compile time.
  ## Sorted by path. The directory walk alone omitted the subdirectory
  ## modules, so the snapshot of such a profile could not be compiled on
  ## its own and an edit to one of them went unrecorded (reprobuild-pm
  ## issue 2026-10-18-home-intent-snapshot-omits-imported-modules-in-
  ## subdirectories; Home-Profile-Generations-And-State.md §Intent
  ## Snapshot). A profile whose compile reads nothing but its top-level
  ## `*.nim` files gets exactly the walk's entries, so its snapshot bytes
  ## and generation ids do not change; with no observation (`compiledFrom`
  ## empty) the snapshot is the walk.
  result = defaultWalkProfileFiles(profileDir)
  var have: seq[string]
  for e in result:
    have.add e.path
  var added = false
  for rel in observedProfileFiles(profileDir, compiledFrom):
    if rel in have:
      continue
    have.add rel
    added = true
    result.add(IntentFileEntry(path: rel,
      content: bytesOf(readFile(extendedPath(profileDir / rel)))))
  if added:
    result.sort(proc(a, b: IntentFileEntry): int = cmp(a.path, b.path))

# ---------------------------------------------------------------------------
# Encoding.
# ---------------------------------------------------------------------------

proc writeBytes(outp: var seq[byte]; data: openArray[byte]) =
  for b in data: outp.add(b)

proc encodedVersion*(snapshot: IntentSnapshot): uint16 =
  ## The schema version `encodeSnapshot` writes for `snapshot`: 1 when
  ## every entry is a source file (unchanged bytes for profiles without
  ## data files), else 2.
  for entry in snapshot.files:
    if entry.role != ifrSource:
      return SnapshotSchemaVersion
  SnapshotSourceOnlyVersion

proc encodeBody(snapshot: IntentSnapshot; version: uint16): seq[byte] =
  result.writeU32Le(uint32(snapshot.files.len))
  for entry in snapshot.files:
    result.writeU32Le(uint32(entry.path.len))
    for ch in entry.path:
      result.add(byte(ord(ch)))
    if version >= 2'u16:
      result.add(byte(ord(entry.role)))
    result.writeU64Le(uint64(entry.content.len))
    for b in entry.content:
      result.add(b)

proc encodeSnapshot*(snapshot: IntentSnapshot): seq[byte] =
  ## Serialize the snapshot to bytes with the envelope shape above.
  ## The bytes are deterministic.
  let version = encodedVersion(snapshot)
  let body = encodeBody(snapshot, version)
  let bodyLen = uint32(body.len)
  result = newSeqOfCap[byte](
    SnapshotHeaderSize + body.len + SnapshotTrailerSize)
  for ch in SnapshotMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(version)
  result.writeU32Le(bodyLen)
  result.writeBytes(body)
  let checksum = blake3.digest(result)
  result.writeBytes(checksum)

proc snapshotDigest*(snapshot: IntentSnapshot): Digest256 =
  ## BLAKE3-256 over the canonical encoded bytes — equals the CAS key.
  blake3.digest(encodeSnapshot(snapshot))

# ---------------------------------------------------------------------------
# Decoding.
# ---------------------------------------------------------------------------

proc decodeSnapshotBytes*(bytes: openArray[byte];
                         filePath = "<memory>"): IntentSnapshot =
  if bytes.len < SnapshotHeaderSize + SnapshotTrailerSize:
    raiseIntentSnapshotCorrupt(filePath, "envelope",
      "file is too short to be an intent snapshot")
  for i in 0 ..< 4:
    if bytes[i] != byte(ord(SnapshotMagic[i])):
      raiseIntentSnapshotCorrupt(filePath, "magic",
        "expected '" & SnapshotMagic & "' magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version < SnapshotSourceOnlyVersion or version > SnapshotSchemaVersion:
    raiseIntentSnapshotCorrupt(filePath, "schemaVersion",
      "unsupported intent-snapshot schema version " & $version)
  let bodyLen = int(readU32Le(bytes, pos))
  if pos + bodyLen + SnapshotTrailerSize != bytes.len:
    raiseIntentSnapshotCorrupt(filePath, "bodyLength",
      "declared body length disagrees with file size")
  let bodyEnd = pos + bodyLen
  var prefix = newSeqOfCap[byte](bodyEnd)
  for i in 0 ..< bodyEnd:
    prefix.add(bytes[i])
  let expected = blake3.digest(prefix)
  for i in 0 ..< 32:
    if bytes[bodyEnd + i] != expected[i]:
      raiseIntentSnapshotCorrupt(filePath, "trailingChecksum",
        "BLAKE3-256 trailing checksum mismatch")
  result.schemaVersion = version
  let countRaw = readU32Le(bytes, pos)
  if not elementCountFits(countRaw, bodyEnd - pos, 12):
    raiseIntentSnapshotCorrupt(filePath, "files", "element count exceeds remaining body")
  let count = int(countRaw)
  result.files = newSeq[IntentFileEntry](count)
  for i in 0 ..< count:
    let pathLen = int(readU32Le(bytes, pos))
    if pos + pathLen > bodyEnd:
      raiseIntentSnapshotCorrupt(filePath,
        "files[" & $i & "].path", "truncated path")
    var path = newString(pathLen)
    for j in 0 ..< pathLen:
      path[j] = char(bytes[pos + j])
    pos += pathLen
    var role = ifrSource
    if version >= 2'u16:
      if pos >= bodyEnd:
        raiseIntentSnapshotCorrupt(filePath,
          "files[" & $i & "].role", "truncated role")
      let raw = int(bytes[pos])
      if raw > ord(high(IntentFileRole)):
        raiseIntentSnapshotCorrupt(filePath,
          "files[" & $i & "].role", "unknown role " & $raw)
      role = IntentFileRole(raw)
      inc pos
    let rawContentLength = readU64Le(bytes, pos)
    if pos > bodyEnd or rawContentLength > uint64(bodyEnd - pos):
      raiseIntentSnapshotCorrupt(filePath, "content", "declared content length overflows body")
    let contentLen = int(rawContentLength)
    if pos + contentLen > bodyEnd:
      raiseIntentSnapshotCorrupt(filePath,
        "files[" & $i & "].content", "truncated content")
    var content = newSeq[byte](contentLen)
    for j in 0 ..< contentLen:
      content[j] = bytes[pos + j]
    pos += contentLen
    result.files[i] = IntentFileEntry(path: path, content: content,
      role: role)
  if pos != bodyEnd:
    raiseIntentSnapshotCorrupt(filePath, "body",
      "trailing " & $(bodyEnd - pos) & " bytes after declared file list")

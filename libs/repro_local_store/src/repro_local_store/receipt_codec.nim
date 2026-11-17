## The prefix receipt (``.repro-receipt``) and its binary codec, split out
## of ``store.nim``.
##
## Same reason ``prefix_paths`` and ``realization_hash`` were split out: a
## caller that needs to know WHERE a realized prefix lives should not have to
## link the store runtime (SQLite, the shm index) to find out. Since the
## directory name was widened from 64 to 160 bits of the realization hash,
## answering that question for a prefix an older build wrote needs the
## prefix's receipt (``prefix_location``), and reading a receipt needs only
## this codec: ``blake3`` and ``repro_core``'s framing helpers.
##
## ``store.nim`` imports and re-exports this module, so every existing
## ``repro_local_store`` consumer keeps seeing the same symbols.

import std/[algorithm, os, tables]

import blake3
import repro_core/codec
from repro_core/paths import extendedPath

import ./prefix_paths

type
  StoreError* = object of CatchableError
    ## Base type for every error the store may raise to its callers.

  EReceiptMissing* = object of StoreError
  EReceiptCorrupt* = object of StoreError
  EReceiptMismatch* = object of StoreError
    ## The realization-hash recorded in a prefix's `.repro-receipt` does
    ## not match the prefix's directory name. Quarantined to
    ## `gc/pending-deletion/`.

  RealizationReceipt* = object
    ## The typed payload sealed into every realized prefix as
    ## `.repro-receipt`. The on-disk encoding is the canonical binary
    ## envelope below; the JSON form is for `repro store dump`.
    schemaVersion*: uint16
    adapter*: string
    packageName*: string
    version*: string
    realizationHash*: PrefixIdBytes
    realizedPath*: string
    declaredExecutablePath*: string
    exportedExecutables*: seq[string]
    lockIdentity*: string
    provenanceUrl*: string
    provenanceChecksum*: string
    declaredExecutableAlias*: string
      ## The second name realize copied the declared program under, if any.
      ##
      ## One of three v3 fields recording REALIZE INPUTS THAT CHANGE THE
      ## SEALED BYTES. A prefix is not a pure function of the archive it
      ## came from: before sealing, realize copies the declared program
      ## under ``executableAlias``, writes a launcher pair for
      ## ``launcher``, and deletes ``prunePaths``. Two packages over one
      ## archive that declare these differently hold DIFFERENT bytes.
      ##
      ## They are recorded so a reader can ask a prefix whether its tree is
      ## the one a fresh extraction of a given declaration would produce —
      ## a question the rest of the receipt cannot answer, and the one a
      ## sibling-prefix clone has to answer before it may link anything.
    declaredLauncher*: string
      ## The interpreter realize wrote a launcher pair for, if any. See
      ## ``declaredExecutableAlias``.
    declaredPrunePaths*: seq[string]
      ## The prefix-relative paths realize deleted after extraction. See
      ## ``declaredExecutableAlias``.
    materializationMechanism*: string  ## "hardlink" | "reflink" | "copy" |
                                       ## "directory" (debug hint only)
    createdAtUnix*: int64
    writerProcessId*: int64
    writerMode*: string                ## "direct" | "daemon"
    outputName*: string
    contentDigest*: string
      ## v4: the prefix's content as realised, ``tree-v2:<hex>``
      ## (``storeTreeDigest``: ``portable_fingerprint.treeDigestOf`` over
      ## ``treeEntries`` of the prefix, its receipt left out). "" in a v1-v3
      ## receipt or one a realiser wrote without it (an adopted prefix): such
      ## a prefix's content is unverifiable, never trusted for being there.
      ## Recipe-Val M8: which Nix-style package output this receipt
      ## belongs to. Empty string (the default) means "legacy
      ## single-output realize" and the on-disk encoding round-trips
      ## byte-identically to the pre-M8 receipt envelope. Multi-output
      ## realize sets this to ``"bin"`` / ``"man"`` / ``"doc"`` /
      ## ``"dev"`` (whatever the recipe declared).
    outputPrefixes*: Table[string, string]
      ## Recipe-Val M8 sibling-output index: empty for single-output
      ## receipts, populated only on the receipt sealed into the
      ## *first* output of a multi-output realize so a downstream
      ## consumer can discover the sibling prefixes (one per declared
      ## output) without re-walking the store index. Keys are
      ## logical output names (``"bin"``, ``"man"``, …); values are
      ## store-relative paths (forward-slashed).

const
  ReceiptFileName* = ".repro-receipt"
  ReceiptMagic* = "RPRC"                ## envelope magic
  ReceiptFormatVersion* = 4'u16
    ## v2: Recipe-Val M8 — appends ``outputName: string`` and a
    ## length-prefixed (name, relativePath) sibling-output map after
    ## the v1 ``writerMode`` field. v1 receipts decode with both
    ## fields empty, which matches the single-output legacy
    ## behavior byte-for-byte (the canonical encoding of an empty
    ## string + empty table appends 6 bytes, so v1 receipts written
    ## on disk before this upgrade remain readable without
    ## re-sealing).

# ---------------------------------------------------------------------------
# Receipt envelope (binary)
# ---------------------------------------------------------------------------

proc writePrefixId(buf: var seq[byte]; id: PrefixIdBytes) =
  for b in id: buf.add(b)

proc readPrefixId(buf: openArray[byte]; pos: var int): PrefixIdBytes =
  if pos + 32 > buf.len:
    raise newException(EReceiptCorrupt, "truncated prefix id")
  for i in 0 ..< 32:
    result[i] = buf[pos + i]
  pos += 32

proc encodeReceipt*(rec: RealizationReceipt): seq[byte] =
  ## Canonical binary envelope: 4-byte magic, u16 LE version, fields in
  ## a fixed order, followed by a trailing BLAKE3 checksum.
  var body: seq[byte] = @[]
  body.writeU16Le(rec.schemaVersion)
  body.writeString(rec.adapter)
  body.writeString(rec.packageName)
  body.writeString(rec.version)
  body.writePrefixId(rec.realizationHash)
  body.writeString(rec.realizedPath)
  body.writeString(rec.declaredExecutablePath)
  body.writeU32Le(uint32(rec.exportedExecutables.len))
  for exported in rec.exportedExecutables:
    body.writeString(exported)
  body.writeString(rec.lockIdentity)
  body.writeString(rec.provenanceUrl)
  body.writeString(rec.provenanceChecksum)
  body.writeString(rec.materializationMechanism)
  body.writeU64Le(uint64(rec.createdAtUnix))
  body.writeU64Le(uint64(rec.writerProcessId))
  body.writeString(rec.writerMode)
  # Recipe-Val M8 v2 trailing fields. Single-output realize leaves
  # ``outputName`` empty and ``outputPrefixes`` empty, so v1
  # receipts that round-trip through encode/decode pick up the
  # 4-byte zero count and the 4-byte empty-string length only —
  # the body grows by 8 bytes vs. v1, which the checksum and
  # ``payloadLen`` header rebuild correctly.
  body.writeString(rec.outputName)
  body.writeU32Le(uint32(rec.outputPrefixes.len))
  # Emit sibling-output entries in deterministic order: sort keys
  # so a multi-output realize always emits the same bytes regardless
  # of which output's receipt was sealed first.
  var siblingKeys: seq[string] = @[]
  for key in rec.outputPrefixes.keys:
    siblingKeys.add(key)
  siblingKeys.sort()
  for key in siblingKeys:
    body.writeString(key)
    body.writeString(rec.outputPrefixes[key])
  # v3 trailing fields: the realize inputs that CHANGE THE SEALED BYTES but
  # are not derivable from the archive. A prefix is not a pure function of
  # its download — realize also copies the declared program under
  # ``executableAlias``, writes a launcher pair for ``launcher``, and drops
  # ``prunePaths`` — so a reader that wants to know whether this tree is the
  # one a fresh extraction would produce has to be told. Without them a
  # sibling-prefix clone cannot be made safe: it would copy an alias the
  # cloning package never declared, and two machines would hold different
  # bytes under one prefix id.
  body.writeString(rec.declaredExecutableAlias)
  body.writeString(rec.declaredLauncher)
  body.writeU32Le(uint32(rec.declaredPrunePaths.len))
  for prunePath in rec.declaredPrunePaths:
    body.writeString(prunePath)
  # v4 trailing field: the content digest at realisation (see the field).
  body.writeString(rec.contentDigest)

  result.add(byte(ord(ReceiptMagic[0])))
  result.add(byte(ord(ReceiptMagic[1])))
  result.add(byte(ord(ReceiptMagic[2])))
  result.add(byte(ord(ReceiptMagic[3])))
  result.writeU16Le(ReceiptFormatVersion)
  result.writeU32Le(uint32(body.len))
  result.add(body)
  let checksum = blake3.digest(result)
  for b in checksum:
    result.add(b)

proc decodeReceipt*(buf: openArray[byte]): RealizationReceipt =
  if buf.len < 10 + 32:
    raise newException(EReceiptCorrupt, "receipt too short")
  for i in 0 ..< 4:
    if buf[i] != byte(ord(ReceiptMagic[i])):
      raise newException(EReceiptCorrupt, "unknown receipt magic")
  var pos = 4
  let version = readU16Le(buf, pos)
  if version notin {1'u16, 2'u16, 3'u16, ReceiptFormatVersion}:
    raise newException(EReceiptCorrupt,
      "unsupported receipt format version: " & $version)
  let bodyLen = int(readU32Le(buf, pos))
  if pos + bodyLen + 32 != buf.len:
    raise newException(EReceiptCorrupt,
      "receipt size mismatch (declared body " & $bodyLen & " bytes)")
  let bodyStart = pos
  let bodyEnd = bodyStart + bodyLen
  # Verify trailing BLAKE3 checksum over header + body.
  var prefixForChecksum: seq[byte] = @[]
  for i in 0 ..< bodyEnd:
    prefixForChecksum.add(buf[i])
  let expected = blake3.digest(prefixForChecksum)
  for i in 0 ..< 32:
    if buf[bodyEnd + i] != expected[i]:
      raise newException(EReceiptCorrupt, "receipt checksum mismatch")
  result.schemaVersion = readU16Le(buf, pos)
  result.adapter = readString(buf, pos)
  result.packageName = readString(buf, pos)
  result.version = readString(buf, pos)
  result.realizationHash = readPrefixId(buf, pos)
  result.realizedPath = readString(buf, pos)
  result.declaredExecutablePath = readString(buf, pos)
  let exportedCountRaw = readU32Le(buf, pos)
  if not elementCountFits(exportedCountRaw, bodyEnd - pos, 4):
    raise newException(EReceiptCorrupt, "element count exceeds remaining body")
  let exportedCount = int(exportedCountRaw)
  result.exportedExecutables = newSeq[string](exportedCount)
  for i in 0 ..< exportedCount:
    result.exportedExecutables[i] = readString(buf, pos)
  result.lockIdentity = readString(buf, pos)
  result.provenanceUrl = readString(buf, pos)
  result.provenanceChecksum = readString(buf, pos)
  result.materializationMechanism = readString(buf, pos)
  result.createdAtUnix = int64(readU64Le(buf, pos))
  result.writerProcessId = int64(readU64Le(buf, pos))
  result.writerMode = readString(buf, pos)
  result.outputPrefixes = initTable[string, string]()
  if version >= 2'u16:
    # Recipe-Val M8 v2 trailing fields. v1 receipts decode with
    # both fields empty (single-output legacy semantics).
    result.outputName = readString(buf, pos)
    let siblingCountRaw = readU32Le(buf, pos)
    if not elementCountFits(siblingCountRaw, bodyEnd - pos, 8):
      raise newException(EReceiptCorrupt, "element count exceeds remaining body")
    let siblingCount = int(siblingCountRaw)
    for i in 0 ..< siblingCount:
      let key = readString(buf, pos)
      let value = readString(buf, pos)
      result.outputPrefixes[key] = value
  if version >= 3'u16:
    # v1 and v2 receipts decode with all three empty. That is the SAFE
    # direction for the consumer these exist for: a clone keyed on them
    # refuses to match an older receipt rather than assuming it declared
    # nothing, because "empty" and "unknown" are the same bytes here.
    result.declaredExecutableAlias = readString(buf, pos)
    result.declaredLauncher = readString(buf, pos)
    let pruneCountRaw = readU32Le(buf, pos)
    if not elementCountFits(pruneCountRaw, bodyEnd - pos, 4):
      raise newException(EReceiptCorrupt, "element count exceeds remaining body")
    let pruneCount = int(pruneCountRaw)
    result.declaredPrunePaths = newSeq[string](pruneCount)
    for i in 0 ..< pruneCount:
      result.declaredPrunePaths[i] = readString(buf, pos)
  if version >= 4'u16:
    result.contentDigest = readString(buf, pos)
  if pos != bodyEnd:
    raise newException(EReceiptCorrupt, "trailing receipt bytes")

proc receiptDigest*(rec: RealizationReceipt): PrefixIdBytes =
  ## BLAKE3-256 of the canonical encoded receipt.
  blake3.digest(encodeReceipt(rec))

proc readReceiptFile*(path: string): RealizationReceipt =
  if not fileExists(extendedPath(path)):
    raise newException(EReceiptMissing, "no receipt at " & path)
  let raw = readFile(extendedPath(path))
  var buf = newSeq[byte](raw.len)
  for i, ch in raw:
    buf[i] = byte(ord(ch))
  decodeReceipt(buf)

proc writeReceiptFile*(path: string; rec: RealizationReceipt) =
  let bytes = encodeReceipt(rec)
  var text = newString(bytes.len)
  for i, b in bytes:
    text[i] = char(b)
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), text)

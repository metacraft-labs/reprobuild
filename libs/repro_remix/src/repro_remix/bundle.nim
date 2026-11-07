## Detached export bundles (spec §"Export bundle").
##
## A bundle is one file: an RBSZ-framed index record (`rkBundleIndex`)
## followed by a data region holding every entry's bytes back to back. The
## index lists each entry's kind, digest, offset and length. Nothing in a
## bundle is ever extracted to a path, so path traversal is not
## expressible; every entry is addressed by digest only.
##
## Canonical form, so that one set of contents has one bundle: entries are
## strictly ascending by `(kind, digest)`, and their byte ranges tile the
## data region in index order from offset 0 with no gap or overlap. The
## reader refuses anything else.
##
## Completeness: every blob a bundled manifest references must be in the
## bundle with the declared size, and every manifest must verify. A bundle
## is the offline path of Invariant I-10, so a partial one is refused
## rather than half-trusted.

import ssz_serialization

import ./types
import ./identity
import ./codec
import ./verify

const
  MaxBundleEntries* = 65536
  MaxBundleEnvelopeBytes = MaxBodyBytes + 64 * 1024
    ## Bound on one bundled envelope (manifest, statement, key-log entry).

type
  BundleEntryKind* = enum
    bekManifestEnvelope = 1
    bekBlob = 2
    bekStatementEnvelope = 3
      ## Reserved for M3 statements; carried and digest-checked only.
    bekKeyLogEnvelope = 4
      ## Reserved for M3 key logs; carried and digest-checked only.
    bekTransparencyProof = 5
      ## Reserved for M3 inclusion proofs; carried and digest-checked only.

  BundleEntryW = object
    kind: uint8
    digest: Digest32
    offset: uint64
    length: uint64

  BundleIndexW = object
    entries: List[BundleEntryW, MaxBundleEntries]

  BundleEntry* = object
    kind*: BundleEntryKind
    digest*: Digest32
      ## BLAKE3-256 of the entry bytes (for a blob, its CAS id).
    bytes*: seq[byte]

  Bundle* = object
    entries*: seq[BundleEntry]
    manifests*: seq[VerifiedManifest]
      ## Every bundled manifest, verified, in index order.

proc entryKey(kind: BundleEntryKind; digest: Digest32): seq[byte] =
  result = @[byte(ord(kind))]
  result.add digest

proc cmpKey(a, b: seq[byte]): int =
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]:
      return (if a[i] < b[i]: -1 else: 1)
  cmp(a.len, b.len)

proc maxEntryBytes(kind: BundleEntryKind): uint64 =
  case kind
  of bekBlob: MaxBlobBytes
  else: uint64(MaxBundleEnvelopeBytes)

proc writeBundle*(entries: openArray[(BundleEntryKind, seq[byte])]): seq[byte] =
  ## Build a canonical bundle. Entries may be given in any order; digests
  ## are computed here, and an exact duplicate is stored once.
  var items: seq[BundleEntry]
  for (kind, bytes) in entries:
    if uint64(bytes.len) > maxEntryBytes(kind):
      refuse(rrBound, "bundle entry of " & $bytes.len & " bytes")
    let e = BundleEntry(kind: kind, digest: blobId(bytes), bytes: bytes)
    var dup = false
    for x in items:
      if x.kind == e.kind and x.digest == e.digest:
        dup = true
    if not dup:
      items.add e
  if items.len > MaxBundleEntries:
    refuse(rrBound, "bundle has " & $items.len & " entries")
  # Insertion sort keeps this dependency-free; bundles are not hot paths.
  for i in 1 ..< items.len:
    var j = i
    while j > 0 and cmpKey(entryKey(items[j - 1].kind, items[j - 1].digest),
                           entryKey(items[j].kind, items[j].digest)) > 0:
      swap(items[j - 1], items[j])
      dec j
  var index: seq[BundleEntryW]
  var offset = 0'u64
  for e in items:
    index.add BundleEntryW(kind: uint8(ord(e.kind)), digest: e.digest,
                           offset: offset, length: uint64(e.bytes.len))
    offset += uint64(e.bytes.len)
  let body = SSZ.encode(BundleIndexW(
    entries: List[BundleEntryW, MaxBundleEntries].init(index)))
  result = encodeEnvelope(Envelope(schemaVersion: RemixSchemaVersion,
    requiredFeatures: 0, recordKind: rkBundleIndex, body: body))
  for e in items:
    result.add e.bytes

proc readBundle*(bytes: openArray[byte]): Bundle =
  ## Parse, digest-check, and verify a bundle. Refuses on any defect.
  if bytes.len < 12:
    refuse(rrTruncated, "shorter than the RBSZ frame header")
  var frameLen = 0'u64
  for i in 0 ..< 4:
    frameLen = frameLen or (uint64(bytes[8 + i]) shl (8 * i))
  if frameLen > uint64(bytes.len - 12):
    refuse(rrTruncated, "index frame runs past the end of the bundle")
  let indexEnd = 12 + int(frameLen)
  let env = decodeEnvelope(bytes.toOpenArray(0, indexEnd - 1))
  if env.recordKind != rkBundleIndex:
    refuse(rrUnknownRecordKind, "bundle does not start with an index record")
  if env.signatures.len != 0:
    refuse(rrForbiddenContent, "a bundle index carries no signatures")
  var index: BundleIndexW
  try:
    index = SSZ.decode(env.body, BundleIndexW)
  except SerializationError as e:
    refuse(rrMalformed, "bundle index: " & e.msg)
  if SSZ.encode(index) != env.body:
    refuse(rrNonCanonical, "bundle index does not re-encode to the same bytes")

  let dataLen = uint64(bytes.len - indexEnd)
  var expectOffset = 0'u64
  var prevKey: seq[byte]
  for i, w in asSeq(index.entries):
    var kind: BundleEntryKind
    if w.kind < uint8(ord(BundleEntryKind.low)) or
       w.kind > uint8(ord(BundleEntryKind.high)):
      refuse(rrUnknownVocabulary, "bundle entry kind " & $w.kind)
    kind = BundleEntryKind(w.kind)
    let key = entryKey(kind, w.digest)
    if i > 0:
      let c = cmpKey(prevKey, key)
      if c == 0: refuse(rrDuplicate, "bundle entry " & $i & " repeats its predecessor")
      if c > 0: refuse(rrUnsorted, "bundle entry " & $i & " is out of canonical order")
    prevKey = key
    if w.offset != expectOffset:
      refuse(rrNonCanonical, "bundle entry " & $i & " leaves a gap or overlaps")
    if w.length > maxEntryBytes(kind):
      refuse(rrBound, "bundle entry " & $i & " declares " & $w.length & " bytes")
    if w.length > dataLen - w.offset:
      refuse(rrTruncated, "bundle entry " & $i & " runs past the end of the data")
    let start = indexEnd + int(w.offset)
    let data = @(bytes.toOpenArray(start, start + int(w.length) - 1))
    if blobId(data) != w.digest:
      refuse(rrDigestMismatch, "bundle entry " & $i & " does not match its digest")
    result.entries.add BundleEntry(kind: kind, digest: w.digest, bytes: data)
    expectOffset = w.offset + w.length
  if expectOffset != dataLen:
    refuse(rrLengthMismatch, "bundle data region has bytes no entry covers")

  # Verify manifests and their blob closure.
  for e in result.entries:
    if e.kind == bekManifestEnvelope:
      result.manifests.add decodeAndVerify(e.bytes)
  for v in result.manifests:
    var refs: seq[BlobRef]
    for p in v.manifest.patches: refs.add p.blob
    for c in v.manifest.configuration: refs.add c.value
    refs.add v.manifest.graphFragments
    refs.add v.manifest.assets
    for r in refs:
      var found = false
      for e in result.entries:
        if e.kind == bekBlob and e.digest == r.id:
          if uint64(e.bytes.len) != r.size:
            refuse(rrSizeMismatch, "bundled blob size differs from the manifest's BlobRef")
          found = true
          break
      if not found:
        refuse(rrMissingBlob, "manifest " & $v.id & " references a blob the bundle lacks")

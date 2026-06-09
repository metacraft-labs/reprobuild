## The `RBPI` ("Reprobuild Profile Intent") binary envelope (M83
## Phase B). Mirrors the M69 `RBIP` plan envelope and the M69 `RBSL`
## audit-log record so the three on-disk artefact families share a
## single magic+version+bodyLen+body+checksum framing.
##
## On-disk shape (little-endian throughout):
##
##   offset 0   : magic            4 bytes ASCII "RBPI"
##   offset 4   : schemaVersion    u16 LE
##   offset 6   : bodyLength       u32 LE
##   offset 10  : body             bodyLength bytes (CBOR — see codec.nim)
##   trailing   : checksum         32 bytes BLAKE3-256
##                                 over magic + version + bodyLen + body
##
## Total envelope size = 10 + bodyLen + 32 bytes.
##
## The reader is STRICT: bad magic, unsupported version, declared body
## length that disagrees with the file size, and trailing-checksum
## mismatch all raise `ERbpiCorrupt` with the offending FIELD tagged.

import blake3
import repro_core

import ./errors

const
  RbpiMagic*         = "RBPI"           ## 4-byte ASCII envelope magic.
  RbpiSchemaVersion* = 2'u16            ## Current envelope schema version.
    ##
    ## Version history:
    ##   1 (M83 Phase B): initial envelope; ActivityElement carries
    ##     pkgName only on the CBOR side (pkgVersion was dropped at the
    ##     RBPI boundary in early M83 — a latent bug). configOverrides,
    ##     hosts, resources, adapterPreference all present.
    ##   2 (2026-06-09): ActivityElement.aekPackageRef CBOR map gains
    ##     two OPTIONAL fields:
    ##       "version"  -- the literal version pin (fixes the M83
    ##                     drop); present only when non-empty.
    ##       "binaries" -- the explicit binary names a package installs,
    ##                     used by path-based catalog adapters when the
    ##                     package name doesn't match the binary name
    ##                     (e.g. `ripgrep` -> `rg`); present only when
    ##                     non-empty.
    ##     The version bump matters for the on-disk cache: profile
    ##     compile artifacts at `<state-dir>/profile-cache/<digest>.rbpi`
    ##     mix the schema version into the digest input (see
    ##     `computeProfileDigest`), so a v1 cache entry's digest never
    ##     collides with a v2 entry for the same source set; v1 files
    ##     are also rejected by the strict reader at read time
    ##     (`unsupported RBPI schema version`), which the cache validity
    ##     check (`cachedArtifactIsValid`) catches as "miss → recompile".
    ## When you change the on-the-wire CBOR shape of ANY field that
    ## affects how a downstream consumer would interpret the envelope,
    ## bump this constant AND document the change here.
  RbpiHeaderSize*    = 4 + 2 + 4        ## magic + version + bodyLen.
  RbpiTrailerSize*   = 32               ## BLAKE3-256 trailing checksum.

# ---------------------------------------------------------------------------
# Header helpers.
# ---------------------------------------------------------------------------

proc encodeRbpiHeader*(bodyLen: uint32): seq[byte] =
  ## Build the 10-byte fixed header: magic + schemaVersion + bodyLen.
  ## The trailing BLAKE3 checksum is written by `wrapEnvelope`.
  result = newSeqOfCap[byte](RbpiHeaderSize)
  for ch in RbpiMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(RbpiSchemaVersion)
  result.writeU32Le(bodyLen)

proc readRbpiHeader*(bytes: openArray[byte]):
    tuple[version: uint16, bodyLen: uint32] =
  ## Parse the 10-byte fixed header. Raises `ERbpiCorrupt` for a bad
  ## magic, an unsupported version, or a truncated input. Does NOT
  ## validate the trailing checksum — `readEnvelope` does that.
  if bytes.len < RbpiHeaderSize:
    raiseRbpiCorrupt("envelope",
      "input is " & $bytes.len & " bytes; need at least " &
      $RbpiHeaderSize & " for the header")
  for i in 0 ..< 4:
    if bytes[i] != byte(ord(RbpiMagic[i])):
      raiseRbpiCorrupt("magic",
        "expected ASCII '" & RbpiMagic & "' at offset 0")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != RbpiSchemaVersion:
    raiseRbpiCorrupt("schemaVersion",
      "unsupported RBPI schema version " & $version &
      " (this build understands " & $RbpiSchemaVersion & ")")
  let bodyLen = readU32Le(bytes, pos)
  (version: version, bodyLen: bodyLen)

# ---------------------------------------------------------------------------
# Envelope wrap / unwrap.
# ---------------------------------------------------------------------------

proc wrapEnvelope*(body: openArray[byte]): seq[byte] =
  ## Returns magic + version + bodyLen + body + BLAKE3-256(magic +
  ## version + bodyLen + body). Deterministic for a fixed body.
  result = newSeqOfCap[byte](RbpiHeaderSize + body.len + RbpiTrailerSize)
  for ch in RbpiMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(RbpiSchemaVersion)
  result.writeU32Le(uint32(body.len))
  for b in body:
    result.add(b)
  let checksum = blake3.digest(result)
  for b in checksum:
    result.add(b)

proc readEnvelope*(bytes: openArray[byte]): seq[byte] =
  ## Validate the magic, version, body-length bounds, and trailing
  ## BLAKE3 checksum BEFORE returning the body bytes. Raises
  ## `ERbpiCorrupt` on any structural failure, with the offending
  ## field tagged ("magic", "schemaVersion", "bodyLength", "checksum",
  ## or "envelope" for an outright-too-short input).
  if bytes.len < RbpiHeaderSize + RbpiTrailerSize:
    raiseRbpiCorrupt("envelope",
      "input is " & $bytes.len & " bytes; need at least " &
      $(RbpiHeaderSize + RbpiTrailerSize) & " for an empty-body envelope")
  # Header validation also catches bad magic / unsupported version.
  let (_, bodyLenU32) = readRbpiHeader(bytes)
  let bodyLen = int(bodyLenU32)
  let bodyEnd = RbpiHeaderSize + bodyLen
  if bodyEnd + RbpiTrailerSize != bytes.len:
    raiseRbpiCorrupt("bodyLength",
      "declared body length " & $bodyLen &
      " disagrees with input size " & $bytes.len &
      " (expected total " & $(bodyEnd + RbpiTrailerSize) & ")")
  var prefix = newSeqOfCap[byte](bodyEnd)
  for i in 0 ..< bodyEnd:
    prefix.add(bytes[i])
  let expected = blake3.digest(prefix)
  for i in 0 ..< 32:
    if bytes[bodyEnd + i] != expected[i]:
      raiseRbpiCorrupt("checksum",
        "BLAKE3-256 trailing checksum mismatch")
  result = newSeqOfCap[byte](bodyLen)
  for i in 0 ..< bodyLen:
    result.add(bytes[RbpiHeaderSize + i])

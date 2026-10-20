## Domain-separated BLAKE3 identities (spec §"Identities").
##
## Every protocol identity is `BLAKE3-256(u32le(len(context)) ‖ context ‖
## input)`. Prefixing the context with its length makes the boundary
## between context and input unambiguous, so no input can be chosen to
## make two identity kinds collide. The context strings are normative and
## versioned with the identity they name.

import blake3

import ./types

const
  ReleaseContext* = "reproos.remix.release.v1"
  KeyContext* = "reproos.remix.key.v1"
  SignatureContext* = "reproos.remix.signature.v1"
  CompositionContext* = "reproos.remix.composition.v1"
  VariantContext* = "reproos.remix.variant.v1"
  StatementContext* = "reproos.remix.statement.v1"
  InstallLockContext* = "reproos.remix.install-lock.v1"

proc toDigest32(d: Blake3Digest): Digest32 =
  for i in 0 ..< 32:
    result[i] = d[i]

proc putU32Le(h: Blake3Hasher; value: uint32) =
  var b: array[4, byte]
  for i in 0 ..< 4:
    b[i] = byte((value shr (8 * i)) and 0xff)
  h.update(b)

proc putU16Le(h: Blake3Hasher; value: uint16) =
  h.update([byte(value and 0xff), byte(value shr 8)])

proc domainDigest*(context: string; parts: varargs[seq[byte]]): Digest32 =
  ## The one identity primitive. `parts` are concatenated after the
  ## framed context; callers pass fixed-width or self-delimiting parts only.
  let h = initHasher()
  try:
    h.putU32Le(uint32(context.len))
    h.update(context)
    for p in parts:
      h.update(p)
    result = toDigest32(h.finalize())
  finally:
    h.close()

proc recordIdentity*(context: string; schemaVersion: uint16;
                     requiredFeatures: uint32; recordKind: RecordKind;
                     body: openArray[byte]): Digest32 =
  ## Identity of a record: its header fields and canonical body bytes, but
  ## not its signatures (spec §"Envelope"). Covering the header means that
  ## setting a required-feature bit yields a different identity rather
  ## than a different meaning for the same one.
  let h = initHasher()
  try:
    h.putU32Le(uint32(context.len))
    h.update(context)
    h.putU16Le(schemaVersion)
    h.putU32Le(requiredFeatures)
    h.update([byte(ord(recordKind))])
    h.update(body)
    result = toDigest32(h.finalize())
  finally:
    h.close()

proc releaseId*(env: Envelope): ReleaseId =
  ## `ReleaseId` of a manifest envelope (Invariant I-1).
  if env.recordKind != rkManifest:
    refuse(rrUnknownRecordKind, "releaseId of a non-manifest record")
  ReleaseId(recordIdentity(ReleaseContext, env.schemaVersion,
                           env.requiredFeatures, env.recordKind, env.body))

proc keyId*(algorithm: SignatureAlgorithm; publicKey: openArray[byte]): KeyId =
  ## `KeyId = BLAKE3(ctx, algorithm tag ‖ canonical public-key bytes)`.
  KeyId(domainDigest(KeyContext, @[byte(ord(algorithm))], @publicKey))

proc signingMessage*(identity: Digest32): seq[byte] =
  ## What a signature covers: the record identity under its own context,
  ## so a signature over a release can never be replayed as a signature
  ## over any other record kind or protocol.
  @(domainDigest(SignatureContext, @identity))

proc blobId*(bytes: openArray[byte]): Digest32 =
  ## CAS identity of a blob: plain BLAKE3-256 of its bytes, the same
  ## digest `Local-Content-Addressed-Store.md` names objects by. Not
  ## domain-separated, deliberately: a blob id must equal the CAS key.
  toDigest32(blake3.digest(bytes))

proc toHex*(d: Digest32): string =
  const hexChars = "0123456789abcdef"
  result = newString(64)
  for i, b in d:
    result[2 * i] = hexChars[int(b shr 4)]
    result[2 * i + 1] = hexChars[int(b and 0x0f)]

proc `$`*(id: ReleaseId): string = "blake3:" & toHex(Digest32(id))
proc `$`*(id: KeyId): string = "blake3:" & toHex(Digest32(id))

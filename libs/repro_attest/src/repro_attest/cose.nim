## COSE signature verification — RFC 9052 (structures) over RFC 9053
## (the ECDSA algorithm and curve identifiers), on top of `libs/cbor`.
##
## ## What is here
##
## `COSE_Sign1` (CBOR tag 18) and `COSE_Sign` (tag 98) VERIFICATION with
## ES256, ES384 and ES512 — ECDSA over P-256, P-384 and P-521 with
## SHA-256, SHA-384 and SHA-512 — against `COSE_Key` EC2 public keys.
## The Sig_structure of RFC 9052 §4.4 is built here, the protected
## buckets are used as the bytes they arrived as, and the elliptic-curve
## arithmetic is BearSSL's.
##
## ## What is NOT here, stated rather than implied
##
## No signing. No `COSE_Encrypt`, `COSE_Encrypt0`, `COSE_Mac` or
## `COSE_Mac0`, and no recipient structures, key wrap or ECDH — RFC 9052
## publishes those examples WITHOUT the symmetric key material, so an
## offline gate has nothing to check them against. No EdDSA, no
## RSA-PSS, no HMAC, no counter
## signatures, no `COSE_Key` private keys, no OKP key type, no point
## compression, no `content type` or `Base IV` handling.
##
## ## Fail-closed, by construction rather than by discipline
##
## `verifyCoseSign1` and `verifyCoseSign` return the payload, and the
## ONLY way out of them other than a verified payload is a raised
## `CoseError`. There is no boolean, no "verified: false" field and no
## partially-populated result, because a caller that reads a field to
## find out whether verification happened is a caller that can forget
## to. In particular, a CBOR parse failure is re-raised as
## `cxeMalformedCbor` and never becomes "no header parameters were
## found, so none of them were violated".
##
## Every refusal carries a distinct `CoseErrorKind`, and
## `CoseErrorMessage` satisfies `messagesAreDistinguishable`: no message
## is a substring of another, so a test matching on a fragment of one
## refusal cannot be satisfied by a different refusal.
##
## ## Deliberate tightenings of a SHOULD
##
## Two, both named here because a reader should not have to find them in
## the code:
##
##   * RFC 9053 §2.1 *suggests* SHA-256 with P-256, SHA-384 with P-384
##     and SHA-512 with P-521. This module REQUIRES it
##     (`cxeKeyCurveAlgorithmMismatch`).
##   * RFC 9052 §3 says applications SHOULD verify that a label does not
##     occur in both buckets. This module refuses when one does
##     (`cxeDuplicateLabelAcrossBuckets`).
##
## And one restriction that is this module's own, not the RFC's: a
## message must carry a `kid`, and it must name a key in the supplied
## set (`cxeNoKeyIdentifier`, `cxeKeyNotFound`). RFC 9052 allows a key
## to be identified by other means; nothing here needs that yet, and
## "try every key I was given" is not a behaviour to acquire by default.

import cbor

import bearssl/abi/bearssl_ec as bsslEcAbi
import bearssl/abi/bearssl_hash as bsslHashAbi

# ---------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------

type
  CoseErrorKind* = enum
    cxeMalformedCbor
    cxeNotTagged
    cxeWrongTag
    cxeNotArray
    cxeWrongArity
    cxeProtectedNotBytes
    cxeProtectedNotMap
    cxeUnprotectedNotMap
    cxeDuplicateLabelAcrossBuckets
    cxeNoAlgorithm
    cxeAlgorithmNotInteger
    cxeUnsupportedAlgorithm
    cxeCritNotProtected
    cxeCritNotArray
    cxeCritEmpty
    cxeCritLabelNotInProtectedBucket
    cxeCritLabelNotUnderstood
    cxePayloadNotBytes
    cxeDetachedPayloadMissing
    cxeDetachedPayloadUnexpected
    cxeSignatureNotBytes
    cxeSignatureWrongLength
    cxeSignaturesNotArray
    cxeNoSignatures
    cxeSignatureDidNotVerify
    cxeKeySetNotArray
    cxeKeyNotMap
    cxeKeyNotEc2
    cxeKeyCurveMissing
    cxeKeyCurveUnsupported
    cxeKeyCoordinateMissing
    cxeKeyCoordinateWrongLength
    cxeKeyCurveAlgorithmMismatch
    cxeKeyAlgorithmRestricted
    cxeNoKeyIdentifier
    cxeKeyIdentifierNotBytes
    cxeKeyNotFound

  CoseError* = object of CatchableError
    ## `site` is the file and line of the rule that refused; see the
    ## same field on `CborError` for why it is here.
    kind*: CoseErrorKind
    site*: tuple[filename: string, line: int, column: int]

const
  CoseErrorMessage*: array[CoseErrorKind, string] = [
    cxeMalformedCbor:
      "the message is not well-formed CBOR",
    cxeNotTagged:
      "the message carries no CBOR tag and an untagged one was not asked for",
    cxeWrongTag:
      "the message carries a CBOR tag other than the one this structure uses",
    cxeNotArray:
      "a COSE structure must be a CBOR array",
    cxeWrongArity:
      "the COSE array has the wrong number of elements",
    cxeProtectedNotBytes:
      "the protected bucket is not a byte string",
    cxeProtectedNotMap:
      "the protected bucket does not hold a CBOR map",
    cxeUnprotectedNotMap:
      "the unprotected bucket is not a CBOR map",
    cxeDuplicateLabelAcrossBuckets:
      "one label appears in the protected and the unprotected bucket at once",
    cxeNoAlgorithm:
      "no alg header parameter was found in either bucket",
    cxeAlgorithmNotInteger:
      "the alg header parameter is not an integer label",
    cxeUnsupportedAlgorithm:
      "the alg header parameter names an algorithm this build cannot verify",
    cxeCritNotProtected:
      "crit was found outside the protected bucket",
    cxeCritNotArray:
      "crit is not a CBOR array",
    cxeCritEmpty:
      "crit is present and holds no labels",
    cxeCritLabelNotInProtectedBucket:
      "crit names a label that the protected bucket does not carry",
    cxeCritLabelNotUnderstood:
      "crit names a label the caller did not declare that it understands",
    cxePayloadNotBytes:
      "the payload is neither a byte string nor nil",
    cxeDetachedPayloadMissing:
      "the payload is detached and no detached payload was supplied",
    cxeDetachedPayloadUnexpected:
      "a detached payload was supplied for a message that carries its own",
    cxeSignatureNotBytes:
      "the signature field is not a byte string",
    cxeSignatureWrongLength:
      "the signature length does not match two coordinates of the key curve",
    cxeSignaturesNotArray:
      "the signatures field is not a CBOR array",
    cxeNoSignatures:
      "the signatures array is empty",
    cxeSignatureDidNotVerify:
      "the elliptic-curve signature does not verify over the Sig_structure",
    cxeKeySetNotArray:
      "a COSE key set must be a CBOR array",
    cxeKeyNotMap:
      "a COSE key must be a CBOR map",
    cxeKeyNotEc2:
      "the key type is not EC2",
    cxeKeyCurveMissing:
      "the key carries no crv parameter",
    cxeKeyCurveUnsupported:
      "the key names a curve this build does not implement",
    cxeKeyCoordinateMissing:
      "the key is missing its x or its y coordinate",
    cxeKeyCoordinateWrongLength:
      "a key coordinate is not the width its curve requires",
    cxeKeyCurveAlgorithmMismatch:
      "the key curve is not the one the signature algorithm pairs with",
    cxeKeyAlgorithmRestricted:
      "the key restricts itself to a different algorithm",
    cxeNoKeyIdentifier:
      "the message carries no kid and this verifier requires one",
    cxeKeyIdentifierNotBytes:
      "the kid header parameter is not a byte string",
    cxeKeyNotFound:
      "no supplied key carries the kid the message names"]

proc hexOf(bytes: openArray[byte]): string =
  const Digits = "0123456789abcdef"
  for b in bytes:
    result.add Digits[int(b shr 4)]
    result.add Digits[int(b and 0x0f'u8)]

proc coseFailAt*(kind: CoseErrorKind; detail: string;
                 site: tuple[filename: string, line: int, column: int])
                {.noreturn.} =
  var e = newException(CoseError, CoseErrorMessage[kind])
  if detail.len > 0:
    e.msg = e.msg & ": " & detail
  e.kind = kind
  e.site = site
  raise e

template coseFail*(kind: CoseErrorKind; detail: string = "") =
  ## A template, so `instantiationInfo()` names the rule's own line.
  coseFailAt(kind, detail, instantiationInfo())

# ---------------------------------------------------------------------
# Algorithm and curve identifiers (RFC 9053 Tables 1, 17 and 18)
# ---------------------------------------------------------------------

type
  CoseCurve* = enum
    ccP256
    ccP384
    ccP521

  CoseAlgorithm* = enum
    caEs256
    caEs384
    caEs512

const
  CoseKeyTypeEc2* = 2'i64          ## RFC 9053 Table 17
  CoseCurveLabel*: array[CoseCurve, int64] = [1'i64, 2'i64, 3'i64]
  CoseCurveName*: array[CoseCurve, string] = ["P-256", "P-384", "P-521"]
  CoseCurveCoordinateLen*: array[CoseCurve, int] = [32, 48, 66]
    ## ceiling(key_length / 8), the width RFC 9053 §2.1 gives for each
    ## half of `I2OSP(R, n) | I2OSP(S, n)`.

  CoseAlgorithmLabel*: array[CoseAlgorithm, int64] =
    [-7'i64, -35'i64, -36'i64]     ## RFC 9053 Table 1
  CoseAlgorithmName*: array[CoseAlgorithm, string] =
    ["ES256", "ES384", "ES512"]
  CoseAlgorithmCurve*: array[CoseAlgorithm, CoseCurve] =
    [ccP256, ccP384, ccP521]

  # COSE header parameter labels, RFC 9052 Table 3.
  LabelAlg* = 1'i64
  LabelCrit* = 2'i64
  LabelKid* = 4'i64

  # COSE key parameter labels: RFC 9052 Table 4 for the common ones and
  # RFC 9053 §7.1.1 for the EC2 ones.
  KeyLabelKty* = 1'i64
  KeyLabelKid* = 2'i64
  KeyLabelAlg* = 3'i64
  KeyLabelCrv* = -1'i64
  KeyLabelX* = -2'i64
  KeyLabelY* = -3'i64

  CoseSign1Tag* = 18'u64           ## RFC 9052 §4.2
  CoseSignTag* = 98'u64            ## RFC 9052 §4.1

  ContextSignature1* = "Signature1"   ## RFC 9052 §4.4
  ContextSignature* = "Signature"

proc algorithmForLabel(label: int64): CoseAlgorithm =
  for a in CoseAlgorithm:
    if CoseAlgorithmLabel[a] == label:
      return a
  coseFail(cxeUnsupportedAlgorithm, "alg " & $label)

proc curveForLabel(label: int64): CoseCurve =
  for c in CoseCurve:
    if CoseCurveLabel[c] == label:
      return c
  coseFail(cxeKeyCurveUnsupported, "crv " & $label)

# ---------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------

type
  CoseKey* = object
    kid*: seq[byte]
    curve*: CoseCurve
    point*: seq[byte]
      ## The uncompressed SEC 1 encoding, 0x04 ‖ X ‖ Y, which is what
      ## BearSSL's `EcPublicKey` wants.
    hasAlgorithm*: bool
    algorithm*: CoseAlgorithm

proc intLabel(item: CborItem): int64 =
  if not fitsInt64(item):
    coseFail(cxeAlgorithmNotInteger, "label is not a 64-bit integer")
  asInt64(item)

proc parseCoseKey*(item: CborItem): CoseKey =
  ## One `COSE_Key` map holding an EC2 public key.
  if item.isNil or item.kind != ckMap:
    coseFail(cxeKeyNotMap)
  let kty = item.lookupInt(KeyLabelKty)
  if kty.isNil or not fitsInt64(kty) or asInt64(kty) != CoseKeyTypeEc2:
    coseFail(cxeKeyNotEc2,
      if kty.isNil: "no kty" else: "kty " & $kty.kind)
  let crv = item.lookupInt(KeyLabelCrv)
  if crv.isNil:
    coseFail(cxeKeyCurveMissing)
  if not fitsInt64(crv):
    coseFail(cxeKeyCurveUnsupported, "crv is not an integer label")
  result.curve = curveForLabel(asInt64(crv))
  let x = item.lookupInt(KeyLabelX)
  let y = item.lookupInt(KeyLabelY)
  if x.isNil or x.kind != ckBytes or y.isNil or y.kind != ckBytes:
    coseFail(cxeKeyCoordinateMissing)
  let n = CoseCurveCoordinateLen[result.curve]
  if x.bytes.len != n or y.bytes.len != n:
    coseFail(cxeKeyCoordinateWrongLength,
      CoseCurveName[result.curve] & " wants " & $n & ", got x=" &
        $x.bytes.len & " y=" & $y.bytes.len)
  result.point = @[0x04'u8]
  for b in x.bytes: result.point.add b
  for b in y.bytes: result.point.add b
  let kid = item.lookupInt(KeyLabelKid)
  if not kid.isNil:
    if kid.kind != ckBytes:
      coseFail(cxeKeyIdentifierNotBytes, "in a COSE key")
    result.kid = kid.bytes
  let alg = item.lookupInt(KeyLabelAlg)
  if not alg.isNil:
    result.hasAlgorithm = true
    result.algorithm = algorithmForLabel(intLabel(alg))

proc parseCoseKeySet*(item: CborItem):
    tuple[keys: seq[CoseKey], skipped: int] =
  ## RFC 9052 §7: "If one element in a COSE Key Set is either malformed
  ## or uses a key that is not understood by an application, that key is
  ## ignored, and the other keys are processed normally."
  ##
  ## The count of ignored elements is RETURNED rather than swallowed. A
  ## caller that wants the RFC's leniency gets it; a gate that wants a
  ## corpus which cannot shrink silently asserts the count is zero.
  if item.isNil or item.kind != ckArray:
    coseFail(cxeKeySetNotArray)
  for e in item.elems:
    try:
      result.keys.add parseCoseKey(e)
    except CoseError:
      inc result.skipped

# ---------------------------------------------------------------------
# Header buckets
# ---------------------------------------------------------------------

type
  CoseHeaders* = object
    protectedBytes*: seq[byte]
      ## The bucket EXACTLY as it arrived. This, not a re-encoding of
      ## the parsed map, is what goes into the Sig_structure — a
      ## re-encoding that differed in one byte would invalidate a
      ## signature that is in fact good, and, worse, an encoder that
      ## normalised the bucket would make two different protected
      ## headers produce one signed input.
    protected*: CborItem   ## always a map; empty when the bstr was empty
    unprotected*: CborItem ## always a map

proc decodeOrRefuse(bytes: openArray[byte];
                    opts = DefaultCborOptions): CborItem =
  try:
    decodeItem(bytes, opts)
  except CborError as e:
    coseFail(cxeMalformedCbor, e.msg)

proc parseHeaders(protectedItem, unprotectedItem: CborItem): CoseHeaders =
  if protectedItem.isNil or protectedItem.kind != ckBytes:
    coseFail(cxeProtectedNotBytes)
  result.protectedBytes = protectedItem.bytes
  if result.protectedBytes.len == 0:
    result.protected = cMap([])
  else:
    let inner = decodeOrRefuse(result.protectedBytes)
    if inner.kind != ckMap:
      coseFail(cxeProtectedNotMap, $inner.kind)
    result.protected = inner
  if unprotectedItem.isNil or unprotectedItem.kind != ckMap:
    coseFail(cxeUnprotectedNotMap)
  result.unprotected = unprotectedItem
  for p in result.protected.entries:
    for u in result.unprotected.entries:
      if equalValue(p.key, u.key):
        coseFail(cxeDuplicateLabelAcrossBuckets,
          "label appears twice")

proc protectedOnly(h: CoseHeaders; label: int64): CborItem =
  h.protected.lookupInt(label)

proc anyBucket(h: CoseHeaders; label: int64): CborItem =
  ## RFC 9052 §3: "attributes MUST be obtained from the protected
  ## bucket, and only if an attribute is not found in the protected
  ## bucket can that attribute be obtained from the unprotected bucket."
  ##
  ## Worth knowing, because it is not obvious and no test can show it:
  ## while `parseHeaders` refuses a label that appears in BOTH buckets,
  ## the ORDER below is unobservable — no input can reach a case where
  ## the two buckets disagree. The duplicate-label refusal is what
  ## actually enforces the property this precedence exists for. If that
  ## refusal is ever relaxed to the SHOULD the RFC writes, this order
  ## becomes load-bearing and needs a case of its own.
  let p = h.protected.lookupInt(label)
  if not p.isNil: p else: h.unprotected.lookupInt(label)

proc algorithmOf(h: CoseHeaders): CoseAlgorithm =
  let alg = h.anyBucket(LabelAlg)
  if alg.isNil:
    coseFail(cxeNoAlgorithm)
  algorithmForLabel(intLabel(alg))

proc keyIdOf(h: CoseHeaders): seq[byte] =
  let kid = h.anyBucket(LabelKid)
  if kid.isNil:
    coseFail(cxeNoKeyIdentifier)
  if kid.kind != ckBytes:
    coseFail(cxeKeyIdentifierNotBytes, "in a message header")
  kid.bytes

proc checkCritical(h: CoseHeaders; understood: openArray[CborItem]) =
  ## RFC 9052 §3.1. `crit` MUST live in the protected bucket, MUST hold
  ## at least one label, every label it names MUST be present in the
  ## protected bucket, and the processor MUST understand each one.
  ##
  ## "Understand" is the CALLER's word here, which is the only place it
  ## can be: this module cannot know what an application does with a
  ## header parameter. The default is an empty list, so a message with
  ## a `crit` is refused unless the caller has said, by value, which
  ## labels it is prepared to handle.
  if not h.unprotected.lookupInt(LabelCrit).isNil:
    coseFail(cxeCritNotProtected)
  let crit = h.protectedOnly(LabelCrit)
  if crit.isNil:
    return
  if crit.kind != ckArray:
    coseFail(cxeCritNotArray, $crit.kind)
  if crit.elems.len == 0:
    coseFail(cxeCritEmpty)
  for label in crit.elems:
    if h.protected.lookup(label).isNil:
      coseFail(cxeCritLabelNotInProtectedBucket,
        hexOf(encodeItem(label)))
    var ok = false
    for u in understood:
      if equalValue(u, label):
        ok = true
        break
    if not ok:
      coseFail(cxeCritLabelNotUnderstood, hexOf(encodeItem(label)))

# ---------------------------------------------------------------------
# The Sig_structure, RFC 9052 §4.4
# ---------------------------------------------------------------------

proc sigStructureSign1*(bodyProtected: openArray[byte];
                        externalAad, payload: openArray[byte]): seq[byte] =
  ## `[ "Signature1", body_protected, external_aad, payload ]`, encoded
  ## under RFC 9052 §9 — definite lengths, minimal arguments.
  encodeDeterministic(cArray([
    cText(ContextSignature1),
    cBytes(bodyProtected),
    cBytes(externalAad),
    cBytes(payload)]))

proc sigStructureSign*(bodyProtected, signProtected: openArray[byte];
                       externalAad, payload: openArray[byte]): seq[byte] =
  ## `[ "Signature", body_protected, sign_protected, external_aad,
  ## payload ]`. The extra element is what makes a COSE_Sign signature
  ## and a COSE_Sign1 signature over the same bytes different values,
  ## and the different context string is what makes them different even
  ## when the extra element is empty.
  encodeDeterministic(cArray([
    cText(ContextSignature),
    cBytes(bodyProtected),
    cBytes(signProtected),
    cBytes(externalAad),
    cBytes(payload)]))

# ---------------------------------------------------------------------
# ECDSA over BearSSL
# ---------------------------------------------------------------------

proc digestFor(alg: CoseAlgorithm; msg: openArray[byte]): seq[byte] =
  case alg
  of caEs256:
    var ctx: bsslHashAbi.Sha256Context
    bsslHashAbi.sha256Init(ctx)
    if msg.len > 0:
      # `sha224Update` is not a narrowing, for the same reason
      # `sha384Update` is not one below: BearSSL's SHA-224 and SHA-256
      # share one context type and one update function, and the binding
      # exposes no `sha256Update`. `sha256Init` and `sha256Out` are what
      # make it SHA-256.
      bsslHashAbi.sha224Update(ctx, unsafeAddr msg[0], uint(msg.len))
    result = newSeq[byte](32)
    bsslHashAbi.sha256Out(ctx, addr result[0])
  of caEs384:
    var ctx: bsslHashAbi.Sha384Context
    bsslHashAbi.sha384Init(ctx)
    if msg.len > 0:
      bsslHashAbi.sha384Update(ctx, unsafeAddr msg[0], uint(msg.len))
    result = newSeq[byte](48)
    bsslHashAbi.sha384Out(ctx, addr result[0])
  of caEs512:
    var ctx: bsslHashAbi.Sha512Context
    bsslHashAbi.sha512Init(ctx)
    if msg.len > 0:
      # `sha384Update` is not a typo and not a narrowing: BearSSL's
      # SHA-384 and SHA-512 share one context type and one update
      # function, and the binding exposes no `sha512Update` to call.
      # `sha512Init` and `sha512Out` are what make it SHA-512, and the
      # RFC 6979 P-521/SHA-512 vectors are what say so out loud.
      bsslHashAbi.sha384Update(ctx, unsafeAddr msg[0], uint(msg.len))
    result = newSeq[byte](64)
    bsslHashAbi.sha512Out(ctx, addr result[0])

proc bearsslCurve(c: CoseCurve): cint =
  case c
  of ccP256: cint(bsslEcAbi.EC_secp256r1)
  of ccP384: cint(bsslEcAbi.EC_secp384r1)
  of ccP521: cint(bsslEcAbi.EC_secp521r1)

proc ecdsaVerifyRaw(key: CoseKey; alg: CoseAlgorithm;
                    toBeSigned, signature: openArray[byte]): bool

proc ecdsaSignatureIsValid*(key: CoseKey; alg: CoseAlgorithm;
                            message, signature: openArray[byte]): bool =
  ## The ECDSA primitive the message-level entry points are built on:
  ## `signature` is `I2OSP(R, n) | I2OSP(S, n)` per RFC 9053 §2.1, and
  ## `message` is hashed here with the algorithm's own hash.
  ##
  ## This one returns a bool BECAUSE it is the primitive — the caller is
  ## `verifyCoseSign1` / `verifyCoseSign`, which turn a false into a
  ## refusal. It is exported so that published ECDSA vectors can be
  ## pinned against it directly; a COSE example cannot reach P-384 at
  ## all, since RFC 9052 Appendix C publishes no ES384 message.
  ##
  ## It does NOT check the key against the algorithm's curve; that is
  ## `selectKey`'s rule and it happens before this is ever called. A
  ## caller reaching this directly is responsible for the pairing, and
  ## a mismatched signature or key width is refused rather than read
  ## past the end — by `ecdsaVerifyRaw`, which is the single place a
  ## raw point and a raw signature reach the curve implementation.
  ecdsaVerifyRaw(key, alg, message, signature)

proc ecdsaVerifyRaw(key: CoseKey; alg: CoseAlgorithm;
                    toBeSigned, signature: openArray[byte]): bool =
  # The widths are checked HERE because this is the only place either
  # buffer is turned into a pointer. `parseCoseKey` cannot produce a
  # point of the wrong width, so a caller that builds a `CoseKey` from
  # something other than a COSE_Key map — a certificate, say — is the
  # only way to reach this, and that caller would otherwise read past
  # the end of the buffer rather than be told no.
  if key.point.len != 1 + 2 * CoseCurveCoordinateLen[key.curve]:
    return false
  if signature.len != 2 * CoseCurveCoordinateLen[key.curve]:
    return false
  var digest = digestFor(alg, toBeSigned)
  var point = key.point
  var sig = @signature
  var pk: bsslEcAbi.EcPublicKey
  pk.curve = bearsslCurve(key.curve)
  pk.q = addr point[0]
  pk.qlen = uint(point.len)
  let impl = bsslEcAbi.ecGetDefault()
  let verifier = bsslEcAbi.ecdsaVrfyRawGetDefault()
  verifier(impl, addr digest[0], csize_t(digest.len), addr pk,
           addr sig[0], csize_t(sig.len)) == 1'u32

# ---------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------

type
  CoseVerified* = object
    ## What a caller gets ONLY when a signature verified.
    payload*: seq[byte]
    algorithm*: CoseAlgorithm
    kid*: seq[byte]
    protectedBytes*: seq[byte]
    toBeSigned*: seq[byte]

proc selectKey(keys: openArray[CoseKey]; kid: seq[byte];
               alg: CoseAlgorithm): CoseKey =
  var found = false
  for k in keys:
    if k.kid == kid:
      result = k
      found = true
      break
  if not found:
    coseFail(cxeKeyNotFound, hexOf(kid))
  if result.hasAlgorithm and result.algorithm != alg:
    coseFail(cxeKeyAlgorithmRestricted,
      CoseAlgorithmName[result.algorithm] & " against " &
        CoseAlgorithmName[alg])
  if result.curve != CoseAlgorithmCurve[alg]:
    coseFail(cxeKeyCurveAlgorithmMismatch,
      CoseAlgorithmName[alg] & " with " & CoseCurveName[result.curve])
  # The supplied key's POINT is checked here too, and not only in
  # `parseCoseKey`, because the keys reaching this procedure are the
  # caller's: a key built from a certificate rather than parsed from a
  # COSE_Key map never went through that rule. A refusal here names the
  # width; `ecdsaVerifyRaw` independently declines to dereference one.
  let want = 1 + 2 * CoseCurveCoordinateLen[result.curve]
  if result.point.len != want:
    coseFail(cxeKeyCoordinateWrongLength,
      CoseCurveName[result.curve] & " wants a " & $want &
        "-byte point, got " & $result.point.len)

proc unwrapTag(item: CborItem; tag: uint64; requireTag: bool): CborItem =
  if item.kind == ckTag:
    if item.tag != tag:
      coseFail(cxeWrongTag, $item.tag & " instead of " & $tag)
    return item.content
  if requireTag:
    coseFail(cxeNotTagged, "expected tag " & $tag)
  item

proc payloadBytes(item: CborItem; detached: openArray[byte];
                  detachedSupplied: bool): seq[byte] =
  if item.isNull:
    if not detachedSupplied:
      coseFail(cxeDetachedPayloadMissing)
    return @detached
  if item.kind != ckBytes:
    coseFail(cxePayloadNotBytes, $item.kind)
  if detachedSupplied:
    coseFail(cxeDetachedPayloadUnexpected)
  item.bytes

proc signatureBytes(item: CborItem; key: CoseKey): seq[byte] =
  if item.isNil or item.kind != ckBytes:
    coseFail(cxeSignatureNotBytes)
  let want = 2 * CoseCurveCoordinateLen[key.curve]
  if item.bytes.len != want:
    coseFail(cxeSignatureWrongLength,
      $item.bytes.len & " bytes, " & CoseCurveName[key.curve] &
        " needs " & $want)
  item.bytes

proc verifyCoseSign1*(message: openArray[byte];
                      keys: openArray[CoseKey];
                      externalAad: openArray[byte] = [];
                      detachedPayload: openArray[byte] = [];
                      detachedPayloadSupplied = false;
                      understoodCritical: openArray[CborItem] = [];
                      requireTag = true): CoseVerified =
  ## RFC 9052 §4.2 + §4.4. Returns the payload only when the signature
  ## over the Sig_structure verified.
  let top = unwrapTag(decodeOrRefuse(message), CoseSign1Tag, requireTag)
  if top.kind != ckArray:
    coseFail(cxeNotArray, $top.kind)
  if top.elems.len != 4:
    coseFail(cxeWrongArity, $top.elems.len & " instead of 4")
  let h = parseHeaders(top.elems[0], top.elems[1])
  h.checkCritical(understoodCritical)
  let alg = h.algorithmOf()
  let kid = h.keyIdOf()
  let key = selectKey(keys, kid, alg)
  let payload = payloadBytes(top.elems[2], detachedPayload,
                             detachedPayloadSupplied)
  let sig = signatureBytes(top.elems[3], key)
  let tbs = sigStructureSign1(h.protectedBytes, externalAad, payload)
  if not ecdsaVerifyRaw(key, alg, tbs, sig):
    coseFail(cxeSignatureDidNotVerify,
      CoseAlgorithmName[alg] & " over " & $tbs.len & " bytes")
  CoseVerified(payload: payload, algorithm: alg, kid: kid,
               protectedBytes: h.protectedBytes, toBeSigned: tbs)

proc verifyCoseSign*(message: openArray[byte];
                     keys: openArray[CoseKey];
                     externalAad: openArray[byte] = [];
                     detachedPayload: openArray[byte] = [];
                     detachedPayloadSupplied = false;
                     understoodCritical: openArray[CborItem] = [];
                     requireTag = true): seq[CoseVerified] =
  ## RFC 9052 §4.1 + §4.4. EVERY signature in the array must verify
  ## against a key the caller supplied; there is no "one of them was
  ## good" mode, because choosing which signer's verdict counts is an
  ## application decision and a library that guessed would be making it
  ## silently. The result carries one entry per signature, in order.
  let top = unwrapTag(decodeOrRefuse(message), CoseSignTag, requireTag)
  if top.kind != ckArray:
    coseFail(cxeNotArray, $top.kind)
  if top.elems.len != 4:
    coseFail(cxeWrongArity, $top.elems.len & " instead of 4")
  let body = parseHeaders(top.elems[0], top.elems[1])
  body.checkCritical(understoodCritical)
  let payload = payloadBytes(top.elems[2], detachedPayload,
                             detachedPayloadSupplied)
  let signatures = top.elems[3]
  if signatures.isNil or signatures.kind != ckArray:
    coseFail(cxeSignaturesNotArray)
  if signatures.elems.len == 0:
    coseFail(cxeNoSignatures)
  for s in signatures.elems:
    if s.isNil or s.kind != ckArray:
      coseFail(cxeNotArray, "COSE_Signature")
    if s.elems.len != 3:
      coseFail(cxeWrongArity, $s.elems.len & " instead of 3")
    let sh = parseHeaders(s.elems[0], s.elems[1])
    sh.checkCritical(understoodCritical)
    let alg = sh.algorithmOf()
    let kid = sh.keyIdOf()
    let key = selectKey(keys, kid, alg)
    let sig = signatureBytes(s.elems[2], key)
    let tbs = sigStructureSign(body.protectedBytes, sh.protectedBytes,
                               externalAad, payload)
    if not ecdsaVerifyRaw(key, alg, tbs, sig):
      coseFail(cxeSignatureDidNotVerify,
        CoseAlgorithmName[alg] & " over " & $tbs.len & " bytes")
    result.add CoseVerified(payload: payload, algorithm: alg, kid: kid,
                            protectedBytes: sh.protectedBytes,
                            toBeSigned: tbs)

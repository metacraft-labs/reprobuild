## Hybrid Public Key Encryption (RFC 9180) over the vendored BearSSL.
##
## ## What this is for
##
## A broker that has decided a machine is trustworthy still has to get a
## secret *to* that machine, and only to that machine. The 64 bytes
## ``binding.nim`` constructs say *which* ephemeral public key a boot
## session holds; this module is what encrypts to that key. Nothing here
## decides whether a machine deserves a secret — that is policy, and it
## lives above this seam.
##
## ## What is implemented, and what is NOT
##
## RFC 9180 is a matrix. This build fills exactly one row of it:
##
##   * KEM   ``0x0020`` — DHKEM(X25519, HKDF-SHA256).
##   * KDF   ``0x0001`` — HKDF-SHA256.
##   * AEAD  ``0x0001`` — AES-128-GCM, and ``0x0003`` — ChaCha20Poly1305.
##   * All four modes: base (``0x00``), PSK (``0x01``), auth (``0x02``)
##     and auth-PSK (``0x03``).
##
## Deliberately absent, and refused rather than approximated — there is
## no enum member to name them with, so a caller cannot ask:
##
##   * DHKEM(P-256), DHKEM(P-384), DHKEM(P-521), DHKEM(X448).
##   * HKDF-SHA384, HKDF-SHA512.
##   * AES-256-GCM (``0x0002``) and the export-only AEAD (``0xFFFF``).
##
## ## What it is built on
##
## X25519, HMAC-SHA256, AES-CTR + GHASH and ChaCha20 + Poly1305 all come
## from the vendored BearSSL. *No second implementation of any primitive
## is introduced here.* What is new is the composition RFC 9180 defines
## and BearSSL does not have: the labeled KDF, the KEM, the key schedule
## and the context.
##
## One primitive is rebuilt on a *lower* BearSSL primitive rather than
## vendored: HKDF. BearSSL ships ``br_hkdf``, but its
## ``br_hkdf_produce`` is a **stream** — two calls with different
## ``info`` continue one output sequence rather than performing two
## independent expansions — and it never exposes the PRK, so a context
## cannot be re-seeded either. HPKE needs three independent
## ``Expand``s from one ``secret``. So ``hkdfExtract`` /
## ``hkdfExpand`` below are RFC 5869 spelled directly over BearSSL's
## ``br_hmac_*``, which is the same primitive ``br_hkdf`` itself uses.
##
## ## Framing, and why there is nothing to frame
##
## The sibling discipline in ``binding.nim`` length-prefixes every
## variable-length part, because an unframed concatenation of two
## caller-chosen values is ambiguous. That is not a theoretical worry
## here: the report-data construction next door was written unframed,
## shipped, and had to be repaired. The same question has to be answered
## for this module, and the answer is different in kind:
##
##   * ``LabeledExtract(salt, label, ikm)`` hashes
##     ``"HPKE-v1" ‖ suite_id ‖ label ‖ ikm``. ``suite_id`` is a fixed
##     width (10 bytes for the HPKE suite, 5 for the KEM suite), ``label``
##     is drawn from a **closed set of compile-time constants**, and
##     ``ikm`` — the only variable-length part — is **last**. A string
##     with one variable-length field, at the end, is unambiguous.
##   * ``LabeledExpand`` is the same shape with a fixed 2-byte length in
##     front.
##   * ``key_schedule_context = mode ‖ psk_id_hash ‖ info_hash`` puts the
##     two caller-supplied values through SHA-256 *first*, so both are
##     exactly ``Nh`` bytes by the time they are joined. A caller cannot
##     move the boundary between ``psk_id`` and ``info``.
##   * ``kem_context`` joins two or three public keys, each exactly
##     ``Nenc`` bytes.
##
## Two obligations follow, and both are discharged by something that can
## fail rather than by this paragraph. ``LabelsAreUnambiguous`` below
## records the property the argument rests on — no label is a prefix of
## another label used by the *same* function — and ``labelsAreUnambiguous``
## computes it from the arrays this module actually uses.
##
## The widths are handled by their reachability. ``kem_context`` joins a
## public key a CALLER can supply (an ``HpkeKeyPair``'s ``pk``), so its
## width is an ``HpkeError`` with an input that reaches it.
## ``key_schedule_context`` joins two SHA-256 outputs, which no input can
## make vary, so its width is a ``doAssert`` and not a refusal: a rule
## with no reachable input is not a rule, and dressing one up as a
## refusal would inflate the refusal ratio with a branch no test can
## redden. The same distinction is made at the two places BearSSL's own
## return values are checked.
##
## ``info`` and ``aad`` themselves are opaque to HPKE, and this module
## never builds one by joining two caller-supplied values. A caller that
## wants to — a key-agreement endpoint will — must frame them, and
## ``binding.bindingPreimage`` is the framing this repository already
## uses.
##
## ## No randomness
##
## There is no random number generator here. Every key enters through
## ``deriveKeyPair(ikm)``, which is RFC 9180 §7.1.3's derivation, and
## every encapsulation takes the ephemeral key as an argument. Choosing
## ``ikm`` — and being answerable for where its entropy came from — is
## the caller's job. This is why every vector below is reproducible and
## why this module has no untested code path that depends on the clock or
## the kernel.
##
## ## Mocking
##
## None.

import std/strutils

import bearssl/abi/consttypes as bsslConstTypes
import bearssl/abi/bearssl_hash as bsslHashAbi
import bearssl/abi/bearssl_hmac as bsslHmacAbi
import bearssl/abi/bearssl_ec as bsslEcAbi
import bearssl/abi/bearssl_block as bsslBlockAbi
import bearssl/abi/bearssl_aead as bsslAeadAbi

type
  HpkeError* = object of CatchableError
    ## Every refusal in this module. The message names what was refused,
    ## and each message below has exactly one producing site so a test
    ## that matches one cannot be satisfied by another.

  HpkeMode* = enum
    ## RFC 9180 §5.1. The value is the byte that goes into
    ## ``key_schedule_context``.
    hmBase = 0x00
    hmPsk = 0x01
    hmAuth = 0x02
    hmAuthPsk = 0x03

  HpkeAead* = enum
    ## The two AEADs this build composes. The value is the registered
    ## ``aead_id``; the two that are absent from this enum
    ## (``0x0002`` AES-256-GCM, ``0xFFFF`` export-only) cannot be named
    ## by a caller, which is the refusal.
    haAes128Gcm = 0x0001
    haChaCha20Poly1305 = 0x0003

  ExtractLabel* = enum
    ## Which ``LabeledExtract`` label a call site wants. Call sites index
    ## ``ExtractLabels`` with one of these rather than spelling the string,
    ## which is what keeps that array honest — see the note beside it.
    elPskIdHash, elInfoHash, elSecret, elEaePrk, elDkpPrk

  ExpandLabel* = enum
    ## Likewise for ``LabeledExpand``.
    xlKey, xlBaseNonce, xlExp, xlSec, xlSharedSecret, xlSk

  HpkeKeyPair* = object
    ## An X25519 key pair. ``sk`` and ``pk`` are raw 32-byte strings, the
    ## little-endian encodings RFC 7748 defines.
    sk*: string
    pk*: string

  HpkeContext* = object
    ## An established HPKE context: everything the key schedule produced
    ## plus the sequence number. Sender and receiver contexts are the
    ## same object — HPKE's is a symmetric construction — so one type
    ## carries both ``seal`` and ``open``.
    aead*: HpkeAead
    mode*: HpkeMode
    key*: string
    baseNonce*: string
    exporterSecret*: string
    keyScheduleContext*: string
      ## Exposed so a second implementation can be pinned against the
      ## *intermediate*, not only against the ciphertext. A construction
      ## checked only end-to-end can be wrong in two places that cancel.
    secret*: string
      ## Likewise. It is key material: do not log it.
    seq*: uint64
      ## Read-only for callers; advance it with ``setSequenceNumber``.

const
  HpkeVersionLabel* = "HPKE-v1"
    ## RFC 9180 §4. Versioned: a future construction is a new label.

  KemIdX25519HkdfSha256* = 0x0020'u16
  KdfIdHkdfSha256* = 0x0001'u16

  Nsecret* = 32  ## DHKEM(X25519, HKDF-SHA256) shared-secret length.
  Nsk* = 32      ## X25519 private key length.
  Npk* = 32      ## X25519 public key length.
  Nenc* = 32     ## Serialized encapsulated key length.
  Nh* = 32       ## SHA-256 output length.

  # --- labels, by the function that uses them ------------------------
  #
  # These two sets are separate because the prefix-freeness argument is
  # per function, not global: "sec" IS a prefix of "secret", and the two
  # live in different sets. Keeping them apart is the point, not an
  # accident of layout.

  ExtractLabels*: array[ExtractLabel, string] = [
    "psk_id_hash", "info_hash", "secret", "eae_prk", "dkp_prk"]
    ## Every ``label`` this module passes to ``labeledExtract``, and the
    ## ONLY place those strings exist: every call site below indexes this
    ## array. That is not tidiness, it is what makes the prefix-freeness
    ## property mean something. While the labels were spelled again at the
    ## call sites, this array was a second, independent list that merely
    ## AGREED with them — and ``labelsAreUnambiguous(ExtractLabels)`` then
    ## proved a property of the declaration while saying nothing about the
    ## bytes the protocol actually hashes. Measured, not supposed:
    ## deleting ``eae_prk`` from this array — a label the module really
    ## does pass to ``labeledExtract`` — was GREEN on both gates.
    ##
    ## Indexing closes the drift: changing a string here changes what the
    ## call site hashes, and the published vectors then refuse it. It does
    ## NOT stop a NEW call site from passing a bare literal; that remains
    ## a review obligation rather than a mechanism.

  ExpandLabels*: array[ExpandLabel, string] = [
    "key", "base_nonce", "exp", "sec", "shared_secret", "sk"]
    ## Every ``label`` this module passes to ``labeledExpand``, indexed
    ## from the call sites for the reason above.

  LabelsAreUnambiguous* =
    "no label is a prefix of another label used by the same function"
    ## The property the framing argument in this module's header rests
    ## on, written where the labels are so it is read beside them. It is
    ## checked mechanically against the two arrays above.

  DefaultPsk* = ""
  DefaultPskId* = ""
    ## RFC 9180 §5.1's ``default_psk`` / ``default_psk_id``.

  PskMinBytes* = 32
    ## RFC 9180 §5.1.1: a PSK shorter than 32 bytes is refused rather
    ## than accepted with a warning.

proc nk*(a: HpkeAead): int =
  ## AEAD key length.
  case a
  of haAes128Gcm: 16
  of haChaCha20Poly1305: 32

proc nn*(a: HpkeAead): int =
  ## AEAD nonce length. Both suites use 12; the arithmetic below does
  ## not assume it.
  case a
  of haAes128Gcm: 12
  of haChaCha20Poly1305: 12

proc nt*(a: HpkeAead): int =
  ## AEAD tag length.
  case a
  of haAes128Gcm: 16
  of haChaCha20Poly1305: 16

proc fail(msg: string) {.noreturn.} =
  ## The one place this module raises from. Having one raise site does
  ## not make two refusals the same refusal: the messages are distinct
  ## and each literal below occurs once.
  raise newException(HpkeError, msg)

# ---------------------------------------------------------------------
# Byte helpers
# ---------------------------------------------------------------------

proc dataPtr(s: string): pointer {.inline.} =
  if s.len == 0: nil else: unsafeAddr s[0]

proc i2osp(n: uint64; w: int): string =
  ## Big-endian fixed-width integer, RFC 8017's I2OSP. Fixed width is
  ## what makes the concatenations above unambiguous.
  result = newString(w)
  var v = n
  for i in countdown(w - 1, 0):
    result[i] = char(v and 0xFF'u64)
    v = v shr 8

proc constTimeEq*(a, b: string): bool =
  ## Comparison whose running time depends on the lengths and not on
  ## the contents. Used for the AEAD tag, where an early return is an
  ## oracle.
  ##
  ## Exported so the length clause below has an input that reaches it.
  ## ``aeadOpen`` refuses a short ciphertext first, so through the HPKE
  ## surface this proc is only ever handed two ``Nt``-byte strings and
  ## "different lengths are not equal" is a branch no caller can take.
  ## A rule with no reachable input is not a rule — measured, not
  ## assumed: a mutation that made it return TRUE on a length mismatch
  ## was green on both gates until this line was exported and pinned.
  if a.len != b.len: return false
  var diff = 0'u8
  for i in 0 ..< a.len:
    diff = diff or (uint8(a[i]) xor uint8(b[i]))
  diff == 0'u8

proc isAllZero(s: string): bool =
  ## Whether every byte is zero, in constant time over the length.
  var acc = 0'u8
  for c in s:
    acc = acc or uint8(c)
  acc == 0'u8

# ---------------------------------------------------------------------
# HKDF-SHA256, RFC 5869, over BearSSL's HMAC
# ---------------------------------------------------------------------

proc hmacSha256*(key, data: string): string =
  ## One HMAC-SHA256, BearSSL's.
  var kc: HmacKeyContext
  hmacKeyInit(kc, addr sha256Vtable, dataPtr(key), csize_t(key.len))
  var hc: HmacContext
  hmacInit(hc, kc, csize_t(0))
  hmacUpdate(hc, dataPtr(data), csize_t(data.len))
  result = newString(Nh)
  discard hmacOut(hc, addr result[0])

proc hkdfExtract*(salt, ikm: string): string =
  ## RFC 5869 §2.2. The salt is the HMAC key; an empty salt is
  ## ``Nh`` zero bytes, which is what an empty HMAC key already means.
  hmacSha256(salt, ikm)

proc hkdfExpand*(prk, info: string; length: int): string =
  ## RFC 5869 §2.3. Independent of any other expansion from the same
  ## PRK, which is the property ``br_hkdf_produce`` does not have.
  if length < 0:
    fail("hpke: an expansion length below zero names no output")
  if length > 255 * Nh:
    fail("hpke: expansion of " & $length & " bytes exceeds the " &
      $(255 * Nh) & "-byte ceiling RFC 5869 sets for this hash")
  result = newString(0)
  var t = ""
  var counter = 1'u8
  while result.len < length:
    t = hmacSha256(prk, t & info & char(counter))
    result.add t
    counter.inc
  result.setLen(length)

# ---------------------------------------------------------------------
# The labeled KDF, RFC 9180 §4
# ---------------------------------------------------------------------

proc kemSuiteId*(kemId: uint16): string =
  ## ``"KEM" ‖ I2OSP(kem_id, 2)`` — 5 bytes, fixed.
  "KEM" & i2osp(uint64(kemId), 2)

proc hpkeSuiteId*(kemId, kdfId, aeadId: uint16): string =
  ## ``"HPKE" ‖ I2OSP(kem_id, 2) ‖ I2OSP(kdf_id, 2) ‖ I2OSP(aead_id, 2)``
  ## — 10 bytes, fixed.
  "HPKE" & i2osp(uint64(kemId), 2) & i2osp(uint64(kdfId), 2) &
    i2osp(uint64(aeadId), 2)

proc suiteIdFor*(aead: HpkeAead): string =
  ## The HPKE suite id for the one KEM and one KDF this build carries.
  hpkeSuiteId(KemIdX25519HkdfSha256, KdfIdHkdfSha256, uint16(ord(aead)))

proc labeledExtractPreimage*(suiteId, label, ikm: string): string =
  ## The exact bytes hashed, exposed for the same reason
  ## ``binding.bindingPreimage`` is: a framing that is wrong but agrees
  ## on one digest is then visible instead of merely improbable.
  HpkeVersionLabel & suiteId & label & ikm

proc labeledExtract*(suiteId, salt, label, ikm: string): string =
  hkdfExtract(salt, labeledExtractPreimage(suiteId, label, ikm))

proc labeledExpandInfo*(suiteId, label, info: string; length: int): string =
  ## The ``info`` string ``LabeledExpand`` feeds to HKDF-Expand.
  i2osp(uint64(length), 2) & HpkeVersionLabel & suiteId & label & info

proc labeledExpand*(suiteId, prk, label, info: string; length: int): string =
  hkdfExpand(prk, labeledExpandInfo(suiteId, label, info, length), length)

# ---------------------------------------------------------------------
# X25519, BearSSL's
# ---------------------------------------------------------------------

proc x25519(scalar, point: string): string =
  ## ``scalar * point`` on Curve25519.
  ##
  ## BearSSL takes the *point* little-endian (RFC 7748's encoding) and
  ## the *scalar* BIG-endian, clamps the scalar itself, and writes the
  ## result back over the point buffer. So the scalar is reversed here
  ## and the point is not. Getting this backwards yields a wrong but
  ## perfectly well-formed 32 bytes, which is precisely the failure the
  ## RFC 9180 vectors exist to catch.
  if scalar.len != Nsk:
    fail("hpke: a curve25519 scalar of " & $scalar.len &
      " bytes cannot be used; 32 is the only length")
  if point.len != Npk:
    fail("hpke: a curve25519 u-coordinate of " & $point.len &
      " bytes cannot be used; 32 is the only length")
  var be = newString(Nsk)
  for i in 0 ..< Nsk:
    be[i] = scalar[Nsk - 1 - i]
  # **The copy below is load-bearing for the same reason ``aeadSeal``'s
  # is, and this site is the OTHER instance of that defect.** BearSSL
  # writes the scalar multiplication back over the buffer it is handed,
  # in place, through ``addr buf[0]``. ``var buf = point`` shares the
  # caller's payload rather than copying it whenever the payload is a
  # string literal — Nim's string assignment shallow-copies a literal on
  # purpose, since a literal is immutable — so a caller that passes a
  # ``const`` public key writes through a pointer into the binary's
  # read-only data: SIGSEGV, not a shared secret. Reproduced standalone;
  # it was latent only because every public key reaching ``dh`` so far
  # came out of ``hexToBytes`` or ``publicKey``, both of which allocate.
  var buf = newString(Npk)
  copyMem(addr buf[0], unsafeAddr point[0], Npk)
  let ok = bsslEcAbi.ecC25519I31.mul(
    cast[ptr byte](addr buf[0]), csize_t(Npk),
    cast[ConstPtrByte](addr be[0]), csize_t(Nsk),
    cint(EC_curve25519))
  # Not a refusal: BearSSL's curve25519 ``mul`` returns 0 only for the two
  # lengths validated above, so no INPUT can reach this. It is an
  # assertion on a foreign function's contract, and it is deliberately
  # NOT an ``HpkeError`` — a rule with no reachable input is not a rule,
  # and counting one as a refusal would inflate the refusal ratio with a
  # branch no test can ever redden.
  doAssert ok == 1'u32, "bearssl curve25519 mul rejected a validated input"
  buf

proc publicKey*(sk: string): string =
  ## ``sk * G``. The public half of an X25519 private key.
  if sk.len != Nsk:
    fail("hpke: a private key of " & $sk.len &
      " bytes has no public half; 32 is the only length")
  var be = newString(Nsk)
  for i in 0 ..< Nsk:
    be[i] = sk[Nsk - 1 - i]
  result = newString(Npk)
  let n = bsslEcAbi.ecC25519I31.mulgen(
    cast[ptr byte](addr result[0]),
    cast[ConstPtrByte](addr be[0]), csize_t(Nsk),
    cint(EC_curve25519))
  # Foreign-contract assertion, not a refusal — see ``x25519``.
  doAssert int(n) == Npk, "bearssl curve25519 mulgen returned a short key"

proc dh*(sk, pk: string): string =
  ## RFC 9180 §7.1.3's ``DH``, WITH the check that makes it fail closed.
  ##
  ## BearSSL's curve25519 ``mul`` returns 1 for every well-formed input,
  ## including the small-order points whose result is the all-zero
  ## value. RFC 7748 §6.1 says to abort on that value and RFC 9180
  ## §7.1.3 inherits the requirement, so the check is HERE — nothing
  ## below it would notice. Without it a peer who sends a low-order
  ## encapsulated key gets a shared secret they can predict.
  let z = x25519(sk, pk)
  if isAllZero(z):
    fail("hpke: the diffie-hellman shared secret is the all-zero value, " &
      "which a small-order public key forces and no honest peer produces")
  z

# ---------------------------------------------------------------------
# DHKEM(X25519, HKDF-SHA256), RFC 9180 §4.1
# ---------------------------------------------------------------------

proc deriveKeyPair*(ikm: string): HpkeKeyPair =
  ## RFC 9180 §7.1.3. The only way a key enters this module.
  if ikm.len < Nsk:
    fail("hpke: key derivation was given " & $ikm.len &
      " bytes of seed material; 32 is the floor, a derived key being no " &
      "stronger than the seed it came from")
  let suite = kemSuiteId(KemIdX25519HkdfSha256)
  let dkpPrk = labeledExtract(suite, "", ExtractLabels[elDkpPrk], ikm)
  let sk = labeledExpand(suite, dkpPrk, ExpandLabels[xlSk], "", Nsk)
  HpkeKeyPair(sk: sk, pk: publicKey(sk))

proc extractAndExpand(dhBytes, kemContext: string): string =
  let suite = kemSuiteId(KemIdX25519HkdfSha256)
  let eaePrk = labeledExtract(suite, "", ExtractLabels[elEaePrk], dhBytes)
  labeledExpand(suite, eaePrk, ExpandLabels[xlSharedSecret], kemContext,
                Nsecret)

proc checkKemContext(kemContext: string; parts: int) =
  ## The width invariant the framing argument rests on. A ``kem_context``
  ## that is not exactly ``parts * Nenc`` bytes means a public key of
  ## the wrong length reached the concatenation, and the boundary
  ## between two keys has moved.
  if kemContext.len != parts * Nenc:
    fail("hpke: kem_context came to " & $kemContext.len & " bytes, and " &
      $parts & " fixed-width public keys are exactly " & $(parts * Nenc))

proc encapWithEphemeral*(pkR: string; ephemeral: HpkeKeyPair):
    tuple[sharedSecret, enc: string] =
  ## RFC 9180 §4.1's ``Encap``, with the ephemeral key supplied rather
  ## than generated — see the module header on randomness.
  if pkR.len != Npk:
    fail("hpke: base encapsulation was handed a recipient key of " &
      $pkR.len & " bytes")
  let dhBytes = dh(ephemeral.sk, pkR)
  let enc = ephemeral.pk
  let kemContext = enc & pkR
  checkKemContext(kemContext, 2)
  (extractAndExpand(dhBytes, kemContext), enc)

proc decap*(enc, skR: string): string =
  ## RFC 9180 §4.1's ``Decap``.
  if enc.len != Nenc:
    fail("hpke: decapsulation was handed an encapsulated key of " &
      $enc.len & " bytes")
  let pkR = publicKey(skR)
  let dhBytes = dh(skR, enc)
  let kemContext = enc & pkR
  checkKemContext(kemContext, 2)
  extractAndExpand(dhBytes, kemContext)

proc authEncapWithEphemeral*(pkR: string; ephemeral: HpkeKeyPair;
                             skS: string): tuple[sharedSecret, enc: string] =
  ## RFC 9180 §4.1's ``AuthEncap``.
  if pkR.len != Npk:
    fail("hpke: authenticated encapsulation was handed a recipient key of " &
      $pkR.len & " bytes")
  let pkS = publicKey(skS)
  let dhBytes = dh(ephemeral.sk, pkR) & dh(skS, pkR)
  let enc = ephemeral.pk
  let kemContext = enc & pkR & pkS
  checkKemContext(kemContext, 3)
  (extractAndExpand(dhBytes, kemContext), enc)

proc authDecap*(enc, skR, pkS: string): string =
  ## RFC 9180 §4.1's ``AuthDecap``.
  if enc.len != Nenc:
    fail("hpke: authenticated unwrapping was handed an encapsulated key " &
      "of " & $enc.len & " bytes")
  if pkS.len != Npk:
    fail("hpke: authenticated unwrapping was handed a sender key of " &
      $pkS.len & " bytes")
  let pkR = publicKey(skR)
  let dhBytes = dh(skR, enc) & dh(skR, pkS)
  let kemContext = enc & pkR & pkS
  checkKemContext(kemContext, 3)
  extractAndExpand(dhBytes, kemContext)

# ---------------------------------------------------------------------
# The key schedule, RFC 9180 §5.1
# ---------------------------------------------------------------------

proc verifyPskInputs*(mode: HpkeMode; psk, pskId: string) =
  ## RFC 9180 §5.1's ``VerifyPSKInputs``, plus §5.1.1's length floor.
  ##
  ## All four refusals are separate because they are separate mistakes,
  ## and a caller reading the message has to know which one they made.
  let gotPsk = psk != DefaultPsk
  let gotPskId = pskId != DefaultPskId
  if gotPsk and not gotPskId:
    fail("hpke: a psk arrived without a psk_id; an unnamed secret cannot " &
      "be agreed on by two parties")
  if gotPskId and not gotPsk:
    fail("hpke: a psk_id arrived without a psk; naming a secret is not " &
      "holding one")
  if gotPsk and mode in {hmBase, hmAuth}:
    fail("hpke: a psk arrived under a mode that binds none; a use that " &
      "binds one is a distinct mode")
  if not gotPsk and mode in {hmPsk, hmAuthPsk}:
    fail("hpke: this mode requires a psk and none arrived")
  if gotPsk and psk.len < PskMinBytes:
    fail("hpke: the psk is " & $psk.len & " bytes; " & $PskMinBytes &
      " is the floor RFC 9180 sets")

proc keySchedule*(aead: HpkeAead; mode: HpkeMode;
                  sharedSecret, info, psk, pskId: string): HpkeContext =
  ## RFC 9180 §5.1's ``KeySchedule``.
  verifyPskInputs(mode, psk, pskId)
  let suite = suiteIdFor(aead)
  let pskIdHash = labeledExtract(suite, "", ExtractLabels[elPskIdHash], pskId)
  let infoHash = labeledExtract(suite, "", ExtractLabels[elInfoHash], info)
  let ksc = char(ord(mode)) & pskIdHash & infoHash
  # Foreign-contract assertion, not a refusal: both halves are SHA-256
  # outputs, so no INPUT can make this width vary. The framing property
  # it records is checked where it CAN vary — in the gate, across every
  # psk_id and info length the vectors and the negative cases use.
  doAssert ksc.len == 1 + 2 * Nh, "key_schedule_context is not framed"
  let secret = labeledExtract(suite, sharedSecret, ExtractLabels[elSecret], psk)
  HpkeContext(
    aead: aead,
    mode: mode,
    key: labeledExpand(suite, secret, ExpandLabels[xlKey], ksc, aead.nk),
    baseNonce: labeledExpand(suite, secret, ExpandLabels[xlBaseNonce], ksc, aead.nn),
    exporterSecret: labeledExpand(suite, secret, ExpandLabels[xlExp], ksc, Nh),
    keyScheduleContext: ksc,
    secret: secret,
    seq: 0'u64)

# ---------------------------------------------------------------------
# Setup, RFC 9180 §5.1.1 – §5.1.4
# ---------------------------------------------------------------------

proc setupBaseS*(aead: HpkeAead; pkR: string; ephemeral: HpkeKeyPair;
                 info: string): tuple[enc: string, ctx: HpkeContext] =
  let (ss, enc) = encapWithEphemeral(pkR, ephemeral)
  (enc, keySchedule(aead, hmBase, ss, info, DefaultPsk, DefaultPskId))

proc setupBaseR*(aead: HpkeAead; enc, skR, info: string): HpkeContext =
  keySchedule(aead, hmBase, decap(enc, skR), info, DefaultPsk, DefaultPskId)

proc setupPskS*(aead: HpkeAead; pkR: string; ephemeral: HpkeKeyPair;
                info, psk, pskId: string):
    tuple[enc: string, ctx: HpkeContext] =
  let (ss, enc) = encapWithEphemeral(pkR, ephemeral)
  (enc, keySchedule(aead, hmPsk, ss, info, psk, pskId))

proc setupPskR*(aead: HpkeAead; enc, skR, info, psk, pskId: string):
    HpkeContext =
  keySchedule(aead, hmPsk, decap(enc, skR), info, psk, pskId)

proc setupAuthS*(aead: HpkeAead; pkR: string; ephemeral: HpkeKeyPair;
                 info, skS: string): tuple[enc: string, ctx: HpkeContext] =
  let (ss, enc) = authEncapWithEphemeral(pkR, ephemeral, skS)
  (enc, keySchedule(aead, hmAuth, ss, info, DefaultPsk, DefaultPskId))

proc setupAuthR*(aead: HpkeAead; enc, skR, info, pkS: string): HpkeContext =
  keySchedule(aead, hmAuth, authDecap(enc, skR, pkS), info,
              DefaultPsk, DefaultPskId)

proc setupAuthPskS*(aead: HpkeAead; pkR: string; ephemeral: HpkeKeyPair;
                    info, psk, pskId, skS: string):
    tuple[enc: string, ctx: HpkeContext] =
  let (ss, enc) = authEncapWithEphemeral(pkR, ephemeral, skS)
  (enc, keySchedule(aead, hmAuthPsk, ss, info, psk, pskId))

proc setupAuthPskR*(aead: HpkeAead; enc, skR, info, psk, pskId, pkS: string):
    HpkeContext =
  keySchedule(aead, hmAuthPsk, authDecap(enc, skR, pkS), info, psk, pskId)

# ---------------------------------------------------------------------
# AEAD, BearSSL's
# ---------------------------------------------------------------------

proc aesGcm(key, nonce, aad: string; data: var string;
            encrypt: bool): string =
  ## AES-128-GCM over BearSSL's constant-time AES-CTR and GHASH.
  ## Encrypts or decrypts ``data`` in place and returns the tag it
  ## computed. Verification is the caller's, in constant time.
  var bc: AesCtCtrKeys
  aesCtCtrInit(bc, dataPtr(key), csize_t(key.len))
  var gc: GcmContext
  gcmInit(gc, addr bc.vtable, ghashCtmul)
  gcmReset(gc, dataPtr(nonce), csize_t(nonce.len))
  gcmAadInject(gc, dataPtr(aad), csize_t(aad.len))
  gcmFlip(gc)
  if data.len > 0:
    gcmRun(gc, cint(if encrypt: 1 else: 0), addr data[0], csize_t(data.len))
  result = newString(16)
  gcmGetTag(gc, addr result[0])

proc chachaPoly(key, nonce, aad: string; data: var string;
                encrypt: bool): string =
  ## ChaCha20Poly1305 over BearSSL's ``br_poly1305_ctmul_run``, which is
  ## the whole RFC 8439 AEAD. It computes the tag and does not check it;
  ## verification is the caller's, in constant time.
  result = newString(16)
  poly1305CtmulRun(dataPtr(key), dataPtr(nonce),
                   (if data.len == 0: nil else: addr data[0]),
                   csize_t(data.len),
                   dataPtr(aad), csize_t(aad.len),
                   addr result[0], chacha20CtRun,
                   cint(if encrypt: 1 else: 0))

proc aeadSeal(aead: HpkeAead; key, nonce, aad, pt: string): string =
  ## **The copy below is load-bearing and must not be shortened back to
  ## ``var buf = pt``.** Both AEAD routines encrypt *in place*, through
  ## ``addr buf[0]``. ``var buf = pt`` is not a copy when the compiler
  ## can see that ``pt`` is dead afterwards — it is a MOVE — and the
  ## move propagates all the way up through ``seal`` and ``sealBase`` to
  ## whatever the caller passed. When that is a string *literal* (or a
  ## ``const``, which is one), the moved string's bytes live in the
  ## binary's read-only data, and writing through them is a segmentation
  ## fault rather than a ciphertext.
  ##
  ## It is a real defect and it was latent for exactly as long as every
  ## caller was a test: the published vectors arrive as
  ## ``hexToBytes(...)``, which is heap-allocated, so the whole corpus
  ## ran through the move without touching read-only memory. The first
  ## caller that sealed a literal crashed. ``newString`` plus
  ## ``copyMem`` is an unconditional allocation that no optimisation can
  ## elide.
  ##
  ## ``aeadOpen`` below does not need it: its ``buf`` comes from a slice
  ## expression, which always allocates.
  var buf = newString(pt.len)
  if pt.len > 0:
    copyMem(addr buf[0], unsafeAddr pt[0], pt.len)
  let tag =
    case aead
    of haAes128Gcm: aesGcm(key, nonce, aad, buf, true)
    of haChaCha20Poly1305: chachaPoly(key, nonce, aad, buf, true)
  buf & tag

proc aeadOpen(aead: HpkeAead; key, nonce, aad, ct: string): string =
  if ct.len < aead.nt:
    fail("hpke: a ciphertext of " & $ct.len & " bytes is shorter than " &
      "the " & $aead.nt & "-byte tag it must carry")
  var buf = ct[0 ..< ct.len - aead.nt]
  let want = ct[ct.len - aead.nt ..< ct.len]
  let got =
    case aead
    of haAes128Gcm: aesGcm(key, nonce, aad, buf, false)
    of haChaCha20Poly1305: chachaPoly(key, nonce, aad, buf, false)
  if not constTimeEq(got, want):
    fail("hpke: the aead tag does not verify; this ciphertext, aad and " &
      "key do not belong together")
  buf

# ---------------------------------------------------------------------
# Context, RFC 9180 §5.2
# ---------------------------------------------------------------------

proc setSequenceNumber*(ctx: var HpkeContext; n: uint64) =
  ## Position the context at a sequence number.
  ##
  ## Not test scaffolding: RFC 9180's own vectors skip sequence numbers
  ## and a real receiver that tolerates loss has to as well. It is the
  ## only writer of ``seq`` outside ``seal``/``open``, and it is what
  ## makes the ceiling below a rule with a reachable input rather than
  ## an unreachable one.
  ctx.seq = n

proc computeNonce*(ctx: HpkeContext): string =
  ## ``xor(base_nonce, I2OSP(seq, Nn))``.
  let s = i2osp(ctx.seq, ctx.aead.nn)
  result = newString(ctx.aead.nn)
  for i in 0 ..< ctx.aead.nn:
    result[i] = char(uint8(ctx.baseNonce[i]) xor uint8(s[i]))

proc incrementSeq(ctx: var HpkeContext) =
  ## RFC 9180 §5.2 requires the context to abort rather than reuse a
  ## nonce. The RFC's ceiling is ``2^(8*Nn) - 1``; this build's counter
  ## is 64-bit, so it refuses at ``2^64 - 1`` instead — strictly
  ## earlier, and by a margin no deployment reaches.
  if ctx.seq == high(uint64):
    fail("hpke: the sequence number is exhausted; another message would " &
      "reuse a nonce")
  ctx.seq.inc

proc seal*(ctx: var HpkeContext; aad, pt: string): string =
  ## Encrypt under the context, advancing its sequence number.
  let nonce = ctx.computeNonce()
  result = aeadSeal(ctx.aead, ctx.key, nonce, aad, pt)
  ctx.incrementSeq()

proc open*(ctx: var HpkeContext; aad, ct: string): string =
  ## Decrypt under the context, advancing its sequence number.
  ##
  ## The sequence number advances only on success: a rejected
  ## ciphertext must not move a receiver off the message it is still
  ## waiting for.
  let nonce = ctx.computeNonce()
  result = aeadOpen(ctx.aead, ctx.key, nonce, aad, ct)
  ctx.incrementSeq()

proc exportSecret*(ctx: HpkeContext; exporterContext: string;
                   length: int): string =
  ## RFC 9180 §5.3's ``Export``.
  labeledExpand(suiteIdFor(ctx.aead), ctx.exporterSecret,
                ExpandLabels[xlSec], exporterContext, length)

# ---------------------------------------------------------------------
# Single-shot, RFC 9180 §6.1
# ---------------------------------------------------------------------

proc sealBase*(aead: HpkeAead; pkR: string; ephemeral: HpkeKeyPair;
               info, aad, pt: string): tuple[enc, ct: string] =
  ## ``SealBase``. One message to one recipient.
  var (enc, ctx) = setupBaseS(aead, pkR, ephemeral, info)
  (enc, ctx.seal(aad, pt))

proc openBase*(aead: HpkeAead; enc, skR, info, aad, ct: string): string =
  ## ``OpenBase``. Raises ``HpkeError`` — never returns plaintext it
  ## could not authenticate.
  var ctx = setupBaseR(aead, enc, skR, info)
  ctx.open(aad, ct)

proc labelsAreUnambiguous*(labels: openArray[string]): bool =
  ## Whether no member of ``labels`` is a prefix of another member.
  ##
  ## Exposed so the property in ``LabelsAreUnambiguous`` is *computed*
  ## from the constants this module uses rather than restated in a test.
  for i in 0 ..< labels.len:
    for j in 0 ..< labels.len:
      if i != j and labels[j].startsWith(labels[i]):
        return false
  true

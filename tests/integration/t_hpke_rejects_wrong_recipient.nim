## HPKE fails closed: what happens when the ciphertext, the encapsulated
## key, the recipient or the inputs are not the ones the sender meant.
##
## ## The claim this gate has to make, and the one it must not make
##
## The weak claim would be "decrypting under the wrong key gives
## different bytes". That is nearly worthless: a stream cipher will
## happily produce *some* 29 bytes for any key, and a gate that only
## compares them to the plaintext passes against an implementation that
## hands the caller garbage and calls it plaintext.
##
## So every case below asserts the **refusal** — that an ``HpkeError``
## was raised and which one — and the suite additionally asserts, once,
## globally, that across every tampering case in this file **no plaintext
## was produced at all**. ``producedPlaintexts`` collects whatever escapes
## an ``open``; the last case checks it is empty. The companion
## observation is made explicitly: the ciphertext body is exactly as long
## as the plaintext, so a plausible-looking wrong answer is one XOR away
## and the only thing standing between an attacker and it is the tag
## check.
##
## ## Two different refusals, kept apart on purpose
##
## A corrupted encapsulated key can fail in two distinct ways, and a
## gate that matched a single substring would be satisfied by either:
##
##   * A **bit-flipped** key is still a perfectly good curve point. The
##     Diffie-Hellman succeeds, yields a *different* shared secret, and
##     the failure lands on the AEAD tag.
##   * A **small-order** key forces the Diffie-Hellman output to the
##     all-zero value, which RFC 7748 §6.1 says to abort on. BearSSL's
##     ``mul`` does not: it returns success for these inputs, so
##     ``hpke.dh`` checks for the all-zero value itself. Without that
##     check a peer who sends a small-order key gets a shared secret they
##     can predict, and the tag would then verify.
##
## Both are exercised, each is matched against its own full message, and
## each is asserted to be *not* the other's message.
##
## ## Provenance of the small-order encodings
##
## RFC 7748 §6.1 and §7 describe the all-zero output a small-order input
## forces but publish no such encoding. The four used here were confirmed
## to force it by an independent X25519 — a direct transcription of RFC
## 7748 §5's Montgomery-ladder pseudocode into Python, which reproduces
## RFC 7748's own §5.2 and §6.1 vectors before it is used for anything
## else. They are u = 0, u = 1, u = p - 1 and u = p, the smallest
## encodings for which this is true. Nothing here relies on the code
## under test to establish that they are small-order.
##
## ## Every refusal this module can raise, and nothing else
##
## The last case in the file asserts that the refusals collected while
## running everything above are *exactly* the twenty-one messages this
## module has, that they are all distinct, and that **no message is a
## substring of another** — so a case that matches one refusal cannot be
## passing on a different one. The twenty-one literals below are written
## out here independently of the library; changing a message in the
## library reddens this gate.
##
## ## Mocking
##
## None.

import std/[algorithm, sequtils, strutils, unittest]

import repro_attest/binding
import repro_attest/hpke

# ---------------------------------------------------------------------
# Fixed inputs. Every key in this file is derived from a seed spelled
# out here, so nothing depends on a random number generator and every
# failure is reproducible from this file alone.
# ---------------------------------------------------------------------

const
  IkmRecipientOne =
    "6db9df30aa07dd42ee5e8181afdb977e538f5e1fec8a06223f33f7013e525037"
  IkmRecipientTwo =
    "11111111111111111111111111111111111111111111111111111111111111ff"
  IkmEphemeral =
    "7268600d403fce431561aef583ee1613527cff655c1343f29812e66706df3234"
  IkmSender =
    "22222222222222222222222222222222222222222222222222222222222222ee"
  IkmOtherSender =
    "33333333333333333333333333333333333333333333333333333333333333dd"
  InfoHex = "4f6465206f6e2061204772656369616e2055726e"
  AadHex = "436f756e742d30"
  PtHex = "4265617574792069732074727574682c20747275746820626561757479"
  PskHex =
    "0247fd33b913760fa1fa51e1892d9f307fbe65eb171e8132c2af18555a738b82"
  PskIdHex = "456e6e796e20447572696e206172616e204d6f726961"

  # Small-order Curve25519 u-coordinates; see the header for provenance.
  SmallOrderPoints = [
    "0000000000000000000000000000000000000000000000000000000000000000",
    "0100000000000000000000000000000000000000000000000000000000000000",
    "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"]

  # The twenty-one refusals, transcribed from the library rather than
  # imported from it. A message that changes there must be changed here
  # too, deliberately, or this gate reddens.
  RefusalExpandNegative =
    "hpke: an expansion length below zero names no output"
  RefusalExpandCeiling =
    "hpke: expansion of 8161 bytes exceeds the 8160-byte ceiling " &
    "RFC 5869 sets for this hash"
  RefusalScalarLength =
    "hpke: a curve25519 scalar of 31 bytes cannot be used; 32 is the " &
    "only length"
  RefusalPointLength =
    "hpke: a curve25519 u-coordinate of 33 bytes cannot be used; 32 is " &
    "the only length"
  RefusalPrivateKeyLength =
    "hpke: a private key of 16 bytes has no public half; 32 is the only " &
    "length"
  RefusalAllZeroSecret =
    "hpke: the diffie-hellman shared secret is the all-zero value, which " &
    "a small-order public key forces and no honest peer produces"
  RefusalSeedFloor =
    "hpke: key derivation was given 31 bytes of seed material; 32 is the " &
    "floor, a derived key being no stronger than the seed it came from"
  RefusalKemContextWidth =
    "hpke: kem_context came to 63 bytes, and 2 fixed-width public keys " &
    "are exactly 64"
  RefusalEncapRecipient =
    "hpke: base encapsulation was handed a recipient key of 31 bytes"
  RefusalDecapEnc =
    "hpke: decapsulation was handed an encapsulated key of 31 bytes"
  RefusalAuthEncapRecipient =
    "hpke: authenticated encapsulation was handed a recipient key of 31 " &
    "bytes"
  RefusalAuthDecapEnc =
    "hpke: authenticated unwrapping was handed an encapsulated key of 31 " &
    "bytes"
  RefusalAuthDecapSender =
    "hpke: authenticated unwrapping was handed a sender key of 31 bytes"
  RefusalPskWithoutId =
    "hpke: a psk arrived without a psk_id; an unnamed secret cannot be " &
    "agreed on by two parties"
  RefusalPskIdWithoutPsk =
    "hpke: a psk_id arrived without a psk; naming a secret is not " &
    "holding one"
  RefusalPskUnderWrongMode =
    "hpke: a psk arrived under a mode that binds none; a use that binds " &
    "one is a distinct mode"
  RefusalPskMissing =
    "hpke: this mode requires a psk and none arrived"
  RefusalPskTooShort =
    "hpke: the psk is 31 bytes; 32 is the floor RFC 9180 sets"
  RefusalCiphertextShort =
    "hpke: a ciphertext of 5 bytes is shorter than the 16-byte tag it " &
    "must carry"
  RefusalTag =
    "hpke: the aead tag does not verify; this ciphertext, aad and key do " &
    "not belong together"
  RefusalSeqExhausted =
    "hpke: the sequence number is exhausted; another message would reuse " &
    "a nonce"

  AllRefusals = [
    RefusalExpandNegative, RefusalExpandCeiling, RefusalScalarLength,
    RefusalPointLength, RefusalPrivateKeyLength, RefusalAllZeroSecret,
    RefusalSeedFloor, RefusalKemContextWidth, RefusalEncapRecipient,
    RefusalDecapEnc, RefusalAuthEncapRecipient, RefusalAuthDecapEnc,
    RefusalAuthDecapSender, RefusalPskWithoutId, RefusalPskIdWithoutPsk,
    RefusalPskUnderWrongMode, RefusalPskMissing, RefusalPskTooShort,
    RefusalCiphertextShort, RefusalTag, RefusalSeqExhausted]

let
  info = hexToBytes("info", InfoHex)
  aad = hexToBytes("aad", AadHex)
  pt = hexToBytes("pt", PtHex)
  psk = hexToBytes("psk", PskHex)
  pskId = hexToBytes("psk_id", PskIdHex)
  recipientOne = deriveKeyPair(hexToBytes("ikmR1", IkmRecipientOne))
  recipientTwo = deriveKeyPair(hexToBytes("ikmR2", IkmRecipientTwo))
  ephemeral = deriveKeyPair(hexToBytes("ikmE", IkmEphemeral))
  sender = deriveKeyPair(hexToBytes("ikmS", IkmSender))
  otherSender = deriveKeyPair(hexToBytes("ikmS2", IkmOtherSender))

var
  refusals: seq[string] = @[]
    ## Every refusal message raised while this file runs. The last case
    ## holds it to the full set the library can produce.
  producedPlaintexts: seq[string] = @[]
    ## Anything an ``open`` handed back in a case that was supposed to
    ## refuse. Asserted empty at the end: this is "fails rather than
    ## producing garbage plaintext", stated once over every case.

template mustRefuse(what: string; body: untyped): string =
  ## Runs ``body`` — an expression whose value is dropped — which must
  ## raise ``HpkeError``, and yields the message it raised.
  block:
    var msg = ""
    try:
      discard body
    except HpkeError as e:
      msg = e.msg
      refusals.add e.msg
    if msg.len == 0:
      checkpoint("nothing was refused: " & what)
    check msg.len > 0
    msg

template mustRefuseOpen(what: string; body: untyped): string =
  ## The same, for an expression that would yield a plaintext. Anything
  ## it yields is recorded so the suite can assert that nothing did.
  block:
    var msg = ""
    try:
      producedPlaintexts.add(body)
    except HpkeError as e:
      msg = e.msg
      refusals.add e.msg
    if msg.len == 0:
      checkpoint("a plaintext escaped: " & what)
    check msg.len > 0
    msg

proc flipBit(s: string; index: int): string =
  result = s
  result[index] = char(uint8(result[index]) xor 0x01'u8)

proc flipBitAt(s: string; bit: int): string =
  ## Flip ONE bit of ``s``, counted across the whole string. `flipBit`
  ## above only ever reaches bit 0 of a byte, so a sweep built on it
  ## covers 32 of the 256 single-bit corruptions of a 32-byte key. This
  ## one covers all of them.
  result = s
  result[bit div 8] =
    char(uint8(result[bit div 8]) xor (1'u8 shl (bit mod 8)))

proc driveHpkeRejectsWrongRecipient() =
  ## The body of test
  ##   "t_hpke_rejects_wrong_recipient"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  for aead in [haAes128Gcm, haChaCha20Poly1305]:
    let (enc, ct) = sealBase(aead, recipientOne.pk, ephemeral,
                             info, aad, pt)
    # The positive control, first: the refusals below are worth
    # nothing unless the same call succeeds for the right key.
    check openBase(aead, enc, recipientOne.sk, info, aad, ct) == pt
    # The ciphertext body is exactly as long as the plaintext, so a
    # wrong-but-plausible answer of the right length exists and is one
    # XOR away. What follows is the refusal to produce it.
    check ct.len == pt.len + aead.nt
    check recipientOne.sk != recipientTwo.sk
    check mustRefuseOpen("open under the other recipient's key",
      openBase(aead, enc, recipientTwo.sk, info, aad, ct)) == RefusalTag
  check producedPlaintexts.len == 0

proc driveHpkeRejectsACorruptedEncapsulatedKey() =
  ## The body of test
  ##   "t_hpke_rejects_a_corrupted_encapsulated_key"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  for aead in [haAes128Gcm, haChaCha20Poly1305]:
    let (enc, ct) = sealBase(aead, recipientOne.pk, ephemeral,
                             info, aad, pt)
    check enc.len == Nenc
    var refused = 0
    for i in 0 ..< enc.len * 8:
      let tampered = flipBitAt(enc, i)
      check tampered != enc
      # EVERY single-bit corruption of the encapsulated key is refused —
      # all 256, not one per byte. Not "decrypts differently" — refused.
      # Bit 255 is the one worth naming: RFC 7748 has the scalar
      # multiplication IGNORE it, so the Diffie-Hellman output is
      # unchanged by that flip and only `kem_context` — which binds the
      # encapsulated key as SENT — can tell the two apart.
      check mustRefuseOpen("bit " & $i & " of enc",
        openBase(aead, tampered, recipientOne.sk, info, aad, ct)) ==
        RefusalTag
      refused.inc
    check refused == 256
    # And the same call without the corruption still works, so the
    # refusal is about the corruption.
    check openBase(aead, enc, recipientOne.sk, info, aad, ct) == pt
  check producedPlaintexts.len == 0

proc driveHpkeRejectsASmallOrderEncapsulatedKeyAtTheSecret() =
  ## The body of test
  ##   "t_hpke_rejects_a_small_order_encapsulated_key_at_the_secret"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # A different failure from the one above, and it must stay
  # different: this one is refused before any key is derived, because
  # the shared secret is a value an attacker can predict.
  for aead in [haAes128Gcm, haChaCha20Poly1305]:
    let (enc, ct) = sealBase(aead, recipientOne.pk, ephemeral,
                             info, aad, pt)
    for hexPoint in SmallOrderPoints:
      let small = hexToBytes("small-order point", hexPoint)
      check small.len == Nenc
      let msg = mustRefuseOpen("small-order enc " & hexPoint,
        openBase(aead, enc = small, skR = recipientOne.sk, info = info,
                 aad = aad, ct = ct))
      check msg == RefusalAllZeroSecret
      # The two refusals are not one refusal wearing two hats.
      check msg != RefusalTag
      check not msg.contains(RefusalTag)
      check not RefusalTag.contains(msg)
    check openBase(aead, enc, recipientOne.sk, info, aad, ct) == pt
  check producedPlaintexts.len == 0

proc driveHpkeRejectsTamperedCiphertextAadInfoAndSequence() =
  ## The body of test
  ##   "t_hpke_rejects_tampered_ciphertext_aad_info_and_sequence"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let aead = haChaCha20Poly1305
  let (enc, ct) = sealBase(aead, recipientOne.pk, ephemeral,
                           info, aad, pt)
  # A flipped bit in the ciphertext body.
  check mustRefuseOpen("body",
    openBase(aead, enc, recipientOne.sk, info, aad,
             flipBit(ct, 0))) == RefusalTag
  # A flipped bit in the tag.
  check mustRefuseOpen("tag",
    openBase(aead, enc, recipientOne.sk, info, aad,
             flipBit(ct, ct.len - 1))) == RefusalTag
  # A different aad.
  check mustRefuseOpen("aad",
    openBase(aead, enc, recipientOne.sk, info, aad & "!", ct)) ==
    RefusalTag
  # A different info, which changes the key schedule rather than the
  # AEAD inputs — and is refused all the same.
  check mustRefuseOpen("info",
    openBase(aead, enc, recipientOne.sk, info & "!", aad, ct)) ==
    RefusalTag
  # A receiver positioned at the wrong sequence number.
  var out1 = setupBaseR(aead, enc, recipientOne.sk, info)
  out1.setSequenceNumber(1'u64)
  check mustRefuseOpen("sequence number",
    out1.open(aad, ct)) == RefusalTag
  # A ciphertext with no room for a tag.
  check mustRefuseOpen("truncated ciphertext",
    openBase(aead, enc, recipientOne.sk, info, aad, ct[0 ..< 5])) ==
    RefusalCiphertextShort
  # A refused open must not move the receiver off the message it is
  # still waiting for, so the counter advances on success only.
  var out2 = setupBaseR(aead, enc, recipientOne.sk, info)
  check out2.seq == 0'u64
  check mustRefuseOpen("body, counter must not move",
    out2.open(aad, flipBit(ct, 0))) == RefusalTag
  check out2.seq == 0'u64
  check out2.open(aad, ct) == pt
  check out2.seq == 1'u64
  # Positive control.
  check openBase(aead, enc, recipientOne.sk, info, aad, ct) == pt
  check producedPlaintexts.len == 0

proc driveHpkeRejectsTheWrongSenderInAuthenticatedMode() =
  ## The body of test
  ##   "t_hpke_rejects_the_wrong_sender_in_authenticated_mode"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let aead = haAes128Gcm
  let (enc, ctx) = setupAuthS(aead, recipientOne.pk, ephemeral, info,
                              sender.sk)
  var sctx = ctx
  let ct = sctx.seal(aad, pt)
  # Positive control: the real sender's public key opens it.
  var good = setupAuthR(aead, enc, recipientOne.sk, info, sender.pk)
  check good.open(aad, ct) == pt
  # A different sender's public key does not, and the failure is a
  # refusal rather than a different plaintext.
  check sender.pk != otherSender.pk
  var bad = setupAuthR(aead, enc, recipientOne.sk, info, otherSender.pk)
  check mustRefuseOpen("wrong sender key", bad.open(aad, ct)) == RefusalTag
  # The shared secret really is different, which is what the tag is
  # detecting.
  check authDecap(enc, recipientOne.sk, sender.pk) !=
    authDecap(enc, recipientOne.sk, otherSender.pk)
  check producedPlaintexts.len == 0

suite "hpke refuses the wrong recipient":

  test "t_hpke_rejects_wrong_recipient":
    driveHpkeRejectsWrongRecipient()

  test "t_hpke_rejects_a_corrupted_encapsulated_key":
    driveHpkeRejectsACorruptedEncapsulatedKey()

  test "t_hpke_rejects_a_small_order_encapsulated_key_at_the_secret":
    driveHpkeRejectsASmallOrderEncapsulatedKeyAtTheSecret()

  test "t_hpke_rejects_tampered_ciphertext_aad_info_and_sequence":
    driveHpkeRejectsTamperedCiphertextAadInfoAndSequence()

  test "t_hpke_rejects_the_wrong_sender_in_authenticated_mode":
    driveHpkeRejectsTheWrongSenderInAuthenticatedMode()

proc driveHpkeRejectsKeysAndEncapsulationsOfTheWrongLength() =
  ## The body of test
  ##   "t_hpke_rejects_keys_and_encapsulations_of_the_wrong_length"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let short31 = repeat('\0', 31)
  let long33 = repeat('\0', 33)
  check mustRefuse("short scalar", dh(short31, recipientOne.pk)) ==
    RefusalScalarLength
  check mustRefuse("long point", dh(recipientOne.sk, long33)) ==
    RefusalPointLength
  check mustRefuse("short private key",
    publicKey(repeat('\0', 16))) == RefusalPrivateKeyLength
  check mustRefuse("short recipient key",
    encapWithEphemeral(short31, ephemeral)) == RefusalEncapRecipient
  check mustRefuse("short enc",
    decap(short31, recipientOne.sk)) == RefusalDecapEnc
  check mustRefuse("short auth recipient key",
    authEncapWithEphemeral(short31, ephemeral, sender.sk)) ==
    RefusalAuthEncapRecipient
  check mustRefuse("short auth enc",
    authDecap(short31, recipientOne.sk, sender.pk)) ==
    RefusalAuthDecapEnc
  check mustRefuse("short sender key",
    authDecap(recipientOne.pk, recipientOne.sk, short31)) ==
    RefusalAuthDecapSender
  # A malformed ephemeral PUBLIC key is the input that reaches the
  # kem_context width rule: everything else in the concatenation has
  # already been length-checked, and this one has not.
  let malformed = HpkeKeyPair(sk: ephemeral.sk, pk: ephemeral.pk[0 ..< 31])
  check mustRefuse("malformed ephemeral public key",
    encapWithEphemeral(recipientOne.pk, malformed)) ==
    RefusalKemContextWidth
  # Positive controls for all of the above.
  check dh(recipientOne.sk, ephemeral.pk).len == Nsecret
  check publicKey(recipientOne.sk) == recipientOne.pk
  check encapWithEphemeral(recipientOne.pk, ephemeral).enc == ephemeral.pk
  check decap(ephemeral.pk, recipientOne.sk).len == Nsecret

proc driveHpkeRejectsASeedBelowTheFloor() =
  ## The body of test
  ##   "t_hpke_rejects_a_seed_below_the_floor"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  check mustRefuse("31-byte seed",
    deriveKeyPair(repeat('\0', 31))) == RefusalSeedFloor
  # The bound is tested AT the bound, not under it: 32 works.
  check deriveKeyPair(repeat('\0', 32)).sk.len == Nsk

proc driveHpkeRejectsInconsistentPskInputs() =
  ## The body of test
  ##   "t_hpke_rejects_inconsistent_psk_inputs"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let shared = repeat('\0', Nsecret)
  check mustRefuse("psk without psk_id",
    keySchedule(haAes128Gcm, hmPsk, shared, info, psk,
                        DefaultPskId)) == RefusalPskWithoutId
  check mustRefuse("psk_id without psk",
    keySchedule(haAes128Gcm, hmPsk, shared, info, DefaultPsk,
                        pskId)) == RefusalPskIdWithoutPsk
  check mustRefuse("psk under base mode",
    keySchedule(haAes128Gcm, hmBase, shared, info, psk,
                        pskId)) == RefusalPskUnderWrongMode
  check mustRefuse("psk under auth mode",
    keySchedule(haAes128Gcm, hmAuth, shared, info, psk,
                        pskId)) == RefusalPskUnderWrongMode
  check mustRefuse("no psk under psk mode",
    keySchedule(haAes128Gcm, hmPsk, shared, info, DefaultPsk,
                        DefaultPskId)) == RefusalPskMissing
  check mustRefuse("no psk under auth-psk mode",
    keySchedule(haAes128Gcm, hmAuthPsk, shared, info, DefaultPsk,
                        DefaultPskId)) == RefusalPskMissing
  check mustRefuse("31-byte psk",
    keySchedule(haAes128Gcm, hmPsk, shared, info,
                        repeat('\0', 31), pskId)) == RefusalPskTooShort
  # The floor is tested AT the floor: 32 is accepted.
  check keySchedule(haAes128Gcm, hmPsk, shared, info,
                    repeat('\0', 32), pskId).key.len == haAes128Gcm.nk
  # …and each of the four modes is accepted with the inputs it does
  # want, so none of the refusals above is universal.
  check keySchedule(haAes128Gcm, hmBase, shared, info, DefaultPsk,
                    DefaultPskId).mode == hmBase
  check keySchedule(haAes128Gcm, hmAuth, shared, info, DefaultPsk,
                    DefaultPskId).mode == hmAuth
  check keySchedule(haAes128Gcm, hmPsk, shared, info, psk, pskId).mode ==
    hmPsk
  check keySchedule(haAes128Gcm, hmAuthPsk, shared, info, psk,
                    pskId).mode == hmAuthPsk

proc driveHpkeRejectsExportLengthsOutsideTheHkdfRange() =
  ## The body of test
  ##   "t_hpke_rejects_export_lengths_outside_the_hkdf_range"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var ctx = setupBaseR(
    haAes128Gcm,
    encapWithEphemeral(recipientOne.pk, ephemeral).enc,
    recipientOne.sk, info)
  check mustRefuse("negative export length",
    ctx.exportSecret("", -1)) == RefusalExpandNegative
  check mustRefuse("export past the ceiling",
    ctx.exportSecret("", 255 * Nh + 1)) == RefusalExpandCeiling
  # The bound is tested AT the bound: 255 * Nh is the largest length
  # RFC 5869 admits, and it is produced rather than refused.
  check ctx.exportSecret("", 255 * Nh).len == 255 * Nh
  check ctx.exportSecret("", 0).len == 0

proc driveHpkeRefusesToReuseANonceWhenTheCounterIsExhausted() =
  ## The body of test
  ##   "t_hpke_refuses_to_reuse_a_nonce_when_the_counter_is_exhausted"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var ctx = setupBaseR(
    haChaCha20Poly1305,
    encapWithEphemeral(recipientOne.pk, ephemeral).enc,
    recipientOne.sk, info)
  # One below the ceiling still seals, and lands exactly on it.
  ctx.setSequenceNumber(high(uint64) - 1'u64)
  discard ctx.seal(aad, pt)
  check ctx.seq == high(uint64)
  # On the ceiling it refuses, and the counter has not moved.
  check mustRefuse("exhausted counter", ctx.seal(aad, pt)) ==
    RefusalSeqExhausted
  check ctx.seq == high(uint64)

suite "hpke refuses malformed inputs":

  test "t_hpke_rejects_keys_and_encapsulations_of_the_wrong_length":
    driveHpkeRejectsKeysAndEncapsulationsOfTheWrongLength()

  test "t_hpke_rejects_a_seed_below_the_floor":
    driveHpkeRejectsASeedBelowTheFloor()

  test "t_hpke_rejects_inconsistent_psk_inputs":
    driveHpkeRejectsInconsistentPskInputs()

  test "t_hpke_rejects_export_lengths_outside_the_hkdf_range":
    driveHpkeRejectsExportLengthsOutsideTheHkdfRange()

  test "t_hpke_refuses_to_reuse_a_nonce_when_the_counter_is_exhausted":
    driveHpkeRefusesToReuseANonceWhenTheCounterIsExhausted()

  test "t_hpke_constant_time_equality_is_length_aware":
    # `aeadOpen` refuses a short ciphertext before it compares anything,
    # so through the HPKE surface the tag comparison is only ever handed
    # two 16-byte strings and its "different lengths are not equal"
    # clause has no input that reaches it. That is a rule that cannot
    # fail, and this gate did not catch it until it was measured: a
    # mutation making the comparison return TRUE on a length mismatch
    # was green on BOTH gates. The clause is pinned here directly.
    let tag = repeat('\x11', 16)
    check constTimeEq(tag, tag)
    check constTimeEq("", "")
    check not constTimeEq(tag, tag[0 ..< 15])
    check not constTimeEq(tag[0 ..< 15], tag)
    check not constTimeEq(tag, tag & '\x00')
    check not constTimeEq("", "\x00")
    # …and the contents clause too, so the length fix cannot be the only
    # thing holding the comparison up.
    check not constTimeEq(tag, flipBit(tag, 7))
    check not constTimeEq(tag, flipBit(tag, 15))

# Every case above that raises a refusal. The discipline case drives all
# of them itself: the suite runner executes each case in its own process
# (`--run suite::test`), so `refusals` and `producedPlaintexts` hold only
# what ran in THIS process, and a case that read what earlier cases left
# behind would measure the execution mode rather than the library.
const RefusalDrivers: seq[(string, proc () {.nimcall.})] = @[
  ("t_hpke_rejects_wrong_recipient", driveHpkeRejectsWrongRecipient),
  ("t_hpke_rejects_a_corrupted_encapsulated_key",
    driveHpkeRejectsACorruptedEncapsulatedKey),
  ("t_hpke_rejects_a_small_order_encapsulated_key_at_the_secret",
    driveHpkeRejectsASmallOrderEncapsulatedKeyAtTheSecret),
  ("t_hpke_rejects_tampered_ciphertext_aad_info_and_sequence",
    driveHpkeRejectsTamperedCiphertextAadInfoAndSequence),
  ("t_hpke_rejects_the_wrong_sender_in_authenticated_mode",
    driveHpkeRejectsTheWrongSenderInAuthenticatedMode),
  ("t_hpke_rejects_keys_and_encapsulations_of_the_wrong_length",
    driveHpkeRejectsKeysAndEncapsulationsOfTheWrongLength),
  ("t_hpke_rejects_a_seed_below_the_floor",
    driveHpkeRejectsASeedBelowTheFloor),
  ("t_hpke_rejects_inconsistent_psk_inputs",
    driveHpkeRejectsInconsistentPskInputs),
  ("t_hpke_rejects_export_lengths_outside_the_hkdf_range",
    driveHpkeRejectsExportLengthsOutsideTheHkdfRange),
  ("t_hpke_refuses_to_reuse_a_nonce_when_the_counter_is_exhausted",
    driveHpkeRefusesToReuseANonceWhenTheCounterIsExhausted)]

suite "hpke refusal discipline":

  test "t_hpke_no_two_refusals_hide_behind_one_another":
    # Every refusing case above is driven here, from empty state, so
    # `refusals` holds one entry per refusal that actually fired in THIS
    # process — the same verdict alone as after the others.
    refusals = @[]
    producedPlaintexts = @[]
    for (name, drive) in RefusalDrivers:
      checkpoint("driving " & name)
      drive()
    var seen = refusals
    seen.sort()
    seen = seen.deduplicate(isSorted = true)
    var expected = @AllRefusals
    expected.sort()
    check expected.len == 21
    check expected.deduplicate(isSorted = true).len == 21
    # Every refusal the library has was reached, and nothing else was.
    check seen == expected
    # …and no message is a substring of another, so a case that matched
    # one of them cannot have been satisfied by a different refusal.
    for i in 0 ..< expected.len:
      for j in 0 ..< expected.len:
        if i != j:
          check not expected[j].contains(expected[i])
    # Nothing that was supposed to be refused produced a plaintext.
    check producedPlaintexts.len == 0

## Replaying a real TCG event log reproduces the registers the TPM held
## — and the composite the TPM SIGNED.
##
## ## What this case is worth, and what it is not
##
## The claim under test is the one every other use of an event log rests
## on: that folding the log's digests, in the log's order, from the
## right initial values, lands on the same bytes a TPM arrived at
## independently while the firmware was extending it. If that is true a
## verifier can say *why* a register holds what it holds; if it is false
## the log is decoration.
##
## Three things make this more than a self-check:
##
##   1. **The logs are firmware's, not this codec's.** Both were read
##      off ``binary_bios_measurements`` in a QEMU guest — see
##      ``tcg_event_log_vectors`` for the full capture recipe, the
##      versions, and what the fixtures deliberately do not cover.
##   2. **The expected registers are the TPM's own report of itself**,
##      transcribed from ``/sys/class/tpm/tpm0/pcr-*/*`` in the running
##      guest. They were computed by libtpms, incrementally, at extend
##      time. Nothing replayed them to produce the expectation.
##   3. **All 24 registers of all four banks are asserted**, not just the
##      ones the log touches. The registers a log NEVER mentions are
##      where the reset rule lives, and PCRs 17–22 reset to all-ones
##      rather than to zero. A replay that starts everything at zero
##      agrees about every register a normal boot writes and disagrees
##      about six it does not — so an assertion scoped to the touched
##      registers would be green for a replay that is wrong.
##
## And the headline: for the crypto-agile fixture the replayed registers
## are handed to ``tpm2.pcrComposite`` through the quote's own
## ``TPML_PCR_SELECTION``, and the composite equals the ``pcrDigest``
## inside a ``TPMS_ATTEST`` that this TPM SIGNED and that
## ``tpm2_checkquote`` accepted. That chain — log → replay → composite →
## signed digest — is the whole reason the module exists, and every link
## in it but the replay was produced by somebody else.
##
## ## The EV_NO_ACTION control, and why it is here rather than in the
## ## negative gate
##
## ``EV_NO_ACTION`` entries are not extended. A replay that folds them
## in still parses, still counts right, and produces a register that is
## wrong — the near-miss the module header warns about. Asserting "the
## real log replays correctly" does NOT catch it in these fixtures,
## because the only ``EV_NO_ACTION`` in either one is the agile log's
## own ``Spec ID Event03`` header, which carries a SHA-1 digest and
## would make a folding replay *fail* rather than *differ*.
##
## So this case builds the case that would differ: it splices a
## well-formed ``EV_NO_ACTION`` entry, digests and all, into the real
## log and requires the replayed registers not to move. Its twin — the
## same entry with its type changed to ``EV_ACTION`` — must move them,
## which is what proves the first assertion is not vacuous.
##
## ## Mocking
##
## None. Real logs, a real quote, real digests.

import std/[base64, strutils, unittest]

import nimcrypto/[hash, sha2]

import repro_attest
import ./tcg_event_log_vectors

template checkRegister(cond: bool; alg: TpmAlgId; index: int;
                       got, want: string) =
  ## ``check`` plus the two values, because "expression is false" is
  ## useless when the expression is a 64-byte digest comparison.
  if not cond:
    checkpoint("bank " & $alg & " PCR " & $index & ": the replay produced " &
               got & ", the TPM reported " & want)
  check cond

proc hexOf(s: string): string =
  result = ""
  for c in s: result.add toHex(uint8(c), 2).toLowerAscii

proc le32(v: uint32): string =
  var w = initTpm2Writer("splice")
  w.writeU32Le(v)
  w.bytes

proc le16(v: uint16): string =
  var w = initTpm2Writer("splice")
  w.writeU16Le(v)
  w.bytes

proc agileEntry(pcr: int; eventType: TcgEventType;
                digestByte: char; payload: string): string =
  ## One ``TCG_PCR_EVENT2`` in the exact bank layout the agile fixture's
  ## ``Spec ID Event03`` declares: SHA-1, SHA-256, SHA-384, SHA-512, in
  ## that order. Built here rather than copied from the log so that the
  ## splice is a deliberate, readable structure.
  result = le32(uint32(pcr)) & le32(uint32(eventType)) & le32(4'u32)
  for (alg, size) in [(TpmAlgSha1, 20), (TpmAlgSha256, 32),
                      (TpmAlgSha384, 48), (TpmAlgSha512, 64)]:
    result.add le16(uint16(alg))
    result.add repeat(digestByte, size)
  result.add le32(uint32(payload.len))
  result.add payload

proc spliceAfterFirstEntry(log: string; entry: string): string =
  ## Insert `entry` immediately after the log's first entry, which for
  ## the agile fixture is the ``Spec ID Event03`` header. Parsing the
  ## log to find that boundary rather than hard-coding an offset keeps
  ## the splice correct if the fixture is ever recaptured.
  let parsed = parseEventLog(log)
  doAssert parsed.events.len >= 2
  let boundary = parsed.events[1].wireOffset
  result = log[0 ..< boundary] & entry & log[boundary .. ^1]

suite "TCG event log replay reproduces the registers a TPM held":

  test "the crypto-agile log replays to all 24 registers of all four banks":
    let log = parseEventLog(agileLog())
    check log.format == lfCryptoAgile
    check log.events.len == 32
    check log.specId.specVersionMajor == 2'u8
    check log.specId.uintnSize == 2'u8
    check banks(log) == @[TpmAlgSha1, TpmAlgSha256, TpmAlgSha384, TpmAlgSha512]

    # One row per bank: the algorithm, and the TPM's own report of all
    # 24 of its registers in that bank. All four of this vTPM's banks
    # are ACTIVE, so all four have a hardware anchor.
    let expectations = [
      (TpmAlgSha1, AgilePcrsSha1),
      (TpmAlgSha256, AgilePcrsSha256),
      (TpmAlgSha384, AgilePcrsSha384),
      (TpmAlgSha512, AgilePcrsSha512)]

    # `replayAllBanks` rather than four `replayBank` calls, so the
    # proc a caller actually reaches for is the one under test — and so
    # that it is pinned to return the banks in the order the Spec ID
    # Event declares them rather than in some order of its own.
    let replayed = replayAllBanks(log)
    check replayed.len == expectations.len
    for k, (alg, _) in expectations:
      check replayed[k].alg == alg

    var checkedRegisters = 0
    var extendedRegisters = 0
    for k, (alg, expected) in expectations:
      let bank = replayed[k]
      check bank.alg == alg
      check bank.digestSize == digestSize(alg)
      # 31 of the 32 entries extend; the Spec ID Event03 header does not.
      check bank.extendsApplied == 31
      for i in 0 ..< NumPcrs:
        checkRegister(hexOf(bank.pcrs[i].value) == expected[i],
                      alg, i, hexOf(bank.pcrs[i].value), expected[i])
        inc checkedRegisters
        if bank.pcrs[i].state == prExtended: inc extendedRegisters
    # 4 banks x 24 registers, and 9 extended in each (PCRs 0-7 and 9).
    check checkedRegisters == 96
    check extendedRegisters == 36
    # The SHA-512 bank is the one that pins the LAST digest in every
    # entry's list: a digest-list walk that lost its place would put the
    # right bytes in the first bank and the wrong ones in the last.
    check replayBank(log, TpmAlgSha512).digestSize == 64

  test "the registers the log never touched are at their reset values":
    # This is the assertion that pins the reset rule, and it is worth
    # stating separately from the sweep above because the sweep would
    # still read as "the replay works" if every untouched register
    # happened to be zero. PCRs 17-22 are NOT zero, on a TPM that has
    # simply been started: they are all-ones, and the values below come
    # from the TPM rather than from this codec.
    let log = parseEventLog(agileLog())
    let bank = replayBank(log, TpmAlgSha256)
    for i in [8, 10, 11, 12, 13, 14, 15, 16, 23]:
      check bank.pcrs[i].state == prNeverExtended
      check hexOf(bank.pcrs[i].value) == repeat("00", 32)
      check AgilePcrsSha256[i] == repeat("00", 32)
    for i in 17 .. 22:
      check bank.pcrs[i].state == prNeverExtended
      check hexOf(bank.pcrs[i].value) == repeat("ff", 32)
      check AgilePcrsSha256[i] == repeat("ff", 32)
    for i in [0, 1, 2, 3, 4, 5, 6, 7, 9]:
      check bank.pcrs[i].state == prExtended

  test "the TCG 1.2 log replays to the registers its TPM 1.2 held":
    # A second wire shape entirely: no Spec ID Event, no digest list,
    # a bare 20-byte SHA-1 per entry. A parser that only implements the
    # agile shape cannot read a byte of this.
    let log = parseEventLog(legacyLog())
    check log.format == lfLegacy
    check log.events.len == 15
    check banks(log) == @[TpmAlgSha1]
    let bank = replayBank(log, TpmAlgSha1)
    check bank.extendsApplied == 15
    for i in 0 ..< NumPcrs:
      checkRegister(hexOf(bank.pcrs[i].value) == LegacyPcrsSha1[i],
                    TpmAlgSha1, i, hexOf(bank.pcrs[i].value),
                    LegacyPcrsSha1[i])
    for i in 0 .. 7:
      check bank.pcrs[i].state == prExtended
    for i in 8 ..< NumPcrs:
      check bank.pcrs[i].state == prNeverExtended

  test "the replayed registers reproduce the composite the TPM SIGNED":
    # The chain this module exists for. The selection, the order and the
    # composite's hash all come off the wire inside the quote; the only
    # thing supplied from here is the log.
    let log = parseEventLog(agileLog())
    let q = parseQuote(agileQuoteAttest(), agileQuoteSignature())
    check q.attest.magic == TpmGeneratedValue
    check hexOf(qualifyingData(q)) == AgileQuoteQualifyingHex
    check compositeAlg(q) == TpmAlgSha256

    let selected = selectedPcrs(q.attest.quote.pcrSelect)
    check selected.len == 8
    for i, s in selected:
      check s.bank == TpmAlgSha256
      check s.index == i

    let values = selectedFromReplay(log, q.attest.quote.pcrSelect)
    check values.len == 8
    # Every value handed to the composite is the TPM's own reading of
    # that register, so a disagreement here would be between the replay
    # and the TPM rather than inside this test.
    for v in values:
      check hexOf(v.value) == AgilePcrsSha256[v.index]

    let composite = pcrComposite(compositeAlg(q), q.attest.quote.pcrSelect,
                                 values)
    check hexOf(composite) == hexOf(q.attest.quote.pcrDigest)
    check explainsQuote(log, q)

  test "the pinned attestation key reproduces the pinned AK name":
    # The key and the name are pinned so a LATER reader can re-run
    # `tpm2_checkquote` against these exact bytes. Nothing in this
    # library verifies a signature, so the danger is that they sit here
    # as two constants no test reads — the honest-absence shape: they
    # LOOK like evidence, and a typo in either would redden nothing.
    #
    # This case binds their VALUES to each other, and the bind is the
    # TPM's own naming rule rather than anything this repository chose.
    # A key's name is `nameAlg ‖ H_nameAlg(TPMT_PUBLIC)`. The key is
    # pinned in its PEM `SubjectPublicKeyInfo` encoding — which is what
    # `tpm2_checkquote` consumes, and which is NOT a `TPM2B_PUBLIC`: it
    # carries the public POINT and drops the surrounding `TPMT_PUBLIC`
    # the name is a digest of. But the dropped part is a template, not
    # a secret: an attestation key is a restricted ECDSA/SHA-256 signing
    # key on NIST P-256 with an empty auth policy, and its
    # `objectAttributes` are the fixed set spelled out below. So the
    # `TPMT_PUBLIC` is REBUILT here from the pinned point plus that
    # template, and its SHA-256 must equal the pinned name's digest.
    #
    # That is a real binding and not a shape check: flip one byte of the
    # point, or one byte of the name, and the digests part. It is also
    # the check that says the two constants describe ONE key — a name
    # pinned beside an unrelated key would otherwise never be noticed.
    #
    # What it still does NOT do: verify the SIGNATURE. Nothing here
    # proves this key is the key that signed the attest; only an ECDSA
    # check does that, and this library performs none. `tpm2_checkquote`
    # was run against these exact bytes out of band and accepted them.
    let pem = agileQuoteAkPublic()
    check pem.startsWith("-----BEGIN PUBLIC KEY-----")
    check pem.strip(leading = false).endsWith("-----END PUBLIC KEY-----")
    var b64 = ""
    for line in pem.splitLines():
      if line.len > 0 and not line.startsWith("-----"): b64.add line
    let der = base64.decode(b64)

    # SubjectPublicKeyInfo, decoded rather than compared as an opaque
    # blob: SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 },
    # BIT STRING { 00, 04, X, Y } }. A placeholder, a truncation, a
    # different curve or an RSA key all fail here.
    const EcP256SpkiPrefix =
      "\x30\x59\x30\x13" &
      "\x06\x07\x2A\x86\x48\xCE\x3D\x02\x01" &   # id-ecPublicKey
      "\x06\x08\x2A\x86\x48\xCE\x3D\x03\x01\x07" &  # prime256v1
      "\x03\x42\x00"                              # BIT STRING, 0 unused
    check der.len == EcP256SpkiPrefix.len + 65
    check der[0 ..< EcP256SpkiPrefix.len] == EcP256SpkiPrefix
    check uint8(der[EcP256SpkiPrefix.len]) == 0x04'u8  # uncompressed point
    # A P-256 point is two 32-byte coordinates, and neither is zero —
    # the check that a zeroed-out placeholder would fail.
    let x = der[EcP256SpkiPrefix.len + 1 ..< EcP256SpkiPrefix.len + 33]
    let y = der[EcP256SpkiPrefix.len + 33 ..< EcP256SpkiPrefix.len + 65]
    check x.len == 32
    check y.len == 32
    check x != repeat('\0', 32)
    check y != repeat('\0', 32)

    # The NAME, in a TPM's own spelling: two bytes of algorithm and then
    # that algorithm's digest, consumed EXACTLY.
    let name = agileQuoteAkName()
    var nr = initTpm2Reader(name, "TPM2B_NAME body")
    check nr.readAlg("nameAlg") == TpmAlgSha256
    let nameDigest = nr.readBytes("digest", digestSize(TpmAlgSha256))
    nr.finish()

    # Rebuild the `TPMT_PUBLIC` a `tpm2_createak -G ecc` produces, from
    # the point above and the template every such key shares, and take
    # its name. The template is written out field by field rather than
    # pasted as a blob so that a reader can see which key this claims to
    # be: an ECC key, SHA-256 named, with no auth policy, no symmetric
    # algorithm, an ECDSA/SHA-256 scheme over NIST P-256, and no KDF.
    const
      TpmAlgEcc = 0x0023'u16
      TpmEccNistP256 = 0x0003'u16
      # fixedTPM | fixedParent | sensitiveDataOrigin | userWithAuth |
      # restricted | sign — i.e. a key the TPM will only ever use to
      # sign its own structures, which is what makes it an AK.
      AkObjectAttributes = 0x00050072'u32
    var pw = initTpm2Writer("TPMT_PUBLIC")
    pw.writeU16(TpmAlgEcc)
    pw.writeU16(uint16(TpmAlgSha256))
    pw.writeU32(AkObjectAttributes)
    pw.writeTpm2b("authPolicy", "", MaxDigestBytes)
    pw.writeU16(uint16(TpmAlgNull))       # symmetric: none
    pw.writeU16(uint16(TpmAlgEcdsa))      # scheme
    pw.writeU16(uint16(TpmAlgSha256))     # scheme.details.hashAlg
    pw.writeU16(TpmEccNistP256)
    pw.writeU16(uint16(TpmAlgNull))       # kdf: none
    pw.writeTpm2b("unique.x", x, MaxEccParamBytes)
    pw.writeTpm2b("unique.y", y, MaxEccParamBytes)
    let rebuilt = sha256.digest(pw.bytes)
    var rebuiltName = newString(digestSize(TpmAlgSha256))
    for i in 0 ..< rebuiltName.len: rebuiltName[i] = char(rebuilt.data[i])
    if rebuiltName != nameDigest:
      checkpoint("the TPMT_PUBLIC rebuilt from the pinned key names " &
                 hexOf(rebuiltName) & ", but the pinned AK name is " &
                 hexOf(nameDigest))
    check rebuiltName == nameDigest

    # …and the signed attest names a key of that shape, and a DIFFERENT
    # value, because `qualifiedSigner` is the QUALIFIED name. Asserting
    # the inequality is the point: a reader who expects equality reads a
    # correct fixture as a broken one.
    let q = parseQuote(agileQuoteAttest(), agileQuoteSignature())
    check q.attest.qualifiedSigner.len == name.len
    check q.attest.qualifiedSigner[0 ..< 2] == name[0 ..< 2]
    check q.attest.qualifiedSigner != name

    # The signature is the shape a P-256 key makes, and its hash is the
    # one the composite above was taken under.
    check q.signature.sigAlg == TpmAlgEcdsa
    check q.signature.hashAlg == TpmAlgSha256
    check q.signature.kind == tskEcc
    check q.signature.signatureR.len == 32
    check q.signature.signatureS.len == 32

  test "an EV_NO_ACTION entry spliced into the log does not move a register":
    # The near-miss control. The spliced entry is structurally
    # indistinguishable from a measurement — right bank order, right
    # digest lengths, a payload — and differs only in its type.
    let base = parseEventLog(agileLog())
    let baseline = replayBank(base, TpmAlgSha256)

    let inert = spliceAfterFirstEntry(
      agileLog(), agileEntry(0, EvNoAction, '\x5A', "inert"))
    let withInert = parseEventLog(inert)
    check withInert.events.len == base.events.len + 1
    let replayed = replayBank(withInert, TpmAlgSha256)
    check replayed.extendsApplied == baseline.extendsApplied
    for i in 0 ..< NumPcrs:
      check hexOf(replayed.pcrs[i].value) == hexOf(baseline.pcrs[i].value)
    for i in 0 ..< NumPcrs:
      check hexOf(replayed.pcrs[i].value) == AgilePcrsSha256[i]

    # …and the same entry as a MEASUREMENT does move it, which is what
    # says the assertion above is about EV_NO_ACTION rather than about
    # the splice being ignored, mis-parsed or dropped.
    let active = spliceAfterFirstEntry(
      agileLog(), agileEntry(0, EvAction, '\x5A', "inert"))
    let withActive = parseEventLog(active)
    check withActive.events.len == base.events.len + 1
    let moved = replayBank(withActive, TpmAlgSha256)
    check moved.extendsApplied == baseline.extendsApplied + 1
    check hexOf(moved.pcrs[0].value) != hexOf(baseline.pcrs[0].value)
    check hexOf(moved.pcrs[0].value) != AgilePcrsSha256[0]
    # Only PCR 0 moves: the splice named PCR 0 and nothing else.
    for i in 1 ..< NumPcrs:
      check hexOf(moved.pcrs[i].value) == hexOf(baseline.pcrs[i].value)

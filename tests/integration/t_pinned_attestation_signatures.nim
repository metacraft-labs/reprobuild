## Which pinned attestation signatures can be checked, and which cannot.
##
## ## The defect this gate closes
##
## Three measured boots were pinned into this repository as evidence —
## an attestation structure, a signature over it, and the event log the
## firmware wrote — and **no attestation public key was pinned with
## any of them**. A signature with no key is not weak evidence, it is
## no evidence: there is nothing it can be checked against, by this
## build or by anybody who ever reads the file. Every gate that rests on
## those bytes rests on the provenance note beside them.
##
## This gate makes that situation VISIBLE and BOUNDED rather than
## implicit:
##
##   * every pinned boot appears in ``PinnedBootEvidenceSet``, so a
##     boot cannot be added without declaring whether its key was kept;
##   * a boot that declares a key has that signature VERIFIED under it,
##     by value;
##   * a boot that declares none has to carry the recovered candidate
##     keys that demonstrate why one signature does not determine one
##     key — and this gate requires every candidate to verify, which is
##     exactly the ambiguity being claimed.
##
## ## What this gate is NOT
##
## It is not signature verification in the product. Neither
## ``repro_attest`` nor ``repro_attest_verify`` performs a public-key
## operation, and nothing here changes that: the verification below is
## done by a test, through ``repro_peer_cache``'s ECDSA-P256 surface,
## out of band of the libraries under test. A verdict still rests on the
## log explaining the quote and not on who signed it, and the verdict
## still says so. Reading this gate as "the verifier checks signatures"
## would be exactly the overstatement it exists to prevent.
##
## ## Mocking
##
## None. Every byte verified here was produced by firmware or by a TPM.

import std/[base64, strutils, unittest]

import repro_attest
import repro_peer_cache/auth

include ./attested_boot_vectors
include ./tcg_event_log_vectors

const PinnedBootVectorsSource = staticRead("attested_boot_vectors.nim")
  ## The vector file's own text, read at COMPILE TIME.
  ##
  ## ``PinnedBootEvidenceSet`` is a hand-kept list, and a hand-kept list
  ## is a check that needs a defeating mutation of its own. Measured
  ## rather than assumed: adding a fourth keyless boot's constants to
  ## that file and NOT adding a row for it left every case below green,
  ## so "a boot cannot be pinned without declaring whether its key was
  ## kept" was not true of the file, only of the list. Counting the
  ## declarations is what ties the two together.
  ##
  ## What this does NOT cover, stated because a source scan is the
  ## easiest kind of check to over-read: it counts declarations, so it
  ## catches a boot pinned OUTSIDE the set, and it cannot tell which
  ## constant a given row names. The distinctness check below is what
  ## stops two rows from sharing one constant while a third sits unused.

proc declaredAttestConstants(src: string): seq[string] =
  ## Every ``…AttestHex*`` the vector file declares. Comment lines are
  ## dropped first, so the count cannot be moved by text that does not
  ## compile; a trailing comment cannot satisfy it either, because what
  ## is matched is the left-hand side of a binding rather than a
  ## substring of the line.
  result = @[]
  for raw in src.splitLines():
    let line = raw.strip()
    if line.startsWith("#"): continue
    let eq = line.find('=')
    if eq < 0: continue
    let lhs = line[0 ..< eq].strip()
    if not lhs.endsWith("AttestHex*"): continue
    result.add lhs[0 ..< lhs.len - 1]

proc unhexBytes(h: string): string =
  doAssert h.len mod 2 == 0
  result = newString(h.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(h[2 * i .. 2 * i + 1]))

proc pointOf(hex: string): PublicKeyBytes =
  ## A 65-byte uncompressed ECDSA-P256 point, as the verifier wants it.
  let raw = unhexBytes(hex)
  doAssert raw.len == P256PubLen, "a P-256 point is " & $P256PubLen &
    " bytes, got " & $raw.len
  for i in 0 ..< P256PubLen: result[i] = byte(raw[i])

proc rawSignature(sigHex: string): SignatureBytes =
  ## The ``r ‖ s`` an ECDSA verifier consumes, taken out of the TPM's
  ## own ``TPMT_SIGNATURE`` by the codec rather than by slicing at
  ## offsets this test chose. A hand-written offset would keep working
  ## if the structure changed shape underneath it.
  let sig = parseSignature(unhexBytes(sigHex))
  doAssert sig.sigAlg == TpmAlgEcdsa
  doAssert sig.kind == tskEcc
  doAssert sig.hashAlg == TpmAlgSha256
  doAssert sig.signatureR.len == 32
  doAssert sig.signatureS.len == 32
  for i in 0 ..< 32:
    result[i] = byte(sig.signatureR[i])
    result[32 + i] = byte(sig.signatureS[i])

proc verifies(pointHex, attestHex, sigHex: string): bool =
  ## Does this signature check out over THESE attestation bytes under
  ## THIS key? The message is the attestation structure itself; the
  ## verifier hashes it with SHA-256, which is the hash the signature's
  ## own ``TPMT_SIGNATURE`` names and which ``rawSignature`` asserts.
  let msg = unhexBytes(attestHex)
  var bytes = newSeq[byte](msg.len)
  for i in 0 ..< msg.len: bytes[i] = byte(msg[i])
  verifySignature(pointOf(pointHex), bytes, rawSignature(sigHex))

proc pointFromSpkiPem(pem: string): string =
  ## The 65-byte uncompressed point out of a PEM
  ## ``SubjectPublicKeyInfo``, as hex. The prefix is decoded rather than
  ## skipped by a byte count, so an RSA key, a different curve or a
  ## truncation is refused instead of silently producing 65 bytes of
  ## something else.
  const EcP256SpkiPrefix =
    "\x30\x59\x30\x13" &
    "\x06\x07\x2A\x86\x48\xCE\x3D\x02\x01" &      # id-ecPublicKey
    "\x06\x08\x2A\x86\x48\xCE\x3D\x03\x01\x07" &  # prime256v1
    "\x03\x42\x00"                                # BIT STRING, 0 unused
  var b64 = ""
  for line in pem.splitLines():
    if line.len > 0 and not line.startsWith("-----"): b64.add line
  let der = base64.decode(b64)
  doAssert der.len == EcP256SpkiPrefix.len + 65, "not a P-256 SPKI"
  doAssert der[0 ..< EcP256SpkiPrefix.len] == EcP256SpkiPrefix
  result = ""
  for c in der[EcP256SpkiPrefix.len .. ^1]:
    result.add toHex(int(uint8(c)), 2).toLowerAscii()

proc flipOneByte(hex: string; at: int): string =
  ## One byte of a hex constant, xor 0x01 — the smallest edit that is
  ## still an edit.
  var raw = unhexBytes(hex)
  raw[at] = char(uint8(raw[at]) xor 0x01'u8)
  result = ""
  for c in raw: result.add toHex(int(uint8(c)), 2).toLowerAscii()

suite "the pinned attestation signatures, checked against their keys":

  test "t_pinned_signature_of_the_boot_whose_key_was_kept_verifies":
    ## THE ONE PINNED SIGNATURE ANYBODY CAN CHECK.
    ##
    ## Its key was kept with it, so this is a public-key operation over
    ## real bytes and not a statement about provenance.
    check verifies(KeyedBootAkPointHex, KeyedBootAttestHex,
                   KeyedBootSignatureHex)

    # And it had somewhere to fail, on each of the three inputs
    # independently. A verifier that returned true unconditionally
    # passes the line above and none of these.
    check not verifies(flipOneByte(KeyedBootAkPointHex, 40),
                       KeyedBootAttestHex, KeyedBootSignatureHex)
    check not verifies(KeyedBootAkPointHex,
                       flipOneByte(KeyedBootAttestHex, 40),
                       KeyedBootSignatureHex)
    check not verifies(KeyedBootAkPointHex, KeyedBootAttestHex,
                       flipOneByte(KeyedBootSignatureHex, 10))
    # The last byte too, because a verifier that ignored a trailing
    # scalar would survive a flip in the first half of the signature.
    check not verifies(KeyedBootAkPointHex, KeyedBootAttestHex,
                       flipOneByte(KeyedBootSignatureHex, 71))

  test "t_pinned_signature_key_is_the_key_the_tpm_named":
    ## The pinned key is not a key somebody put beside the bytes: it is
    ## the key the TPM itself named, and the three artifacts pinned for
    ## it agree BY VALUE through the TPM's own naming rule.
    ##
    ##   name = nameAlg ‖ H_nameAlg(TPMT_PUBLIC)
    ##
    ## so the name's digest must be the SHA-256 of the public area's
    ## body, and the public area must carry the same point the
    ## signature verifies under. Flip a byte of any of the three and
    ## this case reddens.
    let publicArea = unhexBytes(KeyedBootAkPublicAreaHex)
    # TPM2B_PUBLIC: a two-byte size and then exactly that many bytes.
    check publicArea.len > 2
    let declared = (int(uint8(publicArea[0])) shl 8) or
                   int(uint8(publicArea[1]))
    let body = publicArea[2 .. ^1]
    check declared == body.len

    let name = unhexBytes(KeyedBootAkNameHex)
    # TPM2B_NAME body: two bytes of algorithm, then that algorithm's
    # digest, consumed exactly.
    check name.len == 2 + 32
    check ((int(uint8(name[0])) shl 8) or int(uint8(name[1]))) ==
      int(uint16(TpmAlgSha256))
    var digest = ""
    for c in name[2 .. ^1]: digest.add toHex(int(uint8(c)), 2).toLowerAscii()
    check sha256Hex(body) == digest

    # And the public area really carries the point the signature
    # verifies under: a TPMT_PUBLIC for an ECC key ends with the two
    # 32-byte coordinates, each in its own TPM2B.
    let point = unhexBytes(KeyedBootAkPointHex)
    check point.len == 65
    check uint8(point[0]) == 0x04'u8
    let x = point[1 .. 32]
    let y = point[33 .. 64]
    check body.find(x) >= 0
    check body.find(y) >= 0
    check body.find(x) < body.find(y)   # X before Y, as TPMS_ECC_POINT has it

    # The key is a RESTRICTED signing key — an attestation key rather
    # than a general-purpose one. `objectAttributes` sits at offset 4 of
    # the public area body (type, nameAlg, then the attributes word).
    var attrs = 0'u32
    for i in 0 ..< 4: attrs = (attrs shl 8) or uint32(uint8(body[4 + i]))
    check attrs == 0x00050072'u32

  test "t_pinned_boots_without_a_key_say_so_and_show_why":
    ## THE HONEST-ABSENCE HALF.
    ##
    ## Three boots carry no key. Rather than leave that as a sentence in
    ## a header, each carries the candidate keys that recovery yields
    ## from its OWN (attest, signature) pair, and this case requires
    ## every one of them to verify. That is the ambiguity in bytes: more
    ## than one key satisfies the signature, so the signature does not
    ## name one.
    var keyed = 0
    var keyless = 0
    for b in PinnedBootEvidenceSet:
      checkpoint(b.name)
      # Exactly one of "has a key" and "explains why it has none".
      check (b.akPointHex.len == 0) == (b.keyAbsenceReason.len > 0)
      # The row is about a boot that is really pinned here.
      check b.attestHex.len == 177 * 2
      check b.signatureHex.len == 72 * 2

      if b.akPointHex.len > 0:
        keyed.inc
        check b.recoveredPointsHex.len == 0
        check verifies(b.akPointHex, b.attestHex, b.signatureHex)
      else:
        keyless.inc
        check b.keyAbsenceReason == UnrecoverableKeyReason
        # More than one candidate, and EVERY one of them verifies.
        check b.recoveredPointsHex.len >= 2
        for cand in b.recoveredPointsHex:
          check verifies(cand, b.attestHex, b.signatureHex)
        # They really are different keys — a list of one key repeated
        # would satisfy the count and demonstrate nothing.
        for i in 0 ..< b.recoveredPointsHex.len:
          for j in i + 1 ..< b.recoveredPointsHex.len:
            check b.recoveredPointsHex[i] != b.recoveredPointsHex[j]

    # The shape of the file, pinned: four boots, three of them keyless.
    # If a later capture pins its key, this count moves and whoever
    # moves it has to look at this case.
    check keyed == 1
    check keyless == 3
    check keyed + keyless == PinnedBootEvidenceSet.len

    # And the set really is EVERY pinned boot, rather than the ones
    # somebody remembered to add. Without this the three checks above
    # are about the list and say nothing about the file: a fifth boot's
    # bytes could sit beside them, tested by nothing, and every case
    # here would stay green — measured, not supposed.
    let declared = declaredAttestConstants(PinnedBootVectorsSource)
    check declared.len == PinnedBootEvidenceSet.len
    checkpoint(declared.join(", "))
    # Two rows naming one constant would satisfy the count while a
    # third constant went untested, so the rows are required to be
    # about different bytes.
    for i in 0 ..< PinnedBootEvidenceSet.len:
      for j in i + 1 ..< PinnedBootEvidenceSet.len:
        check PinnedBootEvidenceSet[i].attestHex !=
          PinnedBootEvidenceSet[j].attestHex

  test "t_pinned_signatures_do_not_verify_under_another_boot_s_key":
    ## "It verifies" must mean "under ITS OWN key".
    ##
    ## With one key in the file, a gate cannot tell "this signature
    ## verifies under this key" apart from "this signature verifies".
    ## Every other key material in the file is used here as a negative:
    ## the kept key against the other boots' signatures, and every
    ## recovered candidate against the kept boot's signature.
    ##
    ## The positive side is asserted IN THIS CASE as well. A negative
    ## control that only ever exercises refusal is satisfied by a
    ## verifier that refuses everything, and would then be a case about
    ## nothing.
    check verifies(KeyedBootAkPointHex, KeyedBootAttestHex,
                   KeyedBootSignatureHex)

    for b in PinnedBootEvidenceSet:
      if b.akPointHex.len > 0: continue
      checkpoint(b.name)
      # This boot's OWN candidates do verify it — the positive half, per
      # row, so the refusals below are a disagreement and not a verifier
      # that says no to everything.
      for cand in b.recoveredPointsHex:
        check verifies(cand, b.attestHex, b.signatureHex)
      # The kept key does not verify this boot's signature ...
      check not verifies(KeyedBootAkPointHex, b.attestHex, b.signatureHex)
      # ... and this boot's own candidates do not verify the kept
      # boot's signature.
      for cand in b.recoveredPointsHex:
        check not verifies(cand, KeyedBootAttestHex, KeyedBootSignatureHex)
        # Nor any other keyless boot's signature.
        for other in PinnedBootEvidenceSet:
          if other.name == b.name or other.akPointHex.len > 0: continue
          check not verifies(cand, other.attestHex, other.signatureHex)

  test "t_the_kept_key_s_boot_replays_to_the_register_it_signed":
    ## The key is only worth pinning if the boot it belongs to is a
    ## whole boot. This joins the kept key's boot the way the other
    ## three are joined — log replays to the signed register digest,
    ## register 11 out of that replay equals the value computed from the
    ## IMAGE's own bytes — so the one signature this build can check is
    ## a signature over a chain and not over an isolated structure.
    let ev = Tpm2Evidence(
      attestBytes: unhexBytes(KeyedBootAttestHex),
      signatureBytes: unhexBytes(KeyedBootSignatureHex),
      eventLogBytes: unhexBytes(KeyedBootEventLogHex))
    check ev.eventLogBytes.len == KeyedBootEventLogBytes

    let q = tpm2EvidenceQuote(ev)
    let log = tpm2EvidenceLog(ev)
    check log.events.len == KeyedBootEventLogEntries
    check explainsQuote(log, q)

    var covers = false
    for s in selectedPcrs(q.attest.quote.pcrSelect):
      if s.bank == TpmAlgSha256 and
         s.index == Pcr11: covers = true
    check covers

    let bank = replayBank(log, TpmAlgSha256)
    check bank.pcrs[Pcr11].state != prNeverExtended
    check bytesToHex(pcrValue(bank, Pcr11)) ==
      KeyedBootUkiPcr11
    check replayEventLogTemplate(KeyedBootUkiTemplate) == KeyedBootUkiPcr11
    # And it answered the same nonce as the other three, so the four
    # are one experiment rather than four unrelated captures.
    check bytesToHex(qualifyingData(q)) == AttestedBootQualifyingHex

  test "t_the_event_log_fixture_s_quote_verifies_under_its_pinned_key":
    ## THE SECOND KEY, and it is from a different capture entirely.
    ##
    ## The event-log vectors pin an attestation key beside their quote,
    ## and until now nothing in this repository checked the two against
    ## each other — the check was run out of band with a command-line
    ## tool and only its outcome was written down. It is run here.
    ##
    ## A second key also makes the case above mean what it says. With
    ## one key in the tree, "this signature verifies under this key" and
    ## "this signature verifies" are the same sentence; with two, each
    ## key has to be the right one.
    let agilePoint = pointFromSpkiPem(agileQuoteAkPublic())
    check verifies(agilePoint, AgileQuoteAttestHex, AgileQuoteSignatureHex)

    # It had somewhere to fail, on each input independently.
    check not verifies(flipOneByte(agilePoint, 40), AgileQuoteAttestHex,
                       AgileQuoteSignatureHex)
    check not verifies(agilePoint, flipOneByte(AgileQuoteAttestHex, 40),
                       AgileQuoteSignatureHex)
    check not verifies(agilePoint, AgileQuoteAttestHex,
                       flipOneByte(AgileQuoteSignatureHex, 10))

    # The two keys are different keys, and neither speaks for the
    # other's boot. This is what makes "under ITS OWN key" a claim.
    check agilePoint != KeyedBootAkPointHex
    check not verifies(agilePoint, KeyedBootAttestHex, KeyedBootSignatureHex)
    check not verifies(KeyedBootAkPointHex, AgileQuoteAttestHex,
                       AgileQuoteSignatureHex)

    # And the pinned NAME is this key's name, by the TPM's own naming
    # rule — so the key that verifies the signature is the key the
    # fixture's name constant describes, rather than a second key
    # sitting beside an unrelated name.
    check agileQuoteAkName().len == 2 + 32
    var namedDigest = ""
    for c in agileQuoteAkName()[2 .. ^1]:
      namedDigest.add toHex(int(uint8(c)), 2).toLowerAscii()
    # The public area is a template plus the point; rebuilt here from
    # the same fixed attestation-key template the kept boot's REAL
    # TPM2B_PUBLIC carries, which is read out of it rather than typed
    # in again.
    let keptBody = unhexBytes(KeyedBootAkPublicAreaHex)[2 .. ^1]
    let templatePrefix = keptBody[0 ..< keptBody.find(
      unhexBytes(KeyedBootAkPointHex)[1 .. 32]) - 2]
    let agileRaw = unhexBytes(agilePoint)
    let rebuilt = templatePrefix & "\x00\x20" & agileRaw[1 .. 32] &
      "\x00\x20" & agileRaw[33 .. 64]
    check sha256Hex(rebuilt) == namedDigest

  test "t_the_machine_says_which_sections_it_measured":
    ## SIX, not five — and the machine is the one saying so.
    ##
    ## A stub measures each section twice, the NAME and then the
    ## CONTENT, and the name event's payload is the section's name in
    ## UTF-16LE. So the firmware's own log states, in bytes this
    ## repository did not write, exactly which sections were measured
    ## and in what order. Five of them an assembler appends; ``.sbat``
    ## the stub brings itself. A document that lists only the appended
    ## ones describes an image no machine can produce.
    ##
    ## The stub labels BOTH events of a pair with the section's name —
    ## they differ in their digests, not in their payloads — so the name
    ## appears twice per section and the pairing is checked rather than
    ## collapsed away.
    let log = tpm2EvidenceLog(Tpm2Evidence(
      attestBytes: unhexBytes(KeyedBootAttestHex),
      signatureBytes: unhexBytes(KeyedBootSignatureHex),
      eventLogBytes: unhexBytes(KeyedBootEventLogHex)))

    var names: seq[string] = @[]
    var pcr11Events = 0
    for e in log.events:
      if e.pcrIndex != Pcr11 or e.eventType != EvIpl: continue
      pcr11Events.inc
      # UTF-16LE, NUL-terminated. Decoded rather than matched as a
      # substring, so a content event that happened to contain the
      # bytes of a name cannot be counted as one.
      if e.data.len < 4 or e.data.len mod 2 != 0: continue
      var decoded = ""
      var isName = true
      var i = 0
      while i < e.data.len:
        let lo = uint8(e.data[i])
        let hi = uint8(e.data[i + 1])
        if hi != 0: isName = false; break
        if lo == 0:
          if i != e.data.len - 2: isName = false
          break
        decoded.add char(lo)
        i += 2
      if isName and decoded.len > 0 and decoded[0] == '.':
        names.add decoded

    check pcr11Events == KeyedBootSectionNameEvents
    check names.len == pcr11Events
    # Each section contributes exactly two consecutive events, and the
    # deduplicated sequence is the order pinned beside these bytes.
    var sections: seq[string] = @[]
    var i = 0
    while i + 1 < names.len:
      check names[i] == names[i + 1]
      sections.add names[i]
      i += 2
    check sections == @KeyedBootMeasuredSections
    check sections.len * 2 == pcr11Events   # a name and a content event each
    # The section an assembler does not append is in there, which is the
    # whole finding.
    check ".sbat" in sections
    # And the template pinned beside these bytes names the same six, so
    # the replay above and the machine's own account agree.
    for name in sections:
      check (";" & name & "=") in KeyedBootUkiTemplate
    check KeyedBootUkiTemplate.count(';') == sections.len + 1

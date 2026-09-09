## The `reproos.attestation-report.v1` envelope and the 64-byte binding
## discipline underneath it.
##
## ## What each case is worth
##
## `t_report_data_vectors` pins the bytes. A hash construction that agrees
## with itself proves nothing — it will produce a stable wrong answer
## forever — so none of the digests below came out of this code. They come
## from two other implementations of SHA-512 over byte strings written out
## here in full:
##
##   * Python 3.13's `hashlib` (OpenSSL), and
##   * coreutils 9.10's `sha512sum`,
##
## and the primitive itself is pinned against the published FIPS 180-4
## vectors for `"abc"` and the empty string, so a broken SHA-512 cannot be
## hidden by a construction that consistently mis-uses it. Every vector is
## regenerable from this file alone; the commands are in the comment beside
## them. The PREIMAGES are pinned too, not only the digests: a framing that
## is wrong but happens to agree on one digest is then visible instead of
## merely improbable.
##
## `t_report_data_domain_separation` is the case that justifies the framing.
## It proves two different things. The easy half is that the purpose is
## really inside the hash, so one challenge answered for two protocols is
## two different sets of bytes. The hard half is that the boundaries
## between the variable-length parts are unambiguous — and it proves this
## by CONSTRUCTING the collision that a plain concatenation admits and
## showing that the framed construction separates exactly those two inputs.
## A test that only asserted "different inputs differ" would pass against
## the ambiguous construction too, which is the whole point.
##
## `t_report_envelope_roundtrip_and_reject` is the document. A report is
## read by something about to decide whether to hand over a secret, so
## every refusal is exercised, and the good document is parsed at the end
## of the block so the refusals are shown to be discriminating rather than
## universal. Two of its checks are about what is NOT refused: a timestamp
## in 1970 and one in 3000 are both accepted, because a report is not stale
## by virtue of its own claim about the clock — freshness comes from the
## challenge, and a challenge below 128 bits IS refused in the same block.
##
## ## Mocking
##
## None. The evidence blobs below are opaque byte strings, which is what
## the envelope treats evidence as; nothing here stands in for a hardware
## root, and nothing here claims to verify one.

import std/[json, options, strutils, unittest]

import repro_attest

# ---------------------------------------------------------------------
# The primitive, pinned against FIPS 180-4.
# ---------------------------------------------------------------------

const
  Fips180Abc =
    "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a" &
    "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
  Fips180Empty =
    "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce" &
    "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"

# ---------------------------------------------------------------------
# Inputs for the pinned vectors. Written as hex so that anyone can
# reproduce every digest below from this file and nothing else:
#
#   python3 - <<'EOF'
#   import hashlib, struct
#   TAG = b"ReproOS-ATT-v1"
#   def preimage(purpose, challenge, pub):
#       p = purpose.encode()
#       return (TAG + struct.pack(">I", len(p)) + p
#                   + struct.pack(">I", len(challenge)) + challenge
#                   + struct.pack(">I", len(pub)) + pub)
#   pre = preimage("attest", bytes.fromhex("000102030405060708090a0b0c0d0e0f"), b"")
#   print(pre.hex()); print(hashlib.sha512(pre).hexdigest())
#   EOF
#
# and, with a third implementation:
#
#   printf '<the preimage hex>' \
#     | python3 -c 'import sys,binascii;sys.stdout.buffer.write(binascii.unhexlify(sys.stdin.read()))' \
#     | sha512sum
# ---------------------------------------------------------------------

const
  ChallengeMin = "000102030405060708090a0b0c0d0e0f"
    ## Sixteen bytes: exactly the floor the discipline allows.
  ChallengeLong =
    "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f"
  EphemeralPub =
    "e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"

  # V1 — attest, minimum-length challenge, no key.
  V1Preimage =
    "526570726f4f532d4154542d763100000006617474657374000000100001020304" &
    "05060708090a0b0c0d0e0f00000000"
  V1ReportData =
    "9e4912ac30625917530cae81518a4f56409cee48df9bdac662c7092ab9576cd9" &
    "fee089b77299317bffc5f17937c8d316c4b8fcd8e76cb0941601e10143027672"

  # V2 — attest, 32-byte challenge, no key.
  V2ReportData =
    "5733694cdee04c53b8e8596a9f88fae10c541651c5a1a62eee411c1cd0940344" &
    "0ceed24983b85f28a67716baf73477b8b6e55fe4bdea0d173d43af3ceebb42ea"

  # V3 — key-agreement, minimum-length challenge, 32-byte key.
  V3Preimage =
    "526570726f4f532d4154542d76310000000d6b65792d61677265656d656e74000000" &
    "10000102030405060708090a0b0c0d0e0f00000020e0e1e2e3e4e5e6e7e8e9eaebec" &
    "edeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"
  V3ReportData =
    "ce7dc68c4ee8bcdbd2d1c59441996e9a1aa6385e9c5d14a8b1e733b7c1c17248" &
    "0a859acdb4b5c14b4603d353cebea8a0c35196d8acac1a71324d504a77d996b9"

  # V4 — key-agreement, 32-byte challenge, 32-byte key.
  V4ReportData =
    "4923659d87b3a6fa4c2ae6d209fc48621b3008e8ac44b9a5f50ea7f88e251961" &
    "20695d282137c56e4943477fbaafa0164b7a47ab7e0d5afcffac62289ab45a85"

  # V5 and V6 are the two combinations the discipline REFUSES: a key under
  # `attest`, and a key agreement with no key. They are pinned anyway,
  # because the construction is total and a later reader must be able to
  # tell "this combination is refused by policy" from "this combination
  # hashes to something else". The refusals themselves are checked below.
  V5ReportData =
    "20b2fbce64db7b0fc4d5ba1caf85750de373dd378e0f12f9551005fd624ecbb9" &
    "1f0ecc7bc181d32b2ea44c1b0b39ed36a187dcf3e284ecf62db667766bcc12d0"
  V6ReportData =
    "fbef3ac447107897bf654ecd663d904961e206d14c07fb28301b6c3f96ba71f3" &
    "eee4e2ab077708c17e2f19b48c02cbde0ef44f7902ce2140a4503ce3c12415c1"

# ---------------------------------------------------------------------
# Envelope fixtures
# ---------------------------------------------------------------------

const
  DemoEvidence = "OPAQUE-BACKEND-NATIVE-EVIDENCE-BYTES"
  DemoTimestamp = "2026-09-09T11:22:33Z"

proc demoClaims(): UnverifiedClaims =
  UnverifiedClaims(
    unverifiedGeneration: "reproos-gen-42",
    unverifiedConfigFingerprint: "reproos-image-v1:a1b2c3",
    unverifiedVerityRootHash: sha512Hex("a-root-hash")[0 .. 63])

proc demoReport(backend = abMock;
                purpose = bpAttest;
                challenge = ChallengeLong;
                certificates = none(seq[string])): AttestationReport =
  attestationReport(backend, DemoTimestamp, challenge,
    ReportBindings(purpose: purpose,
      ephemeralPub: (if purpose == bpKeyAgreement: EphemeralPub else: "")),
    DemoEvidence, demoClaims(), certificates)

proc mutated(base: string; edit: proc (doc: JsonNode)): string =
  ## A valid document with one thing changed. Every refusal below is a
  ## one-edit distance from a document that parses, so nothing passes
  ## because it was malformed in some second, unnoticed way.
  let doc = parseJson(base)
  edit(doc)
  $doc

suite "attestation report envelope and binding discipline":

  test "t_report_data_vectors":
    # (a) The primitive, against the published FIPS 180-4 vectors. If this
    #     fails, nothing below means anything.
    check sha512Hex("abc") == Fips180Abc
    check sha512Hex("") == Fips180Empty

    # (b) The framing, pinned as bytes rather than only as a digest. Two
    #     preimages are written out in full above; a construction that
    #     ordered or prefixed the parts differently would produce the
    #     right length and the wrong bytes, and this is what sees that.
    check bytesToHex(bindingPreimage(bpAttest,
      hexToBytes("challenge", ChallengeMin), "")) == V1Preimage
    check bytesToHex(bindingPreimage(bpKeyAgreement,
      hexToBytes("challenge", ChallengeMin),
      hexToBytes("key", EphemeralPub))) == V3Preimage

    # (c) The four vectors the discipline actually produces — each purpose,
    #     with and without an ephemeral key, at the floor challenge length
    #     and at a longer one. Taken through `reportDataHexFor`, which is
    #     the entry point every backend driver uses, so the vectors pin the
    #     shipped path and not a private helper.
    let attestBindings = ReportBindings(purpose: bpAttest, ephemeralPub: "")
    let kaBindings = ReportBindings(purpose: bpKeyAgreement,
                                    ephemeralPub: EphemeralPub)
    check reportDataHexFor(attestBindings, ChallengeMin) == V1ReportData
    check reportDataHexFor(attestBindings, ChallengeLong) == V2ReportData
    check reportDataHexFor(kaBindings, ChallengeMin) == V3ReportData
    check reportDataHexFor(kaBindings, ChallengeLong) == V4ReportData

    # (d) The same four through the raw construction, which takes bytes
    #     rather than hex. The two paths must not be able to drift.
    check reportDataHex(bpAttest, hexToBytes("c", ChallengeMin), "") ==
      V1ReportData
    check reportDataHex(bpKeyAgreement, hexToBytes("c", ChallengeLong),
      hexToBytes("k", EphemeralPub)) == V4ReportData

    # (e) The two combinations policy refuses, pinned as construction and
    #     refused as policy — so a later reader can tell the difference.
    check reportDataHex(bpAttest, hexToBytes("c", ChallengeLong),
      hexToBytes("k", EphemeralPub)) == V5ReportData
    check reportDataHex(bpKeyAgreement, hexToBytes("c", ChallengeLong), "") ==
      V6ReportData
    expect BindingError:
      discard reportDataHexFor(ReportBindings(purpose: bpAttest,
        ephemeralPub: EphemeralPub), ChallengeLong)
    expect BindingError:
      discard reportDataHexFor(ReportBindings(purpose: bpKeyAgreement,
        ephemeralPub: ""), ChallengeLong)

    # (f) Every report datum is exactly 64 bytes, which is the size the
    #     hardware fields are — not a truncation and not a padding.
    check reportData(bpAttest, hexToBytes("c", ChallengeMin), "").len ==
      ReportDataSize
    check V1ReportData.len == ReportDataHexLen

    # (g) The challenge floor is enforced and the ceiling is real. A
    #     15-byte nonce is refused: freshness is the only thing a challenge
    #     provides, and there is no partial credit for it.
    expect BindingError:
      discard reportDataHexFor(attestBindings, ChallengeMin[0 .. 29])
    check ChallengeMin[0 .. 29].len div 2 == ChallengeMinBytes - 1
    expect BindingError:
      discard reportDataHexFor(attestBindings,
        repeat("ab", ChallengeMaxBytes + 1))
    expect BindingError:
      discard reportDataHexFor(ReportBindings(purpose: bpKeyAgreement,
        ephemeralPub: repeat("cd", EphemeralPubMaxBytes + 1)), ChallengeLong)

    # (h) Hex is lower-case on the way in. One value, one spelling.
    expect BindingError:
      discard reportDataHexFor(attestBindings, toUpperAscii(ChallengeLong))

    # (i) The NUMBERS, pinned as literals. Every assertion above sizes its
    #     input from the constant it is testing, which is the right way to
    #     show a check exists and the wrong way to notice the check moving:
    #     raise the ceiling and the input rises with it. These bounds are
    #     part of a frozen schema, so a second implementation has to be
    #     able to read them off, and changing one has to be visible.
    check ReportDataDomainTag == "ReproOS-ATT-v1"
    check ReportDataSize == 64
    check ReportDataHexLen == 128
    check ChallengeMinBytes == 16
    check ChallengeMaxBytes == 128
    check EphemeralPubMaxBytes == 256

  test "t_report_data_domain_separation":
    let challengeBytes = hexToBytes("c", ChallengeLong)
    let keyBytes = hexToBytes("k", EphemeralPub)

    # (a) The easy half: the purpose is inside the hash, so the same
    #     challenge answered under a different purpose is a different set
    #     of bytes. Without this, a quote minted for a plain attestation
    #     could be presented as one that bound a key.
    check reportDataHex(bpAttest, challengeBytes, "") !=
      reportDataHex(bpKeyAgreement, challengeBytes, "")
    check V1ReportData != V3ReportData

    # (b) ...and the tag separates this construction from any other use of
    #     SHA-512 over the same material.
    check reportDataHex(bpAttest, challengeBytes, "") !=
      sha512Hex($bpAttest & challengeBytes)
    check bindingPreimage(bpAttest, challengeBytes, "").startsWith(
      ReportDataDomainTag)

    # (c) The hard half, stated as the collision it is. Take the design's
    #     formula as a PLAIN concatenation — tag ‖ purpose ‖ challenge ‖
    #     key, no framing — and two entirely different session bindings
    #     produce one byte string:
    #
    #       (key-agreement, challenge = X,      key = Y)
    #       (key-agreement, challenge = X ‖ Y1, key = Y2)   where Y = Y1 ‖ Y2
    #
    #     Both are legal inputs: both challenges are over 128 bits and both
    #     keys are non-empty. A hardware root would sign the same 64 bytes
    #     for both, so a quote bound to one is a quote bound to the other.
    let splitAt = 8
    let challengeB = challengeBytes & keyBytes[0 ..< splitAt]
    let keyB = keyBytes[splitAt .. ^1]
    check challengeB.len >= ChallengeMinBytes
    check keyB.len > 0
    check (challengeB & keyB) == (challengeBytes & keyBytes)

    proc unframed(purpose: BindingPurpose; challenge, key: string): string =
      ## The formula as written, without framing. Defined here and used
      ## nowhere else in the tree: it exists to be shown broken.
      sha512Hex(ReportDataDomainTag & $purpose & challenge & key)

    check unframed(bpKeyAgreement, challengeBytes, keyBytes) ==
      unframed(bpKeyAgreement, challengeB, keyB)

    # (d) The framed construction separates exactly those two inputs. This
    #     is the assertion that would fail against the unframed formula,
    #     which is why (c) is here at all — "different inputs differ" would
    #     have passed either way.
    check reportDataHex(bpKeyAgreement, challengeBytes, keyBytes) !=
      reportDataHex(bpKeyAgreement, challengeB, keyB)

    # (e) The same re-split at every position, so the separation is not a
    #     property of one lucky offset.
    for at in 1 ..< keyBytes.len:
      let c = challengeBytes & keyBytes[0 ..< at]
      let k = keyBytes[at .. ^1]
      check unframed(bpKeyAgreement, challengeBytes, keyBytes) ==
        unframed(bpKeyAgreement, c, k)
      check reportDataHex(bpKeyAgreement, challengeBytes, keyBytes) !=
        reportDataHex(bpKeyAgreement, c, k)

    # (f) The absent key is distinguishable from an empty one, which is the
    #     same boundary at its degenerate end.
    check reportDataHex(bpAttest, challengeBytes & keyBytes, "") !=
      reportDataHex(bpAttest, challengeBytes, keyBytes)

    # (g) The purpose/challenge boundary survives WITHOUT framing today
    #     only because the enum is closed and prefix-free. That is a
    #     property of the current spellings, not of the formula, so it is
    #     asserted rather than assumed: a third purpose that is a prefix of
    #     another would redden this and force the question to be answered
    #     again.
    for a in BindingPurpose:
      for b in BindingPurpose:
        if a != b:
          check not ($a).startsWith($b)
          check not ($b).startsWith($a)

    # (h) A one-bit change anywhere in the challenge moves the register.
    var flipped = challengeBytes
    flipped[0] = char(uint8(flipped[0]) xor 1'u8)
    check reportDataHex(bpAttest, flipped, "") !=
      reportDataHex(bpAttest, challengeBytes, "")

  test "t_report_envelope_roundtrip_and_reject":
    # -----------------------------------------------------------------
    # Round-trip
    # -----------------------------------------------------------------

    # (a) Every tier/backend pair this schema defines renders, parses and
    #     re-renders to the same bytes. A verifier that reads and rewrites
    #     a report must not change it.
    for backend in [abSevSnp, abTdx, abTpm2, abMock]:
      let rendered = renderAttestationReport(demoReport(backend))
      let reparsed = parseAttestationReport(rendered, "<memory>")
      check renderAttestationReport(reparsed) == rendered
      check reparsed.backend == backend
      check reparsed.tier == tierOf(backend)
      check parseJson(rendered)["schema"].getStr ==
        "reproos.attestation-report.v1"

    # (b) The key-agreement shape, with a bundled chain, round-trips too —
    #     including the optional key, which is the one part of the document
    #     whose presence varies.
    let ka = demoReport(abTpm2, bpKeyAgreement, ChallengeLong,
      some(@["CERT-ONE-DER-BYTES", "CERT-TWO-DER-BYTES"]))
    let kaText = renderAttestationReport(ka)
    let kaBack = parseAttestationReport(kaText, "<memory>")
    check renderAttestationReport(kaBack) == kaText
    check kaBack.bindings.purpose == bpKeyAgreement
    check kaBack.bindings.ephemeralPub == EphemeralPub

    # (c) The 64 bytes in the document are the ones the discipline
    #     produces, and the construction is the shared one — the envelope
    #     does not carry a second opinion about its own binding.
    check ka.reportData == reportDataHexFor(ka.bindings, ChallengeLong)
    check demoReport().reportData == V2ReportData

    # (d) Evidence is the only authoritative field, and it decodes to the
    #     bytes that went in. The accessor is the one named for the rule.
    check authoritativeEvidence(ka) == DemoEvidence

    # (e) Certificates: omitted stays omitted, present decodes, and the
    #     accessor says what the caller must do with them.
    let plain = demoReport()
    check not hasBundledCertificates(plain)
    check certificatesForCrossCheck(plain).len == 0
    check not parseJson(renderAttestationReport(plain)).hasKey("certificates")
    check hasBundledCertificates(kaBack)
    check certificatesForCrossCheck(kaBack) ==
      @["CERT-ONE-DER-BYTES", "CERT-TWO-DER-BYTES"]

    # (f) Freshness is the challenge, and only the challenge.
    check bindsChallenge(plain, ChallengeLong)
    check not bindsChallenge(plain, ChallengeMin)

    # (g) Every convenience field is named so a call site has to say it is
    #     unverified. This mirrors the compile-time assertion in the module
    #     and keeps it from becoming vacuous.
    var claimNames: seq[string] = @[]
    let claims = plain.claims
    for name, _ in claims.fieldPairs: claimNames.add name
    check claimNames.len == 3
    for name in claimNames:
      check name.startsWith("unverified")

    # (h) A report's backend and a measurement manifest's launch-shape key
    #     are not spelled the same way for the TPM, and the mapping is
    #     stated once rather than re-derived by string equality.
    check manifestBackendKey(abTpm2) == BackendTpm
    check manifestBackendKey(abTpm2) != $abTpm2
    check manifestBackendKey(abSevSnp) == BackendSevSnp
    check manifestBackendKey(abTdx) == BackendTdx
    check manifestBackendKey(abMock) == ""

    # -----------------------------------------------------------------
    # What is NOT refused: the clock
    # -----------------------------------------------------------------

    # (i) A report is not stale because of what it says the time is, and it
    #     is not fresh because of it either. Both extremes parse.
    let good = renderAttestationReport(plain)
    for stamp in ["1970-01-01T00:00:00Z", "3000-12-31T23:59:60.123456789Z",
                  "2026-09-09T11:22:33+02:00", "2026-09-09T11:22:33-05:30"]:
      let text = mutated(good, proc (doc: JsonNode) =
        doc["timestamp"] = newJString(stamp))
      check parseAttestationReport(text, "<clock>").timestampInformational ==
        stamp

    # -----------------------------------------------------------------
    # Refusals
    # -----------------------------------------------------------------

    # (j) Unknown fields, at every level the document has.
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["notes"] = newJString("hello")), "<mutated>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["bindings"]["nonce"] = newJString("00")), "<mutated>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["claims"]["hostname"] = newJString("host")), "<mutated>")

    # (k) Absent fields. Every required top-level key, one at a time —
    #     including `claims`, which is a convenience but not an optional
    #     one, and excluding `certificates`, which is the only key whose
    #     absence is legal and is checked as such in (e).
    for key in TopLevelRequired:
      expect ReportError:
        discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
          doc.delete(key)), "<missing " & key & ">")
    for key in ClaimKeys:
      expect ReportError:
        discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
          doc["claims"].delete(key)), "<missing claim " & key & ">")

    # (l) Wrong-typed fields. A number where a string belongs, an array
    #     where an object belongs, and a string where an array belongs.
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["challenge"] = newJInt(42)), "<mutated>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["evidence"] = newJInt(42)), "<mutated>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["bindings"] = newJString("attest")), "<mutated>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["claims"] = newJArray()), "<mutated>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["certificates"] = newJString("CERT")), "<mutated>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["certificates"] = %*[42]), "<mutated>")

    # (m) A schema version this build does not implement. A later change to
    #     this document is a version bump, and this is what makes an old
    #     reader refuse a new document instead of half-understanding it.
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["schema"] = newJString("reproos.attestation-report.v2")),
        "<mutated>")

    # (n) An unknown tier, backend or purpose.
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["tier"] = newJString("sgx")), "<mutated>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["backend"] = newJString("sev-es")), "<mutated>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["bindings"]["purpose"] = newJString("sealing")), "<mutated>")

    # (o) A backend that does not belong to its tier. Left unchecked, a
    #     mock instance could name itself `cvm` and every policy written
    #     against the tier would become advisory.
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["tier"] = newJString("cvm")), "<mock claiming cvm>")
    expect ReportError:
      discard parseAttestationReport(
        mutated(renderAttestationReport(demoReport(abTpm2)),
          proc (doc: JsonNode) = doc["tier"] = newJString("cvm")),
        "<tpm2 claiming cvm>")

    # (p) The coupling between purpose and ephemeral key, both polarities.
    #     A key under `attest` is a third, unnamed use of the same 64
    #     bytes; a key agreement with no key cannot bind the channel it
    #     opens.
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["bindings"]["ephemeralPub"] = newJString(EphemeralPub)),
        "<key under attest>")
    expect ReportError:
      discard parseAttestationReport(mutated(kaText, proc (doc: JsonNode) =
        doc["bindings"].delete("ephemeralPub")), "<agreement with no key>")

    # (q) A challenge that is too short, or spelled in the wrong case.
    #     Freshness rests on the challenge alone, so there is no lenient
    #     reading of a weak one.
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["challenge"] = newJString("00112233445566778899aabbccddee")),
        "<120-bit challenge>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["challenge"] = newJString(toUpperAscii(ChallengeLong))),
        "<upper-case challenge>")

    # (r) The self-consistency crux. A report states the 64 bytes it bound;
    #     they must be the 64 bytes its own challenge and bindings produce.
    #     Three ways to break it, each of which a lenient reader would let
    #     through as "the fields disagree, believe one of them":
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["reportData"] = newJString(V1ReportData)),
        "<report data of another challenge>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["challenge"] = newJString(ChallengeMin)),
        "<challenge swapped under the report data>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["reportData"] = newJString(repeat("0", 128))),
        "<report data that is not a binding at all>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["reportData"] = newJString(V2ReportData[0 .. 125])),
        "<report data of the wrong length>")

    # (s) Evidence: empty, or not canonical base64. It is the only
    #     authoritative field, so a report without a decodable one is not a
    #     weaker report.
    #
    #     The empty case asserts the MESSAGE, not merely that something was
    #     raised. Without that, deleting the emptiness check entirely would
    #     leave this green — the base64 check refuses an empty string too,
    #     for a reason that has nothing to do with evidence being
    #     authoritative — and a refusal that survives the deletion of the
    #     code it is meant to protect is not a gate.
    var emptyEvidenceRefusal = ""
    try:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["evidence"] = newJString("")), "<no evidence>")
    except ReportError as err:
      emptyEvidenceRefusal = err.msg
    check "only authoritative field" in emptyEvidenceRefusal

    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["evidence"] = newJString("not base64!!")), "<unreadable evidence>")
    # Non-canonical base64 is refused while its canonical spelling is
    # accepted: "QQ==" and "QR==" both decode to "A", but only the first
    # re-encodes to itself. One report must not be two documents.
    check parseAttestationReport(mutated(good, proc (doc: JsonNode) =
      doc["evidence"] = newJString("QQ==")), "<canonical>").evidence == "QQ=="
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["evidence"] = newJString("QR==")), "<non-canonical padding>")

    # The document's own size bounds. They are not a rate limit — a
    # listening socket needs its own — but an unbounded field in a frozen
    # schema is a field nobody can implement a second time with confidence.
    # The numbers are pinned as literals for the same reason they are in
    # the vectors case: every assertion below sizes its input from the
    # constant, so raising a ceiling would otherwise raise the input too.
    check AttestationReportSchema == "reproos.attestation-report.v1"
    check MaxEvidenceBase64 == 1_048_576
    check MaxCertificates == 16
    check MaxCertificateBase64 == 65_536
    check MaxClaimTokenLen == 256
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        # "QUJD" is base64 for "ABC" and needs no padding, so repeating it
        # is still CANONICAL base64. A padded group repeated would put an
        # "=" mid-string and be refused for that instead, which would make
        # this assertion pass without the cap existing at all.
        doc["evidence"] =
          newJString(repeat("QUJD", MaxEvidenceBase64 div 4 + 1))),
        "<evidence over the cap>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        var chain = newJArray()
        for i in 0 .. MaxCertificates:
          chain.add newJString("Q0VSVA==")
        doc["certificates"] = chain), "<too many certificates>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["certificates"] =
          %*[repeat("QUJD", MaxCertificateBase64 div 4 + 1)]),
        "<certificate over the cap>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["claims"]["generation"] =
          newJString(repeat("g", MaxClaimTokenLen + 1))),
        "<claim over the cap>")

    # (t) Certificates present and empty. "Fetch your own collateral" and
    #     "here is a chain" must not be spellable the same way.
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["certificates"] = newJArray()), "<empty chain>")

    # (u) A malformed timestamp is still refused — informational is not the
    #     same as unchecked, and a field nothing validates is a field
    #     anything can be smuggled through.
    for stamp in ["yesterday", "2026-09-09", "2026-13-09T11:22:33Z",
                  "2026-09-09T25:22:33Z", "2026-09-09 11:22:33Z",
                  "2026-09-09T11:22:33"]:
      expect ReportError:
        discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
          doc["timestamp"] = newJString(stamp)), "<bad timestamp>")

    # (v) A claim that is not shaped like the manifest field it will be
    #     pre-checked against. Unverified does not mean unconstrained.
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["claims"]["verityRootHash"] = newJString("not-a-hash")),
        "<claim that cannot be compared>")
    expect ReportError:
      discard parseAttestationReport(mutated(good, proc (doc: JsonNode) =
        doc["claims"]["generation"] = newJString("")), "<empty claim>")

    # (w) A construction that would emit any of the above is refused at the
    #     source, so a document this build could not itself accept is never
    #     produced.
    expect ReportError:
      discard demoReport(abMock, bpAttest, "00112233445566778899aabbccddee")
    expect ReportError:
      discard attestationReport(abMock, "not-a-timestamp", ChallengeLong,
        ReportBindings(purpose: bpAttest, ephemeralPub: ""),
        DemoEvidence, demoClaims())
    expect ReportError:
      discard attestationReport(abMock, DemoTimestamp, ChallengeLong,
        ReportBindings(purpose: bpAttest, ephemeralPub: ""),
        "", demoClaims())
    expect ReportError:
      discard attestationReport(abMock, DemoTimestamp, ChallengeLong,
        ReportBindings(purpose: bpAttest, ephemeralPub: ""),
        DemoEvidence, demoClaims(), some(newSeq[string]()))

    # (x) And the good document still parses, twice over, so every refusal
    #     above is discriminating rather than universal.
    check parseAttestationReport(good, "<good>").backend == abMock
    check parseAttestationReport(kaText, "<good>").tier == atTpm

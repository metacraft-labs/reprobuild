## A machine attested, and the verifier accepted it.
##
## ## The claim
##
## One measured-boot guest produced an attestation structure, a signature
## and the event log firmware wrote. This gate assembles them into the
## composite the backend defines, wraps that in a real report envelope
## answering a real challenge, builds the measurement manifest the image
## build would have published, and runs the real verifier against the
## real policy parser. The verdict is an ACCEPTANCE.
##
## Until this gate existed, the verifier had never been shown bytes a TPM
## produced. Every green verdict it had ever reached was on the mock
## backend's evidence, whose authentication key is published in the clear
## beside the code that checks it.
##
## ## Why the positive path is worth so little on its own
##
## A verifier that accepted everything would pass the first case here. So
## the cases that carry the weight are the ones that establish the
## acceptance had somewhere to fail:
##
##   * the launch measurement the verifier extracted is the value
##     computed from the IMAGE's bytes, by a different module, before the
##     guest booted — and the gate asserts the two are equal rather than
##     asserting either against itself;
##   * the quote covers the register that measurement is read from, and
##     the gate pins WHICH registers by value, because a quote over eight
##     other registers would explain a log just as well while saying
##     nothing about the image;
##   * a report whose evidence is a composite carrying a DIFFERENT
##     machine's log is rejected, on the same policy, in the same case —
##     without which "it accepted" would not be a statement about these
##     bytes.
##
## ## What this gate does NOT prove
##
## No signature is verified — by this gate or anywhere in this build —
## so what is established is that the log explains the structure, not who
## produced the structure. The verdict says so itself, and the gate reads
## that caveat back rather than taking the library's word for it. The
## guest's TPM is a software implementation. And the manifest here is
## built from the image's own precomputed measurement rather than read
## off an image build's output directory, because no image was built.
##
## ## Mocking
##
## None. The bytes are one boot's; see ``attested_boot_vectors``.

import std/[options, strutils, unittest]

import repro_attest
import repro_attest_verify

include ./attested_boot_vectors

proc unhexBytes(h: string): string =
  doAssert h.len mod 2 == 0
  result = newString(h.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(h[2 * i .. 2 * i + 1]))

proc bootEvidence(): Tpm2Evidence =
  Tpm2Evidence(
    attestBytes: unhexBytes(AttestedBootAttestHex),
    signatureBytes: unhexBytes(AttestedBootSignatureHex),
    eventLogBytes: unhexBytes(AttestedBootEventLogHex))

const
  BootFingerprint = "reproos-attested-uefi:attested-boot"
  BootVerityRootHash =
    "4444444444444444444444444444444444444444444444444444444444444444"
  BootTimestamp = "2026-09-14T21:00:00Z"

  ## A policy that accepts the measured-boot tier and nothing weaker. It
  ## is deliberately NOT the development policy the mock gates use: that
  ## one sets ``allow_mock``, and a measured-boot acceptance reached
  ## under a policy that also admits a rootless tier would not be the
  ## acceptance this gate is about.
  MeasuredBootPolicy = """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["tpm"]
backends = ["tpm2"]
allow_mock = false

[measurements]
manifests = []
require_certificates = false

[freshness]
max_challenge_age_seconds = 0
require_challenge = false
"""

proc bootManifest(pcr11 = AttestedBootUkiPcr11;
                  tmpl = AttestedBootUkiTemplate): AttestedImageManifest =
  ## What the image build publishes for this image. ``pcr11`` and the
  ## template are the values the measurement module computed from the
  ## image's own bytes.
  AttestedImageManifest(
    configFingerprint: BootFingerprint,
    imageOutputs: ImageOutputs(
      uki: DigestPrefix & sha256Hex("attested-boot-uki"),
      verityImage: DigestPrefix & sha256Hex("attested-boot-verity"),
      verityRootHash: BootVerityRootHash),
    tpm: @[TpmExpectation(pcr11: pcr11, eventLogTemplate: tmpl)])

proc bootReportText(evidence: string;
                    challengeHex = AttestedBootChallengeHex): string =
  ## A real envelope, rendered by the real renderer, answering the nonce
  ## the guest's bound bytes were derived from. The envelope's own
  ## ``reportData`` is recomputed here by the discipline — the gate never
  ## copies it out of the quote — so the verifier's report-data-binding
  ## check has two independent sides.
  renderAttestationReport(attestationReport(
    backend = abTpm2,
    timestamp = BootTimestamp,
    challengeHex = challengeHex,
    bindings = ReportBindings(purpose: bpAttest),
    evidence = evidence,
    claims = UnverifiedClaims(
      unverifiedGeneration: "gen-attested-boot-0001",
      unverifiedConfigFingerprint: BootFingerprint,
      unverifiedVerityRootHash: BootVerityRootHash)))

proc verifyBoot(reportText: string;
                manifest: Option[string]): Verdict =
  verifyAttestationReport(VerificationRequest(
    reportText: reportText,
    reportSource: "<one attested boot>",
    policy: parseAttestationPolicy(MeasuredBootPolicy, "<measured-boot>"),
    policySource: "<measured-boot>",
    manifestText: manifest,
    manifestSource: "<the build's manifest>",
    expectedChallengeHex: "",
    challengeIssuedAtMs: none(int64),
    nowMs: 0))

suite "a measured-boot machine's own evidence, verified":

  test "t_tpm_quote_verifies":
    let ev = bootEvidence()
    let composite = composeTpm2Evidence(ev)
    let manifestText = renderAttestedImageManifest(bootManifest())
    let v = verifyBoot(bootReportText(composite), some(manifestText))

    # ---- the acceptance -------------------------------------------
    check v.decision.isAcceptance
    check v.checks[vcReportSchema].outcome == coPassed
    check v.checks[vcTierAccepted].outcome == coPassed
    check v.checks[vcBackendAccepted].outcome == coPassed
    check v.checks[vcNativeEvidence].outcome == coPassed
    check v.checks[vcReportDataBinding].outcome == coPassed
    check v.checks[vcMeasurementMatch].outcome == coPassed

    # It is the measured-boot reader that reached it, not some fallback,
    # and that reader is one this build carries rather than a caller's.
    let reading = readAuthoritativeEvidence(
      parseAttestationReport(bootReportText(composite), "<reading>"))
    check reading.inputs.readerName == Tpm2ReaderName
    check Tpm2ReaderName in BuiltInReaders

    # THE BYTES THE TPM SIGNED ARE THE BYTES THE DISCIPLINE DERIVES FROM
    # THE NONCE. Recomputed here from the nonce, never copied from the
    # quote, so this is a join between two independent sides and not a
    # constant compared against itself.
    check reading.inputs.reportDataInEvidence ==
      some(reportDataHexFor(ReportBindings(purpose: bpAttest),
                           AttestedBootChallengeHex))
    # And equal to the RECORDED value as well, so the constant beside the
    # bytes is one a gate reads rather than a note about them. Three
    # sides now have to agree — what the signed structure carries, what
    # the discipline derives from the nonce, and what was written down —
    # and a fixture constant nothing reads can drift to anything without
    # a gate noticing.
    check reading.inputs.reportDataInEvidence ==
      some(AttestedBootQualifyingHex)

    # ---- and the acceptance had somewhere to fail ------------------
    #
    # The measurement the verifier extracted from the machine's own log
    # equals the one computed from the IMAGE's bytes by a different
    # module before the guest existed. Asserted against the manifest's
    # own expectation AND against the pinned constant, because the
    # manifest was built from that constant and comparing it against
    # itself would be satisfied however the constant moved.
    check v.hasIdentity
    let expected = bootManifest().tpm[0].pcr11
    check expected == AttestedBootUkiPcr11
    check expected == replayEventLogTemplate(AttestedBootUkiTemplate)

    # The register that value is read from is one the quote COVERS, and
    # which registers those are is pinned by value: a quote over eight
    # other registers would explain this log equally well and say
    # nothing whatever about the image.
    let q = tpm2EvidenceQuote(ev)
    var quoted: seq[int] = @[]
    for s in selectedPcrs(q.attest.quote.pcrSelect):
      check s.bank == LaunchMeasurementBank
      quoted.add s.index
    check quoted.len == AttestedBootQuotedRegisters.len
    for i, idx in AttestedBootQuotedRegisters:
      check quoted[i] == idx
    check LaunchMeasurementRegister in quoted

    # The log explains the structure, which is what makes the value
    # above a value the TPM spoke for rather than a number in a file.
    check explainsQuote(tpm2EvidenceLog(ev), q)

    # ---- the negative control, in this same case -------------------
    #
    # Without it, "the verifier accepted" is not a statement about these
    # bytes. A composite whose log is one byte different no longer
    # explains its own quote, and the same policy rejects it.
    # One bit, inside one real measurement's SHA-256 digest — not a
    # trailing byte. A flip in padding the parser never reads would
    # change the bytes and change no answer, which is a negative control
    # that controls nothing; this one changes the replay.
    let parsedLog = tpm2EvidenceLog(ev)
    var target = -1
    for e in parsedLog.events:
      for dg in e.digests:
        if dg.alg == LaunchMeasurementBank and e.pcrIndex ==
           LaunchMeasurementRegister:
          target = ev.eventLogBytes.find(dg.digest)
          break
      if target >= 0: break
    check target >= 0
    var alteredLog = ev.eventLogBytes
    alteredLog[target] = char(uint8(alteredLog[target]) xor 0x01'u8)
    let alteredComposite = composeTpm2Evidence(Tpm2Evidence(
      attestBytes: ev.attestBytes,
      signatureBytes: ev.signatureBytes,
      eventLogBytes: alteredLog))
    check alteredComposite != composite
    let bad = verifyBoot(bootReportText(alteredComposite),
                         some(manifestText))
    check not bad.decision.isAcceptance
    check bad.checks[vcNativeEvidence].outcome == coFailed

  test "t_tpm_quote_verdict_states_that_no_signature_was_checked":
    ## The limit is carried by the verdict, not by a comment in the
    ## library. A build that started verifying signatures would have to
    ## change this text, and a build that quietly stopped stating the
    ## limit reddens here.
    let v = verifyBoot(bootReportText(composeTpm2Evidence(bootEvidence())),
                       some(renderAttestedImageManifest(bootManifest())))
    check v.decision.isAcceptance
    var stated = false
    for c in v.caveats:
      if NoSignatureCheckedNote in c: stated = true
    check stated
    # And the phrase means what it says: nothing in the accepted
    # verdict's own rendering claims a signature was verified.
    let rendered = renderVerdictText(v)
    check NoSignatureCheckedNote in rendered

    # And on a REJECTION too. The caveat rides the READER rather than the
    # outcome: a verdict that refused this evidence still rests on a
    # reading in which nobody checked a signature, and whoever reads the
    # refusal is owed that. Asserted separately because the acceptance
    # above cannot tell "attached to the reader" apart from "attached to
    # acceptances" — and a build that quietly narrowed it to the second
    # would leave every rejection silent about its own limit.
    let refused = verifyBoot(bootReportText(composeTpm2Evidence(
      Tpm2Evidence(
        attestBytes: unhexBytes(NoImageBootAttestHex),
        signatureBytes: unhexBytes(NoImageBootSignatureHex),
        eventLogBytes: unhexBytes(NoImageBootEventLogHex)))),
      some(renderAttestedImageManifest(bootManifest())))
    check not refused.decision.isAcceptance
    var statedOnRejection = false
    for c in refused.caveats:
      if NoSignatureCheckedNote in c: statedOnRejection = true
    check statedOnRejection
    check NoSignatureCheckedNote in renderVerdictText(refused)

  test "t_tpm_quote_without_the_launch_register_is_refused":
    ## The precondition of the whole join, exercised on real bytes.
    ##
    ## A quote over registers 0 to 7 says nothing about register 11, so
    ## a log claiming any value for 11 would explain it perfectly — and a verifier that read
    ## the launch measurement out of that log would be reading a number
    ## nothing signed. The reader must refuse rather than read.
    ##
    ## Built from THIS machine's log and a quote that does not cover 11,
    ## so the only thing wrong with it is the selection.
    let ev = bootEvidence()
    let q = tpm2EvidenceQuote(ev)

    # A quote whose selection is narrowed to 0..7 — re-serialised from
    # the real structure so every other field is genuine.
    var narrowed = q.attest
    narrowed.quote.pcrSelect = pcrSelection(LaunchMeasurementBank,
                                            [0, 1, 2, 3, 4, 5, 6, 7])
    let narrowedBytes = serializeAttest(narrowed)
    check narrowedBytes != ev.attestBytes

    let v = verifyBoot(bootReportText(composeTpm2Evidence(Tpm2Evidence(
      attestBytes: narrowedBytes,
      signatureBytes: ev.signatureBytes,
      eventLogBytes: ev.eventLogBytes))), some(
        renderAttestedImageManifest(bootManifest())))

    check not v.decision.isAcceptance
    check v.checks[vcNativeEvidence].outcome == coFailed
    # Refused for the RIGHT reason: about the register that is missing,
    # not about a digest that stopped matching.
    check "and not " & $LaunchMeasurementBank & ":" &
      $LaunchMeasurementRegister in v.checks[vcNativeEvidence].detail
    # And no launch measurement reached the decision at all.
    check v.checks[vcMeasurementMatch].outcome != coPassed

  test "t_tpm_quote_covering_the_register_in_another_bank_is_refused":
    ## The BANK is part of "covered", not only the index.
    ##
    ## A measurement manifest's expectation is a SHA-256 value. A quote
    ## that covers register 11 in the SHA-1 bank therefore says nothing
    ## about the number a verifier is about to compare, and a reader that
    ## matched on the index alone would read a SHA-256 register out of
    ## the log on the strength of a SHA-1 one having been signed.
    ##
    ## This machine's log really does carry a SHA-1 bank and really did
    ## extend 11 in it, so the selection below is one a TPM could have
    ## produced — which is what makes the case a test of the rule rather
    ## than of a shape nothing reaches.
    let ev = bootEvidence()
    let q = tpm2EvidenceQuote(ev)

    var crossBank = q.attest
    crossBank.quote.pcrSelect = TpmlPcrSelection(selections: @[
      pcrSelection(TpmAlgSha1, [LaunchMeasurementRegister]).selections[0],
      pcrSelection(LaunchMeasurementBank,
                   [0, 1, 2, 3, 4, 5, 6, 7]).selections[0]])
    # The register really is named, in the other bank.
    var named = false
    for s in selectedPcrs(crossBank.quote.pcrSelect):
      if s.index == LaunchMeasurementRegister:
        check s.bank == TpmAlgSha1
        named = true
    check named
    # And it is NOT named in the bank the manifest speaks.
    for s in selectedPcrs(crossBank.quote.pcrSelect):
      if s.bank == LaunchMeasurementBank:
        check s.index != LaunchMeasurementRegister

    let v = verifyBoot(bootReportText(composeTpm2Evidence(Tpm2Evidence(
      attestBytes: serializeAttest(crossBank),
      signatureBytes: ev.signatureBytes,
      eventLogBytes: ev.eventLogBytes))), some(
        renderAttestedImageManifest(bootManifest())))

    check not v.decision.isAcceptance
    check v.checks[vcNativeEvidence].outcome == coFailed
    # Refused by the COVERAGE rule, named by its own phrase — not by the
    # replay rule further down, which would also refuse this composite.
    # Asserting the coverage phrase is what stops one refusal standing in
    # for the other.
    check "the register a launch measurement is taken from" in
      v.checks[vcNativeEvidence].detail
    check "does not describe the boot that was attested to" notin
      v.checks[vcNativeEvidence].detail

  test "t_tpm_evidence_that_does_not_parse_is_refused":
    ## FAIL-CLOSED. A composite the parser will not read must make the
    ## verdict a REJECTION, never a verdict reached on nothing.
    ##
    ## Three shapes, each refused, and the acceptance is asserted in the
    ## same case against the unaltered composite so that "it rejects" is
    ## not satisfied by a verifier that rejects everything.
    let good = composeTpm2Evidence(bootEvidence())
    check verifyBoot(bootReportText(good),
      some(renderAttestedImageManifest(bootManifest()))).decision.isAcceptance

    for broken in [good[0 ..< good.len - 1],      # truncated
                   good & "\x00",                 # trailing bytes
                   "not a composite at all"]:      # not the schema
      let v = verifyBoot(bootReportText(broken),
        some(renderAttestedImageManifest(bootManifest())))
      check not v.decision.isAcceptance
      check v.checks[vcNativeEvidence].outcome == coFailed
      check "the measured-boot evidence did not parse" in
        v.checks[vcNativeEvidence].detail
      # And nothing downstream was reached on the strength of it.
      check v.checks[vcMeasurementMatch].outcome != coPassed
      check not v.hasIdentity

    # And two shapes that FRAME correctly and still cannot be read: the
    # composite parses, all three members are present, and the member the
    # whole reading turns on is not the structure it claims to be.
    # Framing is not structure, and each of these refusals is a different
    # one from the parse refusal above — asserted by requiring the parse
    # refusal's phrase to be ABSENT, so one cannot stand in for the other.
    let ev = bootEvidence()
    for (phrase, wellFramed) in [
        ("the attestation structure in this evidence does not decode",
         composeTpm2Evidence(Tpm2Evidence(
           attestBytes: "not an attestation structure",
           signatureBytes: ev.signatureBytes,
           eventLogBytes: ev.eventLogBytes))),
        ("the event log in this evidence does not decode",
         composeTpm2Evidence(Tpm2Evidence(
           attestBytes: ev.attestBytes,
           signatureBytes: ev.signatureBytes,
           eventLogBytes: "not a TCG event log")))]:
      let v = verifyBoot(bootReportText(wellFramed),
        some(renderAttestedImageManifest(bootManifest())))
      checkpoint(phrase)
      check not v.decision.isAcceptance
      check v.checks[vcNativeEvidence].outcome == coFailed
      check phrase in v.checks[vcNativeEvidence].detail
      check "the measured-boot evidence did not parse" notin
        v.checks[vcNativeEvidence].detail
      check v.checks[vcMeasurementMatch].outcome != coPassed
      check not v.hasIdentity

  test "t_tpm_quote_of_a_machine_that_measured_no_image_is_refused":
    ## A REAL machine that booted no unified kernel image.
    ##
    ## Its quote is genuine, it covers register 11, and its event log
    ## explains it — every other rule in the reader is satisfied. What is
    ## wrong with it is that nothing ever extended register 11, so the
    ## value a verifier would compare against a manifest is the reset
    ## value every machine shares. A reader that read it anyway would
    ## accept any machine whose manifest happened to publish that
    ## constant, and would report an identity for a boot it knows nothing
    ## about.
    let ev = Tpm2Evidence(
      attestBytes: unhexBytes(NoImageBootAttestHex),
      signatureBytes: unhexBytes(NoImageBootSignatureHex),
      eventLogBytes: unhexBytes(NoImageBootEventLogHex))

    # The preconditions really are met, asserted BEFORE the refusal so
    # the refusal cannot be a different rule firing first.
    let q = tpm2EvidenceQuote(ev)
    let log = tpm2EvidenceLog(ev)
    check log.events.len == NoImageBootEventLogEntries
    check ev.eventLogBytes.len == NoImageBootEventLogBytes
    var covers = false
    for s in selectedPcrs(q.attest.quote.pcrSelect):
      if s.bank == LaunchMeasurementBank and
         s.index == LaunchMeasurementRegister: covers = true
    check covers
    # It binds the SAME 64 bytes as the other two boots, so "all three
    # answered one nonce" is checked here rather than asserted in the
    # fixture's header.
    check bytesToHex(qualifyingData(q)) == AttestedBootQualifyingHex
    check explainsQuote(log, q)
    let bank = replayBank(log, LaunchMeasurementBank)
    check bank.pcrs[LaunchMeasurementRegister].state == prNeverExtended
    check bytesToHex(pcrValue(bank, LaunchMeasurementRegister)) ==
      NoImageBootResetPcr11

    # The refusal is the READER's, not the measurement comparison's.
    # That distinction is the whole point: a reader that surfaced the
    # reset value would leave the decision to a comparison against
    # whatever the manifest happens to publish, and the manifest schema
    # is the wrong place for this to be caught. (It could not be caught
    # there at all, in fact — the manifest validator refuses a document
    # whose template does not replay to its own pcr11, and no template
    # replays to the reset value, which is a second, independent reason
    # this machine must be stopped before the comparison.)
    let v = verifyBoot(bootReportText(composeTpm2Evidence(ev)),
      some(renderAttestedImageManifest(bootManifest())))
    check not v.decision.isAcceptance
    check v.checks[vcNativeEvidence].outcome == coFailed
    check "so its value is the reset value every machine shares" in
      v.checks[vcNativeEvidence].detail
    check not v.hasIdentity

  test "t_tpm_quote_identity_says_whether_the_manifest_was_authenticated":
    ## The manifest is NOT inside the measured boot.
    ##
    ## A measured boot covers the image. It does not cover the document
    ## that says what that image should measure to: that document is
    ## supplied to the verifier, and on the acceptance path above the
    ## policy pins no digest for it, so the identity this verdict reports
    ## rests on a file nothing vouched for. The verdict must say which of
    ## those two situations it is in, and this case requires it to
    ## DISCRIMINATE — the same evidence, two policies, two decisions.
    let composite = composeTpm2Evidence(bootEvidence())
    let manifestText = renderAttestedImageManifest(bootManifest())
    let manifestDigest = DigestPrefix & sha256Hex(manifestText)

    # 1. No pin. Accepted, but explicitly as the weaker value, and the
    #    predicate that names the situation is TRUE.
    let unpinned = verifyBoot(bootReportText(composite), some(manifestText))
    check unpinned.decision == vdAcceptedUnpinnedManifest
    check identityRestsOnUnauthenticatedManifest(unpinned.checks)
    check unpinned.hasIdentity
    var saidSo = false
    for c in unpinned.caveats:
      if UnpinnedManifestCaveat in c: saidSo = true
    check saidSo

    # 2. The SAME evidence under a policy that pins the manifest's
    #    digest. Now the predicate is FALSE and the decision is the
    #    unqualified one — so it is a check and not a constant.
    let pinning = MeasuredBootPolicy.replace(
      "manifests = []", "manifests = [\"" & manifestDigest & "\"]")
    let pinned = verifyAttestationReport(VerificationRequest(
      reportText: bootReportText(composite),
      reportSource: "<one attested boot>",
      policy: parseAttestationPolicy(pinning, "<pinning>"),
      policySource: "<pinning>",
      manifestText: some(manifestText),
      manifestSource: "<the build's manifest>",
      expectedChallengeHex: "",
      challengeIssuedAtMs: none(int64),
      nowMs: 0))
    check pinned.decision == vdAccepted
    check not identityRestsOnUnauthenticatedManifest(pinned.checks)
    check pinned.checks[vcManifestPinned].outcome == coPassed
    check pinned.identity.manifestDigest == manifestDigest

    # 3. And a pin that does not match the document is a REJECTION, so
    #    the pinned arm above is not satisfied by a check that passes
    #    whatever it is given.
    let wrongPin = MeasuredBootPolicy.replace(
      "manifests = []",
      "manifests = [\"" & DigestPrefix & sha256Hex("a different manifest") &
      "\"]")
    let refused = verifyAttestationReport(VerificationRequest(
      reportText: bootReportText(composite),
      reportSource: "<one attested boot>",
      policy: parseAttestationPolicy(wrongPin, "<wrong pin>"),
      policySource: "<wrong pin>",
      manifestText: some(manifestText),
      manifestSource: "<the build's manifest>",
      expectedChallengeHex: "",
      challengeIssuedAtMs: none(int64),
      nowMs: 0))
    check not refused.decision.isAcceptance
    check refused.checks[vcManifestPinned].outcome == coFailed

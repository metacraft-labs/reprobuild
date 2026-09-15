## One character of kernel command line, and the verifier says no.
##
## ## The claim
##
## Two guests booted the same image built from the same inputs, except
## that one's command line reads ``reproos.attest=1`` and the other's
## reads ``reproos.attest=2``. Both produced a real quote over their own
## registers and the event log their own firmware wrote. Verified against
## the manifest the HONEST image published, the honest machine is
## accepted and the tampered one is REJECTED.
##
## ## Why the pair, rather than a single altered blob
##
## Flipping a bit in a captured log proves that a digest changed. It does
## not prove that a machine which really booted something else would be
## caught, because a hand-altered log is not something any firmware would
## write: its entries may not even be consistent with each other. Both
## halves here are real boots, so the rejected evidence is evidence a
## real machine really produced — internally consistent, correctly
## signed by its own TPM, and explaining its own quote perfectly. It is
## refused because it describes a DIFFERENT BOOT, which is the only
## reason a verifier should ever refuse it.
##
## ## The control that makes the rejection mean something
##
## The tampered machine is also verified against ITS OWN manifest, and
## that verdict is an ACCEPTANCE. Without it, "the tampered report was
## rejected" would be satisfied by evidence that was simply broken —
## truncated, unparseable, or answering a different challenge — and the
## gate would pass while establishing nothing about measurement. Both
## machines answer the SAME nonce, so the rejection cannot be attributed
## to freshness either.
##
## ## The causal isolation, checked rather than asserted
##
## The two images' replay templates are compared section by section. Five
## of the six sections a stub measures are byte-identical between them
## and exactly one — ``.cmdline`` — differs. That is what licenses the
## sentence "the command line moved the measurement"; without it, a
## rebuild that also moved the initrd would make the claim untestable.
##
## ## What this gate does NOT prove
##
## No signature is verified, so a machine that fabricated a quote whose
## log agreed with it would not be caught by anything here; what is
## caught is a machine that really booted a different image. Nothing was
## modified on disk after the fact — the "tampering" is a build input,
## which is the strongest form available without a signing key to forge.
##
## ## Mocking
##
## None. Both boots are real; see ``attested_boot_vectors``.

import std/[options, strutils, unittest]

import repro_attest
import repro_attest_verify

include ./attested_boot_vectors

proc unhexBytes(h: string): string =
  doAssert h.len mod 2 == 0
  result = newString(h.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(h[2 * i .. 2 * i + 1]))

const
  PairFingerprint = "reproos-attested-uefi:tamper-pair"
  PairVerityRootHash =
    "5555555555555555555555555555555555555555555555555555555555555555"
  PairTimestamp = "2026-09-14T22:00:00Z"

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

proc honestEvidence(): Tpm2Evidence =
  Tpm2Evidence(
    attestBytes: unhexBytes(AttestedBootAttestHex),
    signatureBytes: unhexBytes(AttestedBootSignatureHex),
    eventLogBytes: unhexBytes(AttestedBootEventLogHex))

proc tamperedEvidence(): Tpm2Evidence =
  Tpm2Evidence(
    attestBytes: unhexBytes(TamperedBootAttestHex),
    signatureBytes: unhexBytes(TamperedBootSignatureHex),
    eventLogBytes: unhexBytes(TamperedBootEventLogHex))

proc manifestFor(pcr11, tmpl: string): string =
  renderAttestedImageManifest(AttestedImageManifest(
    configFingerprint: PairFingerprint,
    imageOutputs: ImageOutputs(
      uki: DigestPrefix & sha256Hex("tamper-pair-uki:" & tmpl),
      verityImage: DigestPrefix & sha256Hex("tamper-pair-verity"),
      verityRootHash: PairVerityRootHash),
    tpm: @[TpmExpectation(pcr11: pcr11, eventLogTemplate: tmpl)]))

proc reportFor(ev: Tpm2Evidence): string =
  renderAttestationReport(attestationReport(
    backend = abTpm2,
    timestamp = PairTimestamp,
    challengeHex = AttestedBootChallengeHex,
    bindings = ReportBindings(purpose: bpAttest),
    evidence = composeTpm2Evidence(ev),
    claims = UnverifiedClaims(
      unverifiedGeneration: "gen-tamper-pair-0001",
      unverifiedConfigFingerprint: PairFingerprint,
      unverifiedVerityRootHash: PairVerityRootHash)))

proc verdictFor(reportText, manifestText: string): Verdict =
  verifyAttestationReport(VerificationRequest(
    reportText: reportText,
    reportSource: "<a measured-boot machine>",
    policy: parseAttestationPolicy(MeasuredBootPolicy, "<measured-boot>"),
    policySource: "<measured-boot>",
    manifestText: some(manifestText),
    manifestSource: "<the honest build's manifest>",
    expectedChallengeHex: "",
    challengeIssuedAtMs: none(int64),
    nowMs: 0))

proc templateSections(tmpl: string): seq[string] =
  ## The ``<section>=<digest>`` entries, without the id and bank.
  result = @[]
  let parts = tmpl.split(';')
  for i in 2 ..< parts.len: result.add parts[i]

suite "a measured-boot machine that booted something else":

  test "t_tampered_uki_detected":
    let honestManifest =
      manifestFor(AttestedBootUkiPcr11, AttestedBootUkiTemplate)

    # ---- the honest machine, against its own manifest --------------
    let good = verdictFor(reportFor(honestEvidence()), honestManifest)
    check good.decision.isAcceptance
    check good.checks[vcNativeEvidence].outcome == coPassed
    check good.checks[vcMeasurementMatch].outcome == coPassed

    # ---- the tampered machine, against the SAME manifest -----------
    let bad = verdictFor(reportFor(tamperedEvidence()), honestManifest)
    check not bad.decision.isAcceptance
    check bad.checks[vcMeasurementMatch].outcome == coFailed
    check not bad.hasIdentity

    # Refused for the RIGHT reason, and the refusal names both values.
    # A rejection that happened to arrive through a parse failure or a
    # freshness rule would satisfy "not accepted" while proving nothing
    # about measurement.
    let detail = bad.checks[vcMeasurementMatch].detail
    check TamperedBootUkiPcr11 in detail
    check AttestedBootUkiPcr11 in detail

    # Everything that is NOT the measurement still holds for the
    # tampered machine: its evidence parsed, its log explains its own
    # quote, and it answered the nonce it was given. The machine is not
    # broken; it booted something else.
    check bad.checks[vcNativeEvidence].outcome == coPassed
    check bad.checks[vcReportSchema].outcome == coPassed
    check bad.checks[vcReportDataBinding].outcome == coPassed

  test "t_tampered_uki_rejection_is_about_the_measurement":
    ## THE CONTROL. The tampered machine verifies against its OWN
    ## manifest, so the rejection above is a statement about which image
    ## booted rather than about anything being wrong with the evidence.
    let ownManifest =
      manifestFor(TamperedBootUkiPcr11, TamperedBootUkiTemplate)
    let v = verdictFor(reportFor(tamperedEvidence()), ownManifest)
    check v.decision.isAcceptance
    check v.checks[vcMeasurementMatch].outcome == coPassed
    check v.hasIdentity

    # And symmetrically: the HONEST machine is rejected against the
    # tampered image's manifest. Both directions, so neither manifest is
    # simply the one that accepts everything.
    let reversed = verdictFor(reportFor(honestEvidence()), ownManifest)
    check not reversed.decision.isAcceptance
    check reversed.checks[vcMeasurementMatch].outcome == coFailed

  test "t_tampered_uki_differs_only_in_the_command_line":
    ## The causal isolation, measured from the two templates rather than
    ## asserted in prose.
    let honest = templateSections(AttestedBootUkiTemplate)
    let tampered = templateSections(TamperedBootUkiTemplate)
    check honest.len == tampered.len
    check honest.len == 6

    var differing: seq[string] = @[]
    for i in 0 ..< honest.len:
      if honest[i] != tampered[i]:
        differing.add honest[i].split('=')[0]
    # Every section was compared, and exactly one of the six differs.
    # (An `else` branch asserting the two are equal would sit in the
    # branch taken when they already are, so it could not fail; this
    # assertion is what carries the claim.)
    check differing == @[".cmdline"]

    # The two command lines really do differ, by one character, and the
    # sections carry their digests.
    check AttestedBootUkiCmdline != TamperedBootUkiCmdline
    check AttestedBootUkiCmdline.len == TamperedBootUkiCmdline.len
    var chars = 0
    for i in 0 ..< AttestedBootUkiCmdline.len:
      if AttestedBootUkiCmdline[i] != TamperedBootUkiCmdline[i]: inc chars
    check chars == 1

    # And the two STRINGS are the bytes that were MEASURED. Without this
    # the paragraph above is a statement about two constants nothing else
    # reads: they could be replaced by any pair differing in one
    # character while the section digests they are supposed to explain
    # came from somewhere else entirely. The section a stub measures for
    # `.cmdline` is the command line's own bytes, so each digest is
    # derivable right here, from the string, and must be the one the
    # template records.
    check ";.cmdline=" & sha256Hex(AttestedBootUkiCmdline) in
      AttestedBootUkiTemplate
    check ";.cmdline=" & sha256Hex(TamperedBootUkiCmdline) in
      TamperedBootUkiTemplate

    # And one changed section produces a completely different register:
    # replayed by the library from each template, and equal to what each
    # machine's own firmware left behind.
    check replayEventLogTemplate(AttestedBootUkiTemplate) ==
      AttestedBootUkiPcr11
    check replayEventLogTemplate(TamperedBootUkiTemplate) ==
      TamperedBootUkiPcr11
    check AttestedBootUkiPcr11 != TamperedBootUkiPcr11

  test "t_tampered_uki_registers_come_from_the_machines_own_logs":
    ## The values compared above are the ones the MACHINES produced, not
    ## only the ones the templates predict. Replayed here out of each
    ## boot's own firmware log, and each must equal its own image's
    ## precomputation — which is the join everything here rests on.
    for (ev, expected) in [(honestEvidence(), AttestedBootUkiPcr11),
                           (tamperedEvidence(), TamperedBootUkiPcr11)]:
      let q = tpm2EvidenceQuote(ev)
      let log = tpm2EvidenceLog(ev)
      check explainsQuote(log, q)
      let bank = replayBank(log, LaunchMeasurementBank)
      check bank.pcrs[LaunchMeasurementRegister].state == prExtended
      check bytesToHex(pcrValue(bank, LaunchMeasurementRegister)) == expected
      # Both quotes bind the bytes the discipline derives from the one
      # nonce, so the two reports differ in what they measured and in
      # nothing else.
      check bytesToHex(qualifyingData(q)) ==
        reportDataHexFor(ReportBindings(purpose: bpAttest),
                         AttestedBootChallengeHex)

  test "t_attested_boot_evidence_fits_the_envelope":
    ## The bound, measured against a REAL boot log carrying a unified
    ## kernel image rather than against the bootloader-free capture the
    ## codec was first pinned to.
    let ev = honestEvidence()
    check ev.eventLogBytes.len == AttestedBootEventLogBytes
    check tpm2EvidenceLog(ev).events.len == AttestedBootEventLogEntries
    let composite = composeTpm2Evidence(ev)
    check composite.len < MaxTpm2EvidenceBytes
    # The headroom is the event log's, because every other member is
    # fixed-size. Stated as the multiple it really is.
    let headroom = MaxTpm2EvidenceBytes - (composite.len - ev.eventLogBytes.len)
    check headroom > ev.eventLogBytes.len * 50
    checkpoint("composite " & $composite.len & " B of " &
      $MaxTpm2EvidenceBytes & "; event log " & $ev.eventLogBytes.len &
      " B; event-log headroom " & $headroom & " B = " &
      $(headroom div ev.eventLogBytes.len) & "x this log")

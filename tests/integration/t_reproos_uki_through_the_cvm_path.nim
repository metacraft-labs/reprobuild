## A ReproOS-shaped unified kernel image, measured by the real
## calculators and carried through the confidential-computing path end
## to end.
##
## ## The seam this closes, and the one it does not
##
## The measured-boot side of this work is proved against a software TPM
## in a real guest: an image's register value was computed from its
## bytes before the guest existed and the guest reported the same
## value. The confidential-computing side is proved against genuine
## vendor fixtures: real reports, real quotes, real chains. The JOIN —
## a confidential-computing document carrying THIS project's own
## image's measurement — had never been exercised, and joins between
## two separately-working things are where this work has found most of
## its defects.
##
## This gate exercises the join's CALCULATION half, and that is the
## whole of the claim:
##
##   * a real PE32+ image is built here, with the six sections a
##     ReproOS unified kernel image carries;
##   * its launch measurement is computed by ``snp_launch`` over a
##     firmware tail a reference implementation publishes, in the
##     launch shape that implementation states a digest for, with the
##     image as the measured kernel and nothing else changed;
##   * its runtime register value is computed by the LIBRARY's own
##     fold — ``replayTdxRegisters``, the procedure that reproduces a
##     real operator's four registers from that operator's own
##     published record — over an event log describing this image's own
##     measured sections;
##   * both values travel in production-format evidence through the
##     real reader, the real manifest and the real verifier.
##
## **It does not close the host half, and nothing here should be read
## as doing so.** No host has been asked to produce either number. What
## a hypervisor actually writes into a kernel-digest page, and which
## runtime register a trust domain's firmware extends with a stub's
## sections, are facts about machines this gate has never run on. The
## fold order alone is known to vary between hosts, measured rather
## than supposed, and both orders are live in the wild.
##
## ## A finding, asserted rather than noted
##
## A measurement manifest publishes a trust domain's runtime registers
## and **no check in this build compares them**. The measurement row
## reads the initial-memory measurement and nothing else, so two images
## whose runtime registers differ are indistinguishable to a verifier
## that holds a manifest naming both. The case below proves that by
## building exactly that pair.
##
## ## Mocking
##
## None.

import std/[base64, options, os, sequtils, strutils, unittest]

import repro_attest
import repro_attest/snp_launch
import repro_attest_verify
import repro_attest_verify/tdx_quote

import ./cvm_evidence_emulator
import ./cvm_emulator_scenarios
import ./reproos_shaped_uki

from ./tdx_launch_vectors import TdxLaunchVectors, lcOperatorA

include ./snp_digest_corpus

const
  BaseShape = "test_snp_default"
    ## The launch shape the reference implementation states a digest
    ## for: the firmware that reserves a kernel-digest region, one
    ## processor, a named processor model and a named hypervisor. This
    ## gate changes exactly one thing about it — the measured kernel —
    ## so the difference between its digest and this one is the image.

  AlteredCmdline = "root=/dev/mapper/reproos ro quiE"
    ## One character of the command line, and the same LENGTH, so the
    ## digest moves because the content moved and not because a length
    ## field did.

let nowSeconds = 1_790_000_000'i64

let uki = demoUki()
let alteredUki = demoUki(AlteredCmdline)

proc ukiLaunchParameters(image: string; cmdline: string):
                        SevLaunchParameters =
  ## The reference shape with this image as its measured kernel.
  result = parametersFor(statedShapeFor(BaseShape))
  result.hasKernel = true
  result.kernel = newSeq[byte](image.len)
  for i in 0 ..< image.len: result.kernel[i] = byte(image[i])
  result.initrd = @[]
  result.cmdline = cmdline

let ukiDigest = launchDigestHex(ukiLaunchParameters(uki, ReproosCmdline))
let alteredDigest =
  launchDigestHex(ukiLaunchParameters(alteredUki, AlteredCmdline))

# The trust domain's half: the initial-memory measurement is the
# firmware's and an image does not move it, so the genuine one is used
# unchanged. What the image moves is a runtime register.
let tdxVector = TdxLaunchVectors[lcOperatorA]
let tdxMrtd = tdxMrtdHex(
  toOpenArrayByte(tdxVector.firmware, 0, tdxVector.firmware.len - 1),
  tdxVector.order)

proc registersFor(image: string): array[TdxRtMrCount, string] =
  let replay = replayTdxRegisters(parseEventLog(trustDomainLogFor(image)))
  for i in 0 ..< TdxRtMrCount:
    result[i] = toHexLower(replay.registers[i])

let ukiRegisters = registersFor(uki)
let alteredRegisters = registersFor(alteredUki)

proc measurementsFor(snpHex: string;
                     registers: array[TdxRtMrCount, string]):
                    CvmMeasurements =
  CvmMeasurements(
    snpMeasurementHex: snpHex,
    tdxMrtdHex: tdxMrtd,
    tdxRtmrHex: registers,
    ovmfDigest: DigestPrefix &
      sha256Hex(cvmStringOf(firmwareFor(statedShapeFor(BaseShape)))),
    vcpus: statedShapeFor(BaseShape).vcpus,
    vcpuType: "Milan")

proc failingSet(v: Verdict): set[VerifierCheck] =
  for c in VerifierCheck:
    if v.checks[c].outcome == coFailed: result.incl c

suite "a ReproOS-shaped image through the confidential-computing path":

  test "the image is a real PE32+ the library's own reader walks":
    ## Not a byte string shaped like one: the library's section-table
    ## reader finds the six sections, and its measurement walk measures
    ## the ones a stub measures, in its own order.
    let sections = readPeSectionTable(uki)
    check sections.len == 6
    var names: seq[string] = @[]
    for s in sections: names.add s.name
    check names == @[".sbat", ".osrel", ".cmdline", ".uname", ".initrd",
                     ".linux"]
    let measured = measureUkiPcr11(uki)
    check measured.events.len == 6
    var order: seq[string] = @[]
    for e in measured.events: order.add e.section
    # The MEASUREMENT order is the library's, and it is not the file
    # order above — which is what makes this image an input worth
    # having rather than one whose two orders agree by accident.
    check order == @[".linux", ".osrel", ".cmdline", ".initrd", ".uname",
                     ".sbat"]
    check order != names
    check measured.pcr11.len == 64
    check measured.pcr11 != ZeroPcr
    # And a one-character command line moves it, which is the property
    # every measurement claim below rests on.
    check measureUkiPcr11(alteredUki).pcr11 != measured.pcr11

  test "the image reaches the security processor's launch measurement":
    ## The kernel-digest page is what carries it: the hypervisor puts
    ## the digests of the kernel, the initial ramdisk and the command
    ## line into a page the launch measurement covers.
    let digests = kernelDigestsFor(
      toOpenArrayByte(uki, 0, uki.len - 1), [], ReproosCmdline)
    check cvmHexOf(digests.kernel) == sha256Hex(uki)
    check digests.kernel.len == 32
    # The shape with the image as its kernel is not the shape upstream
    # states a digest for, and the digests differ — so the image
    # genuinely reaches the number.
    check ukiDigest.len == 96
    check ukiDigest != statedDigestFor(BaseShape)
    # One character of the command line moves it, and so does one byte
    # of the image, separately.
    check alteredDigest != ukiDigest
    let sameImageOtherCmdline =
      launchDigestHex(ukiLaunchParameters(uki, AlteredCmdline))
    check sameImageOtherCmdline != ukiDigest
    let otherImageSameCmdline =
      launchDigestHex(ukiLaunchParameters(alteredUki, ReproosCmdline))
    check otherImageSameCmdline != ukiDigest
    check otherImageSameCmdline != sameImageOtherCmdline
    # And the calculation is a function of its inputs: the same image
    # and the same command line give the same number twice.
    check launchDigestHex(ukiLaunchParameters(uki, ReproosCmdline)) ==
      ukiDigest

  test "the emulated security-processor report carries it end to end":
    let m = measurementsFor(ukiDigest, ukiRegisters)
    let run = buildCvmRun(cbSnp, m, cemNone, nowSeconds)
    let v = verifyAttestationReport(cvmVerificationRequestFor(run))
    checkpoint($v.decision & " failed: " & $v.failedChecks)
    check failingSet(v) == cvmBaselineFailures(cbSnp)
    check v.checks[vcMeasurementMatch].outcome == coPassed
    check v.checks[vcNativeEvidence].outcome == coPassed
    let report = parseAttestationReport(run.reportText, "<uki run>")
    let reading = readAuthoritativeEvidence(report)
    check reading.inputs.launchMeasurement == some(ukiDigest)

  test "a one-character command-line change is refused":
    ## The manifest is the ORIGINAL image's. The machine reports the
    ## ALTERED one's measurement. Nothing else differs, and the
    ## verifier's measurement row is what notices.
    let honest = measurementsFor(ukiDigest, ukiRegisters)
    let lying = measurementsFor(alteredDigest, ukiRegisters)
    var run = buildCvmRun(cbSnp, lying, cemNone, nowSeconds)
    # The manifest and the policy come from the honest image; only the
    # evidence is the altered one's.
    run.manifestText = cvmManifestText(cbSnp, honest)
    run.policyText = cvmPolicyText(cbSnp, cvmManifestDigest(cbSnp, honest))
    let v = verifyAttestationReport(cvmVerificationRequestFor(run))
    check v.checks[vcMeasurementMatch].outcome == coFailed
    checkpoint(v.checks[vcMeasurementMatch].detail)
    check alteredDigest in v.checks[vcMeasurementMatch].detail
    check ukiDigest in v.checks[vcMeasurementMatch].detail
    # The manifest is still the one the policy pins, so the ONLY row
    # this moves is the measurement — which is what makes the refusal
    # attributable to the command line rather than to the paperwork.
    check v.checks[vcManifestPinned].outcome == coPassed
    check failingSet(v) ==
      cvmBaselineFailures(cbSnp) + {vcMeasurementMatch}

  test "the image reaches the trust domain's runtime registers":
    ## The fold is the library's, and the log goes through the
    ## library's own parser on the way in. What the image decides is
    ## the value of one register; the others are the firmware's and do
    ## not move.
    let replay = replayTdxRegisters(parseEventLog(trustDomainLogFor(uki)))
    check replay.extendsApplied == 2 + 2 * 6
    let reset = toHexLower(initialRtmr())
    check replay.reached[TrustDomainUkiRegister]
    check ukiRegisters[TrustDomainUkiRegister] != reset
    check ukiRegisters[0] != reset
    # Registers nothing extended hold their reset value, and the gate
    # says which is which rather than comparing a register that was
    # never written.
    check ukiRegisters[1] == reset
    check ukiRegisters[3] == reset
    check not replay.reached[1]
    check not replay.reached[3]
    # One character of the command line moves the register the image
    # owns and nothing else.
    check alteredRegisters[TrustDomainUkiRegister] !=
      ukiRegisters[TrustDomainUkiRegister]
    for i in 0 ..< TdxRtMrCount:
      if i == TrustDomainUkiRegister: continue
      checkpoint("register " & $i)
      check alteredRegisters[i] == ukiRegisters[i]

  test "the emulated trust-domain quote carries both halves end to end":
    let m = measurementsFor(ukiDigest, ukiRegisters)
    let run = buildCvmRun(cbTdx, m, cemNone, nowSeconds)
    let v = verifyAttestationReport(cvmVerificationRequestFor(run))
    checkpoint($v.decision & " failed: " & $v.failedChecks)
    check failingSet(v) == cvmBaselineFailures(cbTdx)
    check v.checks[vcMeasurementMatch].outcome == coPassed
    check v.checks[vcNativeEvidence].outcome == coPassed
    let report = parseAttestationReport(run.reportText, "<uki run>")
    let quote = parseTdxQuote(toOpenArrayByte(authoritativeEvidence(report),
      0, authoritativeEvidence(report).len - 1))
    check cvmHexOf(quote.body.mrTd) == tdxMrtd
    for i in 0 ..< TdxRtMrCount:
      checkpoint("register " & $i)
      check cvmHexOf(quote.body.rtMr[i]) == ukiRegisters[i]

  test "the runtime registers reach the manifest and no check reads them":
    ## A finding, asserted rather than noted. The manifest schema
    ## carries three runtime registers and the verifier's measurement
    ## row compares the initial-memory measurement alone — so two
    ## images that differ ONLY in a runtime register are the same
    ## machine as far as this build's verdict is concerned.
    ##
    ## It is written as a case so that a build which grew the
    ## comparison reddens here and has to correct the claim, which is
    ## the opposite of a gap nobody notices.
    let honest = measurementsFor(ukiDigest, ukiRegisters)
    let other = measurementsFor(ukiDigest, alteredRegisters)
    # The two manifests really do differ, and in the registers only.
    check cvmManifestText(cbTdx, honest) != cvmManifestText(cbTdx, other)
    check cvmManifest(cbTdx, honest).tdx[0].mrtd ==
      cvmManifest(cbTdx, other).tdx[0].mrtd
    check cvmManifest(cbTdx, honest).tdx[0].rtmr2 !=
      cvmManifest(cbTdx, other).tdx[0].rtmr2
    # A machine reporting the ALTERED registers against the HONEST
    # manifest still passes the measurement row.
    var run = buildCvmRun(cbTdx, other, cemNone, nowSeconds)
    run.manifestText = cvmManifestText(cbTdx, honest)
    run.policyText = cvmPolicyText(cbTdx, cvmManifestDigest(cbTdx, honest))
    let v = verifyAttestationReport(cvmVerificationRequestFor(run))
    check v.checks[vcMeasurementMatch].outcome == coPassed
    # And the quote really did carry the other registers, so the row
    # above passed on a machine the manifest does not describe.
    let report = parseAttestationReport(run.reportText, "<other registers>")
    let quote = parseTdxQuote(toOpenArrayByte(authoritativeEvidence(report),
      0, authoritativeEvidence(report).len - 1))
    check cvmHexOf(quote.body.rtMr[TrustDomainUkiRegister]) ==
      alteredRegisters[TrustDomainUkiRegister]
    check cvmHexOf(quote.body.rtMr[TrustDomainUkiRegister]) !=
      cvmManifest(cbTdx, honest).tdx[0].rtmr2

  test "the initial-memory measurement is the firmware's, not the image's":
    ## Which is why the case above is a finding rather than a defect in
    ## this gate: an image cannot move a trust domain's initial-memory
    ## measurement, so the row that DOES compare something is reading
    ## the one value an image has no influence over.
    check registersFor(uki) != registersFor(alteredUki)
    check tdxMrtdHex(
      toOpenArrayByte(tdxVector.firmware, 0, tdxVector.firmware.len - 1),
      tdxVector.order) == tdxMrtd
    check tdxMrtd == tdxVector.mrtd

## The computed trust-domain expectation, from the command that writes
## it to the verdict row that reads it.
##
## ## Why this gate exists
##
## Two findings in this repository's history are the same shape one layer
## apart. One backend's whole verification arm could report "satisfied"
## whatever the chain underneath had decided, and nothing anywhere
## failed. A reader list did not name a reader that had just been added,
## so every verdict would have carried a caveat that was false. Both were
## headline claims with no case.
##
## The claim here is that an expectation this build COMPUTES reaches a
## verdict row a verifier READS. That is two halves and they are proved
## separately:
##
##   * the command writes a document whose measurement is the one
##     computed from the firmware, and whose three runtime registers are
##     the ones replayed from the domain's own record;
##   * and the verifier's measurement row PASSES against a document
##     carrying this domain's measurement and FAILS against one carrying
##     another real domain's — same quote, same policy, same clock. A row
##     that answered the same thing either way would be identical in
##     both, which is exactly the defect that was found one backend over.
##
## ## The negative is a real value, not a string of zeroes
##
## The measurement the failing case supplies is the OTHER genuine
## operator's, out of the other genuine quote. A negative built from
## zeroes would also fail, and would prove only that the row compares
## something.
##
## ## Mocking
##
## None. Real firmware, a real record, real quotes, and the real command.

import std/[base64, options, os, strutils, unittest]

import repro_attest
import repro_attest_verify
import repro_attest_verify/tdx_quote
import repro_attest_verify/tdx_collateral
import repro_cli_support/attest

include ./tdx_launch_vectors

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len: result[i] = byte(s[i])

proc stringOf(b: openArray[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

proc documentOf(c: TdxLaunchCase): string =
  let v = TdxLaunchVectors[c]
  v.quote[0 ..< v.documentBytes]

let scratch = getTempDir() / ("tdx-expectation-" & $getCurrentProcessId())
createDir(scratch)

proc scratchFile(name, content: string): string =
  result = scratch / name
  writeFile(result, content)

const
  Fingerprint = "reproos-attested-uefi:trust-domain"
  RootHash = repeat("44", 32)
  VerityDigest = "sha256:" & repeat("55", 32)

proc baseArgs(outPath: string): seq[string] =
  @["expect",
    "--uki", scratchFile("uki.bin", "not-a-real-unified-kernel-image"),
    "--verity-image-digest", VerityDigest,
    "--verity-root-hash", RootHash,
    "--config-fingerprint", Fingerprint,
    "--backend", "tdx",
    "--out", outPath]

let firmwarePath = scratchFile("ovmf.fd", FirmwareDstack)
let recordPath = scratchFile("record.json", RegisterLogOperatorB)

proc launchArgs(order = "per-region"): seq[string] =
  @["--td-firmware", firmwarePath, "--td-register-log", recordPath,
    "--td-page-order", order]

# Standard error is captured for the whole gate. The refusals below are
# READ rather than counted: a case that asserted only the exit status
# would be satisfied by any of the command's other refusals, which is
# how assertions in this tree are most often defeated.
let stderrLog = scratchFile("stderr.log", "")
doAssert reopen(stderr, stderrLog, fmWrite)

proc runCapturing(args: seq[string]): tuple[code: int; err: string] =
  flushFile(stderr)
  let before = getFileSize(stderrLog)
  result.code = runAttestCommand(args)
  flushFile(stderr)
  var f: File
  doAssert open(f, stderrLog, fmRead)
  f.setFilePos(before)
  result.err = f.readAll()
  f.close()

const
  OtherCommandRefusals: array[4, string] = [
    "describes a trust-domain launch and no --td-firmware was given",
    "--td-register-log is required with it",
    "--td-page-order is required with it",
    "no fold order by the name the caller gave"]
    ## Every OTHER sentence this command can answer a malformed
    ## trust-domain launch with. A case asserting one of them asserts
    ## the absence of all the others, so it cannot be satisfied by a
    ## neighbour picking up the input.

proc onlyRefusal(err: string; expected: string) =
  check expected in err
  for other in OtherCommandRefusals:
    if other != expected:
      check other notin err

suite "the command writes what this build computed":

  test "the document carries the measurement of the firmware it was given":
    let outPath = scratch / "manifest.json"
    let r = runCapturing(baseArgs(outPath) & launchArgs())
    check r.code == AttestExitAccepted
    let m = parseAttestedImageManifest(readFile(outPath), outPath)
    check m.tdx.len == 1
    # Three producers for one value: the command's document, this
    # build's calculator, and the quote a machine signed.
    let q = parseTdxQuote(bytesOf(documentOf(lcOperatorB)))
    check m.tdx[0].mrtd == TdxLaunchVectors[lcOperatorB].mrtd
    check m.tdx[0].mrtd == tdxMrtdHex(bytesOf(FirmwareDstack),
      thoExtendAfterTheRegion)
    check m.tdx[0].mrtd == hexOf(q.body.mrTd).toLowerAscii
    # And the runtime registers are the domain's own, replayed.
    check m.tdx[0].rtmr0 == hexOf(q.body.rtMr[0]).toLowerAscii
    check m.tdx[0].rtmr1 == hexOf(q.body.rtMr[1]).toLowerAscii
    check m.tdx[0].rtmr2 == hexOf(q.body.rtMr[2]).toLowerAscii
    # None of them is a reset value, which is what the rule that refuses
    # to publish one exists to guarantee.
    check m.tdx[0].rtmr0 != repeat("00", 48)
    check m.tdx[0].rtmr1 != repeat("00", 48)
    check m.tdx[0].rtmr2 != repeat("00", 48)

  test "the fold order is a real parameter of the command":
    # The value, not merely the flag. Passing the other order produces a
    # DIFFERENT document, so a build that ignored it would be visible.
    let outPath = scratch / "manifest-other-order.json"
    let r = runCapturing(baseArgs(outPath) & launchArgs("per-page"))
    check r.code == AttestExitAccepted
    let m = parseAttestedImageManifest(readFile(outPath), outPath)
    check m.tdx.len == 1
    check m.tdx[0].mrtd != TdxLaunchVectors[lcOperatorB].mrtd
    # The runtime registers do not depend on it, and that is not an
    # accident either: they come from the record, not from the firmware.
    let q = parseTdxQuote(bytesOf(documentOf(lcOperatorB)))
    check m.tdx[0].rtmr0 == hexOf(q.body.rtMr[0]).toLowerAscii

  test "no launch supplied leaves the array visibly EMPTY":
    let outPath = scratch / "manifest-empty.json"
    check runCapturing(baseArgs(outPath)).code == AttestExitAccepted
    let text = readFile(outPath)
    check "\"tdx\": []" in text
    check parseAttestedImageManifest(text, outPath).tdx.len == 0

suite "the command's refusals, read rather than counted":

  test "a record with no firmware measures nothing":
    let outPath = scratch / "m1.json"
    let r = runCapturing(baseArgs(outPath) &
      @["--td-register-log", recordPath])
    check r.code == 2
    onlyRefusal(r.err,
      "describes a trust-domain launch and no --td-firmware was given")

  test "an order with no firmware measures nothing":
    let outPath = scratch / "m2.json"
    let r = runCapturing(baseArgs(outPath) &
      @["--td-page-order", "per-region"])
    check r.code == 2
    onlyRefusal(r.err,
      "describes a trust-domain launch and no --td-firmware was given")

  test "a firmware with no record cannot fill three of the four rows":
    let outPath = scratch / "m3.json"
    let r = runCapturing(baseArgs(outPath) &
      @["--td-firmware", firmwarePath])
    check r.code == 2
    onlyRefusal(r.err, "--td-register-log is required with it")

  test "a firmware with no order would be a number no machine reports":
    let outPath = scratch / "m4.json"
    let r = runCapturing(baseArgs(outPath) &
      @["--td-firmware", firmwarePath, "--td-register-log", recordPath])
    check r.code == 2
    onlyRefusal(r.err, "--td-page-order is required with it")

  test "an order this build does not know":
    let outPath = scratch / "m5.json"
    let r = runCapturing(baseArgs(outPath) & launchArgs("per-everything"))
    check r.code == 2
    onlyRefusal(r.err, "no fold order by the name the caller gave")

  test "a launch measured for a backend not being published is refused":
    # Not dropped. A parameter that does nothing is a lie about what was
    # published.
    let outPath = scratch / "m6.json"
    let args = @["expect",
      "--uki", scratchFile("uki2.bin", "x"),
      "--verity-image-digest", VerityDigest,
      "--verity-root-hash", RootHash,
      "--config-fingerprint", Fingerprint,
      "--backend", "tpm",
      "--out", outPath] & launchArgs()
    let r = runCapturing(args)
    check r.code == 2
    check "is not among the backends being computed" in r.err

# ---------------------------------------------------------------------
# The verdict row
# ---------------------------------------------------------------------

const
  TdxPolicy = """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["cvm"]
backends = ["tdx"]
allow_mock = false

[measurements]
manifests = []
require_certificates = true

[freshness]
max_challenge_age_seconds = 0
require_challenge = false

[tcb]
allow_grace_days = 0

[tcb.tdx]
min_tcb_status = "UpToDate"
"""
  Challenge = repeat("ab", 32)
  NowMs = 1_790_000_000_000'i64

proc base64Of(b: openArray[byte]): string = base64.encode(stringOf(b))

proc reportFor(c: TdxLaunchCase): string =
  let q = parseTdxQuote(bytesOf(documentOf(c)))
  var certs: seq[string] = @[]
  for der in q.pckChain: certs.add base64Of(der)
  renderAttestationReport(AttestationReport(
    tier: atCvm, backend: abTdx,
    timestampInformational: "2026-09-22T00:00:00Z",
    challenge: Challenge,
    reportData: reportDataHexFor(
      ReportBindings(purpose: bpAttest), Challenge),
    bindings: ReportBindings(purpose: bpAttest),
    evidence: base64Of(q.raw),
    certificates: some(certs),
    claims: UnverifiedClaims(
      unverifiedGeneration: "gen-2026-09-22-0001",
      unverifiedConfigFingerprint: Fingerprint,
      unverifiedVerityRootHash: RootHash)))

proc manifestCarrying(e: TdxExpectation): string =
  renderAttestedImageManifest(AttestedImageManifest(
    configFingerprint: Fingerprint,
    imageOutputs: ImageOutputs(
      uki: DigestPrefix & repeat("66", 32),
      verityImage: VerityDigest,
      verityRootHash: RootHash),
    tdx: @[e]))

proc verdictFor(reportText, manifestText: string): Verdict =
  verifyAttestationReport(VerificationRequest(
    reportText: reportText, reportSource: "<fixture>",
    policy: parseAttestationPolicy(TdxPolicy, "<fixture policy>"),
    policySource: "<fixture policy>",
    manifestText: some(manifestText),
    manifestSource: "<verifier's own manifest>",
    nowMs: NowMs,
    vendorRevocationLists: @[],
    vendorCollateral: TdxCollateralBundle(),
    hasVendorCollateral: false))

suite "the expectation reaches the verdict":

  test "the measurement row passes on this domain and fails on the other":
    # The SAME quote, the SAME policy, the SAME clock, two documents.
    # This is the case the other backend's arm did not have.
    let computed = tdxExpectationFor(TdxLaunchInputs(
      firmware: FirmwareDstack,
      registerLog: RegisterLogOperatorB,
      order: thoExtendAfterTheRegion))
    let report = reportFor(lcOperatorB)

    let matching = verdictFor(report, manifestCarrying(computed))
    check matching.checks[vcMeasurementMatch].outcome == coPassed

    # The negative is the OTHER genuine operator's measurement, taken
    # from the other genuine quote — a real value, not a row of zeroes.
    var other = computed
    other.mrtd = TdxLaunchVectors[lcOperatorA].mrtd
    check other.mrtd != computed.mrtd
    let mismatching = verdictFor(report, manifestCarrying(other))
    check mismatching.checks[vcMeasurementMatch].outcome == coFailed
    check computed.mrtd in mismatching.checks[vcMeasurementMatch].detail

  test "the row is about the measurement and not about the registers":
    # Moving a runtime register must NOT move this row: the schema's
    # comparison is over the initial-memory measurement, and a row that
    # also moved with the registers would be answering a different
    # question from the one its name states.
    let computed = tdxExpectationFor(TdxLaunchInputs(
      firmware: FirmwareDstack,
      registerLog: RegisterLogOperatorB,
      order: thoExtendAfterTheRegion))
    var bentRegisters = computed
    bentRegisters.rtmr1 = repeat("77", 48)
    check bentRegisters.rtmr1 != computed.rtmr1
    let v = verdictFor(reportFor(lcOperatorB),
                       manifestCarrying(bentRegisters))
    check v.checks[vcMeasurementMatch].outcome == coPassed

  test "the document the command wrote is the document the row reads":
    # Not a document assembled here that happens to look like it. The
    # file on disk goes straight into the verifier.
    let outPath = scratch / "manifest-for-verdict.json"
    check runCapturing(baseArgs(outPath) & launchArgs()).code ==
      AttestExitAccepted
    let v = verdictFor(reportFor(lcOperatorB), readFile(outPath))
    check v.checks[vcMeasurementMatch].outcome == coPassed

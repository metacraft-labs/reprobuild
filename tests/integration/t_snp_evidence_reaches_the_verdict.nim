## The security-processor arm of the verifier, from a document a real
## part signed to the verdict rows a caller reads.
##
## ## What was true before this gate existed
##
## `readAuthoritativeEvidence` had four arms and three readers. The
## fourth answered *"this build carries no reader for \"sev-snp\"
## evidence"* and stopped, which meant three further rows downstream had
## **no reachable input at all**: the launch-measurement comparison, the
## trusted-computing-base floor, and the binding between the envelope's
## 64 bytes and the evidence's. The sibling change that published the
## manifest side of that comparison said so out loud rather than letting
## it look wired — *"that arm still has no input"* — and left it here.
##
## This gate is the answer, and it is written to the shape that caught
## two of this repository's worst defects: **an arm that reports the same
## thing whatever it was given is indistinguishable from an arm that
## works.** So nothing below asserts merely that a row passes. Every
## claim is a row that CHANGES, over one document, with exactly one
## thing different between the two runs.
##
## ## What cannot be reached here, and it is the headline limit
##
## **No verdict in this file is an acceptance, and none can be.** The
## envelope's 64 bytes are computed from the challenge a verifier
## issued; a genuine report's 64 bytes were chosen by a real machine
## answering a challenge somebody else issued, years ago. The two cannot
## be made equal without a part signing something this repository asked
## for, so the report-data binding row FAILS on every genuine document
## here — and it fails for the right reason, which the case asserts by
## reading both values out of its detail.
##
## That is the one row confidential-computing hardware is needed for,
## and it is what live validation will be the first to close.
##
## ## The negatives are real values
##
## Where a row must fail, it is made to fail with the OTHER genuine
## part's own measurement, the OTHER genuine part's own endorsement
## certificate, or a floor one real platform meets and the other does
## not. A negative built from zeroes would prove only that a comparison
## compares something.
##
## ## Mocking
##
## None. Two real AMD parts, their real endorsement certificates, the
## vendor's real signing key and root, the real policy reader, the real
## manifest schema and the real verifier.

import std/[options, os, strutils, unittest]

import repro_attest
import repro_attest_verify
import repro_attest_verify/snp_report

include ./snp_vectors
include ./attestation_verifier_harness

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

proc bytesOfHex(h: string): seq[byte] =
  var compact = ""
  for c in h:
    if c in {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}: compact.add c
  doAssert compact.len mod 2 == 0
  result = newSeq[byte](compact.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(compact[2 * i .. 2 * i + 1]))

proc stringOfHex(h: string): string =
  for b in bytesOfHex(h): result.add char(b)

proc hexOfBytes(b: openArray[byte]): string =
  for x in b: result.add toHex(int(x), 2).toLowerAscii

proc base64Decode(text: string): string =
  const Alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  var acc = 0
  var bits = 0
  for c in text:
    if c == '=': break
    let idx = Alphabet.find(c)
    if idx < 0: continue
    acc = (acc shl 6) or idx
    bits += 6
    if bits >= 8:
      bits -= 8
      result.add char((acc shr bits) and 0xff)

proc pemCertificates(text: string): seq[string] =
  const Begin = "-----BEGIN CERTIFICATE-----"
  const End = "-----END CERTIFICATE-----"
  var pos = 0
  while true:
    let b = text.find(Begin, pos)
    if b < 0: break
    let e = text.find(End, b)
    if e < 0: break
    result.add base64Decode(text[b + Begin.len ..< e])
    pos = e + End.len

proc pemBlockAt(text: string; index: int): string =
  const Begin = "-----BEGIN CERTIFICATE-----"
  const End = "-----END CERTIFICATE-----"
  var pos = 0
  var n = 0
  while true:
    let b = text.find(Begin, pos)
    if b < 0: break
    let e = text.find(End, b)
    if e < 0: break
    if n == index: return text[b ..< e + End.len]
    inc n
    pos = e + End.len
  raise newException(ValueError, "no such armoured block")

proc le32(v: int): string =
  result.add char(v and 0xff)
  result.add char((v shr 8) and 0xff)
  result.add char((v shr 16) and 0xff)
  result.add char((v shr 24) and 0xff)

proc certTable(entries: seq[(string, string)]): string =
  let indexLen = (entries.len + 1) * SnpCertTableEntryLen
  var index = ""
  var payloads = ""
  var at = indexLen
  for (guid, payload) in entries:
    index.add guidBytes(guid)
    index.add le32(at)
    index.add le32(payload.len)
    payloads.add payload
    at += payload.len
  index.add repeat('\x00', SnpCertTableEntryLen)
  result = index & payloads

let milanChain = pemCertificates(KdsMilanChainPem)
let milanCrl = stringOfHex(KdsMilanCrlDerHex)

type Part = object
  name: string
  reportHex: string
  vcekDerHex: string

let partA = Part(name: "virtee/sev's Milan part",
                 reportHex: VirteeMilanReportHex,
                 vcekDerHex: VirteeMilanVcekDerHex)
let partB = Part(name: "go-sev-guest's Milan part",
                 reportHex: GsgMilanReportHex,
                 vcekDerHex: GsgMilanVcekDerHex)

proc reportOf(p: Part): SnpReport = parseSnpReport(bytesOfHex(p.reportHex))

proc chainOf(p: Part): seq[string] =
  @[stringOfHex(p.vcekDerHex), milanChain[0], milanChain[1]]

proc auxblobOf(p: Part): string =
  ## The host-loaded certificate table, in the shape a host really ends
  ## up with: the endorsement certificate raw and the vendor's chain
  ## armoured. Built here from genuine certificates; the framing is the
  ## vendor's published layout.
  certTable(@[(SnpVcekGuid, stringOfHex(p.vcekDerHex)),
              (SnpAskGuid, pemBlockAt(KdsMilanChainPem, 0)),
              (SnpArkGuid, pemBlockAt(KdsMilanChainPem, 1))])


# ---------------------------------------------------------------------
# Provenance
# ---------------------------------------------------------------------

type
  VerdictCorpus* = enum
    ## Every byte corpus this gate reads, enumerated so a corpus cannot
    ## exist without a row and a row cannot exist without a corpus. All
    ## six are already pinned by a sibling; this change introduces no
    ## new byte corpus anywhere.
    vcVirteeReport
    vcGsgReport
    vcVirteeVcek
    vcGsgVcek
    vcKdsMilanChain
    vcKdsMilanCrl

  VerdictCorpusRow* = object
    name*: string
    bytes*: int
    sha256*: string

const
  VerdictCorpora*: array[VerdictCorpus, VerdictCorpusRow] = [
    vcVirteeReport: VerdictCorpusRow(name: "VirteeMilanReportHex",
      bytes: 1184,
      sha256: "120d77b213c8868dd42f160ccb0114f05336ec715f6d51070f534b33c7e03f3b"),
    vcGsgReport: VerdictCorpusRow(name: "GsgMilanReportHex", bytes: 1184,
      sha256: "377e6241d3b373ab1df80c0f96978594e7e21f4797dd6ea95e2957e1c1e26060"),
    vcVirteeVcek: VerdictCorpusRow(name: "VirteeMilanVcekDerHex",
      bytes: 1360,
      sha256: "3bbfb6ee259f75a95d13168cfdf2e034181bb93c7c016825731cbe8ea16c95e1"),
    vcGsgVcek: VerdictCorpusRow(name: "GsgMilanVcekDerHex", bytes: 1360,
      sha256: "0d057f9b6e29a69eda9c0154b259567d291c1c08d73a11e9d31ace07c435b6d8"),
    vcKdsMilanChain: VerdictCorpusRow(name: "KdsMilanChainPem", bytes: 4602,
      sha256: "22e62f8d2c21a156470145fc75f7b5a377cb053ced3e97f0bd3f8d8ca5941ce6"),
    vcKdsMilanCrl: VerdictCorpusRow(name: "KdsMilanCrlDerHex", bytes: 866,
      sha256: "873efcf8c8cedc28c603cf50acdff8556a704658357a0d9daab297f483deb0df")]

proc verdictCorpusBytes(c: VerdictCorpus): string =
  case c
  of vcVirteeReport: stringOfHex(VirteeMilanReportHex)
  of vcGsgReport: stringOfHex(GsgMilanReportHex)
  of vcVirteeVcek: stringOfHex(VirteeMilanVcekDerHex)
  of vcGsgVcek: stringOfHex(GsgMilanVcekDerHex)
  of vcKdsMilanChain: KdsMilanChainPem
  of vcKdsMilanCrl: milanCrl

# ---------------------------------------------------------------------
# The documents a verifier is given
# ---------------------------------------------------------------------

proc snpReportTextFor(p: Part; chain: Option[seq[string]];
                      challengeHex = HarnessChallenge): string =
  let bindings = ReportBindings(purpose: bpAttest, ephemeralPub: "")
  renderAttestationReport(attestationReport(abSevSnp, SampleTimestamp,
    challengeHex, bindings, stringOfHex(p.reportHex), sampleClaims(),
    chain))

proc snpManifestText(measurementHex: string): string =
  var m = sampleManifest()
  m.sevSnp = @[SevSnpExpectation(vcpus: 1, vcpuType: "EPYC-v4",
    ovmf: DigestPrefix & sha256Hex("fixture-ovmf"), policy: "0x30000",
    measurement: measurementHex)]
  renderAttestedImageManifest(m)

proc snpPolicyText(manifestDigest: string;
                   bootloader, tee, snp, microcode: int): string =
  ## The production policy with ONE thing settable: the platform-version
  ## floor. Everything else is the shipped template, so a row that moves
  ## between two calls moved because of the floor.
  """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["cvm"]
backends = ["sev-snp", "tdx"]
allow_mock = false

[measurements]
manifests = ["@DIGEST@"]
require_certificates = true

[tcb]
sev-snp.min_tcb = { bootloader = @BL@, tee = @TEE@, snp = @SNP@, microcode = @UC@ }
tdx.min_tcb_status = "UpToDate"
allow_grace_days = 14

[freshness]
max_challenge_age_seconds = 120
require_challenge = true
""".replace("@DIGEST@", manifestDigest)
   .replace("@BL@", $bootloader).replace("@TEE@", $tee)
   .replace("@SNP@", $snp).replace("@UC@", $microcode)

const Now = 1_789_000_000'i64
  ## A fixed instant, so nothing below can move because the clock did.

proc verdictFor(p: Part; manifestText: string;
                bootloader, tee, snp, microcode: int;
                chain = some(seq[string](@[])); crls = true): Verdict =
  let useChain =
    if chain.isSome and chain.get.len == 0: some(chainOf(p)) else: chain
  let text = snpReportTextFor(p, useChain)
  let digest = DigestPrefix & sha256Hex(manifestText)
  var req = verificationRequest(text,
    parseAttestationPolicy(snpPolicyText(digest, bootloader, tee, snp,
                                         microcode), "<gate policy>"),
    some(manifestText), issuedAtMs = some(Now * 1000), nowMs = Now * 1000)
  if crls: req.vendorRevocationLists.add milanCrl
  verifyAttestationReport(req)

proc floorOf(p: Part): tuple[bootloader, tee, snp, microcode: int] =
  let t = reportOf(p).reportedTcb
  (t.bootloader, t.tee, t.snp, t.microcode)

# ---------------------------------------------------------------------

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir

suite "the package boundary the agent side rests on":

  test "the agent's module closure does not reach the verifier":
    # The mirror of the check the verdict gate makes in the other
    # direction, and it is the structural half of a claim this
    # change's modules make in prose: the agent sits INSIDE every
    # attested trusted computing base, so code that decides whether to
    # trust must not ship there. The two readers of one field are
    # transcribed twice for exactly this reason, and a gate that only
    # said so in a comment would not notice an `import` restoring the
    # edge.
    let libs = RepoRoot / "libs"
    let entry = libs / "repro_attest" / "src" / "repro_attest.nim"
    check fileExists(entry)
    let closure = moduleClosure(libs, entry)

    # The positive control FIRST. A walker that resolved nothing would
    # return one entry and satisfy every negative below it.
    var names: seq[string] = @[]
    for path in closure: names.add path.extractFilename
    for wanted in ["tsm_report.nim", "snp_backend.nim", "tdx_backend.nim",
                   "driver.nim", "report.nim", "binding.nim",
                   "tpm2_backend.nim", "mock_backend.nim"]:
      check wanted in names
    check closure.len >= 13

    # The boundary itself, in both spellings a module could use.
    for path in closure:
      check "repro_attest_verify" notin path
      check "repro_attest_agent" notin path

suite "provenance":

  test "every corpus this gate reads is the size and the bytes recorded":
    var seen = 0
    for c in VerdictCorpus:
      let row = VerdictCorpora[c]
      inc seen
      check row.name.len > 0
      check row.sha256.len == 64
      let bytes = verdictCorpusBytes(c)
      check bytes.len == row.bytes
      check sha256Hex(bytes) == row.sha256
    check seen == ord(high(VerdictCorpus)) + 1
    check seen == 6

suite "this build now carries a reader for every backend it names":

  test "the reader is named, so no verdict is caveated as the caller's":
    # The trust-domain reader was missing from this list for exactly as
    # long as it existed, and every verdict it produced would have been
    # caveated with a sentence that was false. The same list, the same
    # gate shape, in the change that adds the reader.
    var named = false
    for r in BuiltInReaders:
      if r == SnpReaderName: named = true
    check named
    check BuiltInReaders.len == ord(high(AttestationBackend)) + 1

  test "and the caveat does not appear on a verdict it produced":
    let f = floorOf(partA)
    let v = verdictFor(partA, snpManifestText(
      hexOfBytes(reportOf(partA).measurement)),
      f.bootloader, f.tee, f.snp, f.microcode)
    for c in v.caveats:
      check "which is not a reader this build carries" notin c

suite "the native-evidence row has input for the first time":

  test "a genuine report with its genuine chain SATISFIES the row":
    for p in [partA, partB]:
      let f = floorOf(p)
      let v = verdictFor(p, snpManifestText(
        hexOfBytes(reportOf(p).measurement)),
        f.bootloader, f.tee, f.snp, f.microcode)
      checkpoint v.checks[vcNativeEvidence].detail
      check v.checks[vcNativeEvidence].outcome == coPassed
      check v.checks[vcNativeEvidence].kind == fkSatisfied
      # And it says WHAT it established and what it did not.
      check "security-processor attestation report" in
        v.checks[vcNativeEvidence].detail
      check "VCEK" in v.checks[vcNativeEvidence].detail
      check "certificate-chain check's question" in
        v.checks[vcNativeEvidence].detail

  test "the reading NAMES the key it checked, and the verdict carries it":
    # `attestationKeySubject` is what makes "a signature was checked"
    # answerable — a flag cannot say WHICH key. Nothing asserted it for
    # this backend until a mutation that set it to `none` passed every
    # case, which is the definition of a field nobody reads.
    for p in [partA, partB]:
      let text = snpReportTextFor(p, some(chainOf(p)))
      let report = parseAttestationReport(text, "<gate>")
      let reading = readAuthoritativeEvidence(report)
      check reading.finding.kind == fkSatisfied
      check reading.inputs.attestationKeySubject.isSome
      let named = reading.inputs.attestationKeySubject.get
      check named.len > 0
      # It is the subject of the certificate the report bundles, not a
      # placeholder: the same description appears in the finding the
      # verdict prints, so the two cannot drift apart.
      check named in reading.finding.detail

  test "the two genuine parts agree on all four platform-version fields":
    # A CORPUS LIMIT, pinned rather than left to be discovered. Both
    # genuine reports carry the same value in `reportedTcb`,
    # `launchTcb`, `currentTcb` and `committedTcb`, so no case here can
    # tell which of the four the reader hands to the floor — a mutation
    # that reads the launch base instead of the reported one passes
    # every case above, and it does so because of this, not because the
    # floor is unwired.
    #
    # Pinned as an EQUALITY so it is a ratchet: a fixture whose four
    # fields differ makes this case fail, and whoever adds it then has
    # to write the case that discriminates.
    for p in [partA, partB]:
      let r = reportOf(p)
      check r.reportedTcb.raw == r.launchTcb.raw
      check r.reportedTcb.raw == r.currentTcb.raw
      check r.reportedTcb.raw == r.committedTcb.raw

  test "the signature is really checked: the other part's key fails":
    # Both certificates are genuine; both parts are genuine. The one
    # thing different between the two runs is which part's endorsement
    # certificate the report bundles, and the row moves.
    let f = floorOf(partA)
    let manifest = snpManifestText(hexOfBytes(reportOf(partA).measurement))
    let mine = verdictFor(partA, manifest, f.bootloader, f.tee, f.snp,
                          f.microcode)
    check mine.checks[vcNativeEvidence].outcome == coPassed
    let theirs = verdictFor(partA, manifest, f.bootloader, f.tee, f.snp,
                            f.microcode, chain = some(chainOf(partB)))
    checkpoint theirs.checks[vcNativeEvidence].detail
    check theirs.checks[vcNativeEvidence].outcome == coFailed
    check "does not verify under the key of" in
      theirs.checks[vcNativeEvidence].detail

  test "a report bundling no chain is refused, and says why":
    # The asymmetry with the trust-domain reader beside it: a
    # trust-domain quote carries its chain inside the signed bytes, and
    # a security-processor report carries no key material at all. With
    # no chain there is nothing to check the signature under, so every
    # field would be one the machine being judged chose for itself.
    let f = floorOf(partA)
    let v = verdictFor(partA, snpManifestText(
      hexOfBytes(reportOf(partA).measurement)),
      f.bootloader, f.tee, f.snp, f.microcode,
      chain = none(seq[string]))
    checkpoint v.checks[vcNativeEvidence].detail
    check v.checks[vcNativeEvidence].outcome == coFailed
    check "carries no key material of its own" in
      v.checks[vcNativeEvidence].detail

  test "a present-but-EMPTY chain is refused, not indexed":
    # Built directly rather than through the parser, which refuses this
    # shape — so the guard that stops the reader indexing element zero
    # of an empty sequence has an input. A verifier an attacker can stop
    # by sending a document is a verifier an attacker can stop.
    let text = snpReportTextFor(partA, some(chainOf(partA)))
    var report = parseAttestationReport(text, "<gate>")
    report.certificates = some(newSeq[string]())
    check report.hasBundledCertificates
    check report.certificatesForCrossCheck.len == 0
    let reading = readAuthoritativeEvidence(report)
    check reading.finding.kind == fkViolated
    check "carries no key material of its own" in reading.finding.detail
    check reading.inputs.readerName == SnpReaderName

  test "evidence that is not the vendor's document is refused":
    let bindings = ReportBindings(purpose: bpAttest, ephemeralPub: "")
    let text = renderAttestationReport(attestationReport(abSevSnp,
      SampleTimestamp, HarnessChallenge, bindings,
      "opaque-snp-evidence-bytes", sampleClaims(), some(chainOf(partA))))
    let manifest = snpManifestText(hexOfBytes(reportOf(partA).measurement))
    let digest = DigestPrefix & sha256Hex(manifest)
    let v = verifyAttestationReport(verificationRequest(text,
      parseAttestationPolicy(snpPolicyText(digest, 0, 0, 0, 0), "<gate>"),
      some(manifest), issuedAtMs = some(Now * 1000), nowMs = Now * 1000))
    check v.checks[vcNativeEvidence].outcome == coFailed
    check "did not read as a security-processor attestation report" in
      v.checks[vcNativeEvidence].detail

suite "the measurement row moves, over one document":

  test "it PASSES on this part's measurement and FAILS on the other's":
    # Same report, same policy, same clock. The only difference is which
    # genuine measurement the manifest publishes — and the negative is
    # the OTHER real part's, not a string of zeroes.
    let f = floorOf(partA)
    let mine = hexOfBytes(reportOf(partA).measurement)
    let theirs = hexOfBytes(reportOf(partB).measurement)
    check mine != theirs

    let matching = verdictFor(partA, snpManifestText(mine),
      f.bootloader, f.tee, f.snp, f.microcode)
    checkpoint matching.checks[vcMeasurementMatch].detail
    check matching.checks[vcMeasurementMatch].outcome == coPassed
    check mine in matching.checks[vcMeasurementMatch].detail

    let mismatching = verdictFor(partA, snpManifestText(theirs),
      f.bootloader, f.tee, f.snp, f.microcode)
    checkpoint mismatching.checks[vcMeasurementMatch].detail
    check mismatching.checks[vcMeasurementMatch].outcome == coFailed
    check vcMeasurementMatch in mismatching.failedChecks
    # And the detail names BOTH values, so a reader can see the
    # comparison rather than take the verdict's word for it.
    check mine in mismatching.checks[vcMeasurementMatch].detail
    check theirs in mismatching.checks[vcMeasurementMatch].detail

  test "a manifest publishing no confidential shape cannot answer":
    let f = floorOf(partA)
    let v = verdictFor(partA, sampleManifestText(), f.bootloader, f.tee,
                       f.snp, f.microcode)
    checkpoint v.checks[vcMeasurementMatch].detail
    check v.checks[vcMeasurementMatch].outcome == coFailed
    check "computed no " in v.checks[vcMeasurementMatch].detail

suite "the trusted-computing-base floor has input for the first time":

  test "it PASSES at the platform's own version and FAILS one above it":
    # Component by component. Each run moves exactly one number, so a
    # floor that compared only one component would pass three of the
    # four cases and fail the rest.
    for p in [partA, partB]:
      let f = floorOf(p)
      let manifest = snpManifestText(hexOfBytes(reportOf(p).measurement))
      let at = verdictFor(p, manifest, f.bootloader, f.tee, f.snp,
                          f.microcode)
      checkpoint at.checks[vcTcbFloor].detail
      check at.checks[vcTcbFloor].outcome == coPassed

      for component in 0 .. 3:
        var raised = f
        case component
        of 0: raised.bootloader = f.bootloader + 1
        of 1: raised.tee = f.tee + 1
        of 2: raised.snp = f.snp + 1
        else: raised.microcode = f.microcode + 1
        let above = verdictFor(p, manifest, raised.bootloader, raised.tee,
                               raised.snp, raised.microcode)
        checkpoint above.checks[vcTcbFloor].detail
        check above.checks[vcTcbFloor].outcome == coFailed
        check "below the policy's floor" in above.checks[vcTcbFloor].detail

  test "the two genuine parts report DIFFERENT platform versions":
    # Without this the floor cases above could be four statements about
    # one number. They are two real platforms at two real versions.
    check floorOf(partA) != floorOf(partB)

suite "the certificate chain the AGENT produced reaches the verdict":

  test "the driver's own output is the chain the verifier accepts":
    # End to end across the seam this change builds: a captured
    # entry's auxiliary blob goes in, the driver turns it into the
    # envelope's certificate list, and the verifier's chain row accepts
    # it against the vendor root it holds. Nothing in between is
    # hand-assembled.
    let dir = getTempDir() / ("repro-snp-verdict-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(dir / TsmOutblobAttr, stringOfHex(partA.reportHex))
    writeFile(dir / TsmProviderAttr, SevSnpProviderName & "\n")
    writeFile(dir / TsmAuxblobAttr, auxblobOf(partA))
    let driver = newSnpDriver(newCapturedTsmSource(dir / TsmOutblobAttr,
      dir / TsmProviderAttr, dir / TsmAuxblobAttr))
    let bound = agentSnpBoundBytes(stringOfHex(partA.reportHex))
    let produced = acquireQuote(driver, bound)
    check produced.certificates.isSome

    let f = floorOf(partA)
    let v = verdictFor(partA, snpManifestText(
      hexOfBytes(reportOf(partA).measurement)),
      f.bootloader, f.tee, f.snp, f.microcode,
      chain = produced.certificates)
    checkpoint v.checks[vcCertificateChain].detail
    check v.checks[vcCertificateChain].outcome == coPassed
    check "Milan" in v.checks[vcCertificateChain].detail
    # And the native-evidence row accepted the SAME bundle, so the
    # driver's first element really is the key that signed the report.
    check v.checks[vcNativeEvidence].outcome == coPassed

  test "and the revocation lists are still the verifier's to supply":
    let f = floorOf(partA)
    let v = verdictFor(partA, snpManifestText(
      hexOfBytes(reportOf(partA).measurement)),
      f.bootloader, f.tee, f.snp, f.microcode, crls = false)
    checkpoint v.checks[vcCertificateChain].detail
    check v.checks[vcCertificateChain].outcome == coFailed

suite "what hardware is needed for, stated as a failing row":

  test "the binding row FAILS on every genuine report, and names both":
    # The envelope's 64 bytes are computed from the challenge THIS
    # verifier issued. A genuine report's 64 bytes were chosen by a real
    # machine answering a challenge somebody else issued. They cannot be
    # made equal without a part signing something this repository asked
    # for, which is what live validation will be the first to do.
    for p in [partA, partB]:
      let f = floorOf(p)
      let v = verdictFor(p, snpManifestText(hexOfBytes(reportOf(p).measurement)),
        f.bootloader, f.tee, f.snp, f.microcode)
      checkpoint v.checks[vcReportDataBinding].detail
      check v.checks[vcReportDataBinding].outcome == coFailed
      # Both values appear, so the row is a comparison and not a
      # constant refusal: the envelope's derived bytes, and the bytes
      # the part actually signed.
      let report = parseAttestationReport(
        snpReportTextFor(p, some(chainOf(p))), "<gate>")
      check report.reportData in v.checks[vcReportDataBinding].detail
      check hexOfBytes(reportOf(p).reportData) in
        v.checks[vcReportDataBinding].detail
      check report.reportData != hexOfBytes(reportOf(p).reportData)

  test "so no verdict in this gate is an acceptance, and that is stated":
    let f = floorOf(partA)
    let v = verdictFor(partA, snpManifestText(
      hexOfBytes(reportOf(partA).measurement)),
      f.bootloader, f.tee, f.snp, f.microcode)
    check v.decision == vdRejected
    check vcReportDataBinding in v.failedChecks
    # Everything else this change wired DID pass, so the binding row
    # is the only thing between this evidence and an acceptance.
    check v.failedChecks == @[vcReportDataBinding]

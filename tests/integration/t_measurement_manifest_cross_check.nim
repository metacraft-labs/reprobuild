## Two postures over one measurement manifest, and the comparison
## between them.
##
## ## What is being claimed
##
## A verifier can come to hold the expectations for an attested image
## two ways, and they are not the same claim.
##
##   * It can take a document somebody else published and believe it
##     because a quorum of admitted rebuilders signed the claim that
##     this configuration produces it. What that is worth is exactly
##     what the signer set is worth, and nothing about the image is
##     recomputed.
##   * It can compute the expectations itself from the image and
##     believe the result because it computed it. That rests on no
##     signer at all, and entirely on the inputs it was handed.
##
## This gate drives BOTH over one unified kernel image and one
## dm-verity root hash and asserts that the two answers are the same
## document — field by field, with every divergence named.
##
## ## Why the two sides are independent here, and where they are not
##
## The left-hand side is a RECORDED document: the bytes below were
## produced once and written into this file, and nothing at run time
## recomputes them. The right-hand side is computed during the run, by
## the shipped `repro attest cross-check`, from the image's own bytes.
## So the comparison is between arithmetic performed at two different
## times by two different processes, and a change to the calculator
## moves one side and not the other — which is the only arrangement in
## which the comparison can fail.
##
## What the two sides DO share is their inputs: the same image bytes,
## the same root hash, the same configuration fingerprint. This gate
## therefore says nothing about whether those inputs are the right
## ones, and it does not claim to. It also shares the schema's parser
## and renderer, which both sides necessarily speak.
##
## The recorded document is a pin in the ordinary sense: an edit to the
## image fixture or to the measurement calculator makes this gate fail,
## and the failure is the gate working. The value the recording holds
## is anchored elsewhere — `t_attested_image_manifest` checks the PCR 11
## calculator against a real measured boot and against systemd's own
## independent implementation.
##
## ## Cases
##
##   * `t_both_postures_name_the_same_image` — the crux. A signed
##     document and a local rebuild over the same image agree, and the
##     command says so and exits 0.
##   * `t_a_moved_measurement_is_named_and_refused` — one character of
##     the image's command line, changed on the local side only. The
##     two postures must disagree, the command must exit non-zero, and
##     it must name every field that moved and no field that did not.
##   * `t_a_manifest_short_of_a_quorum_is_not_cross_checked` — every
##     field agrees and the signatures do not reach the policy's
##     threshold. Still non-zero: a document nobody admitted vouched
##     for has nothing to contribute to a comparison.
##   * `t_the_comparison_covers_every_field_of_the_schema` — each field
##     of a fully populated document, moved one at a time, must be
##     named. A field-by-field comparison that skips a field reports
##     agreement about documents that differ.
##   * `t_refusals` — the flags that would make the comparison
##     circular or vacuous are refused rather than defaulted.
##
## ## Mocking
##
## None. Real ECDSA-P256 keys from the operating system's random
## source, real CBOR, the production policy parser, the production
## quorum evaluator, the production manifest parser and renderer, and
## the shipped CLI entry point.

import std/[options, os, strutils, unittest]

import repro_test_support/process_fixtures

import cbor

import repro_attest
import repro_attest/cose
import repro_attest_verify
import repro_cli_support/attest as cli_attest

import ./reproos_shaped_uki
import ./software_root_test_pki
import ./edge_attestation_harness

const
  Fingerprint = "reproos-attested-uefi:cross-check"
  RootHash = "7777777777777777777777777777777777777777777777777777777777777777"
  VerityDigest = "sha256:" &
    "8888888888888888888888888888888888888888888888888888888888888888"

  AdmittedFrom = "2000-01-01T00:00:00Z"
  AdmittedUntil = "2035-01-01T00:00:00Z"
    ## The admission window every roster entry below is installed for.
    ## The command evaluates the quorum against the real clock, so the
    ## window has to contain it; both ends are stated because
    ## `validateRoster` refuses a key admitted forever.

  # -------------------------------------------------------------------
  # THE RECORDED DOCUMENT
  #
  # `repro attest expect` over `demoUki()` with the three inputs above,
  # run once and pasted here. It is the published half of every case
  # below: nothing at run time recomputes it, which is what makes the
  # comparison a comparison.
  #
  # To regenerate it, run the shipped command over the same fixture:
  #
  #   repro attest expect --uki <demoUki bytes> \
  #     --verity-image-digest <VerityDigest> \
  #     --verity-root-hash <RootHash> \
  #     --config-fingerprint <Fingerprint>
  # -------------------------------------------------------------------
  RecordedManifest = """{
  "schema": "reproos.attested-image.v1",
  "configFingerprint": "reproos-attested-uefi:cross-check",
  "imageOutputs": {
    "uki": "sha256:10472e1ce770b56d4dd8d1c649ebbe1c10484990b398a2e508d36e0844821ad0",
    "verityImage": "sha256:8888888888888888888888888888888888888888888888888888888888888888",
    "verityRootHash": "7777777777777777777777777777777777777777777777777777777777777777"
  },
  "expected": {
    "sev-snp": [],
    "tdx": [],
    "tpm": [
      {
        "pcr11": "4c9afbd23c18e29ac94c4194fcc86252699bcb50735c948cf176dc65ed5b25d1",
        "eventLogTemplate": "systemd-stub-uki-sections.v1;bank=sha256;.linux=024bdc7af055c4bf81ea70932e37fe0ca8b64ffe74377ed61d73bf1eb80f6ca7;.osrel=12a0964f3b3dc8a8e7ffe2415a8214e71a714333e58951ae06d6a26b2928446c;.cmdline=37bb164ff2bf4ae1f70438cb9f32a6392315819657c42b30c9a5e62db899bf3c;.initrd=24df15381711ea761e73ba12123613e7e1e64b188a95ec179a8e433805f9642e;.uname=530811775cc909ee5a3ce99758e72e5d57a569437857d837b77bba736fb1fcf7;.sbat=478c7511bef5dfe4d7a48b7b1a85f532c44d6cfc8d62511b68b45a4502c0b210"
      }
    ]
  }
}
"""

  EvidencePolicyTemplate = """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["tpm"]
backends = ["tpm2"]
allow_mock = false

[measurements]
manifests = []
require_certificates = false

[measurements.evidence]
min_signatures = @K@
known_keys = [@KEYS@]
require_transparency_log = false

[freshness]
max_challenge_age_seconds = 120
require_challenge = true
"""

let scratch = getTempDir() / "repro-manifest-cross-check-" &
  $getCurrentProcessId()
# Removed when THIS process exits, whichever cases it ran — not by a final
# "teardown" case, which under the runner's one-process-per-case model ran in
# one process and left every other case process's scratch behind. Registering
# a path that is never created is harmless. See
# ``repro_test_support/process_fixtures``.
releaseDirAtProcessExit(scratch)

proc scratchFile(name, content: string): string =
  createDir(scratch)
  result = scratch / name
  writeFile(result, content)

proc coseKeyFile(name: string; key: TestKey): string =
  ## The `COSE_Key` an operator installs for one admitted rebuilder.
  ##
  ## Written out here from RFC 9052 §7's labels rather than by calling a
  ## library encoder, because this build has none: the verifier only
  ## ever READS these. Writing the map by hand is therefore the same
  ## choice `edge_attestation_harness` makes about the signed bytes —
  ## the gate states the specification and the production parser is the
  ## thing under test.
  var x, y: seq[byte] = @[]
  for i in 1 .. 32: x.add key.pub[i]
  for i in 33 .. 64: y.add key.pub[i]
  let map = cMap([
    cPair(cUInt(1'u64), cUInt(2'u64)),        #  1 kty  = 2 (EC2)
    cPair(cUInt(2'u64), cBytes(kidOf(key))),  #  2 kid
    cPair(cNegInt(0'u64), cUInt(1'u64)),      # -1 crv  = 1 (P-256)
    cPair(cNegInt(1'u64), cBytes(x)),         # -2 x
    cPair(cNegInt(2'u64), cBytes(y))])        # -3 y
  let encoded = encodeItem(map)
  var raw = newString(encoded.len)
  for i in 0 ..< encoded.len: raw[i] = char(encoded[i])
  scratchFile(name, raw)

proc policyFile(k: int; names: openArray[string]): string =
  var quoted: seq[string] = @[]
  for n in names: quoted.add "\"" & n & "\""
  scratchFile("policy-" & $k & "-of-" & $names.len & ".toml",
    EvidencePolicyTemplate.replace("@K@", $k)
                          .replace("@KEYS@", quoted.join(", ")))

proc attestationsFile(name, manifestText: string;
                      keys: openArray[TestKey]): string =
  ## A bundle in which each key signs the claim derived from
  ## `manifestText` — so the signatures are about the document that is
  ## actually published, whichever document that is.
  let claim = claimForManifest(manifestText, "<published>")
  let statement = edgeStatementBytes(claim)
  var entries: seq[EdgeAttestation] = @[]
  for key in keys: entries.add quorumEntry(key, statement)
  scratchFile(name, bundleOf(claim, entries))

proc admission(key: TestKey): string =
  signerName(key) & "=" & AdmittedFrom & "/" & AdmittedUntil

type
  CrossCheckRun = object
    code: int
    report: string

proc runCrossCheck(args: seq[string]; reportName: string): CrossCheckRun =
  let reportPath = scratch / reportName
  createDir(scratch)
  if fileExists(reportPath): removeFile(reportPath)
  result.code = runAttestCommand(args & @["--out", reportPath])
  if fileExists(reportPath): result.report = readFile(reportPath)

proc baseArgs(manifestPath, policyPath, bundlePath, ukiPath: string;
              keyFiles: openArray[string];
              admissions: openArray[string]): seq[string] =
  result = @["cross-check",
    "--manifest", manifestPath,
    "--policy", policyPath,
    "--attestations", bundlePath,
    "--uki", ukiPath,
    "--verity-image-digest", VerityDigest,
    "--verity-root-hash", RootHash,
    "--config-fingerprint", Fingerprint]
  for f in keyFiles: result.add @["--signer-key", f]
  for a in admissions: result.add @["--signer-admission", a]

proc divergedFieldsOf(report: string): seq[string] =
  ## The field names the report listed, read back out of the report.
  var inList = false
  for raw in report.splitLines:
    if raw.startsWith("  fields diverged:"):
      inList = true
      continue
    if inList:
      if raw.startsWith("      evidence-backed:") or
         raw.startsWith("      locally computed:"):
        continue
      if raw.startsWith("    ") and raw.strip().len > 0:
        result.add raw.strip()
        continue
      inList = false

suite "a measurement manifest, judged from both directions":

  # Two admitted rebuilders, minted fresh from the operating system's
  # random source, so nothing here is a recorded signature that could
  # keep verifying after the thing it signs has moved.
  let keyA = newTestKey()
  let keyB = newTestKey()
  let keyFileA = coseKeyFile("rebuilder-a.cose", keyA)
  let keyFileB = coseKeyFile("rebuilder-b.cose", keyB)
  let admissions = @[admission(keyA), admission(keyB)]
  let keyFiles = @[keyFileA, keyFileB]

  let policyTwoOfTwo = policyFile(2, [signerName(keyA), signerName(keyB)])
  let publishedPath = scratchFile("published.json", RecordedManifest)
  let bundlePath = attestationsFile("attestations.json", RecordedManifest,
                                    [keyA, keyB])
  let ukiPath = scratchFile("reproos.efi", demoUki())

  test "t_both_postures_name_the_same_image":
    # The recorded document really is one this build reads, and it
    # really is about the configuration the local side is told to
    # compute for. Checked first, so a failure below is a divergence
    # rather than an unreadable fixture.
    let published = parseAttestedImageManifest(RecordedManifest,
                                               "<recorded>")
    check published.configFingerprint == Fingerprint
    check published.imageOutputs.verityRootHash == RootHash
    check published.tpm.len == 1

    let run = runCrossCheck(baseArgs(publishedPath, policyTwoOfTwo,
      bundlePath, ukiPath, keyFiles, admissions), "agree.txt")
    check run.code == AttestExitAccepted

    # Both postures accepted, and the comparison found nothing.
    check "evidence-quorum: passed" in run.report
    check "posture: accepted" in run.report
    check "fields diverged: 0" in run.report
    check "canonical bytes: identical" in run.report
    check ("verdict: " & CrossCheckAgreed) in run.report
    check divergedFieldsOf(run.report).len == 0

    # And the comparison compared SOMETHING. An empty divergence list
    # over zero compared fields would read exactly like agreement.
    check "fields compared: 9" in run.report

    # The report states what the agreement does not establish. A
    # cross-check whose limits are not printed beside its verdict reads
    # as a stronger claim than it is.
    check CrossCheckSharedInputCaveat in run.report

  test "t_a_moved_measurement_is_named_and_refused":
    # One character of the kernel command line, on the LOCAL side only.
    # The published document is the same signed bytes as above, so the
    # evidence posture still accepts it — and the two postures must now
    # name different images.
    let movedUki = scratchFile("reproos-moved.efi",
      demoUki("root=/dev/mapper/reproos ro quiEt"))
    let run = runCrossCheck(baseArgs(publishedPath, policyTwoOfTwo,
      bundlePath, movedUki, keyFiles, admissions), "moved.txt")
    check run.code == AttestExitRejected

    # The evidence half is untouched: a quorum still vouches for the
    # document. So the refusal is the comparison's, which is the point
    # — a signature cannot overrule arithmetic.
    check "evidence-quorum: passed" in run.report
    check ("verdict: " & CrossCheckDiverged) in run.report
    check "canonical bytes: different" in run.report

    # Every field that moved is named, and nothing else is. Changing
    # the command line moves the image digest and the register the
    # image measures to, and the template the register is replayed
    # from; it moves neither output of the root filesystem nor the
    # configuration the document names.
    check divergedFieldsOf(run.report) == @[
      "imageOutputs.uki",
      "expected.tpm[0].pcr11",
      "expected.tpm[0].eventLogTemplate"]
    check "fields diverged: 3" in run.report
    check "configFingerprint" notin divergedFieldsOf(run.report)
    check "imageOutputs.verityRootHash" notin divergedFieldsOf(run.report)

  test "t_a_manifest_short_of_a_quorum_is_not_cross_checked":
    # One signature where the policy requires two. Every field agrees,
    # and that is not enough: the left-hand side of the comparison is a
    # document the operator's own policy says nobody admitted vouched
    # for, and a comparison against it establishes only that two files
    # on this disk agree.
    let oneSignature = attestationsFile("one-signature.json",
      RecordedManifest, [keyA])
    let run = runCrossCheck(baseArgs(publishedPath, policyTwoOfTwo,
      oneSignature, ukiPath, keyFiles, admissions), "short.txt")
    check run.code == AttestExitRejected
    check "evidence-quorum: failed" in run.report
    check "posture: rejected" in run.report
    # The arithmetic agreed. The verdict is still a divergence, because
    # one of the two postures never reached an answer.
    check "fields diverged: 0" in run.report
    check ("verdict: " & CrossCheckDiverged) in run.report

  test "t_the_comparison_covers_every_field_of_the_schema":
    # A fully populated document — one row in every backend array — so
    # that every field this schema defines has a value to move. The
    # records are assembled here rather than rendered and re-parsed,
    # because a record whose register no longer replays from its own
    # template is a thing the renderer refuses and the comparison must
    # still handle.
    var base = parseAttestedImageManifest(RecordedManifest, "<recorded>")
    base.sevSnp = @[SevSnpExpectation(vcpus: 4, vcpuType: "EPYC-v4",
      ovmf: DigestPrefix & sha256Hex("firmware"), policy: "0x30000",
      measurement: repeat("a", 96))]
    base.tdx = @[TdxExpectation(mrtd: repeat("b", 96),
      rtmr0: repeat("c", 96), rtmr1: repeat("d", 96),
      rtmr2: repeat("e", 96))]

    # Moving nothing must find nothing, and must still have compared
    # every field — the number comes from the comparison's own counter,
    # which is checked against the schema's key lists inside it.
    let identical = diffAttestedImageManifests(base, base)
    check identical.divergences.len == 0
    check identical.compared == 18

    # One mover per field. The list is written out; the COUNT it has to
    # match is the one the comparison derived from the schema, so a
    # field added to the schema and not to this list fails here.
    var movers: seq[(string, proc (m: var AttestedImageManifest))] = @[]
    proc mover(field: string; f: proc (m: var AttestedImageManifest)) =
      movers.add (field, f)

    mover("configFingerprint",
      proc (m: var AttestedImageManifest) =
        m.configFingerprint = "reproos-attested-uefi:other")
    mover("imageOutputs.uki",
      proc (m: var AttestedImageManifest) =
        m.imageOutputs.uki = DigestPrefix & repeat("1", 64))
    mover("imageOutputs.verityImage",
      proc (m: var AttestedImageManifest) =
        m.imageOutputs.verityImage = DigestPrefix & repeat("2", 64))
    mover("imageOutputs.verityRootHash",
      proc (m: var AttestedImageManifest) =
        m.imageOutputs.verityRootHash = repeat("3", 64))
    mover("expected.sev-snp[0].vcpus",
      proc (m: var AttestedImageManifest) = m.sevSnp[0].vcpus = 8)
    mover("expected.sev-snp[0].vcpuType",
      proc (m: var AttestedImageManifest) =
        m.sevSnp[0].vcpuType = "EPYC-v3")
    mover("expected.sev-snp[0].ovmf",
      proc (m: var AttestedImageManifest) =
        m.sevSnp[0].ovmf = DigestPrefix & repeat("4", 64))
    mover("expected.sev-snp[0].policy",
      proc (m: var AttestedImageManifest) = m.sevSnp[0].policy = "0x30001")
    mover("expected.sev-snp[0].measurement",
      proc (m: var AttestedImageManifest) =
        m.sevSnp[0].measurement = repeat("5", 96))
    mover("expected.tdx[0].mrtd",
      proc (m: var AttestedImageManifest) = m.tdx[0].mrtd = repeat("6", 96))
    mover("expected.tdx[0].rtmr0",
      proc (m: var AttestedImageManifest) = m.tdx[0].rtmr0 = repeat("7", 96))
    mover("expected.tdx[0].rtmr1",
      proc (m: var AttestedImageManifest) = m.tdx[0].rtmr1 = repeat("8", 96))
    mover("expected.tdx[0].rtmr2",
      proc (m: var AttestedImageManifest) = m.tdx[0].rtmr2 = repeat("9", 96))
    mover("expected.tpm[0].pcr11",
      proc (m: var AttestedImageManifest) = m.tpm[0].pcr11 = repeat("f", 64))
    mover("expected.tpm[0].eventLogTemplate",
      proc (m: var AttestedImageManifest) =
        m.tpm[0].eventLogTemplate = EventLogTemplateId & ";bank=sha256" &
          ";.linux=" & repeat("0", 64))
    mover("expected.sev-snp.count",
      proc (m: var AttestedImageManifest) = m.sevSnp = @[])
    mover("expected.tdx.count",
      proc (m: var AttestedImageManifest) = m.tdx = @[])
    mover("expected.tpm.count",
      proc (m: var AttestedImageManifest) = m.tpm = @[])

    check movers.len == identical.compared

    var namedFields: seq[string] = @[]
    for (field, move) in movers:
      var moved = base
      move(moved)
      let got = diffAttestedImageManifests(base, moved)
      # Exactly the field that moved, and no other. A comparison that
      # reported a neighbour as well would be unusable for diagnosis,
      # and one that reported nothing would be the failure this whole
      # case exists to catch.
      var names: seq[string] = @[]
      for d in got.divergences: names.add d.field
      # Exactly one name, and it is the field that moved. Emptying an
      # array is in the same shape: its count moves, and the rows the
      # comparison would otherwise have put side by side simply stop
      # being compared, so nothing else is reported.
      check names == @[field]
      namedFields.add field

    # Every field name is distinct, so the list above really does cover
    # eighteen different fields rather than one field eighteen times.
    for i in 0 ..< namedFields.len:
      for j in i + 1 ..< namedFields.len:
        check namedFields[i] != namedFields[j]

  test "t_refusals":
    # The configuration fingerprint is NOT read out of the document
    # under test. A comparison that took it from there would be
    # checking that field against itself.
    var args = baseArgs(publishedPath, policyTwoOfTwo, bundlePath, ukiPath,
      keyFiles, admissions)
    var stripped: seq[string] = @[]
    var i = 0
    while i < args.len:
      if args[i] == "--config-fingerprint":
        i += 2
        continue
      stripped.add args[i]
      inc i
    check runCrossCheck(stripped, "no-fingerprint.txt").code ==
      AttestExitUsage

    # A document with no attestations is a document nothing vouches
    # for, and comparing it against a local rebuild establishes only
    # that two files agree. Refused rather than compared.
    stripped = @[]
    i = 0
    while i < args.len:
      if args[i] == "--attestations":
        i += 2
        continue
      stripped.add args[i]
      inc i
    check runCrossCheck(stripped, "no-attestations.txt").code ==
      AttestExitUsage

    # A key with no admission window is a key nobody decided to admit
    # forever. The refusal is the shared loader's, so it holds for this
    # subcommand too.
    check runCrossCheck(baseArgs(publishedPath, policyTwoOfTwo, bundlePath,
      ukiPath, keyFiles, []), "no-admission.txt").code == AttestExitUsage

    # This command judges no runtime report, so a flag that names one
    # would be read and thrown away.
    check runCrossCheck(args & @["--report-file", publishedPath],
      "report.txt").code == AttestExitUsage

    # ADDED BY REVIEW. Every flag the shared parser accepts and this
    # subcommand cannot honour is refused rather than read and thrown
    # away. `--json` is the one that matters most: a caller that asked
    # for a machine-readable rendering, got prose and got exit 0 has
    # been told nothing went wrong. The rest are the runtime verifier's
    # own inputs, and this command judges no runtime report and no
    # runtime certificate chain.
    for extra in @[@["--json"],
                   @["--trust-anchor", publishedPath],
                   @["--revocation-list", publishedPath],
                   @["--challenge", "0011223344556677"],
                   @["--challenge-file", publishedPath],
                   @["--challenge-issued-at", AdmittedFrom],
                   @["--vendor-revocation-list", publishedPath]]:
      let run = runCrossCheck(args & extra,
                              "ignored" & extra[0] & ".txt")
      # Non-zero AND no report: a refusal that still wrote a verdict
      # would have done the comparison and then complained about it.
      check run.code == AttestExitUsage
      check run.report.len == 0

    # And the good invocation still passes, so the refusals above are
    # discriminating rather than universal.
    check runCrossCheck(args, "still-good.txt").code == AttestExitAccepted

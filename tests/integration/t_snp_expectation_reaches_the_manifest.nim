## The computed launch measurement reaches the document a verifier reads.
##
## ## Why this gate exists separately from the vector gate
##
## A calculator that nothing calls is a calculator the program does not
## have. The vector gate says the arithmetic is right; this one says the
## arithmetic is *reached* — that `repro attest expect`, the command an
## image build runs to publish its expectations, computes the
## confidential-launch measurement and writes it into the
## `reproos.attested-image.v1` document, where until now that array was
## always empty.
##
## The number written into the document is compared against the
## reference implementation's own published vector for the same launch
## shape, read out of its test suite by name. So this gate is not
## checking that the command produced *a* digest; it is checking that the
## command produced the digest an unrelated implementation states for
## exactly those inputs, through the whole path from a file on disk to a
## rendered document.
##
## ## The flags have no defaults, and that is the design
##
## A launch measurement depends on five things no build can infer from
## its own outputs: how many processors, which machine model, which
## hypervisor, which feature word, which launch policy. Every one of them
## changes the answer, and a wrong answer is not a failure — it is a
## well-formed digest for a machine nobody asked for, which surfaces
## months later as an attestation that will not verify and nothing to
## point at. So each is required, each has a case, and a flag supplied
## with nothing to measure is refused rather than ignored.
##
## ## What this gate does NOT establish
##
## That a verifier compares the value. That claim is made next door, by
## the gate that drives a genuine report all the way to a verdict row,
## and it is made there because it needs genuine evidence rather than a
## computed expectation. What this gate establishes is the other half:
## the value this build PUBLISHES is the one that comparison reads, and
## it is the width the report's own field has. The case below pins the
## shape so the two halves cannot drift apart.
##
## (When this was written the comparison had no input at all, because
## this build carried no reader for this backend's evidence. It carries
## one now; the division of labour between the two gates is unchanged.)
##
## ## Mocking
##
## None. The real command, the real schema, the real calculator.

import std/[base64, os, sequtils, strutils, unittest]

import repro_attest
import repro_cli_support/attest

include ./snp_digest_corpus

let scratch = getTempDir() / "repro-snp-expectation-" & $getCurrentProcessId()

proc scratchFile(name: string; content: string): string =
  createDir(scratch)
  result = scratch / name
  writeFile(result, content)

proc firmwareFile(hex: string): string =
  var raw = ""
  for b in bytesOfHex(hex): raw.add char(b)
  scratchFile("firmware.bin", raw)

const
  Fingerprint = "reproos-attested-uefi:launch-digest"
  RootHash = "4444444444444444444444444444444444444444444444444444444444444444"
  VerityDigest = "sha256:" &
    "5555555555555555555555555555555555555555555555555555555555555555"

proc baseArgs(outPath: string): seq[string] =
  @["expect",
    "--uki", scratchFile("uki.bin", "not-a-real-unified-kernel-image"),
    "--verity-image-digest", VerityDigest,
    "--verity-root-hash", RootHash,
    "--config-fingerprint", Fingerprint,
    # Only this backend, because the others' calculators are a separate
    # question and one of them needs a real unified kernel image.
    "--backend", "sev-snp",
    "--out", outPath]

# The command's refusals are READ, not merely counted. Pass 1 of the
# mutation table found out why: disabling the required-flag check left
# every omission refused anyway, by a DIFFERENT rule one layer down — an
# empty `--vcpus` is not a number, an empty `--vmm` is not a hypervisor,
# an empty `--vcpu-type` is not a machine model. A case that asserted the
# exit status alone was satisfied by five refusals it was not written
# for, which is the way this tree's assertions are most often defeated.
#
# Standard error is redirected for the whole gate rather than per call,
# because restoring it portably is not worth a second mechanism; the
# offsets make each invocation's output readable on its own.
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
  OtherCommandRefusals: array[5, string] = [
    "is not a number",
    "must be written as 0x<hex>",
    "this build knows no family, model and stepping",
    "no initial register state for the hypervisor",
    "describes a confidential launch and no --firmware was given"]
    ## Every OTHER sentence this command can answer a malformed launch
    ## with. A case asserting one refusal asserts the absence of all of
    ## these, so it cannot be satisfied by a neighbour.

proc launchArgs(firmware: string; vcpus = "1"; vcpuType = "EPYC-v4";
                policy = "0x30000"; features = "0x21";
                vmm = "qemu"): seq[string] =
  @["--firmware", firmware, "--vcpus", vcpus, "--vcpu-type", vcpuType,
    "--guest-policy", policy, "--guest-features", features, "--vmm", vmm]

suite "the computed launch measurement reaches the published document":

  test "the command writes the digest the reference implementation states":
    # `test_snp_without_kernel_default` is one processor, the published
    # firmware that reserves a region for a kernel's digests, no kernel,
    # the default hypervisor and feature word 0x21. The command is given
    # exactly those inputs.
    let shape = statedShapeFor("test_snp_without_kernel_default")
    check shape.vcpus == 1
    check shape.vcpuModel == "EPYC-v4"
    check shape.vmm == "QEMU"
    check shape.guestFeatures == 0x21'u64
    check not shape.hasKernel
    check shape.firmware == "ovmf_AmdSev_suffix.bin"

    let firmware = firmwareFile(UpstreamOvmfAmdSevSuffixHex)
    let outPath = scratch / "manifest.json"
    check runAttestCommand(baseArgs(outPath) & launchArgs(firmware)) ==
      AttestExitAccepted
    let manifest = parseAttestedImageManifest(readFile(outPath), outPath)
    check manifest.sevSnp.len == 1
    check manifest.sevSnp[0].measurement ==
      statedDigestFor("test_snp_without_kernel_default")
    check manifest.sevSnp[0].vcpus == 1
    check manifest.sevSnp[0].vcpuType == "EPYC-v4"
    check manifest.sevSnp[0].policy == "0x30000"
    check manifest.sevSnp[0].ovmf == DigestPrefix & sha256Hex(
      readFile(firmware))
    # The document is the canonical rendering of what was parsed, which
    # is what says the value survives the round trip rather than only the
    # record in memory.
    check renderAttestedImageManifest(manifest) == readFile(outPath)

    # The SAME shape with a different feature word, which the corpus also
    # states a digest for. Without this the command could have ignored
    # `--guest-features` entirely — every other invocation in this gate
    # passes 0x21, so its VALUE reached no assertion, and a build that
    # hard-coded it produced this document unchanged. Same for
    # `--guest-policy`, whose value is recorded rather than measured.
    let other = statedShapeFor("test_snp_without_kernel_feature_snp_only")
    check other.guestFeatures == 0x1'u64
    check other.vcpus == shape.vcpus and other.vcpuModel == shape.vcpuModel
    let otherPath = scratch / "manifest-features.json"
    check runAttestCommand(baseArgs(otherPath) &
      launchArgs(firmware, features = "0x1", policy = "0x30001")) ==
      AttestExitAccepted
    let two = parseAttestedImageManifest(readFile(otherPath), otherPath)
    check two.sevSnp.len == 1
    check two.sevSnp[0].measurement ==
      statedDigestFor("test_snp_without_kernel_feature_snp_only")
    check two.sevSnp[0].measurement != manifest.sevSnp[0].measurement
    check two.sevSnp[0].policy == "0x30001"

  test "a measured kernel changes the digest, and to the stated one":
    # The same launch with a directly booted kernel. Upstream's kernel
    # and initial ramdisk are empty files and its command line is text,
    # so the two shapes differ in exactly the thing under test.
    let shape = statedShapeFor("test_snp_default")
    check shape.hasKernel
    check shape.cmdline == "console=ttyS0 loglevel=7"

    let firmware = firmwareFile(UpstreamOvmfAmdSevSuffixHex)
    let outPath = scratch / "manifest-kernel.json"
    check runAttestCommand(baseArgs(outPath) & launchArgs(firmware) &
      @["--launch-kernel", scratchFile("kernel.bin", ""),
        "--launch-initrd", scratchFile("initrd.bin", ""),
        "--launch-cmdline", shape.cmdline]) == AttestExitAccepted
    let manifest = parseAttestedImageManifest(readFile(outPath), outPath)
    check manifest.sevSnp.len == 1
    check manifest.sevSnp[0].measurement == statedDigestFor("test_snp_default")
    check manifest.sevSnp[0].measurement !=
      statedDigestFor("test_snp_without_kernel_default")

  test "a kernel and an initial ramdisk that carry bytes reach the document":
    # The end-to-end case above mirrors the published corpus, whose
    # kernel and initial ramdisk are the null device — so reading
    # NEITHER file produced the same digest as reading both, and the
    # four lines that pass their bytes down had no input at all. These
    # fixtures carry forty and forty-nine bytes.
    let firmware = firmwareFile(UpstreamOvmfAmdSevSuffixHex)
    let row = ReferenceKernelDigests[0]
    check row.kernel.len == 40
    check row.initrd.len == 49
    let outPath = scratch / "manifest-bytes.json"
    check runAttestCommand(baseArgs(outPath) & launchArgs(firmware) &
      @["--launch-kernel", scratchFile("kbytes.bin", row.kernel),
        "--launch-initrd", scratchFile("ibytes.bin", row.initrd),
        "--launch-cmdline", row.cmdline]) == AttestExitAccepted
    let manifest = parseAttestedImageManifest(readFile(outPath), outPath)
    check manifest.sevSnp.len == 1
    check manifest.sevSnp[0].measurement == row.digest
    # Each of the two files is shown to reach the answer on its own: the
    # corpus rows below differ from the first in one input each, and the
    # emitter reproduces them too.
    var produced: seq[string] = @[]
    for r in ReferenceKernelDigests:
      let e = sevSnpExpectationFor(SevSnpLaunchInputs(
        firmware: readFile(firmware), vcpus: 1, vcpuType: "EPYC-v4",
        guestPolicy: 0x30000'u64, guestFeatures: 0x21'u64, vmm: svkQemu,
        measuresKernel: true, kernel: r.kernel, initrd: r.initrd,
        cmdline: r.cmdline))
      check e.measurement == r.digest
      produced.add e.measurement
    check produced.len == 4
    check produced.deduplicate.len == 4

  test "without a firmware the array is emitted empty rather than omitted":
    let outPath = scratch / "manifest-empty.json"
    check runAttestCommand(baseArgs(outPath)) == AttestExitAccepted
    let text = readFile(outPath)
    check "\"sev-snp\": []" in text
    check parseAttestedImageManifest(text, outPath).sevSnp.len == 0

  test "every launch parameter is required, one case each":
    let firmware = firmwareFile(UpstreamOvmfAmdSevSuffixHex)
    let outPath = scratch / "manifest-missing.json"
    var refused = 0
    for omit in ["--vcpus", "--vcpu-type", "--guest-policy",
                 "--guest-features", "--vmm"]:
      var args = baseArgs(outPath)
      let full = launchArgs(firmware)
      var i = 0
      while i < full.len:
        if full[i] != omit: args.add @[full[i], full[i + 1]]
        i += 2
      let outcome = runCapturing(args)
      check outcome.code == AttestExitUsage
      # The sentence, and the absence of every other sentence this
      # command has for a malformed launch.
      check ("--firmware computes a confidential-launch expectation and " &
        omit & " is required with it") in outcome.err
      for other in OtherCommandRefusals:
        check other notin outcome.err
      inc refused
    check refused == 5
    # And with all five it succeeds, so the refusals above are about the
    # missing flag and not about the rest of the invocation.
    check runAttestCommand(baseArgs(outPath) & launchArgs(firmware)) ==
      AttestExitAccepted

  test "a flag that would measure nothing is refused rather than ignored":
    let outPath = scratch / "manifest-orphan.json"
    for orphan in [@["--vcpus", "2"], @["--vcpu-type", "EPYC-Milan"],
                   @["--guest-policy", "0x30000"],
                   @["--guest-features", "0x1"], @["--vmm", "gce"],
                   @["--launch-kernel", scratchFile("k2.bin", "")],
                   @["--launch-initrd", scratchFile("i2.bin", "")],
                   @["--launch-cmdline", "quiet"]]:
      check runAttestCommand(baseArgs(outPath) & orphan) == AttestExitUsage
    # An initial ramdisk or a command line with no kernel beside them is
    # the same mistake one level in: they are measured as part of a
    # kernel's digests and there is no kernel.
    let firmware = firmwareFile(UpstreamOvmfAmdSevSuffixHex)
    check runAttestCommand(baseArgs(outPath) & launchArgs(firmware) &
      @["--launch-initrd", scratchFile("i3.bin", "")]) == AttestExitUsage
    check runAttestCommand(baseArgs(outPath) & launchArgs(firmware) &
      @["--launch-cmdline", "quiet"]) == AttestExitUsage

  test "a launch computed for a backend nobody asked for is refused":
    let firmware = firmwareFile(UpstreamOvmfAmdSevSuffixHex)
    let outPath = scratch / "manifest-wrong-backend.json"
    var args = @["expect",
      "--uki", scratchFile("uki.bin", "not-a-real-unified-kernel-image"),
      "--verity-image-digest", VerityDigest,
      "--verity-root-hash", RootHash,
      "--config-fingerprint", Fingerprint,
      "--backend", "tdx",
      "--out", outPath]
    args.add launchArgs(firmware)
    check runAttestCommand(args) == AttestExitUsage

  test "an input this build cannot read is refused at the build":
    let outPath = scratch / "manifest-bad.json"
    # A firmware image with no identifying table at all.
    let junk = firmwareFile("00".repeat(SnpPageSize))
    check runAttestCommand(baseArgs(outPath) & launchArgs(junk)) ==
      AttestExitUsage
    # A machine model, and a hypervisor, this build has no numbers for.
    let firmware = firmwareFile(UpstreamOvmfAmdSevSuffixHex)
    check runAttestCommand(baseArgs(outPath) &
      launchArgs(firmware, vcpuType = "EPYC-Bergamo")) == AttestExitUsage
    check runAttestCommand(baseArgs(outPath) &
      launchArgs(firmware, vmm = "cloud-hypervisor")) == AttestExitUsage
    # A processor count and a policy that are not numbers.
    check runAttestCommand(baseArgs(outPath) &
      launchArgs(firmware, vcpus = "two")) == AttestExitUsage
    check runAttestCommand(baseArgs(outPath) &
      launchArgs(firmware, policy = "30000")) == AttestExitUsage
    # None of those wrote a document.
    check not fileExists(outPath)

  test "the document cannot re-derive the number it carries, and here is why":
    # The TPM entry beside this one carries a replay template, and the
    # validator refuses an entry that disagrees with itself. This entry
    # has no such rule, because the schema records three of the inputs
    # and not the other three. That is a real gap and it is stated
    # mechanically here rather than in prose alone: two launches
    # differing ONLY in the feature word produce two different
    # measurements and two entries whose every other field is equal.
    let firmware = readFile(firmwareFile(UpstreamOvmfAmdSevSuffixHex))
    var inputs = SevSnpLaunchInputs(firmware: firmware, vcpus: 1,
      vcpuType: "EPYC-v4", guestPolicy: 0x30000'u64, guestFeatures: 0x21'u64,
      vmm: svkQemu)
    let a = sevSnpExpectationFor(inputs)
    inputs.guestFeatures = 0x1'u64
    let b = sevSnpExpectationFor(inputs)
    check a.measurement != b.measurement
    check a.vcpus == b.vcpus
    check a.vcpuType == b.vcpuType
    check a.ovmf == b.ovmf
    check a.policy == b.policy
    # The same for the hypervisor, which the schema does not record
    # either.
    inputs.guestFeatures = 0x21'u64
    inputs.vmm = svkGce
    let c = sevSnpExpectationFor(inputs)
    check a.measurement != c.measurement
    check a.ovmf == c.ovmf and a.vcpuType == c.vcpuType
    # And the firmware's DIGEST is what the schema records, not its
    # bytes, so even the input it does record is not enough to recompute
    # from.
    check a.ovmf.startsWith(DigestPrefix)
    for key in ["guestFeatures", "vmm", "kernel", "initrd", "cmdline"]:
      check key notin SevSnpKeys
    check SevSnpKeys.len == 5

  test "the published value is in the shape the comparison reads":
    # The verifier's measurement check reads `manifest.sevSnp[i]
    # .measurement` and compares it against a launch measurement taken
    # out of evidence. That the comparison HAPPENS is the neighbouring
    # gate's claim, made against a genuine report. What this one claims
    # is that the value published here is the one that comparison reads,
    # and that it is the width the report's own field has.
    let firmware = readFile(firmwareFile(UpstreamOvmfAmdSevSuffixHex))
    let e = sevSnpExpectationFor(SevSnpLaunchInputs(firmware: firmware,
      vcpus: 1, vcpuType: "EPYC-v4", guestPolicy: 0x30000'u64,
      guestFeatures: 0x21'u64, vmm: svkQemu))
    check e.measurement.len == 2 * SnpDigestLen
    for c in e.measurement: check c in {'0' .. '9', 'a' .. 'f'}
    # And a manifest carrying it is accepted by the strict parser, which
    # is the only route into the record the verifier reads.
    let m = AttestedImageManifest(configFingerprint: Fingerprint,
      imageOutputs: ImageOutputs(uki: VerityDigest,
        verityImage: VerityDigest, verityRootHash: RootHash),
      sevSnp: @[e])
    let text = renderAttestedImageManifest(m)
    check parseAttestedImageManifest(text, "<gate>").sevSnp[0].measurement ==
      e.measurement

  test "the two processor bounds are one bound":
    # The calculator refuses a processor count outside its range and the
    # schema refuses one outside its own, and they are written in two
    # files. A test that checked each against itself would pass with the
    # two disagreeing, and a manifest naming a count one of them accepts
    # and the other does not is a document this build can compute and
    # cannot publish.
    check MaxProcessors == 1024
    let firmware = readFile(firmwareFile(UpstreamOvmfAmdSevSuffixHex))
    var inputs = SevSnpLaunchInputs(firmware: firmware, vcpus: MaxProcessors,
      vcpuType: "EPYC-v4", guestPolicy: 0x30000'u64, guestFeatures: 0x21'u64,
      vmm: svkQemu)
    let e = sevSnpExpectationFor(inputs)
    check e.vcpus == MaxProcessors
    # The schema accepts exactly what the calculator produced, and
    # refuses one more.
    let m = AttestedImageManifest(configFingerprint: Fingerprint,
      imageOutputs: ImageOutputs(uki: VerityDigest,
        verityImage: VerityDigest, verityRootHash: RootHash),
      sevSnp: @[e])
    validateAttestedImageManifest(m)
    var tooMany = m
    tooMany.sevSnp[0].vcpus = MaxProcessors + 1
    var raised = false
    try:
      validateAttestedImageManifest(tooMany)
    except ManifestError:
      raised = true
    check raised
    # And the calculator refuses the same count, so neither side is the
    # only one holding the line.
    inputs.vcpus = MaxProcessors + 1
    var refused = false
    try:
      discard sevSnpExpectationFor(inputs)
    except SnpLaunchError as err:
      refused = err.condition == slcProcessorCountOutOfRange
    check refused

  test "the scratch directory is removed":
    removeDir(scratch)
    check not dirExists(scratch)

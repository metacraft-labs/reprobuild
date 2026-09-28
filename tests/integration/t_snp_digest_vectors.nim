## The launch-digest calculator reproduces an independent
## implementation's published vectors.
##
## ## What this gate is actually asserting
##
## A launch measurement is a pure function of its inputs, which makes it
## the easiest kind of thing to test against itself and the hardest kind
## to test honestly. This gate never computes an expected value. It reads
## the reference implementation's own test suite — the file itself,
## carried verbatim and pinned by digest in `snp_digest_vectors` — parses
## the launch shapes out of its call sites and the digests out of its
## assertions, and requires this build to produce those digests from
## those shapes.
##
## The word doing the work is *parses*. A transcribed table of expected
## values is a table this repository wrote, and there is no way to tell a
## transcription error from a calculator that agrees with it — still less
## to tell either from a table copied out of the calculator's own output,
## which is the strongest version of the defeat this repository's
## reviews keep finding. So the vectors enter through a parser over upstream's bytes,
## and the bytes are checked against their published digest before the
## parser runs.
##
## ## The corpus is constrained in both directions
##
##   * adding a fabricated row to the embedded file breaks its sha256,
##     which is checked first;
##   * removing a row moves `ExpectedVectorCounts`, which is pinned;
##   * a row whose *shape* this build cannot run must be declared as such
##     by name, and the declared list is compared against what the parser
##     found, so a shape that silently stopped being computed turns up as
##     a skip that was not declared.
##
## ## What the vectors cover, and why that matters more than how many
##
## The point of a corpus is the spread, not the count. These vectors vary
## the firmware (two images, differing in whether they reserve a region
## for a directly booted kernel's digests), the processor count, the
## machine model, the hypervisor, the feature word, whether a kernel is
## measured at all, and the launch generation. A calculator that had one
## hypervisor's register values built in, or that ignored the feature
## word, or that folded the pages in list order for every hypervisor,
## passes some of these and fails others — which is the property a
## single-shape vector set does not have.
##
## ## What this gate does NOT establish
##
## No hardware produced any of these numbers. They are one software
## calculator's output checked against another's. Two implementations
## agreeing rules out transcription errors and rules in very little about
## a shared misreading of the vendor's specification. See the header of
## `snp_digest_vectors` for what upstream publishes that a successor
## could use to do better.
##
## ## Mocking
##
## None. Published bytes, and this build's own calculator.

import std/[algorithm, base64, exitprocs, os, sequtils, strutils, tables,
            unittest]

import nimcrypto/[hash, sha2]

import repro_attest/snp_launch

include ./snp_digest_corpus

# ---------------------------------------------------------------------
# Which refusals were reached
#
# The vocabulary is per RULE, not per family of rules, so this census
# moves when a rule stops being reachable. It is written only when
# `REPRO_REFUSAL_CENSUS` names a file; the gating of it is a case in the
# refusal gate beside this one.
# ---------------------------------------------------------------------

var reachedLaunchConditions: set[SnpLaunchCondition] = {}

proc writeCensus() {.noconv.} =
  let path = getEnv("REPRO_REFUSAL_CENSUS")
  if path.len == 0: return
  var f: File
  if open(f, path, fmAppend):
    for c in SnpLaunchCondition:
      if c in reachedLaunchConditions: f.writeLine("snp_launch:" & $c)
    f.close()

addExitProc(writeCensus)

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

proc sha256Hex(b: openArray[byte]): string =
  let d = sha256.digest(b)
  for i in 0 ..< 32: result.add toHex(int(d.data[i]), 2).toLowerAscii

var vectorsChecked = 0
  ## Every vector this gate actually computed and compared. Cases below
  ## assert their own delta on it, so a loop that stopped iterating moves
  ## a number instead of going quiet.

proc driveEveryLaunchShapeTheCorpusStatesADigestForReproduces() =
  ## The body of test
  ##   "every launch shape the corpus states a digest for reproduces"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var ran = 0
  for v in corpus.vectors:
    if v.kind != uvkDigest or isSkipped(v.test): continue
    let p = parametersFor(v)
    let got =
      if v.seedHex.len > 0:
        hexOfBytes(snpLaunchDigest(p, bytesOfHex(v.seedHex)))
      else:
        launchDigestHex(p)
    check got == v.expected
    if got != v.expected:
      checkpoint(v.test & ": " & got & " against " & v.expected)
    inc ran
    inc vectorsChecked
  # Two of the three declared skips state a digest; the third asserts
  # about files. Written as the arithmetic rather than as a number, so
  # that changing the skip list cannot leave this alone.
  check ran == ExpectedDigestVectors - ShapesThisBuildDoesNotRun.len + 1

proc driveTheFirmwareSOwnContributionReproducesAndBothRoutesAgree() =
  ## The body of test
  ##   "the firmware's own contribution reproduces, and both routes agree"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var ran = 0
  for v in corpus.vectors:
    if v.kind != uvkFirmwareHash: continue
    check hexOfBytes(snpFirmwareDigest(firmwareFor(v))) == v.expected
    inc ran
    inc vectorsChecked
  check ran == ExpectedFirmwareHashVectors
  # Seeding the chain with that value and walking the firmware's pages
  # are two routes to the same number. The corpus states the same
  # digest for both, but only because upstream also has both routes;
  # this asserts it of THIS build, on a shape the corpus does not pair.
  let p = SevLaunchParameters(mode: slmSevSnp, firmware: amdSevFirmware,
    vcpus: 3, vcpuSignature: cpuSignatureFor("EPYC-Milan"),
    guestFeatures: 0x21, vmm: svkQemu, hasKernel: true,
    cmdline: "root=/dev/vda1")
  check hexOfBytes(snpLaunchDigest(p)) ==
    hexOfBytes(snpLaunchDigest(p, snpFirmwareDigest(amdSevFirmware)))

proc driveEveryLaunchShapeTheCorpusStatesARefusalForIsRefused() =
  ## The body of test
  ##   "every launch shape the corpus states a refusal for is refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var ran = 0
  for v in corpus.vectors:
    if v.kind != uvkRefusal or isSkipped(v.test): continue
    # Upstream's sentence is its own; what is compared is that a
    # refusal happened and that it is about the same thing — a kernel
    # offered to a firmware with nowhere to put its digests.
    check "Kernel specified but OVMF" in v.expected
    var raised = false
    try:
      discard launchDigest(parametersFor(v))
    except SnpLaunchError as err:
      raised = true
      check err.condition in {slcKernelDigestsNoAddress,
                              slcKernelDigestsNoRegion}
      reachedLaunchConditions.incl err.condition
    check raised
    inc ran
    inc vectorsChecked
  check ran == ExpectedRefusalVectors

proc driveTheCorpusSDistinctAnswersStayDistinct() =
  ## The body of test
  ##   "the corpus's distinct answers stay distinct"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # A calculator that returned a constant would satisfy a vector loop
  # only if every vector shared one value. They do not, and the count
  # of distinct values this build produces has to equal the count the
  # corpus states — in both directions, so a build that collapsed two
  # shapes onto one number is red even though each comparison passed.
  var stated: seq[string] = @[]
  var produced: seq[string] = @[]
  for v in corpus.vectors:
    if v.kind != uvkDigest or isSkipped(v.test): continue
    stated.add v.expected
    produced.add (if v.seedHex.len > 0:
        hexOfBytes(snpLaunchDigest(parametersFor(v), bytesOfHex(v.seedHex)))
      else: launchDigestHex(parametersFor(v)))
    inc vectorsChecked
  check stated.deduplicate.len == produced.deduplicate.len
  check stated.sorted == produced.sorted
  check stated.deduplicate.len == 19

proc driveTheFirmwareSPageWalkIsExercisedByMoreThanOnePage() =
  ## The body of test
  ##   "the firmware's page walk is exercised by more than one page"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Every firmware image upstream publishes is ONE page, so the walk's
  # per-page address, its loop and its order have no input in the
  # corpus at all: dropping the offset from the address left every
  # published vector green. These three images are built here and the
  # digests are the reference implementation's, at the pinned commit.
  var seen: seq[string] = @[]
  for row in ReferenceWalkInputs:
    var image: seq[byte] = @[]
    var fills: seq[byte] = @[]
    var i = 0
    while i < row.fill.len:
      fills.add byte(parseHexInt(row.fill[i .. i + 1]))
      i += 2
    for f in fills:
      for _ in 0 ..< SnpPageSize: image.add f
    image.add amdSevFirmware
    check image.len == (fills.len + 1) * SnpPageSize
    let got = hexOfBytes(snpFirmwareDigest(image))
    check got == row.digest
    if got != row.digest: checkpoint(row.name & ": " & got)
    check got notin seen
    seen.add got
    inc vectorsChecked
  check seen.len == 3
  # And the loop agrees with the same pages folded in by hand, one at
  # a time, at addresses this case computes itself.
  var byHand = newSnpLaunchContext()
  var image: seq[byte] = @[]
  for _ in 0 ..< SnpPageSize: image.add 0'u8
  image.add amdSevFirmware
  let base = FourGiB - uint64(image.len)
  for p in 0 ..< 2:
    var page: seq[byte] = @[]
    for i in 0 ..< SnpPageSize: page.add image[p * SnpPageSize + i]
    byHand.update(spkNormal, base + uint64(p * SnpPageSize), sha384Of(page))
  check hexOfBytes(byHand.ld) == ReferenceWalkInputs[0].digest

proc driveEveryHypervisorHasMoreThanOneProcessorSomewhere() =
  ## The body of test
  ##   "every hypervisor has more than one processor somewhere"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # One of the three hypervisors appears in the corpus only at a
  # single processor, so its rule for the processors after the first —
  # which differ from the first in that hypervisor and in no other —
  # had no input. This matrix gives all three of them two and four.
  var produced: seq[string] = @[]
  var byVmm: seq[string] = @[]
  for row in ReferenceProcessorMatrix:
    let got = launchDigestHex(SevLaunchParameters(mode: slmSevSnp,
      firmware: amdSevFirmware, vcpus: row.vcpus,
      vcpuSignature: cpuSignatureFor("EPYC-v4"), guestFeatures: 0x21,
      vmm: vmmKindFor(row.vmm)))
    check got == row.digest
    if got != row.digest:
      checkpoint(row.vmm & "/" & $row.vcpus & ": " & got)
    produced.add got
    if row.vmm notin byVmm: byVmm.add row.vmm
    inc vectorsChecked
  check produced.len == 9
  check produced.deduplicate.len == 9
  check byVmm.len == 3
  # The one row this matrix shares with the PUBLISHED corpus agrees
  # with it, which is what says the matrix was produced under the same
  # reading of the inputs as the corpus was.
  check ReferenceProcessorMatrix[0].vmm == "qemu"
  check ReferenceProcessorMatrix[0].vcpus == 1
  check ReferenceProcessorMatrix[0].digest ==
    statedDigestFor("test_snp_without_kernel_default")

proc driveAKernelAnInitialRamdiskAndACommandLineEachReachTheAnswer() =
  ## The body of test
  ##   "a kernel, an initial ramdisk and a command line each reach the answer"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Every kernel and every initial ramdisk the published corpus names
  # is the null device, so a build that read NEITHER file produced
  # every published number correctly. These four rows carry bytes, and
  # differ from each other in one input each.
  var produced: seq[string] = @[]
  for row in ReferenceKernelDigests:
    var p = SevLaunchParameters(mode: slmSevSnp, firmware: amdSevFirmware,
      vcpus: 1, vcpuSignature: cpuSignatureFor("EPYC-v4"),
      guestFeatures: 0x21, vmm: svkQemu, hasKernel: true,
      cmdline: row.cmdline)
    for c in row.kernel: p.kernel.add byte(c)
    for c in row.initrd: p.initrd.add byte(c)
    let got = launchDigestHex(p)
    check got == row.digest
    if got != row.digest: checkpoint(row.name & ": " & got)
    produced.add got
    inc vectorsChecked
  check produced.len == 4
  check produced.deduplicate.len == 4
  check ReferenceKernelFixture.len == 40
  check ReferenceInitrdFixture.len == 49

# The cases above whose inputs build the checked-vector count.
# The coverage case below drives every one of them itself: the suite
# runner executes each case in its own process (`--run suite::test`),
# so the census holds only what ran in THAT process, and a coverage
# case that read what earlier cases left behind would measure the
# execution mode rather than the code under test.
const VectorDrivers: seq[(string, proc () {.nimcall.})] = @[
  ("every launch shape the corpus states a digest for reproduces",
    driveEveryLaunchShapeTheCorpusStatesADigestForReproduces),
  ("the firmware's own contribution reproduces, and both routes agree",
    driveTheFirmwareSOwnContributionReproducesAndBothRoutesAgree),
  ("every launch shape the corpus states a refusal for is refused",
    driveEveryLaunchShapeTheCorpusStatesARefusalForIsRefused),
  ("the corpus's distinct answers stay distinct",
    driveTheCorpusSDistinctAnswersStayDistinct),
  ("the firmware's page walk is exercised by more than one page",
    driveTheFirmwareSPageWalkIsExercisedByMoreThanOnePage),
  ("every hypervisor has more than one processor somewhere",
    driveEveryHypervisorHasMoreThanOneProcessorSomewhere),
  ("a kernel, an initial ramdisk and a command line each reach the answer",
    driveAKernelAnInitialRamdiskAndACommandLineEachReachTheAnswer)]

suite "the launch-digest calculator against an independent implementation":

  test "the embedded corpus is the file the reference implementation publishes":
    check corpusBytes.len == UpstreamMeasureTestsBytes
    check sha256Hex(corpusBytes.toOpenArrayByte(0, corpusBytes.len - 1)) ==
      UpstreamMeasureTestsSha256
    check vcpuTypesBytes.len == UpstreamVcpuTypesBytes
    check sha256Hex(vcpuTypesBytes.toOpenArrayByte(0,
      vcpuTypesBytes.len - 1)) == UpstreamVcpuTypesSha256

  test "the embedded firmware images are the bytes upstream publishes":
    check amdSevFirmware.len == SnpPageSize
    check ovmfX64Firmware.len == SnpPageSize
    check sha256Hex(amdSevFirmware) == UpstreamOvmfAmdSevSuffixSha256
    check sha256Hex(ovmfX64Firmware) == UpstreamOvmfX64SuffixSha256
    # One of the two published digests is also a published vector: the
    # oldest launch shape with no kernel measures nothing but the
    # firmware image, so its digest is that image's sha256. Checked here
    # against the fixture rather than only against the corpus, because it
    # is the one line of the corpus a reader can verify with `sha256sum`.
    check launchDigestHex(SevLaunchParameters(mode: slmSev,
      firmware: ovmfX64Firmware, vcpus: 1)) == UpstreamOvmfX64SuffixSha256

  test "the corpus parses into exactly the rows it contains":
    check corpus.testNames.len == ExpectedTestCount
    var counts: array[UpstreamVectorKind, int]
    for v in corpus.vectors: inc counts[v.kind]
    check counts[uvkDigest] == ExpectedDigestVectors
    check counts[uvkFirmwareHash] == ExpectedFirmwareHashVectors
    check counts[uvkRefusal] == ExpectedRefusalVectors
    check counts[uvkNoAssertion] == ExpectedUnassertedCalls
    # Every declared skip is a test that exists; every shape the parser
    # could not run is declared. Both directions, so the list cannot
    # quietly grow or quietly stop matching.
    for s in ShapesThisBuildDoesNotRun:
      check s in corpus.testNames
      # …and it is skipped for the ONE reason this build has for
      # skipping anything. Without this, naming ANY row here dropped it
      # from every loop below and nothing failed: the arithmetic on the
      # next lines is stated in terms of this list's own length, so it
      # moves with it. A shape excluded for any other reason has to be
      # excluded in the open.
      check statedShapeFor(s).firmware.endsWith("+supervisor")
    for v in corpus.vectors:
      if v.firmware.endsWith("+supervisor"):
        check isSkipped(v.test)

  test "the corpus varies every input the measurement depends on":
    var firmwares, models, hypervisors, modes: seq[string] = @[]
    var processorCounts: seq[int] = @[]
    var features: seq[uint64] = @[]
    var withKernel = 0
    var withoutKernel = 0
    var cmdlines: seq[string] = @[]
    for v in corpus.vectors:
      if v.kind != uvkDigest or isSkipped(v.test): continue
      if v.firmware notin firmwares: firmwares.add v.firmware
      if v.vcpuModel notin models: models.add v.vcpuModel
      if v.vmm notin hypervisors: hypervisors.add v.vmm
      if v.mode notin modes: modes.add v.mode
      if v.vcpus notin processorCounts: processorCounts.add v.vcpus
      if v.guestFeatures notin features: features.add v.guestFeatures
      if v.hasKernel:
        inc withKernel
        if v.cmdline notin cmdlines: cmdlines.add v.cmdline
      else: inc withoutKernel
    check firmwares.len == 2
    check hypervisors.len == 3
    check modes.len == 3
    check processorCounts.len == 2
    check features.len >= 2
    check models.len == 2          # a named model, and none at all
    check withKernel > 0
    check withoutKernel > 0
    check cmdlines.len == 2        # an empty command line, and one with text

  test "every launch shape the corpus states a digest for reproduces":
    driveEveryLaunchShapeTheCorpusStatesADigestForReproduces()

  test "the firmware's own contribution reproduces, and both routes agree":
    driveTheFirmwareSOwnContributionReproducesAndBothRoutesAgree()

  test "every launch shape the corpus states a refusal for is refused":
    driveEveryLaunchShapeTheCorpusStatesARefusalForIsRefused()

  test "the machine-model table agrees with upstream's in both directions":
    # Upstream's table is the authority and this build's copy is checked
    # against it rather than against itself: a row invented here, a row
    # dropped, or a family/model/stepping typed wrongly is a failure.
    var upstream = initTable[string, tuple[family, model, stepping: int]]()
    for raw in vcpuTypesBytes.splitLines:
      let line = raw.strip()
      if not line.startsWith("'"): continue
      let nameEnd = line.find('\'', 1)
      let name = line[1 ..< nameEnd]
      let open = line.find("cpu_sig(")
      doAssert open > 0, "a table row with no signature: " & line
      let args = balancedArgs(line, open + len("cpu_sig"))
      var got: array[3, int]
      for i, a in args.args:
        let eq = a.find('=')
        doAssert eq > 0, "a positional signature argument: " & a
        got[i] = parseInt(a[eq + 1 .. ^1].strip())
      upstream[name] = (got[0], got[1], got[2])
    check upstream.len == SnpCpuModels.len
    for m in SnpCpuModels:
      check m.name in upstream
      if m.name in upstream:
        check upstream[m.name] == (m.family, m.model, m.stepping)
    var mine: seq[string] = @[]
    for m in SnpCpuModels: mine.add m.name
    for name in upstream.keys:
      check name in mine
    # And the packing. These six are the signatures the reference
    # implementation's own table computes at the pinned commit, quoted
    # from its output; they are the one transcribed thing in this file,
    # and they are here because the alternative is a second copy of the
    # packing rule, which would agree with the first by construction.
    #
    # The transcription is not the only thing holding the packing up.
    # `EPYC-v4` is family 23 — above fifteen, so the split path — and a
    # hypervisor puts that word in `%rdx`, which is inside the VMSA page,
    # which is inside the measurement. Every corpus vector with a named
    # model would therefore fail if the split were wrong.
    check cpuSignatureFor("EPYC") == 0x0080_0f12'u32
    check cpuSignatureFor("EPYC-v4") == 0x0080_0f12'u32
    check cpuSignatureFor("EPYC-Rome") == 0x0083_0f10'u32
    check cpuSignatureFor("EPYC-Milan") == 0x00a0_0f11'u32
    check cpuSignatureFor("EPYC-Genoa") == 0x00a1_0f10'u32
    check cpuSignatureFor("EPYC-Turin") == 0x00b0_0f00'u32
    # The family-15 boundary, which is where the split starts and which
    # NOTHING else reaches: every row of the table is family 23, 25 or
    # 26, and the corpus only ever names one of them. Both values are
    # the reference implementation's own `cpu_sig` at the pinned commit,
    # asked for these arguments directly.
    #
    # Written as two rows rather than one because a calculator that
    # split at the wrong side of the boundary agrees on one of them.
    check cpuSignature(15, 255, 15) == 0x000f_0fff'u32
    check cpuSignature(16, 255, 15) == 0x001f_0fff'u32
    check cpuSignature(15, 0, 0) == 0x0000_0f00'u32
    check cpuSignature(16, 0, 0) == 0x0010_0f00'u32

  test "the hypervisor is a parameter and not an assumption":
    # The same launch under three hypervisors is three measurements.
    # Without this, a calculator with one of them built in passes every
    # vector whose hypervisor happens to be that one.
    var seen: seq[string] = @[]
    for vmm in [svkQemu, svkEc2, svkGce]:
      let p = SevLaunchParameters(mode: slmSevSnp, firmware: amdSevFirmware,
        vcpus: 2, vcpuSignature: cpuSignatureFor("EPYC-v4"),
        guestFeatures: 0x21, vmm: vmm)
      let got = launchDigestHex(p)
      check got notin seen
      seen.add got
    check seen.len == 3

  test "a feature word handed to a pre-SNP launch does not reach the measurement":
    # Upstream's own corpus passes a feature word to a shape that has
    # nowhere to put one, and this build agrees by producing the same
    # number for two different words. Asserted as an observation, not
    # declared: the alternative is a build that silently used the word
    # and disagreed with every vector.
    check sevFeaturesInVmsaFor(slmSevEs, 0x21'u64) == 0'u64
    check sevFeaturesInVmsaFor(slmSevSnp, 0x21'u64) == 0x21'u64
    var digests: seq[string] = @[]
    for features in [0'u64, 0x1'u64, 0x21'u64]:
      digests.add launchDigestHex(SevLaunchParameters(mode: slmSevEs,
        firmware: amdSevFirmware, vcpus: 4,
        vcpuSignature: cpuSignatureFor("EPYC-v4"), guestFeatures: features))
    check digests[0] == digests[1]
    check digests[1] == digests[2]
    # And the same three words on an SNP launch are three numbers, so
    # the equality above is a statement about the mode rather than about
    # a calculator that ignores the word everywhere.
    var snpDigests: seq[string] = @[]
    for features in [0'u64, 0x1'u64, 0x21'u64]:
      snpDigests.add launchDigestHex(SevLaunchParameters(mode: slmSevSnp,
        firmware: amdSevFirmware, vcpus: 4,
        vcpuSignature: cpuSignatureFor("EPYC-v4"), guestFeatures: features))
    check snpDigests.deduplicate.len == 3

  test "the corpus's distinct answers stay distinct":
    driveTheCorpusSDistinctAnswersStayDistinct()


  test "a corpus row naming a kernel this gate has no bytes for is refused":
    # The guard in `parametersFor` says the corpus's kernel is the null
    # device, and with the corpus as it stands nothing makes it fire — a
    # rule with no reachable input, which is the shape this tree's
    # reviews find most often. So it is given one: a shape with the
    # right structure and a different path.
    var synthetic = statedShapeFor("test_snp_default")
    check synthetic.hasKernel
    check synthetic.kernel == "/dev/null"
    synthetic.kernel = "/boot/vmlinuz"
    var raised = false
    try:
      discard parametersFor(synthetic)
    except AssertionDefect as err:
      raised = true
      check "a kernel this gate has no bytes for" in err.msg
    check raised
    # And the same for the initial ramdisk, which is a separate guard.
    var other = statedShapeFor("test_snp_default")
    other.initrd = "/boot/initrd.img"
    raised = false
    try:
      discard parametersFor(other)
    except AssertionDefect as err:
      raised = true
      check "an initial ramdisk this gate has no bytes for" in err.msg
    check raised

  test "the firmware's page walk is exercised by more than one page":
    driveTheFirmwareSPageWalkIsExercisedByMoreThanOnePage()

  test "every hypervisor has more than one processor somewhere":
    driveEveryHypervisorHasMoreThanOneProcessorSomewhere()

  test "a kernel, an initial ramdisk and a command line each reach the answer":
    driveAKernelAnInitialRamdiskAndACommandLineEachReachTheAnswer()

  test "every vector this gate claims to have checked was computed":
    # The loops above each add to one counter. If one of them stopped
    # iterating — a filter that matched nothing, a fixture list that lost
    # an entry — this number moves and the gate is red, rather than the
    # gate passing with nothing in it.
    # Drive every input the census is built from, HERE and from an
    # empty census, so the verdict is the same whether this case runs
    # alone (the runner gives each case its own process) or after
    # the cases above.
    vectorsChecked = 0
    for (name, drive) in VectorDrivers:
      checkpoint("driving " & name)
      drive()
    check vectorsChecked ==
      2 * (ExpectedDigestVectors - ShapesThisBuildDoesNotRun.len + 1) +
      ExpectedFirmwareHashVectors + ExpectedRefusalVectors +
      ReferenceWalkInputs.len + ReferenceProcessorMatrix.len +
      ReferenceKernelDigests.len

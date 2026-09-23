## Changing a launch parameter that reaches the evidence changes the
## expected-measurement identity, and a policy pinned to the old one
## stops accepting.
##
## ## What this gate is, and the shape it is written to avoid
##
## The claim is about a SET — "any provider launch parameter that
## affects evidence" — so the gate has to be constrained by that set
## rather than by a handful of parameters somebody thought of. A gate
## that mutated five named fields would stay green the day a sixth was
## added, and the sixth is exactly the one nobody checked. That is the
## "fixture set not constrained by its own gate" shape, and this
## repository has now found it four times.
##
## So the enumeration is asserted, in three links that together leave no
## way to add a parameter quietly:
##
##   1. **Field to parameter.** `CloudLaunchSpec`'s fields are walked
##      with `fieldPairs` and required to be in BIJECTION with
##      `CloudLaunchParameter`'s spellings. A field added without a
##      parameter is red; a parameter named after no field is red.
##   2. **Parameter to cell.** The table below is
##      `array[LaunchBaseline, array[CloudLaunchParameter, MutationCell]]`
##      — indexed BY the enumeration, so a parameter cannot exist
##      without a cell in every baseline, and the count of cells
##      exercised is asserted as an equality.
##   3. **Cell to consequence.** Each cell DECLARES what the mutation
##      will move, and the declaration is checked against what it does
##      move. A parameter declared operational whose mutation moves the
##      identity is red; one declared measured whose mutation moves no
##      measurement is red. The classification is therefore a claim this
##      gate falsifies, not a comment.
##
## ## Two baselines, because one would disable half the rules
##
## A single launch shape would leave every trust-domain parameter with
## no input and every security-processor parameter with no input, in
## whichever direction it was chosen — the single-anything degeneracy
## the sibling corpora were caught by. So there are two: a
## security-processor launch on one cloud and a trust-domain launch on
## the other. A parameter with no role on a baseline gets a cell saying
## so *and a machine-checkable cause*, never prose alone.
##
## ## The trust-domain baseline's measurement is a GENUINE one
##
## Its firmware and its measurement record are one real operator's, and
## the `MRTD` this adapter computes for it is the value that operator's
## machine SIGNED — pinned here as a literal from the quote, so this is
## not a calculation compared against itself. A cloud launch adapter
## whose expectation happened to be wrong would be invisible to every
## relative assertion in this file; that one row is absolute.
##
## ## What "invalidates stale policy" is measured against
##
## The real verifier. A policy document is built pinning the baseline's
## identity, the mutated launch's manifest is handed to
## `verifyAttestationReport`, and the `manifest-pinned` row is required
## to FAIL — while the same policy with the baseline's own manifest is
## required to pass. Nothing in the adapter participates in that
## outcome: the pin is a digest of the document and the verifier
## recomputes it.
##
## ## Mocking
##
## None. Real firmware bytes, a real operator's measurement record, the
## real calculators, the real schema, the real policy parser and the
## real verifier. The report the verifier is handed is a real envelope
## from the report renderer; it is the vehicle for reaching the
## manifest-pinned row and nothing in this file asserts anything about
## its evidence.

import std/[options, os, sequtils, strutils, unittest]

import repro_attest
import repro_attest_verify

include ./attestation_verifier_harness
include ./snp_digest_vectors

# ---------------------------------------------------------------------
# The corpora, and where every byte of each came from
# ---------------------------------------------------------------------

const
  TdxFirmwareB = staticRead("fixtures/tdx/ovmf-dstack-0.5.9.fd")
  TdxFirmwareA = staticRead("fixtures/tdx/ovmf-ubuntu-2025.02-3ubuntu2.fd")
  TdxRegisterLogB = staticRead("fixtures/tdx/dstack-0.5.9-register-log.json")

  OperatorBQuotedMrtd =
    "f06dfda6dce1cf904d4e2bab1dc370634cf95cefa2ceb2de2e" &
    "ee127c9382698090d7a4a13e14c536ec6c9c3c8fa87077"
    ## The initial-memory measurement operator B's machine put inside a
    ## quote it signed. Transcribed from the sibling corpus that
    ## verified that quote's signatures; it is written here as a
    ## LITERAL because a value this gate computed and compared against
    ## itself would say nothing.

type
  CloudFixtureName = enum
    ## One value per byte corpus this gate reads. The table below is
    ## indexed by it, so a corpus cannot exist without a row and a row
    ## cannot exist without a corpus.
    cfnSecurityProcessorFirmware
    cfnTrustDomainFirmwareA
    cfnTrustDomainFirmwareB
    cfnTrustDomainRegisterLog

  CloudFixtureProvenance = object
    bytes: int
    sha256: string
    origin: string

proc bytesOfHexString(h: string): string =
  doAssert h.len mod 2 == 0
  result = newString(h.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(h[2 * i .. 2 * i + 1]))

let securityProcessorFirmware = bytesOfHexString(UpstreamOvmfAmdSevSuffixHex)

proc fixtureBytesOf(name: CloudFixtureName): string =
  ## Exhaustive over the enumeration by construction: a corpus added
  ## without bytes does not compile.
  case name
  of cfnSecurityProcessorFirmware: securityProcessorFirmware
  of cfnTrustDomainFirmwareA: TdxFirmwareA
  of cfnTrustDomainFirmwareB: TdxFirmwareB
  of cfnTrustDomainRegisterLog: TdxRegisterLogB

const
  CloudFixtureProvenances: array[CloudFixtureName, CloudFixtureProvenance] = [
    cfnSecurityProcessorFirmware: CloudFixtureProvenance(
      bytes: 4096,
      sha256: "8f765dfabc127fc0a938a0744a3103ec15864d7d794eb4c398" &
              "aa976b6d6ab16c",
      origin: "the reference precomputation tool's published test " &
              "fixture ovmf_AmdSev_suffix.bin, carried in this " &
              "repository as hexadecimal beside the vectors parsed " &
              "out of that tool's own test suite"),
    cfnTrustDomainFirmwareA: CloudFixtureProvenance(
      bytes: 4194304,
      sha256: "9e807cb2cd4313406a3aa4becc0836671a5c64ca7bdc08a45" &
              "e15260184b446bf",
      origin: "a stock distribution firmware package, already pinned " &
              "by the sibling trust-domain corpus in this directory"),
    cfnTrustDomainFirmwareB: CloudFixtureProvenance(
      bytes: 4194304,
      sha256: "76888ce69c91aed86c43f840b913899b40b981964b7ce601" &
              "8667f91ad06301f0",
      origin: "operator B's published image, already pinned by the " &
              "sibling trust-domain corpus in this directory"),
    cfnTrustDomainRegisterLog: CloudFixtureProvenance(
      bytes: 7357,
      sha256: "69d46b1a6a8b7409e2aff24368e9d0a9bce50a3e44653115" &
              "c7b607efa1e23bd3",
      origin: "the measurement record operator B served beside that " &
              "quote, already pinned by the sibling corpus")]
    ## Every row names a file a SIBLING already pins. What these rows
    ## add is that THIS reading of it is pinned too: no new byte corpus
    ## enters the repository for this gate, and the four sizes and
    ## digests are recomputed below rather than copied forward.

# ---------------------------------------------------------------------
# The two baselines
# ---------------------------------------------------------------------

type
  LaunchBaseline = enum
    lbSecurityProcessorOnAws = "a sev-snp launch on aws-ec2"
    lbTrustDomainOnGcp = "a tdx launch on gcp-compute"

const
  FixtureFingerprint = "reproos-attested-uefi:cloud-launch"
  FixtureUki = "not-a-real-unified-kernel-image"

proc baselineSpec(b: LaunchBaseline): CloudLaunchSpec =
  ## The two launches every row below is one field away from.
  ##
  ## Every identifier here is a fabricated placeholder. None of them is
  ## an account identifier, a resource name or a network belonging to
  ## anybody: this gate launches nothing, so it needs no real ones, and
  ## a fixture that carried one would publish it.
  case b
  of lbSecurityProcessorOnAws:
    CloudLaunchSpec(
      provider: cpAwsEc2,
      region: "us-east-1",
      instanceName: "reproos-attest-probe",
      instanceShape: "m6a.2xlarge",
      imageReference: "ami-0fixture000000000",
      subnet: "subnet-0fixture000000000",
      sshKeyReference: "reproos-attest-probe-key",
      firmware: securityProcessorFirmware,
      machineModel: "EPYC-Milan",
      guestPolicy: "0x30000",
      guestFeatures: "0x21",
      configFingerprint: FixtureFingerprint,
      ukiImage: FixtureUki,
      verityImageDigest: "sha256:" & repeat('5', 64),
      verityRootHash: repeat('4', 64))
  of lbTrustDomainOnGcp:
    CloudLaunchSpec(
      provider: cpGcpCompute,
      region: "us-central1-a",
      instanceName: "reproos-attest-probe",
      instanceShape: "c3-standard-4",
      imageReference: "projects/reproos-fixture/global/images/base",
      subnet: "reproos-fixture-subnet",
      sshKeyReference: "/etc/reproos/fixture-ssh-keys",
      firmware: TdxFirmwareB,
      foldOrder: "per-region",
      registerLog: TdxRegisterLogB,
      configFingerprint: FixtureFingerprint,
      ukiImage: FixtureUki,
      verityImageDigest: "sha256:" & repeat('5', 64),
      verityRootHash: repeat('4', 64))

# ---------------------------------------------------------------------
# The mutation table
# ---------------------------------------------------------------------

type
  CellOutcome = enum
    ## Ordered weakest to strongest, so `max` over the baselines is the
    ## parameter's own effect and the two can be compared directly.
    ceNotApplicable
    ceOperational
    ceRecorded
    ceMeasured

  NotApplicableCause = enum
    ## Why a cell has no input, as a value rather than as prose. A
    ## sentence explaining an absence cannot be checked; each of these
    ## can be, and each is.
    naCellIsApplicable
    naNoRoleOnThisSurface
    naNoSecondValueThisBuildRecords

  MutationCell = object
    outcome: CellOutcome
    cause: NotApplicableCause
    alsoMoves: seq[CloudLaunchParameter]
      ## Fields the mutation had to move ALONGSIDE the one it names,
      ## because moving that one alone would produce a launch this
      ## build refuses. Declared rather than silent, and every such row
      ## carries an invariant asserted in a case of its own.
    note: string

proc cell(outcome: CellOutcome; note = "";
          cause = naCellIsApplicable;
          alsoMoves: seq[CloudLaunchParameter] = @[]): MutationCell =
  MutationCell(outcome: outcome, cause: cause, alsoMoves: alsoMoves,
               note: note)

let MutationTable: array[LaunchBaseline,
                         array[CloudLaunchParameter, MutationCell]] = [
  lbSecurityProcessorOnAws: [
    clpProvider: cell(ceMeasured,
      "the two clouds' hypervisors start a guest differently, and with " &
      "the processor count held fixed that difference is the whole of " &
      "what moves",
      alsoMoves = @[clpInstanceShape]),
    clpRegion: cell(ceOperational),
    clpInstanceName: cell(ceOperational),
    clpInstanceShape: cell(ceMeasured,
      "the shape decides the processor count and the chain takes one " &
      "more link per processor"),
    clpImageReference: cell(ceOperational,
      "no launch measurement here covers the disk image"),
    clpSubnet: cell(ceOperational),
    clpSshKeyReference: cell(ceOperational),
    clpFirmware: cell(ceMeasured),
    clpMachineModel: cell(ceRecorded,
      "this cloud's hypervisor pins the processor-signature register " &
      "at reset, so the model reaches the document and stops there"),
    clpGuestPolicy: cell(ceRecorded,
      "the launch policy is a separate field of the report and is not " &
      "inside the measurement"),
    clpGuestFeatures: cell(ceMeasured),
    clpFoldOrder: cell(ceNotApplicable,
      "a fold order is a trust domain's",
      cause = naNoRoleOnThisSurface),
    clpRegisterLog: cell(ceNotApplicable,
      "runtime registers are a trust domain's",
      cause = naNoRoleOnThisSurface),
    clpConfigFingerprint: cell(ceRecorded),
    clpUkiImage: cell(ceRecorded),
    clpVerityImageDigest: cell(ceRecorded),
    clpVerityRootHash: cell(ceRecorded)],
  lbTrustDomainOnGcp: [
    clpProvider: cell(ceNotApplicable,
      "this build records a trust-domain shape for one cloud only, so " &
      "there is no second provider to move to",
      cause = naNoSecondValueThisBuildRecords),
    clpRegion: cell(ceOperational),
    clpInstanceName: cell(ceOperational),
    clpInstanceShape: cell(ceOperational,
      "THE FINDING: a trust domain's initial-memory measurement is a " &
      "function of the firmware and the fold order, not of the " &
      "processor count, and the document's trust-domain row records no " &
      "processor count either — so two shapes have one identity"),
    clpImageReference: cell(ceOperational),
    clpSubnet: cell(ceOperational),
    clpSshKeyReference: cell(ceOperational),
    clpFirmware: cell(ceMeasured),
    clpMachineModel: cell(ceNotApplicable,
      "a machine model has no role on a trust domain",
      cause = naNoRoleOnThisSurface),
    clpGuestPolicy: cell(ceNotApplicable,
      "a launch policy has no role on a trust domain",
      cause = naNoRoleOnThisSurface),
    clpGuestFeatures: cell(ceNotApplicable,
      "a feature word has no role on a trust domain",
      cause = naNoRoleOnThisSurface),
    clpFoldOrder: cell(ceMeasured,
      "both orders are attested by genuine quotes and they give " &
      "different measurements over the same bytes"),
    clpRegisterLog: cell(ceMeasured,
      "the runtime registers the document carries are replayed from it"),
    clpConfigFingerprint: cell(ceRecorded),
    clpUkiImage: cell(ceRecorded),
    clpVerityImageDigest: cell(ceRecorded),
    clpVerityRootHash: cell(ceRecorded)]]

proc setValue(spec: var CloudLaunchSpec; p: CloudLaunchParameter;
              value: string) =
  ## The setter beside `valueOf`'s reader. A total function, so a
  ## parameter added without a way to move it does not compile — which
  ## is what stops a new field from getting a cell nobody can exercise.
  case p
  of clpProvider: spec.provider = cloudProviderFor(value)
  of clpRegion: spec.region = value
  of clpInstanceName: spec.instanceName = value
  of clpInstanceShape: spec.instanceShape = value
  of clpImageReference: spec.imageReference = value
  of clpSubnet: spec.subnet = value
  of clpSshKeyReference: spec.sshKeyReference = value
  of clpFirmware: spec.firmware = value
  of clpMachineModel: spec.machineModel = value
  of clpGuestPolicy: spec.guestPolicy = value
  of clpGuestFeatures: spec.guestFeatures = value
  of clpFoldOrder: spec.foldOrder = value
  of clpRegisterLog: spec.registerLog = value
  of clpConfigFingerprint: spec.configFingerprint = value
  of clpUkiImage: spec.ukiImage = value
  of clpVerityImageDigest: spec.verityImageDigest = value
  of clpVerityRootHash: spec.verityRootHash = value

proc withFirstByteFlipped(image: string): string =
  ## One bit, at one byte, of a genuine firmware. The whole image is
  ## folded in as measured pages, so this moves the measurement without
  ## disturbing any structure the reader walks.
  doAssert image.len > 0
  result = image
  result[0] = char(uint8(image[0]) xor 1'u8)

proc withFirstDigestCharChanged(record: string): string =
  ## One character of one digest inside a genuine measurement record,
  ## located mechanically rather than by offset. Every other byte of
  ## the record is left exactly as the operator served it.
  let key = record.find("\"digest\"")
  doAssert key >= 0
  let colon = record.find(':', key)
  doAssert colon >= 0
  let at = record.find('"', colon) + 1
  doAssert at > 0 and at < record.len
  result = record
  result[at] = (if record[at] == '0': '1' else: '0')

proc mutatedSpec(b: LaunchBaseline; p: CloudLaunchParameter): CloudLaunchSpec =
  ## The baseline with one parameter moved — and, for the one row that
  ## needs it, with the field its cell DECLARES alongside.
  result = baselineSpec(b)
  case p
  of clpProvider:
    # The processor count is held fixed on purpose: both shapes have
    # eight, so nothing but the hypervisor differs. The case below
    # asserts that invariant rather than trusting this comment.
    setValue(result, clpProvider, $cpGcpCompute)
    setValue(result, clpInstanceShape, "n2d-standard-8")
  of clpInstanceShape:
    case b
    of lbSecurityProcessorOnAws: setValue(result, p, "m6a.xlarge")
    of lbTrustDomainOnGcp: setValue(result, p, "c3-standard-8")
  of clpFirmware:
    case b
    of lbSecurityProcessorOnAws:
      result.firmware = withFirstByteFlipped(result.firmware)
    of lbTrustDomainOnGcp:
      result.firmware = TdxFirmwareA
  of clpRegisterLog:
    result.registerLog = withFirstDigestCharChanged(result.registerLog)
  of clpFoldOrder: setValue(result, p, "per-page")
  of clpMachineModel: setValue(result, p, "EPYC-Genoa")
  of clpGuestPolicy: setValue(result, p, "0x30001")
  of clpGuestFeatures: setValue(result, p, "0x1")
  of clpRegion:
    case b
    of lbSecurityProcessorOnAws: setValue(result, p, "eu-west-1")
    of lbTrustDomainOnGcp: setValue(result, p, "europe-west4-a")
  of clpInstanceName: setValue(result, p, "reproos-attest-probe-two")
  of clpImageReference:
    case b
    of lbSecurityProcessorOnAws: setValue(result, p, "ami-0fixture000000001")
    of lbTrustDomainOnGcp:
      setValue(result, p, "projects/reproos-fixture/global/images/second")
  of clpSubnet:
    case b
    of lbSecurityProcessorOnAws:
      setValue(result, p, "subnet-0fixture000000001")
    of lbTrustDomainOnGcp: setValue(result, p, "reproos-fixture-subnet-two")
  of clpSshKeyReference:
    case b
    of lbSecurityProcessorOnAws:
      setValue(result, p, "reproos-attest-probe-key-two")
    of lbTrustDomainOnGcp:
      setValue(result, p, "/etc/reproos/fixture-ssh-keys-two")
  of clpConfigFingerprint:
    setValue(result, p, FixtureFingerprint & "-two")
  of clpUkiImage: setValue(result, p, FixtureUki & "-two")
  of clpVerityImageDigest:
    setValue(result, p, "sha256:" & repeat('6', 64))
  of clpVerityRootHash: setValue(result, p, repeat('7', 64))

proc refuses(body: proc (): void): ref CloudLaunchError =
  ## Run something that must refuse, and hand the error back so the case
  ## can pin the rule and the sentence.
  try:
    body()
  except CloudLaunchError as err:
    return err
  raise newException(ValueError, "nothing was refused")

proc measurementsOf(m: AttestedImageManifest): seq[string] =
  ## Every value in the document that a machine's root of trust will
  ## report. Deliberately NOT the firmware digest beside them: that is
  ## a digest of an input, not a value anything measures.
  for e in m.sevSnp: result.add e.measurement
  for e in m.tdx:
    result.add e.mrtd
    result.add e.rtmr0
    result.add e.rtmr1
    result.add e.rtmr2
  for e in m.tpm: result.add e.pcr11

# ---------------------------------------------------------------------
# The stale-policy half, through the real verifier
# ---------------------------------------------------------------------

proc manifestPinnedOutcome(pinnedIdentity, manifestText: string): CheckOutcome =
  ## What the verifier's `manifest-pinned` row says when a policy pins
  ## one identity and is handed a manifest.
  ##
  ## Nothing from the adapter takes part: the verifier recomputes the
  ## digest of the bytes it was handed and compares it against what the
  ## policy names.
  let policy = parseAttestationPolicy(
    TpmPolicyTemplate.replace("@DIGEST@", pinnedIdentity),
    "<cloud launch policy>")
  let reportText = tpm2ReportText()
  var req = verificationRequest(reportText, policy, some(manifestText))
  verifyAttestationReport(req).checks[vcManifestPinned].outcome

# ---------------------------------------------------------------------
# The census, filled in as the cases run
# ---------------------------------------------------------------------

var cellsExercised = 0
var cellsDeclaredInapplicable = 0
var observed: array[LaunchBaseline, array[CloudLaunchParameter, CellOutcome]]
var staleRowsChecked = 0

proc strongestDeclared(p: CloudLaunchParameter): CellOutcome =
  result = ceNotApplicable
  for b in LaunchBaseline:
    if MutationTable[b][p].outcome > result: result = MutationTable[b][p].outcome

proc effectFor(outcome: CellOutcome): CloudParameterEffect =
  case outcome
  of ceMeasured: cpeMeasured
  of ceRecorded: cpeRecorded
  of ceOperational: cpeOperational
  of ceNotApplicable:
    raise newException(ValueError,
      "a parameter with no applicable cell has no observed effect")

# ---------------------------------------------------------------------

suite "the launch parameter set is the gate's own subject":

  test "every field of the specification has a parameter, and the reverse":
    var fields: seq[string] = @[]
    var probe: CloudLaunchSpec
    for name, _ in probe.fieldPairs: fields.add name
    check fields.len == ord(high(CloudLaunchParameter)) + 1
    check fields.len == 17
    for p in CloudLaunchParameter:
      var seen = 0
      for f in fields:
        if f == $p: inc seen
      check seen == 1
    for f in fields:
      var known = false
      for p in CloudLaunchParameter:
        if $p == f: known = true
      if not known:
        checkpoint("the record carries a field no parameter names: " & f)
      check known

  test "the refusal vocabulary is distinguishable":
    # What makes an `in e.msg` assertion below mean ONE rule.
    check cloudLaunchMessagesAreDistinguishable()

  test "both baselines are launches this build accepts":
    # Without this, every "the mutation was refused" outcome below could
    # be the baseline's fault rather than the mutation's.
    for b in LaunchBaseline:
      let spec = baselineSpec(b)
      validateCloudLaunchSpec(spec)
      check cloudLaunchPlan(spec).len > 0
      check cloudLaunchIdentity(spec).startsWith(DigestPrefix)
      check cloudLaunchIdentity(spec).len == DigestPrefix.len + 64
    # And the two are genuinely different launches, so nothing below is
    # a comparison of something with itself.
    check cloudLaunchIdentity(baselineSpec(lbSecurityProcessorOnAws)) !=
          cloudLaunchIdentity(baselineSpec(lbTrustDomainOnGcp))

suite "the trust-domain baseline reproduces a measurement a machine signed":

  test "the adapter's MRTD is the value in that operator's own quote":
    # The absolute row. Everything else in this file is relative — two
    # numbers this build produced, required to differ — and a relative
    # assertion is satisfied by a calculator that is wrong in a
    # consistent way. This one is not: the value on the right came out
    # of a quote a real trust domain signed.
    let m = cloudExpectedManifest(baselineSpec(lbTrustDomainOnGcp))
    check m.tdx.len == 1
    check m.tdx[0].mrtd == OperatorBQuotedMrtd
    check m.tdx[0].mrtd.len == 96
    # And the fold order really is load-bearing here: the same firmware
    # under the other order does NOT produce that operator's value.
    var other = baselineSpec(lbTrustDomainOnGcp)
    other.foldOrder = "per-page"
    check cloudExpectedManifest(other).tdx[0].mrtd != OperatorBQuotedMrtd

suite "every parameter, on every baseline, moves what its cell says":

  test "each cell's declaration is checked against its consequence":
    for b in LaunchBaseline:
      let base = baselineSpec(b)
      let baseManifest = cloudExpectedManifest(base)
      let baseIdentity = cloudLaunchIdentity(base)
      let basePlan = cloudLaunchPlan(base)
      let baseMeasurements = measurementsOf(baseManifest)
      let surface = surfaceOf(base)
      for p in CloudLaunchParameter:
        let c = MutationTable[b][p]
        if c.outcome == ceNotApplicable:
          inc cellsDeclaredInapplicable
          observed[b][p] = ceNotApplicable
          # The cause, checked rather than read.
          case c.cause
          of naNoRoleOnThisSurface:
            check not appliesTo(p, surface)
          of naNoSecondValueThisBuildRecords:
            # The only row of this kind: no cloud other than this one
            # offers a shape that attests with this surface, so there
            # is no coherent second provider to move to.
            check p == clpProvider
            var offering: seq[CloudProvider] = @[]
            for s in CloudInstanceShapes:
              if s.surface == surface and s.provider notin offering:
                offering.add s.provider
            check offering == @[base.provider]
          of naCellIsApplicable:
            checkpoint("a cell declared not applicable with no cause: " &
              $b & "/" & $p)
            check false
          check c.note.len > 0
          continue

        inc cellsExercised
        let m = mutatedSpec(b, p)
        # The mutation moved the field it names…
        checkpoint($b & " / " & $p)
        check valueOf(base, p) != valueOf(m, p)
        # …and moved nothing else the cell did not declare.
        for q in CloudLaunchParameter:
          if q == p or q in c.alsoMoves: continue
          check valueOf(base, q) == valueOf(m, q)

        let mutatedManifest = cloudExpectedManifest(m)
        let mutatedIdentity = cloudLaunchIdentity(m)
        let mutatedPlan = cloudLaunchPlan(m)
        let mutatedMeasurements = measurementsOf(mutatedManifest)
        check baseMeasurements.len == mutatedMeasurements.len

        case c.outcome
        of ceOperational:
          check mutatedIdentity == baseIdentity
          check mutatedMeasurements == baseMeasurements
          check mutatedPlan != basePlan
          observed[b][p] = ceOperational
        of ceRecorded:
          check mutatedIdentity != baseIdentity
          check mutatedMeasurements == baseMeasurements
          observed[b][p] = ceRecorded
        of ceMeasured:
          check mutatedIdentity != baseIdentity
          check mutatedMeasurements != baseMeasurements
          observed[b][p] = ceMeasured
        of ceNotApplicable:
          discard                      # handled above

        # A parameter whose value never reaches an argument vector must
        # leave the invocation byte-identical. This is the other half of
        # "the plan carries no measurement input", and without it a
        # measured parameter could be leaking into the request.
        if not reachesTheCommandLine(p) and p != clpProvider and
           c.alsoMoves.len == 0:
          check mutatedPlan == basePlan

        # The stale-policy clause, for every mutation that moves the
        # identity: a policy pinned to the baseline stops accepting.
        if c.outcome != ceOperational:
          check manifestPinnedOutcome(baseIdentity,
            cloudExpectedManifestText(m)) == coFailed
          inc staleRowsChecked

  test "the one row that moves a second field holds its invariant":
    # `provider` cannot be moved alone: no cloud offers the other's
    # instance shapes. The row moves the shape with it and holds the
    # PROCESSOR COUNT fixed, so the measurement that results is the
    # hypervisor's contribution and not the shape's.
    let b = lbSecurityProcessorOnAws
    let base = baselineSpec(b)
    let m = mutatedSpec(b, clpProvider)
    check MutationTable[b][clpProvider].alsoMoves == @[clpInstanceShape]
    check instanceShapeFor(base.provider, base.instanceShape).vcpus ==
          instanceShapeFor(m.provider, m.instanceShape).vcpus
    check instanceShapeFor(base.provider, base.instanceShape).surface ==
          instanceShapeFor(m.provider, m.instanceShape).surface
    # Every recorded field of the document is equal and only the
    # measurement differs, which is what isolates the hypervisor.
    let a = cloudExpectedManifest(base).sevSnp[0]
    let z = cloudExpectedManifest(m).sevSnp[0]
    check a.vcpus == z.vcpus
    check a.vcpuType == z.vcpuType
    check a.ovmf == z.ovmf
    check a.policy == z.policy
    check a.measurement != z.measurement

suite "the two things a cloud launch does not bind":

  test "the machine model does not reach a cloud launch measurement":
    # Stated as the claim, and asserted as the claim. Both clouds this
    # build has a model for pin the processor-signature register at
    # reset, so a caller naming a different machine gets a document
    # with a different `vcpuType` and the SAME measurement.
    for row in [(cpAwsEc2, "m6a.2xlarge"), (cpGcpCompute, "n2d-standard-8")]:
      var base = baselineSpec(lbSecurityProcessorOnAws)
      base.provider = row[0]
      base.instanceShape = row[1]
      var other = base
      other.machineModel = "EPYC-Genoa"
      check base.machineModel != other.machineModel
      let a = cloudExpectedManifest(base).sevSnp[0]
      let z = cloudExpectedManifest(other).sevSnp[0]
      check a.vcpuType != z.vcpuType
      check a.measurement == z.measurement
      check cloudLaunchIdentity(base) != cloudLaunchIdentity(other)
    # And the model IS otherwise an input to the calculator, so the
    # equality above is a statement about these hypervisors and not
    # about a parameter the calculator ignores. Under the local
    # hypervisor the same change moves the measurement.
    let fw = securityProcessorFirmware
    var local = SevSnpLaunchInputs(firmware: fw, vcpus: 8,
      vcpuType: "EPYC-Milan", guestPolicy: 0x30000'u64,
      guestFeatures: 0x21'u64, vmm: svkQemu)
    let localA = sevSnpExpectationFor(local)
    local.vcpuType = "EPYC-Genoa"
    check sevSnpExpectationFor(local).measurement != localA.measurement

  test "the provider image reference reaches no measurement at all":
    # A guest launched from a provider image has that image's bytes
    # nowhere in its launch measurement. Asserted in both directions:
    # moving the reference moves the request and nothing else, and
    # moving the image IDENTITY the document records moves the document
    # without moving a measurement.
    let base = baselineSpec(lbSecurityProcessorOnAws)
    var elsewhere = base
    elsewhere.imageReference = "ami-0fixture000000009"
    check cloudLaunchIdentity(base) == cloudLaunchIdentity(elsewhere)
    check cloudLaunchPlan(base) != cloudLaunchPlan(elsewhere)
    var otherBytes = base
    otherBytes.verityRootHash = repeat('7', 64)
    otherBytes.ukiImage = FixtureUki & "-different"
    check cloudLaunchIdentity(base) != cloudLaunchIdentity(otherBytes)
    check measurementsOf(cloudExpectedManifest(base)) ==
          measurementsOf(cloudExpectedManifest(otherBytes))
    check cloudLaunchPlan(base) == cloudLaunchPlan(otherBytes)

suite "the invocation carries names and never bytes":

  test "each parameter that reaches a command line occurs in the plan":
    for b in LaunchBaseline:
      let spec = baselineSpec(b)
      let joined = cloudLaunchPlan(spec).join(" ")
      var reaching = 0
      for p in CloudLaunchParameter:
        if not reachesTheCommandLine(p): continue
        inc reaching
        checkpoint($b & " / " & $p)
        check valueOf(spec, p) in joined
      check reaching == 6

  test "the three corpora never occur in a plan":
    for b in LaunchBaseline:
      let spec = baselineSpec(b)
      let joined = cloudLaunchPlan(spec).join(" ")
      for p in [clpFirmware, clpUkiImage, clpRegisterLog]:
        check not reachesTheCommandLine(p)
        let value = valueOf(spec, p)
        if value.len == 0: continue
        check value notin joined
      # And the invocation is short enough that this is not vacuous —
      # a plan that happened to be empty would satisfy the line above.
      check cloudLaunchPlan(spec).len >= 12

suite "a policy pinned to one launch does not accept another":

  test "the baseline's own manifest passes the pin it was built from":
    # The other arm. Without it, `coFailed` everywhere would be
    # satisfied by a verifier that fails this row unconditionally.
    for b in LaunchBaseline:
      let spec = baselineSpec(b)
      let identity = cloudLaunchIdentity(spec)
      check manifestPinnedOutcome(identity,
        cloudExpectedManifestText(spec)) == coPassed
    # And one launch's manifest against the OTHER launch's pin fails,
    # which is the same statement without a mutation in it.
    check manifestPinnedOutcome(
      cloudLaunchIdentity(baselineSpec(lbSecurityProcessorOnAws)),
      cloudExpectedManifestText(baselineSpec(lbTrustDomainOnGcp))) ==
      coFailed

  test "the identity is the digest the policy grammar accepts":
    # Not merely a string that looks like one: the real policy parser
    # reads a document carrying it, and the value it parsed out is the
    # one the adapter produced.
    let identity = cloudLaunchIdentity(baselineSpec(lbSecurityProcessorOnAws))
    let policy = parseAttestationPolicy(
      TpmPolicyTemplate.replace("@DIGEST@", identity), "<pin>")
    check policy.measurements.manifests == @[identity]
    check policy.pinsManifests()

suite "the rules this adapter refuses on":

  test "every refusal has an input, and the count is an EQUALITY":
    var reached: set[CloudLaunchCondition] = {}
    let base = baselineSpec(lbSecurityProcessorOnAws)

    block:
      let e = refuses(proc () = discard cloudProviderFor("digitalocean"))
      check e.condition == clcUnknownProvider
      reached.incl e.condition
      check "digitalocean" in e.msg

    block:
      let e = refuses(proc () =
        discard instanceShapeFor(cpAwsEc2, "t3.micro"))
      check e.condition == clcUnknownInstanceShape
      reached.incl e.condition

    block:
      let e = refuses(proc () =
        discard instanceShapeFor(cpAwsEc2, "n2d-standard-4"))
      check e.condition == clcShapeNotOfferedByProvider
      reached.incl e.condition
      check $cpGcpCompute in e.msg

    block:
      # The cloud whose shape this build records and whose launch it
      # cannot model. The shape RESOLVES; the model does not.
      check instanceShapeFor(cpAzureCvm, "Standard_DC4ads_v5").vcpus == 4
      let e = refuses(proc () = discard measurableCloudFor(cpAzureCvm))
      check e.condition == clcNoLaunchModelForProvider
      reached.incl e.condition
      # And it is refused through the specification too, not only at the
      # lookup — a plan is never rendered for it.
      var azure = base
      azure.provider = cpAzureCvm
      azure.instanceShape = "Standard_DC4ads_v5"
      let viaPlan = refuses(proc () = discard cloudLaunchPlan(azure))
      check viaPlan.condition == clcNoLaunchModelForProvider

    block:
      var blank = base
      blank.region = ""
      let e = refuses(proc () = validateCloudLaunchSpec(blank))
      check e.condition == clcRequiredParameterIsAbsent
      reached.incl e.condition
      check $clpRegion in e.msg

    block:
      var extra = base
      extra.foldOrder = "per-page"
      let e = refuses(proc () = validateCloudLaunchSpec(extra))
      check e.condition == clcParameterHasNoRoleOnThisSurface
      reached.incl e.condition
      check $clpFoldOrder in e.msg

    block:
      var long = base
      long.instanceName = repeat('a', MaxLaunchValueLen + 1)
      let e = refuses(proc () = validateCloudLaunchSpec(long))
      check e.condition == clcLaunchValueIsTooLongForACommandLine
      reached.incl e.condition
      # And exactly at the bound it is accepted, so the rule is a bound
      # and not an arbitrary refusal.
      var atBound = base
      atBound.instanceName = repeat('a', MaxLaunchValueLen)
      validateCloudLaunchSpec(atBound)

    block:
      var unsafe = base
      unsafe.region = "us east 1"
      let e = refuses(proc () = validateCloudLaunchSpec(unsafe))
      check e.condition == clcLaunchValueCarriesACharacterThisBuildWillNotPass
      reached.incl e.condition
      # A space is the mild case; the one that matters is a separator.
      for bad in ["us-east-1;rm", "us-east-1 && x", "$(id)", "`id`",
                  "us-east-1\nrm"]:
        var worse = base
        worse.region = bad
        let f = refuses(proc () = validateCloudLaunchSpec(worse))
        check f.condition ==
          clcLaunchValueCarriesACharacterThisBuildWillNotPass

    block:
      var notHex = base
      notHex.guestPolicy = "30000"
      let e = refuses(proc () = validateCloudLaunchSpec(notHex))
      check e.condition == clcHexWordIsNotWrittenInHexadecimal
      reached.incl e.condition
      # Four more spellings the one rule covers: a non-hex digit, a
      # prefix with nothing after it, an upper-case digit the schema
      # does not accept, and a word wider than the field it fills.
      for bad in ["0xzz", "0x", "0xFFFF",
                  "0x" & repeat('f', MaxHexWordDigits + 1)]:
        var other = base
        other.guestPolicy = bad
        let f = refuses(proc () = validateCloudLaunchSpec(other))
        check f.condition == clcHexWordIsNotWrittenInHexadecimal
      # …and at the bound it is accepted, so the width rule is a bound
      # and not a refusal of everything wide.
      var atBound = base
      atBound.guestPolicy = "0x" & repeat('f', MaxHexWordDigits)
      validateCloudLaunchSpec(atBound)
      check cloudExpectedManifest(atBound).sevSnp[0].policy ==
        "0x" & repeat('f', MaxHexWordDigits)

    block:
      let e = refuses(proc () =
        discard performCloudLaunch(base, clmArmed))
      check e.condition == clcArmedLaunchHasNoEffector
      reached.incl e.condition

    block:
      # A credential variable whose value occurs in the invocation. The
      # environment is restored in a `finally`, because a gate that
      # leaves a variable behind changes every case after it.
      let name = "AWS_ACCESS_KEY_ID"
      let saved = getEnv(name)
      let had = existsEnv(name)
      try:
        putEnv(name, base.region)
        let e = refuses(proc () = discard checkedCloudLaunchPlan(base))
        check e.condition == clcLaunchPlanCarriesCredentialMaterial
        reached.incl e.condition
        check name in e.msg
      finally:
        if had: putEnv(name, saved) else: delEnv(name)
      # …and with it unset the same plan is returned.
      check checkedCloudLaunchPlan(base) == cloudLaunchPlan(base)

    var missing: seq[string] = @[]
    for c in CloudLaunchCondition:
      if c notin reached: missing.add $c
    check missing == newSeq[string]()
    var count = 0
    for c in CloudLaunchCondition:
      if c in reached: inc count
    check count == 11
    check count == ord(high(CloudLaunchCondition)) + 1

  test "every rule has a site, and every site has exactly one rule":
    # The static half, which is what makes the census above a census
    # over SITES rather than over kinds.
    const Source = staticRead(
      "../../libs/repro_attest/src/repro_attest/cloud_launch.nim")
    var found: seq[string] = @[]
    var i = 0
    const Needle = "cloudFail(clc"
    while i < Source.len:
      let at = Source.find(Needle, i)
      if at < 0: break
      var j = at + len("cloudFail(")
      var name = ""
      while j < Source.len and
            (Source[j].isAlphaAscii or Source[j].isDigit):
        name.add Source[j]
        inc j
      found.add name
      i = j
    check found.len == 11
    check found.len == ord(high(CloudLaunchCondition)) + 1
    for c in CloudLaunchCondition:
      var seen = 0
      for n in found:
        if n == $c: inc seen
      if seen != 1:
        checkpoint($c & " is raised at " & $seen & " site(s)")
      check seen == 1
    for n in found:
      var known = false
      for c in CloudLaunchCondition:
        if n == $c: known = true
      check known

suite "provenance":

  test "every corpus this gate reads is the one it names":
    var rows = 0
    for name in CloudFixtureName:
      let row = CloudFixtureProvenances[name]
      let bytes = fixtureBytesOf(name)
      checkpoint($name)
      check bytes.len == row.bytes
      check sha256Hex(bytes) == row.sha256
      check row.origin.len > 0
      inc rows
    check rows == 4
    check rows == ord(high(CloudFixtureName)) + 1
    # The four are four distinct corpora, so the table is not four rows
    # over one thing.
    var digests: seq[string] = @[]
    for name in CloudFixtureName: digests.add sha256Hex(fixtureBytesOf(name))
    check digests.deduplicate.len == 4

suite "the census over the table itself":

  test "every cell was reached, and the count is an EQUALITY":
    check cellsExercised + cellsDeclaredInapplicable ==
      (ord(high(LaunchBaseline)) + 1) *
      (ord(high(CloudLaunchParameter)) + 1)
    check cellsExercised + cellsDeclaredInapplicable == 34
    check cellsExercised == 28
    check cellsDeclaredInapplicable == 6

  test "what each cell was DECLARED to move is what it MOVED":
    for b in LaunchBaseline:
      for p in CloudLaunchParameter:
        checkpoint($b & " / " & $p)
        check observed[b][p] == MutationTable[b][p].outcome

  test "the classification is the strongest thing the cells observed":
    for p in CloudLaunchParameter:
      let strongest = strongestDeclared(p)
      checkpoint($p)
      # No parameter is inapplicable on BOTH baselines: every one of
      # them has an input somewhere, or the classification beside it is
      # a statement about nothing.
      check strongest != ceNotApplicable
      check effectOf(p) == effectFor(strongest)

  test "the partition is three non-empty classes, counted":
    var measured, recorded, operational = 0
    for p in CloudLaunchParameter:
      case effectOf(p)
      of cpeMeasured: inc measured
      of cpeRecorded: inc recorded
      of cpeOperational: inc operational
    check measured == 6
    check recorded == 6
    check operational == 5
    check measured + recorded + operational ==
      ord(high(CloudLaunchParameter)) + 1

  test "every mutation that moved the identity was put to a policy":
    # The stale-policy clause is asserted per ROW, not once. This counts
    # the rows so a loop that stopped early cannot pass.
    var expected = 0
    for b in LaunchBaseline:
      for p in CloudLaunchParameter:
        let o = MutationTable[b][p].outcome
        if o == ceRecorded or o == ceMeasured: inc expected
    check staleRowsChecked == expected
    check staleRowsChecked == 17

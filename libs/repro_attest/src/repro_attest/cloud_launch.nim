## Launching an attested image on a public cloud — described, priced in
## evidence, and deliberately not performed.
##
## ## What this module is for
##
## A confidential instance is launched with a set of parameters. Some of
## them decide what the machine will *report*: the firmware it is created
## from, how many processors it has, which hypervisor starts it, the
## feature word each processor begins with, the order its host folds
## memory in. Others decide only where the instance sits and what it is
## called. A verifier compares a running machine's evidence against an
## expectation published before the launch, so the parameters of the
## first kind are inputs to that expectation and the parameters of the
## second kind must not be — and *which is which is not obvious*, which
## is the whole reason this module exists as data rather than as prose.
##
## So a launch here is a `CloudLaunchSpec`, and every field of it is
## enumerated by `CloudLaunchParameter` and classified by
## `effectOf`:
##
##   * `cpeMeasured` — changing it changes a value a machine's root of
##     trust will report. The strongest class: a stale expectation is
##     not merely out of date, it names a different machine.
##   * `cpeRecorded` — changing it changes the published document, and
##     therefore the document's digest, but no measurement moves.
##   * `cpeOperational` — changing it changes the request sent to the
##     provider and nothing a verifier ever sees.
##
## The classification is *checked against its own consequences* by the
## gate beside this module rather than believed: a parameter declared
## operational that moves the identity is red, and so is a parameter
## declared measured that moves nothing.
##
## ## The identity, and why it is the manifest's digest
##
## `cloudLaunchIdentity` is `sha256:<hex>` over the canonical bytes of
## the `reproos.attested-image.v1` document this launch expects. That is
## not a hash invented here: it is *exactly* the string a measurement
## policy pins in `measurements.manifests`, and exactly the string a
## verifier recomputes from the manifest it was handed. So "changing a
## launch parameter invalidates a stale policy" is not an analogy —
## the pin stops matching, and the verifier's manifest-pinned check
## fails, with no code in this module involved in that outcome.
##
## ## What this build can compute, and for whom
##
## Two of the three providers below have a launch model here, because
## `snp_launch` carries initial register state for their hypervisors and
## not for the third's. A provider with no model is **refused by name**
## rather than given a plan: a launch request this build cannot state an
## expectation for is a machine nobody will be able to verify, and
## emitting the request anyway would make that discovery somebody else's
## problem at the far end of a deployment.
##
## ## Two things a cloud launch does NOT bind, stated here because they
## ## are easy to assume
##
##   1. **The operating system.** A guest launched from a provider image
##      has that image's bytes nowhere in its launch measurement: the
##      measurement covers the firmware and the processors' initial
##      state, and the disk arrives afterwards. So the provider image
##      reference is classified `cpeOperational` — changing it does not
##      change the expectation, because no expectation here covers it.
##      Binding the operating system needs a second, guest-side
##      measurement.
##   2. **The machine model.** Both hypervisors this build has a model
##      for pin the processor-signature register to a constant at reset,
##      so the machine model a caller names does not reach the
##      measurement — it reaches the published document and stops there.
##      That is why it is `cpeRecorded` and not `cpeMeasured`, and it is
##      a statement about *these two hypervisors*, not about the
##      calculation.
##
## ## Nothing here launches anything
##
## `cloudLaunchPlan` renders the provider invocation as an argument
## vector and returns it. `performCloudLaunch` will hand that vector to
## a `CloudEffector` — and only in `clmArmed`, and only to an effector
## the caller supplied, because this build ships none. The command-line
## surface calls `cloudLaunchPlan` and has no way to reach an effector
## at all.
##
## ## Values that reach a command line are constrained
##
## Every spec value that appears in the rendered invocation is confined
## to a conservative character set, checked on the way in. The values
## that are *not* so confined — a firmware image, a unified kernel
## image, a measurement record — are precisely the ones that never reach
## an argument vector.
##
## And the rendered plan is checked against the environment: if any
## declared provider **secret** is set and its value occurs in the plan,
## the plan is refused rather than returned. A plan is the thing that
## gets recorded as a fixture, and a fixture is the thing that gets
## committed.
##
## ## A secret and an identifier are not the same thing
##
## Each provider's tooling reads several variables out of the
## environment, and they are not one kind. `AWS_SECRET_ACCESS_KEY` holds
## credential material and must never reach a recorded plan.
## `CLOUDSDK_CORE_PROJECT` holds the name of a project, and one of these
## clouds spells its image references
## `projects/<project>/global/images/<name>` — so a *correct* plan
## carries that value, and a check that looked for it refused the
## ordinary configuration and called a project name credential material.
## `GOOGLE_APPLICATION_CREDENTIALS` is a third thing again: a path to a
## file that holds the secret. The path is not the secret, and a
## legitimate plan can spell a path under the same directory.
##
## So `CloudEnvVarKind` separates the three, and *only* `cevSecret` is
## searched for. The other two are declared rather than dropped, because
## an effector still has to be told which variables to pass on.
##
## ## A value too short to look for is REPORTED, not refused
##
## The search is a substring test, and a substring test needs a floor.
## Without one, a session-token variable set to `1` matches the `1` in
## `--count 1` and refuses a perfectly good plan — which is a false
## positive dressed as a security finding. Below `MinSecretValueLen` the
## question "does this plan carry that secret" is not answerable by
## substring, so the variable is named in the scan's `unsearchable` list
## and the caller is expected to say so. That is not a hole: real
## credential material on these three clouds is twenty characters at the
## very shortest, so a value below the floor is a broken environment
## rather than a secret this build declined to protect.
##
## ## The environment is a parameter
##
## Every check above takes a `CloudEnvLookup`. A gate that read the
## developer's own environment would pass or fail depending on whose
## machine it ran on, which is how the two faults above shipped: they
## were invisible to a gate that happened to run with those variables
## unset. Pass an explicit lookup and the result is a property of the
## inputs.
##
## ## Mocking
##
## None. Real firmware bytes, the real calculators, the real schema.
## `CloudEnvLookup` is not a mock of the environment: it is the
## environment's *name*, and `processEnvLookup` is the implementation
## the command uses.

import std/[os, strutils]

import ./measurement
import ./manifest
import ./snp_launch
import ./tdx_launch

type
  CloudLaunchCondition* = enum
    ## One value per rule, for the reason `snp_launch` states next door:
    ## a vocabulary whose values are families lets a new rule be added
    ## where no assertion can tell it from its neighbours.
    clcUnknownProvider
    clcUnknownInstanceShape
    clcShapeNotOfferedByProvider
    clcNoLaunchModelForProvider
    clcRequiredParameterIsAbsent
    clcParameterHasNoRoleOnThisSurface
    clcLaunchValueIsTooLongForACommandLine
    clcLaunchValueCarriesACharacterThisBuildWillNotPass
    clcHexWordIsNotWrittenInHexadecimal
    clcArmedLaunchHasNoEffector
    clcLaunchPlanCarriesCredentialMaterial

  CloudLaunchError* = object of CatchableError
    condition*: CloudLaunchCondition

const
  CloudLaunchMessage*: array[CloudLaunchCondition, string] = [
    clcUnknownProvider:
      "this build has no launch adapter for the cloud the caller named",
    clcUnknownInstanceShape:
      "this build has no record of an instance shape by that name, and " &
      "the number of processors a shape has is an input to the " &
      "measurement",
    clcShapeNotOfferedByProvider:
      "the instance shape named is one this build records for a " &
      "different cloud, and a shape resolved against the wrong cloud " &
      "would be measured under the wrong hypervisor",
    clcNoLaunchModelForProvider:
      "this build carries no initial register state for the hypervisor " &
      "this cloud starts its confidential guests with, so it can state " &
      "no expectation for a launch there and will not emit a request it " &
      "cannot publish an expectation for",
    clcRequiredParameterIsAbsent:
      "a launch parameter that reaches the expectation was left empty, " &
      "and a measurement computed from a default is a number no machine " &
      "will report",
    clcParameterHasNoRoleOnThisSurface:
      "a launch parameter was supplied that this attestation surface " &
      "has no use for, so it would be carried into a document nothing " &
      "reads it out of",
    clcLaunchValueIsTooLongForACommandLine:
      "a launch value that is placed into the provider invocation is " &
      "longer than this build will pass as one argument",
    clcLaunchValueCarriesACharacterThisBuildWillNotPass:
      "a launch value that is placed into the provider invocation " &
      "carries a character outside the set these providers spell their " &
      "identifiers with",
    clcHexWordIsNotWrittenInHexadecimal:
      "a launch word that the published document spells in hexadecimal " &
      "was not written that way",
    clcArmedLaunchHasNoEffector:
      "an armed launch was asked for and no effector was supplied; this " &
      "build ships none, so there is nothing for the request to be " &
      "handed to",
    clcLaunchPlanCarriesCredentialMaterial:
      "the rendered provider invocation contains the value of a " &
      "credential variable that is set in this environment, and a plan " &
      "is a document that gets recorded"]

proc cloudLaunchMessagesAreDistinguishable*(): bool =
  ## No message is a substring of another. Checked, not asserted: this
  ## is the property that makes an `in e.msg` assertion mean one rule.
  for a in CloudLaunchCondition:
    for b in CloudLaunchCondition:
      if a == b: continue
      if CloudLaunchMessage[a] in CloudLaunchMessage[b]: return false
  true

proc cloudFail*(condition: CloudLaunchCondition;
                detail: string) {.noreturn.} =
  var e = newException(CloudLaunchError, CloudLaunchMessage[condition])
  if detail.len > 0: e.msg = e.msg & ": " & detail
  e.condition = condition
  raise e

# ---------------------------------------------------------------------
# Providers, surfaces and the shapes that carry them
# ---------------------------------------------------------------------

type
  CloudProvider* = enum
    ## The clouds this adapter knows how to describe a launch for. Not
    ## the clouds it can state an expectation for — that is a separate
    ## question, answered by `snpVmmForProvider`, and the two sets
    ## differ, which is the point of keeping them apart.
    cpAwsEc2 = "aws-ec2"
    cpGcpCompute = "gcp-compute"
    cpAzureCvm = "azure-cvm"

  CloudAttestationSurface* = enum
    ## Which root of trust an instance shape attests with. A property of
    ## the shape and not a free parameter: a caller does not get to ask
    ## a security-processor instance for a trust domain's quote.
    casSecurityProcessor = "sev-snp"
    casTrustDomain = "tdx"

  CloudInstanceShape* = object
    name*: string
    provider*: CloudProvider
    surface*: CloudAttestationSurface
    vcpus*: int
      ## How many processors the shape has. On a cloud this is NOT a
      ## free parameter — it is a property of the shape — and it is an
      ## input to a security-processor measurement, because the chain
      ## takes one more link per processor. A build that let a caller
      ## state it independently would publish expectations for machines
      ## the cloud cannot be asked for.

const
  CloudInstanceShapes*: array[7, CloudInstanceShape] = [
    CloudInstanceShape(name: "m6a.xlarge", provider: cpAwsEc2,
      surface: casSecurityProcessor, vcpus: 4),
    CloudInstanceShape(name: "m6a.2xlarge", provider: cpAwsEc2,
      surface: casSecurityProcessor, vcpus: 8),
    CloudInstanceShape(name: "n2d-standard-4", provider: cpGcpCompute,
      surface: casSecurityProcessor, vcpus: 4),
    CloudInstanceShape(name: "n2d-standard-8", provider: cpGcpCompute,
      surface: casSecurityProcessor, vcpus: 8),
    CloudInstanceShape(name: "c3-standard-4", provider: cpGcpCompute,
      surface: casTrustDomain, vcpus: 4),
    CloudInstanceShape(name: "c3-standard-8", provider: cpGcpCompute,
      surface: casTrustDomain, vcpus: 8),
    CloudInstanceShape(name: "Standard_DC4ads_v5", provider: cpAzureCvm,
      surface: casSecurityProcessor, vcpus: 4)]
    ## The shapes this build records, as data. Transcribed from each
    ## provider's own machine-type documentation and *not* discovered by
    ## calling an API, because discovering it would mean holding
    ## credentials and reaching a cloud — see this module's header.
    ##
    ## The last row is here to be REFUSED. That provider's confidential
    ## guests are started by a hypervisor this build has no initial
    ## register state for, so the shape resolves and the launch model
    ## does not, which is a different and more useful failure than
    ## "unknown shape": it says the cloud is real and the gap is here.

proc cloudProviderNames*(): string =
  ## Every provider this adapter knows, as text, for the surfaces that
  ## take a name. Derived from the enumeration rather than kept beside
  ## it, so a caller-facing list cannot drift from the set implemented.
  var names: seq[string] = @[]
  for p in CloudProvider: names.add $p
  names.join(", ")

proc cloudInstanceShapeNames*(provider: CloudProvider): string =
  var names: seq[string] = @[]
  for s in CloudInstanceShapes:
    if s.provider == provider: names.add s.name
  names.join(", ")

proc cloudProviderFor*(name: string): CloudProvider =
  for p in CloudProvider:
    if $p == name: return p
  var known: seq[string] = @[]
  for p in CloudProvider: known.add $p
  cloudFail(clcUnknownProvider,
    name.escape() & " is not one of " & known.join(", "))

proc instanceShapeFor*(provider: CloudProvider;
                       name: string): CloudInstanceShape =
  ## The shape a name refers to, resolved against the cloud that was
  ## named. A shape belonging to a different cloud is refused rather
  ## than accepted with its own provider substituted, because the
  ## provider decides the hypervisor and the hypervisor decides the
  ## measurement.
  for s in CloudInstanceShapes:
    if s.name == name and s.provider == provider: return s
  for s in CloudInstanceShapes:
    if s.name == name:
      cloudFail(clcShapeNotOfferedByProvider,
        name.escape() & " is recorded for " & $s.provider & " and " &
        $provider & " was named")
  let known = cloudInstanceShapeNames(provider)
  cloudFail(clcUnknownInstanceShape,
    name.escape() & "; this build records " &
    (if known.len == 0: "no shape at all" else: known) &
    " for " & $provider)

type
  MeasurableCloud* = enum
    ## The clouds this build can state a launch expectation for — a
    ## SEPARATE enumeration from `CloudProvider`, and that is the point.
    ##
    ## Every renderer below cases over this one, so there is no arm for
    ## a cloud with no launch model to fall into: such a cloud is
    ## refused on the way in, at the single site below, and nothing
    ## downstream needs an unreachable branch to satisfy the compiler.
    ## An unreachable branch is a rule with no input, which is the
    ## defect this file's census exists to make impossible.
    mcAwsEc2 = "aws-ec2"
    mcGcpCompute = "gcp-compute"

proc measurableCloudFor*(provider: CloudProvider): MeasurableCloud =
  ## The one site where a cloud with no launch model is refused. It is
  ## reached for every launch, whatever the surface, so such a cloud
  ## cannot be given a plan by any route.
  case provider
  of cpAwsEc2: mcAwsEc2
  of cpGcpCompute: mcGcpCompute
  of cpAzureCvm:
    cloudFail(clcNoLaunchModelForProvider,
      $cpAzureCvm & "; this build has models for " &
      $mcAwsEc2 & " and " & $mcGcpCompute)

proc snpVmmForProvider*(provider: CloudProvider): SnpVmmKind =
  ## Which of `snp_launch`'s hypervisor models starts this cloud's
  ## confidential guests.
  case measurableCloudFor(provider)
  of mcAwsEc2: svkEc2
  of mcGcpCompute: svkGce

# ---------------------------------------------------------------------
# The launch specification, its parameters, and what each one moves
# ---------------------------------------------------------------------

type
  CloudLaunchSpec* = object
    ## Everything a launch is described by. Every field has a value of
    ## `CloudLaunchParameter` named after it, and the gate beside this
    ## module asserts the two sets are in bijection — so a field added
    ## here without a parameter, or a parameter without a field, is a
    ## failure rather than a silent hole in the classification.
    provider*: CloudProvider
    region*: string
    instanceName*: string
    instanceShape*: string
    imageReference*: string
    subnet*: string
    sshKeyReference*: string
      ## The provider's own reference to the operator's public key,
      ## spelled the way that provider spells it: a key-pair name on one
      ## cloud, a path to a metadata file on the other.
    firmware*: string
      ## The confidential-launch firmware image, whole. Never reaches a
      ## command line.
    machineModel*: string
    guestPolicy*: string
    guestFeatures*: string
    foldOrder*: string
    registerLog*: string
      ## The measurement record a trust domain wrote. Never reaches a
      ## command line.
    configFingerprint*: string
    ukiImage*: string
      ## The unified kernel image's bytes. Never reaches a command line.
    verityImageDigest*: string
    verityRootHash*: string

  CloudLaunchParameter* = enum
    ## One value per field of `CloudLaunchSpec`, spelled exactly as the
    ## field is spelled.
    clpProvider = "provider"
    clpRegion = "region"
    clpInstanceName = "instanceName"
    clpInstanceShape = "instanceShape"
    clpImageReference = "imageReference"
    clpSubnet = "subnet"
    clpSshKeyReference = "sshKeyReference"
    clpFirmware = "firmware"
    clpMachineModel = "machineModel"
    clpGuestPolicy = "guestPolicy"
    clpGuestFeatures = "guestFeatures"
    clpFoldOrder = "foldOrder"
    clpRegisterLog = "registerLog"
    clpConfigFingerprint = "configFingerprint"
    clpUkiImage = "ukiImage"
    clpVerityImageDigest = "verityImageDigest"
    clpVerityRootHash = "verityRootHash"

  CloudParameterEffect* = enum
    ## What changing a parameter moves. See this module's header.
    cpeMeasured = "measured"
    cpeRecorded = "recorded"
    cpeOperational = "operational"

  CloudParameterRole* = enum
    ## Which attestation surfaces a parameter has a use on. A parameter
    ## supplied on a surface that has no use for it is refused, because
    ## a value that reaches nothing is a caller believing something
    ## about a document that does not carry it.
    cprEverySurface
    cprSecurityProcessorOnly
    cprTrustDomainOnly

proc effectOf*(p: CloudLaunchParameter): CloudParameterEffect =
  ## The declared classification. A total function over the enumeration,
  ## so a parameter added without a classification does not compile.
  ##
  ## What makes this a claim rather than an opinion is that every row is
  ## checked against its own consequence: the gate mutates each
  ## parameter and requires the identity and the measurements to move
  ## exactly as the row says they will.
  case p
  of clpProvider, clpInstanceShape, clpFirmware, clpGuestFeatures,
     clpFoldOrder, clpRegisterLog:
    cpeMeasured
  of clpMachineModel, clpGuestPolicy, clpConfigFingerprint, clpUkiImage,
     clpVerityImageDigest, clpVerityRootHash:
    cpeRecorded
  of clpRegion, clpInstanceName, clpImageReference, clpSubnet,
     clpSshKeyReference:
    cpeOperational

proc roleOf*(p: CloudLaunchParameter): CloudParameterRole =
  case p
  of clpMachineModel, clpGuestPolicy, clpGuestFeatures:
    cprSecurityProcessorOnly
  of clpFoldOrder, clpRegisterLog:
    cprTrustDomainOnly
  else:
    cprEverySurface

proc appliesTo*(p: CloudLaunchParameter;
                surface: CloudAttestationSurface): bool =
  case roleOf(p)
  of cprEverySurface: true
  of cprSecurityProcessorOnly: surface == casSecurityProcessor
  of cprTrustDomainOnly: surface == casTrustDomain

proc valueOf*(spec: CloudLaunchSpec; p: CloudLaunchParameter): string =
  ## One field, as text. The single reader of the record, so the checks
  ## below and the gate's mutation table cannot come to disagree about
  ## which field a parameter names.
  case p
  of clpProvider: $spec.provider
  of clpRegion: spec.region
  of clpInstanceName: spec.instanceName
  of clpInstanceShape: spec.instanceShape
  of clpImageReference: spec.imageReference
  of clpSubnet: spec.subnet
  of clpSshKeyReference: spec.sshKeyReference
  of clpFirmware: spec.firmware
  of clpMachineModel: spec.machineModel
  of clpGuestPolicy: spec.guestPolicy
  of clpGuestFeatures: spec.guestFeatures
  of clpFoldOrder: spec.foldOrder
  of clpRegisterLog: spec.registerLog
  of clpConfigFingerprint: spec.configFingerprint
  of clpUkiImage: spec.ukiImage
  of clpVerityImageDigest: spec.verityImageDigest
  of clpVerityRootHash: spec.verityRootHash

proc reachesTheCommandLine*(p: CloudLaunchParameter): bool =
  ## Which parameter VALUES are placed into the provider invocation.
  ##
  ## Exactly six, and the list is short for a reason worth stating: no
  ## input to a measurement is among them. A firmware image, a unified
  ## kernel image and a measurement record carry bytes rather than
  ## names and never reach an argument vector; a machine model, a
  ## launch policy, a feature word, a fold order and the three image
  ## identity fields reach the published document and stop there. The
  ## gate asserts both halves against a rendered invocation.
  ##
  ## The provider itself is excluded because it does not appear as a
  ## value: it selects which invocation is rendered at all.
  case p
  of clpRegion, clpInstanceName, clpInstanceShape, clpImageReference,
     clpSubnet, clpSshKeyReference:
    true
  else:
    false

const
  SafeLaunchValueChars* = {'0' .. '9', 'a' .. 'z', 'A' .. 'Z',
                           '.', '_', '-', ':', '/', '@', '+', '='}
    ## What a value may contain if it is going onto a command line.
    ## Deliberately narrower than "no shell metacharacters": the set is
    ## what these providers' identifiers are actually made of, and a
    ## value outside it is far more likely to be a mistake than a need.

  MaxLaunchValueLen* = 256

  MaxHexWordDigits* = 16
    ## Both words this spells are sixty-four bits wide, so seventeen
    ## digits is not a wide value, it is a mistake.

proc requireSafeLaunchValue(p: CloudLaunchParameter; value: string) =
  ## Two rules and two sites, because the remedies differ: one value is
  ## too long and the other carries something that does not belong.
  if value.len > MaxLaunchValueLen:
    cloudFail(clcLaunchValueIsTooLongForACommandLine,
      $p & " is " & $value.len & " characters and at most " &
      $MaxLaunchValueLen & " are placed on a command line")
  for c in value:
    if c notin SafeLaunchValueChars:
      cloudFail(clcLaunchValueCarriesACharacterThisBuildWillNotPass,
        $p & " carries " & ("" & c).escape())

proc requireHexWord(p: CloudLaunchParameter; value: string): uint64 =
  ## A `0x`-prefixed lower-case hexadecimal word, which is how the
  ## published document spells both of the words that use this.
  ##
  ## One rule and ONE raise site, deliberately, even though three
  ## different things can be wrong with the text. They are one rule —
  ## "this is not a hexadecimal word this build reads" — with one
  ## remedy, and the detail names the value, so a second site would buy
  ## nothing and would cost the census its bijection.
  var readable = value.startsWith("0x") and value.len > 2 and
                 value.len <= 2 + MaxHexWordDigits
  if readable:
    for c in value[2 .. ^1]:
      if c notin {'0' .. '9', 'a' .. 'f'}: readable = false
  if not readable:
    cloudFail(clcHexWordIsNotWrittenInHexadecimal,
      $p & " is " & value.escape() & "; it is written as 0x followed by " &
      "one to " & $MaxHexWordDigits & " lower-case hexadecimal digits")
  # Accumulated rather than parsed, so there is no second failure mode
  # to handle: the digits have already been checked and at most sixteen
  # of them fit in the word exactly.
  for c in value[2 .. ^1]:
    let digit = (if c <= '9': ord(c) - ord('0') else: 10 + ord(c) - ord('a'))
    result = (result shl 4) or uint64(digit)

proc surfaceOf*(spec: CloudLaunchSpec): CloudAttestationSurface =
  ## Which root of trust this launch will attest with — read off the
  ## shape, never asked of the caller.
  instanceShapeFor(spec.provider, spec.instanceShape).surface

proc validateCloudLaunchSpec*(spec: CloudLaunchSpec) =
  ## Every rule about a launch specification, in one place, in the order
  ## a reader would want them answered.
  ##
  ## The two list-driven rules below each have exactly ONE raise site
  ## and walk the parameter enumeration, so a parameter added to the
  ## record is covered by both without anybody editing either — which is
  ## the property a hand-kept list does not have.
  let shape = instanceShapeFor(spec.provider, spec.instanceShape)
  discard measurableCloudFor(spec.provider)
  for p in CloudLaunchParameter:
    if p == clpProvider: continue        # an enumeration, never empty
    let value = valueOf(spec, p)
    if appliesTo(p, shape.surface):
      if value.len == 0:
        cloudFail(clcRequiredParameterIsAbsent,
          $p & " on a " & $shape.surface & " launch")
    elif value.len > 0:
      cloudFail(clcParameterHasNoRoleOnThisSurface,
        $p & " was supplied and this launch attests with " &
        $shape.surface)
  for p in CloudLaunchParameter:
    if reachesTheCommandLine(p) and appliesTo(p, shape.surface):
      requireSafeLaunchValue(p, valueOf(spec, p))
  if shape.surface == casSecurityProcessor:
    discard requireHexWord(clpGuestPolicy, spec.guestPolicy)
    discard requireHexWord(clpGuestFeatures, spec.guestFeatures)

# ---------------------------------------------------------------------
# The expectation
# ---------------------------------------------------------------------

proc cloudExpectedManifest*(spec: CloudLaunchSpec): AttestedImageManifest =
  ## The `reproos.attested-image.v1` document this launch expects.
  ##
  ## Both halves are the shared calculators' — `snp_launch` for a
  ## security processor, `tdx_launch` for a trust domain — reached
  ## through `manifest`'s own constructors. Nothing about a measurement
  ## is decided here; what is decided here is which launch parameters
  ## become which of their inputs.
  validateCloudLaunchSpec(spec)
  let shape = instanceShapeFor(spec.provider, spec.instanceShape)
  var snpLaunches: seq[SevSnpLaunchInputs] = @[]
  var tdxLaunches: seq[TdxLaunchInputs] = @[]
  var backends: seq[string] = @[]
  case shape.surface
  of casSecurityProcessor:
    backends = @[BackendSevSnp]
    # `measuresKernel: false` — none of the provider surfaces this
    # adapter renders offers a directly booted kernel, so a launch here
    # boots a disk image and the kernel-digest region is folded in
    # blank. That is the mechanism behind this module's first "does not
    # bind" note.
    snpLaunches.add SevSnpLaunchInputs(
      firmware: spec.firmware,
      vcpus: shape.vcpus,
      vcpuType: spec.machineModel,
      guestPolicy: requireHexWord(clpGuestPolicy, spec.guestPolicy),
      guestFeatures: requireHexWord(clpGuestFeatures, spec.guestFeatures),
      vmm: snpVmmForProvider(spec.provider),
      measuresKernel: false)
  of casTrustDomain:
    backends = @[BackendTdx]
    tdxLaunches.add TdxLaunchInputs(
      firmware: spec.firmware,
      order: tdxHostOrderFor(spec.foldOrder),
      registerLog: spec.registerLog)
  attestedImageManifest(spec.configFingerprint, spec.ukiImage,
    spec.verityImageDigest, spec.verityRootHash, backends,
    snpLaunches, tdxLaunches)

proc cloudExpectedManifestText*(spec: CloudLaunchSpec): string =
  renderAttestedImageManifest(cloudExpectedManifest(spec))

proc cloudLaunchIdentity*(spec: CloudLaunchSpec): string =
  ## The identity a measurement policy pins and a verifier recomputes:
  ## `sha256:<hex>` over the manifest's canonical bytes.
  ##
  ## Written as the digest of the DOCUMENT rather than of the parameters
  ## on purpose. A digest over the parameters would be a number only
  ## this module understands; the document's digest is the one
  ## `measurements.manifests` already speaks, so a launch parameter
  ## moving it is a stale policy refusing a machine, not a mismatch
  ## somebody has to translate.
  DigestPrefix & sha256Hex(cloudExpectedManifestText(spec))

# ---------------------------------------------------------------------
# The provider invocation
# ---------------------------------------------------------------------

proc confidentialComputeTypeFor(surface: CloudAttestationSurface): string =
  case surface
  of casSecurityProcessor: "SEV_SNP"
  of casTrustDomain: "TDX"

proc cloudLaunchPlan*(spec: CloudLaunchSpec): seq[string] =
  ## The provider invocation this launch would be made with, as an
  ## argument vector — never a string, so there is no shell to quote
  ## for and nothing to get wrong about quoting.
  ##
  ## This procedure is the whole of what the command-line surface does.
  ## It takes no effector and there is no route from it to one.
  validateCloudLaunchSpec(spec)
  let shape = instanceShapeFor(spec.provider, spec.instanceShape)
  case measurableCloudFor(spec.provider)
  of mcAwsEc2:
    result = @["aws", "ec2", "run-instances",
      "--region", spec.region,
      "--image-id", spec.imageReference,
      "--instance-type", spec.instanceShape,
      "--count", "1",
      "--subnet-id", spec.subnet,
      "--key-name", spec.sshKeyReference,
      "--cpu-options", "AmdSevSnp=enabled",
      "--tag-specifications",
      "ResourceType=instance,Tags=[{Key=Name,Value=" &
        spec.instanceName & "}]"]
  of mcGcpCompute:
    result = @["gcloud", "compute", "instances", "create",
      spec.instanceName,
      "--zone", spec.region,
      "--machine-type", spec.instanceShape,
      "--image", spec.imageReference,
      "--subnet", spec.subnet,
      "--metadata-from-file", "ssh-keys=" & spec.sshKeyReference,
      "--confidential-compute-type", confidentialComputeTypeFor(
        shape.surface),
      "--maintenance-policy", "TERMINATE"]

type
  CloudEnvVarKind* = enum
    ## What a provider variable's VALUE is, which decides whether its
    ## occurrence in a rendered plan is a finding or the plan working
    ## correctly. See this module's header: conflating the first with
    ## the third refuses the ordinary configuration of a cloud.
    cevSecret = "secret"
      ## Credential material. Must never reach a recorded plan, and no
      ## correct plan carries it.
    cevSecretLocation = "secret-location"
      ## A PATH to a file holding credential material. The path is not
      ## the secret; a correct plan can legitimately spell a path in the
      ## same directory, so searching for it produces false refusals and
      ## protects nothing.
    cevIdentifier = "identifier"
      ## Names a project, account, tenancy, profile or region. A correct
      ## plan is SUPPOSED to carry this value.

  CloudEnvVar* = object
    name*: string
    kind*: CloudEnvVarKind

  CloudEnvLookup* = proc (name: string): string {.closure.}
    ## How a check reads the environment. A parameter rather than an
    ## ambient read, so a caller can state the environment it means and
    ## a gate is not a statement about the developer's machine.

  PlanSecretScan* = object
    ## What the secret check could and could not look for. Returned
    ## rather than discarded, because "this variable was not searched
    ## for" is something the operator has to be told.
    searched*: seq[string]
    unsearchable*: seq[string]

const
  MinSecretValueLen* = 16
    ## Below this a value is not searched for. The shortest credential
    ## any of these three providers issues is twenty characters, so the
    ## floor is well under every real one and well over the lengths that
    ## collide with ordinary invocation text — `1`, `us-east-1`, `0x30000`.

proc providerEnvVarsFor*(provider: CloudProvider): seq[CloudEnvVar] =
  ## Every environment variable this provider's own tooling reads, with
  ## what kind of value each one holds. The single declaration: the
  ## effector's name list, the secret check's search set and the
  ## identifier set are all derived from it, so they cannot drift apart.
  case provider
  of cpAwsEc2:
    @[CloudEnvVar(name: "AWS_ACCESS_KEY_ID", kind: cevSecret),
      CloudEnvVar(name: "AWS_SECRET_ACCESS_KEY", kind: cevSecret),
      CloudEnvVar(name: "AWS_SESSION_TOKEN", kind: cevSecret),
      CloudEnvVar(name: "AWS_SHARED_CREDENTIALS_FILE",
                  kind: cevSecretLocation),
      CloudEnvVar(name: "AWS_WEB_IDENTITY_TOKEN_FILE",
                  kind: cevSecretLocation),
      CloudEnvVar(name: "AWS_REGION", kind: cevIdentifier),
      CloudEnvVar(name: "AWS_DEFAULT_REGION", kind: cevIdentifier),
      CloudEnvVar(name: "AWS_PROFILE", kind: cevIdentifier)]
  of cpGcpCompute:
    @[CloudEnvVar(name: "CLOUDSDK_AUTH_ACCESS_TOKEN", kind: cevSecret),
      CloudEnvVar(name: "GOOGLE_OAUTH_ACCESS_TOKEN", kind: cevSecret),
      CloudEnvVar(name: "GOOGLE_APPLICATION_CREDENTIALS",
                  kind: cevSecretLocation),
      CloudEnvVar(name: "CLOUDSDK_CORE_PROJECT", kind: cevIdentifier),
      CloudEnvVar(name: "GOOGLE_CLOUD_PROJECT", kind: cevIdentifier),
      CloudEnvVar(name: "CLOUDSDK_COMPUTE_ZONE", kind: cevIdentifier)]
  of cpAzureCvm:
    @[CloudEnvVar(name: "AZURE_CLIENT_SECRET", kind: cevSecret),
      CloudEnvVar(name: "AZURE_CLIENT_CERTIFICATE_PATH",
                  kind: cevSecretLocation),
      CloudEnvVar(name: "AZURE_CLIENT_ID", kind: cevIdentifier),
      CloudEnvVar(name: "AZURE_TENANT_ID", kind: cevIdentifier),
      CloudEnvVar(name: "AZURE_SUBSCRIPTION_ID", kind: cevIdentifier)]

proc providerEnvNamesFor*(provider: CloudProvider): seq[string] =
  ## Every name, whatever its kind. This is what an effector is handed:
  ## a launch needs the project and the region as much as it needs the
  ## key, and it reads all of them out of its own environment.
  for v in providerEnvVarsFor(provider): result.add v.name

proc credentialEnvNamesFor*(provider: CloudProvider): seq[string] =
  ## The SECRETS only — the variables whose value must never occur in a
  ## recorded plan. Narrower than `providerEnvNamesFor` on purpose: this
  ## is the search set, and a name on it that is not a secret is a false
  ## refusal waiting for the first operator who exports it.
  for v in providerEnvVarsFor(provider):
    if v.kind == cevSecret: result.add v.name

proc allCredentialEnvNames*(): seq[string] =
  for p in CloudProvider:
    for name in credentialEnvNamesFor(p):
      if name notin result: result.add name

proc allProviderEnvVars*(): seq[CloudEnvVar] =
  for p in CloudProvider:
    for v in providerEnvVarsFor(p):
      var known = false
      for seen in result:
        if seen.name == v.name: known = true
      if not known: result.add v

proc processEnvLookup*(): CloudEnvLookup =
  ## The real environment. The only reader of `getEnv` in this module.
  result = proc (name: string): string = getEnv(name)

proc fixedEnvLookup*(pairs: openArray[(string, string)]): CloudEnvLookup =
  ## A stated environment, for a caller that means a particular one —
  ## including the empty one, which is what a gate about plans rather
  ## than about machines should be asking.
  let table = @pairs
  result = proc (name: string): string =
    for pair in table:
      if pair[0] == name: return pair[1]
    ""

proc requirePlanCarriesNoCredential*(plan: seq[string];
                                     env: CloudEnvLookup = nil):
                                     PlanSecretScan {.discardable.} =
  ## Every declared SECRET's value, looked for in the rendered
  ## invocation.
  ##
  ## Every provider's secrets are checked, not only the one being
  ## launched on: a plan recorded as a fixture is read by whoever finds
  ## it, and which cloud it names does not narrow what a mistake could
  ## have put in it.
  ##
  ## Identifiers and secret LOCATIONS are not searched for, and that is
  ## the repair rather than a relaxation — see this module's header.
  let lookup = (if env == nil: processEnvLookup() else: env)
  let joined = plan.join(" ")
  for name in allCredentialEnvNames():
    let value = lookup(name)
    if value.len == 0: continue
    if value.len < MinSecretValueLen:
      result.unsearchable.add name
      continue
    result.searched.add name
    if value in joined:
      cloudFail(clcLaunchPlanCarriesCredentialMaterial,
        "the value of " & name & " occurs in the invocation")

proc renderUnsearchableSecretWarning*(scan: PlanSecretScan): string =
  ## What an operator is told about a variable the check could not look
  ## for. Empty when there is nothing to say, so a caller can test it
  ## rather than test the list.
  if scan.unsearchable.len == 0: return ""
  "these variables are declared to hold credential material and are " &
    "set to a value shorter than " & $MinSecretValueLen & " characters, " &
    "so this plan was NOT searched for them: " &
    scan.unsearchable.join(", ")

proc checkedCloudLaunchPlanScanned*(spec: CloudLaunchSpec;
                                    env: CloudEnvLookup = nil):
                                    tuple[plan: seq[string];
                                          scan: PlanSecretScan] =
  ## The plan, the secret check over it, and what that check could not
  ## look for.
  result.plan = cloudLaunchPlan(spec)
  result.scan = requirePlanCarriesNoCredential(result.plan, env)

proc checkedCloudLaunchPlan*(spec: CloudLaunchSpec;
                             env: CloudEnvLookup = nil): seq[string] =
  ## The plan, and the secret check over it. The two are separate
  ## procedures so a caller with no environment to speak of can render a
  ## plan, and one procedure so nobody has to remember to run the check.
  checkedCloudLaunchPlanScanned(spec, env).plan

# ---------------------------------------------------------------------
# The effector seam — and the mode that never reaches it
# ---------------------------------------------------------------------

type
  CloudLaunchMode* = enum
    clmDryRun = "dry-run"
    clmArmed = "armed"

  CloudEffect* = object
    ## Exactly what an effector would be handed. The provider variables
    ## travel as NAMES: an effector reads them out of its own
    ## environment, so no value of one is ever inside a value this
    ## module built, printed or could record.
    ##
    ## It is EVERY name and not only the secrets. A launch needs the
    ## project and the region as much as it needs the key, and the
    ## narrowing that belongs here is on the kinds the check searches
    ## for, not on what the tool is allowed to read.
    argv*: seq[string]
    providerEnvNames*: seq[string]

  CloudEffector* = proc (effect: CloudEffect): int {.closure.}

  CloudLaunchOutcome* = object
    plan*: seq[string]
    identity*: string
    manifestText*: string
    effectsAttempted*: int
      ## How many times the effector was called. The dry run's answer is
      ## zero, and it is a COUNT rather than a flag so that a gate can
      ## tell "never called" from "called and said nothing".
    effectStatus*: int
    secretScan*: PlanSecretScan
      ## What the secret check looked for, and what it could not look
      ## for. Carried out rather than logged inside, because the caller
      ## is the one with somewhere to print it.

proc performCloudLaunch*(spec: CloudLaunchSpec; mode: CloudLaunchMode;
                         effector: CloudEffector = nil;
                         env: CloudEnvLookup = nil): CloudLaunchOutcome =
  ## Compute everything, and hand the invocation on only when armed.
  ##
  ## Both modes do the SAME work up to the last statement. That is
  ## deliberate: a dry run that took a shorter path would prove nothing
  ## about the path an armed launch takes, and "the dry run creates
  ## nothing" would be a statement about different code.
  let checked = checkedCloudLaunchPlanScanned(spec, env)
  result.plan = checked.plan
  result.secretScan = checked.scan
  result.manifestText = cloudExpectedManifestText(spec)
  result.identity = DigestPrefix & sha256Hex(result.manifestText)
  case mode
  of clmDryRun:
    discard
  of clmArmed:
    if effector == nil:
      cloudFail(clcArmedLaunchHasNoEffector,
        "the invocation is " & $result.plan.len & " arguments long")
    result.effectsAttempted = 1
    result.effectStatus = effector(CloudEffect(argv: result.plan,
      providerEnvNames: providerEnvNamesFor(spec.provider)))

proc renderCloudLaunchPlanText*(outcome: CloudLaunchOutcome): string =
  ## The operator-facing rendering: the invocation, one argument per
  ## line, then the identity a policy would pin. One argument per line
  ## because an invocation printed as a single line invites being pasted
  ## into a shell, and this one is not for that.
  result = "launch-plan:\n"
  for arg in outcome.plan:
    result.add "  " & arg & "\n"
  result.add "expected-measurement-identity: " & outcome.identity & "\n"

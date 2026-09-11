## The verifier: eleven checks, run in order, none of them skipped
## silently.
##
## ## The shape
##
## ``verifyAttestationReport`` parses the report, reads its
## backend-native evidence, and then runs **every** check in
## ``VerifierCheck`` — including the ones already known to be doomed by
## an earlier failure. That is deliberate: a verdict is worth reading
## precisely because it says what was and was not established, and a
## driver that stopped at the first failure would produce a verdict whose
## remaining rows meant "unknown" while looking like "fine".
##
## The loop is over the enum, so a check cannot be dropped from the
## dispatch without the compiler noticing (the ``case`` is exhaustive)
## and cannot be dropped from the *record* without the verdict rejecting
## (``coNotReached``). See ``verdict.nim``'s header for the three
## refusals that structure holds up.
##
## ## Where a skip is authorised, and where it is not
##
## Every check is recorded with a ``required`` flag, derived from the
## policy and — for two of them — from the report's tier. A check that
## could not be performed is a **failure** unless its flag says the
## policy does not require it. Concretely:
##
##   * ``measurement-match`` may be skipped only for a mock-tier report
##     under a policy whose ``allow_mock`` is set. A mock report under a
##     policy that does not allow the tier fails this check as well as
##     the tier check, because the skip was never authorised.
##   * ``manifest-pinned`` may be skipped only when the policy pins no
##     manifest digest — the local-reproduction posture, which the policy
##     author has to spell as ``manifests = []``.
##   * ``challenge-freshness`` may be skipped only when the policy sets
##     ``max_challenge_age_seconds = 0``. A policy that sets a window and
##     a verifier that does not know when it issued the challenge is a
##     **failure**: the window is a clause that has to bite.
##   * ``certificate-chain`` may be skipped only when the policy does not
##     require a bundled chain.
##   * ``tcb-floor`` may be skipped for any tier that reports no vendor
##     trusted computing base.
##
## Everything else is required unconditionally, ``native-evidence`` most
## of all.
##
## ## The embedding seam
##
## ``verifyWithReading`` takes a reading a *caller* performed, for a
## backend this build carries no reader for. That is the API a downstream
## broker with its own SEV-SNP verifier plugs into, and it is not a
## bypass of anything: the caller supplies only the five facts a reader
## produces, and the envelope's tier, backend, challenge and bindings are
## re-projected from the report here rather than taken from the reading.
## A reading that disagreed with the report about what tier it is cannot
## make the verdict disagree. The reader's name is recorded in the
## verdict and a reader this build does not carry earns a caveat, so a
## verdict that rests on someone else's reading says so.
##
## ## Mocking
##
## None.

import std/[options, strutils]

import repro_attest

import ./challenge
import ./evidence
import ./policy
import ./verdict

export evidence, policy, verdict, challenge

type
  VerificationRequest* = object
    ## Everything a verification consumes. Assembled by the CLI, or by an
    ## embedding caller.
    reportText*: string
    reportSource*: string
    policy*: AttestationPolicy
    policySource*: string
    manifestText*: Option[string]
      ## The measurement manifest to compare against — the one the
      ## verifier built itself (posture 1) or the one its policy pins
      ## (posture 3). **Never fetched from the machine under
      ## verification**; see the CLI reference.
    manifestSource*: string
    expectedChallengeHex*: string
      ## The nonce this verifier issued. Empty when none was supplied,
      ## which makes the challenge check inapplicable — and, under any
      ## policy that requires a challenge, therefore a failure.
    challengeIssuedAtMs*: Option[int64]
    nowMs*: int64

const
  BuiltInReaders*: array[1, string] = [MockReaderName]
    ## The readers this build carries. A verdict whose evidence was read
    ## by anything else is caveated, because it rests on a claim the
    ## caller made rather than on code that shipped here.

# ---------------------------------------------------------------------
# The individual checks
#
# Each is a pure function of the authoritative inputs and the policy. In
# particular NONE of them takes an `AttestationReport`, so none of them
# can read the instance's own claims -- see `evidence.nim`.
# ---------------------------------------------------------------------

proc checkTierAccepted(p: AttestationPolicy;
                       inputs: AuthoritativeInputs): CheckFinding =
  if p.acceptsTier(inputs.tier):
    var names: seq[string] = @[]
    for t in p.tiers: names.add $t
    return satisfied("the report's tier is " & $inputs.tier &
      " and the policy accepts " & names.join(", "))
  var names: seq[string] = @[]
  for t in p.tiers: names.add $t
  if inputs.tier == atMock and not p.allowMock:
    return violated("the report's tier is " & $inputs.tier &
      " and this policy does not set accept.allow_mock; a report with no " &
      "root of trust is accepted only by a policy that says so twice")
  violated("the report's tier is " & $inputs.tier &
    " and the policy accepts " & names.join(", "))

proc checkBackendAccepted(p: AttestationPolicy;
                          inputs: AuthoritativeInputs): CheckFinding =
  var names: seq[string] = @[]
  for b in p.backends: names.add $b
  if p.acceptsBackend(inputs.backend):
    return satisfied("the report's backend is " & $inputs.backend &
      " and the policy accepts " & names.join(", "))
  violated("the report's backend is " & $inputs.backend &
    " and the policy accepts " & names.join(", "))

proc checkReportDataBinding(inputs: AuthoritativeInputs): CheckFinding =
  ## The check the report parser cannot make.
  ##
  ## The parser already refuses an envelope whose ``reportData`` is not
  ## what its own challenge and bindings produce. What it cannot do is
  ## look inside the signed evidence, and a backend that bound *other*
  ## bytes produces exactly that: an envelope and a signature that
  ## disagree. Recomputed here from the challenge and the bindings, never
  ## copied from the envelope, so the comparison has two independent
  ## sides.
  if inputs.reportDataInEvidence.isNone:
    return inapplicable("the reader " & inputs.readerName.escape() &
      " located no report data inside the evidence, so the bytes the " &
      "envelope claims were bound could not be checked against the bytes " &
      "that were signed")
  var recomputed = ""
  try:
    recomputed = reportDataHexFor(inputs.bindings, inputs.challengeHex)
  except BindingError as err:
    return violated("this report's challenge and bindings do not produce " &
      "any report data: " & err.msg)
  let inEvidence = inputs.reportDataInEvidence.get
  if inEvidence != recomputed:
    return violated("the signed evidence binds " & inEvidence &
      " but this report's own challenge and bindings produce " & recomputed &
      "; the envelope and the bytes the backend signed disagree about " &
      "what this instance bound")
  satisfied("the 64 bytes inside the signed evidence are the ones this " &
    "report's challenge and bindings produce, recomputed here")

proc checkChallengeMatch(inputs: AuthoritativeInputs;
                         expectedHex: string): CheckFinding =
  if expectedHex.len == 0:
    return inapplicable("this verifier was given no challenge to match, " &
      "so nothing distinguishes this report from one answered for " &
      "somebody else at some other time")
  if inputs.challengeHex != expectedHex:
    return violated("the report answers challenge " & inputs.challengeHex &
      " and this verifier issued " & expectedHex)
  var recomputed = ""
  try:
    recomputed = reportDataHexFor(inputs.bindings, expectedHex)
  except BindingError as err:
    return violated("the challenge this verifier issued is not one the " &
      "binding discipline accepts: " & err.msg)
  if recomputed != inputs.reportDataHex:
    return violated("the report echoes this verifier's challenge but its " &
      "report data is not what that challenge and its bindings produce")
  satisfied("the report answers the challenge this verifier issued, and " &
    "its report data follows from it")

proc checkChallengeFreshness(p: AttestationPolicy;
                             issuedAtMs: Option[int64];
                             nowMs: int64): CheckFinding =
  let window = p.freshness.maxChallengeAgeSeconds
  if window == 0:
    return inapplicable("the policy sets no maximum challenge age " &
      "(freshness.max_challenge_age_seconds = 0)")
  if issuedAtMs.isNone:
    return inapplicable("this verifier was not told when the challenge " &
      "was issued; mint one with `repro attest challenge` and pass the " &
      "record back with --challenge-file, or state the instant with " &
      "--challenge-issued-at")
  let ageMs = nowMs - issuedAtMs.get
  if ageMs < 0:
    return violated("the challenge record says it was issued " &
      $(-ageMs div 1000) & " s in the future; a verifier whose own clock " &
      "disagrees with its own record cannot bound anything")
  let ageSeconds = ageMs div 1000
  if ageSeconds > window:
    return violated("the challenge was issued " & $ageSeconds &
      " s ago and the policy accepts at most " & $window & " s")
  satisfied("the challenge was issued " & $ageSeconds &
    " s ago, within the policy's " & $window & " s")

proc checkManifestPinned(p: AttestationPolicy; manifestDigest: string;
                         haveManifest: bool): CheckFinding =
  if not p.pinsManifests:
    return inapplicable("the policy pins no manifest digest " &
      "(measurements.manifests = []), so whatever manifest this verifier " &
      "was handed is the one it used")
  if not haveManifest:
    return violated("the policy pins " & $p.measurements.manifests.len &
      " manifest digest(s) and this verifier was given no manifest to " &
      "compare against")
  if manifestDigest notin p.measurements.manifests:
    return violated("the manifest supplied digests to " & manifestDigest &
      ", which the policy does not pin; it pins " &
      p.measurements.manifests.join(", "))
  satisfied("the manifest supplied digests to " & manifestDigest &
    ", which the policy pins")

proc checkMeasurementMatch(inputs: AuthoritativeInputs;
                           manifest: AttestedImageManifest;
                           haveManifest: bool): CheckFinding =
  if inputs.launchMeasurement.isNone:
    return inapplicable("the " & $inputs.backend & " backend's evidence " &
      "carries no launch measurement, so there is nothing to compare " &
      "against a measurement manifest")
  if not haveManifest:
    return violated("the evidence attests a launch measurement and this " &
      "verifier was given no measurement manifest to compare it against")
  let observed = inputs.launchMeasurement.get
  let key = manifestBackendKey(inputs.backend)
  var expected: seq[string] = @[]
  if key == BackendTpm:
    for e in manifest.tpm: expected.add e.pcr11
  elif key == BackendSevSnp:
    for e in manifest.sevSnp: expected.add e.measurement
  elif key == BackendTdx:
    for e in manifest.tdx: expected.add e.mrtd
  else:
    return violated("the measurement manifest schema defines no launch " &
      "shape for the " & $inputs.backend & " backend")
  if expected.len == 0:
    return violated("the measurement manifest computed no " & key &
      " expectation, so it cannot say whether " & observed &
      " is what that image produces")
  if observed notin expected:
    return violated("the evidence attests launch measurement " & observed &
      " and the manifest's " & key & " expectations are " &
      expected.join(", "))
  satisfied("the evidence attests launch measurement " & observed &
    ", which the manifest's " & key & " expectations contain")

proc checkCertificateChain(p: AttestationPolicy;
                           inputs: AuthoritativeInputs): CheckFinding =
  if not inputs.bundledCertificates:
    if p.measurements.requireCertificates:
      return violated("the policy requires a bundled certificate chain " &
        "and this report bundles none")
    return inapplicable("the report bundles no certificate chain, and the " &
      "policy does not require one; a verifier that fetches vendor " &
      "collateral itself does not need the instance's copy")
  case inputs.backend
  of abMock: describeMockChain(inputs)
  of abSevSnp, abTdx, abTpm2:
    violated("this build carries no reader for a " & $inputs.backend &
      " certificate chain, so the " & $inputs.certificates.len &
      " bundled element(s) were compared against nothing")

proc tdxStatusRank(status: string): int =
  ## Lower is better. ``-1`` for a status this build cannot order.
  for i, known in KnownTdxTcbStatuses:
    if known == status: return i
  -1

proc checkTcbFloor(p: AttestationPolicy;
                   inputs: AuthoritativeInputs): CheckFinding =
  case inputs.backend
  of abSevSnp:
    if inputs.sevSnpTcb.isNone:
      return inapplicable("no reader supplied an SEV-SNP TCB version, so " &
        "the policy's floor could not be applied")
    if not p.tcb.hasSevSnpMinTcb:
      return violated("the report is SEV-SNP and the policy states no " &
        "sev-snp TCB floor")
    let got = inputs.sevSnpTcb.get
    let want = p.tcb.sevSnpMinTcb
    var below: seq[string] = @[]
    if got.bootloader < want.bootloader:
      below.add "bootloader " & $got.bootloader & " < " & $want.bootloader
    if got.tee < want.tee: below.add "tee " & $got.tee & " < " & $want.tee
    if got.snp < want.snp: below.add "snp " & $got.snp & " < " & $want.snp
    if got.microcode < want.microcode:
      below.add "microcode " & $got.microcode & " < " & $want.microcode
    if below.len > 0:
      return violated("the reported TCB is below the policy's floor: " &
        below.join(", "))
    satisfied("the reported TCB (bootloader " & $got.bootloader & ", tee " &
      $got.tee & ", snp " & $got.snp & ", microcode " & $got.microcode &
      ") is at or above the policy's floor")
  of abTdx:
    if inputs.tdxTcbStatus.isNone:
      return inapplicable("no reader supplied a TDX TCB status, so the " &
        "policy's floor could not be applied")
    if not p.tcb.hasTdxMinTcbStatus:
      return violated("the report is TDX and the policy states no tdx TCB " &
        "status floor")
    let got = inputs.tdxTcbStatus.get
    let gotRank = tdxStatusRank(got)
    if gotRank < 0:
      return violated("the evidence reports TCB status " & got.escape() &
        ", which this build cannot order against the policy's floor")
    if gotRank > tdxStatusRank(p.tcb.tdxMinTcbStatus):
      return violated("the evidence reports TCB status " & got &
        " and the policy's floor is " & p.tcb.tdxMinTcbStatus)
    satisfied("the evidence reports TCB status " & got &
      ", at or above the policy's floor of " & p.tcb.tdxMinTcbStatus)
  of abTpm2, abMock:
    inapplicable("the " & $inputs.backend & " backend reports no vendor " &
      "trusted computing base")

# ---------------------------------------------------------------------
# The instance's own claims — advisory, and kept away from the decision
# ---------------------------------------------------------------------

proc unverifiedClaimNotes*(r: AttestationReport;
                           manifest: AttestedImageManifest;
                           haveManifest: bool): seq[string] =
  ## What the instance said about itself, and whether it agrees with the
  ## manifest.
  ##
  ## Every line is prefixed with the word ``unverified`` because that is
  ## what it is. These reach a verdict as ``claimNotes`` and
  ## ``decisionFor`` never sees them; they exist so that whoever reads a
  ## log to find out why a machine was refused does not have to guess.
  result.add "unverified generation: " & r.claims.unverifiedGeneration
  if not haveManifest:
    result.add "unverified configFingerprint: " &
      r.claims.unverifiedConfigFingerprint
    result.add "unverified verityRootHash: " &
      r.claims.unverifiedVerityRootHash
    return
  let fpAgrees =
    r.claims.unverifiedConfigFingerprint == manifest.configFingerprint
  result.add "unverified configFingerprint: " &
    r.claims.unverifiedConfigFingerprint &
    (if fpAgrees: " (agrees with the manifest)"
     else: " (DISAGREES with the manifest's " & manifest.configFingerprint &
       ")")
  let rhAgrees =
    r.claims.unverifiedVerityRootHash == manifest.imageOutputs.verityRootHash
  result.add "unverified verityRootHash: " &
    r.claims.unverifiedVerityRootHash &
    (if rhAgrees: " (agrees with the manifest)"
     else: " (DISAGREES with the manifest's " &
       manifest.imageOutputs.verityRootHash & ")")

# ---------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------

proc verifyWithReading*(req: VerificationRequest;
                        report: AttestationReport;
                        reading: EvidenceReading): Verdict =
  ## Run every check against a report whose evidence has already been
  ## read. The embedding seam; see the module header for why a caller
  ## cannot steer the envelope through it.
  if reading.inputs.readerName.len == 0:
    raise newException(VerdictError,
      "an evidence reading must name the reader that produced it; a " &
      "verdict has to be able to say whose reading it rests on")

  # The envelope is re-projected from the report. Only the five facts a
  # READER produces are taken from the reading, so a caller cannot make
  # the verdict disagree with the document it is about.
  var inputs = projectEnvelope(report)
  inputs.readerName = reading.inputs.readerName
  inputs.launchMeasurement = reading.inputs.launchMeasurement
  inputs.reportDataInEvidence = reading.inputs.reportDataInEvidence
  inputs.sevSnpTcb = reading.inputs.sevSnpTcb
  inputs.tdxTcbStatus = reading.inputs.tdxTcbStatus

  let p = req.policy
  result.reportSource = req.reportSource
  result.policySource = req.policySource

  var manifest: AttestedImageManifest
  var haveManifest = false
  var manifestDigest = ""
  var manifestComplaint = ""
  if req.manifestText.isSome:
    manifestDigest = DigestPrefix & sha256Hex(req.manifestText.get)
    try:
      manifest = parseAttestedImageManifest(req.manifestText.get,
        req.manifestSource)
      haveManifest = true
    except ManifestError as err:
      manifestComplaint = err.msg
    except MeasurementError as err:
      manifestComplaint = err.msg

  # `measurement-match` may be skipped only for a mock report under a
  # policy that authorised the mock tier. A mock report under any other
  # policy fails it, because the skip was never granted.
  let measurementRequired = not (inputs.tier == atMock and p.allowMock)

  # The schema check is PERFORMED here rather than inherited from
  # whoever parsed the document. `verifyAttestationReport` arrives with a
  # report its own parser accepted, but this is also the embedding entry
  # point, and a caller that assembles an `AttestationReport` record — or
  # edits one after parsing — is not bound by the parser. A check that
  # could not fail on one of its two entry points is not a check on
  # either of them.
  var schemaFinding = satisfied("the document is a " &
    AttestationReportSchema & " this build reads, and is internally " &
    "consistent")
  try:
    validateAttestationReport(report)
  except ReportError as err:
    schemaFinding = violated(err.msg)
  except BindingError as err:
    schemaFinding = violated(err.msg)

  result.record(vcReportSchema, true, schemaFinding)
  result.record(vcTierAccepted, true, checkTierAccepted(p, inputs))
  result.record(vcBackendAccepted, true, checkBackendAccepted(p, inputs))
  result.record(vcNativeEvidence, true, reading.finding)
  result.record(vcReportDataBinding, true, checkReportDataBinding(inputs))
  result.record(vcChallengeMatch, p.freshness.requireChallenge,
    checkChallengeMatch(inputs, req.expectedChallengeHex))
  result.record(vcChallengeFreshness,
    p.freshness.maxChallengeAgeSeconds > 0,
    checkChallengeFreshness(p, req.challengeIssuedAtMs, req.nowMs))
  result.record(vcManifestPinned, p.pinsManifests,
    (if manifestComplaint.len > 0:
       violated("the supplied measurement manifest is not one this build " &
         "will read: " & manifestComplaint)
     else: checkManifestPinned(p, manifestDigest, haveManifest)))
  result.record(vcMeasurementMatch, measurementRequired,
    (if manifestComplaint.len > 0:
       violated("the supplied measurement manifest is not one this build " &
         "will read: " & manifestComplaint)
     else: checkMeasurementMatch(inputs, manifest, haveManifest)))
  result.record(vcCertificateChain, p.measurements.requireCertificates,
    checkCertificateChain(p, inputs))
  result.record(vcTcbFloor, inputs.tier == atCvm, checkTcbFloor(p, inputs))

  result.seal(inputs.tier)

  # Identity is established by a measurement that MATCHED **inside a
  # verdict that accepted**, and is taken from the manifest — never from
  # the report's claims, which is the whole reason those live in a
  # different field of a different type.
  #
  # The decision clause is not belt and braces. A measurement can match a
  # manifest the policy does not pin, or one compared under a challenge
  # that was never answered; the comparison succeeded and the verdict is
  # still a rejection, and a rejected verdict that also printed an
  # established configuration would be read as a qualified yes.
  if result.decision.isAcceptance and haveManifest and
     result.checks[vcMeasurementMatch].outcome == coPassed:
    result.hasIdentity = true
    result.identity = EstablishedIdentity(
      configFingerprint: manifest.configFingerprint,
      verityRootHash: manifest.imageOutputs.verityRootHash,
      manifestDigest: manifestDigest)

  if inputs.tier == atMock:
    result.caveats.add MockCaveat
  if inputs.readerName notin BuiltInReaders:
    result.caveats.add "the backend-native evidence was read by " &
      inputs.readerName.escape() & ", which is not a reader this build " &
      "carries; this verdict rests on the caller's reading of it"
  if result.decision.isAcceptance and not p.pinsManifests:
    result.caveats.add UnpinnedManifestCaveat
  if result.decision.isAcceptance:
    for chk in result.skippedChecks:
      result.caveats.add "this verdict was reached without performing the " &
        $chk & " check: " & result.checks[chk].detail

  result.claimNotes = unverifiedClaimNotes(report, manifest, haveManifest)

proc rejectUnparseable(req: VerificationRequest;
                       complaint: string): Verdict =
  ## A report that does not parse still gets a full verdict: the schema
  ## check violated, and every other check recorded as required and
  ## inapplicable, which ``outcome`` turns into a failure. Nothing is
  ## left ``coNotReached``, so the enumeration is complete for a
  ## rejection as well as for an acceptance.
  result.reportSource = req.reportSource
  result.policySource = req.policySource
  result.record(vcReportSchema, true, violated(complaint))
  for chk in VerifierCheck:
    if chk == vcReportSchema: continue
    result.record(chk, true, inapplicable(
      "the report did not parse, so there was nothing to check"))
  # The tier is unknown, so the least-trusting one is passed. It cannot
  # matter: a failed check has already decided this verdict.
  result.seal(atMock)

proc verifyAttestationReport*(req: VerificationRequest): Verdict =
  ## Parse, read the evidence with this build's reader for its backend,
  ## and run every check.
  var report: AttestationReport
  try:
    report = parseAttestationReport(req.reportText, req.reportSource)
  except ReportError as err:
    return rejectUnparseable(req, err.msg)
  except BindingError as err:
    return rejectUnparseable(req, err.msg)
  verifyWithReading(req, report, readAuthoritativeEvidence(report))

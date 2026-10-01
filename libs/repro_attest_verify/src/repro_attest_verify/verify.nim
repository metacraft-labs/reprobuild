## The verifier: thirteen checks, run in order, none of them skipped
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
## The loop is over the enum and the body is a ``case`` over it, so a
## check cannot be dropped from the dispatch without the compiler
## noticing (the ``case`` is exhaustive) and cannot be dropped from the
## *record* without the verdict rejecting (``coNotReached``). See
## ``verdict.nim``'s header for the three refusals that structure holds
## up.
##
## That first sentence described no code for a long time: the records
## were a straight-line sequence and the only loop over the enum was on
## the unparseable path, so a check added to the enum and not here
## rejected every report at run time instead of failing to compile. The
## dispatch is a ``case`` now and the sentence is true.
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
##     require a bundled chain — and only when no chain was bundled. A
##     chain that IS bundled is always judged, whatever the policy says
##     about requiring one, because a chain that arrived and was not
##     looked at is worse than one that never came.
##   * ``tcb-floor`` may be skipped for any tier that reports no vendor
##     trusted computing base.
##   * ``evidence-quorum`` may be skipped only when the policy states no
##     ``[measurements.evidence]`` clause **and** no attestations were
##     supplied. A bundle that arrived is always judged, on the same
##     grounds as a bundled certificate chain — and note *how* that is
##     enforced: not by the ``required`` flag, which only governs what an
##     inapplicable finding means, but by the check itself, which
##     VIOLATES rather than declines whenever evidence arrived. A flag
##     that looked like it carried the rule would have been a rule with
##     no reachable input.
##   * ``transparency-log`` may be skipped only when the policy does not
##     require inclusion and no inclusion proof was supplied. A proof
##     that arrived is always judged, by the same mechanism: every path
##     on which a proof is present returns satisfied or violated, never
##     inapplicable.
##
## Everything else is required unconditionally, ``native-evidence`` most
## of all.
##
## ## The embedding seam
##
## ``verifyWithReading`` takes a reading a *caller* performed. This
## build now ships a reader for every backend the schema names, so the
## seam is no longer about a backend nobody here can parse; what it is
## about is a reader that establishes MORE than this build's does. The
## security-processor reader, for instance, refuses a report that
## bundles no chain, because it has no way to fetch the endorsement
## certificate for one; a broker that fetches from the vendor's key
## distribution service can read what this build cannot and plug the
## result in here. It is not a bypass of anything: the caller supplies
## only the six facts a reader produces, and the envelope's tier,
## backend, challenge and bindings are re-projected from the report here
## rather than taken from the reading.
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
import ./quorum
import ./snp_chain
import ./tdx_chain
import ./tdx_collateral
import ./tdx_quote
import ./trust
import ./verdict
import ./x509

export evidence, policy, verdict, challenge, trust, x509, quorum

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
    trustAnchors*: seq[X509Cert]
      ## The certificates this verifier's operator installed as roots.
      ## Supplied by the caller and never taken from the report: a
      ## machine that could contribute to the set it is checked against
      ## would be vouching for itself.
    revocationLists*: seq[X509Crl]
      ## The revocation lists this verifier holds. An empty set is not
      ## "nothing has been revoked" — it is a question that cannot be
      ## asked, and `checkCertificateChain` refuses on it.
    vendorRevocationLists*: seq[string]
      ## The same question for a confidential-computing chain, whose
      ## lists are a different document: signed with RSASSA-PSS by a
      ## vendor root rather than with ECDSA by an operator's anchor, so
      ## they cannot travel in the field above. Raw DER, exactly as the
      ## vendor's distribution service serves it.
      ##
      ## Empty is, again, not an answer of "nothing is revoked": the
      ## chain evaluator refuses on it. There is deliberately no
      ## `trustAnchors` companion — the roots of those chains are not
      ## the operator's to choose. See `snp_chain` and `tdx_chain`.
      ##
      ## The two vendors' lists travel in the same field on purpose.
      ## Each evaluator sets aside every list whose issuer is not the
      ## authority it is judging, by name, so a verifier holding both
      ## vendors' collateral hands both to both and each takes its own.
    vendorCollateral*: TdxCollateralBundle
      ## The vendor-signed documents this VERIFIER fetched: what the
      ## platform's trusted-computing base is worth, and what the
      ## quoting enclave is supposed to be. Never taken from the report
      ## — a machine that chose the document it is judged against would
      ## be grading its own paper.
    hasVendorCollateral*: bool
      ## Whether the field above was filled. An absent bundle is not a
      ## pass: the reader then establishes no status, and the floor
      ## check fails for any tier that is supposed to have one.
    attestationsText*: Option[string]
      ## The ``reproos.edge-attestations.v1`` bundle that travels with
      ## the measurement manifest — the build plane's evidence that the
      ## manifest is what that configuration produces.
      ##
      ## This one DOES come from the publisher, and that is not an
      ## inconsistency with the rule above it. A manifest fetched from
      ## the machine under verification would let the machine choose
      ## what it is compared against; a *bundle* is a set of signatures
      ## by parties the policy named in advance, and an attacker who
      ## edits it can only make it verify less.
    attestationsSource*: string
    signerRoster*: seq[QuorumSigner]
      ## The public keys of the rebuilders this verifier's operator
      ## installed. Supplied by the caller and never taken from the
      ## bundle, for the same reason ``trustAnchors`` is never taken
      ## from the report. The policy says which key identifiers may
      ## count; this says what those identifiers' keys actually are, and
      ## the two are required to name the same set.
    witnessedLogRoots*: seq[WitnessedLogRoot]
      ## The transparency-log roots this verifier has witnessed. An
      ## empty set is not "the log is fine" — it is a question that
      ## cannot be asked, and an inclusion proof against a log with no
      ## witnessed root here is refused, exactly as an empty revocation
      ## list is.

const
  SoftwareRootTestReportSymbol* = "verifySoftwareRootTestReport"
    ## The NAME of the report driver a build without
    ## ``-d:reproAttestSoftwareRootTestTrust`` does not have. See
    ## ``SoftwareRootTestChainSymbol`` in ``trust.nim`` for why a spelling
    ## has to be readable from the build that lacks the symbol.

  BuiltInReaders*: array[4, string] =
    [MockReaderName, Tpm2ReaderName, TdxReaderName, SnpReaderName]
    ## The readers this build carries. A verdict whose evidence was read
    ## by anything else is caveated, because it rests on a claim the
    ## caller made rather than on code that shipped here.
    ##
    ## **This list is a claim about the build and it has to be kept in
    ## step with `readAuthoritativeEvidence`'s dispatch.** A reader that
    ## ships and is not named here caveats every verdict it produces
    ## with "the caller read this", which is false; one that is named
    ## here and does not ship would drop a caveat that is true. The
    ## trust-domain reader was missing from it for exactly as long as it
    ## existed, and a gate now asserts the absence of that caveat on a
    ## verdict this build's own reader produced. The security-processor
    ## reader arrived with that lesson already paid for: it is named
    ## here in the same change that added it, and the same gate shape
    ## holds it there.

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

proc checkCertificateChain(req: VerificationRequest;
                           p: AttestationPolicy;
                           inputs: AuthoritativeInputs;
                           evaluateChain: ChainEvaluator): CheckFinding =
  if not inputs.bundledCertificates:
    if p.measurements.requireCertificates:
      return violated("the policy requires a bundled certificate chain " &
        "and this report bundles none")
    return inapplicable("the report bundles no certificate chain, and the " &
      "policy does not require one; a verifier that fetches vendor " &
      "collateral itself does not need the instance's copy")
  case inputs.backend
  of abMock: describeMockChain(inputs)
  of abSevSnp:
    if inputs.certificates.len != AmdChainElements:
      return violated("a confidential-computing endorsement chain is " &
        $AmdChainElements & " certificates — the endorsement key, the " &
        "vendor's signing key and the vendor's root — and this report " &
        "bundles " & $inputs.certificates.len)
    var elements: seq[seq[byte]] = @[]
    for der in inputs.certificates:
      var bytes = newSeq[byte](der.len)
      for i in 0 ..< der.len: bytes[i] = byte(der[i])
      elements.add bytes
    var crls: seq[seq[byte]] = @[]
    for der in req.vendorRevocationLists:
      var bytes = newSeq[byte](der.len)
      for i in 0 ..< der.len: bytes[i] = byte(der[i])
      crls.add bytes
    # No anchor is passed, because there is no anchor to pass. The set
    # of roots this can reach is a constant in `snp_chain`, and the
    # verdict below is the only thing this function learns about it.
    let verdict = evaluateAmdChain(elements[0], elements[1], elements[2],
                                   crls, req.nowMs div 1000)
    if verdict.isAccepted:
      satisfied("the " & $inputs.certificates.len &
        "-element bundled chain reaches this build's " & $verdict.rootLine &
        " vendor root: " & verdict.detail)
    else:
      violated("the " & $inputs.certificates.len &
        "-element bundled chain was refused (" & $verdict.reason & "): " &
        verdict.detail)
  of abTdx:
    if inputs.certificates.len != TdxChainElements:
      return violated("a trust-domain endorsement chain is " &
        $TdxChainElements & " certificates — the provisioning " &
        "certification key, its authority and the vendor's root — and " &
        "this report bundles " & $inputs.certificates.len)
    var elements: seq[seq[byte]] = @[]
    for der in inputs.certificates:
      var bytes = newSeq[byte](der.len)
      for i in 0 ..< der.len: bytes[i] = byte(der[i])
      elements.add bytes
    var crls: seq[seq[byte]] = @[]
    for der in req.vendorRevocationLists:
      var bytes = newSeq[byte](der.len)
      for i in 0 ..< der.len: bytes[i] = byte(der[i])
      crls.add bytes
    # No anchor is passed, because there is no anchor to pass. The set
    # of roots this can reach is a constant in `tdx_chain`, and the
    # verdict below is the only thing this function learns about it.
    let verdict = evaluateIntelPckChain(elements[0], elements[1],
                                        elements[2], crls,
                                        req.nowMs div 1000)
    if verdict.isAccepted:
      satisfied("the " & $inputs.certificates.len &
        "-element bundled chain reaches this build's vendor root: " &
        verdict.detail)
    else:
      violated("the " & $inputs.certificates.len &
        "-element bundled chain was refused (" & $verdict.reason & "): " &
        verdict.detail)
  of abTpm2:
    # The evaluator is supplied by whichever of this module's two
    # drivers is running. Both call the same thirteen checks; the
    # production one passes `evaluateProductionChain`, which has no
    # policy argument and no way to widen what it recognises. See
    # `trust.nim`'s header.
    let verdict = evaluateChain(inputs.certificates,
      req.trustAnchors, req.revocationLists,
      ChainExpectation(
        requiredEku: OidTcgAikCertificate,
        requiredSubjectAltName: requiredSubjectAltNameFor($inputs.backend),
        nowSeconds: req.nowMs div 1000))
    if verdict.isAccepted:
      satisfied("the " & $inputs.certificates.len &
        "-element bundled chain was accepted by the " & verdict.evaluator &
        ": " & verdict.detail)
    else:
      violated("the " & $inputs.certificates.len &
        "-element bundled chain was refused by the " & verdict.evaluator &
        " (" & $verdict.reason & "): " & verdict.detail)

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
# The build plane: what the edge attestations that travel with a
# manifest are worth
#
# Two checks over one context, computed once. They are separate checks
# because they answer separate questions and a policy may require either
# alone; they share a context because both rest on the same three
# preconditions — a manifest to make a claim about, a bundle that parses,
# and a bundle whose subject IS that claim — and a reader who saw those
# three reported differently by the two rows would not know which to
# believe.
# ---------------------------------------------------------------------

type
  EvidenceContext = object
    supplied: bool
      ## A bundle was handed in, whatever became of it.
    parsed: bool
    complaint: string
      ## Why the bundle is not usable, when it is not. Empty otherwise.
    bundle: EdgeAttestationBundle
    claim: EdgeClaim
      ## Derived from the MANIFEST this verifier holds, never from the
      ## bundle's own ``subject``.
    haveClaim: bool
    quorum: QuorumEvaluation
    inclusion: InclusionEvaluation
    rosterComplaint: string
    heldSigners: seq[string]
      ## The key identifiers this verifier holds a public key for,
      ## sorted. Taken from the roster the CALLER supplied, so the
      ## comparison against the policy's admitted set has two
      ## independent sides.

proc evidenceContextFor(req: VerificationRequest; manifestText: string;
                        haveManifest: bool): EvidenceContext =
  result.supplied = req.attestationsText.isSome
  result.heldSigners = rosterNames(req.signerRoster)
  if haveManifest:
    try:
      result.claim = claimForManifest(manifestText, req.manifestSource)
      result.haveClaim = true
    except CatchableError as err:
      result.complaint = "the measurement manifest yields no claim to " &
        "attest: " & err.msg
  if not result.supplied: return
  try:
    result.bundle = parseEdgeAttestationBundle(req.attestationsText.get,
      req.attestationsSource)
    result.parsed = true
  except EdgeAttestationError as err:
    result.complaint = err.msg
    return
  if not result.haveClaim: return
  try:
    result.quorum = evaluateQuorum(result.bundle, result.claim,
                                   req.signerRoster, req.nowMs div 1000)
  except RosterError as err:
    result.rosterComplaint = err.msg
  result.inclusion = evaluateInclusion(result.bundle, result.claim,
                                       req.witnessedLogRoots)

proc checkEvidenceQuorum(p: AttestationPolicy;
                         ctx: EvidenceContext): CheckFinding =
  ## K distinct admitted rebuilders, or a named reason why not.
  ##
  ## Every refusal below says a different thing, deliberately. A check
  ## whose failures share one sentence is a check a reader cannot act on
  ## and a gate can pass by accident.
  if not p.acceptsEvidence:
    if not ctx.supplied:
      return inapplicable("the policy states no [measurements.evidence] " &
        "clause and no edge attestations were supplied, so there was no " &
        "quorum to count")
    return violated("edge attestations were supplied and this policy " &
      "states no [measurements.evidence] clause to judge them by; " &
      "evidence that was carried and never evaluated must not be " &
      "mistaken for evidence that was satisfied")
  let ev = p.measurements.evidence
  if not ctx.supplied:
    return violated("the policy accepts a manifest on the strength of " &
      $ev.minSignatures & " of " & $ev.knownKeys.len &
      " rebuilder signatures and no edge attestations were supplied")
  if not ctx.parsed:
    return violated("the supplied edge attestations are not a document " &
      "this build will read: " & ctx.complaint)
  if not ctx.haveClaim:
    return violated("edge attestations were supplied and this verifier " &
      "holds no measurement manifest for them to be about, so there is " &
      "no claim their signatures could be checked against" &
      (if ctx.complaint.len > 0: " (" & ctx.complaint & ")" else: ""))

  # The bundle's own subject is compared against the claim, and is used
  # for nothing else. A bundle whose subject disagreed would already
  # fail every signature — the statement is derived from the claim, not
  # from the subject — so this row exists to say WHY rather than to
  # decide anything.
  if ctx.bundle.subject.manifestDigest != ctx.claim.manifestDigest:
    return violated("the attestations are about the manifest " &
      ctx.bundle.subject.manifestDigest & " and this verifier holds " &
      ctx.claim.manifestDigest)
  if ctx.bundle.subject.configFingerprint != ctx.claim.configFingerprint:
    return violated("the attestations name the configuration " &
      ctx.bundle.subject.configFingerprint.escape() &
      " and the manifest this verifier holds was produced by " &
      ctx.claim.configFingerprint.escape())

  if ctx.rosterComplaint.len > 0:
    return violated("this verifier's signer roster is not one a quorum " &
      "can be counted over: " & ctx.rosterComplaint)
  let have = ctx.heldSigners
  for admitted in ev.knownKeys:
    if admitted notin have:
      return violated("the policy admits the signer " & admitted &
        " and this verifier holds no public key for it; the quorum would " &
        "be counted over a smaller set than the policy states, without " &
        "the policy changing")
  for held in have:
    if held notin ev.knownKeys:
      return violated("this verifier holds a public key for " & held &
        " and the policy admits no such signer; a key the policy never " &
        "named must not be able to contribute to its threshold")

  if ctx.quorum.defects.len > 0:
    return violated("the attestations carry " & $ctx.quorum.defects.len &
      " entr" & (if ctx.quorum.defects.len == 1: "y" else: "ies") &
      " that a quorum cannot be counted over, and a threshold reached " &
      "beside a forgery is a threshold an attacker chose: " &
      ctx.quorum.defects.join("; "))

  let counted = ctx.quorum.countedSigners.len
  if counted < ev.minSignatures:
    return violated("the attestations carry " & $counted &
      " valid signature(s) from admitted signers (" &
      (if counted == 0: "none" else: ctx.quorum.countedSigners.join(", ")) &
      ") and the policy requires " & $ev.minSignatures & " of the " &
      $ev.knownKeys.len & " it admits")
  satisfied("the attestations carry " & $counted &
    " valid signature(s) from distinct admitted signers (" &
    ctx.quorum.countedSigners.join(", ") & "), and the policy requires " &
    $ev.minSignatures & " of the " & $ev.knownKeys.len & " it admits")

proc checkTransparencyLog(p: AttestationPolicy;
                          ctx: EvidenceContext): CheckFinding =
  ## Inclusion in a log whose root this verifier already held.
  let required = p.requiresTransparencyLog
  if not ctx.supplied:
    if required:
      return violated("the policy requires transparency-log inclusion " &
        "and no edge attestations were supplied to prove any")
    return inapplicable("the policy does not require transparency-log " &
      "inclusion and no edge attestations were supplied")
  if not ctx.parsed:
    if required:
      return violated("the policy requires transparency-log inclusion " &
        "and the supplied attestations do not parse: " & ctx.complaint)
    return inapplicable("the supplied attestations do not parse, so this " &
      "verifier cannot say whether they carried an inclusion proof")
  let proofs = inclusionEntriesOf(ctx.bundle)
  if not ctx.haveClaim:
    if required or proofs.len > 0:
      # A proof that ARRIVED and could not be checked is a violation
      # even under a policy that never asked for one — the same rule the
      # rest of this check follows, applied to the case where what is
      # missing is the claim rather than the root.
      return violated("an inclusion proof was supplied and this verifier " &
        "holds no measurement manifest, so it does not know which leaf to " &
        "look for")
    return inapplicable("this verifier holds no measurement manifest, so " &
      "it does not know which leaf an inclusion proof would be about")

  if proofs.len == 0:
    if required:
      return violated("the policy requires transparency-log inclusion " &
        "and the attestations carry no " & TransparencyLogVerifierId &
        " entry")
    return inapplicable("the policy does not require transparency-log " &
      "inclusion and the attestations carry no " &
      TransparencyLogVerifierId & " entry")

  # A proof that ARRIVED is judged whatever the policy says, on the same
  # grounds as a bundled certificate chain: a proof that was carried and
  # not looked at is worse than one that never came.
  if ctx.inclusion.defects.len > 0:
    return violated("the attestations carry " &
      $ctx.inclusion.defects.len & " inclusion proof(s) this verifier " &
      "could not stand behind: " & ctx.inclusion.defects.join("; "))
  satisfied("this claim is proved to sit in " &
    $ctx.inclusion.verifiedLogs.len & " log(s) whose root this verifier " &
    "has witnessed (" & ctx.inclusion.verifiedLogs.join(", ") & ")")

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

proc verifyUsing(req: VerificationRequest;
                 report: AttestationReport;
                 reading: EvidenceReading;
                 evaluateChain: ChainEvaluator): Verdict =
  ## Every check, against a report whose evidence has already been read,
  ## with the certificate chain judged by ``evaluateChain``.
  ##
  ## Not exported. The evaluator is the ONLY thing either entry point
  ## below varies, and there is no third caller — so "which rules a
  ## chain is judged by" is decided by which procedure was called, and
  ## that in turn is decided by which build this is.
  if reading.inputs.readerName.len == 0:
    raise newException(VerdictError,
      "an evidence reading must name the reader that produced it; a " &
      "verdict has to be able to say whose reading it rests on")

  # The envelope is re-projected from the report. Only the six facts a
  # READER produces are taken from the reading, so a caller cannot make
  # the verdict disagree with the document it is about.
  #
  # Those six are taken on the reading's word, and that is the seam's
  # contract rather than an oversight: this entry point exists for a
  # caller with its own reader. ``attestationKeySubject`` joins them on
  # the same terms as ``launchMeasurement`` — a caller that supplies one
  # it never established is lying to itself, and the caveat below is a
  # statement about the reading it was handed, not a check it performs.
  var inputs = projectEnvelope(report)
  inputs.readerName = reading.inputs.readerName
  inputs.launchMeasurement = reading.inputs.launchMeasurement
  inputs.reportDataInEvidence = reading.inputs.reportDataInEvidence
  inputs.sevSnpTcb = reading.inputs.sevSnpTcb
  inputs.tdxTcbStatus = reading.inputs.tdxTcbStatus
  inputs.attestationKeySubject = reading.inputs.attestationKeySubject

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

  let ctx = evidenceContextFor(req,
    (if req.manifestText.isSome: req.manifestText.get else: ""), haveManifest)

  # The dispatch is a `case` inside a loop over the enum, and BOTH
  # halves of that are load-bearing.
  #
  # The loop is what makes the order of the rows the order of the enum
  # rather than the order somebody typed them in. The `case` is what
  # makes a check added to `VerifierCheck` and not to this dispatch a
  # COMPILE ERROR: without it, the new row would simply stay
  # `coNotReached` and reject every report, which is fail-closed but
  # arrives as a mystery at run time rather than as a message at build
  # time.
  #
  # This module's header claimed the exhaustive `case` for a long time
  # before there was one; the records were a straight-line sequence. The
  # claim is true now.
  for chk in VerifierCheck:
    case chk
    of vcReportSchema:
      result.record(chk, true, schemaFinding)
    of vcTierAccepted:
      result.record(chk, true, checkTierAccepted(p, inputs))
    of vcBackendAccepted:
      result.record(chk, true, checkBackendAccepted(p, inputs))
    of vcNativeEvidence:
      result.record(chk, true, reading.finding)
    of vcReportDataBinding:
      result.record(chk, true, checkReportDataBinding(inputs))
    of vcChallengeMatch:
      result.record(chk, p.freshness.requireChallenge,
        checkChallengeMatch(inputs, req.expectedChallengeHex))
    of vcChallengeFreshness:
      result.record(chk, p.freshness.maxChallengeAgeSeconds > 0,
        checkChallengeFreshness(p, req.challengeIssuedAtMs, req.nowMs))
    of vcManifestPinned:
      result.record(chk, p.pinsManifests,
        (if manifestComplaint.len > 0:
           violated("the supplied measurement manifest is not one this " &
             "build will read: " & manifestComplaint)
         else: checkManifestPinned(p, manifestDigest, haveManifest)))
    of vcMeasurementMatch:
      result.record(chk, measurementRequired,
        (if manifestComplaint.len > 0:
           violated("the supplied measurement manifest is not one this " &
             "build will read: " & manifestComplaint)
         else: checkMeasurementMatch(inputs, manifest, haveManifest)))
    of vcCertificateChain:
      result.record(chk, p.measurements.requireCertificates,
        checkCertificateChain(req, p, inputs, evaluateChain))
    of vcTcbFloor:
      result.record(chk, inputs.tier == atCvm, checkTcbFloor(p, inputs))
    of vcEvidenceQuorum:
      # Required exactly when the policy states an evidence clause, and
      # NOT ALSO when a bundle merely arrived. The temptation is to add
      # that disjunct so an unevaluatable bundle cannot be waived into a
      # skip — but the `required` flag only decides what an
      # *inapplicable* finding means, and the two checks below return
      # inapplicable only on paths where no bundle was supplied. The
      # disjunct would therefore be a rule with no reachable input, and
      # the fail-closed behaviour it looks like it provides is already
      # provided where it belongs: by the findings themselves, which
      # VIOLATE rather than decline whenever evidence arrived.
      result.record(chk, p.acceptsEvidence, checkEvidenceQuorum(p, ctx))
    of vcTransparencyLog:
      result.record(chk, p.requiresTransparencyLog,
        checkTransparencyLog(p, ctx))

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
  #
  # When the manifest it comes out of is one the policy pinned nothing
  # about, the block is still written — it is the most useful thing the
  # verdict has to say — but the decision itself says so, through
  # `identityRestsOnUnauthenticatedManifest`, which reads the same two
  # rows this condition does. The caveat below is then the third channel
  # and not the only one.
  if result.decision.isAcceptance and haveManifest and
     result.checks[vcMeasurementMatch].outcome == coPassed:
    result.hasIdentity = true
    result.identity = EstablishedIdentity(
      configFingerprint: manifest.configFingerprint,
      verityRootHash: manifest.imageOutputs.verityRootHash,
      manifestDigest: manifestDigest)

  if inputs.tier == atMock:
    result.caveats.add MockCaveat
  # The measured-boot reader establishes that a log explains a quote. It
  # establishes who signed the quote only when the report bundled a chain
  # to check the signature against; with no chain there is no key, and a
  # verdict that accepted on that basis without saying so would be read
  # as more than it is.
  #
  # So the caveat is attached to the READING that has the limit — not to
  # the tier, and not to the outcome. It rides a rejection as much as an
  # acceptance, because a refusal's reader is worth knowing about too,
  # and it rides a reading that parsed nothing as much as one that parsed
  # everything: "nobody checked a signature" is true of both. What lifts
  # it is exactly one thing, and it is a fact the reader produced rather
  # than a property of this function's arguments.
  if inputs.readerName == Tpm2ReaderName and
     inputs.attestationKeySubject.isNone:
    result.caveats.add "this verdict rests on a reading in which " &
      NoSignatureCheckedNote
  if inputs.readerName notin BuiltInReaders:
    result.caveats.add "the backend-native evidence was read by " &
      inputs.readerName.escape() & ", which is not a reader this build " &
      "carries; this verdict rests on the caller's reading of it"
  # "Authenticated by nothing but the fact that it was supplied" stops
  # being true the moment a quorum passed, so the condition carries that
  # clause rather than resting on `pinsManifests` alone. The two are
  # derived from the same rows the decision is, through the predicate in
  # `verdict`, so the caveat and the decision cannot come apart.
  if result.decision.isAcceptance and not p.pinsManifests and
     result.checks[vcEvidenceQuorum].outcome != coPassed:
    result.caveats.add UnpinnedManifestCaveat
  if result.decision.isAcceptance and
     result.checks[vcEvidenceQuorum].outcome == coPassed:
    # What a quorum establishes, and the two things it does not. Both
    # are limits of the design rather than of this implementation, and
    # both are stated on every acceptance that rests on one.
    result.caveats.add DistinctSignerCaveat
    if result.checks[vcTransparencyLog].outcome == coPassed:
      result.caveats.add UnverifiedLogAgeCaveat
  for caveat in ctx.quorum.caveats:
    # What the quorum evaluation itself could not establish. Carried on
    # every verdict it reached, accepted or not: a reader who is not
    # told what a revocation here means cannot tell a withdrawn key
    # from one that never signed.
    if caveat notin result.caveats: result.caveats.add caveat
  if ctx.parsed:
    let unevaluated = unevaluatedVerifiers(ctx.bundle)
    if unevaluated.len > 0:
      # Named on every verdict, accepted or not. An attestation nobody
      # looked at makes a bundle read better attested than the verdict
      # it produced, and silence about it is the honest-absence shape.
      result.caveats.add "the edge attestations carry proofs for " &
        $unevaluated.len & " verifier(s) this build does not implement (" &
        unevaluated.join(", ") & "); nothing in this verdict rests on them"
  if result.decision.isAcceptance:
    for chk in result.skippedChecks:
      result.caveats.add "this verdict was reached without performing the " &
        $chk & " check: " & result.checks[chk].detail

  result.claimNotes = unverifiedClaimNotes(report, manifest, haveManifest)

proc verifyWithReading*(req: VerificationRequest;
                        report: AttestationReport;
                        reading: EvidenceReading): Verdict =
  ## Run every check against a report whose evidence has already been
  ## read. The embedding seam; see the module header for why a caller
  ## cannot steer the envelope through it.
  ##
  ## A bundled certificate chain is judged by the production evaluator,
  ## and this procedure takes no argument that could change that.
  verifyUsing(req, report, reading, evaluateProductionChain)

when defined(reproAttestSoftwareRootTestTrust):
  proc verifySoftwareRootTestReport*(req: VerificationRequest;
                                     report: AttestationReport;
                                     reading: EvidenceReading): Verdict =
    ## The same thirteen checks, with the chain judged by the evaluator
    ## that additionally recognises the software-root marker.
    ##
    ## Compiled only into a build that asked for it by name; in every
    ## other build this symbol does not exist, so a production binary
    ## does not contain a path that could reach it. It is not a bypass
    ## of anything else either: every other check runs unchanged, and
    ## the chain still has to link, verify, reach an anchor, be inside
    ## its window, be unrevoked and carry the right purpose.
    verifyUsing(req, report, reading, evaluateSoftwareRootTestChain)

  static:
    doAssert declared(verifySoftwareRootTestReport)
    doAssert astToStr(verifySoftwareRootTestReport) ==
      SoftwareRootTestReportSymbol

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
  ##
  ## This is the entry point every *surface* uses — the CLI, and any
  ## caller that has a document rather than a reading. The chain is
  ## therefore judged by whichever evaluator this BUILD carries, and the
  ## ``when`` below is the only place that is decided.
  ##
  ## A build compiled with ``-d:reproAttestSoftwareRootTestTrust`` judges
  ## it by the evaluator that additionally recognises the software-root
  ## marker; every other build has no such symbol to reach and compiles
  ## the production call. The difference between a surface that accepts a
  ## test hierarchy and one that refuses it is which binary is running,
  ## exactly as it is for ``verifyWithReading`` and
  ## ``verifySoftwareRootTestReport`` one layer down — and this procedure
  ## takes no argument by which either could be selected at run time.
  var report: AttestationReport
  try:
    report = parseAttestationReport(req.reportText, req.reportSource)
  except ReportError as err:
    return rejectUnparseable(req, err.msg)
  except BindingError as err:
    return rejectUnparseable(req, err.msg)
  let reading = readAuthoritativeEvidence(report, req.vendorCollateral,
                                          req.hasVendorCollateral)
  when defined(reproAttestSoftwareRootTestTrust):
    verifySoftwareRootTestReport(req, report, reading)
  else:
    verifyWithReading(req, report, reading)

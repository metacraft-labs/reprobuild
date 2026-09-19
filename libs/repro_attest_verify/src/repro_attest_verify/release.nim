## Releasing a secret to a machine a verdict just accepted — and
## recording every decision, including the ones that release nothing.
##
## ## What this is
##
## The canonical consumer need: hand a credential to a machine **only
## if** it is running an approved configuration, with no operator or
## relay able to read it on the way. The protocol is three steps and this
## module is the middle one:
##
##   1. The verifier mints a challenge and asks the instance for a key
##      agreement. The instance mints an ephemeral key pair *inside the
##      boot session* and puts the public half into hardware-signed
##      evidence.
##   2. **Here.** Verify that evidence against a policy; on acceptance,
##      and only on acceptance, encrypt the secret to that public key
##      under a context rebuilt from the report itself.
##   3. Deliver the ciphertext to ``POST /provision``. Every relay in
##      between carries ciphertext and nothing else.
##
## ## The rules, and why each is here rather than in the policy
##
## A policy says what a *verdict* may be. Releasing a secret is a
## stronger act than accepting a verdict, so three rules are enforced
## here regardless of what any policy says:
##
##   * **The purpose must be a key agreement, with a key.** A report
##     produced for ``attest`` binds no key. There is nothing to encrypt
##     to, and an implementation that reached for one anyway would be
##     encrypting to something the evidence did not cover.
##   * **The challenge check must have PASSED, not merely not-failed.**
##     A policy may declare a challenge optional; a release may not. A
##     report this verifier did not challenge is a report whose freshness
##     rests on nothing, and freshness is the whole of what separates a
##     live instance from a recording of one. So the release reads
##     ``vcChallengeMatch``'s outcome, rather than reading the verdict's
##     decision and trusting that the policy asked.
##   * **A verdict that establishes no root of trust, or an identity
##     taken from a manifest nothing authenticated, does not release by
##     default.** Both are genuine acceptances and both are useful — the
##     first for development, the second for the reproduce-locally
##     posture — and both are exactly the shape in which "it said
##     accepted" is not the same as "a machine was identified". Each has
##     its own opt-in, named after what it gives up, so a deployment that
##     turns one on has written down which.
##
## ## Auditability is a mechanism here, not a recommendation
##
## The design says verifiers SHOULD log every release decision. A SHOULD
## that lives in a document is a SHOULD nobody implements, so this module
## will not make a decision without a sink to record it in: the sink is a
## required argument, a nil one is refused, and **a sink that raises
## withholds the secret**. A release nobody could record is a release
## that does not happen. Refusals are recorded too — a log that contains
## only the releases cannot answer the question an auditor actually has,
## which is what was asked for and turned down.
##
## The record is ``(challenge, measurement, policy digest, verdict)``,
## which is what the design names, plus what a reader needs to act on it:
## which secret, to which ephemeral key, and why.
##
## ## Where the measurement in the record comes from
##
## From the same reading the verdict was reached on, and from nowhere
## else. The report is parsed once, read once, and both the verdict and
## the record are taken from that one reading — so an audit log cannot
## come to name a measurement that is not the one a decision was made
## about. That is worth stating because the obvious implementation reads
## the evidence a second time to fill the log, and a second reading is a
## second chance to disagree.
##
## ## Mocking
##
## None. The verifier is the real verifier and the encryption is the real
## RFC 9180 composition.

import std/[base64, json, options, strutils]

import repro_attest
import repro_attest/x25519_kem

import nimcrypto/[hash, sha2]

import ./evidence
import ./verdict
import ./verify

const
  AttestationAuditSchema* = "reproos.attestation-release-audit.v1"
    ## One record per decision. Versioned: anything an auditor parses is
    ## a wire format.

  NoMeasurement* = "-"
    ## What the record carries when the backend takes no launch
    ## measurement. A dash rather than an empty string, so a record whose
    ## measurement is absent and a record whose measurement field was
    ## never written do not look alike in a log.

type
  ReleaseError* = object of CatchableError
    ## Raised for a release this module will not even decide — a missing
    ## sink, a policy nobody can identify, a secret that is not a secret.
    ## Distinct from *withholding*, which is a decision and is recorded.

  ReleaseDecision* = enum
    ## ``rdWithheld`` is the zero value. A decision nobody finished
    ## releases nothing.
    rdWithheld = "withheld"
    rdReleased = "released"

  AuditRecord* = object
    ## What an auditor reads. Every field is filled on both branches.
    atMs*: int64
    challengeHex*: string
      ## The nonce this verifier issued, as the report answered it.
    measurement*: string
      ## The launch measurement the evidence carries, or ``NoMeasurement``.
    policyDigest*: string
      ## ``sha256:<hex>`` of the policy document the decision was made
      ## under. The document, not the parsed record: two policies that
      ## parse alike are still two documents, and an auditor asks which
      ## file was in force.
    manifestDigest*: string
      ## The measurement manifest the verdict took its identity from, or
      ## the empty string when it established none.
    verdict*: VerdictDecision
    decision*: ReleaseDecision
    secretName*: string
    ephemeralPubHex*: string
    reason*: string
      ## One line. On a release it says what was established; on a
      ## withholding it says what was not.

  AuditSink* = ref object of RootObj
    ## Where decisions are recorded. A seam rather than a file, because
    ## "the format is deployment-specific" — but not an option: see the
    ## module header.

  ReleaseRequest* = object
    verification*: VerificationRequest
    policyText*: string
      ## The bytes of the policy document. Required, and hashed into the
      ## record: a decision recorded against a policy nobody can identify
      ## is a decision nobody can review.
    secretName*: string
      ## Empty means ``DefaultSecretName``.
    secret*: string
      ## The plaintext. Held for the duration of one call.
    allowNoRootOfTrust*: bool
      ## Release against ``accepted-without-a-root-of-trust``. A
      ## development affordance: the documents were well formed and
      ## consistent, and nothing about a machine was established.
    allowUnauthenticatedManifest*: bool
      ## Release against
      ## ``accepted-against-an-unauthenticated-manifest``. The
      ## reproduce-locally posture, where the manifest really was built
      ## here — and indistinguishable, to this code, from a verdict about
      ## an attacker's file.

  ReleaseOutcome* = object
    decision*: ReleaseDecision
    verdict*: Verdict
    audit*: AuditRecord
    wrappedSecretBase64*: string
      ## Empty unless released.
    provisionBody*: string
      ## The exact ``POST /provision`` body. Empty unless released. It is
      ## produced here rather than by the caller so that the four fields
      ## the agent binds together are assembled once, from the report
      ## that was verified.

method recordReleaseDecision*(s: AuditSink; rec: AuditRecord) {.base.} =
  ## Record one decision, or raise.
  ##
  ## Raising is meaningful: it withholds the secret. A sink that cannot
  ## write must not silently let a release through, because the log is
  ## the only evidence a release ever happened.
  raise newException(ReleaseError,
    "this audit sink does not implement recordReleaseDecision, so a " &
    "release decision would go unrecorded")

# ---------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------

proc renderAuditRecord*(rec: AuditRecord): string =
  ## One canonical line of JSON, newline-terminated. A line so that an
  ## append is atomic enough to interleave, and canonical so two readers
  ## of one log agree about what it says.
  $(%*{
    "schema": AttestationAuditSchema,
    "atMs": rec.atMs,
    "challenge": rec.challengeHex,
    "measurement": rec.measurement,
    "policyDigest": rec.policyDigest,
    "manifestDigest": rec.manifestDigest,
    "verdict": $rec.verdict,
    "decision": $rec.decision,
    "secretName": rec.secretName,
    "ephemeralPub": rec.ephemeralPubHex,
    "reason": rec.reason}) & "\n"

type
  FileAuditSink* = ref object of AuditSink
    ## Appends ``renderAuditRecord`` to a file. The sink a deployment
    ## gets when it has not brought its own.
    path: string

proc newFileAuditSink*(path: string): FileAuditSink =
  if path.len == 0:
    raise newException(ReleaseError,
      "an audit sink needs a path to append to")
  result = FileAuditSink(path: path)

proc path*(s: FileAuditSink): string = s.path

method recordReleaseDecision*(s: FileAuditSink; rec: AuditRecord) =
  let f = open(s.path, fmAppend)
  try:
    f.write(renderAuditRecord(rec))
  finally:
    f.close()

# ---------------------------------------------------------------------
# The decision
# ---------------------------------------------------------------------

proc policyDigestOf*(policyText: string): string =
  ## ``sha256:<hex>`` of a policy document, spelled the way a manifest
  ## digest is spelled so an auditor reads one format.
  DigestPrefix & toLowerAscii($sha256.digest(policyText))

proc releasesUnder(d: VerdictDecision; req: ReleaseRequest): bool =
  ## Whether this verdict, under these opt-ins, may release.
  ##
  ## Written as a total function over the enum rather than as a chain of
  ## ``if``s: a decision added later has to be given an answer here, and
  ## the compiler asks for it.
  case d
  of vdRejected: false
  of vdAccepted: true
  of vdAcceptedNoRootOfTrust: req.allowNoRootOfTrust
  of vdAcceptedUnpinnedManifest: req.allowUnauthenticatedManifest

proc withheldReason*(v: Verdict; req: ReleaseRequest): string =
  ## Why this verdict released nothing. Named per case, because "policy"
  ## is not an explanation anybody can act on.
  ##
  ## Exported for one reason: the ``vdAccepted`` arm cannot be reached
  ## through ``releaseSecret`` — ``releasesUnder`` answers true for that
  ## decision unconditionally, so a withholding never gets there — and a
  ## rule with no reachable input is not a rule. Collapsing all four
  ## arms to one sentence was GREEN on both gates until a case could
  ## call this directly.
  case v.decision
  of vdRejected:
    var failed: seq[string] = @[]
    for chk in v.failedChecks: failed.add $chk
    "the verdict is " & $v.decision & "; the checks that failed are " &
      (if failed.len == 0: "none, which is itself a defect in this verdict"
       else: failed.join(", "))
  of vdAcceptedNoRootOfTrust:
    "the verdict is " & $v.decision & ", which establishes that the " &
      "documents agree with each other and nothing about a machine; " &
      "releasing against it is a deliberate opt-in this request did not " &
      "make"
  of vdAcceptedUnpinnedManifest:
    "the verdict is " & $v.decision & ", so the configuration it names " &
      "was taken from a document the policy pinned nothing about; " &
      "releasing against it is a deliberate opt-in this request did not " &
      "make"
  of vdAccepted:
    "the verdict is " & $v.decision &
      ", and this build reached a withholding anyway; that is a defect"

proc releaseUsing(req: ReleaseRequest; v: Verdict;
                  purposeIsAgreement: bool; pubHex, measurement: string;
                  sink: AuditSink; senderSeed: string): ReleaseOutcome =
  ## The decision, the record and — on a release — the ciphertext.
  ##
  ## Everything above this line has already happened: the verdict is
  ## whatever the verifier reached, and the three values beside it were
  ## taken from the report and the reading that produced it. This
  ## procedure adds no reading of its own, so there is exactly one place
  ## in this module where a release is decided.
  let name = (if req.secretName.len == 0: DefaultSecretName
              else: req.secretName)
  result.verdict = v
  result.audit = AuditRecord(
    atMs: req.verification.nowMs,
    challengeHex: req.verification.expectedChallengeHex,
    measurement: measurement,
    policyDigest: policyDigestOf(req.policyText),
    manifestDigest: (if v.hasIdentity: v.identity.manifestDigest else: ""),
    verdict: v.decision,
    decision: rdWithheld,
    secretName: name,
    ephemeralPubHex: pubHex,
    reason: "")

  # The three release-side rules, in the order a reader would ask them.
  # Each writes its own reason; none of them shares one with another, so
  # a log line says which question was answered no.
  if not purposeIsAgreement:
    result.audit.reason =
      "the report's purpose is not " & $bpKeyAgreement &
      ", so it binds no ephemeral key and there is nothing a secret " &
      "could be encrypted to that this evidence covers"
  elif v.checks[vcChallengeMatch].outcome != coPassed:
    result.audit.reason =
      "the " & $vcChallengeMatch & " check is " &
      $v.checks[vcChallengeMatch].outcome &
      "; a policy may treat a challenge as optional and a release may " &
      "not, because freshness is the whole of what separates a live " &
      "instance from a recording of one"
  elif not releasesUnder(v.decision, req):
    result.audit.reason = withheldReason(v, req)
  else:
    result.audit.decision = rdReleased
    result.audit.reason =
      "the verdict is " & $v.decision & " and the secret was encrypted to " &
      "the ephemeral key that verdict's evidence binds"

  var wrapped = ""
  if result.audit.decision == rdReleased:
    # Composed BEFORE the record is written, so a sink that refuses
    # withholds a secret that exists rather than one that does not — and
    # after every check, so nothing is composed for a report that failed
    # one.
    wrapped = wrapSecretForEphemeral(
      hexToBytes("bindings.ephemeralPub", pubHex),
      hexToBytes("challenge", req.verification.expectedChallengeHex),
      name, req.secret, senderSeed)

  # A sink that raises takes the secret with it: `result` is discarded by
  # the raise, and the caller never sees a ciphertext for a decision that
  # was not recorded.
  sink.recordReleaseDecision(result.audit)

  result.decision = result.audit.decision
  if result.decision == rdReleased:
    result.wrappedSecretBase64 = base64.encode(wrapped)
    result.provisionBody = $(%*{
      "ephemeralPub": pubHex,
      "challenge": req.verification.expectedChallengeHex,
      "wrappedSecret": result.wrappedSecretBase64,
      "name": name})

proc checkReleasable(req: ReleaseRequest; sink: AuditSink) =
  ## What this module will not even DECIDE about. Distinct from
  ## withholding, which is a decision and is recorded: these are
  ## programming errors in the caller, and recording them against a
  ## policy digest or a name that does not exist would put nonsense in
  ## an audit log.
  if sink.isNil:
    raise newException(ReleaseError,
      "a release decision needs an audit sink; a decision nobody records " &
      "is a decision nobody can review, and this build will not make one")
  if req.policyText.len == 0:
    raise newException(ReleaseError,
      "the policy document is empty; a release recorded against a policy " &
      "nobody can identify cannot be reviewed against the policy that was " &
      "in force")
  if req.secret.len == 0:
    raise newException(ReleaseError,
      "the secret is empty; releasing nothing to an attested machine is a " &
      "mistake that would look exactly like success")
  validateSecretName(if req.secretName.len == 0: DefaultSecretName
                     else: req.secretName)

proc measurementOf(reading: EvidenceReading): string =
  if reading.inputs.launchMeasurement.isSome:
    reading.inputs.launchMeasurement.get
  else:
    NoMeasurement

proc releaseSecretWithReading*(req: ReleaseRequest;
                               report: AttestationReport;
                               reading: EvidenceReading; sink: AuditSink;
                               senderSeed: string): ReleaseOutcome =
  ## Decide against a reading the caller brought.
  ##
  ## The seam ``verifyWithReading`` is, one layer up: this build carries
  ## readers for two evidence formats, and a downstream broker with a
  ## reader for a third must be able to reach a release decision without
  ## waiting for that reader to land here. The caller's reading supplies
  ## the launch measurement and the 64 bytes as the hardware carried
  ## them; every RULE below is still this module's.
  checkReleasable(req, sink)
  let v =
    when defined(reproAttestSoftwareRootTestTrust):
      verifySoftwareRootTestReport(req.verification, report, reading)
    else:
      verifyWithReading(req.verification, report, reading)
  releaseUsing(req, v, report.bindings.purpose == bpKeyAgreement,
               report.bindings.ephemeralPub, measurementOf(reading),
               sink, senderSeed)

proc releaseSecret*(req: ReleaseRequest; sink: AuditSink;
                    senderSeed: string): ReleaseOutcome =
  ## Verify, decide, record, and — on a release — produce the ciphertext
  ## and the request body that carries it.
  ##
  ## ``senderSeed`` is the sender's own ephemeral-key seed, supplied
  ## rather than drawn, for the reason ``hpke`` gives: a construction
  ## whose randomness is a parameter can be pinned against published
  ## vectors. ``drawSenderSeed()`` is what a deployment passes.
  checkReleasable(req, sink)
  var report: AttestationReport
  try:
    report = parseAttestationReport(req.verification.reportText,
                                    req.verification.reportSource)
  except CatchableError:
    # A report that does not parse still gets a decision and a record.
    # `verifyAttestationReport` produces the full rejection verdict for
    # one, and there is no purpose, no key and no measurement to put
    # beside it — which is what the record then says.
    return releaseUsing(req, verifyAttestationReport(req.verification),
                        false, "", NoMeasurement, sink, senderSeed)
  releaseSecretWithReading(req, report, readAuthoritativeEvidence(report),
                           sink, senderSeed)

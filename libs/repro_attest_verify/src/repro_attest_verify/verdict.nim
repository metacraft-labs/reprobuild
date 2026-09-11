## The verdict: every check a verifier performed, and what came of it.
##
## ## What this type is for
##
## A verifier that answers "yes" or "no" is unusable. The party reading
## the answer has to know *which* questions were asked, which were
## answered, and — the one that matters most — which were **not asked at
## all**. A check that could not be performed and a check that passed are
## different facts, and a verdict that renders them the same way is a
## verdict that lies by omission.
##
## So this module is built around three refusals.
##
## **1. A check cannot be forgotten.** The record is an
## ``array[VerifierCheck, CheckRecord]``, indexed by the enum of every
## check this build knows about. There is no way to produce a verdict
## with a check missing from it; the only thing a bug can do is leave a
## record *unperformed*, and an unperformed record is ``coNotReached``,
## because ``performed`` is ``false`` by default. ``coNotReached`` is not
## acceptable, so a check that was silently dropped rejects the report.
## The fail-closed direction is the default direction.
##
## **2. A skip cannot be spelled as a pass.** A check does not choose its
## outcome. It returns a ``CheckFinding`` — satisfied, violated, or
## *inapplicable* — and the outcome is **derived** from that finding and
## from whether the policy required the check, by ``outcome`` below and
## nowhere else. ``fkInapplicable`` maps to ``coSkipped`` only when the
## policy does not require the check; when it does, "could not be
## performed" is a **failure**, not a waiver. There is no path from
## ``fkInapplicable`` to ``coPassed``.
##
## **3. A rejection is the default decision.** ``vdRejected`` is the zero
## value of ``VerdictDecision``, so a verdict nobody finished computing is
## a rejection. And the successful decision is *two* values, not one:
## ``vdAccepted`` and ``vdAcceptedNoRootOfTrust``. A report from the mock
## tier can only ever reach the second, and a consumer that writes
## ``== vdAccepted`` gets the safe answer without having read this
## paragraph. A consumer that wants the other one has to type its name.
##
## ## What is deliberately NOT in here
##
## The report's ``claims``. They are the instance's own statements about
## itself and §5.1 of the design says a verdict may never be derived from
## them. Saying so in a comment is not enforcement, so the checks in
## ``verify`` are handed an ``AuthoritativeInputs`` that has no claims
## field at all — a check that wanted to read one would not compile. The
## claims appear in a verdict only as ``claimNotes``, filled in *after*
## the decision is computed, and ``decisionFor`` cannot see them: it
## takes the check array and the tier, and nothing else.
##
## ## Mocking
##
## None.

import std/[strutils]

import repro_attest

type
  VerifierCheck* = enum
    ## Every question this build asks of a report. A verdict answers all
    ## of them, in this order.
    vcReportSchema = "report-schema"
      ## The document is a ``reproos.attestation-report.v1`` this build
      ## can read, and is internally consistent.
    vcTierAccepted = "tier-accepted"
      ## The root-of-trust tier is one the policy admits.
    vcBackendAccepted = "backend-accepted"
      ## The backend is one the policy admits, and belongs to the tier.
    vcNativeEvidence = "native-evidence"
      ## The backend-native evidence was read and verified by a reader
      ## for that format. The only authoritative field there is.
    vcReportDataBinding = "report-data-binding"
      ## The 64 bytes *inside* the evidence are the ones the envelope's
      ## own challenge and bindings produce. This is the check the report
      ## parser cannot make and the one a lying backend fails.
    vcChallengeMatch = "challenge-match"
      ## The report answers the challenge this verifier issued.
    vcChallengeFreshness = "challenge-freshness"
      ## That challenge is younger than the policy's window.
    vcManifestPinned = "manifest-pinned"
      ## The measurement manifest this verdict compared against is one
      ## the policy pins by digest.
    vcMeasurementMatch = "measurement-match"
      ## The launch measurement in the evidence is one the manifest says
      ## that image produces.
    vcCertificateChain = "certificate-chain"
      ## The bundled chain is what it claims to be.
    vcTcbFloor = "tcb-floor"
      ## The vendor's trusted computing base is at or above the policy's
      ## floor.

  FindingKind* = enum
    ## What a check found. ``fkViolated`` is the zero value, so a finding
    ## nobody filled in is a violation.
    fkViolated = "violated"
    fkSatisfied = "satisfied"
    fkInapplicable = "inapplicable"
      ## The check could not be performed — the datum it compares was not
      ## present. Whether that is a skip or a failure is not this
      ## finding's to say; see ``outcome``.

  CheckOutcome* = enum
    ## What a check's finding *means* once the policy has been consulted.
    ## ``coNotReached`` is the zero value: a record nobody wrote.
    coNotReached = "not-reached"
    coPassed = "passed"
    coFailed = "failed"
    coSkipped = "skipped"

  CheckFinding* = object
    kind*: FindingKind
    detail*: string
      ## What was compared against what, in one line. Mandatory: a
      ## finding with no detail is refused by ``record``, because a
      ## verdict whose explanation is empty explains nothing.

  CheckRecord* = object
    performed*: bool
    kind*: FindingKind
    required*: bool
      ## Whether the policy requires this check to have been performed.
      ## It is what turns "could not be performed" into a failure.
    detail*: string

  VerdictDecision* = enum
    ## ``vdRejected`` is the zero value. A verdict nobody finished is a
    ## rejection.
    vdRejected = "rejected"
    vdAcceptedNoRootOfTrust = "accepted-without-a-root-of-trust"
      ## Every check the policy required was satisfied — and the tier
      ## that produced the evidence has no root of trust, so what has
      ## been established is that the documents are well formed and
      ## consistent with each other, and nothing about a machine.
    vdAccepted = "accepted"

  EstablishedIdentity* = object
    ## What §5.3 lets a verifier conclude about *which configuration*
    ## answered, taken from the measurement manifest that matched — never
    ## from the report's own claims.
    configFingerprint*: string
    verityRootHash*: string
    manifestDigest*: string

  Verdict* = object
    decision*: VerdictDecision
    checks*: array[VerifierCheck, CheckRecord]
    caveats*: seq[string]
      ## What an accepted verdict does *not* establish. Read by whoever
      ## is about to act on it.
    claimNotes*: seq[string]
      ## The instance's unverified claims, and whether they agree with
      ## the manifest. Advisory: nothing in this module derives a
      ## decision from them, and ``decisionFor`` cannot see them.
    identity*: EstablishedIdentity
    hasIdentity*: bool
    reportSource*: string
    policySource*: string

  VerdictError* = object of CatchableError

const
  AttestationVerdictSchema* = "reproos.attestation-verdict.v1"

  MockCaveat* =
    "the mock tier has no root of trust: this verdict establishes that " &
    "the documents are well formed and agree with each other, and " &
    "nothing about the machine that sent them"

  UnpinnedManifestCaveat* =
    "this policy pins no measurement manifest, so the manifest this " &
    "verdict compared against was authenticated by nothing but the fact " &
    "that it was supplied to the verifier"

# ---------------------------------------------------------------------
# The one rule that turns a finding into an outcome
# ---------------------------------------------------------------------

proc outcome*(rec: CheckRecord): CheckOutcome =
  ## The single place a finding becomes an outcome.
  ##
  ## Written as a derivation rather than stored as a field so there is
  ## no assignment anywhere that could spell a skip as a pass. Note the
  ## ``fkInapplicable`` arm: a check the policy requires and that could
  ## not be performed is a **failure**. "I could not check this" is never
  ## a reason to accept.
  if not rec.performed: return coNotReached
  case rec.kind
  of fkSatisfied: coPassed
  of fkViolated: coFailed
  of fkInapplicable: (if rec.required: coFailed else: coSkipped)

proc decisionFor*(checks: array[VerifierCheck, CheckRecord];
                  tier: AttestationTier): VerdictDecision =
  ## The decision, derived from the outcome of every check and from the
  ## tier — and from nothing else. In particular it never sees the
  ## report's claims, which is why it takes an array rather than a
  ## verdict.
  for chk in VerifierCheck:
    if checks[chk].outcome notin {coPassed, coSkipped}:
      return vdRejected
  if tier == atMock: vdAcceptedNoRootOfTrust else: vdAccepted

# ---------------------------------------------------------------------
# Building one
# ---------------------------------------------------------------------

proc satisfied*(detail: string): CheckFinding =
  CheckFinding(kind: fkSatisfied, detail: detail)

proc violated*(detail: string): CheckFinding =
  CheckFinding(kind: fkViolated, detail: detail)

proc inapplicable*(detail: string): CheckFinding =
  ## The datum this check compares was not present. Say *why* — the
  ## detail is what a reader of a skipped check has instead of a result.
  CheckFinding(kind: fkInapplicable, detail: detail)

proc record*(v: var Verdict; chk: VerifierCheck; required: bool;
             f: CheckFinding) =
  ## Write one check's finding. Called exactly once per check by the
  ## driver's loop over ``VerifierCheck``.
  if f.detail.len == 0:
    raise newException(VerdictError,
      "the check " & $chk & " produced no explanation; a verdict whose " &
      "checks cannot say what they compared is not a machine-readable " &
      "explanation of anything")
  if v.checks[chk].performed:
    raise newException(VerdictError,
      "the check " & $chk & " was recorded twice; the second answer " &
      "would silently replace the first")
  v.checks[chk] = CheckRecord(performed: true, kind: f.kind,
                              required: required, detail: f.detail)

proc seal*(v: var Verdict; tier: AttestationTier) =
  ## Compute the decision. Separate from ``record`` so the decision is a
  ## function of the completed array rather than something accumulated as
  ## the checks run — an accumulator would let an early check decide the
  ## outcome and the later ones become decoration.
  v.decision = decisionFor(v.checks, tier)

# ---------------------------------------------------------------------
# Reading one
# ---------------------------------------------------------------------

proc checksWith*(v: Verdict; want: CheckOutcome): seq[VerifierCheck] =
  for chk in VerifierCheck:
    if v.checks[chk].outcome == want: result.add chk

proc skippedChecks*(v: Verdict): seq[VerifierCheck] = v.checksWith(coSkipped)
proc failedChecks*(v: Verdict): seq[VerifierCheck] = v.checksWith(coFailed)

proc isAcceptance*(d: VerdictDecision): bool =
  ## True for both acceptances. Spelled out here so a caller that means
  ## "not rejected" writes something that says so, rather than a
  ## comparison against one of the two acceptances that quietly rejects
  ## the other.
  d != vdRejected

# ---------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------

proc renderVerdictText*(v: Verdict): string =
  ## The operator's view. Every check is listed, in enum order, with its
  ## outcome and its explanation — including the skipped ones, which is
  ## the whole reason this renderer iterates the enum instead of a
  ## sequence somebody appended to.
  result = "verdict: " & $v.decision & "\n"
  if v.reportSource.len > 0:
    result.add "  report: " & v.reportSource & "\n"
  if v.policySource.len > 0:
    result.add "  policy: " & v.policySource & "\n"
  result.add "checks:\n"
  var widest = 0
  for chk in VerifierCheck:
    widest = max(widest, ($chk).len)
  for chk in VerifierCheck:
    let rec = v.checks[chk]
    result.add "  " & alignLeft($chk, widest) & "  " &
      alignLeft($rec.outcome, 11) & "  " & rec.detail & "\n"
  if v.hasIdentity:
    result.add "establishes:\n"
    result.add "  configFingerprint: " & v.identity.configFingerprint & "\n"
    result.add "  verityRootHash:    " & v.identity.verityRootHash & "\n"
    result.add "  manifest:          " & v.identity.manifestDigest & "\n"
  if v.caveats.len > 0:
    result.add "caveats:\n"
    for c in v.caveats: result.add "  - " & c & "\n"
  if v.claimNotes.len > 0:
    result.add "unverified claims (no part of this verdict rests on them):\n"
    for c in v.claimNotes: result.add "  - " & c & "\n"

proc renderVerdictJson*(v: Verdict): string =
  ## The machine-readable half of §7.1. Hand-rendered in a fixed key
  ## order, like every other document in this chain, so two verifiers
  ## agreeing produce the same bytes.
  proc q(s: string): string =
    result = "\""
    for c in s:
      case c
      of '"': result.add "\\\""
      of '\\': result.add "\\\\"
      of '\n': result.add "\\n"
      of '\t': result.add "\\t"
      of '\r': result.add "\\r"
      else:
        if c < ' ': result.add "\\u00" & toHex(ord(c), 2).toLowerAscii
        else: result.add c
    result.add "\""
  result = "{\n"
  result.add "  \"schema\": " & q(AttestationVerdictSchema) & ",\n"
  result.add "  \"decision\": " & q($v.decision) & ",\n"
  result.add "  \"checks\": [\n"
  for chk in VerifierCheck:
    let rec = v.checks[chk]
    result.add "    {\n"
    result.add "      \"check\": " & q($chk) & ",\n"
    result.add "      \"outcome\": " & q($rec.outcome) & ",\n"
    result.add "      \"required\": " & (if rec.required: "true" else: "false") &
      ",\n"
    result.add "      \"detail\": " & q(rec.detail) & "\n"
    result.add "    }" & (if chk == high(VerifierCheck): "\n" else: ",\n")
  result.add "  ],\n"
  if v.hasIdentity:
    result.add "  \"establishes\": {\n"
    result.add "    \"configFingerprint\": " &
      q(v.identity.configFingerprint) & ",\n"
    result.add "    \"verityRootHash\": " & q(v.identity.verityRootHash) & ",\n"
    result.add "    \"manifest\": " & q(v.identity.manifestDigest) & "\n"
    result.add "  },\n"
  result.add "  \"caveats\": ["
  for i, c in v.caveats:
    result.add (if i == 0: "\n" else: ",\n") & "    " & q(c)
  result.add (if v.caveats.len > 0: "\n  ],\n" else: "],\n")
  result.add "  \"unverifiedClaimNotes\": ["
  for i, c in v.claimNotes:
    result.add (if i == 0: "\n" else: ",\n") & "    " & q(c)
  result.add (if v.claimNotes.len > 0: "\n  ]\n" else: "]\n")
  result.add "}\n"

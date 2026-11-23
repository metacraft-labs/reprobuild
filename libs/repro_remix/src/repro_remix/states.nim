## User-visible Remix states, shared by desktop and web
## (`reprobuild-pm/spec/Remix-Experience-Journeys.md` §"Visible states",
## §"Coverage rule").
##
## Surfaces never invent their own reading of protocol data: they call
## `deriveStates` and render the result with `explanation`. The mappings
## from protocol vocabularies (`stateForRefusal`, `stateForStatement`,
## `decisionForConflict`) are exhaustive `case` statements, so adding a
## refusal code, statement kind or conflict class without deciding how a
## user sees it fails to compile — the mechanical half of the coverage rule.

import std/algorithm

import ./types
import ./statements
import ./composition

type
  VisibleState* = enum
    ## Closed vocabulary; order is display priority (most severe first).
    vsBlocked = "blocked"
    vsRevoked = "revoked"
    vsUnverifiable = "unverifiable"
    vsIncompatible = "incompatible"
    vsIncompleteLineage = "incomplete-lineage"
    vsStalePolicy = "stale-policy"
    vsEvidenceUnavailable = "evidence-unavailable"
    vsYanked = "yanked"
    vsWarning = "warning"
    vsEmbargoedClaim = "embargoed-claim"
    vsUnknown = "unknown"
    vsLowConfidence = "low-confidence"
    vsReviewed = "reviewed"
    vsCertifiedReview = "certified-review"
    vsSuperseded = "superseded"

  StateAxis* = enum
    axConfidence, axSafety, axAuthorship, axLifecycle, axCompatibility,
    axLineage, axPolicy, axAny

  Gate* = enum
    ## What a state does to the install affordance.
    gAllow = "allow"
    gAllowWithWarning = "allow with warning"
    gAllowWithAcknowledgement = "allow with explicit acknowledgement"
    gRefuseNoAffordance = "refuse, no affordance"
    gRefuseNewInstalls = "refuse new installs"
    gRefuseHere = "refuse here"
    gRefusePlanning = "refuse planning"
    gRefuseUntilRefreshed = "refuse until refreshed"
    gRefuseIfGating = "refuse if install-gating"
    gPerVerdict = "per verdict"

  JourneyDecision* = enum
    ## §"Decision data" D1–D18.
    dPlanApproval = "D1"
    dCapabilityGrant = "D2"
    dConflictAcknowledgement = "D3"
    dSupersededRelease = "D4"
    dRollbackPoint = "D5"
    dOneWayMigration = "D6"
    dVisibility = "D7"
    dEvidenceReview = "D8"
    dSecretScan = "D9"
    dResolutionApproval = "D10"
    dReviewScope = "D11"
    dEmbargo = "D12"
    dPanelCommit = "D13"
    dPanelReveal = "D14"
    dModerationAction = "D15"
    dDualControl = "D16"
    dPolicyChange = "D17"
    dPolicySimulation = "D18"

  StateInfo* = object
    axis*: StateAxis
    gate*: Gate
    explanation*: string

  ReleaseView* = object
    ## Everything a surface knows about one release when it renders it.
    ## Every field is protocol data or a gate result; none is a score the
    ## surface computed.
    refusal*: RemixRefusal
    refused*: bool
      ## The install gate refused, with `refusal`.
    statements*: seq[Statement]
      ## Statements about this release (quorum and signatures verified by
      ## the caller).
    incompatibleAxis*: string
      ## Non-empty when compatibility failed, naming the axis.
    superseded*: bool
    missingEvidence*: seq[string]
      ## Items the surface could not retrieve.
    missingEvidenceGates*: bool
      ## Whether any missing item is install-gating.

proc info*(s: VisibleState): StateInfo =
  ## The verbatim strings of §"Visible states".
  case s
  of vsUnknown: StateInfo(axis: axConfidence, gate: gAllowWithWarning,
    explanation: "Not enough evidence yet to judge this release.")
  of vsLowConfidence: StateInfo(axis: axConfidence, gate: gAllowWithWarning,
    explanation: "Some evidence, from few independent sources.")
  of vsReviewed: StateInfo(axis: axConfidence, gate: gAllow,
    explanation: "Reviewed within the stated scope by credible reviewers.")
  of vsCertifiedReview: StateInfo(axis: axConfidence, gate: gAllow,
    explanation: "Includes an attested automated review within its stated scope.")
  of vsWarning: StateInfo(axis: axSafety, gate: gAllowWithAcknowledgement,
    explanation: "Open concerns exist; read them before installing.")
  of vsBlocked: StateInfo(axis: axSafety, gate: gRefuseNoAffordance,
    explanation: "A safety verdict blocks this release.")
  of vsRevoked: StateInfo(axis: axAuthorship, gate: gRefuseNoAffordance,
    explanation: "The author's key or this release was revoked.")
  of vsUnverifiable: StateInfo(axis: axAuthorship, gate: gRefuseNoAffordance,
    explanation: "This release failed verification and cannot be trusted.")
  of vsYanked: StateInfo(axis: axLifecycle, gate: gRefuseNewInstalls,
    explanation: "The author withdrew this release.")
  of vsSuperseded: StateInfo(axis: axLifecycle, gate: gAllow,
    explanation: "A newer release exists.")
  of vsIncompatible: StateInfo(axis: axCompatibility, gate: gRefuseHere,
    explanation: "Does not apply to this system.")
  of vsIncompleteLineage: StateInfo(axis: axLineage, gate: gRefusePlanning,
    explanation: "An ancestor of this release is unavailable.")
  of vsStalePolicy: StateInfo(axis: axPolicy, gate: gRefuseUntilRefreshed,
    explanation: "Safety policy is out of date; refresh before installing.")
  of vsEvidenceUnavailable: StateInfo(axis: axAny, gate: gRefuseIfGating,
    explanation: "This information could not be retrieved.")
  of vsEmbargoedClaim: StateInfo(axis: axSafety, gate: gPerVerdict,
    explanation: "A protected report is under review.")

proc explanation*(s: VisibleState): string = info(s).explanation

proc isInstallable*(states: openArray[VisibleState]): bool =
  ## The single answer surfaces use to decide whether to show an install
  ## affordance at all.
  for s in states:
    if info(s).gate in {gRefuseNoAffordance, gRefuseNewInstalls, gRefuseHere,
                        gRefusePlanning, gRefuseUntilRefreshed}:
      return false
  true

proc stateForRefusal*(r: RemixRefusal): VisibleState =
  ## How a gate refusal reaches the user. Exhaustive.
  case r
  of rrBlockedByPolicy: vsBlocked
  of rrRevokedKey: vsRevoked
  of rrIncompleteLineage, rrLineageCycle, rrLineageTooDeep: vsIncompleteLineage
  # Everything that means "these bytes are not what they claim": a bad or
  # missing signature, an inactive key, tampering, or a malformed or
  # non-canonical record. Refused with no affordance, and not described
  # as a revocation or a verdict, because it is neither.
  # A release whose publication or blobs cannot be proven is in the same
  # place: the gate refused it, so it must never look installable.
  # `evidence-unavailable` is reserved for display items that do not gate.
  of rrNotLogged, rrMissingBlob,
     rrInactiveKey, rrMissingAuthorSignature, rrBadSignature, rrKeyMismatch,
     rrForbiddenContent, rrDigestMismatch, rrSizeMismatch,
     rrTruncated, rrBadMagic, rrUnknownEnvelopeVersion, rrUnknownTypeId,
     rrLengthMismatch, rrOversize, rrMalformed, rrUnknownSchemaVersion,
     rrUnknownRequiredFeature, rrUnknownRecordKind, rrNonCanonical,
     rrDuplicate, rrUnsorted, rrBound, rrInvalidText, rrUnknownVocabulary,
     rrUnknownCriticalExtension, rrDanglingReference, rrUnknownAlgorithm:
    vsUnverifiable

proc stateForStatement*(st: Statement): (bool, VisibleState) =
  ## The state a statement contributes, if any. Exhaustive over kinds.
  case st.kind
  of skVerdict, skRevocation:
    if "block" in st.scope: (true, vsBlocked)
    elif "warn" in st.scope: (true, vsWarning)
    else: (false, vsUnknown)
  of skYank: (true, vsYanked)
  of skKeyRevocation: (true, vsRevoked)
  of skReview, skVouch: (true, vsReviewed)
  of skAttestedInference: (true, vsCertifiedReview)
  of skVulnerabilityClaim:
    if "embargoed" in st.scope: (true, vsEmbargoedClaim) else: (true, vsWarning)
  of skModeration:
    if "block" in st.scope: (true, vsBlocked) else: (false, vsUnknown)
  of skPublication, skBuildEvidence, skTestEvidence, skKeyRotation,
     skLogCheckpoint:
    (false, vsUnknown)

proc decisionForConflict*(c: ConflictClass): JourneyDecision =
  ## Where a composition conflict is shown. Unresolvable classes still
  ## appear at D3 — as a refusal, never as a choice.
  case c
  of ccSource, ccPatch, ccSymbol, ccPackageVersion, ccConfiguration,
     ccFileOwnership, ccService, ccPort, ccDataMigration, ccLineage:
    dConflictAcknowledgement
  of ccPermission: dCapabilityGrant
  of ccLicense, ccBlocked: dConflictAcknowledgement

proc deriveStates*(v: ReleaseView): seq[VisibleState] =
  ## All states that apply, most severe first, without duplicates.
  if v.refused:
    result.add stateForRefusal(v.refusal)
  var reviews = 0
  for st in v.statements:
    let (has, s) = stateForStatement(st)
    if has:
      if s == vsReviewed: inc reviews
      if s notin result: result.add s
  if v.incompatibleAxis.len > 0 and vsIncompatible notin result:
    result.add vsIncompatible
  if v.missingEvidence.len > 0 and vsEvidenceUnavailable notin result:
    result.add vsEvidenceUnavailable
  if v.superseded: result.add vsSuperseded
  # Confidence: no review is `unknown`, one independent review is still
  # `low-confidence`; `reviewed` needs two (Trust And Reputation will
  # replace this rule with its credibility model).
  if vsCertifiedReview notin result:
    if reviews == 0: result.add vsUnknown
    elif reviews == 1:
      result.add vsLowConfidence
      result.delete(result.find(vsReviewed))
  result.sort(proc (a, b: VisibleState): int = cmp(ord(a), ord(b)))

proc decisionForRecordKind*(k: RecordKind): JourneyDecision =
  ## Where each record kind meets the user. Exhaustive.
  case k
  of rkManifest, rkInstallLock, rkBundleIndex: dPlanApproval
  of rkComposition: dResolutionApproval
  of rkStatement: dEvidenceReview
  of rkKeyLogEntry: dEvidenceReview

proc fixtureViews*(): seq[(string, ReleaseView)] =
  ## A named view for every situation the journeys spec names. Statements
  ## are round-tripped through the real codec, so a fixture cannot carry a
  ## statement the protocol would refuse. Used by the coverage check and as
  ## the seed of the UI fixture dataset.
  proc st(kind: StatementKind; scope: seq[string] = @[]): Statement =
    let s = Statement(kind: kind, subjectKind: sbRelease, scope: scope)
    decodeStatement(encodeStatement(s))
  result = @[
    ("new release, no evidence", ReleaseView()),
    ("one review", ReleaseView(statements: @[st(skReview)])),
    ("two reviews", ReleaseView(statements: @[st(skReview), st(skVouch)])),
    ("attested review", ReleaseView(statements: @[st(skAttestedInference)])),
    ("open concern", ReleaseView(statements: @[st(skVerdict, @["warn"])])),
    ("blocked by verdict", ReleaseView(refused: true, refusal: rrBlockedByPolicy,
      statements: @[st(skVerdict, @["block"])])),
    ("author key revoked", ReleaseView(refused: true, refusal: rrRevokedKey)),
    ("forged signature", ReleaseView(refused: true, refusal: rrBadSignature)),
    ("withdrawn by author", ReleaseView(statements: @[st(skYank)])),
    ("newer release exists", ReleaseView(superseded: true)),
    ("wrong platform", ReleaseView(incompatibleAxis: "platform")),
    ("ancestor missing", ReleaseView(refused: true, refusal: rrIncompleteLineage)),
    ("evidence unreachable", ReleaseView(missingEvidence: @["build report"],
      missingEvidenceGates: false)),
    ("embargoed claim", ReleaseView(statements: @[st(skVulnerabilityClaim, @["embargoed"])])),
  ]

proc withStalePolicy*(states: seq[VisibleState]): seq[VisibleState] =
  ## Stale policy is a gate outcome (`PlanResult.stalePolicy`), not a
  ## refusal code, so surfaces add it explicitly.
  result = states
  if vsStalePolicy notin result: result.add vsStalePolicy
  result.sort(proc (a, b: VisibleState): int = cmp(ord(a), ord(b)))

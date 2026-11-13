## The provisioning LOCK WRITER — M7 deliverable 2 of
## ``ReproOS-Campaign-Completion.milestones.org``: turn one composed
## selection (M6, ``catalog_composition``) plus the full identity of the
## contribution it selected (M7 D1, ``contribution_fingerprint``) into a
## sealed ``LockedRealization`` for the committed lock
## (``repro_lock/provisioning``; the record format, canonical encoding,
## strict reader and staleness check all live there).
##
## ## What it refuses
##
##   * a ``developInterface`` contribution -- forbidden in a committed lock
##     by Provisioning-Contributions.md § Interface Artifacts;
##   * a contribution whose fingerprint REFUSES;
##   * a contribution whose fingerprint is not ``dependenciesFullyResolved``.
##     This is the gate M7 deliverable 1 left for this deliverable, and it is
##     deliberately NOT ``isResolved``: a dependency the resolver did not bind
##     folds in as its coordinate-only LEAF, so the fingerprint is a
##     perfectly well-formed hex that does not move with that dependency's
##     realization metadata. Two catalogs differing only there would lock to
##     the same bytes. Such a fingerprint is never serialised;
##   * a contribution identity that is not the one the selection selected
##     (its artifact-readable record digest differs from the selection's);
##   * a realization lock identity the contribution does not declare, or
##     declares more than once;
##   * every malformed field ``repro_lock/provisioning`` refuses --
##     including a catalog revision that is not a full-width object id,
##     which M6 composition does NOT check and this writer does.
##
## Refusals are collected rather than short-circuited, so one call names
## every cause.
##
## ## What it does NOT do
##
## It does not select anything: the selection comes from
## ``composeCatalogs`` (unique eligible contribution, or the curator policy)
## by way of ``contribution_selection.resolveProvisioningSelections``, which
## is also where a committed lock is READ and checked (M7 deliverable 3).
## A selection the lock itself made (``csLock``) is refused here: its
## verified record is carried forward as it is, never re-derived.
## It does not filter a realization by platform or ABI (spec § Resolution
## step 4 is not implemented anywhere yet); ``hostPlatform`` /
## ``targetPlatform`` / ``capabilities`` are recorded as the caller states
## them.

import std/[options, sequtils, strutils]

import repro_lock/provisioning

import ../repro_interface_artifacts
import ./contribution_fingerprint
import ./catalog_composition

export provisioning

type
  RealizationLockRequest* = object
    ## What to lock: the selection composition made, the FULL identity of
    ## the contribution it selected, which of that contribution's
    ## realizations, and the platform pair and capability set it is locked
    ## for.
    selection*: CatalogSelection
    identity*: ContributionIdentity
    realizationLockIdentity*: string
    hostPlatform*: string
    targetPlatform*: string
    capabilities*: seq[string]

  RealizationLockOutcome* = object
    ## ``record`` is sealed and serialisable exactly when ``refusals`` is
    ## empty.
    record*: LockedRealization
    fingerprint*: ContributionFingerprint
    refusals*: seq[string]

proc locked*(outcome: RealizationLockOutcome): bool =
  outcome.refusals.len == 0

type DeclaredRealization* = object
  kind*: LockedRealizationKind
  integrity*: string

proc canonicalIntegrity(value: string): string =
  ## A 64-hex digest is case-insensitive, so the record spells it in lower
  ## case; an SRI digest's base64 body is case-SENSITIVE and is kept byte
  ## for byte. Anything else is passed through, for the record's own
  ## validation to refuse.
  if value.len == 64 and value.allIt(it in HexDigits):
    value.toLowerAscii()
  else:
    value

proc declaredRealizations*(identity: ContributionIdentity;
                           lockIdentity: string): seq[DeclaredRealization] =
  ## Every realization of the contribution whose declared lock identity is
  ## ``lockIdentity``, with the integrity evidence its family carries.
  let c = identity.contribution
  for p in c.nixProvisioning:
    if p.lockIdentity == lockIdentity:
      result.add(DeclaredRealization(kind: lrkNix,
        integrity: canonicalIntegrity(p.nixpkgsNarHash)))
  for p in c.tarballProvisioning:
    if p.lockIdentity == lockIdentity:
      result.add(DeclaredRealization(kind: lrkTarball,
        integrity: canonicalIntegrity(p.sha256)))
  for p in c.scoopProvisioning:
    if p.lockIdentity == lockIdentity:
      result.add(DeclaredRealization(kind: lrkScoop,
        integrity: canonicalIntegrity(p.manifestChecksum)))
  for p in identity.fromSourceProvisioning:
    if p.lockIdentity == lockIdentity:
      result.add(DeclaredRealization(kind: lrkFromSource,
        integrity: canonicalIntegrity(p.recipeDigest)))

proc lockSelectedRealization*(request: RealizationLockRequest;
                              resolver: ContributionResolver):
    RealizationLockOutcome =
  ## THE lock writer. Computes the contribution fingerprint itself -- so
  ## the fingerprint that is locked is, by construction, the fingerprint of
  ## the identity that was checked -- and returns a sealed record, or the
  ## complete list of reasons it refuses. Never raises.
  let c = request.identity.contribution
  var refusals: seq[string] = @[]

  if c.developInterface:
    refusals.add("develop-interface: contribution \"" & c.contributor &
      "\" binds developInterface, which is forbidden in a committed lock")

  if request.selection.reason == csLock:
    refusals.add("selection-already-locked: the selection of package \"" &
      c.targetPackage & "\" was made BY the committed lock; carry its " &
      "verified record forward (ResolvedProvisioningSelection.lockedRecord) " &
      "rather than re-locking it, which would lose why it was selected")

  let fp = contributionFingerprint(request.identity, resolver)
  result.fingerprint = fp
  if not fp.isResolved:
    refusals.add("contribution-fingerprint-refused: " & fp.refusalReason)
  elif not fp.dependenciesFullyResolved:
    refusals.add("dependencies-not-fully-resolved: the contribution " &
      "fingerprint binds these dependencies by coordinate only, so it does " &
      "not move with their realization metadata: " &
      fp.unresolvedDependencies.mapIt(contributionCoordinate(it)).join(", "))

  if request.selection.contributionRecordDigest !=
      interfaceContributionRecordDigest(c):
    refusals.add("selection-mismatch: the contribution identity is not the " &
      "one the selection selected (record digest " &
      interfaceContributionRecordDigest(c) & ", selected " &
      request.selection.contributionRecordDigest & ")")

  let declared = declaredRealizations(request.identity,
    request.realizationLockIdentity)
  var realization = DeclaredRealization()
  if declared.len == 0:
    refusals.add("realization-not-declared: contribution \"" &
      c.contributor & "\" declares no realization with lock identity \"" &
      request.realizationLockIdentity & "\"")
  elif declared.len > 1:
    refusals.add("realization-ambiguous: contribution \"" & c.contributor &
      "\" declares " & $declared.len & " realizations with lock identity \"" &
      request.realizationLockIdentity & "\"")
  else:
    realization = declared[0]

  let coordinate = request.selection.catalogCoordinate
  let draft = LockedRealization(
    packageName: c.targetPackage,
    interfaceFingerprint: normalizedFingerprint(c.targetInterfaceFingerprint),
    contributor: c.contributor,
    contributionFingerprint: fp.hex,
    catalogWorkspace: coordinate.workspace,
    catalogRemote: coordinate.remote,
    catalogRevision: coordinate.revision.toLowerAscii(),
    catalogInterfaceArtifact:
      normalizedFingerprint(coordinate.interfaceArtifact),
    realizationKind: realization.kind,
    realizationLockIdentity: request.realizationLockIdentity,
    realizationIntegrity: realization.integrity,
    hostPlatform: request.hostPlatform,
    targetPlatform: request.targetPlatform,
    capabilities: request.capabilities,
    selectedBy:
      case request.selection.reason
      of csUniqueEligible: lsrUniqueEligible
      of csCuratorPolicy, csLock: lsrCuratorPolicy)
  let evidence = ContributionEvidence(
    fingerprintHex: fp.hex,
    refusals: fp.refusals,
    unresolvedDependencies:
      fp.unresolvedDependencies.mapIt(contributionCoordinate(it)))
  # The seal's own refusals: its evidence gate (which restates the two
  # fingerprint refusals above in its own words -- it is the gate that also
  # holds for a caller that seals directly) and every field.
  refusals.add(lockedRealizationRefusals(draft, evidence))

  result.refusals = refusals
  if refusals.len == 0:
    result.record = sealLockedRealization(draft, evidence)
  else:
    result.record = draft

proc currentContributionFingerprint*(identity: ContributionIdentity;
                                     resolver: ContributionResolver):
    Option[string] =
  ## The contribution fingerprint a locked record is checked AGAINST, under
  ## the same gate the writer applies: ``none`` unless it is fully resolved.
  ## A record can then only ever be matched by a fully bound fingerprint.
  let fp = contributionFingerprint(identity, resolver)
  if fp.dependenciesFullyResolved: some(fp.hex) else: none(string)

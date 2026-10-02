## The provisioning RESOLVER -- M7 deliverable 3 of
## ``ReproOS-Campaign-Completion.milestones.org``: select each package's
## provisioning contribution from the committed lock or an explicit curator
## policy, and fail closed when the lock no longer describes what the
## composed catalogs offer (the fail-closed half of deliverable 4).
##
## Normatively: ``reprobuild-specs/Provisioning-Contributions.md``
## § Resolution and § Locks And Snapshots.
##
## ## Precedence
##
## For every package the composed catalogs offer eligible contributions for:
##
##   1. a ``provisioning`` record of the COMMITTED LOCK for this
##      (package, host platform, target platform) pins the selection;
##   2. otherwise an explicit CURATOR POLICY rule selects;
##   3. otherwise a UNIQUE eligible contribution is selected;
##   4. anything else refuses as ambiguous, naming every candidate and its
##      source location (``composeCatalogs``).
##
## Import order is never a selection rule; neither is the order of lock
## records or policy rules (``composeCatalogs`` refuses contradictory
## ones). A policy/unique selection is NOT a lock entry: it reaches the lock
## only when the caller writes it with ``contribution_lock
## .lockSelectedRealization``, which records ``selected_by`` -- that is how
## "curator snapshots ... serialize the resulting selection into the lock".
##
## ## What a lock record must still match, or the resolution refuses
##
## A lock pin is never relaxed to policy or to the unique eligible
## contribution, and is never re-pinned to whatever the catalogs offer now.
## The record is checked against the composed catalogs and the full
## identity of the contribution they offer, and resolution REFUSES,
## naming both sides, when:
##
##   * its contributor offers no eligible contribution
##     (``locked-contribution-unavailable``, from ``composeCatalogs``);
##   * the package's canonical interface moved (``interface-changed``:
##     incompatible; never silently re-selected, even when the contributor
##     republished against the new interface);
##   * the offered contribution's fingerprint is not the locked one
##     (``contribution-changed``: realization metadata, integrity, provider
##     identity or a dependency moved; the interface did not, so typechecking
##     stays valid, but the locked realization is refused);
##   * the offering catalog's coordinate -- workspace, remote, revision or
##     interface-artifact identity -- is not the locked one
##     (``catalog-changed``). This refuses a moved branch tip of the SELECTED
##     contributor's catalog even when the contribution's content is
##     unchanged: the lock pins a revision, and a false refusal is safe;
##   * the locked realization lock identity is not declared exactly once,
##     with the locked kind and integrity (``realization-changed``);
##   * a curator policy rule names a DIFFERENT contributor for a locked
##     package (``policy-contradicts-lock``): the committed lock and the
##     curator disagree, and silently following either one hides that.
##
## The staleness comparison of interface and contribution is
## ``repro_lock/provisioning.requireCurrentRealization`` -- the same gate
## ``lockedRealizationFor`` applies -- so there is one definition of
## "current".
##
## Every selected contribution, however selected, must be backed by a
## ``ContributionIdentity`` the caller offers for exactly that record, whose
## fingerprint is ``dependenciesFullyResolved`` (the writer's gate): a
## selection the resolver cannot fingerprint is refused, not passed on.
##
## Resolution is all-or-nothing, like composition: any refusal leaves
## ``selections`` empty.
##
## ## What it hands the engine
##
## ``pinOf`` turns a selection into a ``ProvisioningPin`` carrying the
## contribution fingerprint and, for a lock selection, the locked
## realization's lock identity; ``provisioning_pins.applyProvisioningPins``
## checks it against the consumer's artifact, the planners in
## ``repro_tool_profiles`` provision exactly that realization, and fold the
## fingerprint into the realization/build keys (deliverable 4).
##
## TRUST BOUNDARY: the engine cannot recompute the fingerprint or re-check
## the lock, so a pin is trusted input. It must come from ``pinOf`` over a
## resolution made in the same process. The CLI build path's caller,
## ``repro_cli_support/provisioning_lock_selection``, does exactly that on
## every build (and binds the pins into its tool-identity cache key only as
## a digest); nothing persists a pin, and anything that ever does must add
## verification the engine can check (see ``ProvisioningPin``).
##
## ## What it does NOT do
##
##   * Platform, ABI and capability FILTERING (spec § Resolution step 4):
##     records are matched on the platform pair the caller states; nothing
##     refuses a realization declared for another cpu/os.
##   * Model the canonical package's in-package realizations as a
##     contribution: they are not a ``CatalogContent`` entry, so the lock
##     cannot pin them.
##   * Explain WHY a lock record no longer matches, or re-select: that is
##     deliverable 5, ``provisioning_lock_diff`` (``explainLockMismatch``,
##     which the CLI appends to this resolver's refusal, and
##     ``reselectProvisioning``, which runs THIS resolver without the lock's
##     claims for ``repro lock refresh --provisioning``).

import std/[algorithm, options, sequtils, strutils]

import repro_lock/provisioning

import ../repro_interface_artifacts
import ./catalog_composition
import ./contribution_fingerprint
import ./contribution_lock

export provisioning

type
  ProvisioningSelectionSource* = enum
    pssUniqueEligible = "unique-eligible"
    pssCuratorPolicy = "curator-policy"
    pssLock = "lock"

  ProvisioningResolutionRequest* = object
    imports*: seq[CatalogImport]
      ## The explicitly identified catalogs, as for ``composeCatalogs``.
    lockClaims*: seq[LockedRealization]
      ## The committed lock's ``provisioning`` records
      ## (``repro_lock.lockedProvisioningClaims``), all platform pairs.
    policy*: CatalogSelectionPolicy
      ## The explicit curator policy (may be empty).
    offered*: seq[ContributionIdentity]
      ## The FULL identities of the contributions the catalogs offer --
      ## at least one for every contribution that may be selected.
    hostPlatform*: string
    targetPlatform*: string

  ResolvedProvisioningSelection* = object
    selection*: CatalogSelection
    identity*: ContributionIdentity
    contributionFingerprint*: string
      ## The CURRENT fully-bound contribution fingerprint of ``identity``;
      ## for a lock selection, equal to the locked one (checked).
    source*: ProvisioningSelectionSource
    lockedRecord*: Option[LockedRealization]
      ## The verified record, for a lock selection (carry it forward as is);
      ## ``none`` for a policy / unique selection, which the caller locks
      ## with ``lockSelectedRealization``.

  ProvisioningResolution* = object
    selections*: seq[ResolvedProvisioningSelection]
      ## In package order (``composeCatalogs``' order); empty whenever
      ## ``refusals`` is not.
    refusals*: seq[string]
      ## Sorted, de-duplicated.

proc resolved*(resolution: ProvisioningResolution): bool =
  resolution.refusals.len == 0

proc selectionFor*(resolution: ProvisioningResolution;
                   packageName: string): ResolvedProvisioningSelection =
  for s in resolution.selections:
    if s.selection.targetPackage == packageName:
      return s
  raise newException(KeyError, "no provisioning selection for package \"" &
    packageName & "\"" &
    (if resolution.refusals.len > 0:
       ": " & resolution.refusals.join(" | ") else: ""))

proc pinOf*(s: ResolvedProvisioningSelection): ProvisioningPin =
  ## The engine-side pin for a selection (see ``provisioning_pins``).
  ProvisioningPin(
    packageName: s.selection.targetPackage,
    contributor: s.selection.contributor,
    contributionFingerprint: s.contributionFingerprint,
    contributionRecordDigest: s.selection.contributionRecordDigest,
    realizationLockIdentity:
      if s.lockedRecord.isSome: s.lockedRecord.get.realizationLockIdentity
      else: "")

proc pinsOf*(resolution: ProvisioningResolution): seq[ProvisioningPin] =
  resolution.selections.mapIt(pinOf(it))

proc coordinateOfRecord(r: LockedRealization): string =
  r.catalogWorkspace & "|" & r.catalogRemote & "@" & r.catalogRevision & "#" &
    r.catalogInterfaceArtifact

proc coordinateOfSelection(c: CatalogCoordinate): string =
  c.workspace & "|" & c.remote & "@" & c.revision.toLowerAscii() & "#" &
    normalizedFingerprint(c.interfaceArtifact)

proc resolveProvisioningSelections*(request: ProvisioningResolutionRequest;
                                    resolver: ContributionResolver):
    ProvisioningResolution =
  ## THE provisioning resolver. Never raises. See the module docstring for
  ## the precedence and for every refusal.
  var refusals: seq[string] = @[]
  let host = request.hostPlatform
  let target = request.targetPlatform
  if host.strip().len == 0 or target.strip().len == 0:
    refusals.add("platform-missing: the host and target platform the lock " &
      "is resolved for must both be stated (host \"" & host &
      "\", target \"" & target & "\")")
    return ProvisioningResolution(refusals: refusals)

  # --- 1. The lock's claims for this platform pair --------------------------
  var claims: seq[LockedRealization] = @[]
  for r in request.lockClaims:
    if not r.isSealed:
      # Only the lock writer's seal and the strict reader's seal produce a
      # claim; a record built or edited in memory is not a committed lock.
      refusals.add("lock-claim-unsealed: the provisioning record for " &
        "package \"" & r.packageName & "\" (contributor \"" &
        r.contributor & "\") was not read from a committed lock or sealed " &
        "by the lock writer, or was edited after sealing")
      continue
    if r.hostPlatform == host and r.targetPlatform == target:
      claims.add(r)
  var claimPackages = claims.mapIt(it.packageName).sorted(cmp)
  for i in 1 ..< claimPackages.len:
    if claimPackages[i] == claimPackages[i - 1]:
      refusals.add("lock-claims-duplicated: the lock carries more than one " &
        "provisioning record for package \"" & claimPackages[i] & "\" on " &
        host & " -> " & target)
  claimPackages = claimPackages.deduplicate(isSorted = true)

  # --- 2. Curator policy may not contradict the lock ------------------------
  # A rule that AGREES with the lock is passed on unchanged: inside
  # ``composeCatalogs`` the lock pin outranks it.
  for rule in request.policy.selections:
    for r in claims:
      if r.packageName == rule.targetPackage:
        if r.contributor != rule.contributor:
          refusals.add("policy-contradicts-lock: the committed lock pins " &
            "contributor \"" & r.contributor & "\" (contribution " &
            r.contributionFingerprint & ") for package \"" & r.packageName &
            "\", but the curator policy selects \"" & rule.contributor &
            "\". Neither is followed silently: refresh the lock to adopt " &
            "the policy, or change the policy back.")

  # --- 3. Compose with the lock pins at the top of the precedence ----------
  let composition = composeCatalogs(request.imports, request.policy,
    claims.mapIt(CatalogLockPin(targetPackage: it.packageName,
      contributor: it.contributor)))
  # A refused composition carries no selections, so its diagnostics reach
  # the caller through the all-or-nothing return at the end.
  for d in composition.diagnostics:
    refusals.add($d.kind & ": " & d.message)

  # --- 4. Every selection backed by a fingerprintable identity --------------
  var selections: seq[ResolvedProvisioningSelection] = @[]
  for sel in composition.selections:
    let wantDigest = sel.contributionRecordDigest
    let backing = request.offered.filterIt(
      interfaceContributionRecordDigest(it.contribution) == wantDigest)
    if backing.len == 0:
      refusals.add("contribution-identity-missing: package \"" &
        sel.targetPackage & "\" selects contributor \"" & sel.contributor &
        "\" (record " & wantDigest & ", " & $sel.reason & "), but no full " &
        "contribution identity was offered for that record, so its " &
        "contribution fingerprint cannot be computed or checked")
      continue
    var hexes: seq[string] = @[]
    var chosen = backing[0]
    var fpRefusal = ""
    for identity in backing:
      let fp = contributionFingerprint(identity, resolver)
      if not fp.isResolved:
        fpRefusal = "contribution-fingerprint-refused: " & fp.refusalReason
      elif not fp.dependenciesFullyResolved:
        fpRefusal = "dependencies-not-fully-resolved: " &
          fp.unresolvedDependencies.mapIt(contributionCoordinate(it)).join(", ")
      else:
        if fp.hex notin hexes:
          hexes.add(fp.hex)
          chosen = identity
    if fpRefusal.len > 0:
      refusals.add(fpRefusal & " (package \"" & sel.targetPackage &
        "\", contributor \"" & sel.contributor & "\")")
      continue
    if hexes.len != 1:
      refusals.add("contribution-identity-ambiguous: package \"" &
        sel.targetPackage & "\" selects contributor \"" & sel.contributor &
        "\" (record " & wantDigest & "), and the offered identities for " &
        "that record fingerprint to " & $hexes.len & " different values: " &
        hexes.sorted(cmp).join(", "))
      continue
    let currentHex = hexes[0]

    var resolved = ResolvedProvisioningSelection(selection: sel,
      identity: chosen, contributionFingerprint: currentHex,
      source:
        case sel.reason
        of csLock: pssLock
        of csCuratorPolicy: pssCuratorPolicy
        of csUniqueEligible: pssUniqueEligible)

    if sel.reason == csLock:
      # The record is checked by the SAME gate ``lockedRealizationFor``
      # applies, then against the catalog coordinate and realization.
      var record: LockedRealization
      try:
        record = requireCurrentRealization(claims, sel.targetPackage, host,
          target, normalizedFingerprint(sel.targetInterfaceFingerprint),
          currentHex)
      except StaleLockedRealizationError as err:
        refusals.add($err.freshness & ": " & err.msg & " (the lock pins " &
          "contributor \"" & sel.contributor & "\"; the composed catalogs " &
          "offer contributor \"" & sel.contributor & "\" at interface " &
          normalizedFingerprint(sel.targetInterfaceFingerprint) &
          ", contribution " & currentHex & "; not re-selected)")
        continue
      except LockedRealizationError as err:
        refusals.add("lock-claim-missing: " & err.msg)
        continue
      let lockedAt = coordinateOfRecord(record)
      let offeredAt = coordinateOfSelection(sel.catalogCoordinate)
      # Compared component by component: the spellings above are for the
      # diagnostic only and are not injective.
      let c = sel.catalogCoordinate
      if record.catalogWorkspace != c.workspace or
          record.catalogRemote != c.remote or
          record.catalogRevision != c.revision.toLowerAscii() or
          record.catalogInterfaceArtifact !=
            normalizedFingerprint(c.interfaceArtifact):
        refusals.add("catalog-changed: the lock pins contributor \"" &
          record.contributor & "\" for package \"" & record.packageName &
          "\" from catalog " & lockedAt & ", but the composed catalogs " &
          "offer it from catalog " & offeredAt & ". The lock pins the " &
          "catalog revision; refresh the lock deliberately.")
        continue
      let declared = declaredRealizations(chosen,
        record.realizationLockIdentity)
      if declared.len != 1 or declared[0].kind != record.realizationKind or
          declared[0].integrity != record.realizationIntegrity:
        refusals.add("realization-changed: the lock pins realization \"" &
          record.realizationLockIdentity & "\" (" & $record.realizationKind &
          ", integrity " & record.realizationIntegrity & ") of contributor \"" &
          record.contributor & "\" for package \"" & record.packageName &
          "\", but the offered contribution declares it " & $declared.len &
          " time(s)" &
          (if declared.len == 1:
             " as " & $declared[0].kind & ", integrity " & declared[0].integrity
           else: ""))
        continue
      resolved.lockedRecord = some(record)
    selections.add(resolved)

  # A claim whose package no catalog offers is refused by ``composeCatalogs``
  # (``locked-contribution-unavailable``), so every claim for this platform
  # pair either produced a lock selection above or refused.

  if refusals.len > 0:
    return ProvisioningResolution(
      refusals: refusals.sorted(cmp).deduplicate(isSorted = true))
  # ``composition.selections`` is already in sorted package order and is
  # walked in that order, so ``selections`` is too.
  ProvisioningResolution(selections: selections)

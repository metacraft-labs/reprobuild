## Provisioning LOCK DIFF and RE-SELECTION -- M7 deliverable 5 of
## ``ReproOS-Campaign-Completion.milestones.org``: "Add lock refresh and diff
## diagnostics that explain why a contributor changed."
##
## Normatively: ``reprobuild-specs/Provisioning-Contributions.md``
## § Resolution and § Locks And Snapshots.
##
## ## The diff
##
## ``diffProvisioningRecords`` compares two sets of locked provisioning
## realizations (``repro_lock/provisioning.LockedRealization``) and reports
## one ``ProvisioningRecordChange`` per (package, host platform, target
## platform) -- the lock's own uniqueness key -- that differs. The order the
## records arrive in is never observable. Each change carries every cause
## that applies, classified from the records' own fields:
##
##   * ``contributor-changed`` -- another contributor is selected;
##   * ``interface-changed`` -- the package's canonical interface moved
##     (incompatible);
##   * ``contribution-changed`` -- same contributor, same interface, a
##     different contribution fingerprint: a REALIZATION-ONLY change
##     (typechecking stays valid);
##   * ``catalog-changed`` -- a catalog coordinate component (workspace,
##     remote, revision, interface-artifact identity) moved;
##   * ``realization-changed`` -- the locked realization's lock identity,
##     family or integrity moved;
##   * ``selection-basis-changed`` -- ``unique-eligible`` vs
##     ``curator-policy``;
##   * ``capabilities-changed``;
##   * ``added`` / ``removed`` / ``platform-moved`` (one package's only
##     removed record and only added record are on different platform
##     pairs).
##
## ## Why a fingerprint moved, and what is NOT claimed
##
## A lock records the contribution FINGERPRINT, not the metadata it was
## computed from, so the records alone cannot say which realization field
## moved it. The diff says so ("cause not determinable from the records")
## and names only the recorded fingerprint INPUTS that also moved (the
## interface, the realization's lock identity / family / integrity), each
## as "accounts for at least part of the change" -- never as the whole
## cause. A catalog revision is NOT a fingerprint input and is never
## offered as a cause of a fingerprint change.
##
## Field-level causes are given only from EVIDENCE: the full
## ``ContributionIdentity`` of the old and of the new contribution
## (``ProvisioningDiffEvidence``). Evidence is used only after it is
## VERIFIED: its contribution fingerprint is recomputed and must be fully
## resolved and EQUAL to the fingerprint the record carries -- an identity
## that does not reproduce the locked fingerprint is not evidence about it.
## ``explainContributionChange`` then compares exactly the inputs the
## fingerprint folds in (``contribution_fingerprint``: contributor, target
## package, normalised target interface and provider identity, every
## realization through the SAME ``RealizationFieldView`` the encoder is
## built from, and every dependency edge's folded hex), so a field cannot
## move the fingerprint without being named. If the two fingerprints differ
## and no compared input does, it says the cause is not determinable rather
## than inventing one.
##
## Refused, never diffed: a record that is not SEALED (read from a committed
## lock by the strict reader, or written by the lock writer), and two
## records for one key on one side. A refused diff carries no changes, so
## it can never read as "no change".
##
## ## Re-selection (``reselectProvisioning``)
##
## The explicit re-selection ``repro lock refresh --provisioning`` performs
## (see ``repro_cli_support/provisioning_lock_selection``): re-run the
## resolver for one platform pair WITHOUT the lock's own claims -- the
## curator policy, else the unique eligible contribution, else an ambiguity
## refusal (Provisioning-Contributions.md § Resolution) -- lock every
## selection with the lock writer (``lockSelectedRealization``, which gates
## on ``dependenciesFullyResolved``), carry the records of OTHER platform
## pairs forward unchanged, and diff the incumbent against the result.
## All or nothing: any refusal leaves ``records`` empty and nothing is to
## be written. The lock's own pin is deliberately not a selection rule here:
## it is the thing being re-derived, and a record may only say
## ``unique-eligible`` or ``curator-policy``.
##
## ## Build-time explanation (``explainLockMismatch``)
##
## When the resolver refuses a committed lock, the CLI appends the same
## diff -- each locked record against what the composed catalogs now offer
## for the same contributor -- so a ``contribution-changed`` refusal says
## which field moved (given evidence) or that it cannot tell.
##
## ## Trust boundary
##
## Nothing here produces a ``ProvisioningPin``. Re-selection produces
## RECORDS (sealed by the lock writer); a build still re-reads them and
## re-runs the resolver in-process (``contribution_selection``) before any
## pin exists.

import std/[algorithm, options, sequtils, strutils, tables]

import repro_lock/provisioning

import ../repro_interface_artifacts
import ./catalog_composition
import ./contribution_fingerprint
import ./contribution_lock
import ./contribution_selection

export provisioning

# ---------------------------------------------------------------------------
# Field-level explanation from two contribution identities
# ---------------------------------------------------------------------------

type
  ContributionExplanation* = object
    ## Why the contribution fingerprint of ``previous`` differs from that
    ## of ``current``. ``determinable`` is false when either identity is not
    ## usable evidence (its fingerprint refuses or is not fully bound) or
    ## when no compared input differs; ``refusal`` then says which.
    determinable*: bool
    previousHex*: string
    currentHex*: string
    lines*: seq[string]
    refusal*: string

proc q(value: string): string =
  ## A value as a diagnostic spells it: quoted, with whitespace and control
  ## characters escaped, so a case or whitespace variant is visible.
  value.escape()

proc variantNote(a, b: string): string =
  if a != b and a.toLowerAscii() == b.toLowerAscii():
    " (differs only in letter case)"
  elif a != b and a.strip() == b.strip():
    " (differs only in surrounding whitespace)"
  else:
    ""

proc setText(values: seq[string]): string =
  "[" & values.sorted(cmp).mapIt(q(it)).join(", ") & "]"

proc pairsText(pairs: seq[(string, string)]): string =
  var sortedPairs = pairs
  sortedPairs.sort(proc (a, b: (string, string)): int =
    result = cmp(a[0], b[0])
    if result == 0: result = cmp(a[1], b[1]))
  "{" & sortedPairs.mapIt(q(it[0]) & ": " & q(it[1])).join(", ") & "}"

proc viewLabel(v: RealizationFieldView): string =
  v.family & " realization " & q(v.lockIdentity)

proc compareViews(a, b: RealizationFieldView): seq[string] =
  ## Every encoded component of two views of ONE family that differs.
  let label = viewLabel(a)
  var bFields = initTable[string, string]()
  for (name, value) in b.fields:
    bFields[name] = value
  var seen: seq[string] = @[]
  for (name, value) in a.fields:
    seen.add(name)
    let other = bFields.getOrDefault(name, "")
    if name notin bFields or other != value:
      result.add(label & ": field " & name & ": " & q(value) & " -> " &
        (if name in bFields: q(other) else: "<absent>") &
        variantNote(value, other))
  for (name, value) in b.fields:
    if name notin seen:
      result.add(label & ": field " & name & ": <absent> -> " & q(value))
  for i in 0 ..< max(a.sets.len, b.sets.len):
    let name = if i < a.sets.len: a.sets[i][0] else: b.sets[i][0]
    let av = if i < a.sets.len: a.sets[i][1].sorted(cmp) else: @[]
    let bv = if i < b.sets.len: b.sets[i][1].sorted(cmp) else: @[]
    if av != bv:
      result.add(label & ": " & name & ": " & setText(av) & " -> " &
        setText(bv))
  for i in 0 ..< max(a.pairSets.len, b.pairSets.len):
    let name = if i < a.pairSets.len: a.pairSets[i][0] else: b.pairSets[i][0]
    let av = if i < a.pairSets.len: a.pairSets[i][1] else: @[]
    let bv = if i < b.pairSets.len: b.pairSets[i][1] else: @[]
    if pairsText(av) != pairsText(bv):
      result.add(label & ": " & name & ": " & pairsText(av) & " -> " &
        pairsText(bv))

proc viewKey(v: RealizationFieldView): string =
  ## Pairing key: family, then lock identity, length-framed.
  $v.family.len & ":" & v.family & $v.lockIdentity.len & ":" & v.lockIdentity

proc compareRealizations(previous, current: seq[RealizationFieldView]):
    seq[string] =
  var prevBy = initTable[string, seq[RealizationFieldView]]()
  var curBy = initTable[string, seq[RealizationFieldView]]()
  var keys: seq[string] = @[]
  for v in previous:
    let k = viewKey(v)
    if k notin prevBy: prevBy[k] = @[]
    prevBy[k].add(v)
    if k notin keys: keys.add(k)
  for v in current:
    let k = viewKey(v)
    if k notin curBy: curBy[k] = @[]
    curBy[k].add(v)
    if k notin keys: keys.add(k)
  keys.sort(cmp)
  var removed, added: seq[RealizationFieldView] = @[]
  for k in keys:
    let a = prevBy.getOrDefault(k, @[])
    let b = curBy.getOrDefault(k, @[])
    if a.len == 1 and b.len == 1:
      result.add(compareViews(a[0], b[0]))
    elif a.len == 0:
      added.add(b)
    elif b.len == 0:
      removed.add(a)
    else:
      let ea = a.mapIt(encodeFieldView(it)).sorted(cmp)
      let eb = b.mapIt(encodeFieldView(it)).sorted(cmp)
      if ea != eb:
        result.add(viewLabel(a[0]) & ": declared " & $a.len &
          " time(s) before and " & $b.len & " time(s) now; declarations " &
          "sharing one lock identity cannot be paired field by field, and " &
          "their encoded set differs")
  # One removed and one added realization of the same family are the same
  # realization under a new lock identity: compare them field by field.
  var pairedRemoved, pairedAdded: seq[int] = @[]
  for family in ["nix", "tarball", "scoop", "from-source"]:
    var ri, ai: seq[int] = @[]
    for i, v in removed:
      if v.family == family: ri.add(i)
    for i, v in added:
      if v.family == family: ai.add(i)
    if ri.len == 1 and ai.len == 1:
      result.add(compareViews(removed[ri[0]], added[ai[0]]))
      pairedRemoved.add(ri[0])
      pairedAdded.add(ai[0])
  for i, v in removed:
    if i notin pairedRemoved:
      result.add(viewLabel(v) & ": removed")
  for i, v in added:
    if i notin pairedAdded:
      result.add(viewLabel(v) & ": added")

proc dependencyKeyText(dep: ContributionDependencyRef): string =
  ## Injective (length-framed) key over the full dependency coordinate.
  let fp = normalizedFingerprint(dep.targetInterfaceFingerprint)
  $dep.targetPackage.len & ":" & dep.targetPackage & $dep.contributor.len &
    ":" & dep.contributor & $fp.len & ":" & fp

proc compareDependencies(previous, current: seq[ContributionDependencyBinding]):
    seq[string] =
  ## The dependency edges that moved the fingerprint. The fingerprint folds
  ## in the SET of bound sub-fingerprints (sorted, de-duplicated), so an
  ## edge is named only when one of its sub-fingerprints is in exactly one
  ## of the two sets: an edge added, removed or re-pointed onto a
  ## sub-fingerprint the other side also folds in moves nothing, and naming
  ## it would misattribute the change.
  var prevHexes, curHexes: seq[string] = @[]
  for b in previous: prevHexes.add(b.hex)
  for b in current: curHexes.add(b.hex)
  proc moves(hexes: seq[string]; otherSide: seq[string]): bool =
    hexes.anyIt(it notin otherSide)
  var prevBy = initTable[string, seq[ContributionDependencyBinding]]()
  var curBy = initTable[string, seq[ContributionDependencyBinding]]()
  var keys: seq[(string, string)] = @[]
  for b in previous:
    let k = dependencyKeyText(b.dependency)
    if k notin prevBy:
      prevBy[k] = @[]
      if keys.allIt(it[1] != k):
        keys.add((contributionCoordinate(b.dependency), k))
    prevBy[k].add(b)
  for b in current:
    let k = dependencyKeyText(b.dependency)
    if k notin curBy:
      curBy[k] = @[]
      if keys.allIt(it[1] != k):
        keys.add((contributionCoordinate(b.dependency), k))
    curBy[k].add(b)
  keys.sort(proc (a, b: (string, string)): int =
    result = cmp(a[0], b[0])
    if result == 0: result = cmp(a[1], b[1]))
  for (spelling, k) in keys:
    let a = prevBy.getOrDefault(k, @[])
    let b = curBy.getOrDefault(k, @[])
    let ha = a.mapIt(it.hex).sorted(cmp).deduplicate(isSorted = true)
    let hb = b.mapIt(it.hex).sorted(cmp).deduplicate(isSorted = true)
    if not (moves(ha, curHexes) or moves(hb, prevHexes)):
      continue
    if a.len == 0:
      result.add("dependency " & q(spelling) & ": added")
    elif b.len == 0:
      result.add("dependency " & q(spelling) & ": removed")
    else:
      if ha != hb:
        result.add("dependency " & q(spelling) & ": its contribution " &
          "fingerprint changed: " & ha.join(",") & " -> " & hb.join(",") &
          " (see that dependency's own contribution for its cause)")

proc resolverOrLeaf(r: ContributionResolver): ContributionResolver =
  if r.isNil: noContributionResolver else: r

proc explainContributionChange*(previous, current: ContributionIdentity;
                                previousResolver,
                                currentResolver: ContributionResolver):
    ContributionExplanation =
  ## Why ``previous`` and ``current`` fingerprint differently, input by
  ## input (see the module docstring). Never raises.
  let pf = contributionFingerprint(previous, resolverOrLeaf(previousResolver))
  let cf = contributionFingerprint(current, resolverOrLeaf(currentResolver))
  result.previousHex = pf.hex
  result.currentHex = cf.hex
  for (label, fp) in [("previous", pf), ("current", cf)]:
    if not fp.isResolved:
      result.refusal = "the " & label & " contribution identity does not " &
        "fingerprint (" & fp.refusalReason & ")"
      return
    if not fp.dependenciesFullyResolved:
      result.refusal = "the " & label & " contribution identity binds " &
        "dependencies by coordinate only (" &
        fp.unresolvedDependencies.mapIt(contributionCoordinate(it)).join(", ") &
        "), so its fingerprint cannot be compared input by input"
      return
  result.determinable = true
  if pf.hex == cf.hex:
    return
  let a = previous.contribution
  let b = current.contribution
  if a.contributor != b.contributor:
    result.lines.add("contributor id: " & q(a.contributor) & " -> " &
      q(b.contributor) & variantNote(a.contributor, b.contributor))
  if a.targetPackage != b.targetPackage:
    result.lines.add("target package: " & q(a.targetPackage) & " -> " &
      q(b.targetPackage) & variantNote(a.targetPackage, b.targetPackage))
  let ia = normalizedFingerprint(a.targetInterfaceFingerprint)
  let ib = normalizedFingerprint(b.targetInterfaceFingerprint)
  if ia != ib:
    result.lines.add("target interface fingerprint: " & ia & " -> " & ib)
  let pa = normalizedFingerprint(previous.providerIdentity)
  let pb = normalizedFingerprint(current.providerIdentity)
  if pa != pb:
    result.lines.add("provider identity: " & pa & " -> " & pb)
  result.lines.add(compareRealizations(realizationFieldViews(previous),
    realizationFieldViews(current)))
  result.lines.add(compareDependencies(pf.dependencyBindings,
    cf.dependencyBindings))
  if result.lines.len == 0:
    result.determinable = false
    result.refusal = "the two contribution fingerprints differ, but no " &
      "compared input does; the cause is not determinable"

# ---------------------------------------------------------------------------
# The record diff
# ---------------------------------------------------------------------------

type
  ProvisioningChangeKind* = enum
    pckAdded = "added"
    pckRemoved = "removed"
    pckMoved = "moved"
    pckChanged = "changed"

  ProvisioningChangeCause* = enum
    pccAdded = "added"
    pccRemoved = "removed"
    pccPlatformMoved = "platform-moved"
    pccContributorChanged = "contributor-changed"
    pccInterfaceChanged = "interface-changed"
    pccContributionChanged = "contribution-changed"
      ## Same contributor, same interface, different contribution
      ## fingerprint: a realization-only change.
    pccCatalogChanged = "catalog-changed"
    pccRealizationChanged = "realization-changed"
    pccSelectionBasisChanged = "selection-basis-changed"
    pccCapabilitiesChanged = "capabilities-changed"
    pccNotOffered = "not-offered"
      ## Build-time only: the locked selection is not among what the
      ## composed catalogs offer (``explainLockMismatch``).

  ProvisioningRecordChange* = object
    kind*: ProvisioningChangeKind
    packageName*: string
    hostPlatform*: string
      ## The pair the change is reported on: the new record's, or the old
      ## one's for a removal.
    targetPlatform*: string
    previousHostPlatform*: string
      ## For ``pckMoved``: the pair the package was locked for before.
    previousTargetPlatform*: string
    causes*: seq[ProvisioningChangeCause]
    lines*: seq[string]
    causeDeterminable*: bool
      ## For a ``contribution-changed`` (or interface-changed) record with
      ## the same contributor: whether verified evidence named the inputs
      ## that moved the fingerprint.

  ProvisioningLockDiff* = object
    changes*: seq[ProvisioningRecordChange]
      ## Sorted by (package, host, target). Empty whenever ``refusals`` is
      ## not.
    refusals*: seq[string]

  ProvisioningDiffEvidence* = object
    ## Contribution identities a diff may use to explain a fingerprint
    ## change field by field. Each is used only if its fingerprint, under
    ## the given resolver, is fully resolved and EQUAL to the fingerprint
    ## of the record it is offered for. Optional: empty evidence makes
    ## every fingerprint change "not determinable from the records".
    previous*: seq[ContributionIdentity]
    current*: seq[ContributionIdentity]
    previousResolver*: ContributionResolver
    currentResolver*: ContributionResolver

proc refused*(diff: ProvisioningLockDiff): bool = diff.refusals.len > 0

proc unchanged*(diff: ProvisioningLockDiff): bool =
  ## True only for a diff that was computed AND found nothing. A refused
  ## diff is not unchanged.
  diff.refusals.len == 0 and diff.changes.len == 0

proc coordinateText(r: LockedRealization): string =
  "workspace " & q(r.catalogWorkspace) & ", remote " & q(r.catalogRemote) &
    ", revision " & r.catalogRevision & ", interface artifact " &
    r.catalogInterfaceArtifact

proc evidenceFor(ids: seq[ContributionIdentity];
                 resolver: ContributionResolver;
                 packageName, contributor, hex: string):
    Option[ContributionIdentity] =
  ## The first identity for (package, contributor) whose fully resolved
  ## fingerprint is ``hex``; none otherwise. (The package and contributor
  ## filters only skip fingerprinting unrelated identities: the
  ## fingerprint binds both.)
  for id in ids:
    if id.contribution.targetPackage != packageName or
        id.contribution.contributor != contributor:
      continue
    let fp = contributionFingerprint(id, resolverOrLeaf(resolver))
    if fp.dependenciesFullyResolved and fp.hex == hex:
      return some(id)
  none(ContributionIdentity)

proc describeRecord(r: LockedRealization): string =
  "contributor " & q(r.contributor) & ", contribution " &
    r.contributionFingerprint & ", interface " & r.interfaceFingerprint &
    ", catalog (" & coordinateText(r) & "), realization " &
    $r.realizationKind & " " & q(r.realizationLockIdentity) &
    " (integrity " & r.realizationIntegrity & "), capabilities " &
    setText(r.capabilities) & ", selected by " & $r.selectedBy

proc explainRecordChange*(old, new: LockedRealization;
                          evidence: ProvisioningDiffEvidence;
                          currentFingerprintKnown = true):
    ProvisioningRecordChange =
  ## Classify and explain how ``new`` differs from ``old`` (two records of
  ## one package; the platform pair is the caller's business). ``causes``
  ## is empty when they are identical. ``currentFingerprintKnown`` false
  ## means ``new.contributionFingerprint`` is not a computed value (the
  ## build-time view of an identity that does not fingerprint): no
  ## fingerprint comparison is made.
  result.kind = pckChanged
  result.packageName = new.packageName
  result.hostPlatform = new.hostPlatform
  result.targetPlatform = new.targetPlatform
  result.causeDeterminable = true
  template cause(c: ProvisioningChangeCause) =
    if c notin result.causes: result.causes.add(c)

  let sameContributor = old.contributor == new.contributor
  if not sameContributor:
    cause(pccContributorChanged)
    result.lines.add("contributor changed: " & q(old.contributor) & " -> " &
      q(new.contributor) &
      (if old.contributor.toLowerAscii() == new.contributor.toLowerAscii():
         " (the ids differ only in letter case; contributor ids are " &
         "compared exactly, so this is another contributor)"
       else: ""))
  let interfaceMoved = old.interfaceFingerprint != new.interfaceFingerprint
  if interfaceMoved:
    cause(pccInterfaceChanged)
    result.lines.add("interface changed: " & old.interfaceFingerprint &
      " -> " & new.interfaceFingerprint & " (the package's canonical " &
      "interface moved: the locked selection is incompatible)")

  # Recorded fingerprint INPUTS that moved, for the "at least part of the
  # cause" statement. The catalog coordinate is deliberately absent: it is
  # not an input of the contribution fingerprint.
  var realizationInputs: seq[string] = @[]
  if old.realizationLockIdentity != new.realizationLockIdentity:
    realizationInputs.add("the realization lock identity")
  if old.realizationKind != new.realizationKind:
    realizationInputs.add("the realization family")
  if old.realizationIntegrity != new.realizationIntegrity:
    realizationInputs.add("the realization integrity")

  if not currentFingerprintKnown:
    result.lines.add("contribution: the offered contribution has no " &
      "computable fingerprint, so it cannot be compared with the locked " &
      old.contributionFingerprint)
  elif old.contributionFingerprint != new.contributionFingerprint:
    if not sameContributor:
      result.lines.add("contribution fingerprint: " &
        old.contributionFingerprint & " -> " & new.contributionFingerprint &
        " (another contributor's contribution)")
    else:
      if interfaceMoved:
        result.lines.add("contribution fingerprint changed: " &
          old.contributionFingerprint & " -> " & new.contributionFingerprint &
          " (the interface fingerprint is one of its inputs, and it moved)")
      else:
        cause(pccContributionChanged)
        result.lines.add("contribution changed (realization-only: the " &
          "interface is unchanged, so typechecking stays valid): " &
          old.contributionFingerprint & " -> " & new.contributionFingerprint)
      let before = evidenceFor(evidence.previous, evidence.previousResolver,
        old.packageName, old.contributor, old.contributionFingerprint)
      let after = evidenceFor(evidence.current, evidence.currentResolver,
        new.packageName, new.contributor, new.contributionFingerprint)
      var explained = false
      if before.isSome and after.isSome:
        let ex = explainContributionChange(before.get, after.get,
          evidence.previousResolver, evidence.currentResolver)
        if ex.determinable:
          explained = true
          result.lines.add("  cause (from the two contribution identities, " &
            "each verified to reproduce its record's fingerprint):")
          for line in ex.lines:
            result.lines.add("    - " & line)
      if not explained:
        result.causeDeterminable = false
        var missing: seq[string] = @[]
        if before.isNone: missing.add("the locked contribution")
        if after.isNone: missing.add("the new contribution")
        result.lines.add("  cause: not determinable from the records -- a " &
          "lock records the contribution fingerprint, not the metadata it " &
          "was computed from" &
          (if missing.len > 0:
             ", and no identity reproducing the fingerprint of " &
             missing.join(" or ") & " was supplied"
           else: ""))
        var inputs = realizationInputs
        if interfaceMoved: inputs.insert("the interface fingerprint", 0)
        if inputs.len > 0:
          result.lines.add("  recorded fingerprint inputs that also " &
            "changed (each accounts for at least part of the change; other " &
            "metadata may have changed too): " & inputs.join(", "))
        else:
          result.lines.add("  no recorded fingerprint input changed (the " &
            "interface, realization lock identity, family and integrity are " &
            "the same), so the change is in metadata the lock does not " &
            "record: realization fields, the provider identity or a " &
            "dependency")
  elif not sameContributor or interfaceMoved:
    # The fingerprint binds the contributor id and the interface, so the
    # two records contradict each other: never "the same contribution".
    result.lines.add("contribution fingerprint unchanged: " &
      old.contributionFingerprint & ", although the " &
      (if not sameContributor: "contributor id" else: "interface") &
      " it binds changed: the two records are inconsistent (a contribution " &
      "fingerprint binds its contributor id and interface), so at least " &
      "one of them was not written by the lock writer from that " &
      "contribution")
  elif canonicalRealizationEntry(old) != canonicalRealizationEntry(new):
    result.lines.add("contribution fingerprint unchanged: " &
      old.contributionFingerprint & " (the same contribution, byte for byte)")

  for (name, a, b) in [
      ("workspace", old.catalogWorkspace, new.catalogWorkspace),
      ("remote", old.catalogRemote, new.catalogRemote),
      ("revision", old.catalogRevision, new.catalogRevision),
      ("interface artifact", old.catalogInterfaceArtifact,
        new.catalogInterfaceArtifact)]:
    if a != b:
      cause(pccCatalogChanged)
      result.lines.add("catalog " & name & " changed: " & q(a) & " -> " &
        q(b) & variantNote(a, b))

  if old.realizationLockIdentity != new.realizationLockIdentity:
    cause(pccRealizationChanged)
    result.lines.add("realization changed: lock identity " &
      q(old.realizationLockIdentity) & " -> " &
      q(new.realizationLockIdentity) &
      variantNote(old.realizationLockIdentity, new.realizationLockIdentity))
  if old.realizationKind != new.realizationKind:
    cause(pccRealizationChanged)
    result.lines.add("realization changed: family " & $old.realizationKind &
      " -> " & $new.realizationKind)
  if old.realizationIntegrity != new.realizationIntegrity:
    cause(pccRealizationChanged)
    result.lines.add("realization changed: integrity " &
      q(old.realizationIntegrity) & " -> " & q(new.realizationIntegrity))

  if old.selectedBy != new.selectedBy:
    cause(pccSelectionBasisChanged)
    result.lines.add("selection basis changed: " & $old.selectedBy & " -> " &
      $new.selectedBy)
  if old.capabilities != new.capabilities:
    cause(pccCapabilitiesChanged)
    result.lines.add("capabilities changed: " & setText(old.capabilities) &
      " -> " & setText(new.capabilities))


proc keyOf(r: LockedRealization): string =
  $r.packageName.len & ":" & r.packageName & $r.hostPlatform.len & ":" &
    r.hostPlatform & $r.targetPlatform.len & ":" & r.targetPlatform

proc validateSide(records: seq[LockedRealization]; side: string;
                  refusals: var seq[string]) =
  var counts = initTable[string, int]()
  for r in records:
    if not r.isSealed:
      refusals.add(side & ": the record for package " & q(r.packageName) &
        " on " & r.hostPlatform & " -> " & r.targetPlatform & " was not " &
        "read from a committed lock or written by the lock writer (or was " &
        "edited after sealing); it is not diffed")
    counts.mgetOrPut(keyOf(r), 0) += 1
  for r in records:
    let k = keyOf(r)
    if counts.getOrDefault(k, 0) > 1:
      refusals.add(side & ": " & $counts[k] & " records for package " &
        q(r.packageName) & " on " & r.hostPlatform & " -> " &
        r.targetPlatform & "; a lock selects exactly one, so which one " &
        "changed is undecidable")
      counts[k] = 0

proc cmpChange(a, b: ProvisioningRecordChange): int =
  result = cmp(a.packageName, b.packageName)
  if result == 0: result = cmp(a.hostPlatform, b.hostPlatform)
  if result == 0: result = cmp(a.targetPlatform, b.targetPlatform)
  if result == 0: result = cmp(ord(a.kind), ord(b.kind))

proc diffProvisioningRecords*(old, new: seq[LockedRealization];
                              evidence = ProvisioningDiffEvidence()):
    ProvisioningLockDiff =
  ## The provisioning-level diff of two lock states (see the module
  ## docstring). Never raises.
  var refusals: seq[string] = @[]
  validateSide(old, "old lock", refusals)
  validateSide(new, "new lock", refusals)
  if refusals.len > 0:
    return ProvisioningLockDiff(
      refusals: refusals.sorted(cmp).deduplicate(isSorted = true))

  var oldBy = initTable[string, LockedRealization]()
  var newBy = initTable[string, LockedRealization]()
  for r in old: oldBy[keyOf(r)] = r
  for r in new: newBy[keyOf(r)] = r

  var changes: seq[ProvisioningRecordChange] = @[]
  var removedOf = initTable[string, seq[LockedRealization]]()
  var addedOf = initTable[string, seq[LockedRealization]]()
  var packages: seq[string] = @[]
  for r in old:
    let k = keyOf(r)
    if k in newBy:
      let n = newBy[k]
      if canonicalRealizationEntry(r) != canonicalRealizationEntry(n):
        var change = explainRecordChange(r, n, evidence)
        if change.causes.len == 0:
          # Unreachable while every field is classified above; kept so an
          # unclassified difference is reported, never read as "no change".
          change.lines.add("the records differ in a field this diff does " &
            "not classify: " & describeRecord(r) & " -> " & describeRecord(n))
        changes.add(change)
    else:
      removedOf.mgetOrPut(r.packageName, @[]).add(r)
      if r.packageName notin packages: packages.add(r.packageName)
  for r in new:
    if keyOf(r) notin oldBy:
      addedOf.mgetOrPut(r.packageName, @[]).add(r)
      if r.packageName notin packages: packages.add(r.packageName)

  var removedNames: seq[string] = @[]
  for p in packages:
    let rs = removedOf.getOrDefault(p, @[])
    let ads = addedOf.getOrDefault(p, @[])
    if rs.len == 1 and ads.len == 1:
      var change = explainRecordChange(rs[0], ads[0], evidence)
      change.kind = pckMoved
      change.previousHostPlatform = rs[0].hostPlatform
      change.previousTargetPlatform = rs[0].targetPlatform
      change.causes.insert(pccPlatformMoved, 0)
      change.lines.insert("moved to another platform: no longer locked for " &
        rs[0].hostPlatform & " -> " & rs[0].targetPlatform & "; now locked " &
        "for " & ads[0].hostPlatform & " -> " & ads[0].targetPlatform, 0)
      if change.causes.len == 1:
        change.lines.add("nothing else in the record changed")
      changes.add(change)
      continue
    for r in rs:
      removedNames.add(p)
      changes.add(ProvisioningRecordChange(kind: pckRemoved,
        packageName: p, hostPlatform: r.hostPlatform,
        targetPlatform: r.targetPlatform, causes: @[pccRemoved],
        causeDeterminable: true,
        lines: @["removed: the lock no longer pins " & describeRecord(r)]))
    for r in ads:
      changes.add(ProvisioningRecordChange(kind: pckAdded,
        packageName: p, hostPlatform: r.hostPlatform,
        targetPlatform: r.targetPlatform, causes: @[pccAdded],
        causeDeterminable: true,
        lines: @["added: " & describeRecord(r)]))
  # A package added under a name that differs from a removed one only in
  # letter case is ANOTHER package (names are compared exactly); say so.
  for change in changes.mitems:
    if change.kind == pckAdded:
      for other in removedNames:
        if other != change.packageName and
            other.toLowerAscii() == change.packageName.toLowerAscii():
          change.lines.add("note: package " & q(other) & " was removed in " &
            "this diff; the names differ only in letter case and are " &
            "different packages")
  changes.sort(cmpChange)
  ProvisioningLockDiff(changes: changes)

proc headerOf(c: ProvisioningRecordChange): string =
  let causes =
    if c.causes.len == 0: ""
    else: " (" & c.causes.mapIt($it).join(", ") & ")"
  case c.kind
  of pckMoved:
    "provisioning " & q(c.packageName) & ": moved from " &
      c.previousHostPlatform & " -> " & c.previousTargetPlatform & " to " &
      c.hostPlatform & " -> " & c.targetPlatform & causes
  else:
    "provisioning " & q(c.packageName) & " on " & c.hostPlatform & " -> " &
      c.targetPlatform & ": " & $c.kind & causes

proc renderChange*(c: ProvisioningRecordChange): seq[string] =
  result.add(headerOf(c))
  for line in c.lines:
    result.add("  " & line)

proc renderProvisioningDiff*(diff: ProvisioningLockDiff): string =
  ## The diff as text, one header per change and its explanation indented
  ## under it. Empty for an unchanged diff; a refused diff renders as its
  ## refusal, never as empty.
  var lines: seq[string] = @[]
  if diff.refusals.len > 0:
    lines.add("provisioning diff refused (the lock states cannot be " &
      "compared; this is NOT \"no change\"):")
    for r in diff.refusals:
      lines.add("  " & r)
  else:
    for c in diff.changes:
      lines.add(renderChange(c))
  lines.join("\n")

# ---------------------------------------------------------------------------
# Build-time explanation of a refused lock
# ---------------------------------------------------------------------------

proc explainUnmatchedClaim(claim: LockedRealization;
                           imports: seq[CatalogImport];
                           compositionRefused: bool):
    ProvisioningRecordChange =
  ## A locked record the composition did not select from: say what the
  ## catalogs offer for its package instead.
  result = ProvisioningRecordChange(kind: pckChanged,
    packageName: claim.packageName, hostPlatform: claim.hostPlatform,
    targetPlatform: claim.targetPlatform, causeDeterminable: true)
  var canon: seq[string] = @[]
  var mine: seq[string] = @[]
  var others: seq[string] = @[]
  for imp in imports:
    if imp.content.isNone: continue
    let content = imp.content.get
    for entry in content.canonicalInterfaces:
      if entry.packageName == claim.packageName:
        let fp = normalizedFingerprint(entry.interfaceFingerprint)
        if fp notin canon: canon.add(fp)
    for c in content.contributions:
      if c.targetPackage != claim.packageName: continue
      if c.contributor == claim.contributor:
        let line = "contributor " & q(c.contributor) & " offers it at " &
          "interface " & normalizedFingerprint(c.targetInterfaceFingerprint) &
          " from catalog " & catalogCoordinateKey(imp.coordinate)
        if line notin mine: mine.add(line)
      elif c.contributor notin others:
        others.add(c.contributor)
  canon.sort(cmp)
  mine.sort(cmp)
  others.sort(cmp)
  if canon.len == 1 and canon[0] != claim.interfaceFingerprint:
    result.causes.add(pccInterfaceChanged)
    result.lines.add("interface changed: " & claim.interfaceFingerprint &
      " -> " & canon[0] & " (the package's canonical interface moved: the " &
      "locked selection is incompatible)")
  elif canon.len == 0:
    result.lines.add("no imported catalog declares a canonical interface " &
      "for the package")
  elif canon.len > 1:
    result.lines.add("the imported catalogs declare " & $canon.len &
      " canonical interfaces for the package: " & canon.join(", "))
  if mine.len == 0:
    result.causes.add(pccNotOffered)
    result.lines.add("the locked contributor " & q(claim.contributor) &
      " offers no contribution for the package in any imported catalog" &
      (if others.len > 0:
         "; offered by: " & others.mapIt(q(it)).join(", ")
       else: "; no contributor offers it"))
  else:
    result.lines.add(mine)
    if compositionRefused:
      result.lines.add("the composed catalogs refused (see the refusals " &
        "above), so the locked record could not be compared further")

proc explainLockMismatch*(request: ProvisioningResolutionRequest;
                          resolver: ContributionResolver;
                          previous: seq[ContributionIdentity] = @[]):
    seq[ProvisioningRecordChange] =
  ## For each sealed lock claim on the request's platform pair, how it
  ## differs from what the composed catalogs offer NOW for the same
  ## contributor -- the explanation the CLI appends to a refused build.
  ## ``previous``: optional evidence (see ``ProvisioningDiffEvidence``).
  ## Claims that still match exactly produce nothing. Never raises.
  let host = request.hostPlatform
  let target = request.targetPlatform
  let res = resolverOrLeaf(resolver)
  var claims: seq[LockedRealization] = @[]
  for r in request.lockClaims:
    if r.isSealed and r.hostPlatform == host and r.targetPlatform == target:
      claims.add(r)
  let composition = composeCatalogs(request.imports, request.policy,
    claims.mapIt(CatalogLockPin(targetPackage: it.packageName,
      contributor: it.contributor)))
  for claim in claims:
    var selected = none(CatalogSelection)
    for sel in composition.selections:
      if sel.targetPackage == claim.packageName and sel.reason == csLock:
        selected = some(sel)
    if selected.isNone:
      let change = explainUnmatchedClaim(claim, request.imports,
        composition.refused)
      if change.lines.len > 0:
        result.add(change)
      continue
    let sel = selected.get
    let backing = request.offered.filterIt(
      interfaceContributionRecordDigest(it.contribution) ==
        sel.contributionRecordDigest)
    var hexes: seq[string] = @[]
    var chosen = none(ContributionIdentity)
    for identity in backing:
      let fp = contributionFingerprint(identity, res)
      if fp.dependenciesFullyResolved and fp.hex notin hexes:
        hexes.add(fp.hex)
        chosen = some(identity)
    var view = claim
    view.interfaceFingerprint =
      normalizedFingerprint(sel.targetInterfaceFingerprint)
    view.catalogWorkspace = sel.catalogCoordinate.workspace
    view.catalogRemote = sel.catalogCoordinate.remote
    view.catalogRevision = sel.catalogCoordinate.revision.toLowerAscii()
    view.catalogInterfaceArtifact =
      normalizedFingerprint(sel.catalogCoordinate.interfaceArtifact)
    let known = hexes.len == 1
    view.contributionFingerprint = if known: hexes[0] else: ""
    var extra: seq[string] = @[]
    if chosen.isSome and known:
      let declared = declaredRealizations(chosen.get,
        claim.realizationLockIdentity)
      if declared.len == 1:
        view.realizationKind = declared[0].kind
        view.realizationIntegrity = declared[0].integrity
      else:
        extra.add("the offered contribution declares the locked " &
          "realization " & q(claim.realizationLockIdentity) & " " &
          $declared.len & " time(s)")
    elif backing.len == 0:
      extra.add("no full identity is offered for the selected record, so " &
        "its contribution fingerprint cannot be computed")
    elif hexes.len == 0:
      extra.add("the offered identity's contribution fingerprint refuses " &
        "or is not fully resolved")
    else:
      extra.add("the offered identities for the selected record " &
        "fingerprint to " & $hexes.len & " different values")
    var change = explainRecordChange(claim, view, ProvisioningDiffEvidence(
      previous: previous, current: backing, previousResolver: res,
      currentResolver: res), currentFingerprintKnown = known)
    if extra.len > 0:
      if pccRealizationChanged notin change.causes and
          extra[0].startsWith("the offered contribution declares"):
        change.causes.add(pccRealizationChanged)
      change.lines.add(extra)
    if change.causes.len > 0 or change.lines.len > 0:
      result.add(change)
  result.sort(cmpChange)

# ---------------------------------------------------------------------------
# Explicit re-selection
# ---------------------------------------------------------------------------

type
  ProvisioningReselectionRequest* = object
    imports*: seq[CatalogImport]
    policy*: CatalogSelectionPolicy
    offered*: seq[ContributionIdentity]
    previous*: seq[ContributionIdentity]
      ## Optional diagnostic evidence for the diff (see
      ## ``ProvisioningDiffEvidence``).
    incumbent*: seq[LockedRealization]
      ## Every record of the lock being replaced, all platform pairs.
    hostPlatform*: string
    targetPlatform*: string

  ProvisioningReselection* = object
    records*: seq[LockedRealization]
      ## The complete new record set: the incumbent's records for other
      ## platform pairs, unchanged, plus one freshly locked record per
      ## selection on this pair. Empty whenever ``refusals`` is not.
    diff*: ProvisioningLockDiff
    carriedForward*: int
      ## How many incumbent records (other platform pairs) are carried
      ## unchanged.
    refusals*: seq[string]

proc reselected*(r: ProvisioningReselection): bool = r.refusals.len == 0

proc declaredLockIdentities(identity: ContributionIdentity): seq[string] =
  for v in realizationFieldViews(identity):
    if v.lockIdentity.len > 0 and v.lockIdentity notin result:
      result.add(v.lockIdentity)
  result.sort(cmp)

proc reselectProvisioning*(request: ProvisioningReselectionRequest;
                           resolver: ContributionResolver):
    ProvisioningReselection =
  ## Re-select every provisioning contribution on one platform pair (see
  ## the module docstring). All or nothing; never raises.
  let host = request.hostPlatform
  let target = request.targetPlatform
  let res = resolverOrLeaf(resolver)
  var refusals: seq[string] = @[]
  validateSide(request.incumbent, "incumbent lock", refusals)
  if refusals.len > 0:
    return ProvisioningReselection(
      refusals: refusals.sorted(cmp).deduplicate(isSorted = true))

  let resolution = resolveProvisioningSelections(ProvisioningResolutionRequest(
    imports: request.imports, lockClaims: @[], policy: request.policy,
    offered: request.offered, hostPlatform: host, targetPlatform: target),
    res)
  if not resolution.resolved:
    refusals.add(resolution.refusals)
    let pinnedHere = request.incumbent.filterIt(it.hostPlatform == host and
      it.targetPlatform == target)
    if pinnedHere.len > 0 and resolution.refusals.anyIt(
        it.startsWith($cdAmbiguousContribution)):
      refusals.add("note: re-selection does not take the incumbent lock's " &
        "own pins as a selection rule (they are what is being re-derived); " &
        "the incumbent pins " & pinnedHere.mapIt(q(it.packageName) & " -> " &
          q(it.contributor)).join(", ") & ". Name the contributor in the " &
        "curator policy to keep it.")
    return ProvisioningReselection(refusals: refusals)

  var fresh: seq[LockedRealization] = @[]
  for s in resolution.selections:
    let pkg = s.selection.targetPackage
    var incumbentHere = none(LockedRealization)
    for r in request.incumbent:
      if r.packageName == pkg and r.hostPlatform == host and
          r.targetPlatform == target:
        incumbentHere = some(r)
    var lockIdentity = ""
    if incumbentHere.isSome and
        declaredRealizations(s.identity,
          incumbentHere.get.realizationLockIdentity).len == 1:
      # The selected contribution still declares the locked realization:
      # keep locking that one.
      lockIdentity = incumbentHere.get.realizationLockIdentity
    else:
      let candidates = declaredLockIdentities(s.identity)
      if candidates.len == 1:
        lockIdentity = candidates[0]
      elif candidates.len == 0:
        refusals.add("realization-not-lockable: contributor " &
          q(s.selection.contributor) & " declares no realization with a " &
          "lock identity for package " & q(pkg))
        continue
      else:
        refusals.add("realization-choice-ambiguous: contributor " &
          q(s.selection.contributor) & " declares " & $candidates.len &
          " realizations for package " & q(pkg) & " (" &
          candidates.mapIt(q(it)).join(", ") & ") and the lock does not " &
          "already pin one of them; re-selection does not choose among " &
          "them")
        continue
    let outcome = lockSelectedRealization(RealizationLockRequest(
      selection: s.selection, identity: s.identity,
      realizationLockIdentity: lockIdentity, hostPlatform: host,
      targetPlatform: target,
      capabilities:
        if incumbentHere.isSome: incumbentHere.get.capabilities else: @[]),
      res)
    if not outcome.locked:
      refusals.add("package " & q(pkg) & " (contributor " &
        q(s.selection.contributor) & ") cannot be locked: " &
        outcome.refusals.join("; "))
      continue
    fresh.add(outcome.record)
  if refusals.len > 0:
    return ProvisioningReselection(
      refusals: refusals.sorted(cmp).deduplicate(isSorted = true))

  var records: seq[LockedRealization] = @[]
  var carried = 0
  for r in request.incumbent:
    if r.hostPlatform != host or r.targetPlatform != target:
      records.add(r)
      inc carried
  records.add(fresh)
  let diff = diffProvisioningRecords(request.incumbent, records,
    ProvisioningDiffEvidence(previous: request.previous,
      current: request.offered, previousResolver: res, currentResolver: res))
  if diff.refused:
    return ProvisioningReselection(refusals: diff.refusals)
  ProvisioningReselection(records: records, diff: diff,
    carriedForward: carried)

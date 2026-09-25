## Stamping resolver-selected provisioning pins onto a consumer's tool uses
## -- the ENGINE-SIDE half of M7 deliverable 3 of
## ``ReproOS-Campaign-Completion.milestones.org``.
##
## The resolver (``contribution_selection.resolveProvisioningSelections``)
## decides WHICH contribution provisions a package -- from the committed
## lock, an explicit curator policy, or a unique eligible contribution --
## and verifies the lock against the composed catalogs. What it hands the
## engine is a ``ProvisioningPin`` per package. This module is where the
## engine accepts those pins, and it accepts them only against the
## consumer's own interface artifact:
##
##   * the artifact must carry EXACTLY ONE distinct contribution record for
##     the pinned (package, contributor), and its
##     ``interfaceContributionRecordDigest`` must be the one the resolver
##     selected. A consumer artifact built from an older (or newer) import
##     of the contributor than the catalogs the lock was checked against is
##     therefore refused, not realized from stale metadata;
##   * every tool use of the package must carry that contributor's
##     realizations exactly as the record declares them;
##   * a pin that names a locked realization (``realizationLockIdentity``)
##     must name one the record declares exactly once;
##   * a pin must be well formed, name the package it is stamped on, and
##     appear once per package (a repeated identical pin is one pin).
##
## Independently of any pin, a used package for which the artifact carries
## two DISTINCT contribution records from ONE contributor refuses: the
## acquisition planners select by contributor, so such a pair could only be
## told apart by the order the contributions were imported in, and import
## order is never a selection rule (Provisioning-Contributions.md,
## Resolution).
##
## Refusals raise ``ProvisioningPinError`` and name every cause found.
## Nothing here reads the environment.
##
## ## Trust boundary
##
## These checks bind a pin to the consumer's ARTIFACT; they do not -- and
## cannot -- re-verify the pin against the lock or recompute its
## ``contributionFingerprint`` (that needs the provider identity, which the
## artifact does not carry). A hand-built pin with the right record digest
## and an arbitrary fingerprint, or naming a contributor other than the
## locked one, is ACCEPTED here (measured). The pin is therefore trusted
## input, and that is sound only while its sole producer is
## ``contribution_selection.pinOf`` over a resolution made in the same
## process. No code path persists, caches or transmits a pin today. Any that
## is added -- a cached build identity keyed on pins, a pin read back from
## disk or received over IPC -- must carry verification this module can
## check, or re-run the resolver, before the pin reaches
## ``applyProvisioningPins``.

import std/[algorithm, sequtils, strutils]

import ../repro_interface_artifacts
import ./contribution_fingerprint

type
  ProvisioningPinError* = object of ValueError

proc isLowerHex64(value: string): bool =
  value.len == 64 and value.allIt(it in {'0'..'9', 'a'..'f'})

proc isPinned*(pin: ProvisioningPin): bool =
  ## True for ANY non-zero pin. A partially filled pin is a pin -- and a
  ## malformed one, which ``pinDefects`` refuses -- never "no pin".
  pin != default(ProvisioningPin)

proc pinDefects*(pin: ProvisioningPin): seq[string] =
  ## Every reason ``pin`` is not a usable pin. Empty for a well-formed pin
  ## and for the zero value.
  if not pin.isPinned:
    return @[]
  if pin.packageName.len == 0 or pin.packageName.strip() != pin.packageName:
    result.add("package name is empty or padded: \"" & pin.packageName & "\"")
  if pin.contributor.len == 0 or pin.contributor.strip() != pin.contributor:
    result.add("contributor is empty or padded: \"" & pin.contributor &
      "\" (the canonical package provider is never pinned)")
  if not isLowerHex64(pin.contributionFingerprint):
    result.add("contribution fingerprint is not 64 lower-case hex: \"" &
      pin.contributionFingerprint & "\"")
  if not isLowerHex64(pin.contributionRecordDigest):
    result.add("contribution record digest is not 64 lower-case hex: \"" &
      pin.contributionRecordDigest & "\"")
  if pin.realizationLockIdentity.strip() != pin.realizationLockIdentity:
    result.add("realization lock identity is padded: \"" &
      pin.realizationLockIdentity & "\"")

proc describePin*(pin: ProvisioningPin): string =
  "contributor \"" & pin.contributor & "\" (contribution " &
    pin.contributionFingerprint & ", record " & pin.contributionRecordDigest &
    (if pin.realizationLockIdentity.len > 0:
       ", realization \"" & pin.realizationLockIdentity & "\""
     else: "") &
    ")"

proc declaredCount(c: InterfaceProvisioningContribution;
                   lockIdentity: string): int =
  ## How many of the record's realizations, in any family, declare
  ## ``lockIdentity``.
  c.nixProvisioning.countIt(it.lockIdentity == lockIdentity) +
    c.tarballProvisioning.countIt(it.lockIdentity == lockIdentity) +
    c.scoopProvisioning.countIt(it.lockIdentity == lockIdentity)

proc sameEntries[T](actual, declared: seq[T]): bool =
  ## Multiset equality: the use carries the contributor's realizations in
  ## the order ``toProjectInterface`` appended them, which is the record's
  ## own declaration order, but the check does not depend on it.
  if actual.len != declared.len:
    return false
  var remaining = declared
  for entry in actual:
    let at = remaining.find(entry)
    if at < 0:
      return false
    remaining.delete(at)
  true

proc recordDigestOf(c: InterfaceProvisioningContribution): string =
  ## ``interfaceContributionRecordDigest`` already spells lower-case hex
  ## (``repro_hash.toHex``), which is what ``pinDefects`` requires of a pin.
  interfaceContributionRecordDigest(c)

proc applyProvisioningPins*(pi: ProjectInterface;
                            pins: openArray[ProvisioningPin]):
    seq[InterfaceToolUse] =
  ## ``pi.toolUses`` with each pin stamped on the uses of its package, after
  ## checking the pins against ``pi`` (see the module docstring). Raises
  ## ``ProvisioningPinError`` naming every cause; returns the uses unchanged
  ## (and still subject to the duplicate-contributor check) when ``pins`` is
  ## empty.
  var refusals: seq[string] = @[]

  # --- 1. Pins: well formed, one per package --------------------------------
  var byPackage: seq[ProvisioningPin] = @[]
  for pin in pins:
    let defects = pinDefects(pin)
    if not pin.isPinned:
      refusals.add("a zero provisioning pin was supplied; a pin names a " &
        "package, a contributor and the verified contribution")
      continue
    if defects.len > 0:
      refusals.add("malformed provisioning pin for package \"" &
        pin.packageName & "\": " & defects.join("; "))
      continue
    var seen = false
    for existing in byPackage:
      if existing.packageName == pin.packageName:
        seen = true
        if existing != pin:
          refusals.add("two different provisioning pins for package \"" &
            pin.packageName & "\": " & describePin(existing) & " and " &
            describePin(pin) & "; a package is provisioned by one " &
            "selection, and which pin wins must not depend on their order")
    if not seen:
      byPackage.add(pin)

  # --- 2. Distinct records per (package, contributor) -----------------------
  var usedPackages: seq[string] = @[]
  for useDef in pi.toolUses:
    if useDef.packageSelector notin usedPackages:
      usedPackages.add(useDef.packageSelector)
  usedPackages.sort(cmp)
  for packageName in usedPackages:
    var contributors: seq[string] = @[]
    for c in pi.provisioningContributions:
      if c.targetPackage == packageName and c.contributor notin contributors:
        contributors.add(c.contributor)
    contributors.sort(cmp)
    for contributor in contributors:
      let digests = pi.provisioningContributions.
        filterIt(it.targetPackage == packageName and
          it.contributor == contributor).
        mapIt(recordDigestOf(it)).sorted(cmp).deduplicate(isSorted = true)
      if digests.len > 1:
        refusals.add("package \"" & packageName & "\" carries " &
          $digests.len & " different contribution records from contributor \"" &
          contributor & "\" (records " & digests.join(", ") & "); they " &
          "could only be told apart by import order, which is never a " &
          "selection rule. Drop one of the imports.")

  # --- 3. Each pin against the artifact's record ----------------------------
  for pin in byPackage:
    let records = pi.provisioningContributions.filterIt(
      it.targetPackage == pin.packageName and it.contributor == pin.contributor)
    if records.len == 0:
      let offered = pi.provisioningContributions.
        filterIt(it.targetPackage == pin.packageName).
        mapIt("\"" & it.contributor & "\"").sorted(cmp).
        deduplicate(isSorted = true)
      refusals.add("the provisioning selection for package \"" &
        pin.packageName & "\" pins " & describePin(pin) & ", but the " &
        "consumer's interface artifact carries no contribution from it " &
        "(contributors it carries: " &
        (if offered.len == 0: "<none>" else: offered.join(", ")) & ")")
      continue
    let digest = recordDigestOf(records[0])
    if records.anyIt(recordDigestOf(it) != digest):
      continue  # refused by step 2
    if digest != pin.contributionRecordDigest:
      refusals.add("the provisioning selection for package \"" &
        pin.packageName & "\" pins " & describePin(pin) & ", but the " &
        "consumer's interface artifact carries record " & digest &
        " from that contributor; the artifact was not built from the " &
        "contribution the selection verified. Rebuild the consumer's " &
        "interface against the locked catalogs, or refresh the lock.")
      continue
    if pin.realizationLockIdentity.len > 0:
      let declared = declaredCount(records[0], pin.realizationLockIdentity)
      if declared != 1:
        refusals.add("the provisioning selection for package \"" &
          pin.packageName & "\" pins " & describePin(pin) & ", but the " &
          "consumer's record from that contributor declares that " &
          "realization " & $declared & " time(s); the lock pins exactly " &
          "one realization")
        continue
    for useDef in pi.toolUses:
      if useDef.packageSelector != pin.packageName:
        continue
      if not (sameEntries(useDef.nixProvisioning.filterIt(
                it.contributor == pin.contributor), records[0].nixProvisioning) and
              sameEntries(useDef.tarballProvisioning.filterIt(
                it.contributor == pin.contributor),
                records[0].tarballProvisioning) and
              sameEntries(useDef.scoopProvisioning.filterIt(
                it.contributor == pin.contributor),
                records[0].scoopProvisioning)):
        refusals.add("tool use \"" & useDef.rawConstraint & "\" of package \"" &
          pin.packageName & "\" does not carry the realizations of " &
          describePin(pin) & " as its record declares them")
        break

  # --- 4. A use may not arrive already pinned -------------------------------
  # Pins are stamped HERE and nowhere else. A use that already carries one
  # was stamped by someone else; dropping it would silently unpin the use,
  # and keeping it would bypass every check above.
  for useDef in pi.toolUses:
    if useDef.provisioningPin.isPinned:
      refusals.add("tool use \"" & useDef.rawConstraint & "\" of package \"" &
        useDef.packageSelector & "\" already carries a provisioning pin (" &
        describePin(useDef.provisioningPin) & "); pins are applied only " &
        "by applyProvisioningPins")

  if refusals.len > 0:
    raise newException(ProvisioningPinError,
      "provisioning selection refused: " &
      refusals.sorted(cmp).deduplicate(isSorted = true).join(" | "))

  result = pi.toolUses
  for useDef in result.mitems:
    for pin in byPackage:
      if pin.packageName == useDef.packageSelector:
        useDef.provisioningPin = pin

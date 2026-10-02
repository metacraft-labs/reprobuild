## M7 deliverable 5 -- lock refresh and diff diagnostics that explain why a
## contributor changed (``ReproOS-Campaign-Completion.milestones.org`` § M7;
## normative design ``reprobuild-specs/Provisioning-Contributions.md``
## § Resolution and § Locks And Snapshots).
##
## Drives ``repro_interface_artifacts/provisioning_lock_diff`` directly:
##
##   * ``diffProvisioningRecords`` -- one case per change class, each
##     asserting the EXACT diagnostic text, plus the adversarial inputs a
##     diagnostics feature must not get wrong: reordered, duplicated and
##     unsealed records, records for another host, letter-case and
##     whitespace variants, and evidence that does not reproduce the locked
##     fingerprint. The two failures that matter are a diff that reports
##     "no change" when something changed, and one that misattributes the
##     cause -- so every case also asserts what is NOT said;
##   * ``explainContributionChange`` -- the field-level explanation, which
##     must name every fingerprint input that moved (realization fields,
##     set-valued fields, provider identity, dependencies) and nothing else;
##   * ``reselectProvisioning`` -- explicit re-selection: it rewrites the
##     records and diffs them, carries other platform pairs, and refuses --
##     producing no record -- on unbound dependencies, ambiguity, a
##     contradictory policy, an unreadable incumbent or an unlockable
##     realization;
##   * ``explainLockMismatch`` -- the build-time explanation of a refused
##     lock.
##
## No mocks: records are sealed by the real lock writer
## (``lockSelectedRealization``) or the real seal over a real fingerprint,
## identities are fingerprinted by the real ``contributionFingerprint``, and
## catalogs are composed by the real ``composeCatalogs``.

import std/[algorithm, options, sequtils, strutils, unittest]

import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_interface_artifacts/contribution_fingerprint
import repro_interface_artifacts/contribution_lock
import repro_interface_artifacts/contribution_selection
import repro_interface_artifacts/provisioning_lock_diff
import repro_lock

const
  Pkg = "diff-target"
  Pkg2 = "diff-other"
  A = "github:example/diff-catalog-a"
  B = "github:example/diff-catalog-b"
  Ws = "github:example/diff-workspace"
  PackagesRemote = "github:example/diff-packages"
  IfaceV1 = repeat('1', 64)
  IfaceV2 = repeat('2', 64)
  Iface2 = repeat('3', 64)
  PackagesRev = repeat('9', 40)
  RevA1 = repeat('a', 40)
  RevA2 = repeat('b', 40)
  RevB1 = repeat('c', 40)
  Art0 = repeat('4', 64)
  ArtA = repeat('5', 64)
  ArtA2 = repeat('6', 64)
  ArtB = repeat('7', 64)
  NixpkgsRev = "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"
  NarA = "sha256-" & repeat('A', 43) & "="
  NarB = "sha256-" & repeat('B', 43) & "="
  NarC = "sha256-" & repeat('C', 43) & "="
  ProvA = repeat('a', 64)
  ProvA2 = repeat('d', 64)
  ProvB = repeat('b', 64)
  Host = "amd64-linux"
  OtherHost = "arm64-linux"

# ---------------------------------------------------------------------------
# Fixture: identities, records, catalogs
# ---------------------------------------------------------------------------

proc nixLockId(selector, nar: string): string =
  "github:NixOS/nixpkgs/" & NixpkgsRev & "?narHash=" & nar & "#" & selector

proc nix(contributor, selector, nar: string; exe = "bin/tool";
         pkg = Pkg; lockId = ""): InterfaceNixProvisioning =
  InterfaceNixProvisioning(packageName: pkg, contributor: contributor,
    selector: "nixpkgs#" & selector, executablePath: exe,
    nixpkgsRef: "github:NixOS/nixpkgs", nixpkgsRev: NixpkgsRev,
    nixpkgsNarHash: nar, packageId: "tool@1",
    lockIdentity: if lockId.len > 0: lockId else: nixLockId(selector, nar))

proc contribution(contributor: string; nixes: seq[InterfaceNixProvisioning];
                  pkg = Pkg; iface = IfaceV1):
    InterfaceProvisioningContribution =
  InterfaceProvisioningContribution(targetPackage: pkg,
    targetInterfaceFingerprint: iface, contributor: contributor,
    nixProvisioning: nixes)

proc ident(c: InterfaceProvisioningContribution; provider = ProvA;
           deps: seq[ContributionDependencyRef] = @[]): ContributionIdentity =
  ContributionIdentity(contribution: c, providerIdentity: provider,
    dependencies: deps)

proc idA(nar = NarA; exe = "bin/tool"; provider = ProvA; iface = IfaceV1):
    ContributionIdentity =
  ident(contribution(A, @[nix(A, "tool-a", nar, exe)], iface = iface),
    provider)

proc idB(): ContributionIdentity =
  ident(contribution(B, @[nix(B, "tool-b", NarB)]), ProvB)

proc fpOf(id: ContributionIdentity): string =
  let fp = contributionFingerprint(id, noContributionResolver)
  doAssert fp.dependenciesFullyResolved, fp.refusalReason
  fp.hex

proc rec(id: ContributionIdentity; revision = RevA1; remote = "";
         artifact = ArtA; workspace = Ws; lockId = ""; host = Host;
         target = Host; caps: seq[string] = @[];
         basis = lsrUniqueEligible): LockedRealization =
  ## A record sealed by the real seal over the identity's real fingerprint.
  let c = id.contribution
  let lid =
    if lockId.len > 0: lockId else: c.nixProvisioning[0].lockIdentity
  let declared = declaredRealizations(id, lid)
  doAssert declared.len == 1
  let fp = fpOf(id)
  sealLockedRealization(LockedRealization(packageName: c.targetPackage,
    interfaceFingerprint: normalizedFingerprint(c.targetInterfaceFingerprint),
    contributor: c.contributor, contributionFingerprint: fp,
    catalogWorkspace: workspace,
    catalogRemote: if remote.len > 0: remote else: c.contributor,
    catalogRevision: revision, catalogInterfaceArtifact: artifact,
    realizationKind: declared[0].kind, realizationLockIdentity: lid,
    realizationIntegrity: declared[0].integrity, hostPlatform: host,
    targetPlatform: target, capabilities: caps, selectedBy: basis),
    ContributionEvidence(fingerprintHex: fp))

proc lockText(records: seq[LockedRealization]): string =
  serializeLockedDependencies(LockedDependencies(
    schema: SolvedGraphLockSchemaV2, platform: Host, optimal: true,
    inputsDigest: inputsDigestOf("diff"),
    packages: @[LockedPackage(name: "nim", version: "2.2.8", source: "nim",
      selection: ssSelected)]).withProvisioningRealizations(records))

proc readBack(records: seq[LockedRealization]): seq[LockedRealization] =
  ## The records as a committed lock hands them back (strict reader).
  parseLockedDependencies(lockText(records)).lockedProvisioningClaims()

proc render(d: ProvisioningLockDiff): string = renderProvisioningDiff(d)

proc resolverTo(id: ContributionIdentity): ContributionResolver =
  ## A resolver binding every dependency to ``id``.
  result = proc (d: ContributionDependencyRef): Option[ContributionIdentity]
      {.gcsafe.} = some(id)

proc splitResolverTo(iface: string; matching, others: ContributionIdentity):
    ContributionResolver =
  ## A resolver binding a dependency on ``iface`` to ``matching`` and every
  ## other dependency to ``others``.
  result = proc (d: ContributionDependencyRef): Option[ContributionIdentity]
      {.gcsafe.} =
    if d.targetInterfaceFingerprint == iface: some(matching) else: some(others)

proc interfacesCatalog(ifaces: seq[(string, string)]): CatalogImport =
  CatalogImport(coordinate: CatalogCoordinate(workspace: Ws,
      remote: PackagesRemote, revision: PackagesRev, interfaceArtifact: Art0),
    discoveredAt: "/w/packages", content: some(CatalogContent(
      canonicalInterfaces: ifaces.mapIt(catalogInterface(it[0], it[1])))))

proc catalog(remote, revision, artifact: string;
             contributions: seq[InterfaceProvisioningContribution]):
    CatalogImport =
  CatalogImport(coordinate: CatalogCoordinate(workspace: Ws, remote: remote,
      revision: revision, interfaceArtifact: artifact),
    discoveredAt: "/w/" & remote.split('/')[^1],
    content: some(CatalogContent(contributions: contributions)))

proc policyFor(contributor: string; pkg = Pkg): CatalogSelectionPolicy =
  CatalogSelectionPolicy(selections: @[CatalogSelectionRule(
    targetPackage: pkg, contributor: contributor)])

proc evidence(previous, current: seq[ContributionIdentity]):
    ProvisioningDiffEvidence =
  ProvisioningDiffEvidence(previous: previous, current: current,
    previousResolver: noContributionResolver,
    currentResolver: noContributionResolver)

proc only(d: ProvisioningLockDiff): ProvisioningRecordChange =
  doAssert not d.refused, d.render
  doAssert d.changes.len == 1, d.render
  d.changes[0]

# ---------------------------------------------------------------------------

suite "provisioning lock diff":

  test "an identical lock, reordered records and a re-read lock all diff to nothing":
    # Pins: key-based matching (order never observable) and that equal
    # records produce no change.
    let other = ident(contribution(B, @[nix(B, "tool-b", NarB, pkg = Pkg2)],
      pkg = Pkg2, iface = Iface2), ProvB)
    let records = @[rec(idA()), rec(other, revision = RevB1, artifact = ArtB),
      rec(idA(), host = OtherHost, target = OtherHost)]
    for (old, new) in [(records, records), (records, records.reversed),
        (records.reversed, readBack(records)),
        (@[records[2], records[0], records[1]], records)]:
      let d = diffProvisioningRecords(old, new)
      check d.unchanged
      check not d.refused
      check d.render == ""
    # Two locks written from the records in different orders are the same
    # document, and so the same records.
    check lockText(records) == lockText(records.reversed)
    # Empty against empty.
    check diffProvisioningRecords(@[], @[]).unchanged

  test "contributor changed":
    let old = rec(idA())
    let new = rec(idB(), revision = RevB1, artifact = ArtB,
      basis = lsrCuratorPolicy)
    let c = diffProvisioningRecords(@[old], @[new]).only
    check c.kind == pckChanged
    check c.causes == @[pccContributorChanged, pccCatalogChanged,
      pccRealizationChanged, pccSelectionBasisChanged]
    check pccContributionChanged notin c.causes
    check c.lines == @[
      "contributor changed: \"" & A & "\" -> \"" & B & "\"",
      "contribution fingerprint: " & fpOf(idA()) & " -> " & fpOf(idB()) &
        " (another contributor's contribution)",
      "catalog remote changed: \"" & A & "\" -> \"" & B & "\"",
      "catalog revision changed: \"" & RevA1 & "\" -> \"" & RevB1 & "\"",
      "catalog interface artifact changed: \"" & ArtA & "\" -> \"" & ArtB &
        "\"",
      "realization changed: lock identity \"" & nixLockId("tool-a", NarA) &
        "\" -> \"" & nixLockId("tool-b", NarB) & "\"",
      "realization changed: integrity \"" & NarA & "\" -> \"" & NarB & "\"",
      "selection basis changed: unique-eligible -> curator-policy"]
    check renderChange(c)[0] == "provisioning \"" & Pkg & "\" on " & Host &
      " -> " & Host & ": changed (contributor-changed, catalog-changed, " &
      "realization-changed, selection-basis-changed)"

  test "realization-only contribution change: verified evidence names the field, no evidence says it cannot tell":
    # The provider identity is a fingerprint input the lock does not
    # record: nothing recorded moves except the fingerprint.
    let old = rec(idA())
    let new = rec(idA(provider = ProvA2))
    check old.contributionFingerprint != new.contributionFingerprint
    let bare = diffProvisioningRecords(@[old], @[new]).only
    check bare.causes == @[pccContributionChanged]
    check not bare.causeDeterminable
    check bare.lines == @[
      "contribution changed (realization-only: the interface is unchanged, " &
        "so typechecking stays valid): " & old.contributionFingerprint &
        " -> " & new.contributionFingerprint,
      "  cause: not determinable from the records -- a lock records the " &
        "contribution fingerprint, not the metadata it was computed from, " &
        "and no identity reproducing the fingerprint of the locked " &
        "contribution or the new contribution was supplied",
      "  no recorded fingerprint input changed (the interface, realization " &
        "lock identity, family and integrity are the same), so the change " &
        "is in metadata the lock does not record: realization fields, the " &
        "provider identity or a dependency"]
    # Never attributed to the catalog, the interface or the realization.
    for wrong in [pccCatalogChanged, pccInterfaceChanged,
        pccRealizationChanged, pccContributorChanged]:
      check wrong notin bare.causes
    let given = diffProvisioningRecords(@[old], @[new],
      evidence(@[idA()], @[idA(provider = ProvA2)])).only
    check given.causeDeterminable
    check given.causes == @[pccContributionChanged]
    check given.lines == @[given.lines[0],
      "  cause (from the two contribution identities, each verified to " &
        "reproduce its record's fingerprint):",
      "    - provider identity: " & ProvA & " -> " & ProvA2]

  test "a realization field change is named by evidence; a recorded input that also moved is only part of the cause":
    # executablePath: not recorded; the catalog artifact moves with the
    # content, but a catalog move is never offered as a fingerprint cause.
    block:
      let old = rec(idA())
      let new = rec(idA(exe = "bin/tool2"), artifact = ArtA2)
      let bare = diffProvisioningRecords(@[old], @[new]).only
      check bare.causes == @[pccContributionChanged, pccCatalogChanged]
      check bare.lines[1].startsWith("  cause: not determinable")
      check bare.lines[2].startsWith("  no recorded fingerprint input changed")
      check bare.lines[3] == "catalog interface artifact changed: \"" &
        ArtA & "\" -> \"" & ArtA2 & "\""
      let given = diffProvisioningRecords(@[old], @[new],
        evidence(@[idA()], @[idA(exe = "bin/tool2")])).only
      check given.lines[1 .. 2] == @[
        "  cause (from the two contribution identities, each verified to " &
          "reproduce its record's fingerprint):",
        "    - nix realization \"" & nixLockId("tool-a", NarA) &
          "\": field executablePath: \"bin/tool\" -> \"bin/tool2\""]
      check given.lines.len == 4
    # nixpkgsNarHash: moves the recorded integrity AND lock identity.
    block:
      let old = rec(idA())
      let new = rec(idA(nar = NarC))
      let bare = diffProvisioningRecords(@[old], @[new]).only
      check bare.causes == @[pccContributionChanged, pccRealizationChanged]
      check bare.lines[2] == "  recorded fingerprint inputs that also " &
        "changed (each accounts for at least part of the change; other " &
        "metadata may have changed too): the realization lock identity, " &
        "the realization integrity"
      let given = diffProvisioningRecords(@[old], @[new],
        evidence(@[idA()], @[idA(nar = NarC)])).only
      check given.lines[2 .. 4] == @[
        "    - nix realization \"" & nixLockId("tool-a", NarA) &
          "\": field nixpkgsNarHash: \"" & NarA & "\" -> \"" & NarC & "\"",
        "    - nix realization \"" & nixLockId("tool-a", NarA) &
          "\": field lockIdentity: \"" & nixLockId("tool-a", NarA) &
          "\" -> \"" & nixLockId("tool-a", NarC) & "\"",
        "realization changed: lock identity \"" & nixLockId("tool-a", NarA) &
          "\" -> \"" & nixLockId("tool-a", NarC) & "\""]

  test "evidence that does not reproduce the locked fingerprint is not used":
    # Pins the verification of evidence: an identity offered for the old
    # record that fingerprints to something else (here: another provider)
    # must not be used to "explain" the change.
    let old = rec(idA())
    let new = rec(idA(nar = NarC))
    let wrong = diffProvisioningRecords(@[old], @[new],
      evidence(@[idA(provider = ProvA2)], @[idA(nar = NarC)])).only
    check not wrong.causeDeterminable
    check wrong.lines[1] == "  cause: not determinable from the records -- " &
      "a lock records the contribution fingerprint, not the metadata it was " &
      "computed from, and no identity reproducing the fingerprint of the " &
      "locked contribution was supplied"
    check wrong.lines.allIt("provider identity" notin it)
    # Evidence for the right fingerprint but another contributor is not
    # used either.
    let foreign = diffProvisioningRecords(@[old], @[new],
      evidence(@[ident(contribution(B, @[nix(A, "tool-a", NarA)]))],
        @[idA(nar = NarC)])).only
    check not foreign.causeDeterminable

  test "interface changed":
    let old = rec(idA())
    let new = rec(idA(iface = IfaceV2))
    let bare = diffProvisioningRecords(@[old], @[new]).only
    check bare.causes == @[pccInterfaceChanged]
    check pccContributionChanged notin bare.causes
    check bare.lines[0] == "interface changed: " & IfaceV1 & " -> " &
      IfaceV2 & " (the package's canonical interface moved: the locked " &
      "selection is incompatible)"
    check bare.lines[1] == "contribution fingerprint changed: " &
      old.contributionFingerprint & " -> " & new.contributionFingerprint &
      " (the interface fingerprint is one of its inputs, and it moved)"
    check bare.lines[3] == "  recorded fingerprint inputs that also " &
      "changed (each accounts for at least part of the change; other " &
      "metadata may have changed too): the interface fingerprint"
    let given = diffProvisioningRecords(@[old], @[new],
      evidence(@[idA()], @[idA(iface = IfaceV2)])).only
    check given.lines[3] == "    - target interface fingerprint: " &
      IfaceV1 & " -> " & IfaceV2
    check given.lines.len == 4

  test "catalog coordinates or revision moved, contribution unchanged":
    let old = rec(idA())
    for (new, line) in [
        (rec(idA(), revision = RevA2), "catalog revision changed: \"" &
          RevA1 & "\" -> \"" & RevA2 & "\""),
        (rec(idA(), workspace = "github:example/other-ws"),
          "catalog workspace changed: \"" & Ws &
          "\" -> \"github:example/other-ws\""),
        (rec(idA(), remote = "github:example/diff-catalog-a-mirror"),
          "catalog remote changed: \"" & A &
          "\" -> \"github:example/diff-catalog-a-mirror\""),
        (rec(idA(), artifact = ArtA2), "catalog interface artifact " &
          "changed: \"" & ArtA & "\" -> \"" & ArtA2 & "\"")]:
      let c = diffProvisioningRecords(@[old], @[new]).only
      check c.causes == @[pccCatalogChanged]
      check c.lines == @["contribution fingerprint unchanged: " &
        old.contributionFingerprint & " (the same contribution, byte for " &
        "byte)", line]

  test "realization lock identity or integrity changed, contribution unchanged":
    # One contribution declaring two realizations; the lock moves from one
    # to the other.
    let two = ident(contribution(A, @[nix(A, "tool-a", NarA),
      nix(A, "tool-a2", NarC)]))
    let old = rec(two, lockId = nixLockId("tool-a", NarA))
    let new = rec(two, lockId = nixLockId("tool-a2", NarC))
    let c = diffProvisioningRecords(@[old], @[new]).only
    check c.causes == @[pccRealizationChanged]
    check c.lines == @[
      "contribution fingerprint unchanged: " & old.contributionFingerprint &
        " (the same contribution, byte for byte)",
      "realization changed: lock identity \"" & nixLockId("tool-a", NarA) &
        "\" -> \"" & nixLockId("tool-a2", NarC) & "\"",
      "realization changed: integrity \"" & NarA & "\" -> \"" & NarC & "\""]

  test "realization family changed under the same lock identity":
    let lid = nixLockId("tool-a", NarA)
    let tarId = ident(InterfaceProvisioningContribution(targetPackage: Pkg,
      targetInterfaceFingerprint: IfaceV1, contributor: A,
      tarballProvisioning: @[InterfaceTarballProvisioning(packageName: Pkg,
        contributor: A, url: "https://example.invalid/t.tar.gz",
        sha256: repeat('f', 64), archiveType: "tar.gz",
        executablePath: "bin/t", lockIdentity: lid)]))
    let old = rec(idA())
    let new = rec(tarId, lockId = lid)
    let c = diffProvisioningRecords(@[old], @[new]).only
    check c.causes == @[pccContributionChanged, pccRealizationChanged]
    check c.lines[2] == "  recorded fingerprint inputs that also changed " &
      "(each accounts for at least part of the change; other metadata may " &
      "have changed too): the realization family, the realization integrity"
    check c.lines[3 .. 4] == @["realization changed: family nix -> tarball",
      "realization changed: integrity \"" & NarA & "\" -> \"" &
        repeat('f', 64) & "\""]

  test "evidence whose fingerprint is not fully bound is not used":
    # A record sealed over a LEAF-PADDED hex (the seal is told no
    # dependency is unbound); the identity that produces that hex binds its
    # dependency by coordinate only, so it is not evidence.
    let dep = ContributionDependencyRef(targetPackage: Pkg2, contributor: B,
      targetInterfaceFingerprint: Iface2)
    let padded = ident(contribution(A, @[nix(A, "tool-a", NarA)]), ProvA,
      @[dep])
    let hex = contributionFingerprint(padded, noContributionResolver).hex
    var draft = rec(idA())
    let old = sealLockedRealization(LockedRealization(
      packageName: draft.packageName,
      interfaceFingerprint: draft.interfaceFingerprint,
      contributor: draft.contributor, contributionFingerprint: hex,
      catalogWorkspace: draft.catalogWorkspace,
      catalogRemote: draft.catalogRemote,
      catalogRevision: draft.catalogRevision,
      catalogInterfaceArtifact: draft.catalogInterfaceArtifact,
      realizationKind: draft.realizationKind,
      realizationLockIdentity: draft.realizationLockIdentity,
      realizationIntegrity: draft.realizationIntegrity, hostPlatform: Host,
      targetPlatform: Host, selectedBy: draft.selectedBy),
      ContributionEvidence(fingerprintHex: hex))
    let c = diffProvisioningRecords(@[old], @[rec(idA(nar = NarC))],
      evidence(@[padded], @[idA(nar = NarC)])).only
    check not c.causeDeterminable
    check c.lines[1] == "  cause: not determinable from the records -- a " &
      "lock records the contribution fingerprint, not the metadata it was " &
      "computed from, and no identity reproducing the fingerprint of the " &
      "locked contribution was supplied"

  test "selection basis and capabilities changed":
    let old = rec(idA(), caps = @["gpu"])
    let new = rec(idA(), basis = lsrCuratorPolicy, caps = @["cuda", "gpu"])
    let c = diffProvisioningRecords(@[old], @[new]).only
    check c.causes == @[pccSelectionBasisChanged, pccCapabilitiesChanged]
    check c.lines == @[
      "contribution fingerprint unchanged: " & old.contributionFingerprint &
        " (the same contribution, byte for byte)",
      "selection basis changed: unique-eligible -> curator-policy",
      "capabilities changed: [\"gpu\"] -> [\"cuda\", \"gpu\"]"]

  test "added, removed, and moved to another platform":
    let a = rec(idA())
    let other = rec(idA(), host = OtherHost, target = OtherHost)
    let d1 = diffProvisioningRecords(@[], @[a])
    check d1.only.kind == pckAdded
    check d1.render == "provisioning \"" & Pkg & "\" on " & Host & " -> " &
      Host & ": added (added)\n  added: contributor \"" & A &
      "\", contribution " & a.contributionFingerprint & ", interface " &
      IfaceV1 & ", catalog (workspace \"" & Ws & "\", remote \"" & A &
      "\", revision " & RevA1 & ", interface artifact " & ArtA &
      "), realization nix \"" & nixLockId("tool-a", NarA) & "\" (integrity " &
      NarA & "), capabilities [], selected by unique-eligible"
    let d2 = diffProvisioningRecords(@[a], @[])
    check d2.only.kind == pckRemoved
    check d2.only.lines[0].startsWith("removed: the lock no longer pins " &
      "contributor \"" & A & "\"")
    let d3 = diffProvisioningRecords(@[a], @[other])
    let m = d3.only
    check m.kind == pckMoved
    check m.causes == @[pccPlatformMoved]
    check renderChange(m) == @[
      "provisioning \"" & Pkg & "\": moved from " & Host & " -> " & Host &
        " to " & OtherHost & " -> " & OtherHost & " (platform-moved)",
      "  moved to another platform: no longer locked for " & Host & " -> " &
        Host & "; now locked for " & OtherHost & " -> " & OtherHost,
      "  contribution fingerprint unchanged: " & a.contributionFingerprint &
        " (the same contribution, byte for byte)",
      "  nothing else in the record changed"]
    # A move that also changes the contributor says both.
    let d4 = diffProvisioningRecords(@[a], @[rec(idB(), revision = RevB1,
      artifact = ArtB, host = OtherHost, target = OtherHost)])
    check d4.only.causes[0 .. 1] == @[pccPlatformMoved, pccContributorChanged]
    # Gaining a second platform is an addition, not a move.
    let d5 = diffProvisioningRecords(@[a], @[a, other])
    check d5.only.kind == pckAdded
    check d5.only.hostPlatform == OtherHost

  test "records for another host are compared on their own key":
    let here = rec(idA())
    let there = rec(idA(), host = OtherHost, target = OtherHost)
    # Only the other host's record changes: the diff names that host only.
    let movedThere = rec(idA(), revision = RevA2, host = OtherHost,
      target = OtherHost)
    let d = diffProvisioningRecords(@[here, there], @[movedThere, here])
    check d.only.hostPlatform == OtherHost
    check d.only.causes == @[pccCatalogChanged]
    # Several changes come out in (package, host, target) order whatever
    # order the records arrive in.
    let pkg2 = ident(contribution(B, @[nix(B, "tool-b", NarB, pkg = Pkg2)],
      pkg = Pkg2, iface = Iface2), ProvB)
    let o2 = rec(pkg2, revision = RevB1, artifact = ArtB)
    let n2 = rec(pkg2, revision = RevA2, artifact = ArtB)
    for old in [@[there, here, o2], @[o2, here, there]]:
      let many = diffProvisioningRecords(old, @[movedThere, rec(idA(),
        revision = RevA2), n2])
      check many.changes.mapIt(it.packageName & "@" & it.hostPlatform) ==
        @[Pkg2 & "@" & Host, Pkg & "@" & Host, Pkg & "@" & OtherHost]
    # A cross-target record (host != target) is its own key too.
    let cross = rec(idA(), host = Host, target = OtherHost)
    check diffProvisioningRecords(@[here], @[here, cross]).only.kind ==
      pckAdded

  test "duplicated and unsealed records refuse the diff; a refused diff is never 'no change'":
    let a = rec(idA())
    let a2 = rec(idA(), revision = RevA2)
    for (old, new) in [(@[a, a2], @[a]), (@[a], @[a, a2]), (@[a, a], @[a, a])]:
      let d = diffProvisioningRecords(old, new)
      check d.refused
      check not d.unchanged
      check d.changes.len == 0
      check "a lock selects exactly one" in d.render
      check d.render.startsWith("provisioning diff refused")
    var edited = a
    edited.catalogRevision = RevA2      # edited after sealing
    let d = diffProvisioningRecords(@[a], @[edited])
    check d.refused
    check not d.unchanged
    check "not read from a committed lock or written by the lock writer" in
      d.render
    # An unsealed record that is otherwise IDENTICAL still refuses: the
    # diff never vouches for a record it cannot trust.
    var unsealedSame = LockedRealization(packageName: a.packageName,
      interfaceFingerprint: a.interfaceFingerprint, contributor: a.contributor,
      contributionFingerprint: a.contributionFingerprint,
      catalogWorkspace: a.catalogWorkspace, catalogRemote: a.catalogRemote,
      catalogRevision: a.catalogRevision,
      catalogInterfaceArtifact: a.catalogInterfaceArtifact,
      realizationKind: a.realizationKind,
      realizationLockIdentity: a.realizationLockIdentity,
      realizationIntegrity: a.realizationIntegrity, hostPlatform: Host,
      targetPlatform: Host, selectedBy: a.selectedBy)
    check diffProvisioningRecords(@[a], @[unsealedSame]).refused

  test "letter-case and whitespace variants are reported, never folded together":
    # A contributor id differing only in case is ANOTHER contributor.
    let upper = "GitHub:example/diff-catalog-a"
    let caseVariant = rec(ident(contribution(upper,
      @[nix(upper, "tool-a", NarA)])), remote = A)
    let c = diffProvisioningRecords(@[rec(idA())], @[caseVariant]).only
    check pccContributorChanged in c.causes
    check c.lines[0] == "contributor changed: \"" & A & "\" -> \"" & upper &
      "\" (the ids differ only in letter case; contributor ids are compared " &
      "exactly, so this is another contributor)"
    # A package name differing only in case is another package: removed +
    # added, with a note -- not "moved", not "no change".
    let other = rec(ident(contribution(A, @[nix(A, "tool-a", NarA,
      pkg = "Diff-Target")], pkg = "Diff-Target")))
    let d = diffProvisioningRecords(@[rec(idA())], @[other])
    check d.changes.len == 2
    check d.changes.mapIt(it.kind).sorted(cmp) == @[pckAdded, pckRemoved]
    check d.render.contains("note: package \"" & Pkg & "\" was removed in " &
      "this diff; the names differ only in letter case and are different " &
      "packages")
    # A whitespace-only realization field change is named as such by the
    # evidence.
    let ws = idA(exe = "bin/tool ")
    let given = diffProvisioningRecords(@[rec(idA())], @[rec(ws)],
      evidence(@[idA()], @[ws])).only
    check given.lines[2] == "    - nix realization \"" &
      nixLockId("tool-a", NarA) & "\": field executablePath: \"bin/tool\" " &
      "-> \"bin/tool \" (differs only in surrounding whitespace)"
    # A record field cannot carry such a variant at all: the seal refuses
    # it, so it can never reach a diff as a silently-equal record.
    expect LockedRealizationError:
      var r = rec(idA())
      r.contributor = A & " "
      discard sealLockedRealization(r, ContributionEvidence(
        fingerprintHex: r.contributionFingerprint))

  test "a contributor or interface that moved under an unchanged fingerprint is reported as inconsistent records":
    # Found by the D5 verifier, probing from outside: a hand-edited record
    # (the strict reader seals what it reads) with another contributor or
    # interface but the old contribution fingerprint was described as "the
    # same contribution, byte for byte". The fingerprint binds both, so the
    # records contradict each other; that is said, and the cause is still
    # the field that moved.
    let old = rec(idA())
    for field in ["contributor id", "interface"]:
      var edited = old
      if field == "interface": edited.interfaceFingerprint = IfaceV2
      else: edited.contributor = B
      let sealed = sealLockedRealization(edited, ContributionEvidence(
        fingerprintHex: edited.contributionFingerprint))
      let c = diffProvisioningRecords(@[old], @[sealed]).only
      check pccContributionChanged notin c.causes
      check (if field == "interface": pccInterfaceChanged
             else: pccContributorChanged) in c.causes
      check not renderChange(c).join("\n").contains(
        "the same contribution, byte for byte")
      check c.lines.contains("contribution fingerprint unchanged: " &
        fpOf(idA()) & ", although the " & field & " it binds changed: the " &
        "two records are inconsistent (a contribution fingerprint binds its " &
        "contributor id and interface), so at least one of them was not " &
        "written by the lock writer from that contribution")

suite "field-level explanation":

  test "every fingerprint input that moved is named, and nothing else":
    let base = ident(contribution(A, @[nix(A, "tool-a", NarA)]))
    template one(changed: ContributionIdentity; expected: seq[string]) =
      let ex = explainContributionChange(base, changed,
        noContributionResolver, noContributionResolver)
      check ex.determinable
      check ex.lines == expected
    var t = base
    t.contribution.nixProvisioning[0].selector = "nixpkgs#tool-x"
    one(t, @["nix realization \"" & nixLockId("tool-a", NarA) &
      "\": field selector: \"nixpkgs#tool-a\" -> \"nixpkgs#tool-x\""])
    t = base
    t.contribution.nixProvisioning[0].expressionFile = "pkgs/tool.nix"
    one(t, @["nix realization \"" & nixLockId("tool-a", NarA) &
      "\": field expressionFile: \"\" -> \"pkgs/tool.nix\""])
    t = base
    t.contribution.nixProvisioning[0].nixpkgsRev = repeat('e', 40)
    one(t, @["nix realization \"" & nixLockId("tool-a", NarA) &
      "\": field nixpkgsRev: \"" & NixpkgsRev & "\" -> \"" &
      repeat('e', 40) & "\""])
    # Letter case of an integrity digest moves the fingerprint (recorded
    # M7 D1 residual) and is said to be case only.
    t = base
    t.contribution.nixProvisioning[0].nixpkgsNarHash = NarA.toLowerAscii()
    one(t, @["nix realization \"" & nixLockId("tool-a", NarA) &
      "\": field nixpkgsNarHash: \"" & NarA & "\" -> \"" &
      NarA.toLowerAscii() & "\" (differs only in letter case)"])
    # A realization added, and one removed.
    t = base
    t.contribution.nixProvisioning.add(nix(A, "tool-b", NarB))
    t.contribution.nixProvisioning.add(InterfaceNixProvisioning(
      packageName: Pkg, contributor: A, selector: "nixpkgs#tool-c",
      nixpkgsRev: NixpkgsRev, nixpkgsNarHash: NarC,
      lockIdentity: nixLockId("tool-c", NarC)))
    one(t, @["nix realization \"" & nixLockId("tool-b", NarB) & "\": added",
      "nix realization \"" & nixLockId("tool-c", NarC) & "\": added"])
    # ...and the other way round: removed.
    check explainContributionChange(t, base, noContributionResolver,
      noContributionResolver).lines == @["nix realization \"" &
      nixLockId("tool-b", NarB) & "\": removed", "nix realization \"" &
      nixLockId("tool-c", NarC) & "\": removed"]
    # Set-valued tarball fields.
    let tar = ident(InterfaceProvisioningContribution(targetPackage: Pkg,
      targetInterfaceFingerprint: IfaceV1, contributor: A,
      tarballProvisioning: @[InterfaceTarballProvisioning(packageName: Pkg,
        contributor: A, url: "https://example.invalid/t.tar.gz",
        mirrors: @["https://m1.invalid/t.tar.gz"], sha256: repeat('f', 64),
        archiveType: "tar.gz", executablePath: "bin/t",
        lockIdentity: "sha256:" & repeat('f', 64))]))
    var tar2 = tar
    tar2.contribution.tarballProvisioning[0].mirrors =
      @["https://m2.invalid/t.tar.gz", "https://m1.invalid/t.tar.gz"]
    tar2.contribution.tarballProvisioning[0].prunePaths = @["share/doc"]
    let ex = explainContributionChange(tar, tar2, noContributionResolver,
      noContributionResolver)
    check ex.lines == @[
      "tarball realization \"sha256:" & repeat('f', 64) & "\": mirrors: " &
        "[\"https://m1.invalid/t.tar.gz\"] -> [\"https://m1.invalid/" &
        "t.tar.gz\", \"https://m2.invalid/t.tar.gz\"]",
      "tarball realization \"sha256:" & repeat('f', 64) & "\": prunePaths: " &
        "[] -> [\"share/doc\"]"]
    # Mirror ORDER is not an input: equal fingerprints, nothing said.
    var tar3 = tar2
    tar3.contribution.tarballProvisioning[0].mirrors.reverse()
    let same = explainContributionChange(tar2, tar3, noContributionResolver,
      noContributionResolver)
    check same.determinable
    check same.previousHex == same.currentHex
    check same.lines.len == 0
    # From-source recipe inputs (a pair set) and its digest.
    let src = ContributionIdentity(contribution: contribution(A, @[]),
      providerIdentity: ProvA, fromSourceProvisioning: @[FromSourceRealization(
        packageName: Pkg, contributor: A, recipePath: "recipes/t.nim",
        recipeDigest: repeat('1', 64), recipeInputs: @[("cc", "gcc")],
        lockIdentity: "recipe:t")])
    var src2 = src
    src2.fromSourceProvisioning[0].recipeInputs = @[("cc", "clang")]
    check explainContributionChange(src, src2, noContributionResolver,
      noContributionResolver).lines == @["from-source realization " &
      "\"recipe:t\": recipeInputs: {\"cc\": \"gcc\"} -> {\"cc\": \"clang\"}"]

  test "contributor id, target package, and realizations sharing one lock identity":
    let base = idA()
    var t = base
    t.contribution.contributor = B
    check explainContributionChange(base, t, noContributionResolver,
      noContributionResolver).lines ==
      @["contributor id: \"" & A & "\" -> \"" & B & "\""]
    t = base
    t.contribution.targetPackage = Pkg2
    check explainContributionChange(base, t, noContributionResolver,
      noContributionResolver).lines ==
      @["target package: \"" & Pkg & "\" -> \"" & Pkg2 & "\""]
    # Two declarations under ONE lock identity cannot be paired; the set
    # difference is still reported, never dropped.
    let shared = ident(contribution(A, @[
      nix(A, "tool-a", NarA, lockId = "nix:shared"),
      nix(A, "tool-b", NarB, lockId = "nix:shared")]))
    var changed = shared
    changed.contribution.nixProvisioning[1] =
      nix(A, "tool-c", NarC, lockId = "nix:shared")
    check explainContributionChange(shared, changed, noContributionResolver,
      noContributionResolver).lines == @["nix realization \"nix:shared\": " &
      "declared 2 time(s) before and 2 time(s) now; declarations sharing " &
      "one lock identity cannot be paired field by field, and their " &
      "encoded set differs"]
    var reordered = shared
    reordered.contribution.nixProvisioning.reverse()
    let same = explainContributionChange(shared, reordered,
      noContributionResolver, noContributionResolver)
    check same.determinable
    check same.lines.len == 0

  test "a realization under a new lock identity is compared field by field":
    let base = ident(contribution(A, @[nix(A, "tool-a", NarA)]))
    var moved = base
    moved.contribution.nixProvisioning[0].lockIdentity = "nix:renamed"
    check explainContributionChange(base, moved, noContributionResolver,
      noContributionResolver).lines == @["nix realization \"" &
      nixLockId("tool-a", NarA) & "\": field lockIdentity: \"" &
      nixLockId("tool-a", NarA) & "\" -> \"nix:renamed\""]

  test "dependencies: added, removed, re-bound, and moved through the resolver":
    let depRef = ContributionDependencyRef(targetPackage: Pkg2,
      contributor: B, targetInterfaceFingerprint: Iface2)
    let depV1 = ident(contribution(B, @[nix(B, "dep", NarB, pkg = Pkg2)],
      pkg = Pkg2, iface = Iface2), ProvB)
    let depV2 = ident(contribution(B, @[nix(B, "dep", NarC, pkg = Pkg2)],
      pkg = Pkg2, iface = Iface2), ProvB)
    let r1 = resolverTo(depV1)
    let r2 = resolverTo(depV2)
    let root = ident(contribution(A, @[nix(A, "tool-a", NarA)]), ProvA,
      @[depRef])
    let noDeps = ident(contribution(A, @[nix(A, "tool-a", NarA)]), ProvA)
    let spelled = "\"" & contributionCoordinate(depRef) & "\""
    check explainContributionChange(noDeps, root, r1, r1).lines ==
      @["dependency " & spelled & ": added"]
    check explainContributionChange(root, noDeps, r1, r1).lines ==
      @["dependency " & spelled & ": removed"]
    let moved = explainContributionChange(root, root, r1, r2)
    check moved.determinable
    check moved.lines == @["dependency " & spelled & ": its contribution " &
      "fingerprint changed: " & fpOf(depV1) & " -> " & fpOf(depV2) &
      " (see that dependency's own contribution for its cause)"]
    # A leaf-bound side is not usable evidence: said, not guessed.
    let leaf = explainContributionChange(root, root, r1,
      noContributionResolver)
    check not leaf.determinable
    check "binds dependencies by coordinate only" in leaf.refusal

  test "a dependency edge whose sub-fingerprint the fingerprint already folds in is not named as a cause":
    # Found by the D5 verifier, probing from outside: the fingerprint folds
    # in the SET of bound sub-fingerprints, so an edge added, removed or
    # re-pointed that binds a sub-fingerprint already in that set moves
    # nothing -- naming it beside the real cause was a misattribution.
    let depRef = ContributionDependencyRef(targetPackage: Pkg2,
      contributor: B, targetInterfaceFingerprint: Iface2)
    let depRef2 = ContributionDependencyRef(targetPackage: Pkg2,
      contributor: B, targetInterfaceFingerprint: IfaceV2)
    let depV1 = ident(contribution(B, @[nix(B, "dep", NarB, pkg = Pkg2)],
      pkg = Pkg2, iface = Iface2), ProvB)
    let r1 = resolverTo(depV1)
    let nixes = @[nix(A, "tool-a", NarA)]
    let one = ident(contribution(A, nixes), ProvA, @[depRef])
    let provider = "provider identity: " & ProvA & " -> " & ProvA2
    for current in [ident(contribution(A, nixes), ProvA2, @[depRef, depRef2]),
                    ident(contribution(A, nixes), ProvA2, @[depRef2])]:
      let ex = explainContributionChange(one, current, r1, r1)
      check ex.determinable
      check ex.lines == @[provider]
    # A re-pointed edge that binds a NEW sub-fingerprint is still named.
    let depV2 = ident(contribution(B, @[nix(B, "dep", NarC, pkg = Pkg2)],
      pkg = Pkg2, iface = IfaceV2), ProvB)
    let split = splitResolverTo(IfaceV2, depV2, depV1)
    let moved = explainContributionChange(one,
      ident(contribution(A, nixes), ProvA, @[depRef, depRef2]), split, split)
    check moved.lines == @["dependency \"" & contributionCoordinate(depRef2) &
      "\": added"]

  test "an identity that does not fingerprint is not evidence":
    var broken = ident(contribution(A, @[nix(A, "tool-a", NarA)]))
    broken.providerIdentity = ""
    let ex = explainContributionChange(broken, idA(), noContributionResolver,
      noContributionResolver)
    check not ex.determinable
    check ex.lines.len == 0
    check "does not fingerprint" in ex.refusal

suite "explicit re-selection":

  proc standardImports(contribA = contribution(A, @[nix(A, "tool-a", NarA)]);
                       revA = RevA1): seq[CatalogImport] =
    @[interfacesCatalog(@[(Pkg, IfaceV1)]),
      catalog(A, revA, ArtA, @[contribA]),
      catalog(B, RevB1, ArtB, @[contribution(B, @[nix(B, "tool-b", NarB)])])]

  proc request(imports: seq[CatalogImport]; incumbent: seq[LockedRealization];
               policy = CatalogSelectionPolicy();
               offered = @[idA(), idB()];
               previous: seq[ContributionIdentity] = @[]):
      ProvisioningReselectionRequest =
    ProvisioningReselectionRequest(imports: imports, policy: policy,
      offered: offered, previous: previous, incumbent: incumbent,
      hostPlatform: Host, targetPlatform: Host)

  proc lockedBy(policy: CatalogSelectionPolicy; imports = standardImports();
                offered = @[idA(), idB()]): LockedRealization =
    let r = reselectProvisioning(request(imports, @[], policy,
      offered = offered), noContributionResolver)
    doAssert r.reselected, r.refusals.join(" | ")
    r.records[0]

  test "re-selection rewrites the records, carries other platforms and prints the diff":
    let incumbentA = lockedBy(policyFor(A))
    check incumbentA.contributor == A
    check incumbentA.selectedBy == lsrCuratorPolicy
    let elsewhere = rec(idA(), host = OtherHost, target = OtherHost)
    let crossTarget = rec(idA(), host = Host, target = OtherHost)
    # The curator now prefers B: re-selection adopts it.
    let r = reselectProvisioning(request(standardImports(),
      readBack(@[incumbentA, elsewhere, crossTarget]), policyFor(B)),
      noContributionResolver)
    check r.reselected
    check r.carriedForward == 2
    check r.records.len == 3
    check r.records.filterIt(it.hostPlatform == OtherHost) == @[elsewhere]
    check r.records.filterIt(it.targetPlatform == OtherHost and
      it.hostPlatform == Host) == @[crossTarget]
    let mine = r.records.filterIt(it.hostPlatform == Host and
      it.targetPlatform == Host)[0]
    check mine.contributor == B
    check mine.isSealed
    check mine.selectedBy == lsrCuratorPolicy
    let c = r.diff.only
    check c.causes[0] == pccContributorChanged
    check renderProvisioningDiff(r.diff).startsWith("provisioning \"" & Pkg &
      "\" on " & Host & " -> " & Host & ": changed (contributor-changed")
    # The records it produced survive the lock codec unchanged.
    check readBack(r.records).mapIt(canonicalRealizationEntry(it)).sorted(
      cmp) == r.records.mapIt(canonicalRealizationEntry(it)).sorted(cmp)

  test "re-selecting an unchanged world changes nothing":
    # The incumbent's capabilities are carried to the re-selected record.
    let incumbent = rec(idA(), caps = @["gpu"], basis = lsrCuratorPolicy)
    let r = reselectProvisioning(request(standardImports(),
      readBack(@[incumbent]), policyFor(A)), noContributionResolver)
    check r.reselected
    check r.diff.unchanged
    check r.records.mapIt(canonicalRealizationEntry(it)) ==
      @[canonicalRealizationEntry(incumbent)]

  test "a republished contribution is re-locked and the diff explains it from evidence":
    let incumbent = lockedBy(policyFor(A))
    let republished = contribution(A, @[nix(A, "tool-a", NarC)])
    let r = reselectProvisioning(request(standardImports(republished, RevA2),
      readBack(@[incumbent]), policyFor(A),
      offered = @[ident(republished), idB()], previous = @[idA()]),
      noContributionResolver)
    check r.reselected
    let c = r.diff.only
    check c.causes == @[pccContributionChanged, pccCatalogChanged,
      pccRealizationChanged]
    check c.causeDeterminable
    check "    - nix realization \"" & nixLockId("tool-a", NarA) &
      "\": field nixpkgsNarHash: \"" & NarA & "\" -> \"" & NarC & "\"" in
      c.lines
    check r.records[0].realizationLockIdentity == nixLockId("tool-a", NarC)

  test "re-selection keeps the locked realization while it is still declared":
    let two = contribution(A, @[nix(A, "tool-a", NarA),
      nix(A, "tool-a2", NarC)])
    let imports = standardImports(two)
    let incumbent = rec(ident(two), lockId = nixLockId("tool-a2", NarC),
      basis = lsrCuratorPolicy)
    let r = reselectProvisioning(request(imports, readBack(@[incumbent]),
      policyFor(A), offered = @[ident(two), idB()]), noContributionResolver)
    check r.reselected
    check r.records[0].realizationLockIdentity == nixLockId("tool-a2", NarC)
    # With no incumbent the choice between two realizations is refused.
    let fresh = reselectProvisioning(request(imports, @[], policyFor(A),
      offered = @[ident(two), idB()]), noContributionResolver)
    check not fresh.reselected
    check fresh.records.len == 0
    check fresh.refusals.anyIt(it.startsWith("realization-choice-ambiguous"))

  test "re-selection refuses on ambiguity and writes nothing, naming the incumbent pin":
    let incumbent = lockedBy(policyFor(A))
    let r = reselectProvisioning(request(standardImports(),
      readBack(@[incumbent])), noContributionResolver)
    check not r.reselected
    check r.records.len == 0
    check r.diff.changes.len == 0
    check r.refusals.anyIt(it.startsWith("unresolved-contribution-ambiguity"))
    check r.refusals.anyIt("the incumbent pins \"" & Pkg & "\" -> \"" & A &
      "\"" in it)

  test "re-selection refuses a contradictory policy":
    let contradictory = CatalogSelectionPolicy(selections: @[
      CatalogSelectionRule(targetPackage: Pkg, contributor: A),
      CatalogSelectionRule(targetPackage: Pkg, contributor: B)])
    let r = reselectProvisioning(request(standardImports(), @[],
      contradictory), noContributionResolver)
    check not r.reselected
    check r.records.len == 0
    check r.refusals.anyIt(it.startsWith("contradictory-curator-policy"))

  test "re-selection refuses unresolved dependencies":
    let dep = ContributionDependencyRef(targetPackage: Pkg2, contributor: B,
      targetInterfaceFingerprint: Iface2)
    let withDep = ident(contribution(A, @[nix(A, "tool-a", NarA)]), ProvA,
      @[dep])
    let r = reselectProvisioning(request(standardImports(), @[], policyFor(A),
      offered = @[withDep, idB()]), noContributionResolver)
    check not r.reselected
    check r.records.len == 0
    check r.refusals.anyIt(it.startsWith("dependencies-not-fully-resolved"))
    # Bound through a resolver, the same contribution locks.
    let depId = ident(contribution(B, @[nix(B, "dep", NarB, pkg = Pkg2)],
      pkg = Pkg2, iface = Iface2), ProvB)
    let bound = reselectProvisioning(request(standardImports(), @[],
      policyFor(A), offered = @[withDep, idB()]), resolverTo(depId))
    check bound.reselected

  test "re-selection refuses a selection the lock writer cannot lock":
    # Composition accepts an abbreviated catalog revision; the writer does
    # not. Nothing is written.
    let imports = @[interfacesCatalog(@[(Pkg, IfaceV1)]),
      catalog(A, "abc1234", ArtA, @[contribution(A, @[nix(A, "tool-a", NarA)])])]
    let r = reselectProvisioning(request(imports, @[], policyFor(A),
      offered = @[idA()]), noContributionResolver)
    check not r.reselected
    check r.records.len == 0
    check r.refusals.len == 1
    check r.refusals[0].startsWith("package \"" & Pkg & "\" (contributor \"" &
      A & "\") cannot be locked: ")
    check "catalog_revision" in r.refusals[0]
    # A contribution with no lockable realization at all.
    let unnamed = contribution(A, @[nix(A, "tool-a", NarA, lockId = "")])
    var unnamedNix = unnamed
    unnamedNix.nixProvisioning[0].lockIdentity = ""
    let r2 = reselectProvisioning(request(@[interfacesCatalog(@[(Pkg,
      IfaceV1)]), catalog(A, RevA1, ArtA, @[unnamedNix])], @[], policyFor(A),
      offered = @[ident(unnamedNix)]), noContributionResolver)
    check not r2.reselected
    check r2.refusals == @["realization-not-lockable: contributor \"" & A &
      "\" declares no realization with a lock identity for package \"" & Pkg &
      "\""]
    # Two declarations sharing one lock identity: the writer refuses it.
    let shared = contribution(A, @[
      nix(A, "tool-a", NarA, lockId = "nix:shared"),
      nix(A, "tool-b", NarB, lockId = "nix:shared")])
    let r3 = reselectProvisioning(request(@[interfacesCatalog(@[(Pkg,
      IfaceV1)]), catalog(A, RevA1, ArtA, @[shared])], @[], policyFor(A),
      offered = @[ident(shared)]), noContributionResolver)
    check not r3.reselected
    check r3.refusals.len == 1
    check "realization-ambiguous" in r3.refusals[0]

  test "re-selection refuses an unreadable incumbent":
    let a = rec(idA())
    for incumbent in [@[a, rec(idA(), revision = RevA2)]]:
      let r = reselectProvisioning(request(standardImports(), incumbent,
        policyFor(A)), noContributionResolver)
      check not r.reselected
      check r.records.len == 0
    var edited = a
    edited.contributor = B
    let r = reselectProvisioning(request(standardImports(), @[edited],
      policyFor(A)), noContributionResolver)
    check not r.reselected

suite "build-time explanation of a refused lock":

  proc resolutionRequest(imports: seq[CatalogImport];
                         claims: seq[LockedRealization];
                         offered: seq[ContributionIdentity];
                         policy = CatalogSelectionPolicy()):
      ProvisioningResolutionRequest =
    ProvisioningResolutionRequest(imports: imports, lockClaims: claims,
      policy: policy, offered: offered, hostPlatform: Host,
      targetPlatform: Host)

  let lockedA = readBack(@[rec(idA(), basis = lsrCuratorPolicy)])

  test "contribution-changed is explained, from evidence when it is supplied":
    let republished = contribution(A, @[nix(A, "tool-a", NarA)])
    let imports = @[interfacesCatalog(@[(Pkg, IfaceV1)]),
      catalog(A, RevA1, ArtA, @[republished])]
    let req = resolutionRequest(imports, lockedA,
      @[ident(republished, ProvA2), idB()])
    let res = resolveProvisioningSelections(req, noContributionResolver)
    check not res.resolved
    check res.refusals.anyIt(it.startsWith("contribution-changed"))
    let bare = explainLockMismatch(req, noContributionResolver)
    check bare.len == 1
    check bare[0].causes == @[pccContributionChanged]
    check not bare[0].causeDeterminable
    let given = explainLockMismatch(req, noContributionResolver, @[idA()])
    check given[0].causeDeterminable
    check given[0].lines[^1] == "    - provider identity: " & ProvA & " -> " &
      ProvA2
    # The resolver's refusal and the explanation agree on the class.
    check renderChange(given[0])[0].endsWith("(contribution-changed)")

  test "a matching lock explains nothing":
    let imports = @[interfacesCatalog(@[(Pkg, IfaceV1)]),
      catalog(A, RevA1, ArtA, @[contribution(A, @[nix(A, "tool-a", NarA)])])]
    let req = resolutionRequest(imports, lockedA, @[idA()])
    check resolveProvisioningSelections(req, noContributionResolver).resolved
    check explainLockMismatch(req, noContributionResolver).len == 0

  test "a moved catalog revision is explained as a catalog move only":
    let imports = @[interfacesCatalog(@[(Pkg, IfaceV1)]),
      catalog(A, RevA2, ArtA, @[contribution(A, @[nix(A, "tool-a", NarA)])])]
    let req = resolutionRequest(imports, lockedA, @[idA(), idB()])
    let ex = explainLockMismatch(req, noContributionResolver)
    check ex.len == 1
    check ex[0].causes == @[pccCatalogChanged]
    check ex[0].lines == @["contribution fingerprint unchanged: " &
      lockedA[0].contributionFingerprint & " (the same contribution, byte " &
      "for byte)", "catalog revision changed: \"" & RevA1 & "\" -> \"" &
      RevA2 & "\""]

  test "an interface change the contributor did not follow, and a contributor that left":
    # The canonical interface moved; A still offers the old one, so the
    # composition refuses and there is no lock selection to compare.
    let imports = @[interfacesCatalog(@[(Pkg, IfaceV2)]),
      catalog(A, RevA1, ArtA, @[contribution(A, @[nix(A, "tool-a", NarA)])])]
    let ex = explainLockMismatch(resolutionRequest(imports, lockedA, @[idA()]),
      noContributionResolver)
    check ex.len == 1
    check ex[0].causes == @[pccInterfaceChanged]
    check ex[0].lines[0] == "interface changed: " & IfaceV1 & " -> " &
      IfaceV2 & " (the package's canonical interface moved: the locked " &
      "selection is incompatible)"
    check ex[0].lines[1] == "contributor \"" & A & "\" offers it at " &
      "interface " & IfaceV1 & " from catalog " &
      catalogCoordinateKey(imports[1].coordinate)
    # A is gone; only B offers the package.
    let onlyB = @[interfacesCatalog(@[(Pkg, IfaceV1)]),
      catalog(B, RevB1, ArtB, @[contribution(B, @[nix(B, "tool-b", NarB)])])]
    let gone = explainLockMismatch(resolutionRequest(onlyB, lockedA, @[idB()]),
      noContributionResolver)
    check gone.len == 1
    check gone[0].causes == @[pccNotOffered]
    check gone[0].lines == @["the locked contributor \"" & A & "\" offers no " &
      "contribution for the package in any imported catalog; offered by: \"" &
      B & "\""]

  test "no canonical interface, several canonical interfaces, nobody offering":
    let contribs = @[contribution(A, @[nix(A, "tool-a", NarA)])]
    let noIface = explainLockMismatch(resolutionRequest(
      @[catalog(A, RevA1, ArtA, contribs)], lockedA, @[idA()]),
      noContributionResolver)
    check noIface.len == 1
    check noIface[0].causes.len == 0
    check noIface[0].lines[0] == "no imported catalog declares a canonical " &
      "interface for the package"
    check renderChange(noIface[0])[0] == "provisioning \"" & Pkg & "\" on " &
      Host & " -> " & Host & ": changed"
    check noIface[0].lines[^1] == "the composed catalogs refused (see the " &
      "refusals above), so the locked record could not be compared further"
    var second = interfacesCatalog(@[(Pkg, IfaceV2)])
    second.coordinate.remote = "github:example/diff-packages-2"
    let twoIfaces = explainLockMismatch(resolutionRequest(
      @[interfacesCatalog(@[(Pkg, IfaceV1)]), second,
        catalog(A, RevA1, ArtA, contribs)], lockedA, @[idA()]),
      noContributionResolver)
    check twoIfaces[0].lines[0] == "the imported catalogs declare 2 " &
      "canonical interfaces for the package: " & IfaceV1 & ", " & IfaceV2
    check pccInterfaceChanged notin twoIfaces[0].causes
    let nobody = explainLockMismatch(resolutionRequest(
      @[interfacesCatalog(@[(Pkg, IfaceV1)])], lockedA, @[]),
      noContributionResolver)
    check nobody[0].causes == @[pccNotOffered]
    check nobody[0].lines == @["the locked contributor \"" & A & "\" " &
      "offers no contribution for the package in any imported catalog; no " &
      "contributor offers it"]

  test "only sealed claims for this platform pair are explained, in package order":
    let imports = @[interfacesCatalog(@[(Pkg, IfaceV1), (Pkg2, Iface2)]),
      catalog(A, RevA2, ArtA, @[contribution(A, @[nix(A, "tool-a", NarA)])]),
      catalog(B, RevA2, ArtB, @[contribution(B, @[nix(B, "tool-b", NarB,
        pkg = Pkg2)], pkg = Pkg2, iface = Iface2)])]
    let pkg2 = ident(contribution(B, @[nix(B, "tool-b", NarB, pkg = Pkg2)],
      pkg = Pkg2, iface = Iface2), ProvB)
    let claims = readBack(@[rec(idA()), rec(pkg2, revision = RevB1,
      artifact = ArtB)])
    for order in [claims, claims.reversed]:
      let ex = explainLockMismatch(resolutionRequest(imports, order,
        @[idA(), pkg2]), noContributionResolver)
      check ex.mapIt(it.packageName) == @[Pkg2, Pkg]
    # A claim for another platform pair is not this build's business.
    let elsewhere = readBack(@[rec(idA(), host = OtherHost,
      target = OtherHost)])
    check explainLockMismatch(resolutionRequest(imports, elsewhere,
      @[idA()]), noContributionResolver).len == 0
    # A claim edited after sealing is the resolver's refusal, not a record
    # to compare.
    var edited = readBack(@[rec(idA())])
    edited[0].catalogRevision = RevB1
    check explainLockMismatch(resolutionRequest(imports, edited,
      @[idA()]), noContributionResolver).len == 0

  test "the offered identity must fingerprint, fully bound, to one value":
    let imports = @[interfacesCatalog(@[(Pkg, IfaceV1)]),
      catalog(A, RevA1, ArtA, @[contribution(A, @[nix(A, "tool-a", NarA)])])]
    # Not fully bound: never compared, never "contribution-changed".
    let dep = ContributionDependencyRef(targetPackage: Pkg2, contributor: B,
      targetInterfaceFingerprint: Iface2)
    let unbound = explainLockMismatch(resolutionRequest(imports, lockedA,
      @[ident(contribution(A, @[nix(A, "tool-a", NarA)]), ProvA, @[dep])]),
      noContributionResolver)
    check unbound.len == 1
    check unbound[0].causes.len == 0
    check unbound[0].lines[^1] == "the offered identity's contribution " &
      "fingerprint refuses or is not fully resolved"
    # Two identities for the selected record that disagree.
    let two = explainLockMismatch(resolutionRequest(imports, lockedA,
      @[idA(), idA(provider = ProvA2)]), noContributionResolver)
    check two.len == 1
    check two[0].causes.len == 0
    check two[0].lines[^1] == "the offered identities for the selected " &
      "record fingerprint to 2 different values"

  test "a locked realization the offered contribution no longer declares":
    let republished = contribution(A, @[nix(A, "tool-a", NarC)])
    let imports = @[interfacesCatalog(@[(Pkg, IfaceV1)]),
      catalog(A, RevA1, ArtA, @[republished])]
    let ex = explainLockMismatch(resolutionRequest(imports, lockedA,
      @[ident(republished)]), noContributionResolver)
    check ex.len == 1
    check ex[0].causes == @[pccContributionChanged, pccRealizationChanged]
    check ex[0].lines[^1] == "the offered contribution declares the locked " &
      "realization \"" & nixLockId("tool-a", NarA) & "\" 0 time(s)"
    # Declared twice under the locked lock identity: not one realization.
    let twice = contribution(A, @[nix(A, "tool-a", NarA),
      nix(A, "tool-a2", NarB, lockId = nixLockId("tool-a", NarA))])
    let ex2 = explainLockMismatch(resolutionRequest(@[interfacesCatalog(
      @[(Pkg, IfaceV1)]), catalog(A, RevA1, ArtA, @[twice])], lockedA,
      @[ident(twice)]), noContributionResolver)
    check ex2.len == 1
    check pccRealizationChanged in ex2[0].causes
    check ex2[0].lines[^1] == "the offered contribution declares the locked " &
      "realization \"" & nixLockId("tool-a", NarA) & "\" 2 time(s)"

  test "an offered identity that cannot be fingerprinted is not compared":
    let imports = @[interfacesCatalog(@[(Pkg, IfaceV1)]),
      catalog(A, RevA1, ArtA, @[contribution(A, @[nix(A, "tool-a", NarA)])])]
    let ex = explainLockMismatch(resolutionRequest(imports, lockedA, @[]),
      noContributionResolver)
    check ex.len == 1
    check pccContributionChanged notin ex[0].causes
    check ex[0].lines == @["contribution: the offered contribution has no " &
      "computable fingerprint, so it cannot be compared with the locked " &
      lockedA[0].contributionFingerprint, "no full identity is offered for " &
      "the selected record, so its contribution fingerprint cannot be " &
      "computed"]

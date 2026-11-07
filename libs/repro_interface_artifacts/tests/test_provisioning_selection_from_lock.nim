## M7 deliverable 3 -- the provisioning resolver's guards, one case per
## guard family, each case naming what it pins.
##
## ``ReproOS-Campaign-Completion.milestones.org`` § M7; normative design
## ``reprobuild-specs/Provisioning-Contributions.md`` § Resolution and
## § Locks And Snapshots. The end-to-end acceptance (a committed lock file,
## the engine realizing the locked contributor, build keys moving) is
## ``tests/integration/t_e2e_locked_provisioning_contributor_selection``;
## this file drives ``resolveProvisioningSelections``, ``composeCatalogs``
## with lock pins, ``lockSelectedRealization`` and ``applyProvisioningPins``
## directly, through inputs that suite cannot reach -- including a
## hand-edited committed lock, which the strict reader ACCEPTS whenever the
## edit keeps the canonical spelling.
##
## No mocks: packages come from the real DSL, contributions are lifted by
## the real ``toProjectInterface``, locks go through the real ``repro_lock``
## codec.

import std/[options, sequtils, strutils, unittest]

import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_interface_artifacts/contribution_fingerprint
import repro_interface_artifacts/contribution_lock
import repro_interface_artifacts/contribution_selection
import repro_interface_artifacts/provisioning_pins
import repro_lock
import repro_project_dsl

package selTarget:
  executable selTarget:
    name "sel-target"
    cli:
      subcmd "run":
        flag verbose, bool

package selHelper:
  executable selHelper:
    name "sel-helper"
    cli:
      subcmd "run":
        flag quiet, bool

package selCatalog:
  defaultToolProvisioning "nix"
  uses:
    "selTarget"
    "selHelper"

const
  A = "github:example/sel-catalog-a"
  B = "github:example/sel-catalog-b"
  PackagesRemote = "github:example/sel-packages"
  Workspace = "github:example/sel-workspace"
  PackagesRev = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
  RevA = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
  RevB = "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3"
  NixpkgsRev = "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"
  NarA = "sha256-" & repeat('A', 43) & "="
  NarB = "sha256-" & repeat('B', 43) & "="
  NarC = "sha256-" & repeat('C', 43) & "="
  ProviderA = repeat('a', 64)
  ProviderB = repeat('b', 64)
  Host = "amd64-linux"
  Target = "amd64-linux"

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

proc canonical(name: string): string =
  canonicalPackageInterfaceFingerprint(findPackage(name), registeredPackages())

proc nixLockIdentity(selector, narHash: string): string =
  "github:NixOS/nixpkgs/" & NixpkgsRev & "?narHash=" & narHash & "#" &
    selector["nixpkgs#".len .. ^1]

proc lifted(targetPackage, contributor, selector, narHash: string;
            line = 1): InterfaceProvisioningContribution =
  let def = ProvisioningContributionDef(
    targetPackage: targetPackage,
    targetInterfaceFingerprint: canonical(targetPackage),
    contributor: contributor,
    nixProvisioning: @[NixPackageProvisioningDef(
      selector: selector, executablePath: "bin/tool",
      nixpkgsRef: "github:NixOS/nixpkgs", nixpkgsRev: NixpkgsRev,
      nixpkgsNarHash: narHash, packageId: "tool@1",
      lockIdentity: nixLockIdentity(selector, narHash))],
    sourceFile: "catalogs/" & contributor.split('/')[^1] & ".nim",
    sourceLine: line)
  toProjectInterface(findPackage("selCatalog"), registeredPackages(),
    @[def]).provisioningContributions[0]

proc recA(narHash = NarA): InterfaceProvisioningContribution =
  lifted("selTarget", A, "nixpkgs#tool-a", narHash, 10)
proc recB(): InterfaceProvisioningContribution =
  lifted("selTarget", B, "nixpkgs#tool-b", NarB, 20)
proc recHelper(): InterfaceProvisioningContribution =
  lifted("selHelper", B, "nixpkgs#helper", NarB, 30)

proc artifactIdentityOf(content: CatalogContent): string =
  var pi = toProjectInterface(findPackage("selCatalog"), registeredPackages(),
    @[])
  pi.provisioningContributions = content.contributions
  catalogArtifactIdentity(@[artifactFor(pi)])

proc catalogAt(remote, revision: string;
               contributions: seq[InterfaceProvisioningContribution];
               workspace = Workspace; artifact = ""): CatalogImport =
  let content = CatalogContent(contributions: contributions)
  CatalogImport(
    coordinate: CatalogCoordinate(workspace: workspace, remote: remote,
      revision: revision,
      interfaceArtifact:
        if artifact.len > 0: artifact else: artifactIdentityOf(content)),
    discoveredAt: "/w/" & remote.split('/')[^1],
    content: some(content))

proc interfaces(): CatalogImport =
  let content = CatalogContent(canonicalInterfaces: @[
    catalogInterface("selTarget", canonical("selTarget")),
    catalogInterface("selHelper", canonical("selHelper"))])
  CatalogImport(
    coordinate: CatalogCoordinate(workspace: Workspace,
      remote: PackagesRemote, revision: PackagesRev,
      interfaceArtifact: artifactIdentityOf(content)),
    discoveredAt: "/w/packages", content: some(content))

proc catA(narHash = NarA; revision = RevA; workspace = Workspace;
          remote = A; artifact = ""): CatalogImport =
  catalogAt(remote, revision, @[recA(narHash)], workspace, artifact)
proc catB(): CatalogImport = catalogAt(B, RevB, @[recB(), recHelper()])

proc idOf(c: InterfaceProvisioningContribution; provider: string;
          deps: seq[ContributionDependencyRef] = @[]): ContributionIdentity =
  ContributionIdentity(contribution: c, providerIdentity: provider,
    dependencies: deps)

proc offeredAll(narHash = NarA): seq[ContributionIdentity] =
  @[idOf(recA(narHash), ProviderA), idOf(recB(), ProviderB),
    idOf(recHelper(), ProviderB)]

proc policy(contributor: string): CatalogSelectionPolicy =
  CatalogSelectionPolicy(selections: @[CatalogSelectionRule(
    targetPackage: "selTarget", contributor: contributor)])

proc resolveWith(imports: seq[CatalogImport];
                 claims: seq[LockedRealization] = @[];
                 pol = CatalogSelectionPolicy();
                 offered = offeredAll();
                 host = Host; target = Target): ProvisioningResolution =
  resolveProvisioningSelections(ProvisioningResolutionRequest(
    imports: imports, lockClaims: claims, policy: pol, offered: offered,
    hostPlatform: host, targetPlatform: target), noContributionResolver)

proc standard(): seq[CatalogImport] = @[interfaces(), catA(), catB()]

proc recordFor(contributor: string; host = Host;
               target = Target): LockedRealization =
  let r = resolveWith(standard(), pol = policy(contributor))
  doAssert r.resolved, r.refusals.join(" | ")
  let s = r.selectionFor("selTarget")
  let outcome = lockSelectedRealization(RealizationLockRequest(
    selection: s.selection, identity: s.identity,
    realizationLockIdentity:
      if contributor == A: nixLockIdentity("nixpkgs#tool-a", NarA)
      else: nixLockIdentity("nixpkgs#tool-b", NarB),
    hostPlatform: host, targetPlatform: target), noContributionResolver)
  doAssert outcome.locked, outcome.refusals.join("; ")
  outcome.record

proc lockText(records: seq[LockedRealization]): string =
  serializeLockedDependencies(LockedDependencies(
    schema: SolvedGraphLockSchemaV2, platform: Host, optimal: true,
    inputsDigest: inputsDigestOf("sel"),
    packages: @[LockedPackage(name: "nim", version: "2.2.8", source: "nim",
      selection: ssSelected)]).withProvisioningRealizations(records))

proc claimsOf(text: string): seq[LockedRealization] =
  parseLockedDependencies(text).lockedProvisioningClaims()

proc text(r: ProvisioningResolution): string = r.refusals.join(" | ")

suite "provisioning selection from the committed lock":

  test "the platform pair must be stated":
    # Pins the platform-missing guard.
    for (h, t) in [("", Target), (Host, ""), ("  ", Target)]:
      let r = resolveWith(standard(), host = h, target = t)
      check not r.resolved
      check "platform-missing" in r.text

  test "a claim for another platform pair is not applied":
    # Pins the host/target filter: a claim locked for another pair must
    # neither select nor refuse here.
    let other = recordFor(A, host = "arm64-linux", target = "arm64-linux")
    let r = resolveWith(standard(), claimsOf(lockText(@[other])))
    check not r.resolved
    check "unresolved-contribution-ambiguity" in r.text
    let here = resolveWith(standard(), claimsOf(lockText(@[other])),
      host = "arm64-linux", target = "arm64-linux")
    check here.resolved
    check here.selectionFor("selTarget").source == pssLock

  test "two claims for one package on one platform pair refuse, in either order":
    # Pins lock-claims-duplicated. The strict reader never yields two, so
    # this is the direct API; sealed records are used so only this guard
    # can refuse.
    let a = recordFor(A)
    let b = recordFor(B)
    let r1 = resolveWith(standard(), @[a, b])
    let r2 = resolveWith(standard(), @[b, a])
    check not r1.resolved
    check "lock-claims-duplicated" in r1.text
    check r1.text == r2.text

  test "a claim that is not sealed refuses":
    # Pins lock-claim-unsealed: a record built or edited in memory is not a
    # committed lock.
    var edited = recordFor(A)
    edited.capabilities = @["avx2"]
    check "lock-claim-unsealed" in resolveWith(standard(), @[edited]).text
    var handBuilt = LockedRealization(packageName: "selTarget",
      contributor: A)
    check "lock-claim-unsealed" in resolveWith(standard(), @[handBuilt]).text
    # Refusals are reported in one order whatever order the claims came in.
    # The two claims name DIFFERENT contributors, so their refusal texts
    # differ and only the final sort makes the two orders agree (with equal
    # texts the de-duplication alone would hide a missing sort).
    let handBuiltB = LockedRealization(packageName: "selTarget",
      contributor: B)
    let both1 = resolveWith(standard(), @[edited, handBuiltB])
    let both2 = resolveWith(standard(), @[handBuiltB, edited])
    check both1.refusals.len == 3   # two unsealed claims + the ambiguity
    check both1.refusals.countIt("lock-claim-unsealed" in it) == 2
    check both1.text == both2.text

  test "a selection without an offered identity refuses":
    # Pins contribution-identity-missing, for a policy selection and for a
    # lock selection.
    let withoutB = offeredAll().filterIt(it.contribution.contributor != B or
      it.contribution.targetPackage != "selTarget")
    let r = resolveWith(standard(), pol = policy(B), offered = withoutB)
    check not r.resolved
    check "contribution-identity-missing" in r.text
    let locked = resolveWith(standard(), claimsOf(lockText(@[recordFor(B)])),
      offered = withoutB)
    check "contribution-identity-missing" in locked.text

  test "a selection whose fingerprint refuses or is not fully bound refuses":
    # Pins the resolver's copy of the writer's gate.
    var unbound = offeredAll()
    unbound[0] = idOf(recA(), ProviderA, @[ContributionDependencyRef(
      targetPackage: "selHelper", contributor: B,
      targetInterfaceFingerprint: canonical("selHelper"))])
    let r = resolveWith(standard(), pol = policy(A), offered = unbound)
    check not r.resolved
    check "dependencies-not-fully-resolved" in r.text
    var noProvider = offeredAll()
    noProvider[0] = idOf(recA(), "")
    let r2 = resolveWith(standard(), pol = policy(A), offered = noProvider)
    check "contribution-fingerprint-refused" in r2.text

  test "two offered identities for one record must agree":
    # Pins contribution-identity-ambiguous; a repeated identical identity is
    # one identity.
    let twice = offeredAll() & @[idOf(recA(), ProviderA)]
    check resolveWith(standard(), pol = policy(A), offered = twice).resolved
    let split = offeredAll() & @[idOf(recA(), ProviderB)]
    let r = resolveWith(standard(), pol = policy(A), offered = split)
    check not r.resolved
    check "contribution-identity-ambiguous" in r.text

  test "every catalog-coordinate component of a lock claim is checked":
    # Pins each component of catalog-changed (the revision is in the e2e
    # suite), and that an upper-case revision spelling is the same revision.
    let claims = claimsOf(lockText(@[recordFor(A)]))
    for moved in [catA(workspace = "github:example/other-workspace"),
                  catA(remote = "github:example/sel-catalog-a-mirror"),
                  catA(artifact = repeat('f', 64))]:
      let r = resolveWith(@[interfaces(), moved, catB()], claims)
      check not r.resolved
      check "catalog-changed" in r.text
    let upper = resolveWith(@[interfaces(), catA(revision = RevA.toUpperAscii),
      catB()], claims)
    check upper.resolved

  test "a hand-edited committed lock the reader accepts is refused by the resolver":
    # Pins realization-changed and the contribution check against edits
    # that keep the canonical spelling, so the strict reader accepts them.
    let original = lockText(@[recordFor(A)])
    check claimsOf(original).len == 1
    # Only the integrity field: the lock identity spells the NAR hash too.
    let integrityEdit = original.replace(
      "realization_integrity = \"" & NarA & "\"",
      "realization_integrity = \"" & NarC & "\"")
    check integrityEdit != original
    check claimsOf(integrityEdit).len == 1   # the reader accepts it
    let r1 = resolveWith(standard(), claimsOf(integrityEdit))
    check not r1.resolved
    check "realization-changed" in r1.text
    # All or nothing: selHelper alone would resolve, but nothing is handed
    # out while any package refuses.
    check r1.selections.len == 0
    let lockIdEdit = original.replace(
      "realization_lock_identity = \"" & nixLockIdentity("nixpkgs#tool-a", NarA),
      "realization_lock_identity = \"" & nixLockIdentity("nixpkgs#tool-z", NarA))
    check lockIdEdit != original
    let r2 = resolveWith(standard(), claimsOf(lockIdEdit))
    check "realization-changed" in r2.text
    let kindEdit = original.replace("realization = \"nix\"",
      "realization = \"from-source\"")
    check kindEdit != original
    let r3 = resolveWith(standard(), claimsOf(kindEdit))
    check "realization-changed" in r3.text
    # Re-pointing the contributor alone: B is offered, but not at the locked
    # contribution fingerprint.
    let contributorEdit = original.replace("contributor = \"" & A & "\"",
      "contributor = \"" & B & "\"")
    let r4 = resolveWith(standard(), claimsOf(contributorEdit))
    check not r4.resolved
    check "contribution-changed" in r4.text
    # A realization lock identity the contribution declares TWICE (same
    # kind, same integrity): everything else matches, but the lock pins
    # exactly one realization, so this refuses rather than taking either.
    let lockedId = nixLockIdentity("nixpkgs#tool-a", NarA)
    let dupId = nixLockIdentity("nixpkgs#tool-a-dup", NarA)
    proc nixDef(selector, lockIdentity: string): NixPackageProvisioningDef =
      NixPackageProvisioningDef(selector: selector, executablePath: "bin/tool",
        nixpkgsRef: "github:NixOS/nixpkgs", nixpkgsRev: NixpkgsRev,
        nixpkgsNarHash: NarA, packageId: "tool@1", lockIdentity: lockIdentity)
    let twiceDef = ProvisioningContributionDef(targetPackage: "selTarget",
      targetInterfaceFingerprint: canonical("selTarget"), contributor: A,
      nixProvisioning: @[nixDef("nixpkgs#tool-a", lockedId),
        nixDef("nixpkgs#tool-a-dup", dupId),
        nixDef("nixpkgs#tool-a-dup2", dupId)],
      sourceFile: "catalogs/sel-catalog-a.nim", sourceLine: 10)
    let twice = toProjectInterface(findPackage("selCatalog"),
      registeredPackages(), @[twiceDef]).provisioningContributions[0]
    let twiceImports = @[interfaces(), catalogAt(A, RevA, @[twice]), catB()]
    let twiceOffered = @[idOf(twice, ProviderA), idOf(recB(), ProviderB),
      idOf(recHelper(), ProviderB)]
    let twiceSel = resolveWith(twiceImports, pol = policy(A),
      offered = twiceOffered).selectionFor("selTarget")
    let twiceLocked = lockSelectedRealization(RealizationLockRequest(
      selection: twiceSel.selection, identity: twiceSel.identity,
      realizationLockIdentity: lockedId, hostPlatform: Host,
      targetPlatform: Target), noContributionResolver)
    check twiceLocked.locked
    let twiceText = lockText(@[twiceLocked.record])
    check resolveWith(twiceImports, claimsOf(twiceText),
      offered = twiceOffered).resolved
    let dupEdit = twiceText.replace(
      "realization_lock_identity = \"" & lockedId,
      "realization_lock_identity = \"" & dupId)
    check dupEdit != twiceText
    let r5 = resolveWith(twiceImports, claimsOf(dupEdit),
      offered = twiceOffered)
    check not r5.resolved
    check "realization-changed" in r5.text
    check "2 time(s)" in r5.text

  test "contradictory lock pins refuse with one diagnostic, in either order":
    # Pins contradictory-lock-pins, and that a contradictory package derives
    # nothing else from either pin.
    let pinsAB = @[CatalogLockPin(targetPackage: "selTarget", contributor: A),
                   CatalogLockPin(targetPackage: "selTarget", contributor: B)]
    let c1 = composeCatalogs(standard(), CatalogSelectionPolicy(), pinsAB)
    let c2 = composeCatalogs(standard(), CatalogSelectionPolicy(),
      @[pinsAB[1], pinsAB[0]])
    check c1.refused
    check c1.diagnostics.mapIt(it.kind) == @[cdContradictoryLock]
    check c1.diagnosticReport == c2.diagnosticReport
    let withAbsent = @[CatalogLockPin(targetPackage: "selTarget",
      contributor: "github:example/absent"), pinsAB[0]]
    for order in [withAbsent, @[withAbsent[1], withAbsent[0]]]:
      let c = composeCatalogs(standard(), CatalogSelectionPolicy(), order)
      check c.diagnostics.mapIt(it.kind) == @[cdContradictoryLock]

  test "a lock pin outranks the policy inside composition and is never relaxed":
    let pin = @[CatalogLockPin(targetPackage: "selTarget", contributor: A)]
    let c = composeCatalogs(standard(), policy(B), pin)
    check not c.refused
    let s = c.selections.filterIt(it.targetPackage == "selTarget")[0]
    check s.contributor == A
    check s.reason == csLock
    # Unique-eligible packages are unaffected by another package's pin.
    check c.selections.filterIt(it.targetPackage == "selHelper")[0].reason ==
      csUniqueEligible
    # A pin whose package has NO eligible contribution: exactly the lock
    # diagnostic, not a second policy one.
    let bare = composeCatalogs(@[interfaces()], policy(A), pin)
    check bare.diagnostics.mapIt(it.kind) == @[cdLockedContributionUnavailable]

  test "a lock pin with two eligible contributions from its contributor refuses":
    let twoOfA = @[interfaces(), catA(),
      catalogAt("github:example/sel-catalog-a-fork", RevB, @[recA(NarC)]),
      catB()]
    let c = composeCatalogs(twoOfA, CatalogSelectionPolicy(),
      @[CatalogLockPin(targetPackage: "selTarget", contributor: A)])
    check c.refused
    check "from the locked contributor" in c.diagnosticReport

  test "the lock writer refuses to re-lock a selection the lock made":
    let r = resolveWith(standard(), claimsOf(lockText(@[recordFor(A)])))
    check r.resolved
    let s = r.selectionFor("selTarget")
    check s.source == pssLock
    let outcome = lockSelectedRealization(RealizationLockRequest(
      selection: s.selection, identity: s.identity,
      realizationLockIdentity: nixLockIdentity("nixpkgs#tool-a", NarA),
      hostPlatform: Host, targetPlatform: Target), noContributionResolver)
    check not outcome.locked
    check outcome.refusals.anyIt("selection-already-locked" in it)

  test "pins are checked against the consumer artifact before they are stamped":
    # Pins the engine-side guards of applyProvisioningPins that the e2e
    # suite does not reach: padded names, a digest that is not lower-case
    # hex, a use that arrives already pinned, a record whose realizations
    # the use does not carry, and stamping only the pinned package.
    let pi = toProjectInterface(findPackage("selCatalog"), registeredPackages(),
      @[])
    var consumer = pi
    consumer.provisioningContributions = @[recA(), recB(), recHelper()]
    for useDef in consumer.toolUses.mitems:
      for c in consumer.provisioningContributions:
        if c.targetPackage == useDef.packageSelector:
          useDef.nixProvisioning.add(c.nixProvisioning)
    let r = resolveWith(standard(), pol = policy(A))
    let pins = r.pinsOf
    let stamped = applyProvisioningPins(consumer, pins)
    for useDef in stamped:
      check useDef.provisioningPin ==
        pins.filterIt(it.packageName == useDef.packageSelector)[0]
    let onlyTarget = applyProvisioningPins(consumer,
      pins.filterIt(it.packageName == "selTarget"))
    for useDef in onlyTarget:
      check useDef.provisioningPin.isPinned ==
        (useDef.packageSelector == "selTarget")

    proc refusal(pi: ProjectInterface; pins: seq[ProvisioningPin]): string =
      try:
        discard applyProvisioningPins(pi, pins)
        ""
      except ProvisioningPinError as err:
        err.msg

    let good = pins.filterIt(it.packageName == "selTarget")[0]
    var padded = good
    padded.packageName = " selTarget"
    check "package name is empty or padded" in refusal(consumer, @[padded])
    var paddedC = good
    paddedC.contributor = A & " "
    check "contributor is empty or padded" in refusal(consumer, @[paddedC])
    var upperDigest = good
    upperDigest.contributionRecordDigest =
      good.contributionRecordDigest.toUpperAscii()
    check "record digest is not 64 lower-case hex" in
      refusal(consumer, @[upperDigest])
    var upperFp = good
    upperFp.contributionFingerprint = good.contributionFingerprint.toUpperAscii()
    check "contribution fingerprint is not 64 lower-case hex" in
      refusal(consumer, @[upperFp])
    check "a zero provisioning pin" in refusal(consumer, @[ProvisioningPin()])
    var prePinned = consumer
    prePinned.toolUses[0].provisioningPin = good
    check "already carries a provisioning pin" in refusal(prePinned, @[])
    var drifted = consumer
    for useDef in drifted.toolUses.mitems:
      if useDef.packageSelector == "selTarget":
        for p in useDef.nixProvisioning.mitems:
          if p.contributor == A:
            p.selector = "nixpkgs#tool-drifted"
    check "does not carry the realizations of" in refusal(drifted, @[good])
    var missing = consumer
    for useDef in missing.toolUses.mitems:
      if useDef.packageSelector == "selTarget":
        useDef.nixProvisioning = useDef.nixProvisioning.filterIt(
          it.contributor != A)
    check "does not carry the realizations of" in refusal(missing, @[good])
    # The locked realization: a policy pin names none, a lock pin names the
    # record's, and the artifact's record must declare it exactly once.
    check good.realizationLockIdentity == ""
    let lockPins = resolveWith(standard(),
      claimsOf(lockText(@[recordFor(A)]))).pinsOf
    let lockGood = lockPins.filterIt(it.packageName == "selTarget")[0]
    check lockGood.realizationLockIdentity ==
      nixLockIdentity("nixpkgs#tool-a", NarA)
    check applyProvisioningPins(consumer, @[lockGood]).anyIt(
      it.provisioningPin == lockGood)
    var undeclared = lockGood
    undeclared.realizationLockIdentity = nixLockIdentity("nixpkgs#tool-z", NarA)
    check "declares that realization 0 time(s)" in
      refusal(consumer, @[undeclared])
    var paddedR = lockGood
    paddedR.realizationLockIdentity = lockGood.realizationLockIdentity & " "
    check "realization lock identity is padded" in
      refusal(consumer, @[paddedR])

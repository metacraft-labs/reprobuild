## ``e2e_locked_provisioning_contributor_selection`` -- ReproOS-Campaign-
## Completion M7 verification entry, deliverables 3 and (the fail-closed
## half of) 4:
##
##   Two eligible contributors are resolved unambiguously by a committed
##   lock and remain pinned across import-order and branch-tip changes.
##
## Normative design: ``reprobuild-specs/Provisioning-Contributions.md``
## § Resolution and § Locks And Snapshots.
##
## ## The chain exercised, with no mocks
##
##   package DSL  ->  toProjectInterface (the consumer's interface artifact,
##   carrying both contributions)  ->  composeCatalogs over explicitly
##   identified catalog imports  ->  resolveProvisioningSelections (lock,
##   else curator policy, else unique, else refuse)  ->
##   lockSelectedRealization  ->  serializeLockedDependencies, written to a
##   ``repro.lock`` file on disk and read back with parseLockedDependencies
##   ->  lockedProvisioningClaims  ->  resolveProvisioningSelections again,
##   from the committed lock  ->  pinsOf  ->  toolBuildIdentity(tpmTarball),
##   which REALIZES the selected contributor's archive into a real local
##   store and returns the tool profile and typed-tool action identities the
##   engine keys build edges on.
##
## Each contributor's realization is a real ``tar.gz`` built in the test and
## served from a ``file://`` URL, so "which contributor was realized" is
## read back from the realized executable's bytes, not inferred.
##
## ## What this does NOT cover
##
##   * The ``repro`` binary. No CLI path reads a committed lock's
##     ``provisioning`` records and passes pins to ``toolBuildIdentity`` yet
##     (``repro_cli_support`` calls it without pins, so an ambiguous pair
##     still refuses there, and its tool-identity cache key does not bind
##     pins). Discovering catalogs from published repositories (M6
##     deliverable 2) and obtaining each offered contribution's provider
##     identity are the caller's job here; nothing in production supplies
##     them yet.
##   * Linux. Built and run on Windows only.
##   * Nix and Scoop realization (the tarball family is the one that
##     realizes on every host); their planners share ``selectContributor``
##     and ``contributorLockIdentity`` with the tarball planner.
##   * Lock refresh re-selection and diff diagnostics (deliverable 5): the
##     "refresh" below is done by hand -- drop the stale record, re-resolve
##     under the curator policy, lock the new selection.

import std/[algorithm, options, os, osproc, sequtils, strutils, tempfiles,
            unittest]

import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_interface_artifacts/contribution_fingerprint
import repro_interface_artifacts/contribution_lock
import repro_interface_artifacts/contribution_selection
import repro_interface_artifacts/provisioning_pins
import repro_lock
import repro_project_dsl
import repro_tool_profiles

package lockedTool:
  executable lockedTool:
    name "locked-tool"
    cli:
      subcmd "run":
        flag verbose, bool

package lockedToolConsumer:
  defaultToolProvisioning "tarball"
  uses:
    "lockedTool"

const
  ContributorA = "github:example/locked-tool-catalog-a"
  ContributorB = "github:example/locked-tool-catalog-b"
  PackagesRemote = "github:example/locked-tool-packages"
  RemoteA = "github:example/locked-tool-catalog-a"
  RemoteB = "github:example/locked-tool-catalog-b"
  Workspace = "github:example/locked-tool-workspace"
  PackagesRev = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
  RevA1 = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
  RevA2 = "b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3"
  RevB1 = "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3"
  RevB2 = "c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4"
  ProviderA = repeat('a', 64)
  ProviderA2 = repeat('d', 64)
  ProviderB = repeat('b', 64)
  ProviderB2 = repeat('e', 64)
  ToolPackage = "lockedTool"

let Host = currentPlatformId()
let Target = currentPlatformId()

# ---------------------------------------------------------------------------
# Real archives, one per contributor "tip"
# ---------------------------------------------------------------------------

var fixtureRoot = ""

proc executableRelPath(): string =
  when defined(windows): "bin/locked-tool.cmd" else: "bin/locked-tool"

type Archive = object
  url: string
  sha256: string
  marker: string

proc buildArchive(name, marker: string): Archive =
  ## A ``tar.gz`` whose ``bin/locked-tool`` prints ``marker``.
  let payload = fixtureRoot / ("payload-" & name)
  let top = payload / "locked-tool-1.0.0"
  createDir(top / "bin")
  let tool = top / executableRelPath()
  when defined(windows):
    writeFile(tool, "@echo off\r\necho " & marker & "\r\n")
  else:
    writeFile(tool, "#!/bin/sh\necho " & marker & "\n")
    setFilePermissions(tool, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  let archive = fixtureRoot / (name & ".tar.gz")
  var tarExe = "tar"
  when defined(windows):
    let systemTar = getEnv("SystemRoot", r"C:\Windows") / "System32" /
      "tar.exe"
    tarExe = if fileExists(systemTar): systemTar else: findExe("tar")
  let res = execCmdEx(quoteShell(tarExe) & " -czf " & quoteShell(archive) &
    " -C " & quoteShell(payload) & " locked-tool-1.0.0")
  doAssert res.exitCode == 0, "tar failed: " & res.output
  Archive(url: "file://" & archive.replace('\\', '/'),
    sha256: fileSha256Hex(archive).toLowerAscii(), marker: marker)

var archiveA1, archiveA2, archiveB1, archiveB2: Archive

# ---------------------------------------------------------------------------
# Contributions, catalogs, the consumer artifact
# ---------------------------------------------------------------------------

proc findPackage(name: string; packages: seq[PackageDef]): PackageDef =
  for pkg in packages:
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

proc tarballDef(archive: Archive): TarballProvisioningDef =
  TarballProvisioningDef(
    url: archive.url,
    sha256: archive.sha256,
    archiveType: "tar.gz",
    executablePath: executableRelPath(),
    stripComponents: 1,
    packageId: "locked-tool@1.0.0",
    lockIdentity: "sha256:" & archive.sha256)

proc contributionDef(contributor: string; archive: Archive;
                     packages: seq[PackageDef];
                     line = 1): ProvisioningContributionDef =
  let target = findPackage(ToolPackage, packages)
  ProvisioningContributionDef(
    targetPackage: ToolPackage,
    targetInterfaceFingerprint:
      canonicalPackageInterfaceFingerprint(target, packages),
    contributor: contributor,
    tarballProvisioning: @[tarballDef(archive)],
    sourceFile: "catalogs/" & contributor.split('/')[^1] & "/locked_tool.nim",
    sourceLine: line)

proc consumerInterface(defs: seq[ProvisioningContributionDef];
                       packages: seq[PackageDef]): ProjectInterface =
  ## The consumer's interface artifact, lifted through the PRODUCTION
  ## projection with the contributions in the order given -- the order
  ## "imports" arrive in.
  toProjectInterface(findPackage("lockedToolConsumer", packages), packages,
    defs)

proc recordOf(def: ProvisioningContributionDef;
              packages: seq[PackageDef]): InterfaceProvisioningContribution =
  consumerInterface(@[def], packages).provisioningContributions[0]

proc artifactIdentityOf(content: CatalogContent;
                        packages: seq[PackageDef]): string =
  var pi = toProjectInterface(findPackage("lockedToolConsumer", packages),
    packages, @[])
  pi.provisioningContributions = content.contributions
  catalogArtifactIdentity(@[artifactFor(pi)])

proc catalogAt(remote, revision: string; content: CatalogContent;
               packages: seq[PackageDef]): CatalogImport =
  CatalogImport(
    coordinate: CatalogCoordinate(workspace: Workspace, remote: remote,
      revision: revision,
      interfaceArtifact: artifactIdentityOf(content, packages)),
    discoveredAt: "/w/" & remote.split('/')[^1],
    content: some(content))

type Tip = object
  ## One published state of a contributor's catalog: revision, archive and
  ## provider identity.
  contributor: string
  remote: string
  revision: string
  archive: Archive
  provider: string

proc tipA1(): Tip = Tip(contributor: ContributorA, remote: RemoteA,
  revision: RevA1, archive: archiveA1, provider: ProviderA)
proc tipB1(): Tip = Tip(contributor: ContributorB, remote: RemoteB,
  revision: RevB1, archive: archiveB1, provider: ProviderB)

type World = object
  ## Everything one "checkout" of the workspace offers.
  packages: seq[PackageDef]
  tips: seq[Tip]
  imports: seq[CatalogImport]
  offered: seq[ContributionIdentity]
  consumer: ProjectInterface

proc world(tips: seq[Tip]; packages = registeredPackages();
           importOrder: seq[int] = @[]; consumerOrder: seq[int] = @[]):
    World =
  result.packages = packages
  result.tips = tips
  let target = findPackage(ToolPackage, packages)
  let interfaces = catalogAt(PackagesRemote, PackagesRev, CatalogContent(
    canonicalInterfaces: @[catalogInterface(ToolPackage,
      canonicalPackageInterfaceFingerprint(target, packages))],
    contributions: @[]), packages)
  var defs: seq[ProvisioningContributionDef] = @[]
  var catalogs = @[interfaces]
  for tip in tips:
    # The declaration line is a property of the contributor's catalog, not
    # of its position in ``tips``: permuting the imports must not move it.
    let line = if tip.contributor == ContributorA: 10 else: 20
    let def = contributionDef(tip.contributor, tip.archive, packages, line)
    defs.add(def)
    let record = recordOf(def, packages)
    catalogs.add(catalogAt(tip.remote, tip.revision, CatalogContent(
      contributions: @[record]), packages))
    result.offered.add(ContributionIdentity(contribution: record,
      providerIdentity: tip.provider))
  if importOrder.len > 0:
    result.imports = importOrder.mapIt(catalogs[it])
  else:
    result.imports = catalogs
  if consumerOrder.len > 0:
    result.consumer = consumerInterface(consumerOrder.mapIt(defs[it]),
      packages)
  else:
    result.consumer = consumerInterface(defs, packages)

proc policyFor(contributor: string): CatalogSelectionPolicy =
  CatalogSelectionPolicy(selections: @[CatalogSelectionRule(
    targetPackage: ToolPackage, contributor: contributor)])

proc resolve(w: World; claims: seq[LockedRealization] = @[];
             policy = CatalogSelectionPolicy()): ProvisioningResolution =
  resolveProvisioningSelections(ProvisioningResolutionRequest(
    imports: w.imports, lockClaims: claims, policy: policy,
    offered: w.offered, hostPlatform: Host, targetPlatform: Target),
    noContributionResolver)

proc lockSelection(w: World; s: ResolvedProvisioningSelection):
    LockedRealization =
  let tip = w.tips.filterIt(it.contributor == s.selection.contributor)[0]
  let outcome = lockSelectedRealization(RealizationLockRequest(
    selection: s.selection, identity: s.identity,
    realizationLockIdentity: "sha256:" & tip.archive.sha256,
    hostPlatform: Host, targetPlatform: Target, capabilities: @[]),
    noContributionResolver)
  doAssert outcome.locked, outcome.refusals.join("; ")
  outcome.record

proc baseLock(): LockedDependencies =
  parseLockedDependencies(serializeLockedDependencies(LockedDependencies(
    schema: SolvedGraphLockSchemaV2, platform: Host, optimal: true,
    inputsDigest: inputsDigestOf("locked-provisioning-selection"),
    packages: @[LockedPackage(name: "nim", version: "2.2.8", source: "nim",
      selection: ssSelected)])))

proc commitLock(records: seq[LockedRealization]; name: string): string =
  ## Write the lock to disk as a committed ``repro.lock``; returns its path.
  let dir = fixtureRoot / ("checkout-" & name)
  createDir(dir)
  result = dir / "repro.lock"
  writeFile(result,
    serializeLockedDependencies(baseLock().withProvisioningRealizations(
      records)))

proc readCommittedLock(path: string): LockedDependencies =
  parseLockedDependencies(readFile(path))

proc claimsOf(path: string): seq[LockedRealization] =
  readCommittedLock(path).lockedProvisioningClaims()

var storeCounter = 0

proc build(w: World; pins: seq[ProvisioningPin]; store = ""):
    PathOnlyBuildIdentity =
  ## The engine: resolve and REALIZE the consumer's tools in tarball mode.
  let root =
    if store.len > 0: store
    else:
      inc storeCounter
      fixtureRoot / ("store-" & $storeCounter)
  toolBuildIdentity(artifactFor(w.consumer), tpmTarball, storeRoot = root,
    pins = pins)

proc realizedMarker(identity: PathOnlyBuildIdentity): string =
  ## The marker the REALIZED executable prints (its ``echo`` line).
  for line in readFile(identity.profiles[0].resolvedExecutablePath).splitLines():
    if line.startsWith("echo "):
      return line["echo ".len .. ^1].strip()

proc refusalText(r: ProvisioningResolution): string =
  r.refusals.join(" | ")

proc engineRefusal(body: proc ()): string =
  try:
    body()
    ""
  except ValueError as err:
    err.msg

# ---------------------------------------------------------------------------

suite "e2e_locked_provisioning_contributor_selection":
  when defined(windows):
    # The tarball adapter shells out to ``tar``; prefer the System32 bsdtar
    # over an MSYS one, which mis-parses drive-letter paths.
    putEnv("PATH", getEnv("SystemRoot", r"C:\Windows") / "System32" & ";" &
      getEnv("PATH"))
  delEnv(RemovedContributorSelectorEnv)
  # Hermetic: never substitute from, or publish to, a shared binary cache.
  putEnv("REPRO_CACHE_DISABLE", "1")
  fixtureRoot = createTempDir("repro-locked-contributor-", "")
  archiveA1 = buildArchive("a1", "locked-tool-from-contributor-a-tip-1")
  archiveA2 = buildArchive("a2", "locked-tool-from-contributor-a-tip-2")
  archiveB1 = buildArchive("b1", "locked-tool-from-contributor-b-tip-1")
  archiveB2 = buildArchive("b2", "locked-tool-from-contributor-b-tip-2")

  test "two eligible contributors with no lock and no policy are refused, never picked by order":
    let w = world(@[tipA1(), tipB1()])
    let r = w.resolve()
    check not r.resolved
    check r.selections.len == 0
    let text = r.refusalText
    check "unresolved-contribution-ambiguity" in text
    check ContributorA in text and ContributorB in text
    check "declared at catalogs/" in text
    check "import order is never a selection rule" in text
    # The engine, unpinned, refuses the same pair itself.
    let engine = engineRefusal(proc () = discard w.build(@[]))
    check "ambiguous tarball provisioning" in engine
    check ContributorA in engine and ContributorB in engine
    check "committed lock" in engine
    # Reversing both orders yields byte-identical refusals.
    let reversed = world(@[tipB1(), tipA1()])
    check reversed.resolve().refusalText == text
    check engineRefusal(proc () = discard reversed.build(@[])) == engine

  test "a curator policy selects, and its choice is serialized into the committed lock":
    let w = world(@[tipA1(), tipB1()])
    let r = w.resolve(policy = policyFor(ContributorA))
    check r.resolved
    let s = r.selectionFor(ToolPackage)
    check s.source == pssCuratorPolicy
    check s.selection.contributor == ContributorA
    check s.lockedRecord.isNone
    let record = w.lockSelection(s)
    check record.selectedBy == lsrCuratorPolicy
    check record.contributor == ContributorA
    check record.contributionFingerprint == s.contributionFingerprint
    check record.catalogRemote == RemoteA
    check record.catalogRevision == RevA1
    let path = commitLock(@[record], "policy")
    let claims = claimsOf(path)
    check claims.len == 1
    check claims[0] == record
    check readFile(path).contains("selected_by = \"curator-policy\"")

  test "the committed lock alone resolves the two eligible contributors and the engine realizes the locked one":
    let w = world(@[tipA1(), tipB1()])
    let record = w.lockSelection(
      w.resolve(policy = policyFor(ContributorA)).selectionFor(ToolPackage))
    let path = commitLock(@[record], "locked")
    # No policy now: the lock alone decides.
    let r = w.resolve(claimsOf(path))
    check r.resolved
    let s = r.selectionFor(ToolPackage)
    check s.source == pssLock
    check s.selection.contributor == ContributorA
    check s.lockedRecord == some(record)
    check s.contributionFingerprint == record.contributionFingerprint
    let identity = w.build(r.pinsOf)
    check identity.realizedMarker == archiveA1.marker
    check identity.profiles[0].tarballSha256 == archiveA1.sha256
    check ("\ncontribution:" & record.contributionFingerprint & "\n") in
      identity.profiles[0].lockIdentity
    check identity.profiles[0].lockIdentity.startsWith(
      "contributor:" & ContributorA & "\n")
    # And the lock outranks a policy that AGREES with it.
    let agreeing = w.resolve(claimsOf(path), policyFor(ContributorA))
    check agreeing.resolved
    check agreeing.selectionFor(ToolPackage).source == pssLock

  test "the selection stays pinned across every import order and consumer order":
    let w0 = world(@[tipA1(), tipB1()])
    let path = commitLock(@[w0.lockSelection(w0.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))], "orders")
    let claims = claimsOf(path)
    let store = fixtureRoot / "store-orders"
    var pins: seq[seq[ProvisioningPin]] = @[]
    var fingerprints: seq[string] = @[]
    var actions: seq[string] = @[]
    var perms = @[0, 1, 2]
    var seen = 0
    while true:
      for consumerOrder in [@[0, 1], @[1, 0]]:
        let w = world(@[tipA1(), tipB1()], importOrder = perms,
          consumerOrder = consumerOrder)
        let r = w.resolve(claims)
        check r.resolved
        check r.selectionFor(ToolPackage).selection.contributor == ContributorA
        pins.add(r.pinsOf)
        let identity = w.build(r.pinsOf, store)
        check identity.realizedMarker == archiveA1.marker
        fingerprints.add(identity.profiles[0].profileFingerprint.bytes.mapIt(it.toHex(2)).join())
        actions.add(identity.actionIdentities[0].actionFingerprint.bytes.mapIt(it.toHex(2)).join())
        inc seen
      if not perms.nextPermutation():
        break
    check seen == 12
    check pins.deduplicate().len == 1
    check fingerprints.deduplicate().len == 1
    check actions.deduplicate().len == 1

  test "the non-selected contributor's branch tip moves and the selection stays pinned":
    let w1 = world(@[tipA1(), tipB1()])
    let path = commitLock(@[w1.lockSelection(w1.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))], "btip")
    let before = w1.resolve(claimsOf(path))
    let store = fixtureRoot / "store-btip"
    let identityBefore = w1.build(before.pinsOf, store)
    # B publishes a new tip: new revision, new archive, new provider.
    let movedB = Tip(contributor: ContributorB, remote: RemoteB,
      revision: RevB2, archive: archiveB2, provider: ProviderB2)
    let w2 = world(@[tipA1(), movedB])
    # B's new tip is a live alternative: a policy would select it.
    let wouldB = w2.resolve(policy = policyFor(ContributorB))
    check wouldB.resolved
    check wouldB.selectionFor(ToolPackage).selection.contributor == ContributorB
    # The lock keeps A, with the identical pin and build keys.
    let after = w2.resolve(claimsOf(path))
    check after.resolved
    check after.pinsOf == before.pinsOf
    let identityAfter = w2.build(after.pinsOf, store)
    check identityAfter.realizedMarker == archiveA1.marker
    check identityAfter.profiles[0].profileFingerprint ==
      identityBefore.profiles[0].profileFingerprint
    check identityAfter.actionIdentities[0].actionFingerprint ==
      identityBefore.actionIdentities[0].actionFingerprint
    check identityAfter.profiles[0].selectedStorePath ==
      identityBefore.profiles[0].selectedStorePath

  test "the selected contributor's content change refuses and is never re-pinned":
    let w1 = world(@[tipA1(), tipB1()])
    let record = w1.lockSelection(w1.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))
    let path = commitLock(@[record], "atip")
    let movedA = Tip(contributor: ContributorA, remote: RemoteA,
      revision: RevA2, archive: archiveA2, provider: ProviderA)
    let w2 = world(@[movedA, tipB1()])
    let offeredNow = w2.resolve(policy = policyFor(ContributorA)).
      selectionFor(ToolPackage).contributionFingerprint
    check offeredNow != record.contributionFingerprint
    let r = w2.resolve(claimsOf(path))
    check not r.resolved
    check r.selections.len == 0
    let text = r.refusalText
    check "contribution-changed" in text
    check record.contributionFingerprint in text   # the locked one
    check offeredNow in text                       # the offered one
    check ContributorA in text
    # Not re-selected to B, and not relaxed to the policy either.
    let withPolicyB = w2.resolve(claimsOf(path), policyFor(ContributorB))
    check not withPolicyB.resolved
    check "policy-contradicts-lock" in withPolicyB.refusalText
    let withPolicyA = w2.resolve(claimsOf(path), policyFor(ContributorA))
    check not withPolicyA.resolved
    check "contribution-changed" in withPolicyA.refusalText
    # A stale pin cannot be forced into the engine either: the consumer
    # artifact carries A's NEW record, the stale pin names the old one.
    let stalePin = w1.resolve(claimsOf(path)).pinsOf
    let engine = engineRefusal(proc () = discard w2.build(stalePin))
    check "was not built from the contribution the selection verified" in
      engine

  test "a provider-only change of the selected contributor refuses":
    let w1 = world(@[tipA1(), tipB1()])
    let path = commitLock(@[w1.lockSelection(w1.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))], "prov")
    var providerMoved = tipA1()
    providerMoved.provider = ProviderA2
    let w2 = world(@[providerMoved, tipB1()])
    # Same artifact-readable record, same catalog coordinate...
    check w2.imports == w1.imports
    let r = w2.resolve(claimsOf(path))
    check not r.resolved
    check "contribution-changed" in r.refusalText

  test "a moved catalog revision of the selected contributor refuses even with unchanged content":
    let w1 = world(@[tipA1(), tipB1()])
    let path = commitLock(@[w1.lockSelection(w1.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))], "arev")
    var revisionMoved = tipA1()
    revisionMoved.revision = RevA2
    let r = world(@[revisionMoved, tipB1()]).resolve(claimsOf(path))
    check not r.resolved
    let text = r.refusalText
    check "catalog-changed" in text
    check RevA1 in text and RevA2 in text

  test "a locked contributor that is no longer offered refuses; the unique remaining one is not taken":
    let w1 = world(@[tipA1(), tipB1()])
    let path = commitLock(@[w1.lockSelection(w1.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))], "gone")
    let onlyB = world(@[tipB1()])
    check onlyB.resolve().resolved   # B alone is unique-eligible...
    let r = onlyB.resolve(claimsOf(path))
    check not r.resolved             # ...but the lock pins A.
    let text = r.refusalText
    check "locked-contribution-unavailable" in text
    check ContributorA in text and ContributorB in text
    # No catalog offers the package at all.
    let none = world(@[])
    let r2 = none.resolve(claimsOf(path))
    check not r2.resolved
    check "locked-contribution-unavailable" in r2.refusalText

  test "an incompatible interface change invalidates the lock entry and refuses":
    let w1 = world(@[tipA1(), tipB1()])
    let record = w1.lockSelection(w1.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))
    let path = commitLock(@[record], "iface")
    # The package interface changes; both contributors republish against it.
    var packages = registeredPackages().filterIt(it.packageName != ToolPackage)
    var changed = findPackage(ToolPackage, registeredPackages())
    changed.executables = @[ExecutableDef(exportName: "lockedTool",
      binaryName: "locked-tool-v2")]
    packages.add(changed)
    let w2 = world(@[tipA1(), tipB1()], packages)
    let newInterface = canonicalPackageInterfaceFingerprint(changed, packages)
    check newInterface != record.interfaceFingerprint
    check w2.resolve(policy = policyFor(ContributorA)).resolved
    let r = w2.resolve(claimsOf(path))
    check not r.resolved
    let text = r.refusalText
    check "interface-changed" in text
    check record.interfaceFingerprint in text and newInterface in text
    # Contributions still pinned to the OLD interface are not eligible at all.
    var stale = w2
    stale.imports = w2.imports[0 .. 0] & w1.imports[1 .. ^1]
    let r2 = stale.resolve(claimsOf(path))
    check not r2.resolved
    check "incompatible-interface-fingerprint" in r2.refusalText

  test "a contribution-only refresh moves the realization and build keys but not the typecheck identity":
    for variant in ["provider-only", "archive-and-revision"]:
      let w1 = world(@[tipA1(), tipB1()])
      let record1 = w1.lockSelection(w1.resolve(
        policy = policyFor(ContributorA)).selectionFor(ToolPackage))
      let path1 = commitLock(@[record1], "refresh-1-" & variant)
      let store = fixtureRoot / ("store-refresh-" & variant)
      let built1 = w1.build(w1.resolve(claimsOf(path1)).pinsOf, store)

      var moved = tipA1()
      if variant == "provider-only":
        moved.provider = ProviderA2
      else:
        moved.revision = RevA2
        moved.archive = archiveA2
      let w2 = world(@[moved, tipB1()])
      # The stale lock refuses (above); refresh it: drop the stale record,
      # re-resolve under the curator policy, lock the new selection.
      check not w2.resolve(claimsOf(path1)).resolved
      let record2 = w2.lockSelection(w2.resolve(
        policy = policyFor(ContributorA)).selectionFor(ToolPackage))
      let path2 = commitLock(@[record2], "refresh-2-" & variant)
      check record2.contributionFingerprint != record1.contributionFingerprint
      let r2 = w2.resolve(claimsOf(path2))
      check r2.resolved
      let built2 = w2.build(r2.pinsOf, store)

      # Typecheck identity: unchanged.
      check lockIdentityOf(readCommittedLock(path1)) ==
        lockIdentityOf(readCommittedLock(path2))
      check record2.interfaceFingerprint == record1.interfaceFingerprint
      check canonicalPackageInterfaceFingerprint(
        findPackage(ToolPackage, w2.packages), w2.packages) ==
        record1.interfaceFingerprint
      # Realization and build edges: every key moves.
      let p1 = built1.profiles[0]
      let p2 = built2.profiles[0]
      check p2.selectedStorePath != p1.selectedStorePath
      check p2.profileFingerprint != p1.profileFingerprint
      check built2.actionIdentities[0].actionFingerprint !=
        built1.actionIdentities[0].actionFingerprint
      check ("\ncontribution:" & record2.contributionFingerprint & "\n") in
        p2.lockIdentity
      if variant == "provider-only":
        # Nothing else about the realization moved: same archive, same
        # bytes -- the contribution fingerprint alone moved the keys.
        check p2.tarballSha256 == p1.tarballSha256
        check p2.tarballUrl == p1.tarballUrl
        check built2.realizedMarker == built1.realizedMarker
        check artifactFor(w2.consumer).interfaceFingerprint ==
          artifactFor(w1.consumer).interfaceFingerprint
      else:
        check built2.realizedMarker == archiveA2.marker

  test "a curator policy that contradicts the committed lock refuses":
    let w = world(@[tipA1(), tipB1()])
    let record = w.lockSelection(w.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))
    let r = w.resolve(claimsOf(commitLock(@[record], "contradict")),
      policyFor(ContributorB))
    check not r.resolved
    let text = r.refusalText
    check "policy-contradicts-lock" in text
    check ContributorA in text and ContributorB in text

  test "the removed environment selector never overrides the lock":
    let w = world(@[tipA1(), tipB1()])
    let r = w.resolve(claimsOf(commitLock(@[w.lockSelection(w.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))], "env")))
    check r.resolved
    putEnv(RemovedContributorSelectorEnv, ContributorB)
    defer: delEnv(RemovedContributorSelectorEnv)
    let pinned = engineRefusal(proc () = discard w.build(r.pinsOf))
    check "REPRO_PROVISIONING_CONTRIBUTOR is set" in pinned
    check "was removed" in pinned
    let unpinned = engineRefusal(proc () = discard w.build(@[]))
    check "REPRO_PROVISIONING_CONTRIBUTOR is set" in unpinned

  test "the engine refuses a pin its consumer artifact does not carry exactly":
    let w = world(@[tipA1(), tipB1()])
    let r = w.resolve(claimsOf(commitLock(@[w.lockSelection(w.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))], "pins")))
    let good = r.pinsOf[0]
    # A contributor the consumer artifact does not carry.
    var foreign = good
    foreign.contributor = "github:example/not-imported"
    check "carries no contribution from it" in
      engineRefusal(proc () = discard w.build(@[foreign]))
    # A record digest that is not the artifact's.
    var otherRecord = good
    otherRecord.contributionRecordDigest = repeat('0', 64)
    check "was not built from the contribution the selection verified" in
      engineRefusal(proc () = discard w.build(@[otherRecord]))
    # Malformed: a short fingerprint is a pin, never "no pin".
    var short = good
    short.contributionFingerprint = "abc"
    check "malformed provisioning pin" in
      engineRefusal(proc () = discard w.build(@[short]))
    var blank = good
    blank.contributor = ""
    check "malformed provisioning pin" in
      engineRefusal(proc () = discard w.build(@[blank]))
    # Two different pins for one package, in either order.
    var toB = good
    toB.contributor = ContributorB
    toB.contributionRecordDigest = interfaceContributionRecordDigest(
      w.offered[1].contribution).toLowerAscii()
    # ``good`` came from the committed lock, so it also names A's locked
    # realization; B's pin names B's.
    toB.realizationLockIdentity = "sha256:" & archiveB1.sha256
    check "two different provisioning pins" in
      engineRefusal(proc () = discard w.build(@[good, toB]))
    check "two different provisioning pins" in
      engineRefusal(proc () = discard w.build(@[toB, good]))
    # A repeated identical pin is one pin.
    check w.build(@[good, good]).realizedMarker == archiveA1.marker
    # The other contributor, correctly pinned, realizes ITS archive.
    check w.build(@[toB]).realizedMarker == archiveB1.marker

  test "a lock that pins one of the contributor's two realizations realizes exactly that one":
    # Contributor A declares TWO tarball realizations, both eligible on this
    # host. The committed lock pins one of them; the engine must realize
    # that one, not the first in declaration order (which it did before the
    # pin carried the locked realization: the lock said A2, the engine
    # realized A1).
    let packages = registeredPackages()
    var defA = contributionDef(ContributorA, archiveA1, packages, 10)
    defA.tarballProvisioning.add(tarballDef(archiveA2))
    let defB = contributionDef(ContributorB, archiveB1, packages, 20)
    let recordA = recordOf(defA, packages)
    var w = world(@[tipA1(), tipB1()])
    w.imports[1] = catalogAt(RemoteA, RevA1,
      CatalogContent(contributions: @[recordA]), packages)
    w.offered[0] = ContributionIdentity(contribution: recordA,
      providerIdentity: ProviderA)
    w.consumer = consumerInterface(@[defA, defB], packages)
    let s = w.resolve(policy = policyFor(ContributorA)).selectionFor(ToolPackage)
    for archive in [archiveA2, archiveA1]:
      let outcome = lockSelectedRealization(RealizationLockRequest(
        selection: s.selection, identity: s.identity,
        realizationLockIdentity: "sha256:" & archive.sha256,
        hostPlatform: Host, targetPlatform: Target, capabilities: @[]),
        noContributionResolver)
      check outcome.locked
      let r = w.resolve(claimsOf(commitLock(@[outcome.record],
        "two-realizations-" & archive.marker)))
      check r.resolved
      check r.pinsOf[0].realizationLockIdentity == "sha256:" & archive.sha256
      let identity = w.build(r.pinsOf)
      check identity.realizedMarker == archive.marker
      check identity.profiles[0].tarballSha256 ==
        outcome.record.realizationIntegrity
    # A policy selection pins the contributor only: declaration order.
    let byPolicy = w.resolve(policy = policyFor(ContributorA))
    check byPolicy.pinsOf[0].realizationLockIdentity == ""
    check w.build(byPolicy.pinsOf).realizedMarker == archiveA1.marker
    # A pin naming a realization the contributor does not declare refuses.
    var undeclared = byPolicy.pinsOf[0]
    undeclared.realizationLockIdentity = "sha256:" & archiveB1.sha256
    check "declares that realization 0 time(s)" in
      engineRefusal(proc () = discard w.build(@[undeclared]))

  test "two different records from one contributor are refused rather than ordered":
    let packages = registeredPackages()
    let first = contributionDef(ContributorA, archiveA1, packages, 1)
    let second = contributionDef(ContributorA, archiveA2, packages, 2)
    var w = world(@[tipA1()])
    w.consumer = consumerInterface(@[first, second], packages)
    let engine = engineRefusal(proc () = discard w.build(@[]))
    check "different contribution records from contributor" in engine
    w.consumer = consumerInterface(@[second, first], packages)
    check engineRefusal(proc () = discard w.build(@[])) == engine

  removeDir(fixtureRoot)

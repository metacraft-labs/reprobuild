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
## ## The CLI build path (``repro_cli_support``)
##
## The cases from "the CLI build path ..." on drive the functions ``repro
## build`` itself calls, at the library level: ``buildProvisioningPins``
## reads the committed ``repro.lock`` FILE from the project directory
## (``committedProvisioningLockPath``), obtains the catalogs from the
## installed ``ProvisioningCatalogSource``, runs the resolver and hands the
## pins to ``warmResolveAndWriteIdentity`` -- the build path's own warm-table
## / on-disk tool-identity cache, keyed by ``toolIdentityCacheKey`` -- which
## realizes the locked archive. They cover: the lock selecting through that
## path; the pins being part of the cache key (a lock moved from A to B is
## re-resolved, never served A's cached identity); every refusal raising
## ``ProvisioningSelectionRefused`` with the resolver's message (the build
## lets it propagate; nothing retries unpinned); the no-lock /
## no-record path consulting nothing and keying exactly as before; and the
## consumer's typecheck identity (its interface fingerprint and its
## provider-compile edge) staying put for realization-only changes while
## the CLI cache and the realization keys move (deliverable 4).
##
## The catalog source is supplied BY THE TEST (``useCatalogs``). It is not a
## mock of anything that exists: explicit catalog imports and provider
## identities (M6 deliverables 1 and 2) have no production implementation,
## so in a real ``repro build`` no source is installed and a lock with
## provisioning records refuses -- which is also tested.
##
## ## What this does NOT cover
##
##   * The ``repro`` binary itself: ``executeBuildTarget`` (which calls
##     ``buildProvisioningPins`` then ``warmResolveAndWriteIdentity`` and
##     ``loweredGraphCacheKey`` with the same pins), the dev-env activation
##     and ``repro develop`` sites, and the producer runtime-tool sites are
##     not run end to end: the binary's ``.#apps`` edge crashes on this host
##     (``nim.exe`` STATUS_STACK_BUFFER_OVERRUN, pre-existing).
##   * A production catalog source (M6 deliverables 1 and 2).
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
import repro_cli_support
import repro_hash
import repro_lock
import repro_lock_files
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
# The CLI build path (``repro_cli_support``)
# ---------------------------------------------------------------------------

var catalogWorld: World
var catalogSourceCalls = 0

proc useCatalogs(w: World) =
  ## Install ``w``'s catalogs as the CLI's ``ProvisioningCatalogSource`` --
  ## the input M6 deliverables 1 and 2 will supply in production (see the
  ## module docstring).
  catalogWorld = w
  setProvisioningCatalogSource(
    proc (request: ProvisioningCatalogRequest): ProvisioningCatalogInputs =
      inc catalogSourceCalls
      ProvisioningCatalogInputs(imports: catalogWorld.imports,
        offered: catalogWorld.offered))

proc cliProject(records: seq[LockedRealization]; name: string): string =
  ## A project directory whose committed ``repro.lock`` carries ``records``.
  parentDir(commitLock(records, name))

proc cliArtifact(w: World; consumerRoot = ""): ProjectInterfaceArtifact =
  ## The consumer's artifact as extraction produces it for a project rooted
  ## at ``consumerRoot``: the contributions it imports are marked imported
  ## (``markImportedContributions``; they are declared under ``catalogs/``,
  ## outside it).
  var pi = w.consumer
  let root =
    if consumerRoot.len > 0: consumerRoot else: fixtureRoot / "consumer"
  markImportedContributions(pi, root / "repro.nim")
  artifactFor(pi)

proc cliBuild(w: World; projectRoot, outDir: string): PathOnlyBuildIdentity =
  ## What ``repro build`` does for the consumer: resolve the pins from the
  ## project's committed lock, then resolve (and realize) the tool identity
  ## through the build path's own cache.
  let artifact = w.cliArtifact()
  warmResolveAndWriteIdentity(artifact, outDir, tpmTarball,
    pins = buildProvisioningPins(artifact, projectRoot)).identity

proc cliRefusal(body: proc ()): string =
  try:
    body()
    ""
  except ProvisioningSelectionRefused as err:
    err.msg

proc hx(d: ContentDigest): string =
  d.bytes.mapIt(it.toHex(2)).join().toLowerAscii()

const UnpinnedKeyAtF7544a7b =
  "4dca22f8441755fbf7bf3986f84ad518fbbcb6a4274805fe37f43c67edb7d497"
  ## ``toolIdentityCacheKey(fixedKeyArtifact(), tpmTarball)`` computed by the
  ## tree BEFORE lock selection reached the CLI (f7544a7b). A build with no
  ## lock-selected pin and no imported contribution must key exactly so.

proc fixedKeyArtifact(): ProjectInterfaceArtifact =
  ## A consumer artifact made of literals only (no archive digests, which
  ## vary per run), carrying one contribution record as its OWN.
  let tarball = InterfaceTarballProvisioning(packageName: "lockedTool",
    contributor: "github:example/locked-tool-catalog-a",
    url: "https://example.invalid/locked-tool-a.tar.gz",
    sha256: repeat('a', 64), archiveType: "tar.gz",
    executablePath: "bin/locked-tool", stripComponents: 1,
    packageId: "locked-tool@1.0.0", lockIdentity: "sha256:" & repeat('a', 64))
  artifactFor(ProjectInterface(projectName: "keyFixture",
    packageName: "keyFixture", defaultToolProvisioning: "tarball",
    toolUses: @[InterfaceToolUse(rawConstraint: "lockedTool",
      packageSelector: "lockedTool", executableName: "locked-tool",
      tarballProvisioning: @[tarball])],
    provisioningContributions: @[InterfaceProvisioningContribution(
      targetPackage: "lockedTool", targetInterfaceFingerprint: repeat('c', 64),
      contributor: "github:example/locked-tool-catalog-a",
      tarballProvisioning: @[tarball])]))

proc writeProjectLock(projectRoot: string; records: seq[LockedRealization]) =
  createDir(projectRoot)
  writeFile(projectRoot / "repro.lock",
    serializeLockedDependencies(baseLock().withProvisioningRealizations(
      records)))

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

  test "the CLI build path reads the committed repro.lock and realizes the locked contributor":
    let w = world(@[tipA1(), tipB1()])
    w.useCatalogs()
    let record = w.lockSelection(w.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))
    let project = cliProject(@[record], "cli-locked")
    check committedProvisioningLockPath(project) == project / "repro.lock"
    let pins = buildProvisioningPins(w.cliArtifact(), project)
    check pins == w.resolve(claimsOf(project / "repro.lock")).pinsOf
    check pins.len == 1
    check pins[0].contributor == ContributorA
    check pins[0].realizationLockIdentity == "sha256:" & archiveA1.sha256
    # An explicit ``--lock`` binding for ``default`` governs instead of the
    # project's own lock -- the same file the governing lock identity and
    # the version pins read.
    let recordB = w.lockSelection(w.resolve(
      policy = policyFor(ContributorB)).selectionFor(ToolPackage))
    let elsewhere = commitLock(@[recordB], "cli-bound")
    var bindings = initLockBindings()
    bindings.applyLockFlag(elsewhere)
    setActiveLockBindings(bindings)
    check committedProvisioningLockPath(project) == absolutePath(elsewhere)
    check buildProvisioningPins(w.cliArtifact(), project)[0].contributor ==
      ContributorB
    resetActiveLockBindings()
    check buildProvisioningPins(w.cliArtifact(), project)[0].contributor ==
      ContributorA
    let identity = w.cliBuild(project, fixtureRoot / "cli-out-locked")
    check identity.realizedMarker == archiveA1.marker
    check ("\ncontribution:" & record.contributionFingerprint & "\n") in
      identity.profiles[0].lockIdentity
    # Without a lock the CLI path pins nothing, and the two eligible
    # contributors refuse exactly as the engine always did.
    let unlocked = fixtureRoot / "cli-unlocked"
    createDir(unlocked)
    check buildProvisioningPins(w.cliArtifact(), unlocked).len == 0
    let engine = engineRefusal(proc () =
      discard w.cliBuild(unlocked, fixtureRoot / "cli-out-unlocked"))
    check "ambiguous tarball provisioning" in engine

  test "the CLI tool-identity cache key binds the pins: a lock moved from A to B is never served A's cached identity":
    let w = world(@[tipA1(), tipB1()])
    w.useCatalogs()
    let recordA = w.lockSelection(w.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))
    let recordB = w.lockSelection(w.resolve(
      policy = policyFor(ContributorB)).selectionFor(ToolPackage))
    let project = fixtureRoot / "cli-cache"
    let outDir = fixtureRoot / "cli-out-cache"
    let artifact = w.cliArtifact()
    writeProjectLock(project, @[recordA])
    let pinsA = buildProvisioningPins(artifact, project)
    let first = warmResolveAndWriteIdentity(artifact, outDir, tpmTarball,
      pins = pinsA)
    check first.identity.realizedMarker == archiveA1.marker
    let keyA = toolIdentityCacheKey(artifact, tpmTarball, pins = pinsA)
    check readFile(outDir / "tool-identity-cache" / "tarball.current-key").
      strip() == keyA
    # The same pins are served from the warm table.
    var resolves = warmBuildCacheCounters.toolIdentityResolves
    check warmResolveAndWriteIdentity(artifact, outDir, tpmTarball,
      pins = pinsA).identity.realizedMarker == archiveA1.marker
    check warmBuildCacheCounters.toolIdentityResolves == resolves
    # The committed lock now pins B: same artifact, same outDir.
    writeProjectLock(project, @[recordB])
    let pinsB = buildProvisioningPins(artifact, project)
    check pinsB[0].contributor == ContributorB
    let keyB = toolIdentityCacheKey(artifact, tpmTarball, pins = pinsB)
    check keyB != keyA
    resolves = warmBuildCacheCounters.toolIdentityResolves
    let second = warmResolveAndWriteIdentity(artifact, outDir, tpmTarball,
      pins = pinsB)
    check warmBuildCacheCounters.toolIdentityResolves == resolves + 1
    check second.identity.realizedMarker == archiveB1.marker
    check second.identity.profiles[0].profileFingerprint !=
      first.identity.profiles[0].profileFingerprint
    # A cold process (on-disk cache only) is not served A either.
    forgetWarmBuildCaches()
    check warmResolveAndWriteIdentity(artifact, outDir, tpmTarball,
      pins = pinsB).identity.realizedMarker == archiveB1.marker
    # Back to A: A's key again, and A's archive.
    writeProjectLock(project, @[recordA])
    let pinsA2 = buildProvisioningPins(artifact, project)
    check pinsA2 == pinsA
    check toolIdentityCacheKey(artifact, tpmTarball, pins = pinsA2) == keyA
    forgetWarmBuildCaches()
    check warmResolveAndWriteIdentity(artifact, outDir, tpmTarball,
      pins = pinsA2).identity.realizedMarker == archiveA1.marker
    check fileExists(outDir / "tool-identity-cache" / (keyA & ".rbtp"))
    check fileExists(outDir / "tool-identity-cache" / (keyB & ".rbtp"))
    # The lowered-graph cache key embeds the tool-identity key with the same
    # pins, so a graph lowered under A is not served under B either.
    proc graphKey(pins: seq[ProvisioningPin]): string =
      loweredGraphCacheKey(artifact, tpmTarball, "provider-artifact", "", "",
        pins = pins)
    check graphKey(pinsA) != graphKey(pinsB)
    check graphKey(pinsA) != graphKey(@[])
    check graphKey(pinsA2) == graphKey(pinsA)
    # Every field of a pin is bound; an unpinned key is a different key.
    for field in 0 .. 4:
      var moved = pinsA[0]
      case field
      of 0: moved.packageName = moved.packageName & "x"
      of 1: moved.contributor = moved.contributor & "x"
      of 2: moved.contributionFingerprint = repeat('0', 64)
      of 3: moved.contributionRecordDigest = repeat('0', 64)
      else: moved.realizationLockIdentity = "sha256:" & archiveA2.sha256
      check toolIdentityCacheKey(artifact, tpmTarball, pins = @[moved]) != keyA
    check toolIdentityCacheKey(artifact, tpmTarball) != keyA
    check toolIdentityCacheKey(artifact, tpmTarball, pins = @[]) ==
      toolIdentityCacheKey(artifact, tpmTarball)
    # Pin order is not observable.
    var helperPin = pinsB[0]
    helperPin.packageName = "otherPackage"
    check toolIdentityCacheKey(artifact, tpmTarball, pins = @[pinsA[0],
      helperPin]) == toolIdentityCacheKey(artifact, tpmTarball,
      pins = @[helperPin, pinsA[0]])

  test "a lock refusal fails the CLI build path with the resolver's message and never falls back to an unpinned selection":
    let w1 = world(@[tipA1(), tipB1()])
    w1.useCatalogs()
    let record = w1.lockSelection(w1.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))
    let project = cliProject(@[record], "cli-refuse")
    let lockPath = project / "repro.lock"
    let outDir = fixtureRoot / "cli-out-refuse"
    check w1.cliBuild(project, outDir).realizedMarker == archiveA1.marker
    # A publishes new content; the lock still pins the old contribution.
    let w2 = world(@[Tip(contributor: ContributorA, remote: RemoteA,
      revision: RevA2, archive: archiveA2, provider: ProviderA), tipB1()])
    w2.useCatalogs()
    let offeredNow = w2.resolve(policy = policyFor(ContributorA)).
      selectionFor(ToolPackage).contributionFingerprint
    let text = cliRefusal(proc () = discard w2.cliBuild(project, outDir))
    check "provisioning selection refused" in text
    check "contribution-changed" in text
    check record.contributionFingerprint in text
    check offeredNow in text
    check lockPath in text
    check "not relaxed to an unpinned selection" in text
    # The locked contributor is gone; B alone would be unique-eligible.
    let onlyB = world(@[tipB1()])
    onlyB.useCatalogs()
    let gone = cliRefusal(proc () =
      discard buildProvisioningPins(onlyB.cliArtifact(), project))
    check "locked-contribution-unavailable" in gone
    check ContributorA in gone
    # In production no catalog source is installed yet (M6 deliverables 1
    # and 2): a lock with provisioning records refuses, naming why.
    setProvisioningCatalogSource(nil)
    check not provisioningCatalogSourceInstalled()
    let production = cliRefusal(proc () = discard w1.cliBuild(project, outDir))
    check "M6 deliverables 1 and 2" in production
    check "\"" & ToolPackage & "\" -> \"" & ContributorA & "\"" in production
    check lockPath in production
    check "The lock is not ignored" in production
    # The catalog source's curator policy is honoured -- and one that
    # contradicts the committed lock refuses rather than being followed.
    setProvisioningCatalogSource(
      proc (request: ProvisioningCatalogRequest): ProvisioningCatalogInputs =
        ProvisioningCatalogInputs(imports: w1.imports, offered: w1.offered,
          policy: policyFor(ContributorB)))
    let contradicted = cliRefusal(proc () = discard w1.cliBuild(project, outDir))
    check "policy-contradicts-lock" in contradicted
    check ContributorB in contradicted
    # A failing catalog source refuses; it is not read as "no catalogs".
    setProvisioningCatalogSource(
      proc (request: ProvisioningCatalogRequest): ProvisioningCatalogInputs =
        raise newException(IOError, "catalog checkout is missing"))
    check "catalog checkout is missing" in
      cliRefusal(proc () = discard w1.cliBuild(project, outDir))
    # The catalog source's dependency resolver is the one used: a contribution
    # that declares a dependency is fully bound only through it.
    var wd = world(@[tipA1(), tipB1()])
    let dep = ContributionDependencyRef(targetPackage: ToolPackage,
      contributor: ContributorB,
      targetInterfaceFingerprint:
        wd.offered[1].contribution.targetInterfaceFingerprint)
    wd.offered[0].dependencies = @[dep]
    let depIdentity = wd.offered[1]
    let depResolver: ContributionResolver =
      proc (d: ContributionDependencyRef): Option[ContributionIdentity] {.gcsafe.} =
        # The test's suite body is module scope; the resolver runs in this
        # thread only.
        {.cast(gcsafe).}:
          result = if d == dep: some(depIdentity) else: none(ContributionIdentity)
    let depSelection = resolveProvisioningSelections(
      ProvisioningResolutionRequest(imports: wd.imports,
        policy: policyFor(ContributorA), offered: wd.offered,
        hostPlatform: Host, targetPlatform: Target), depResolver).
      selectionFor(ToolPackage)
    let depLocked = lockSelectedRealization(RealizationLockRequest(
      selection: depSelection.selection, identity: depSelection.identity,
      realizationLockIdentity: "sha256:" & archiveA1.sha256,
      hostPlatform: Host, targetPlatform: Target, capabilities: @[]),
      depResolver)
    check depLocked.locked
    let depProject = cliProject(@[depLocked.record], "cli-dependency")
    setProvisioningCatalogSource(
      proc (request: ProvisioningCatalogRequest): ProvisioningCatalogInputs =
        ProvisioningCatalogInputs(imports: wd.imports, offered: wd.offered,
          resolver: depResolver))
    check buildProvisioningPins(wd.cliArtifact(), depProject)[0].
      contributionFingerprint == depLocked.record.contributionFingerprint
    setProvisioningCatalogSource(
      proc (request: ProvisioningCatalogRequest): ProvisioningCatalogInputs =
        ProvisioningCatalogInputs(imports: wd.imports, offered: wd.offered))
    check "dependencies-not-fully-resolved" in cliRefusal(proc () =
      discard buildProvisioningPins(wd.cliArtifact(), depProject))
    # Provisioning records that cannot be read are refused, not dropped.
    w1.useCatalogs()
    let broken = fixtureRoot / "cli-broken"
    createDir(broken)
    var lines = readFile(lockPath).splitLines()
    for i, line in lines:
      if line.startsWith("provisioning"):
        lines[i] = line[0 ..< line.len div 2]
    writeFile(broken / "repro.lock", lines.join("\n"))
    let unreadable = cliRefusal(proc () =
      discard buildProvisioningPins(w1.cliArtifact(), broken))
    check "cannot be read" in unreadable
    check "they are not ignored" in unreadable
    # TOML spellings of the key the strict reader does not read (it accepts
    # each of these as a lock with NO provisioning record -- measured) are
    # refused, never built unpinned.
    let plainLock = readFile(lockPath).splitLines().filterIt(
      not it.startsWith("provisioning")).join("\n")
    for spelling in ["\"provisioning\" = [{ record = \"x\" }]",
                     "'provisioning' = [{ record = \"x\" }]",
                     "[[provisioning]]\nrecord = \"x\"",
                     "provisioning.record = \"x\""]:
      writeFile(broken / "repro.lock", plainLock & "\n" & spelling & "\n")
      check parseLockedDependencies(readFile(broken / "repro.lock")).
        lockedProvisioningClaims().len == 0
      check "not read" in cliRefusal(proc () =
        discard buildProvisioningPins(w1.cliArtifact(), broken))

  test "with no lock, or no provisioning record for this platform pair, the CLI path consults nothing and keys as before":
    let w = world(@[tipA1()])
    w.useCatalogs()
    catalogSourceCalls = 0
    let artifact = w.cliArtifact()
    let unpinnedKey = toolIdentityCacheKey(artifact, tpmTarball)
    # No lock file.
    let noLock = fixtureRoot / "cli-no-lock"
    createDir(noLock)
    check buildProvisioningPins(artifact, noLock).len == 0
    # A lock without provisioning records.
    let plain = cliProject(@[], "cli-plain")
    check ProvisioningLockKey notin readFile(plain / "repro.lock")
    check buildProvisioningPins(artifact, plain).len == 0
    # Records for another platform pair only.
    let other = if Host == "arm64-linux": "amd64-linux" else: "arm64-linux"
    let s = w.resolve().selectionFor(ToolPackage)
    let foreign = lockSelectedRealization(RealizationLockRequest(
      selection: s.selection, identity: s.identity,
      realizationLockIdentity: "sha256:" & archiveA1.sha256,
      hostPlatform: other, targetPlatform: other, capabilities: @[]),
      noContributionResolver)
    check foreign.locked
    let otherPlatform = cliProject(@[foreign.record], "cli-other-platform")
    check ProvisioningLockKey in readFile(otherPlatform / "repro.lock")
    check buildProvisioningPins(artifact, otherPlatform).len == 0
    # A lock the strict reader rejects, with no provisioning line: this
    # reader never gated a build, and still does not.
    let malformed = fixtureRoot / "cli-malformed"
    createDir(malformed)
    writeFile(malformed / "repro.lock", "schema = \"not-a-lock\"\n")
    check buildProvisioningPins(artifact, malformed).len == 0
    # No project root and no ``--lock`` binding: no lock -- not whatever
    # ``repro.lock`` the process's working directory happens to hold.
    let cwdProject = cliProject(@[w.lockSelection(w.resolve().
      selectionFor(ToolPackage))], "cli-cwd")
    let cwd = getCurrentDir()
    setCurrentDir(cwdProject)
    check committedProvisioningLockPath("") == ""
    check buildProvisioningPins(artifact, "").len == 0
    setCurrentDir(cwd)
    # Nothing consulted the catalogs, and the key is the unpinned one --
    # byte for byte the key the CLI computed before this change.
    check catalogSourceCalls == 0
    let fixed = fixedKeyArtifact()
    check toolIdentityCacheKey(fixed, tpmTarball) == UnpinnedKeyAtF7544a7b
    for root in [noLock, plain, otherPlatform, malformed]:
      check toolIdentityCacheKey(fixed, tpmTarball,
        pins = buildProvisioningPins(fixed, root)) == UnpinnedKeyAtF7544a7b
    for root in [noLock, plain, otherPlatform, malformed]:
      check toolIdentityCacheKey(artifact, tpmTarball,
        pins = buildProvisioningPins(artifact, root)) == unpinnedKey
    # Even with no catalog source installed at all.
    setProvisioningCatalogSource(nil)
    check buildProvisioningPins(artifact, plain).len == 0
    check buildProvisioningPins(artifact, otherPlatform).len == 0
    # A cross-repo producer's runtime tools: its OWN lock governs them, and
    # a runtime artifact carries no contributed realization, so nothing is
    # selected there -- even under a lock with records and no catalog source.
    var runtimeOnly = artifact
    runtimeOnly.projectInterface.toolUses = @[InterfaceToolUse(
      rawConstraint: ToolPackage, packageSelector: ToolPackage,
      executableName: "locked-tool")]
    check producerRuntimeProvisioningPins(runtimeOnly, cwdProject).len == 0
    # A runtime use that does carry one is held to the producer's lock...
    check "M6 deliverables 1 and 2" in cliRefusal(proc () =
      discard producerRuntimeProvisioningPins(artifact, cwdProject))
    for family in ["nix", "scoop"]:
      var contributed = runtimeOnly
      if family == "nix":
        contributed.projectInterface.toolUses[0].nixProvisioning = @[
          InterfaceNixProvisioning(packageName: ToolPackage,
            contributor: ContributorA, selector: "nixpkgs#locked-tool")]
      else:
        contributed.projectInterface.toolUses[0].scoopProvisioning = @[
          InterfaceScoopProvisioning(packageName: ToolPackage,
            contributor: ContributorA, bucket: "main", app: "locked-tool")]
      check "M6 deliverables 1 and 2" in cliRefusal(proc () =
        discard producerRuntimeProvisioningPins(contributed, cwdProject))
    # ...which the consumer's ``--lock`` binding does not redirect.
    var bindings = initLockBindings()
    bindings.applyLockFlag(plain / "repro.lock")
    setActiveLockBindings(bindings)
    check buildProvisioningPins(artifact, cwdProject).len == 0
    check "M6 deliverables 1 and 2" in cliRefusal(proc () =
      discard producerRuntimeProvisioningPins(artifact, cwdProject))
    resetActiveLockBindings()
    # And the unique contributor is realized, unpinned, as before.
    let identity = warmResolveAndWriteIdentity(artifact,
      fixtureRoot / "cli-out-plain", tpmTarball,
      pins = buildProvisioningPins(artifact, plain)).identity
    check identity.realizedMarker == archiveA1.marker
    check "\ncontribution:" notin identity.profiles[0].lockIdentity
    # The same project then gains a lock pinning the same contributor: the
    # unpinned identity cached in this outDir is NOT served for it (cold
    # process, on-disk cache only)...
    w.useCatalogs()
    let pinnedPins = buildProvisioningPins(artifact, cwdProject)
    check pinnedPins.len == 1
    forgetWarmBuildCaches()
    let pinnedIdentity = warmResolveAndWriteIdentity(artifact,
      fixtureRoot / "cli-out-plain", tpmTarball, pins = pinnedPins).identity
    check ("\ncontribution:" & pinnedPins[0].contributionFingerprint & "\n") in
      pinnedIdentity.profiles[0].lockIdentity
    # ...and dropping the lock again is not served the pinned one.
    forgetWarmBuildCaches()
    let unpinnedAgain = warmResolveAndWriteIdentity(artifact,
      fixtureRoot / "cli-out-plain", tpmTarball, pins = @[]).identity
    check "\ncontribution:" notin unpinnedAgain.profiles[0].lockIdentity

  test "a realization-only change keeps the consumer's typecheck identity; an interface change moves it":
    # Deliverable 4, second half, measured in both directions. The typecheck
    # identity is the consumer's interface fingerprint and the edge that
    # compiles (typechecks) its recipe, keyed on it.
    let consumerRoot = fixtureRoot / "consumer-typecheck"
    createDir(consumerRoot)
    let module = consumerRoot / "repro.nim"
    writeFile(module, "import repro_project_dsl\n")
    proc typecheck(w: World): seq[string] =
      let artifact = w.cliArtifact(consumerRoot)
      let plan = providerCompilePlan(module,
        consumerRoot / "out" / "project-provider", artifact.interfaceFingerprint,
        workDir = getCurrentDir())
      @[hx(artifact.interfaceFingerprint), hx(plan.compileEdge.actionFingerprint),
        hx(plan.providerArtifactId)]
    let w1 = world(@[tipA1(), tipB1()])
    let project1 = cliProject(@[w1.lockSelection(w1.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))], "tc-1")
    # (1) realization-only change of the SELECTED contributor, lock refreshed.
    let w2 = world(@[Tip(contributor: ContributorA, remote: RemoteA,
      revision: RevA2, archive: archiveA2, provider: ProviderA), tipB1()])
    let project2 = cliProject(@[w2.lockSelection(w2.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))], "tc-2")
    # (2) the same change to the NON-selected contributor; the lock holds.
    let w3 = world(@[tipA1(), Tip(contributor: ContributorB, remote: RemoteB,
      revision: RevB2, archive: archiveB2, provider: ProviderB)])
    # (3) an interface change of the target -- a second public executable,
    # so the consumer's own use of the first is unchanged and only the
    # imported records' target fingerprint can move it; both republish,
    # lock refreshed.
    var packages = registeredPackages().filterIt(it.packageName != ToolPackage)
    var changed = findPackage(ToolPackage, registeredPackages())
    changed.executables.add(ExecutableDef(exportName: "lockedExtra",
      binaryName: "locked-extra"))
    packages.add(changed)
    let w4 = world(@[tipA1(), tipB1()], packages)
    let project4 = cliProject(@[w4.lockSelection(w4.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))], "tc-4")

    let base = w1.typecheck()
    check w2.typecheck() == base
    check w3.typecheck() == base
    let moved = w4.typecheck()
    for i in 0 .. 2:
      check moved[i] != base[i]
    # The lock identity (typechecking under the lock) never moves.
    check lockIdentityOf(readCommittedLock(project2 / "repro.lock")) ==
      lockIdentityOf(readCommittedLock(project1 / "repro.lock"))
    check lockIdentityOf(readCommittedLock(project4 / "repro.lock")) ==
      lockIdentityOf(readCommittedLock(project1 / "repro.lock"))

    # Realization and build keys, through the CLI path into one outDir.
    let outDir = fixtureRoot / "cli-out-typecheck"
    w1.useCatalogs()
    let b1 = w1.cliBuild(project1, outDir)
    w2.useCatalogs()
    let b2 = w2.cliBuild(project2, outDir)
    w3.useCatalogs()
    let b3 = w3.cliBuild(project1, outDir)
    check b1.realizedMarker == archiveA1.marker
    check b2.realizedMarker == archiveA2.marker   # never A1's cached identity
    check b2.profiles[0].selectedStorePath != b1.profiles[0].selectedStorePath
    check b2.profiles[0].profileFingerprint != b1.profiles[0].profileFingerprint
    check b2.actionIdentities[0].actionFingerprint !=
      b1.actionIdentities[0].actionFingerprint
    check b3.realizedMarker == archiveA1.marker
    check b3.profiles[0].profileFingerprint == b1.profiles[0].profileFingerprint
    check b3.actionIdentities[0].actionFingerprint ==
      b1.actionIdentities[0].actionFingerprint
    # The realization metadata the typecheck identity no longer carries is
    # still bound where it is READ: the CLI tool-identity key moves for both
    # realization changes although the interface fingerprint did not.
    let pins1 = w1.resolve(claimsOf(project1 / "repro.lock")).pinsOf
    check w3.cliArtifact().interfaceFingerprint ==
      w1.cliArtifact().interfaceFingerprint
    check toolIdentityCacheKey(w3.cliArtifact(), tpmTarball, pins = pins1) !=
      toolIdentityCacheKey(w1.cliArtifact(), tpmTarball, pins = pins1)
    check toolIdentityCacheKey(w2.cliArtifact(), tpmTarball) !=
      toolIdentityCacheKey(w1.cliArtifact(), tpmTarball)
    # Including a realization field the key's own tool-use field list does
    # not name (``prunePaths``): only the imported-metadata digest binds it
    # now that the interface fingerprint does not.
    var pruned = w1.consumer
    for c in pruned.provisioningContributions.mitems:
      if c.contributor == ContributorB:
        c.tarballProvisioning[0].prunePaths = @["share/doc"]
    for u in pruned.toolUses.mitems:
      for t in u.tarballProvisioning.mitems:
        if t.contributor == ContributorB:
          t.prunePaths = @["share/doc"]
    var prunedWorld = w1
    prunedWorld.consumer = pruned
    check prunedWorld.cliArtifact().interfaceFingerprint ==
      w1.cliArtifact().interfaceFingerprint
    check toolIdentityCacheKey(prunedWorld.cliArtifact(), tpmTarball,
      pins = pins1) != toolIdentityCacheKey(w1.cliArtifact(), tpmTarball,
      pins = pins1)
    check toolIdentityCacheKey(prunedWorld.cliArtifact(), tpmTarball) !=
      toolIdentityCacheKey(w1.cliArtifact(), tpmTarball)
    # The catalog direction: the same records as a project's OWN (a catalog
    # project) still move its interface fingerprint.
    check artifactFor(w3.consumer).interfaceFingerprint !=
      artifactFor(w1.consumer).interfaceFingerprint
    check artifactFor(w2.consumer).interfaceFingerprint !=
      artifactFor(w1.consumer).interfaceFingerprint

  test "an explicitly named lock that cannot be read, and records the reader does not read, refuse rather than build unpinned":
    # Found by the M7 verifier, probing from outside. Each of these used to
    # yield NO pin -- an unpinned build of a lock that pins a contributor.
    let w = world(@[tipA1(), tipB1()])
    w.useCatalogs()
    let artifact = w.cliArtifact()
    let record = w.lockSelection(w.resolve(
      policy = policyFor(ContributorA)).selectionFor(ToolPackage))
    let project = cliProject(@[record], "explicit-lock")
    # (1) ``--lock`` naming a file that does not exist, or a directory, is
    # missing evidence the user asked for -- not "no lock". The implicit
    # ``<project>/repro.lock`` being absent still means no lock.
    for bound in [fixtureRoot / "no-such-dir" / "repro.lock",
                  fixtureRoot / "a-directory"]:
      createDir(fixtureRoot / "a-directory")
      var bindings = initLockBindings()
      bindings.applyLockFlag(bound)
      setActiveLockBindings(bindings)
      let text = cliRefusal(proc () =
        discard buildProvisioningPins(artifact, project))
      resetActiveLockBindings()
      check "provisioning selection refused" in text
      check "cannot be read" in text
    let empty = fixtureRoot / "explicit-lock-empty-project"
    createDir(empty)
    check buildProvisioningPins(artifact, empty).len == 0
    createDir(empty / "repro.lock")
    check buildProvisioningPins(artifact, empty).len == 0
    # (2) A lock that exists but cannot be read refuses with the selection's
    # own refusal, explicit or implicit (a raw I/O error used to escape).
    when defined(windows):
      let unreadable = fixtureRoot / "unreadable-lock"
      createDir(unreadable)
      copyFile(project / "repro.lock", unreadable / "repro.lock")
      let user = getEnv("USERNAME")
      let denied = execCmdEx("icacls " & quoteShell(unreadable / "repro.lock") &
        " /deny " & quoteShell(user & ":(R)"))
      check denied.exitCode == 0
      var bindings = initLockBindings()
      bindings.applyLockFlag(unreadable / "repro.lock")
      setActiveLockBindings(bindings)
      check "cannot be read" in cliRefusal(proc () =
        discard buildProvisioningPins(artifact, empty))
      resetActiveLockBindings()
      check "cannot be read" in cliRefusal(proc () =
        discard buildProvisioningPins(artifact, unreadable))
      discard execCmdEx("icacls " & quoteShell(unreadable / "repro.lock") &
        " /remove:d " & quoteShell(user))
      check buildProvisioningPins(artifact, unreadable)[0].contributor ==
        ContributorA
    # (3) Spellings of the key the strict reader does not read refuse even
    # BESIDE a record it does read (here one for another platform, so the
    # read part pins nothing on this host), and escaped spellings refuse on
    # their own.
    let other = if Host == "arm64-linux": "amd64-linux" else: "arm64-linux"
    let s = w.resolve(policy = policyFor(ContributorA)).selectionFor(ToolPackage)
    let foreign = lockSelectedRealization(RealizationLockRequest(
      selection: s.selection, identity: s.identity,
      realizationLockIdentity: "sha256:" & archiveA1.sha256,
      hostPlatform: other, targetPlatform: other, capabilities: @[]),
      noContributionResolver)
    check foreign.locked
    # A record made on another HOST for this target is not this platform
    # pair either: it governs nothing here, and (production, no catalog
    # source) is not refused as though it did.
    let crossHost = lockSelectedRealization(RealizationLockRequest(
      selection: s.selection, identity: s.identity,
      realizationLockIdentity: "sha256:" & archiveA1.sha256,
      hostPlatform: other, targetPlatform: Target, capabilities: @[]),
      noContributionResolver)
    check crossHost.locked
    let crossTarget = lockSelectedRealization(RealizationLockRequest(
      selection: s.selection, identity: s.identity,
      realizationLockIdentity: "sha256:" & archiveA1.sha256,
      hostPlatform: Host, targetPlatform: other, capabilities: @[]),
      noContributionResolver)
    check crossTarget.locked
    setProvisioningCatalogSource(nil)
    check buildProvisioningPins(artifact,
      cliProject(@[crossHost.record], "cross-host")).len == 0
    check buildProvisioningPins(artifact,
      cliProject(@[crossTarget.record], "cross-target")).len == 0
    w.useCatalogs()
    let lockText = readFile(project / "repro.lock")
    let plainLock = lockText.splitLines().filterIt(
      not it.startsWith(ProvisioningLockKey)).join("\n")
    let hostLine = lockText.splitLines().filterIt(
      it.startsWith(ProvisioningLockKey))[0]
    let hostRecords = hostLine[hostLine.find('=') + 1 .. ^1].strip()
    let foreignText = serializeLockedDependencies(
      baseLock().withProvisioningRealizations(@[foreign.record]))
    let foreignLine = foreignText.splitLines().filterIt(
      it.startsWith(ProvisioningLockKey))[0]
    let mixed = fixtureRoot / "mixed-spellings"
    createDir(mixed)
    for spelling in ["\"provisioning\" = " & hostRecords,
                     "'provisioning' = " & hostRecords,
                     "[[provisioning]]\nrecord = \"x\"",
                     "provisioning.x = 1",
                     "\"\\u0070rovisioning\" = " & hostRecords,
                     "\"provisioni\\u006Eg\" = " & hostRecords,
                     "\"\\U00000070rovisioning\" = " & hostRecords,
                     "[[\"\\u0070rovisioning\"]]\nrecord = \"x\"",
                     "\xEF\xBB\xBFprovisioning = " & hostRecords]:
      for withForeign in [true, false]:
        let body =
          if withForeign: plainLock & "\n" & foreignLine & "\n" & spelling
          else: plainLock & "\n" & spelling
        writeFile(mixed / "repro.lock", body & "\n")
        let text = cliRefusal(proc () =
          discard buildProvisioningPins(artifact, mixed))
        check "not read" in text
        # ...and with no catalog source installed (production) as well.
        setProvisioningCatalogSource(nil)
        check "not read" in cliRefusal(proc () =
          discard buildProvisioningPins(artifact, mixed))
        w.useCatalogs()
    # The writer's own form, indented or with CRLF line ends, is still read.
    for body in [plainLock & "\n\t" & hostLine,
                 (plainLock & "\n" & hostLine).replace("\n", "\r\n")]:
      writeFile(mixed / "repro.lock", body & "\n")
      check buildProvisioningPins(artifact, mixed)[0].contributor ==
        ContributorA
    # A key merely CONTAINING the word elsewhere in the document is not the
    # provisioning key: an inline-table member of another key.
    writeFile(mixed / "repro.lock", plainLock & "\n" &
      "x = { provisioning = 1 }\n")
    check buildProvisioningPins(artifact, mixed).len == 0

  removeDir(fixtureRoot)

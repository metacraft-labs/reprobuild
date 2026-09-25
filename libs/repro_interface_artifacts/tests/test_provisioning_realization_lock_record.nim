## M7 deliverable 2 -- the locked provisioning realization.
##
## ``ReproOS-Campaign-Completion.milestones.org`` § M7:
##
##   Serialize catalog coordinates, exact revision, selected contributor,
##   contribution fingerprint, platform, capabilities, and realization lock
##   identity.
##
## Normative design: ``reprobuild-specs/Provisioning-Contributions.md``
## § Locks And Snapshots. The record is one more array (``provisioning``)
## inside the EXISTING committed lock, ``repro.lock`` /
## ``reprobuild.solved-graph-lock.v2``, written by ``repro_lock``'s
## ``serializeLockedDependencies`` and read by ``parseLockedDependencies``.
## The record module is ``repro_lock/provisioning``; the writer that turns a
## composed selection into a record is
## ``repro_interface_artifacts/contribution_lock``.
##
## ## Mocks
##
## None. The packages are declared through the real ``package`` DSL and
## lifted through the real ``toProjectInterface`` / ``interfaceFingerprint``
## path; catalogs are composed by the real ``composeCatalogs``; contribution
## fingerprints are computed by the real ``contributionFingerprint``; locks
## are written and read by the real ``repro_lock`` codec. The only callback
## is ``ContributionResolver``, a production parameter of the composer.
##
## ## What this file does NOT prove
##
##   * Nothing about a resolver SELECTING from the lock (M7 deliverable 3)
##     or about per-edge invalidation in the engine (deliverable 4): here
##     "invalidates the locked realization" is asserted as the record being
##     REFUSED on read against the current facts. Both are exercised by
##     ``tests/integration/t_e2e_locked_provisioning_contributor_selection``.
##   * Platform/ABI filtering of a realization (spec § Resolution step 4):
##     the platform pair and capabilities are recorded as the caller states
##     them.

import std/[algorithm, options, os, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_interface_artifacts/contribution_fingerprint
import repro_interface_artifacts/contribution_lock
import repro_lock
import repro_project_dsl
import repro_project_dsl/source_cache_identity

package lockedTarget:
  executable lockedTarget:
    name "locked-target"
    cli:
      subcmd "run":
        flag verbose, bool

package lockedHelper:
  executable lockedHelper:
    name "locked-helper"
    cli:
      subcmd "help":
        flag quiet, bool

package lockedCatalog:
  defaultToolProvisioning "nix"
  uses:
    "lockedTarget"

const
  NixContributor = "github:metacraft-labs/reprobuild-nix-packages"
  ScoopContributor = "github:metacraft-labs/reprobuild-scoop-packages"
  DevelopContributor = "github:example/develop-catalog"
  PackagesRemote = "github:metacraft-labs/reprobuild-packages"
  NixRemote = "github:metacraft-labs/reprobuild-nix-packages"
  ScoopRemote = "github:metacraft-labs/reprobuild-scoop-packages"
  DevelopRemote = "github:example/develop-catalog"
  Workspace = "github:metacraft-labs/reproos"
  PackagesRev = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
  NixRev = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
  ScoopRev = "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3"
  DevelopRev = "e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5"
  NixpkgsRev = "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"
  NarHashA = "sha256-" & repeat('A', 43) & "="
  NarHashB = "sha256-" & repeat('B', 43) & "="
  ScoopChecksum = repeat('c', 64)
  ProviderA = repeat('a', 64)
  ProviderB = repeat('b', 64)
  Host = "amd64-linux"
  Target = "amd64-linux"

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

proc canonicalFingerprint(name: string): string =
  canonicalPackageInterfaceFingerprint(findPackage(name), registeredPackages())

proc nixLockIdentity(selector: string; narHash = NarHashA): string =
  ## The spelling the ``nixPackage`` macro derives for a nixpkgs selector.
  "github:NixOS/nixpkgs/" & NixpkgsRev & "?narHash=" & narHash & "#" &
    selector["nixpkgs#".len .. ^1]

proc nixDef(selector = "nixpkgs#hello"; narHash = NarHashA;
            lockIdentity = ""): NixPackageProvisioningDef =
  NixPackageProvisioningDef(
    selector: selector,
    executablePath: "bin/hello",
    nixpkgsRef: "github:NixOS/nixpkgs",
    nixpkgsRev: NixpkgsRev,
    nixpkgsNarHash: narHash,
    packageId: "hello@2.12.2",
    lockIdentity:
      if lockIdentity.len > 0: lockIdentity
      else: nixLockIdentity(selector, narHash))

proc scoopLockIdentity(): string = "scoop:main/hello:" & ScoopChecksum

proc scoopDef(): ScoopProvisioningDef =
  ScoopProvisioningDef(
    bucket: "main",
    app: "hello",
    version: "2.12.2",
    manifestChecksum: ScoopChecksum,
    manifestUrl: "https://example.invalid/main/hello.json",
    executablePath: "bin/hello.exe",
    packageId: "main/hello@2.12.2",
    lockIdentity: scoopLockIdentity())

proc lifted(targetPackage, contributor: string;
            nix: seq[NixPackageProvisioningDef] = @[];
            scoop: seq[ScoopProvisioningDef] = @[];
            tarball: seq[TarballProvisioningDef] = @[];
            sourceFile = "catalog/entry.nim"; line = 1;
            developInterface = false;
            packages: seq[PackageDef] = @[]):
    InterfaceProvisioningContribution =
  ## Lift a contribution through the PRODUCTION projection, so the record
  ## composed and locked below is the record an interface artifact carries.
  let candidates = if packages.len > 0: packages else: registeredPackages()
  var targetFp = ""
  for pkg in candidates:
    if pkg.packageName == targetPackage:
      targetFp = canonicalPackageInterfaceFingerprint(pkg, candidates)
  let def = ProvisioningContributionDef(
    targetPackage: targetPackage,
    targetInterfaceFingerprint: if developInterface: "" else: targetFp,
    contributor: contributor,
    developInterface: developInterface,
    nixProvisioning: nix,
    scoopProvisioning: scoop,
    tarballProvisioning: tarball,
    sourceFile: sourceFile,
    sourceLine: line)
  let catalog = toProjectInterface(findPackage("lockedCatalog"), candidates,
    @[def])
  catalog.provisioningContributions[0]

proc artifactIdentityOf(content: CatalogContent): string =
  var pi = toProjectInterface(findPackage("lockedCatalog"),
    registeredPackages(), @[])
  pi.provisioningContributions = content.contributions
  catalogArtifactIdentity(@[artifactFor(pi)])

proc catalogAt(remote, revision, discoveredAt: string;
               content: CatalogContent): CatalogImport =
  CatalogImport(
    coordinate: CatalogCoordinate(workspace: Workspace, remote: remote,
      revision: revision, interfaceArtifact: artifactIdentityOf(content)),
    discoveredAt: discoveredAt,
    content: some(content))

proc interfacesCatalog(discoveredAt = "/w/reprobuild-packages"):
    CatalogImport =
  catalogAt(PackagesRemote, PackagesRev, discoveredAt, CatalogContent(
    canonicalInterfaces: @[
      catalogInterface("lockedTarget", canonicalFingerprint("lockedTarget")),
      catalogInterface("lockedHelper", canonicalFingerprint("lockedHelper"))],
    contributions: @[]))

proc targetNix(sourceFile = "catalog/target.nim"; narHash = NarHashA):
    InterfaceProvisioningContribution =
  lifted("lockedTarget", NixContributor, nix = @[nixDef(narHash = narHash)],
    sourceFile = sourceFile, line = 11)

proc helperNix(sourceFile = "catalog/helper.nim"):
    InterfaceProvisioningContribution =
  lifted("lockedHelper", NixContributor,
    nix = @[nixDef("nixpkgs#helper")], sourceFile = sourceFile, line = 22)

proc targetScoop(): InterfaceProvisioningContribution =
  lifted("lockedTarget", ScoopContributor, scoop = @[scoopDef()],
    sourceFile = "catalog/scoop.nim", line = 33)

proc nixCatalog(discoveredAt = "/w/reprobuild-nix-packages";
                revision = NixRev; sourceDir = "catalog";
                narHash = NarHashA): CatalogImport =
  catalogAt(NixRemote, revision, discoveredAt, CatalogContent(
    canonicalInterfaces: @[],
    contributions: @[targetNix(sourceDir & "/target.nim", narHash),
                     helperNix(sourceDir & "/helper.nim")]))

proc scoopCatalog(): CatalogImport =
  catalogAt(ScoopRemote, ScoopRev, "/w/reprobuild-scoop-packages",
    CatalogContent(canonicalInterfaces: @[],
      contributions: @[targetScoop()]))

proc policy(contributor: string): CatalogSelectionPolicy =
  CatalogSelectionPolicy(selections: @[CatalogSelectionRule(
    targetPackage: "lockedTarget", contributor: contributor)])

proc selectionOf(composition: CatalogComposition;
                 packageName: string): CatalogSelection =
  for s in composition.selections:
    if s.targetPackage == packageName:
      return s
  raise newException(ValueError, "no selection for " & packageName &
    ": " & composition.diagnosticReport)

proc helperRef(): ContributionDependencyRef =
  ContributionDependencyRef(targetPackage: "lockedHelper",
    contributor: NixContributor,
    targetInterfaceFingerprint: canonicalFingerprint("lockedHelper"))

proc identityOf(contribution: InterfaceProvisioningContribution;
                provider = ProviderA;
                dependencies: seq[ContributionDependencyRef] = @[]):
    ContributionIdentity =
  ContributionIdentity(contribution: contribution,
    providerIdentity: provider, dependencies: dependencies)

proc bindingResolver(dep: ContributionDependencyRef):
    Option[ContributionIdentity] {.gcsafe.} =
  ## Binds the helper dependency to its REAL contribution identity.
  {.cast(gcsafe).}:
    if dep.targetPackage == "lockedHelper" and
        dep.contributor == NixContributor:
      return some(identityOf(helperNix()))
  none(ContributionIdentity)

proc request(selection: CatalogSelection; identity: ContributionIdentity;
             lockIdentity: string; host = Host; target = Target;
             capabilities = @["cuda", "x86-64-v3"]): RealizationLockRequest =
  RealizationLockRequest(selection: selection, identity: identity,
    realizationLockIdentity: lockIdentity, hostPlatform: host,
    targetPlatform: target, capabilities: capabilities)

proc lockOrFail(req: RealizationLockRequest;
                resolver: ContributionResolver = bindingResolver):
    LockedRealization =
  let outcome = lockSelectedRealization(req, resolver)
  if not outcome.locked:
    raise newException(ValueError, "refused: " & outcome.refusals.join("; "))
  outcome.record

proc baseLock(): LockedDependencies =
  ## A real solved-graph lock with a deps set, as ``repro lock refresh``
  ## writes one; the provisioning array is added to it.
  parseLockedDependencies(serializeLockedDependencies(LockedDependencies(
    schema: SolvedGraphLockSchemaV2, platform: Host, optimal: true,
    inputsDigest: inputsDigestOf("solver-inputs"),
    variants: @[LockedVariant(name: "compiler", value: "clang")],
    packages: @[LockedPackage(name: "nim", version: "2.2.8", source: "nim",
      selection: ssSelected)],
    deps: @[LockedDep(name: "reprobuild", path: ".",
      coordinates: Coordinates(kind: ckVcs,
        url: "https://github.com/metacraft-labs/reprobuild",
        gitRef: "main", revision: NixRev),
      integrity: "blake3:" & ProviderA, visibility: "public")])))

proc documentWith(records: seq[LockedRealization]): string =
  serializeLockedDependencies(baseLock().withProvisioningRealizations(records))

proc provisioningLine(document: string): string =
  for line in document.splitLines():
    if line.startsWith(ProvisioningLockKey & " = "):
      return line
  raise newException(ValueError, "no provisioning line")

proc replaceLine(document, old, replacement: string): string =
  document.replace(old, replacement)

proc parseRefusal(document: string): string =
  ## The reader's refusal text, or "" if it ACCEPTED the document.
  try:
    discard parseLockedDependencies(document)
    ""
  except SolvedGraphLockParseError as err:
    err.msg

proc refusesAsAbsent(ld: LockedDependencies;
                     packageName, host, target: string;
                     interfaceFp, contributionFp: string): bool =
  ## True iff the reader refuses because the lock records NO realization for
  ## this key -- not because some record it made up is stale.
  try:
    discard ld.lockedRealizationFor(packageName, host, target, interfaceFp,
      contributionFp)
    false
  except StaleLockedRealizationError:
    false
  except LockedRealizationError as err:
    "records no provisioning realization" in err.msg

proc currentHexOf(identity: ContributionIdentity): string =
  currentContributionFingerprint(identity, bindingResolver).get

proc standardComposition(): CatalogComposition =
  composeCatalogs(@[interfacesCatalog(), nixCatalog(), scoopCatalog()],
    policy(NixContributor))

proc targetRecord(capabilities = @["cuda", "x86-64-v3"]): LockedRealization =
  let composition = standardComposition()
  lockOrFail(request(composition.selectionOf("lockedTarget"),
    identityOf(targetNix()), nixLockIdentity("nixpkgs#hello"),
    capabilities = capabilities))

proc helperRecord(): LockedRealization =
  let composition = standardComposition()
  lockOrFail(request(composition.selectionOf("lockedHelper"),
    identityOf(helperNix()), nixLockIdentity("nixpkgs#helper"),
    capabilities = @[]))

suite "provisioning realization lock record":

  test "a locked realization round-trips byte-identically":
    let target = targetRecord()
    let helper = helperRecord()
    let document = documentWith(@[target, helper])
    let parsed = parseLockedDependencies(document)
    check serializeLockedDependencies(parsed) == document
    check parsed.provisioningRealizationCount == 2

    # Every field the spec lists comes back as written.
    let back = parsed.lockedRealizationFor("lockedTarget", Host, Target,
      canonicalFingerprint("lockedTarget"), currentHexOf(identityOf(
        targetNix())))
    check back.packageName == "lockedTarget"
    check back.interfaceFingerprint == canonicalFingerprint("lockedTarget")
    check back.contributor == NixContributor
    check back.contributionFingerprint ==
      currentHexOf(identityOf(targetNix()))
    check back.catalogWorkspace == Workspace
    check back.catalogRemote == NixRemote
    check back.catalogRevision == NixRev
    check back.catalogInterfaceArtifact ==
      nixCatalog().coordinate.interfaceArtifact
    check back.realizationKind == lrkNix
    check back.realizationLockIdentity == nixLockIdentity("nixpkgs#hello")
    check back.realizationIntegrity == NarHashA
    check back.hostPlatform == Host
    check back.targetPlatform == Target
    check back.capabilities == @["cuda", "x86-64-v3"]
    check back.selectedBy == lsrCuratorPolicy
    check canonicalRealizationEntry(back) == canonicalRealizationEntry(target)
    let helperBack = parsed.lockedRealizationFor("lockedHelper", Host, Target,
      canonicalFingerprint("lockedHelper"), currentHexOf(identityOf(
        helperNix())))
    check helperBack.capabilities.len == 0
    check helperBack.selectedBy == lsrUniqueEligible
    check canonicalRealizationEntry(helperBack) ==
      canonicalRealizationEntry(helper)

    # The record is pinned by value, so a silent change to the encoding
    # cannot pass as a round trip that merely agrees with itself.
    check provisioningLine(document).startsWith(
      "provisioning = [{ record = \"" & LockedRealizationRecordV1 &
      "\", package = \"lockedHelper\", interface = \"" &
      canonicalFingerprint("lockedHelper") & "\", contributor = \"" &
      NixContributor & "\", contribution = \"")
    check canonicalRealizationEntry(target).endsWith(
      "catalog_workspace = \"" & Workspace & "\", catalog_remote = \"" &
      NixRemote & "\", catalog_revision = \"" & NixRev &
      "\", catalog_interface_artifact = \"" &
      nixCatalog().coordinate.interfaceArtifact &
      "\", realization = \"nix\", realization_lock_identity = \"" &
      nixLockIdentity("nixpkgs#hello") & "\", realization_integrity = \"" &
      NarHashA & "\", host_platform = \"amd64-linux\", target_platform = " &
      "\"amd64-linux\", capabilities = \"cuda,x86-64-v3\", selected_by = " &
      "\"curator-policy\" }")

    # The solved-graph part is untouched and the record does not move the
    # §6.2 lock identity (a contribution-only refresh must not invalidate
    # typechecking, which that identity governs).
    check parseSolvedGraphLock(document).packages ==
      baseLock().solvedPartOf.packages
    check lockIdentityOf(parsed) == lockIdentityOf(baseLock())

  test "the encoding is canonical whatever order the selection arrived in":
    let reference = documentWith(@[targetRecord(), helperRecord()])
    # Records supplied in the other order.
    check documentWith(@[helperRecord(), targetRecord()]) == reference
    # Capabilities supplied permuted and repeated: a set.
    check documentWith(@[targetRecord(@["x86-64-v3", "cuda", "cuda"]),
      helperRecord()]) == reference
    # Hex supplied in upper case is the same identity.
    let composition = standardComposition()
    var upper = composition.selectionOf("lockedTarget")
    upper.catalogCoordinate.revision = NixRev.toUpperAscii()
    upper.catalogCoordinate.interfaceArtifact =
      upper.catalogCoordinate.interfaceArtifact.toUpperAscii()
    check documentWith(@[lockOrFail(request(upper, identityOf(targetNix()),
      nixLockIdentity("nixpkgs#hello"))), helperRecord()]) == reference
    # A pin spelled with its algorithm prefix, in upper case, is the same
    # canonical interface (the spellings the DSL and the codec accept).
    var prefixed = targetNix()
    prefixed.targetInterfaceFingerprint = "BLAKE3-256:" &
      canonicalFingerprint("lockedTarget").toUpperAscii()
    check documentWith(@[lockOrFail(request(
      composition.selectionOf("lockedTarget"), identityOf(prefixed),
      nixLockIdentity("nixpkgs#hello"))), helperRecord()]) == reference
    # Every permutation of the catalog imports composes to a selection that
    # locks to the same bytes.
    var imports = @[interfacesCatalog(), nixCatalog(), scoopCatalog()]
    var order = @[0, 1, 2]
    var seen = 0
    while true:
      let permuted = composeCatalogs(order.mapIt(imports[it]),
        policy(NixContributor))
      let records = @[
        lockOrFail(request(permuted.selectionOf("lockedTarget"),
          identityOf(targetNix()), nixLockIdentity("nixpkgs#hello"))),
        lockOrFail(request(permuted.selectionOf("lockedHelper"),
          identityOf(helperNix()), nixLockIdentity("nixpkgs#helper"),
          capabilities = @[]))]
      check documentWith(records) == reference
      inc seen
      if not order.nextPermutation(): break
    check seen == 6

  test "no host path, discoveredAt or source location enters the record":
    # One logical catalog set, found at Windows paths with Windows source
    # locations on one host and at POSIX paths on another.
    let windows = composeCatalogs(@[
      interfacesCatalog("C:\\Users\\dev\\reprobuild-packages"),
      nixCatalog("C:\\Users\\dev\\reprobuild-nix-packages",
        sourceDir = "C:\\Users\\dev\\reprobuild-nix-packages\\catalog"),
      scoopCatalog()], policy(NixContributor))
    let posix = composeCatalogs(@[
      interfacesCatalog("/home/dev/reprobuild-packages"),
      nixCatalog("/home/dev/reprobuild-nix-packages",
        sourceDir = "/home/dev/reprobuild-nix-packages/catalog"),
      scoopCatalog()], policy(NixContributor))
    check not windows.refused
    check not posix.refused
    let onWindows = documentWith(@[lockOrFail(request(
      windows.selectionOf("lockedTarget"),
      identityOf(targetNix("C:\\Users\\dev\\reprobuild-nix-packages\\" &
        "catalog\\target.nim")), nixLockIdentity("nixpkgs#hello")))])
    let onPosix = documentWith(@[lockOrFail(request(
      posix.selectionOf("lockedTarget"),
      identityOf(targetNix("/home/dev/reprobuild-nix-packages/catalog/" &
        "target.nim")), nixLockIdentity("nixpkgs#hello")))])
    check onWindows == onPosix
    let line = provisioningLine(onWindows)
    check "\\" notin line
    check "C:" notin line
    check "/home/" notin line
    check "Users" notin line
    check "target.nim" notin line

    # And a value that SPELLS a host location refuses, in every field that
    # could carry one.
    let composition = standardComposition()
    let selection = composition.selectionOf("lockedTarget")
    for remote in ["/srv/git/reprobuild-nix-packages",
                   "C:/git/reprobuild-nix-packages",
                   "c:\\git\\reprobuild-nix-packages",
                   "file:///srv/git/reprobuild-nix-packages",
                   "../reprobuild-nix-packages",
                   "./reprobuild-nix-packages",
                   "git\\reprobuild-nix-packages",
                   "~/reprobuild-nix-packages",
                   "ssh://host/D:/git/reprobuild-nix-packages",
                   # Verifier additions (M7 D2 verification): a file: URL
                   # behind a compound scheme, a scheme whose path is
                   # absolute on THIS host (no authority), a drive-relative
                   # path, and a one-letter scheme -- which cannot be told
                   # apart from a drive letter, so it refuses too.
                   "git+file:///srv/git/reprobuild-nix-packages",
                   "GIT+FILE:///srv/git/reprobuild-nix-packages",
                   "git+file://fileserver/git/reprobuild-nix-packages",
                   "path:/srv/git/reprobuild-nix-packages",
                   "nix:/nix/store/reprobuild-nix-packages",
                   "C:git/reprobuild-nix-packages",
                   "x:metacraft-labs/reprobuild-nix-packages"]:
      var moved = selection
      moved.catalogCoordinate.remote = remote
      let outcome = lockSelectedRealization(request(moved,
        identityOf(targetNix()), nixLockIdentity("nixpkgs#hello")),
        bindingResolver)
      check not outcome.locked
      check outcome.refusals.anyIt(it.startsWith("field catalog_remote:"))
    # A URL -- including one whose path is absolute on the REMOTE host --
    # is a remote, not a host path.
    for remote in ["https://git.example.invalid/reprobuild-nix-packages",
                   "git+https://git.example.invalid/reprobuild-nix-packages",
                   "ssh://git.example.invalid/srv/git/reprobuild-nix-packages"]:
      var remoteOk = selection
      remoteOk.catalogCoordinate.remote = remote
      check lockSelectedRealization(request(remoteOk,
        identityOf(targetNix()), nixLockIdentity("nixpkgs#hello")),
        bindingResolver).locked
    var workspace = selection
    workspace.catalogCoordinate.workspace = "C:\\Users\\dev\\reproos"
    check lockSelectedRealization(request(workspace, identityOf(targetNix()),
      nixLockIdentity("nixpkgs#hello")), bindingResolver).refusals.anyIt(
        it.startsWith("field catalog_workspace:"))
    let pathLocked = lifted("lockedTarget", NixContributor,
      nix = @[nixDef(lockIdentity = "nix:C:/nix/hello.nix")])
    let pathComposition = composeCatalogs(@[interfacesCatalog(),
      catalogAt(NixRemote, NixRev, "/w/nix", CatalogContent(
        contributions: @[pathLocked]))], CatalogSelectionPolicy())
    check lockSelectedRealization(request(
      pathComposition.selectionOf("lockedTarget"), identityOf(pathLocked),
      "nix:C:/nix/hello.nix"), bindingResolver).refusals.anyIt(
        it.startsWith("field realization_lock_identity:"))
    # A realization declared through a LOCAL flake reference (the nix
    # ``path:`` and ``git+file:`` schemes) is a host path too.
    for localRef in ["path:/home/dev/nixpkgs#hello",
                     "git+file:///home/dev/nixpkgs#hello"]:
      let localLocked = lifted("lockedTarget", NixContributor,
        nix = @[nixDef(lockIdentity = localRef)])
      let localComposition = composeCatalogs(@[interfacesCatalog(),
        catalogAt(NixRemote, NixRev, "/w/nix", CatalogContent(
          contributions: @[localLocked]))], CatalogSelectionPolicy())
      check lockSelectedRealization(request(
        localComposition.selectionOf("lockedTarget"), identityOf(localLocked),
        localRef), bindingResolver).refusals.anyIt(
          it.startsWith("field realization_lock_identity:"))
    # EVERY free-text field refuses a host location, the package name
    # included, whether the record is sealed directly or read back.
    let sealedTarget = targetRecord()
    for leak in ["C:\\Users\\dev\\x", "/home/dev/x", "file:///home/dev/x",
                 "git+file:///home/dev/x", "path:/home/dev/x", "C:x",
                 "~/x", "..\\x"]:
      for field in ["package", "contributor", "catalog_workspace",
                    "catalog_remote", "realization_lock_identity"]:
        var edited = sealedTarget
        case field
        of "package": edited.packageName = leak
        of "contributor": edited.contributor = leak
        of "catalog_workspace": edited.catalogWorkspace = leak
        of "catalog_remote": edited.catalogRemote = leak
        else: edited.realizationLockIdentity = leak
        var refusal = ""
        try:
          discard sealLockedRealization(edited, ContributionEvidence(
            fingerprintHex: edited.contributionFingerprint))
        except LockedRealizationError as err:
          refusal = err.msg
        if ("field " & field & ":") notin refusal:
          checkpoint(field & " accepted " & leak.escape)
        check ("field " & field & ":") in refusal
    let leakDocument = documentWith(@[sealedTarget])
    check "field package:" in parseRefusal(leakDocument.replace(
      "package = \"lockedTarget\"", "package = \"/home/dev/lockedTarget\""))
    check "field package:" in parseRefusal(leakDocument.replace(
      "package = \"lockedTarget\"", "package = \"C:\\\\lockedTarget\""))

  test "the writer refuses a fingerprint that is resolved but not fully resolved":
    # THE alias M7 deliverable 1 left for this deliverable: the target's
    # contribution depends on the helper; composed in declaration space
    # only, the helper folds in as its coordinate LEAF.
    let composition = standardComposition()
    let identity = identityOf(targetNix(), dependencies = @[helperRef()])
    let leafPadded = lockSelectedRealization(request(
      composition.selectionOf("lockedTarget"), identity,
      nixLockIdentity("nixpkgs#hello")), noContributionResolver)
    check leafPadded.fingerprint.isResolved          # a usable hex...
    check leafPadded.fingerprint.hex.len == 64
    check not leafPadded.fingerprint.dependenciesFullyResolved  # ...leaf-padded
    check not leafPadded.locked
    check leafPadded.refusals.anyIt(
      it.startsWith("dependencies-not-fully-resolved:") and
      "lockedHelper@" & NixContributor in it)
    # ... and the seal's own gate holds on the writer's path as well.
    check leafPadded.refusals.anyIt(
      it.startsWith("evidence: the contribution fingerprint is not fully") and
      "lockedHelper@" & NixContributor in it)
    expect LockedRealizationError:
      discard serializeProvisioningRealizations(@[leafPadded.record])

    # The control: the same selection with a resolver that binds the
    # helper locks, and to a DIFFERENT contribution fingerprint.
    let bound = lockSelectedRealization(request(
      composition.selectionOf("lockedTarget"), identity,
      nixLockIdentity("nixpkgs#hello")), bindingResolver)
    check bound.locked
    check bound.record.contributionFingerprint != leafPadded.fingerprint.hex

    # The same gate holds for a caller that seals directly ...
    var draft = bound.record
    expect LockedRealizationError:
      discard sealLockedRealization(draft, ContributionEvidence(
        fingerprintHex: draft.contributionFingerprint,
        unresolvedDependencies: @[contributionCoordinate(helperRef())]))
    expect LockedRealizationError:
      discard sealLockedRealization(draft, ContributionEvidence(
        fingerprintHex: draft.contributionFingerprint,
        refusals: @["provider identity"]))
    expect LockedRealizationError:
      discard sealLockedRealization(draft, ContributionEvidence(
        fingerprintHex: leafPadded.fingerprint.hex))
    check sealLockedRealization(draft, ContributionEvidence(
      fingerprintHex: draft.contributionFingerprint)).isSealed
    # ... for a record built or edited by hand, which carries no seal ...
    draft.contributionFingerprint = leafPadded.fingerprint.hex
    check not draft.isSealed
    expect LockedRealizationError:
      discard serializeProvisioningRealizations(@[draft])
    # ... and for the fingerprint a record is checked AGAINST.
    check currentContributionFingerprint(identity,
      noContributionResolver).isNone
    check currentContributionFingerprint(identity, bindingResolver).get ==
      bound.record.contributionFingerprint

  test "a developInterface contribution is refused":
    # Composition itself selects a develop-bound contribution -- nothing in
    # M6 refuses it -- so the lock writer is where it must stop.
    let develop = lifted("lockedTarget", DevelopContributor,
      nix = @[nixDef()], developInterface = true)
    check develop.developInterface
    let composition = composeCatalogs(@[interfacesCatalog(),
      catalogAt(DevelopRemote, DevelopRev, "/w/develop", CatalogContent(
        contributions: @[develop]))], CatalogSelectionPolicy())
    check not composition.refused
    let outcome = lockSelectedRealization(request(
      composition.selectionOf("lockedTarget"), identityOf(develop),
      nixLockIdentity("nixpkgs#hello")), bindingResolver)
    check not outcome.locked
    check outcome.refusals.anyIt(it.startsWith("develop-interface:"))
    # The contribution fingerprint refuses it as well, and the writer names
    # that refusal in its own words rather than relying on the seal's.
    check not outcome.fingerprint.isResolved
    check outcome.refusals.anyIt(
      it.startsWith("contribution-fingerprint-refused:"))
    check outcome.refusals.anyIt(
      it.startsWith("evidence: the contribution fingerprint refused") and
      "developInterface" in it)

  test "an incompatible interface change invalidates the lock on read":
    let identity = identityOf(targetNix())
    let document = documentWith(@[targetRecord()])
    let parsed = parseLockedDependencies(document)
    let oldInterface = canonicalFingerprint("lockedTarget")
    let current = currentHexOf(identity)
    # Control: against the facts it was written from, it is current.
    check parsed.lockedRealizationFor("lockedTarget", Host, Target,
      oldInterface, current).contributor == NixContributor

    # Refresh the package interface: a new public executable.
    let packages = registeredPackages()
    var refreshedTarget = findPackage("lockedTarget")
    refreshedTarget.executables.add(ExecutableDef(
      exportName: "lockedTargetExtra", binaryName: "locked-target-extra"))
    var refreshed: seq[PackageDef] = @[]
    for pkg in packages:
      refreshed.add(if pkg.packageName == "lockedTarget": refreshedTarget
                    else: pkg)
    let newInterface = canonicalPackageInterfaceFingerprint(refreshedTarget,
      refreshed)
    check newInterface != oldInterface

    # The lock is detected as invalid on read, and never handed out --
    # neither with the old contribution fingerprint nor with the one the
    # contribution has once it is re-pinned to the new interface.
    let repinned = currentHexOf(identityOf(lifted("lockedTarget",
      NixContributor, nix = @[nixDef()], packages = refreshed)))
    check repinned != current
    for contribution in [current, repinned]:
      var raised = false
      try:
        discard parsed.lockedRealizationFor("lockedTarget", Host, Target,
          newInterface, contribution)
      except StaleLockedRealizationError as err:
        raised = true
        check err.freshness == lrfInterfaceChanged
        check "incompatible" in err.msg
      check raised

  test "a contribution-only refresh invalidates the realization, not the interface":
    let interfaceBefore = canonicalFingerprint("lockedTarget")
    let document = documentWith(@[targetRecord()])
    let parsed = parseLockedDependencies(document)
    let before = currentHexOf(identityOf(targetNix()))

    # Refresh ONLY the contribution: new realization metadata, and
    # separately a new provider identity.
    let metadataRefresh = currentHexOf(identityOf(targetNix(
      narHash = NarHashB)))
    let providerRefresh = currentHexOf(identityOf(targetNix(),
      provider = ProviderB))
    check canonicalFingerprint("lockedTarget") == interfaceBefore
    check metadataRefresh != before
    check providerRefresh != before
    for moved in [metadataRefresh, providerRefresh]:
      check freshnessOf(parsed.lockedRealizationFor("lockedTarget", Host,
        Target, interfaceBefore, before), interfaceBefore, moved) ==
        lrfContributionChanged
      var raised = false
      try:
        discard parsed.lockedRealizationFor("lockedTarget", Host, Target,
          interfaceBefore, moved)
      except StaleLockedRealizationError as err:
        raised = true
        check err.freshness == lrfContributionChanged
        check "typechecking stays valid" in err.msg
      check raised

    # Re-locking the refreshed contribution changes the record's
    # contribution fingerprint and integrity, and NOT its interface.
    let refreshedComposition = composeCatalogs(@[interfacesCatalog(),
      nixCatalog(narHash = NarHashB), scoopCatalog()], policy(NixContributor))
    let relocked = lockOrFail(request(
      refreshedComposition.selectionOf("lockedTarget"),
      identityOf(targetNix(narHash = NarHashB)),
      nixLockIdentity("nixpkgs#hello", NarHashB)))
    check relocked.interfaceFingerprint == interfaceBefore
    check relocked.contributionFingerprint == metadataRefresh
    check relocked.realizationIntegrity == NarHashB

  test "a curator-policy selection is serialised into the lock":
    # Two eligible contributors: without a policy, composition refuses.
    let ambiguous = composeCatalogs(@[interfacesCatalog(), nixCatalog(),
      scoopCatalog()], CatalogSelectionPolicy())
    check ambiguous.refused
    check ambiguous.diagnostics.anyIt(it.kind == cdAmbiguousContribution)

    # The curator picks Scoop; the lock records that choice.
    let curated = composeCatalogs(@[interfacesCatalog(), nixCatalog(),
      scoopCatalog()], policy(ScoopContributor))
    check curated.selectionOf("lockedTarget").reason == csCuratorPolicy
    let document = documentWith(@[lockOrFail(request(
      curated.selectionOf("lockedTarget"), identityOf(targetScoop()),
      scoopLockIdentity(), host = "amd64-windows", target = "amd64-windows",
      capabilities = @[]))])
    check "selected_by = \"curator-policy\"" in document

    # A locked build needs the lock and the contribution it names -- not
    # the policy, and not a composition of every catalog.
    let parsed = parseLockedDependencies(document)
    let back = parsed.lockedRealizationFor("lockedTarget", "amd64-windows",
      "amd64-windows", canonicalFingerprint("lockedTarget"),
      currentHexOf(identityOf(targetScoop())))
    check back.contributor == ScoopContributor
    check back.catalogRemote == ScoopRemote
    check back.catalogRevision == ScoopRev
    check back.realizationKind == lrkScoop
    check back.realizationLockIdentity == scoopLockIdentity()
    check back.realizationIntegrity == ScoopChecksum
    check back.selectedBy == lsrCuratorPolicy
    # A different curator decision is a different lock.
    check documentWith(@[targetRecord()]) != document

  test "the writer refuses a missing or malformed field rather than truncating":
    let composition = standardComposition()
    let selection = composition.selectionOf("lockedTarget")
    let identity = identityOf(targetNix())
    let lockId = nixLockIdentity("nixpkgs#hello")

    proc refusalsWith(edit: proc (r: var RealizationLockRequest)):
        seq[string] =
      var req = request(selection, identity, lockId)
      edit(req)
      let outcome = lockSelectedRealization(req, bindingResolver)
      check not outcome.locked
      expect LockedRealizationError:
        discard serializeProvisioningRealizations(@[outcome.record])
      outcome.refusals

    # An abbreviated revision composes (M6 does not check its width) but
    # never locks.
    var short = selection
    short.catalogCoordinate.revision = NixRev[0 ..< 12]
    let shortImport = catalogAt(NixRemote, NixRev[0 ..< 12], "/w/nix",
      nixCatalog().content.get)
    check not composeCatalogs(@[interfacesCatalog(), shortImport,
      scoopCatalog()], policy(NixContributor)).refused
    for revision in [NixRev[0 ..< 12], NixRev[0 ..< 39], NixRev & "b",
                     "g" & NixRev[1 .. ^1], "", repeat('a', 63)]:
      let refusals = refusalsWith(proc (r: var RealizationLockRequest) =
        r.selection.catalogCoordinate.revision = revision)
      check refusals.anyIt(it.startsWith("field catalog_revision:"))
    # A 64-hex (SHA-256 object format) revision is full width.
    var sha256Revision = selection
    sha256Revision.catalogCoordinate.revision = repeat('d', 64)
    check lockSelectedRealization(request(sha256Revision, identity, lockId),
      bindingResolver).locked

    check refusalsWith(proc (r: var RealizationLockRequest) =
      r.selection.catalogCoordinate.workspace = " ").anyIt(
        it.startsWith("field catalog_workspace:"))
    check refusalsWith(proc (r: var RealizationLockRequest) =
      r.selection.catalogCoordinate.remote = "").anyIt(
        it.startsWith("field catalog_remote:"))
    check refusalsWith(proc (r: var RealizationLockRequest) =
      r.selection.catalogCoordinate.interfaceArtifact = "abc").anyIt(
        it.startsWith("field catalog_interface_artifact:"))
    for platform in ["", "linux", "amd64-linux-gnu", "AMD64-linux", "-linux"]:
      check refusalsWith(proc (r: var RealizationLockRequest) =
        r.hostPlatform = platform).anyIt(
          it.startsWith("field host_platform:"))
      check refusalsWith(proc (r: var RealizationLockRequest) =
        r.targetPlatform = platform).anyIt(
          it.startsWith("field target_platform:"))
    for capability in ["", "CUDA", "a,b", "-x", "has space"]:
      check refusalsWith(proc (r: var RealizationLockRequest) =
        r.capabilities = @["cuda", capability]).anyIt(
          it.startsWith("field capabilities:"))
    # A realization the contribution does not declare, and one it declares
    # twice.
    check refusalsWith(proc (r: var RealizationLockRequest) =
      r.realizationLockIdentity = "github:NixOS/nixpkgs/other#hello").anyIt(
        it.startsWith("realization-not-declared:"))
    check refusalsWith(proc (r: var RealizationLockRequest) =
      r.realizationLockIdentity = "").anyIt(
        it.startsWith("realization-not-declared:"))
    let twice = lifted("lockedTarget", NixContributor,
      nix = @[nixDef(), nixDef("nixpkgs#hello-alt", lockIdentity = lockId)])
    let twiceComposition = composeCatalogs(@[interfacesCatalog(),
      catalogAt(NixRemote, NixRev, "/w/nix", CatalogContent(
        contributions: @[twice]))], CatalogSelectionPolicy())
    check lockSelectedRealization(request(
      twiceComposition.selectionOf("lockedTarget"), identityOf(twice),
      lockId), bindingResolver).refusals.anyIt(
        it.startsWith("realization-ambiguous:"))
    # A contribution identity the selection did not select.
    check refusalsWith(proc (r: var RealizationLockRequest) =
      r.identity = identityOf(targetScoop())).anyIt(
        it.startsWith("selection-mismatch:"))
    # Weak or truncated integrity evidence.
    for narHash in ["sha1-" & repeat('A', 27) & "=",
                    "sha256-" & repeat('A', 42) & "=",
                    "sha256-" & repeat('A', 43) & "==",
                    "sha256-" & repeat('A', 44),
                    "sha256-" & repeat('A', 42) & "-="]:
      let weak = lifted("lockedTarget", NixContributor,
        nix = @[nixDef(narHash = narHash, lockIdentity = lockId)])
      let weakComposition = composeCatalogs(@[interfacesCatalog(),
        catalogAt(NixRemote, NixRev, "/w/nix", CatalogContent(
          contributions: @[weak]))], CatalogSelectionPolicy())
      check lockSelectedRealization(request(
        weakComposition.selectionOf("lockedTarget"), identityOf(weak),
        lockId), bindingResolver).refusals.anyIt(
          it.startsWith("field realization_integrity:"))
    # A full-width sha512 SRI digest is integrity evidence too.
    let sha512 = "sha512-" & repeat('A', 86) & "=="
    let strong = lifted("lockedTarget", NixContributor,
      nix = @[nixDef(narHash = sha512, lockIdentity = lockId)])
    let strongComposition = composeCatalogs(@[interfacesCatalog(),
      catalogAt(NixRemote, NixRev, "/w/nix", CatalogContent(
        contributions: @[strong]))], CatalogSelectionPolicy())
    let strongOutcome = lockSelectedRealization(request(
      strongComposition.selectionOf("lockedTarget"), identityOf(strong),
      lockId), bindingResolver)
    check strongOutcome.locked
    check strongOutcome.record.realizationIntegrity == sha512
    # Two records for one package and platform pair.
    expect LockedRealizationError:
      discard serializeProvisioningRealizations(
        @[targetRecord(), targetRecord(@[])])

  test "the reader refuses a missing or malformed field rather than truncating":
    let document = documentWith(@[targetRecord(), helperRecord()])
    let line = provisioningLine(document)
    check parseRefusal(document) == ""

    # Every truncation of the record array refuses; none reads as a lock
    # that selected fewer realizations.
    for cut in ProvisioningLockKey.len ..< line.len:
      let refusal = parseRefusal(replaceLine(document, line, line[0 ..< cut]))
      check refusal.len > 0
      if refusal.len == 0:
        checkpoint("accepted a truncation at byte " & $cut)
        break
    # The whole line cut away is a lock without provisioning, which is
    # what every lock written before M7 D2 is.
    check parseLockedDependencies(replaceLine(document, line & "\n", "")).
      provisioningRealizationCount == 0

    template refusedWith(mutated, fragment: string) =
      let refusal = parseRefusal(mutated)
      if fragment notin refusal:
        checkpoint("expected \"" & fragment & "\", got \"" & refusal & "\"")
      check fragment in refusal

    let targetEntry = canonicalRealizationEntry(targetRecord())
    const Fields = ["record", "package", "interface", "contributor",
      "contribution", "catalog_workspace", "catalog_remote",
      "catalog_revision", "catalog_interface_artifact", "realization",
      "realization_lock_identity", "realization_integrity", "host_platform",
      "target_platform", "capabilities", "selected_by"]
    for field in Fields:
      # The field and its value, wherever it sits in the entry.
      let start = targetEntry.find(field & " = \"")
      check start > 0
      let stop = targetEntry.find("\"", start + field.len + 4)
      let pair = targetEntry[start .. stop]
      let withoutField =
        if targetEntry[start - 2 .. start - 1] == ", ":
          targetEntry.replace(", " & pair, "")
        else:
          targetEntry.replace(pair & ", ", "")
      refusedWith(document.replace(targetEntry, withoutField),
        "missing field " & field)
      refusedWith(document.replace(targetEntry,
        targetEntry.replace(pair, pair & ", " & pair)),
        "duplicate field " & field)
    refusedWith(document.replace(targetEntry,
      targetEntry.replace(" }", ", mirror = \"x\" }")), "unknown field mirror")
    refusedWith(document.replace(LockedRealizationRecordV1,
      "reprobuild.locked-provisioning-realization.v2"),
      "unsupported record version")
    refusedWith(document.replace("catalog_revision = \"" & NixRev,
      "catalog_revision = \"" & NixRev[0 ..< 12]), "field catalog_revision:")
    refusedWith(document.replace("realization = \"nix\"",
      "realization = \"docker\""), "field realization:")
    refusedWith(document.replace("selected_by = \"curator-policy\"",
      "selected_by = \"import-order\""), "field selected_by:")
    refusedWith(document.replace("capabilities = \"cuda,x86-64-v3\"",
      "capabilities = \"x86-64-v3,cuda\""), "field capabilities:")
    refusedWith(document.replace("interface = \"" &
      canonicalFingerprint("lockedTarget"), "interface = \"" &
      canonicalFingerprint("lockedTarget").toUpperAscii()),
      "field interface:")
    refusedWith(document.replace("host_platform = \"amd64-linux\"",
      "host_platform = \"C:\\\\amd64\""), "field host_platform:")
    # Every field's validation holds on READ, not only on write.
    let lockedIface = canonicalFingerprint("lockedTarget")
    let lockedContribution = currentHexOf(identityOf(targetNix()))
    let artifact = nixCatalog().coordinate.interfaceArtifact
    for (field, good, bad) in [
        ("package", "lockedTarget", ""),
        ("package", "lockedTarget", " lockedTarget"),
        ("interface", lockedIface, lockedIface[0 ..< 63]),
        ("contributor", NixContributor, "/srv/catalog"),
        ("contribution", lockedContribution, lockedContribution.toUpperAscii()),
        ("catalog_workspace", Workspace, "C:/workspaces/reproos"),
        ("catalog_remote", NixRemote, "../reprobuild-nix-packages"),
        ("catalog_revision", NixRev, NixRev[0 ..< 39]),
        ("catalog_interface_artifact", artifact, artifact & "0"),
        ("realization_lock_identity", nixLockIdentity("nixpkgs#hello"), " "),
        ("realization_integrity", NarHashA, "md5-" & repeat('A', 22) & "=="),
        ("host_platform", Host, "amd64-"),
        ("target_platform", Target, "amd64"),
        ("capabilities", "cuda,x86-64-v3", "cuda,cuda"),
        ("capabilities", "cuda,x86-64-v3", "CUDA,x86-64-v3")]:
      let pair = field & " = \"" & good & "\""
      check pair in targetEntry
      refusedWith(document.replace(targetEntry,
        targetEntry.replace(pair, field & " = \"" & bad & "\"")),
        "field " & field & ":")
    refusedWith(document.replace("host_platform = \"amd64-linux\"",
      "host_platform = \"amd64\\qlinux\""), "unknown escape")
    refusedWith(replaceLine(document, line, line & " x"),
      "unexpected bytes after the array")
    # Syntax errors each name their own cause.
    refusedWith(document.replace("{ record = ", "{ = "), "expected a key")
    refusedWith(document.replace("\", package = \"lockedTarget",
      "\" package = \"lockedTarget"), "expected ',' or '}'")
    refusedWith(document.replace("}, {", "} {"), "expected ',' or ']'")
    # Non-canonical spelling of the same records.
    refusedWith(document.replace("}, {", "},{"), "not the canonical encoding")
    let helperEntry = canonicalRealizationEntry(helperRecord())
    refusedWith(document.replace(helperEntry & ", " & targetEntry,
      targetEntry & ", " & helperEntry), "not the canonical encoding")
    refusedWith(replaceLine(document, line, "provisioning = []"),
      "an empty array is never written")
    # Two records for one key; the key twice; the key without its value.
    refusedWith(document.replace(helperEntry, targetEntry),
      "two provisioning realizations")
    refusedWith(document & line & "\n", "twice")
    refusedWith(replaceLine(document, line, "provisioning"), "truncated")
    refusedWith(replaceLine(document, line, "provisioning ["), "truncated")

  test "every realization family locks with its own integrity evidence":
    # Scoop, with its hex checksum spelled in upper case: a hex digest is
    # case-insensitive, so the record spells it in lower case.
    let upperScoop = lifted("lockedTarget", ScoopContributor,
      scoop = @[ScoopProvisioningDef(bucket: "main", app: "hello",
        version: "2.12.2", manifestChecksum: ScoopChecksum.toUpperAscii(),
        manifestUrl: "https://example.invalid/main/hello.json",
        executablePath: "bin/hello.exe", packageId: "main/hello@2.12.2",
        lockIdentity: scoopLockIdentity())])
    let scoopComposition = composeCatalogs(@[interfacesCatalog(),
      catalogAt(ScoopRemote, ScoopRev, "/w/scoop", CatalogContent(
        contributions: @[upperScoop]))], CatalogSelectionPolicy())
    let scoopRecord = lockOrFail(request(
      scoopComposition.selectionOf("lockedTarget"), identityOf(upperScoop),
      scoopLockIdentity()))
    check scoopRecord.realizationKind == lrkScoop
    check scoopRecord.realizationIntegrity == ScoopChecksum

    # A tarball.
    const TarSha = "1111111111111111111111111111111111111111111111111111111111111111"
    const TarLock = "sha256:" & TarSha
    let tarball = lifted("lockedTarget", NixContributor,
      tarball = @[TarballProvisioningDef(
        url: "https://example.invalid/hello-2.12.2.tar.gz", sha256: TarSha,
        archiveType: "tar.gz", executablePath: "bin/hello",
        stripComponents: 1, lockIdentity: TarLock)])
    let tarComposition = composeCatalogs(@[interfacesCatalog(),
      catalogAt(NixRemote, NixRev, "/w/tar", CatalogContent(
        contributions: @[tarball]))], CatalogSelectionPolicy())
    let tarRecord = lockOrFail(request(
      tarComposition.selectionOf("lockedTarget"), identityOf(tarball),
      TarLock))
    check tarRecord.realizationKind == lrkTarball
    check tarRecord.realizationIntegrity == TarSha

    # From source, with the recipe digest of a REAL recipe tree.
    let root = createTempDir("repro-m7d2-recipe", "")
    defer: removeDir(root)
    createDir(root / "internal")
    writeFile(root / "repro.nim", "import ./internal/recipe\nconst entry* = payload\n")
    writeFile(root / "internal" / "recipe.nim", "const payload* = \"v1\"\n")
    let closure = solvedSourceClosure(root, @[], @[root])
    check closure.missing.len == 0
    let sourceLock = "source:lockedTarget@" & closure.digestHex
    var fromSource = identityOf(targetNix())
    fromSource.fromSourceProvisioning = @[FromSourceRealization(
      packageName: "lockedTarget", contributor: NixContributor,
      recipePath: "recipes/locked-target",
      recipeDigest: closure.digestHex.toUpperAscii(),
      lockIdentity: sourceLock)]
    let sourceRecord = lockOrFail(request(
      standardComposition().selectionOf("lockedTarget"), fromSource,
      sourceLock))
    check sourceRecord.realizationKind == lrkFromSource
    check sourceRecord.realizationIntegrity == closure.digestHex.toLowerAscii()

    # One package locked for two platform pairs: the reader hands back the
    # one asked for.
    let windowsRecord = lockOrFail(request(
      standardComposition().selectionOf("lockedTarget"),
      identityOf(targetNix()), nixLockIdentity("nixpkgs#hello"),
      host = "amd64-windows", target = "arm64-windows", capabilities = @[]))
    # Same target as the base record, different host; and same host,
    # different target: each is its own key.
    let crossRecord = lockOrFail(request(
      standardComposition().selectionOf("lockedTarget"),
      identityOf(targetNix()), nixLockIdentity("nixpkgs#hello"),
      host = "arm64-macosx", target = Target, capabilities = @["metal"]))
    let armRecord = lockOrFail(request(
      standardComposition().selectionOf("lockedTarget"),
      identityOf(targetNix()), nixLockIdentity("nixpkgs#hello"),
      host = Host, target = "arm64-linux", capabilities = @["neon"]))
    let parsed = parseLockedDependencies(documentWith(@[targetRecord(),
      windowsRecord, crossRecord, armRecord]))
    check parsed.provisioningRealizationCount == 4
    let current = currentHexOf(identityOf(targetNix()))
    let interfaceFp = canonicalFingerprint("lockedTarget")
    check parsed.lockedRealizationFor("lockedTarget", "amd64-windows",
      "arm64-windows", interfaceFp, current).capabilities.len == 0
    check parsed.lockedRealizationFor("lockedTarget", Host, Target,
      interfaceFp, current).capabilities == @["cuda", "x86-64-v3"]
    check parsed.lockedRealizationFor("lockedTarget", "arm64-macosx", Target,
      interfaceFp, current).capabilities == @["metal"]
    check parsed.lockedRealizationFor("lockedTarget", Host, "arm64-linux",
      interfaceFp, current).capabilities == @["neon"]
    check parsed.refusesAsAbsent("lockedTarget", "amd64-windows", Target,
      interfaceFp, current)

  test "a value that needs escaping round-trips":
    const Odd = "github:NixOS/nixpkgs/rev#\"quoted\"\tname\r\nline"
    let odd = lifted("lockedTarget", NixContributor,
      nix = @[nixDef(lockIdentity = Odd)])
    let composition = composeCatalogs(@[interfacesCatalog(),
      catalogAt(NixRemote, NixRev, "/w/nix", CatalogContent(
        contributions: @[odd]))], CatalogSelectionPolicy())
    let record = lockOrFail(request(composition.selectionOf("lockedTarget"),
      identityOf(odd), Odd))
    let document = documentWith(@[record])
    check "\\\"quoted\\\"\\tname\\r\\nline" in provisioningLine(document)
    let parsed = parseLockedDependencies(document)
    check serializeLockedDependencies(parsed) == document
    check parsed.lockedRealizationFor("lockedTarget", Host, Target,
      canonicalFingerprint("lockedTarget"), currentHexOf(identityOf(odd))).
      realizationLockIdentity == Odd

    # A cut inside a value, and a cut just after an escape's backslash, are
    # each reported as what they are.
    let line = provisioningLine(document)
    let inValue = line.find("quoted")
    check parseRefusal(document.replace(line, line[0 .. inValue])).contains(
      "truncated inside a quoted value")
    let atEscape = line.find("\\t")
    check parseRefusal(document.replace(line, line[0 .. atEscape])).contains(
      "truncated inside an escape")

    # A quote in a package name round-trips through the escaping like any
    # other value. A backslash is refused in EVERY field -- the package name
    # included -- so the writer's backslash escape is pinned on the encoder
    # directly, and the reader's on a document that spells one.
    var draft = record
    draft.packageName = "odd\"package\"name"
    let sealed = sealLockedRealization(draft, ContributionEvidence(
      fingerprintHex: record.contributionFingerprint))
    let oddDocument = documentWith(@[sealed])
    check "odd\\\"package\\\"name" in provisioningLine(oddDocument)
    check serializeLockedDependencies(parseLockedDependencies(oddDocument)) ==
      oddDocument
    var slashed = record
    slashed.packageName = "odd\\package"
    check "package = \"odd\\\\package\"" in canonicalRealizationEntry(slashed)
    expect LockedRealizationError:
      discard sealLockedRealization(slashed, ContributionEvidence(
        fingerprintHex: record.contributionFingerprint))
    check "field package: contains a backslash" in parseRefusal(
      document.replace("package = \"lockedTarget\"",
        "package = \"odd\\\\package\""))

  test "a lock without provisioning records reads and writes as before":
    # The codec change is additive: a document carrying no record is
    # byte-identical through a round trip and has no provisioning line.
    let document = serializeLockedDependencies(baseLock())
    check ProvisioningLockKey notin document
    check document == serializeLockedDependencies(
      parseLockedDependencies(document))
    check parseLockedDependencies(document).provisioningRealizationCount == 0
    check documentWith(@[]) == document
    check parseLockedDependencies(document).refusesAsAbsent("lockedTarget",
      Host, Target, canonicalFingerprint("lockedTarget"),
      currentHexOf(identityOf(targetNix())))

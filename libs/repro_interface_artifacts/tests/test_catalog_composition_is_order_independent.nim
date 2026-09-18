## M6 deliverables 1, 3 and (part of) 4 — federated catalog discovery and
## composition.
##
## Acceptance test named by ``ReproOS-Campaign-Completion.milestones.org``
## § M6 Verification:
##
##   "Permuting catalog import order produces byte-identical solver input,
##    lock, and selected graph."
##
## The normative design is
## ``reprobuild-specs/Provisioning-Contributions.md`` § Interface Artifacts,
## § Resolution, § Locks And Snapshots and § Repository Composition. The
## sentence this whole file exists to pin is in § Resolution:
##
##   Import order is never a selection rule. If more than one eligible
##   contribution remains and no lock or policy selects one, resolution
##   fails with an ambiguity diagnostic listing contributor ids and source
##   locations.
##
## ## Mocks
##
## NONE, per the workspace policy in ``AGENTS.md``. Every fixture is real:
##
##   * the two target packages and the catalog project are declared through
##     the real ``package`` / ``uses`` DSL at module scope, and every
##     canonical interface fingerprint under test is computed by the
##     production ``canonicalPackageInterfaceFingerprint``;
##   * every contribution record is lifted through the production
##     ``toProjectInterface`` projection — the same path the interface
##     artifact codec carries — so the records composed here are the records
##     a real imported catalog would carry, readable without running any
##     provider;
##   * the catalog interface-artifact identity is computed by
##     ``catalogArtifactIdentity`` over the production
##     ``interfaceFingerprint`` of a real lifted artifact, not over a
##     hand-written hex string;
##   * the two "different on-disk locations" are two different ``discoveredAt``
##     strings on the same coordinate, which is exactly the difference the
##     composition is required to ignore.
##
## The one record built by hand rather than lifted is the STALE contribution
## in "an incompatible interface fingerprint refuses": it is a real lifted
## record whose ``targetInterfaceFingerprint`` is then rewritten to a
## different 64-hex value, because the production projection refuses to
## create such a record at all. That is the state a catalog pinned to a
## superseded interface revision is in on disk, and composition is the layer
## that has to notice.
##
## ## What this file does NOT prove
##
##   * It does not prove anything about a LOCK. The milestone's sentence says
##     "solver input, lock, and selected graph"; the lock RECORD is M7
##     deliverable 2 and does not exist yet, so only the solver input and the
##     selected graph are asserted byte-identical here. Nothing in this file
##     may be read as evidence about lock serialisation, lock refresh or
##     lock-pinned selection.
##   * It does not prove M6 deliverable 5 (a hermetic multi-repository fixture
##     over published commits) or
##     ``e2e_federated_catalog_discovery_from_published_repositories``. Every
##     catalog here is an in-process value; no repository is cloned, fetched
##     or checked out, and the ``revision`` component of a coordinate is
##     asserted only to be an IDENTITY INPUT, never to correspond to a commit
##     that exists.
##   * The ``CatalogSelectionPolicy`` exercised here is a curator policy — an
##     explicit, in-memory selection input. It is NOT a lock and must not be
##     mistaken for one: it is not serialised, not committed, and carries no
##     contribution fingerprint, revision or platform.
##   * Byte-identity is asserted over ``resolverInput`` and ``selectedGraph``,
##     which bind the catalog coordinates, the canonical interfaces and the
##     contribution RECORD digests. They do not bind provider identity or a
##     contribution's dependency closure; that is
##     ``contribution_fingerprint`` (M7 deliverable 1), and composition
##     deliberately does not call it — a contribution's provider identity is
##     not readable from an interface artifact, and M6 deliverable 2 forbids
##     executing provider code to obtain one.
##   * Order-independence is asserted over the permutations of THREE imported
##     catalogs and over the permutations of the contributions and canonical
##     interfaces declared inside them. It is evidence about the
##     canonicalisation, not a proof over arbitrary catalog sets.

import std/[algorithm, options, sequtils, strutils, unittest]

import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_project_dsl

package federatedTarget:
  executable federatedTarget:
    name "federated-target"
    cli:
      subcmd "run":
        flag verbose, bool

package federatedHelper:
  executable federatedHelper:
    name "federated-helper"
    cli:
      subcmd "help":
        flag quiet, bool

package federatedCatalog:
  defaultToolProvisioning "nix"
  uses:
    "federatedTarget"

const
  NixContributor = "github:metacraft-labs/reprobuild-nix-packages"
  ScoopContributor = "github:metacraft-labs/reprobuild-scoop-packages"
  PackagesRemote = "github:metacraft-labs/reprobuild-packages"
  NixRemote = "github:metacraft-labs/reprobuild-nix-packages"
  ScoopRemote = "github:metacraft-labs/reprobuild-scoop-packages"
  Workspace = "github:metacraft-labs/reproos"
  PackagesRev = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
  NixRev = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
  ScoopRev = "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3"
  OtherRev = "d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4"
  NixpkgsRev = "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"
  NarHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

proc canonicalFingerprint(name: string): string =
  canonicalPackageInterfaceFingerprint(findPackage(name), registeredPackages())

proc nixDef(selector = "nixpkgs#hello"): NixPackageProvisioningDef =
  NixPackageProvisioningDef(
    selector: selector,
    executablePath: "bin/hello",
    nixpkgsRef: "github:NixOS/nixpkgs",
    nixpkgsRev: NixpkgsRev,
    nixpkgsNarHash: NarHash,
    packageId: "hello@2.12.2")

proc scoopDef(app = "hello"): ScoopProvisioningDef =
  ScoopProvisioningDef(
    bucket: "main",
    app: app,
    version: "2.12.2",
    manifestChecksum: repeat('c', 64),
    manifestUrl: "https://example.invalid/main/hello.json",
    executablePath: "bin/hello.exe")

proc lifted(targetPackage, contributor: string;
            nix: seq[NixPackageProvisioningDef] = @[];
            scoop: seq[ScoopProvisioningDef] = @[];
            line = 1): InterfaceProvisioningContribution =
  ## Lift a contribution through the PRODUCTION projection, so the record
  ## composed below is the record an imported interface artifact carries.
  let def = ProvisioningContributionDef(
    targetPackage: targetPackage,
    targetInterfaceFingerprint: canonicalFingerprint(targetPackage),
    contributor: contributor,
    nixProvisioning: nix,
    scoopProvisioning: scoop,
    sourceFile: "catalog/" & targetPackage & ".nim",
    sourceLine: line)
  let catalog = toProjectInterface(findPackage("federatedCatalog"),
    registeredPackages(), @[def])
  catalog.provisioningContributions[0]

proc interfacesCatalogContent(): CatalogContent =
  CatalogContent(
    canonicalInterfaces: @[
      catalogInterface("federatedTarget", canonicalFingerprint(
        "federatedTarget")),
      catalogInterface("federatedHelper", canonicalFingerprint(
        "federatedHelper"))],
    contributions: @[])

proc nixCatalogContent(): CatalogContent =
  CatalogContent(
    canonicalInterfaces: @[],
    contributions: @[
      lifted("federatedTarget", NixContributor, nix = @[nixDef()], line = 11),
      lifted("federatedHelper", NixContributor,
        nix = @[nixDef("nixpkgs#helper")], line = 22)])

proc scoopCatalogContent(): CatalogContent =
  CatalogContent(
    canonicalInterfaces: @[],
    contributions: @[
      lifted("federatedTarget", ScoopContributor, scoop = @[scoopDef()],
        line = 33)])

proc artifactIdentityOf(content: CatalogContent): string =
  ## A real interface-artifact identity: the digest of the production codec's
  ## bytes for an artifact carrying exactly this catalog's contributions.
  var pi = toProjectInterface(findPackage("federatedCatalog"),
    registeredPackages(), @[])
  pi.provisioningContributions = content.contributions
  catalogArtifactIdentity(@[artifactFor(pi)])

proc catalogAt(remote, revision, discoveredAt: string;
               content: CatalogContent): CatalogImport =
  CatalogImport(
    coordinate: CatalogCoordinate(
      workspace: Workspace,
      remote: remote,
      revision: revision,
      interfaceArtifact: artifactIdentityOf(content)),
    discoveredAt: discoveredAt,
    content: some(content))

proc interfacesCatalog(discoveredAt = "/w/reprobuild-packages"): CatalogImport =
  catalogAt(PackagesRemote, PackagesRev, discoveredAt,
    interfacesCatalogContent())

proc nixCatalog(discoveredAt = "/w/reprobuild-nix-packages"): CatalogImport =
  catalogAt(NixRemote, NixRev, discoveredAt, nixCatalogContent())

proc scoopCatalog(
    discoveredAt = "/w/reprobuild-scoop-packages"): CatalogImport =
  catalogAt(ScoopRemote, ScoopRev, discoveredAt, scoopCatalogContent())

proc nixPolicy(): CatalogSelectionPolicy =
  CatalogSelectionPolicy(selections: @[
    CatalogSelectionRule(targetPackage: "federatedTarget",
      contributor: NixContributor)])

proc permutationsOf(count: int): seq[seq[int]] =
  var order = toSeq(0 ..< count)
  result = @[order]
  while order.nextPermutation():
    result.add(order)

proc reorder[T](values: seq[T]; order: seq[int]): seq[T] =
  for index in order:
    result.add(values[index])

proc messagesOfKind(composition: CatalogComposition;
                    kind: CatalogDiagnosticKind): seq[string] =
  for diagnostic in composition.diagnostics:
    if diagnostic.kind == kind:
      result.add(diagnostic.message)

suite "catalog composition is order independent":

  test "permuting catalog import order composes byte-identically":
    let imports = @[interfacesCatalog(), nixCatalog(), scoopCatalog()]
    let orders = permutationsOf(imports.len)
    check orders.len == 6
    let reference = composeCatalogs(imports, nixPolicy())
    check reference.diagnostics.len == 0
    check reference.resolverInputDigest.len == 64
    check reference.selectedGraphDigest.len == 64
    check reference.selections.len == 2
    for order in orders:
      let permuted = composeCatalogs(reorder(imports, order), nixPolicy())
      check permuted.resolverInput == reference.resolverInput
      check permuted.resolverInputDigest == reference.resolverInputDigest
      check permuted.selectedGraph == reference.selectedGraph
      check permuted.selectedGraphDigest == reference.selectedGraphDigest

  test "permuting contributions inside a catalog composes byte-identically":
    let reference = composeCatalogs(
      @[interfacesCatalog(), nixCatalog(), scoopCatalog()], nixPolicy())
    check reference.diagnostics.len == 0
    for contributionOrder in permutationsOf(2):
      for interfaceOrder in permutationsOf(2):
        var interfaces = interfacesCatalog()
        var content = interfacesCatalogContent()
        content.canonicalInterfaces =
          reorder(content.canonicalInterfaces, interfaceOrder)
        interfaces.content = some(content)
        var nix = nixCatalog()
        var nixContent = nixCatalogContent()
        nixContent.contributions =
          reorder(nixContent.contributions, contributionOrder)
        nix.content = some(nixContent)
        let permuted = composeCatalogs(
          @[interfaces, nix, scoopCatalog()], nixPolicy())
        check permuted.diagnostics.len == 0
        check permuted.resolverInput == reference.resolverInput
        check permuted.selectedGraph == reference.selectedGraph

  test "a catalog is bound by its coordinate, not by its on-disk location":
    let here = composeCatalogs(@[
      interfacesCatalog("/checkout-a/reprobuild-packages"),
      nixCatalog("/checkout-a/reprobuild-nix-packages"),
      scoopCatalog("/checkout-a/reprobuild-scoop-packages")], nixPolicy())
    let there = composeCatalogs(@[
      interfacesCatalog("D:/elsewhere/vendor/packages-mirror"),
      nixCatalog("D:/elsewhere/vendor/nix-mirror"),
      scoopCatalog("D:/elsewhere/vendor/scoop-mirror")], nixPolicy())
    check here.diagnostics.len == 0
    check there.diagnostics.len == 0
    check there.resolverInput == here.resolverInput
    check there.resolverInputDigest == here.resolverInputDigest
    check there.selectedGraph == here.selectedGraph
    check not here.resolverInput.contains("checkout-a")
    check not there.resolverInput.contains("elsewhere")

  test "an incomplete catalog coordinate refuses":
    var ambient = nixCatalog()
    ambient.coordinate.revision = ""
    let composition = composeCatalogs(
      @[interfacesCatalog(), ambient, scoopCatalog()], nixPolicy())
    check composition.refused
    check composition.resolverInput.len == 0
    check composition.resolverInputDigest.len == 0
    let messages = messagesOfKind(composition, cdIncompleteCoordinate)
    check messages.len == 1
    check messages[0].contains("revision")
    check messages[0].contains(NixRemote)

  test "two eligible contributions with no policy fail closed":
    let imports = @[interfacesCatalog(), nixCatalog(), scoopCatalog()]
    let composition = composeCatalogs(imports, CatalogSelectionPolicy())
    check composition.refused
    check composition.resolverInput.len == 0
    check composition.selectedGraph.len == 0
    check composition.selections.len == 0
    let messages = messagesOfKind(composition, cdAmbiguousContribution)
    check messages.len == 1
    let message = messages[0]
    check message.contains(NixContributor)
    check message.contains(ScoopContributor)
    check message.contains("catalog/federatedTarget.nim:11")
    check message.contains("catalog/federatedTarget.nim:33")
    check message.contains(NixRev)
    check message.contains(ScoopRev)
    for order in permutationsOf(imports.len):
      let permuted = composeCatalogs(
        reorder(imports, order), CatalogSelectionPolicy())
      check messagesOfKind(permuted, cdAmbiguousContribution) == messages

  test "a curator policy selects, and a different policy selects differently":
    let imports = @[interfacesCatalog(), nixCatalog(), scoopCatalog()]
    let chooseNix = composeCatalogs(imports, nixPolicy())
    let chooseScoop = composeCatalogs(imports, CatalogSelectionPolicy(
      selections: @[CatalogSelectionRule(targetPackage: "federatedTarget",
        contributor: ScoopContributor)]))
    check chooseNix.diagnostics.len == 0
    check chooseScoop.diagnostics.len == 0
    check chooseScoop.selectedGraph != chooseNix.selectedGraph
    check chooseNix.selectedGraph.contains(NixContributor)
    check chooseScoop.selectedGraph.contains(ScoopContributor)
    check chooseNix.resolverInput == chooseScoop.resolverInput
    let helperReasons = chooseNix.selections.filterIt(
      it.targetPackage == "federatedHelper").mapIt(it.reason)
    check helperReasons == @[csUniqueEligible]
    let targetReasons = chooseNix.selections.filterIt(
      it.targetPackage == "federatedTarget").mapIt(it.reason)
    check targetReasons == @[csCuratorPolicy]

  test "a missing catalog refuses with its own diagnostic":
    var absent = scoopCatalog("/checkout-a/reprobuild-scoop-packages")
    absent.content = none(CatalogContent)
    let composition = composeCatalogs(
      @[interfacesCatalog(), nixCatalog(), absent], nixPolicy())
    check composition.refused
    check composition.resolverInputDigest.len == 0
    let messages = messagesOfKind(composition, cdMissingCatalog)
    check messages.len == 1
    check messages[0].contains(ScoopRemote)
    check messages[0].contains(ScoopRev)
    check messages[0].contains("/checkout-a/reprobuild-scoop-packages")

  test "a duplicate canonical interface refuses with its own diagnostic":
    var rival = scoopCatalog()
    var content = scoopCatalogContent()
    content.canonicalInterfaces = @[
      catalogInterface("federatedTarget",
        canonicalFingerprint("federatedTarget"))]
    rival.content = some(content)
    rival.coordinate.interfaceArtifact = artifactIdentityOf(content)
    let composition = composeCatalogs(
      @[interfacesCatalog(), nixCatalog(), rival], nixPolicy())
    check composition.refused
    check composition.resolverInputDigest.len == 0
    let messages = messagesOfKind(composition, cdDuplicateCanonicalInterface)
    check messages.len == 1
    check messages[0].contains("federatedTarget")
    check messages[0].contains(PackagesRemote)
    check messages[0].contains(ScoopRemote)

  test "an incompatible interface fingerprint refuses with its own diagnostic":
    var stale = nixCatalog()
    var content = nixCatalogContent()
    content.contributions[0].targetInterfaceFingerprint = repeat('e', 64)
    stale.content = some(content)
    stale.coordinate.interfaceArtifact = artifactIdentityOf(content)
    let composition = composeCatalogs(
      @[interfacesCatalog(), stale, scoopCatalog()], nixPolicy())
    check composition.refused
    check composition.resolverInputDigest.len == 0
    let messages = messagesOfKind(composition, cdIncompatibleFingerprint)
    check messages.len == 1
    check messages[0].contains(NixContributor)
    check messages[0].contains("federatedTarget")
    check messages[0].contains(repeat('e', 64))
    check messages[0].contains(canonicalFingerprint("federatedTarget"))

  test "a contribution with no imported canonical interface refuses":
    var orphan = nixCatalog()
    var content = nixCatalogContent()
    content.contributions[0].targetPackage = "federatedAbsent"
    orphan.content = some(content)
    orphan.coordinate.interfaceArtifact = artifactIdentityOf(content)
    let composition = composeCatalogs(
      @[interfacesCatalog(), orphan, scoopCatalog()], nixPolicy())
    check composition.refused
    let messages = messagesOfKind(composition, cdUnknownTargetInterface)
    check messages.len == 1
    check messages[0].contains("federatedAbsent")
    check messages[0].contains(NixContributor)

  test "one coordinate serving two different contents refuses":
    var forged = scoopCatalog("D:/mirror/scoop")
    var content = scoopCatalogContent()
    content.contributions[0].scoopProvisioning[0].app = "hello-forged"
    forged.content = some(content)
    let composition = composeCatalogs(@[
      interfacesCatalog(), nixCatalog(),
      scoopCatalog("/checkout-a/scoop"), forged], nixPolicy())
    check composition.refused
    check composition.resolverInputDigest.len == 0
    let messages = messagesOfKind(composition, cdCatalogIdentityConflict)
    check messages.len == 1
    check messages[0].contains(ScoopRemote)
    check messages[0].contains(ScoopRev)
    check messages[0].contains("/checkout-a/scoop")
    check messages[0].contains("D:/mirror/scoop")

  test "composition is stable under catalog revision identity":
    ## The moved catalog is the NIX one, which the policy selects: the same
    ## content republished at a second declared revision must therefore be
    ## distinguishable in the resolver input AND in the selected graph, and
    ## must NOT be distinguishable from itself at the same revision.
    let atNixRev = composeCatalogs(
      @[interfacesCatalog(), nixCatalog(), scoopCatalog()], nixPolicy())
    let alsoAtNixRev = composeCatalogs(
      @[scoopCatalog(), interfacesCatalog(), nixCatalog()], nixPolicy())
    var moved = nixCatalog()
    moved.coordinate.revision = OtherRev
    let atOtherRev = composeCatalogs(
      @[interfacesCatalog(), moved, scoopCatalog()], nixPolicy())
    check atNixRev.diagnostics.len == 0
    check atOtherRev.diagnostics.len == 0
    check alsoAtNixRev.resolverInputDigest == atNixRev.resolverInputDigest
    check alsoAtNixRev.selectedGraph == atNixRev.selectedGraph
    check atOtherRev.resolverInputDigest != atNixRev.resolverInputDigest
    check atOtherRev.resolverInput.contains(OtherRev)
    check not atOtherRev.resolverInput.contains(NixRev)
    check atOtherRev.selectedGraph != atNixRev.selectedGraph
    check atOtherRev.selectedGraphDigest != atNixRev.selectedGraphDigest

  test "the interface-artifact identity survives a move but not an edit":
    ## The load-bearing half of the cross-host claim, and the one that was
    ## measured wrong first: an identity digested over the ENCODED artifact
    ## bytes carries every declaration's absolute ``SourceLocation``, so the
    ## same catalog extracted on two hosts produced two coordinates. The
    ## identity must move with the catalog's published realization metadata
    ## and stay put when only a source location moves.
    var here = toProjectInterface(findPackage("federatedCatalog"),
      registeredPackages(), @[])
    here.provisioningContributions = nixCatalogContent().contributions
    var moved = here
    for contribution in moved.provisioningContributions.mitems:
      contribution.location = SourceLocation(
        file: "D:/elsewhere/vendor/nix-mirror/catalog.nim", line: 4096)
      for realization in contribution.nixProvisioning.mitems:
        realization.location = SourceLocation(
          file: "D:/elsewhere/vendor/nix-mirror/catalog.nim", line: 4097)
    var edited = here
    edited.provisioningContributions[0].nixProvisioning[0].selector =
      "nixpkgs#hello-unfree"

    check catalogArtifactIdentity(@[artifactFor(moved)]).len == 64
    check catalogArtifactIdentity(@[artifactFor(moved)]) ==
      catalogArtifactIdentity(@[artifactFor(here)])
    check catalogArtifactIdentity(@[artifactFor(edited)]) !=
      catalogArtifactIdentity(@[artifactFor(here)])
    check catalogArtifactIdentity(
      @[artifactFor(here), artifactFor(edited)]) ==
      catalogArtifactIdentity(@[artifactFor(edited), artifactFor(here)])

  test "the composed document carries no host-specific bytes":
    ## The support for the cross-host claim: a composed document that
    ## contains no CR, no backslash, no byte outside printable ASCII and
    ## no absolute path cannot differ between a Windows and a Linux host
    ## for any reason this module controls.
    let composition = composeCatalogs(
      @[interfacesCatalog("M:/w/packages"), nixCatalog("M:/w/nix"),
        scoopCatalog("M:/w/scoop")], nixPolicy())
    check composition.diagnostics.len == 0
    for document in [composition.resolverInput, composition.selectedGraph]:
      check document.len > 0
      check document.endsWith("\n")
      check not document.contains('\r')
      check not document.contains('\\')
      check not document.contains("M:/w/")
      for ch in document:
        # LF terminates a record, TAB separates its fields, and every other
        # byte must be printable ASCII.
        check ord(ch) in {0x09, 0x0a} or (ord(ch) >= 0x20 and ord(ch) < 0x7f)

  test "a contribution's source location is outside the digested surface":
    ## ``catalogArtifactIdentity`` is not the only digest a ``SourceLocation``
    ## could reach, and pinning only that one leaves the cross-host bug a
    ## second way back in. Every contribution is reduced to
    ## ``interfaceContributionRecordDigest``, and THAT value is emitted into
    ## both composed documents — so folding ``location`` into it reproduces
    ## the original failure exactly: one catalog declared at a Windows
    ## absolute path and at a POSIX one composes to two different digests.
    ## Measured: that mutation leaves every other case in this file AND all
    ## 26 cases of ``test_contribution_fingerprint_invalidation_boundaries``
    ## green, so this case is the only thing standing in front of it.
    proc declaredAt(discoveredAt, file: string; line: int): CatalogImport =
      result = nixCatalog(discoveredAt)
      var content = nixCatalogContent()
      for contribution in content.contributions.mitems:
        contribution.location = SourceLocation(file: file, line: line)
        for realization in contribution.nixProvisioning.mitems:
          realization.location = SourceLocation(file: file, line: line + 1)
      result.content = some(content)
    let reference = composeCatalogs(
      @[interfacesCatalog(), nixCatalog(), scoopCatalog()], nixPolicy())
    let onWindows = composeCatalogs(@[
      interfacesCatalog("C:/checkout/reprobuild-packages"),
      declaredAt("C:/checkout/reprobuild-nix-packages",
        "C:\\checkout\\reprobuild-nix-packages\\catalog.nim", 991),
      scoopCatalog("C:/checkout/reprobuild-scoop-packages")], nixPolicy())
    let onLinux = composeCatalogs(@[
      interfacesCatalog("/home/u/ws/reprobuild-packages"),
      declaredAt("/home/u/ws/reprobuild-nix-packages",
        "/home/u/ws/reprobuild-nix-packages/catalog.nim", 3),
      scoopCatalog("/home/u/ws/reprobuild-scoop-packages")], nixPolicy())
    check onWindows.diagnostics.len == 0
    check onLinux.diagnostics.len == 0
    check onWindows.resolverInput == onLinux.resolverInput
    check onWindows.selectedGraph == onLinux.selectedGraph
    check onWindows.resolverInputDigest == reference.resolverInputDigest
    check onWindows.selectedGraphDigest == reference.selectedGraphDigest

  test "each of the coordinate's four components is separately required":
    ## "an incomplete catalog coordinate refuses" drops only the REVISION, so
    ## on its own it pins one of the four guards and leaves the other three
    ## deletable by a refactor with a green suite. Measured: removing the
    ## workspace, remote or interface-artifact check individually reddens
    ## nothing else in this file.
    for (component, gap) in [("workspace", "workspace is empty"),
                             ("remote", "remote is empty"),
                             ("revision", "revision is empty"),
                             ("interfaceArtifact",
                              "interface-artifact identity is empty")]:
      var ambient = nixCatalog()
      case component
      of "workspace": ambient.coordinate.workspace = ""
      of "remote": ambient.coordinate.remote = ""
      of "revision": ambient.coordinate.revision = ""
      else: ambient.coordinate.interfaceArtifact = ""
      let composition = composeCatalogs(
        @[interfacesCatalog(), ambient, scoopCatalog()], nixPolicy())
      check composition.refused
      check composition.resolverInput.len == 0
      check composition.resolverInputDigest.len == 0
      check composition.selections.len == 0
      let messages = messagesOfKind(composition, cdIncompleteCoordinate)
      check messages.len == 1
      check messages[0].contains(gap)
    ## A hex string of the wrong width is not a coordinate either: an
    ## identity that is merely hex-SHAPED must not pass for one.
    var truncated = nixCatalog()
    truncated.coordinate.interfaceArtifact = repeat('a', 63)
    let composition = composeCatalogs(
      @[interfacesCatalog(), truncated, scoopCatalog()], nixPolicy())
    check composition.refused
    let messages = messagesOfKind(composition, cdIncompleteCoordinate)
    check messages.len == 1
    check messages[0].contains("not a 64-hex digest")

  test "a refusal with several causes reports them in one stable order":
    ## "two eligible contributions with no policy fail closed" permutes ONE
    ## diagnostic of ONE kind, and a single-element list compares equal
    ## whether or not anything sorts it. Two causes raised in different
    ## phases, from imports at different positions, are what pins the
    ## diagnostic ORDER itself — measured: dropping the diagnostic sort
    ## reddens nothing else in this file.
    var ambient = nixCatalog()
    ambient.coordinate.revision = ""
    var absent = scoopCatalog()
    absent.content = none(CatalogContent)
    let imports = @[interfacesCatalog(), ambient, absent]
    let reference = composeCatalogs(imports, nixPolicy())
    check reference.refused
    check reference.resolverInput.len == 0
    check reference.diagnostics.len == 3
    for order in permutationsOf(imports.len):
      let permuted = composeCatalogs(reorder(imports, order), nixPolicy())
      check permuted.diagnostics == reference.diagnostics
      check permuted.diagnosticReport == reference.diagnosticReport

  test "two mirrors of one catalog may order contributions freely":
    ## "one coordinate serving two different contents refuses" makes the two
    ## imports differ in a FIELD, which they do sorted or unsorted — so on its
    ## own it does not pin the content canonicalisation. Two mirrors of one
    ## catalog that publish the same SET in a different declaration order are
    ## the same catalog, and calling that a conflict would refuse a correct
    ## workspace. Measured: dropping the content sort reddens nothing else.
    var mirror = nixCatalog("D:/mirror/nix")
    var content = nixCatalogContent()
    content.contributions = reorder(content.contributions, @[1, 0])
    mirror.content = some(content)
    let composition = composeCatalogs(@[interfacesCatalog(),
      nixCatalog("/checkout-a/nix"), mirror, scoopCatalog()], nixPolicy())
    let reference = composeCatalogs(
      @[interfacesCatalog(), nixCatalog(), scoopCatalog()], nixPolicy())
    check composition.diagnostics.len == 0
    check composition.resolverInput == reference.resolverInput
    check composition.selectedGraph == reference.selectedGraph

  test "the declaring workspace is part of the catalog's identity":
    ## Two workspaces may pin the same remote at the same revision and mean
    ## two different statements; the coordinate says so only if ``workspace``
    ## is actually an input to its digest. Measured: dropping it from the
    ## coordinate payload reddens nothing else — the revision half is pinned
    ## by "composition is stable under catalog revision identity", this half
    ## was not pinned at all.
    var elsewhere = nixCatalog()
    elsewhere.coordinate.workspace = "github:metacraft-labs/other-workspace"
    let here = composeCatalogs(
      @[interfacesCatalog(), nixCatalog(), scoopCatalog()], nixPolicy())
    let there = composeCatalogs(
      @[interfacesCatalog(), elsewhere, scoopCatalog()], nixPolicy())
    check here.diagnostics.len == 0
    check there.diagnostics.len == 0
    check there.resolverInputDigest != here.resolverInputDigest
    check there.selectedGraphDigest != here.selectedGraphDigest
    check there.resolverInput.contains("other-workspace")

  test "a field cannot break out of its record":
    ## Every emitted field is escaped before it is framed. Without that, a
    ## contributor id carrying a TAB or an LF would forge extra fields or an
    ## extra record inside a document a digest is then taken over — a catalog
    ## could therefore claim a record it does not own. Measured: removing the
    ## escaping reddens nothing else in this file.
    var forging = scoopCatalog()
    var content = scoopCatalogContent()
    content.contributions[0].contributor =
      "evil\tfederatedHelper\tsmuggled\ncontribution\tfederatedHelper"
    forging.content = some(content)
    forging.coordinate.interfaceArtifact = artifactIdentityOf(content)
    let composition = composeCatalogs(@[interfacesCatalog(), nixCatalog(),
      forging], CatalogSelectionPolicy(selections: @[
        CatalogSelectionRule(targetPackage: "federatedTarget",
          contributor: NixContributor)]))
    check composition.diagnostics.len == 0
    check composition.resolverInput.contains("\\t")
    check composition.resolverInput.contains("\\n")
    check not composition.resolverInput.contains("\tsmuggled\t")
    ## The document still has exactly one record per line and one more line
    ## than it has records-worth of framing: the forged LF did not add one.
    let reference = composeCatalogs(
      @[interfacesCatalog(), nixCatalog(), scoopCatalog()], nixPolicy())
    check composition.resolverInput.count('\n') ==
      reference.resolverInput.count('\n')

  test "a contradictory curator policy refuses instead of taking the last":
    ## The position of an entry in the POLICY list is no more a selection
    ## rule than the position of an import, and the spec's rule is about the
    ## class, not about one list: if more than one eligible contribution
    ## remains and nothing decides between them, resolution fails closed.
    ##
    ## Measured on the working tree BEFORE this was fixed: the rules were
    ## folded into a map last-wins, so the two policies below -- the same two
    ## entries in opposite order -- selected different contributors, with no
    ## diagnostic and a fully populated ``selectedGraph``. Nothing in the
    ## suite noticed, because no case had ever given one package two rules.
    let imports = @[interfacesCatalog(), nixCatalog(), scoopCatalog()]
    let nixThenScoop = CatalogSelectionPolicy(selections: @[
      CatalogSelectionRule(targetPackage: "federatedTarget",
        contributor: NixContributor),
      CatalogSelectionRule(targetPackage: "federatedTarget",
        contributor: ScoopContributor)])
    let scoopThenNix = CatalogSelectionPolicy(selections: @[
      CatalogSelectionRule(targetPackage: "federatedTarget",
        contributor: ScoopContributor),
      CatalogSelectionRule(targetPackage: "federatedTarget",
        contributor: NixContributor)])
    for policy in [nixThenScoop, scoopThenNix]:
      let composition = composeCatalogs(imports, policy)
      check composition.refused
      check composition.resolverInput.len == 0
      check composition.resolverInputDigest.len == 0
      check composition.selectedGraph.len == 0
      check composition.selectedGraphDigest.len == 0
      check composition.selections.len == 0
      let messages = messagesOfKind(composition, cdContradictoryPolicy)
      check messages.len == 1
      check messages[0].contains("federatedTarget")
      check messages[0].contains(NixContributor)
      check messages[0].contains(ScoopContributor)
    ## The refusal names the same two candidates in the same order either
    ## way, so the REFUSAL is byte-identical under policy permutation too.
    check composeCatalogs(imports, scoopThenNix).diagnosticReport ==
      composeCatalogs(imports, nixThenScoop).diagnosticReport
    ## A policy that merely REPEATS one entry says one thing twice and is
    ## not contradictory: refusing it would be a false refusal.
    let repeated = CatalogSelectionPolicy(selections: @[
      CatalogSelectionRule(targetPackage: "federatedTarget",
        contributor: NixContributor),
      CatalogSelectionRule(targetPackage: "federatedTarget",
        contributor: NixContributor)])
    let once = composeCatalogs(imports, nixPolicy())
    let twice = composeCatalogs(imports, repeated)
    check twice.diagnostics.len == 0
    check twice.resolverInput == once.resolverInput
    check twice.selectedGraph == once.selectedGraph

  test "the same catalog imported twice is one catalog":
    let once = composeCatalogs(
      @[interfacesCatalog(), nixCatalog(), scoopCatalog()], nixPolicy())
    let twice = composeCatalogs(@[
      interfacesCatalog(), nixCatalog(),
      scoopCatalog("/checkout-a/scoop"),
      scoopCatalog("D:/mirror/scoop")], nixPolicy())
    check once.diagnostics.len == 0
    check twice.diagnostics.len == 0
    check twice.resolverInput == once.resolverInput
    check twice.selectedGraph == once.selectedGraph

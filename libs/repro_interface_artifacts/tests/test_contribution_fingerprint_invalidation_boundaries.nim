## M7 deliverable 1 — the provisioning contribution fingerprint.
##
## Acceptance test named by ``ReproOS-Campaign-Completion.milestones.org``
## § M7 Verification:
##
##   "Metadata changes invalidate realization edges while interface changes
##    invalidate incompatible contribution locks and consumers."
##
## The normative design is
## ``reprobuild-specs/Provisioning-Contributions.md`` § Identities,
## § Interface Artifacts and § Locks And Snapshots. Its central invariant,
## which this file exists to pin:
##
##   Provisioning metadata is realization policy, not package API.
##   Changing a Nix attribute, Scoop manifest, archive URL, source recipe
##   or default provisioning mode MUST NOT change the canonical package
##   interface fingerprint. It MUST change the contribution fingerprint
##   and any lock selecting that contribution.
##
## ## Mocks
##
## NONE, per the workspace policy in ``AGENTS.md``. Every fixture is real:
##
##   * the target package and the catalog project are declared through the
##     real ``package`` / ``uses`` DSL at module scope and lifted through
##     the real ``toProjectInterface`` / ``interfaceFingerprint`` path, so
##     both fingerprints under test are the production ones;
##   * the from-source realization's ``recipeDigest`` is computed by the
##     real ``solvedSourceClosure`` over a REAL temp recipe tree written to
##     the filesystem, so "changing a source recipe input" is an actual
##     file mutation, not a hand-edited hex string;
##   * the only callback in the file is ``ContributionResolver``, which is
##     a production parameter of the composer (the federation resolver
##     supplies it), not a stand-in for one — the same shape
##     ``ForeignDepResolver`` has in ``foreign_common.nim``. The closures
##     here return real ``ContributionIdentity`` values built by the same
##     helpers as the rest of the file.
##
## ## What this file does NOT prove
##
##   * It does not prove anything about lock SERIALIZATION (M7 deliverable
##     2) or about resolver selection from a committed lock (deliverable
##     3). "Lock invalidation" is asserted here as the existing
##     ``toProjectInterface`` refusal of a contribution pinned to a
##     fingerprint the active interface no longer has.
##   * It does not pin the invariant for an IN-PACKAGE realization
##     reached through a ``uses:`` entry. The invariant DOES hold there —
##     ``writeToolUse`` computes ``omitRealizations = forFingerprint and
##     version >= 13`` and ``interfaceFingerprint`` always serialises at
##     ``EnvelopeVersion = 17``, so every tool-use realization is omitted
##     from the fingerprinted payload — but no case in this file, and no
##     case anywhere in the suite, measures it. The invariant is pinned
##     here only for the federated (external-catalog) form, which is the
##     form the spec's Repository Composition section describes.
##   * The dependency leaf identity binds the declared COORDINATE
##     (package, contributor, target interface fingerprint), not the
##     dependency's realized output. Two catalogs that differ only in an
##     unresolved dependency's realization metadata therefore land on the
##     same leaf. Supplying a resolver binds the difference; the
##     "resolver binds more than the leaf" case pins that. Two things
##     this file does NOT establish about that fallback: it is the
##     DEFAULT (``noContributionResolver``), and the returned
##     ``ContributionFingerprint`` carries no marker of it — ``isResolved``
##     is true and ``refusals`` empty whether every dependency was bound
##     or every one folded in as a coordinate-only leaf. The
##     ``leafDepIdentityHex`` precedent in ``foreign_common.nim`` binds
##     MORE than this leaf does: its coordinate includes ``snapshot``,
##     which pins the upstream index revision, whereas a contributor id
##     names a repository and not a revision of it.

import std/[algorithm, options, os, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_interface_artifacts/contribution_fingerprint
import repro_project_dsl
import repro_project_dsl/source_cache_identity

package contributionTarget:
  executable contributionTarget:
    name "contribution-target"
    cli:
      subcmd "run":
        flag verbose, bool

package contributionCatalog:
  defaultToolProvisioning "nix"
  uses:
    "contributionTarget"

const
  Contributor = "github:metacraft-labs/reprobuild-nix-packages"
  OtherContributor = "github:example/other-catalog"
  ProviderA = repeat('a', 64)
  ProviderB = repeat('b', 64)
  NixRev = "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"
  NarHashA = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  NarHashB = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
  TarSha = repeat('1', 64)
  TarShaB = repeat('2', 64)

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

proc targetFingerprint(): string =
  let packages = registeredPackages()
  canonicalPackageInterfaceFingerprint(findPackage("contributionTarget"),
    packages)

proc nixDef(selector = "nixpkgs#hello"; exePath = "bin/hello";
            rev = NixRev; narHash = NarHashA):
    NixPackageProvisioningDef =
  NixPackageProvisioningDef(
    selector: selector,
    executablePath: exePath,
    nixpkgsRef: "github:NixOS/nixpkgs",
    nixpkgsRev: rev,
    nixpkgsNarHash: narHash,
    packageId: "hello@2.12.2")

proc tarballDef(url = "https://example.invalid/hello-2.12.2.tar.gz";
                sha = TarSha; mirrors: seq[string] = @[]):
    TarballProvisioningDef =
  TarballProvisioningDef(
    url: url,
    mirrors: mirrors,
    sha256: sha,
    archiveType: "tar.gz",
    executablePath: "bin/hello",
    stripComponents: 1)

proc scoopDef(bucket = "main"; app = "hello";
              checksum = repeat('c', 64)): ScoopProvisioningDef =
  ScoopProvisioningDef(
    bucket: bucket,
    app: app,
    version: "2.12.2",
    manifestChecksum: checksum,
    manifestUrl: "https://example.invalid/main/hello.json",
    executablePath: "bin/hello.exe")

proc contributionDef(fingerprint: string;
                     contributor = Contributor;
                     nix: seq[NixPackageProvisioningDef] = @[];
                     tarball: seq[TarballProvisioningDef] = @[];
                     scoop: seq[ScoopProvisioningDef] = @[]):
    ProvisioningContributionDef =
  ProvisioningContributionDef(
    targetPackage: "contributionTarget",
    targetInterfaceFingerprint: fingerprint,
    contributor: contributor,
    nixProvisioning: nix,
    tarballProvisioning: tarball,
    scoopProvisioning: scoop,
    sourceFile: "catalog.nim",
    sourceLine: 1)

proc projectContribution(def: ProvisioningContributionDef;
                         packages: seq[PackageDef] = @[]):
    InterfaceProvisioningContribution =
  ## Lift a contribution through the REAL projection path, so the record
  ## under test is the one the interface artifact carries.
  let candidates = if packages.len > 0: packages else: registeredPackages()
  let catalog = toProjectInterface(findPackage("contributionCatalog"),
    candidates, @[def])
  catalog.provisioningContributions[0]

proc identityOf(def: ProvisioningContributionDef;
                providerIdentity = ProviderA;
                fromSource: seq[FromSourceRealization] = @[];
                dependencies: seq[ContributionDependencyRef] = @[];
                packages: seq[PackageDef] = @[]): ContributionIdentity =
  ContributionIdentity(
    contribution: projectContribution(def, packages),
    providerIdentity: providerIdentity,
    fromSourceProvisioning: fromSource,
    dependencies: dependencies)

proc hexOf(identity: ContributionIdentity;
           resolver: ContributionResolver = noContributionResolver): string =
  let fp = contributionFingerprint(identity, resolver)
  if not fp.isResolved:
    raise newException(ValueError, "refused: " & fp.refusalReason)
  fp.hex

proc writeRecipeTree(root, implementation: string) =
  createDir(root / "internal")
  writeFile(root / "repro.nim",
    "import ./internal/recipe\n" &
    "const entry* = payload\n")
  writeFile(root / "internal" / "recipe.nim",
    "const payload* = \"" & implementation & "\"\n")

proc recipeDigest(root: string): string =
  let closure = solvedSourceClosure(root, @[], @[root])
  if closure.missing.len > 0:
    raise newException(ValueError,
      "recipe closure incomplete: " & closure.missing.join("; "))
  closure.digestHex

suite "contribution fingerprint invalidation boundaries":

  test "a nix attribute moves the contribution fingerprint, not the interface":
    let fp = targetFingerprint()
    let before = hexOf(identityOf(contributionDef(fp, nix = @[nixDef()])))
    let interfaceBefore = targetFingerprint()

    let after = hexOf(identityOf(contributionDef(fp,
      nix = @[nixDef(selector = "nixpkgs#hello-unfree")])))
    let interfaceAfter = targetFingerprint()

    check before.len == 64
    check after != before
    check interfaceAfter == interfaceBefore
    check interfaceAfter == fp

  test "an archive URL moves the contribution fingerprint, not the interface":
    let fp = targetFingerprint()
    let before = hexOf(identityOf(contributionDef(fp,
      tarball = @[tarballDef()])))
    let after = hexOf(identityOf(contributionDef(fp,
      tarball = @[tarballDef(url = "https://mirror.invalid/hello.tar.gz")])))
    check after != before
    check targetFingerprint() == fp

  test "a scoop manifest field moves the contribution fingerprint only":
    let fp = targetFingerprint()
    let before = hexOf(identityOf(contributionDef(fp,
      scoop = @[scoopDef()])))
    let after = hexOf(identityOf(contributionDef(fp,
      scoop = @[scoopDef(bucket = "extras")])))
    check after != before
    check targetFingerprint() == fp

  test "a source recipe input moves the contribution fingerprint only":
    let fp = targetFingerprint()
    let root = createTempDir("repro-m7-recipe", "")
    defer: removeDir(root)
    writeRecipeTree(root, "implementation-1")
    let digestOne = recipeDigest(root)
    let one = hexOf(identityOf(contributionDef(fp, nix = @[nixDef()]),
      fromSource = @[FromSourceRealization(
        packageName: "contributionTarget",
        contributor: Contributor,
        recipePath: "recipes/contribution-target",
        recipeDigest: digestOne,
        recipeInputs: @[("cc", "gcc"), ("optimize", "speed")])]))

    writeRecipeTree(root, "implementation-2")
    let digestTwo = recipeDigest(root)
    check digestTwo != digestOne
    let two = hexOf(identityOf(contributionDef(fp, nix = @[nixDef()]),
      fromSource = @[FromSourceRealization(
        packageName: "contributionTarget",
        contributor: Contributor,
        recipePath: "recipes/contribution-target",
        recipeDigest: digestTwo,
        recipeInputs: @[("cc", "gcc"), ("optimize", "speed")])]))
    check two != one

    # A declared recipe INPUT is realization policy too.
    let three = hexOf(identityOf(contributionDef(fp, nix = @[nixDef()]),
      fromSource = @[FromSourceRealization(
        packageName: "contributionTarget",
        contributor: Contributor,
        recipePath: "recipes/contribution-target",
        recipeDigest: digestTwo,
        recipeInputs: @[("cc", "clang"), ("optimize", "speed")])]))
    check three != two
    check targetFingerprint() == fp

  test "an interface change moves the InterfaceFingerprint and invalidates locks":
    let packages = registeredPackages()
    let target = findPackage("contributionTarget")
    let oldFingerprint = canonicalPackageInterfaceFingerprint(target, packages)

    var alternative = target
    alternative.executables.add(ExecutableDef(
      exportName: "contributionTargetExtra",
      binaryName: "contribution-target-extra"))
    var refreshed: seq[PackageDef] = @[]
    for pkg in packages:
      if pkg.packageName == "contributionTarget": refreshed.add(alternative)
      else: refreshed.add(pkg)
    let newFingerprint = canonicalPackageInterfaceFingerprint(alternative,
      refreshed)

    # Half 1: the package interface moved.
    check newFingerprint != oldFingerprint

    # Half 2: a contribution lock pinned to the OLD interface identity no
    # longer selects — the projection refuses it outright.
    expect ValueError:
      discard toProjectInterface(findPackage("contributionCatalog"),
        refreshed, @[contributionDef(oldFingerprint, nix = @[nixDef()])])

    # Half 3: the target interface fingerprint is an INPUT of the
    # contribution fingerprint, so a contribution that re-pins to the new
    # interface is a different contribution identity.
    let pinnedOld = hexOf(identityOf(contributionDef(oldFingerprint,
      nix = @[nixDef()])))
    let pinnedNew = hexOf(identityOf(contributionDef(newFingerprint,
      nix = @[nixDef()]), packages = refreshed))
    check pinnedNew != pinnedOld

  test "contributor id, provider identity and integrity fields each move it":
    let fp = targetFingerprint()
    let base = hexOf(identityOf(contributionDef(fp, nix = @[nixDef()],
      tarball = @[tarballDef()], scoop = @[scoopDef()])))

    let otherContributor = hexOf(identityOf(contributionDef(fp,
      contributor = OtherContributor, nix = @[nixDef()],
      tarball = @[tarballDef()], scoop = @[scoopDef()])))
    check otherContributor != base

    let otherProvider = hexOf(identityOf(contributionDef(fp,
      nix = @[nixDef()], tarball = @[tarballDef()], scoop = @[scoopDef()]),
      providerIdentity = ProviderB))
    check otherProvider != base

    let otherNarHash = hexOf(identityOf(contributionDef(fp,
      nix = @[nixDef(narHash = NarHashB)], tarball = @[tarballDef()],
      scoop = @[scoopDef()])))
    check otherNarHash != base

    let otherRev = hexOf(identityOf(contributionDef(fp,
      nix = @[nixDef(rev = repeat('d', 40))], tarball = @[tarballDef()],
      scoop = @[scoopDef()])))
    check otherRev != base

    let otherSha = hexOf(identityOf(contributionDef(fp, nix = @[nixDef()],
      tarball = @[tarballDef(sha = TarShaB)], scoop = @[scoopDef()])))
    check otherSha != base

    let otherChecksum = hexOf(identityOf(contributionDef(fp,
      nix = @[nixDef()], tarball = @[tarballDef()],
      scoop = @[scoopDef(checksum = repeat('e', 64))])))
    check otherChecksum != base

    # The projection copies the contributor onto every realization, so the
    # checks above would still pass if the composer read ONLY the
    # per-realization copy — measured: dropping the top-level contributor
    # from the payload left them green. A record reaching the composer
    # from a decoder or a hand-built catalog need not agree with its own
    # realizations, so the contribution-level fields are pinned on their
    # own here. Same for the target package name.
    var renamedContributor = identityOf(contributionDef(fp,
      nix = @[nixDef()], tarball = @[tarballDef()], scoop = @[scoopDef()]))
    renamedContributor.contribution.contributor = OtherContributor
    check hexOf(renamedContributor) != base

    var renamedTarget = identityOf(contributionDef(fp, nix = @[nixDef()],
      tarball = @[tarballDef()], scoop = @[scoopDef()]))
    renamedTarget.contribution.targetPackage = "someOtherPackage"
    check hexOf(renamedTarget) != base

    # Every mutation above must also be distinct from EVERY other one:
    # a fingerprint that collapsed two different axes onto one value
    # would pass the pairwise checks above and still be wrong.
    var all = @[base, otherContributor, otherProvider, otherNarHash,
                otherRev, otherSha, otherChecksum,
                hexOf(renamedContributor), hexOf(renamedTarget)]
    all.sort(cmp)
    check all.deduplicate.len == all.len

  test "canonical: permuting emission order is byte-identical":
    let fp = targetFingerprint()
    let deps = @[
      ContributionDependencyRef(targetPackage: "libz",
        contributor: Contributor, targetInterfaceFingerprint: repeat('1', 64)),
      ContributionDependencyRef(targetPackage: "libssl",
        contributor: OtherContributor,
        targetInterfaceFingerprint: repeat('2', 64))]
    let fromSource = @[FromSourceRealization(
      packageName: "contributionTarget",
      contributor: Contributor,
      recipePath: "recipes/contribution-target",
      recipeDigest: repeat('3', 64),
      recipeInputs: @[("cc", "gcc"), ("optimize", "speed"), ("lto", "on")])]

    let straight = hexOf(identityOf(contributionDef(fp,
      nix = @[nixDef(), nixDef(selector = "nixpkgs#hello-static",
        exePath = "bin/hello-static")],
      tarball = @[tarballDef(mirrors = @["https://a.invalid/h.tgz",
        "https://b.invalid/h.tgz"])]),
      fromSource = fromSource, dependencies = deps))

    # Same contribution, every list emitted in the opposite order and the
    # recipe-input map in a different insertion order.
    let permutedFromSource = @[FromSourceRealization(
      packageName: "contributionTarget",
      contributor: Contributor,
      recipePath: "recipes/contribution-target",
      recipeDigest: repeat('3', 64),
      recipeInputs: @[("lto", "on"), ("cc", "gcc"), ("optimize", "speed")])]
    let permuted = hexOf(identityOf(contributionDef(fp,
      nix = @[nixDef(selector = "nixpkgs#hello-static",
        exePath = "bin/hello-static"), nixDef()],
      tarball = @[tarballDef(mirrors = @["https://b.invalid/h.tgz",
        "https://a.invalid/h.tgz"])]),
      fromSource = permutedFromSource,
      dependencies = @[deps[1], deps[0]]))

    check permuted == straight

    # Non-vacuity control for this case: a permutation is not the only
    # thing that leaves a fingerprint alone, so prove the same shape DOES
    # move when the CONTENT changes rather than its order.
    let contentChanged = hexOf(identityOf(contributionDef(fp,
      nix = @[nixDef(), nixDef(selector = "nixpkgs#hello-static",
        exePath = "bin/hello-static")],
      tarball = @[tarballDef(mirrors = @["https://a.invalid/h.tgz",
        "https://c.invalid/h.tgz"])]),
      fromSource = fromSource, dependencies = deps))
    check contentChanged != straight

  test "base case: dependencies compose without building them":
    let fp = targetFingerprint()
    let deps = @[
      ContributionDependencyRef(targetPackage: "libz",
        contributor: Contributor, targetInterfaceFingerprint: repeat('1', 64)),
      ContributionDependencyRef(targetPackage: "libssl",
        contributor: Contributor, targetInterfaceFingerprint: repeat('2', 64))]

    # No resolver, no build, no realization hash: the declared coordinate
    # IS a complete identity in declaration space.
    let leafOnly = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]), dependencies = deps))
    check leafOnly.isResolved
    check leafOnly.hex.len == 64

    let noDeps = hexOf(identityOf(contributionDef(fp, nix = @[nixDef()])))
    check leafOnly.hex != noDeps

    # A dependency's declared coordinate is load-bearing.
    var otherDeps = deps
    otherDeps[0].targetInterfaceFingerprint = repeat('9', 64)
    let movedLeaf = hexOf(identityOf(contributionDef(fp, nix = @[nixDef()]),
      dependencies = otherDeps))
    check movedLeaf != leafOnly.hex

  test "recursion: a resolver binds more than the leaf coordinate":
    let fp = targetFingerprint()
    let dep = ContributionDependencyRef(targetPackage: "libz",
      contributor: Contributor, targetInterfaceFingerprint: repeat('1', 64))
    let root = identityOf(contributionDef(fp, nix = @[nixDef()]),
      dependencies = @[dep])

    proc depIdentity(selector: string): ContributionIdentity =
      ContributionIdentity(
        contribution: InterfaceProvisioningContribution(
          targetPackage: "libz",
          targetInterfaceFingerprint: repeat('1', 64),
          contributor: Contributor,
          nixProvisioning: @[InterfaceNixProvisioning(
            packageName: "libz", contributor: Contributor,
            selector: selector, executablePath: "lib/libz.so",
            nixpkgsRev: NixRev, nixpkgsNarHash: NarHashA)]),
        providerIdentity: ProviderB)

    var resolvedSelector = "nixpkgs#zlib"
    proc resolver(d: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        if d.targetPackage == "libz": some(depIdentity(resolvedSelector))
        else: none(ContributionIdentity)

    let leafOnly = hexOf(root)
    let resolvedOne = hexOf(root, resolver)
    check resolvedOne != leafOnly

    resolvedSelector = "nixpkgs#zlib-static"
    let resolvedTwo = hexOf(root, resolver)
    check resolvedTwo != resolvedOne

  test "recursion: a dependency cycle terminates at the leaf":
    let fp = targetFingerprint()
    let depB = ContributionDependencyRef(targetPackage: "bee",
      contributor: Contributor, targetInterfaceFingerprint: repeat('1', 64))
    let depA = ContributionDependencyRef(targetPackage: "contributionTarget",
      contributor: Contributor, targetInterfaceFingerprint: fp)

    # A -> B -> A, with BOTH sides resolvable. Resolving only one of them
    # would make this case pass whether or not the ``visited`` guard
    # exists, because the unresolved side folds in as its leaf anyway —
    # measured: with only "bee" resolvable, deleting the guard left the
    # case green. The cycle has to actually close for the guard to be the
    # thing that terminates it.
    let rootIdentity = identityOf(contributionDef(fp, nix = @[nixDef()]),
      dependencies = @[depB])
    let beeIdentity = ContributionIdentity(
      contribution: InterfaceProvisioningContribution(
        targetPackage: "bee",
        targetInterfaceFingerprint: repeat('1', 64),
        contributor: Contributor,
        nixProvisioning: @[InterfaceNixProvisioning(
          packageName: "bee", contributor: Contributor,
          selector: "nixpkgs#bee", executablePath: "bin/bee",
          nixpkgsRev: NixRev, nixpkgsNarHash: NarHashA)]),
      providerIdentity: ProviderA,
      dependencies: @[depA])

    proc cyclicResolver(d: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        if d.targetPackage == "bee": some(beeIdentity)
        elif d.targetPackage == "contributionTarget": some(rootIdentity)
        else: none(ContributionIdentity)

    let cyclic = contributionFingerprint(rootIdentity, cyclicResolver)
    check cyclic.isResolved
    check cyclic.hex.len == 64

    # Terminating is not enough on its own: prove the cycle-broken value
    # is still a function of the cycle's content.
    let acyclic = hexOf(identityOf(contributionDef(fp, nix = @[nixDef()]),
      dependencies = @[depB]))
    check cyclic.hex != acyclic

  test "fail closed: a missing identity input refuses instead of fingerprinting":
    let fp = targetFingerprint()

    proc refusalFor(identity: ContributionIdentity;
                    resolver: ContributionResolver = noContributionResolver):
        ContributionFingerprint =
      let got = contributionFingerprint(identity, resolver)
      check not got.isResolved
      check got.hex.len == 0
      check got.refusals.len > 0
      got

    # No target interface fingerprint.
    var noFingerprint = identityOf(contributionDef(fp, nix = @[nixDef()]))
    noFingerprint.contribution.targetInterfaceFingerprint = ""
    check refusalFor(noFingerprint).refusalReason.contains(
      "target interface fingerprint")

    # A target interface fingerprint that is not a digest at all.
    var badFingerprint = identityOf(contributionDef(fp, nix = @[nixDef()]))
    badFingerprint.contribution.targetInterfaceFingerprint = "not-a-digest"
    discard refusalFor(badFingerprint)

    # A develop-bound contribution has no published interface identity.
    var develop = identityOf(contributionDef(fp, nix = @[nixDef()]))
    develop.contribution.developInterface = true
    check refusalFor(develop).refusalReason.contains("developInterface")

    # No contributor id.
    var noContributor = identityOf(contributionDef(fp, nix = @[nixDef()]))
    noContributor.contribution.contributor = ""
    check refusalFor(noContributor).refusalReason.contains("contributor id")

    # No provider identity.
    check refusalFor(identityOf(contributionDef(fp, nix = @[nixDef()]),
      providerIdentity = "")).refusalReason.contains("provider identity")

    # No realization at all.
    check refusalFor(identityOf(contributionDef(fp))).refusalReason.contains(
      "realization metadata")

    # An unresolvable integrity field: a nix realization with no NAR hash.
    var noNarHash = identityOf(contributionDef(fp, nix = @[nixDef()]))
    noNarHash.contribution.nixProvisioning[0].nixpkgsNarHash = ""
    check refusalFor(noNarHash).refusalReason.contains("nixpkgsNarHash")

    # A malformed integrity field: a tarball sha256 that is not a digest.
    var badSha = identityOf(contributionDef(fp, tarball = @[tarballDef()]))
    badSha.contribution.tarballProvisioning[0].sha256 = "deadbeef"
    check refusalFor(badSha).refusalReason.contains("sha256")

    # A from-source realization whose recipe digest was never resolved.
    check refusalFor(identityOf(contributionDef(fp, nix = @[nixDef()]),
      fromSource = @[FromSourceRealization(
        packageName: "contributionTarget",
        contributor: Contributor,
        recipePath: "recipes/contribution-target",
        recipeDigest: "")])).refusalReason.contains("recipeDigest")

    # A dependency reference missing its contributor.
    check refusalFor(identityOf(contributionDef(fp, nix = @[nixDef()]),
      dependencies = @[ContributionDependencyRef(
        targetPackage: "libz", contributor: "",
        targetInterfaceFingerprint: repeat('1', 64))])).refusalReason.contains(
      "dependency")

    # A resolver that produces an UNFINGERPRINTABLE dependency must not be
    # silently downgraded to the leaf: the refusal propagates.
    proc brokenResolver(d: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        some(ContributionIdentity(
          contribution: InterfaceProvisioningContribution(
            targetPackage: d.targetPackage,
            targetInterfaceFingerprint: d.targetInterfaceFingerprint,
            contributor: d.contributor),
          providerIdentity: ProviderA))
    let propagated = refusalFor(identityOf(contributionDef(fp,
      nix = @[nixDef()]),
      dependencies = @[ContributionDependencyRef(targetPackage: "libz",
        contributor: Contributor,
        targetInterfaceFingerprint: repeat('1', 64))]), brokenResolver)
    check propagated.refusalReason.contains("libz")

    # The positive control for this whole case: the same fixture WITH every
    # required input present does resolve, so the refusals above are not a
    # composer that refuses everything.
    check contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]))).isResolved

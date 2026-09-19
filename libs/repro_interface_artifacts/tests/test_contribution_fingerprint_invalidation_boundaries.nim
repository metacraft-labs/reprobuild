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
##     same leaf, and this file does not claim otherwise -- "the
##     unresolved-dependency alias is flagged rather than silent" asserts
##     the collision itself. What the hardening changed is that the alias
##     is no longer reachable by accident and no longer silent:
##     ``noContributionResolver`` is not a default argument any more (the
##     one-argument call is a compile error, verified out of tree), and
##     the result carries ``unresolvedDependencies`` /
##     ``dependenciesFullyResolved``. Supplying a resolver still binds
##     the difference; the "resolver binds more than the leaf" case pins
##     that.
##
##     The residual that remains: a flagged fingerprint is still a
##     fingerprint, so M7 deliverable 2 must refuse to serialise one into
##     a lock rather than assume ``isResolved`` is enough. And the
##     ``leafDepIdentityHex`` precedent in ``foreign_common.nim`` binds
##     MORE than this leaf does: its coordinate includes ``snapshot``,
##     which pins the upstream index revision, whereas a contributor id
##     names a repository and not a revision of it.

import std/[algorithm, monotimes, options, os, sequtils, strutils, tempfiles,
            times, unittest]

import repro_binary_cache_client/cache_key
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

  # Canonical-encoding pins — see "the canonical encoding is pinned by
  # value, not only by relation". These are the bytes of ONE fully
  # specified contribution under the v1 magics; a deliberate re-key bumps
  # the magic and updates these in the same commit.
  PinnedContributionHex =
    "3434d65d1d3d08938ff87ec1a5c309d101f9e4d09f3cbef24e38e6cdf876e389"
  PinnedLeafHex =
    "f1def744605ba3160e89988e0c798572face12dbaf3d1d48980760e760afda2c"
  PinnedRecordDigestHex =
    "e5156f93892102d964fb2c9babb6ed15689ae4ddb371ccac9f3388aa7d1d06e9"

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
      identityOf(contributionDef(fp, nix = @[nixDef()]), dependencies = deps),
      noContributionResolver)
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
      identityOf(contributionDef(fp, nix = @[nixDef()])),
      noContributionResolver).isResolved

  test "provider identity must be a well-formed content identity":
    ## M7 hardening, defect 4. ``providerIdentity`` was required-non-empty
    ## and shape-UNCHECKED, alone among this module's required inputs: a
    ## placeholder string, or a value stamped with the codebase's
    ## "identity not computed yet" marker, still produced a 64-hex
    ## fingerprint. It is a CONTENT identity of the provider
    ## implementation — the same class of value as
    ## ``targetInterfaceFingerprint``, which this module has always
    ## shape-checked — so it is now held to the same 64-hex contract.
    let fp = targetFingerprint()

    # Positive control first: the real content identity still resolves, so
    # the refusals below are not a composer that refuses everything.
    check contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()])),
      noContributionResolver).isResolved

    proc providerRefusal(provider: string): ContributionFingerprint =
      {.cast(gcsafe).}:
        contributionFingerprint(identityOf(contributionDef(fp,
          nix = @[nixDef()]), providerIdentity = provider),
          noContributionResolver)

    # A placeholder, a truncated digest, an over-long one and a non-hex
    # string of the right WIDTH are each not a content identity.
    for placeholder in ["provider", "TODO", "unknown", "deadbeef",
                        repeat('a', 63), repeat('a', 65), repeat('z', 64)]:
      let got = providerRefusal(placeholder)
      check not got.isResolved
      check got.hex.len == 0
      check got.refusalReason.contains("provider identity")

    # A value STAMPED as not-yet-computed is refused by name rather than
    # merely as a malformed digest: "pending" is a different diagnosis
    # from "malformed", and a lock writer needs to be able to tell them
    # apart. ``repro.identity.pending`` is the marker
    # ``cache_key.PendingCacheIdentityOptionKey`` already uses for exactly
    # this state.
    for pending in ["repro.identity.pending",
                    "repro.identity.pending:source closure",
                    "REPRO.IDENTITY.PENDING"]:
      let got = providerRefusal(pending)
      check not got.isResolved
      check got.refusalReason.contains("repro.identity.pending")

    # An empty provider identity keeps refusing, and keeps saying so in
    # the words the existing fail-closed case pins.
    check providerRefusal("").refusalReason.contains("provider identity")

    # Two spellings of the SAME content identity are the same
    # contribution: the value is normalised into the payload exactly as
    # the target interface fingerprint is, so an algorithm-prefixed
    # provider identity does not re-key every contribution.
    let bare = hexOf(identityOf(contributionDef(fp, nix = @[nixDef()]),
      providerIdentity = ProviderA), noContributionResolver)
    let prefixed = hexOf(identityOf(contributionDef(fp, nix = @[nixDef()]),
      providerIdentity = "blake3-256:" & ProviderA.toUpperAscii()),
      noContributionResolver)
    check prefixed == bare

    # Non-vacuity control for that last pair: normalisation must not have
    # flattened the field into a constant.
    check hexOf(identityOf(contributionDef(fp, nix = @[nixDef()]),
      providerIdentity = ProviderB), noContributionResolver) != bare

  test "the source location is diagnostic, not a fingerprint input":
    ## M7 hardening, defect 3a. The module docstring states that
    ## ``SourceLocation`` is deliberately NOT an input — the spec calls
    ## the contribution's source location a diagnostic, and folding it in
    ## would make moving a declaration down a file a realization change.
    ## The behaviour held and nothing pinned it.
    let fp = targetFingerprint()
    let base = identityOf(contributionDef(fp, nix = @[nixDef()],
      tarball = @[tarballDef()]))
    let baseHex = hexOf(base, noContributionResolver)

    # Same contribution, declared in a different file at a different line.
    var moved = base
    moved.contribution.location = SourceLocation(
      file: "catalogs/other-catalog.nim", line: 4211)
    check moved.contribution.location != base.contribution.location
    check hexOf(moved, noContributionResolver) == baseHex

    # Only the line number moved: the narrower half of the same claim,
    # and the one an edit above the declaration actually produces.
    var shifted = base
    shifted.contribution.location = SourceLocation(
      file: base.contribution.location.file,
      line: base.contribution.location.line + 17)
    check hexOf(shifted, noContributionResolver) == baseHex

    # Non-vacuity control: the same mutate-the-record shape DOES move the
    # fingerprint for a field that IS an input, so the two equalities
    # above are a statement about the location and not about the helper.
    var renamed = base
    renamed.contribution.targetPackage = "someOtherPackage"
    check hexOf(renamed, noContributionResolver) != baseHex

  test "MaxContributionDepth refuses rather than truncating":
    ## M7 hardening, defect 3b. ``MaxContributionDepth`` is documented to
    ## REFUSE rather than truncate, which is the whole difference between
    ## a bounded identity and one computed over a silently-cut graph.
    ## Nothing pinned either half.
    let fp = targetFingerprint()
    let chainFingerprint = repeat('7', 64)

    proc chainDep(level: int): ContributionDependencyRef =
      ContributionDependencyRef(targetPackage: "chain-" & $level,
        contributor: Contributor,
        targetInterfaceFingerprint: chainFingerprint)

    # A chain of DISTINCT coordinates: ``visited`` never fires, so the
    # depth bound is the only thing that can stop it.
    var chainLength = 0
    proc chainResolver(d: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        if not d.targetPackage.startsWith("chain-"):
          return none(ContributionIdentity)
        var level = 0
        try:
          level = parseInt(d.targetPackage["chain-".len .. ^1])
        except ValueError:
          return none(ContributionIdentity)
        var deps: seq[ContributionDependencyRef] = @[]
        if level < chainLength:
          deps.add(chainDep(level + 1))
        some(ContributionIdentity(
          contribution: InterfaceProvisioningContribution(
            targetPackage: d.targetPackage,
            targetInterfaceFingerprint: chainFingerprint,
            contributor: Contributor,
            nixProvisioning: @[InterfaceNixProvisioning(
              packageName: d.targetPackage, contributor: Contributor,
              selector: "nixpkgs#chain", executablePath: "bin/chain",
              nixpkgsRev: NixRev, nixpkgsNarHash: NarHashA)]),
          providerIdentity: ProviderB,
          dependencies: deps))

    let root = identityOf(contributionDef(fp, nix = @[nixDef()]),
      dependencies = @[chainDep(0)])

    # The root sits at depth 0 and ``chain-<n>`` at depth n + 1, so the
    # node at depth ``MaxContributionDepth`` is ``chain-63``: a graph
    # whose deepest node is ``chain-63`` is the last one INSIDE the
    # bound, and giving ``chain-63`` a dependency of its own is the first
    # one outside it.
    chainLength = MaxContributionDepth - 1
    let inside = contributionFingerprint(root, chainResolver)
    check inside.isResolved
    check inside.hex.len == 64

    chainLength = MaxContributionDepth
    let outside = contributionFingerprint(root, chainResolver)
    check not outside.isResolved
    # REFUSES, rather than truncating to a hex computed over the first 64
    # levels: an empty hex is the only acceptable answer here.
    check outside.hex.len == 0
    check outside.refusalReason.contains(
      "contribution dependency depth exceeds " & $MaxContributionDepth)
    check outside.refusalReason.contains("chain-" & $MaxContributionDepth)

    # Deeper still stays refused rather than wrapping around into some
    # other verdict.
    chainLength = MaxContributionDepth * 3
    let far = contributionFingerprint(root, chainResolver)
    check not far.isResolved
    check far.hex.len == 0

  test "length-prefix framing prevents boundary confusion":
    ## M7 hardening, defect 3c. Every value is length-prefixed before it
    ## is concatenated so that no value can be confused with its
    ## neighbour. Measured during verification: deleting the length
    ## prefix from ``putStr`` left the whole suite GREEN — the one
    ## mutation of fourteen that did not redden. These are the collisions
    ## that mutation produces.
    let pinned = repeat('4', 64)

    proc framed(contributor, targetPackage: string): string =
      ## Built directly rather than through ``toProjectInterface``,
      ## because the projection would reject a target package that is not
      ## a registered one. This is the record shape a decoder hands the
      ## composer.
      {.cast(gcsafe).}:
        let identity = ContributionIdentity(
          contribution: InterfaceProvisioningContribution(
            targetPackage: targetPackage,
            targetInterfaceFingerprint: pinned,
            contributor: contributor,
            # Byte-identical in both members of the pair, so the ONLY
            # difference between the two payloads is where the boundary
            # between the contributor and the target package falls.
            nixProvisioning: @[InterfaceNixProvisioning(
              packageName: "framing", contributor: "framing",
              selector: "nixpkgs#framing", executablePath: "bin/framing",
              nixpkgsRev: NixRev, nixpkgsNarHash: NarHashA)]),
          providerIdentity: ProviderA)
        let fp = contributionFingerprint(identity, noContributionResolver)
        if not fp.isResolved:
          raise newException(ValueError, "refused: " & fp.refusalReason)
        fp.hex

    # ("ab", "c") and ("a", "bc") concatenate to the same bytes without a
    # length prefix.
    let split1 = framed("ab", "c")
    let split2 = framed("a", "bc")
    check split1.len == 64
    check split2.len == 64
    check split1 != split2

    # The same confusion one field along, and with a longer shared run so
    # the pair is not a one-character curiosity.
    check framed("catalog", "target") != framed("catalogtar", "get")

    # The dependency BASE CASE frames its own coordinate and is a
    # separate payload with its own magic, so it is pinned separately.
    proc leafOf(targetPackage, contributor: string): string =
      {.cast(gcsafe).}:
        leafContributionIdentityHex(ContributionDependencyRef(
          targetPackage: targetPackage, contributor: contributor,
          targetInterfaceFingerprint: pinned))

    check leafOf("ab", "c") != leafOf("a", "bc")
    check leafOf("libz", "github:x/y") != leafOf("libzgithub:x", "/y")

    # Non-vacuity control: the pairs above differ because of FRAMING, not
    # because every call of these helpers differs — the same coordinate
    # spelled the same way is the same identity.
    check framed("ab", "c") == split1
    check leafOf("ab", "c") == leafOf("ab", "c")

    # And the leaf magic keeps a leaf apart from a full contribution over
    # the same coordinate, which is the other half of the framing claim.
    check leafOf("c", "ab") != framed("ab", "c")

  test "a dependency-free contribution is fully bound":
    ## M7 hardening, defect 1. The marker added for unresolved
    ## dependencies must not penalise a contribution that declares NONE:
    ## an empty dependency set is complete evidence, not missing
    ## evidence. Same distinction ``source_cache_identity``'s
    ## ``dependenciesResolved`` draws between "solved to the empty set"
    ## and "not solved yet".
    let fp = targetFingerprint()
    let depFree = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()])),
      noContributionResolver)
    check depFree.isResolved
    check depFree.unresolvedDependencies.len == 0
    check depFree.dependenciesFullyResolved

    # The same contribution WITH a dependency the resolver binds is
    # equally fully bound — the flag tracks binding, not the presence of
    # dependencies.
    let dep = ContributionDependencyRef(targetPackage: "libz",
      contributor: Contributor, targetInterfaceFingerprint: repeat('1', 64))

    proc bindingResolver(d: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        if d.targetPackage != "libz":
          return none(ContributionIdentity)
        some(ContributionIdentity(
          contribution: InterfaceProvisioningContribution(
            targetPackage: "libz",
            targetInterfaceFingerprint: repeat('1', 64),
            contributor: Contributor,
            nixProvisioning: @[InterfaceNixProvisioning(
              packageName: "libz", contributor: Contributor,
              selector: "nixpkgs#zlib", executablePath: "lib/libz.so",
              nixpkgsRev: NixRev, nixpkgsNarHash: NarHashA)]),
          providerIdentity: ProviderB))

    let bound = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]),
        dependencies = @[dep]), bindingResolver)
    check bound.isResolved
    check bound.unresolvedDependencies.len == 0
    check bound.dependenciesFullyResolved

    # Non-vacuity control: the flag is not hard-wired true. The SAME
    # contribution with the SAME dependency, composed with the
    # leaf-folding resolver, is not fully bound.
    let unbound = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]),
        dependencies = @[dep]), noContributionResolver)
    check unbound.isResolved
    check not unbound.dependenciesFullyResolved

  test "an unresolved dependency is reported by coordinate":
    ## M7 hardening, defect 1. ``isResolved`` answers "did a usable hex
    ## come out", which was TRUE whether every dependency was bound or
    ## every one folded in as a coordinate-only leaf. A consumer could
    ## not tell a complete fingerprint from a leaf-padded one; a lock
    ## writer needs to.
    let fp = targetFingerprint()
    let libz = ContributionDependencyRef(targetPackage: "libz",
      contributor: Contributor, targetInterfaceFingerprint: repeat('1', 64))
    let libssl = ContributionDependencyRef(targetPackage: "libssl",
      contributor: OtherContributor,
      targetInterfaceFingerprint: repeat('2', 64))

    let both = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]),
        dependencies = @[libz, libssl]), noContributionResolver)
    check both.isResolved
    check not both.dependenciesFullyResolved
    check both.unresolvedDependencies.len == 2
    var reported: seq[string] = @[]
    for d in both.unresolvedDependencies:
      reported.add(contributionCoordinate(d))
    check contributionCoordinate(libz) in reported
    check contributionCoordinate(libssl) in reported
    # The full coordinate is reported, not just the package name: a lock
    # writer has to name the contributor and the pinned interface too.
    check reported[0].contains(Contributor) or reported[1].contains(Contributor)
    check reported[0].contains(OtherContributor) or
      reported[1].contains(OtherContributor)

    # A resolver that binds only ONE of them reports exactly the other.
    proc partialResolver(d: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        if d.targetPackage != "libz":
          return none(ContributionIdentity)
        some(ContributionIdentity(
          contribution: InterfaceProvisioningContribution(
            targetPackage: "libz",
            targetInterfaceFingerprint: repeat('1', 64),
            contributor: Contributor,
            nixProvisioning: @[InterfaceNixProvisioning(
              packageName: "libz", contributor: Contributor,
              selector: "nixpkgs#zlib", executablePath: "lib/libz.so",
              nixpkgsRev: NixRev, nixpkgsNarHash: NarHashA)]),
          providerIdentity: ProviderB))

    let partial = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]),
        dependencies = @[libz, libssl]), partialResolver)
    check partial.isResolved
    check not partial.dependenciesFullyResolved
    check partial.unresolvedDependencies.len == 1
    check contributionCoordinate(partial.unresolvedDependencies[0]) ==
      contributionCoordinate(libssl)

    # Reporting is order-independent and de-duplicated: the same
    # coordinate declared twice is one unbound coordinate, and declaring
    # the pair in the other order reports the same set.
    let flipped = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]),
        dependencies = @[libssl, libz, libssl]), noContributionResolver)
    check flipped.unresolvedDependencies.len == 2
    var flippedReported: seq[string] = @[]
    for d in flipped.unresolvedDependencies:
      flippedReported.add(contributionCoordinate(d))
    reported.sort(cmp)
    flippedReported.sort(cmp)
    check flippedReported == reported

  test "the unresolved-dependency alias is flagged rather than silent":
    ## M7 hardening, defect 1, the measured aliasing itself. An
    ## unresolved dependency binds only its DECLARED coordinate, so two
    ## catalogs that differ only in that dependency's realization
    ## metadata land on the same hex. That is a property of declaration
    ## space and it is not fixed here — what is fixed is that it is no
    ## longer SILENT.
    let fp = targetFingerprint()
    let dep = ContributionDependencyRef(targetPackage: "libz",
      contributor: Contributor, targetInterfaceFingerprint: repeat('1', 64))
    let root = identityOf(contributionDef(fp, nix = @[nixDef()]),
      dependencies = @[dep])

    proc depIdentityWith(selector: string): ContributionIdentity =
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

    # Two catalogs whose ONLY difference is the dependency's realization.
    var catalogSelector = "nixpkgs#zlib"
    proc catalogResolver(d: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        if d.targetPackage == "libz": some(depIdentityWith(catalogSelector))
        else: none(ContributionIdentity)

    let unresolvedOne = contributionFingerprint(root, noContributionResolver)
    catalogSelector = "nixpkgs#zlib-static"
    let unresolvedTwo = contributionFingerprint(root, noContributionResolver)

    # Still the same hex — the alias is real and is not claimed fixed.
    check unresolvedOne.hex == unresolvedTwo.hex
    # But both now SAY so, which is the fix: a consumer can refuse to
    # serialise either one into a lock.
    check not unresolvedOne.dependenciesFullyResolved
    check not unresolvedTwo.dependenciesFullyResolved
    check contributionCoordinate(unresolvedOne.unresolvedDependencies[0]) ==
      contributionCoordinate(dep)
    check contributionCoordinate(unresolvedTwo.unresolvedDependencies[0]) ==
      contributionCoordinate(dep)

    # The control that makes the flag load-bearing: with a binding
    # resolver the SAME pair of catalogs is distinguishable, and neither
    # fingerprint is flagged.
    catalogSelector = "nixpkgs#zlib"
    let boundOne = contributionFingerprint(root, catalogResolver)
    catalogSelector = "nixpkgs#zlib-static"
    let boundTwo = contributionFingerprint(root, catalogResolver)
    check boundOne.hex != boundTwo.hex
    check boundOne.dependenciesFullyResolved
    check boundTwo.dependenciesFullyResolved

  test "an unresolved dependency deeper in the graph still reaches the root":
    ## M7 hardening, defect 1. A leaf-padded fingerprint two levels down
    ## makes the ROOT fingerprint leaf-padded too — its payload contains
    ## the child's hex, which was itself computed over an unbound
    ## coordinate. A marker that stopped at the level it happened on
    ## would let a root claim to be complete while resting on a leaf.
    let fp = targetFingerprint()
    let mid = ContributionDependencyRef(targetPackage: "libmid",
      contributor: Contributor, targetInterfaceFingerprint: repeat('1', 64))
    let deep = ContributionDependencyRef(targetPackage: "libdeep",
      contributor: OtherContributor,
      targetInterfaceFingerprint: repeat('2', 64))

    proc midOnlyResolver(d: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        if d.targetPackage != "libmid":
          return none(ContributionIdentity)
        some(ContributionIdentity(
          contribution: InterfaceProvisioningContribution(
            targetPackage: "libmid",
            targetInterfaceFingerprint: repeat('1', 64),
            contributor: Contributor,
            nixProvisioning: @[InterfaceNixProvisioning(
              packageName: "libmid", contributor: Contributor,
              selector: "nixpkgs#mid", executablePath: "lib/libmid.so",
              nixpkgsRev: NixRev, nixpkgsNarHash: NarHashA)]),
          providerIdentity: ProviderB,
          dependencies: @[deep]))

    let root = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]),
        dependencies = @[mid]), midOnlyResolver)
    check root.isResolved
    check not root.dependenciesFullyResolved
    # The coordinate reported is the one that actually went unbound —
    # the GRANDCHILD, not the intermediate that resolved fine.
    check root.unresolvedDependencies.len == 1
    check contributionCoordinate(root.unresolvedDependencies[0]) ==
      contributionCoordinate(deep)

  test "a cycle-broken edge is reported as unbound too":
    ## M7 hardening, defect 1. A dependency folded in because it is
    ## already on the ``visited`` stack binds its coordinate and nothing
    ## else, exactly as an unresolvable one does. It is the same
    ## leaf-padding and it is reported the same way: deliverable 2 must
    ## not serialise either shape into a lock believing it complete.
    let fp = targetFingerprint()
    let depB = ContributionDependencyRef(targetPackage: "bee",
      contributor: Contributor, targetInterfaceFingerprint: repeat('1', 64))
    let depA = ContributionDependencyRef(targetPackage: "contributionTarget",
      contributor: Contributor, targetInterfaceFingerprint: fp)

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
    check not cyclic.dependenciesFullyResolved
    check cyclic.unresolvedDependencies.len == 1
    check contributionCoordinate(cyclic.unresolvedDependencies[0]) ==
      contributionCoordinate(depA)

  test "a deep diamond composes in bounded time":
    ## M7 hardening, defect 2. ``MaxContributionDepth`` bounds DEPTH, not
    ## WORK: without memoisation a two-edge-per-level diamond re-composed
    ## every shared sub-graph once per path, so cost doubled per level.
    ## Measured on this tree before the fix, in the same shape this case
    ## builds: 428 ms at depth 12, 6.9 s at 16, 27.7 s at 18, 112.7 s at
    ## 20. A legal 40-level diamond did not terminate in practice, which
    ## makes the depth bound a promise the composer could not keep.
    ##
    ## The budget is deliberately generous — three orders of magnitude
    ## above the memoised cost — because this case exists to catch the
    ## return of exponential blow-up, not to police milliseconds on a
    ## loaded CI host.
    const DiamondDepth = 20
    const BudgetMs = 5000.0
    let pinned = repeat('1', 64)

    proc coord(name: string): ContributionDependencyRef =
      ContributionDependencyRef(targetPackage: name,
        contributor: Contributor, targetInterfaceFingerprint: pinned)

    var deepestSelector = "nixpkgs#bottom"

    proc diamondNode(name, selector: string;
                     deps: seq[ContributionDependencyRef]):
        ContributionIdentity =
      ContributionIdentity(
        contribution: InterfaceProvisioningContribution(
          targetPackage: name,
          targetInterfaceFingerprint: pinned,
          contributor: Contributor,
          nixProvisioning: @[InterfaceNixProvisioning(
            packageName: name, contributor: Contributor,
            selector: selector, executablePath: "bin/" & name,
            nixpkgsRev: NixRev, nixpkgsNarHash: NarHashA)]),
        providerIdentity: ProviderA,
        dependencies: deps)

    # ``lvl-k`` -> {``left-k``, ``right-k``} -> ``lvl-(k+1)``: two edges
    # per level, 2^depth distinct paths, 3 distinct coordinates per
    # level. The recursion depth is 2 * DiamondDepth, comfortably inside
    # ``MaxContributionDepth``, so this case measures WORK and not the
    # depth guard.
    proc diamondResolver(d: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        let parts = d.targetPackage.split('-')
        if parts.len != 2:
          return none(ContributionIdentity)
        var level = 0
        try:
          level = parseInt(parts[1])
        except ValueError:
          return none(ContributionIdentity)
        case parts[0]
        of "lvl":
          if level >= DiamondDepth:
            return some(diamondNode(d.targetPackage, deepestSelector, @[]))
          return some(diamondNode(d.targetPackage, "nixpkgs#lvl",
            @[coord("left-" & $level), coord("right-" & $level)]))
        of "left", "right":
          return some(diamondNode(d.targetPackage, "nixpkgs#side",
            @[coord("lvl-" & $(level + 1))]))
        else:
          return none(ContributionIdentity)

    let root = diamondNode("lvl-0", "nixpkgs#lvl",
      @[coord("left-0"), coord("right-0")])

    let started = getMonoTime()
    let composed = contributionFingerprint(root, diamondResolver)
    let elapsedMs = (getMonoTime() - started).inMilliseconds.float

    check composed.isResolved
    check composed.hex.len == 64
    check composed.dependenciesFullyResolved
    checkpoint "diamond depth " & $DiamondDepth & " composed in " &
      $elapsedMs & " ms (budget " & $BudgetMs & " ms)"
    check elapsedMs < BudgetMs

    # Non-vacuity, and the load-bearing half of this case: memoisation
    # must not have replaced the traversal with a shortcut that stops
    # binding the deep graph. The DEEPEST node's realization metadata
    # still moves the root fingerprint.
    deepestSelector = "nixpkgs#bottom-static"
    let moved = contributionFingerprint(root, diamondResolver)
    check moved.isResolved
    check moved.hex != composed.hex

    # And the composition is repeatable: re-running with the original
    # deepest selector lands back on the original hex, so the memo is not
    # leaking state between calls.
    deepestSelector = "nixpkgs#bottom"
    check contributionFingerprint(root, diamondResolver).hex == composed.hex

  test "memoisation: a cycle-touching graph is order-independent":
    ## M7 hardening, defect 2, the soundness half. Memoising a sub-result
    ## by coordinate is only valid for a sub-graph whose value did not
    ## depend on the ``visited`` stack it was computed under. In
    ##
    ##   root -> {cee, why};  cee -> dee;  dee -> why;  why -> cee
    ##
    ## the value of ``cee`` differs between the two branches (reached
    ## under ``root/cee`` the cycle closes at ``cee``; reached under
    ## ``root/why`` it closes at ``why``), so a memo that cached it
    ## regardless would hand the second branch the first branch's answer
    ## and the fingerprint would depend on the order the root happened to
    ## declare its dependencies in.
    ##
    ## Declaration order is not an input of this identity — the canonical
    ## encoding sorts the dependency hexes precisely so it is not — so
    ## the two orders must agree. That is an oracle-free property, and it
    ## is exactly what an unsound memo breaks.
    let fp = targetFingerprint()
    let pinned = repeat('5', 64)

    proc coord(name: string): ContributionDependencyRef =
      ContributionDependencyRef(targetPackage: name,
        contributor: Contributor, targetInterfaceFingerprint: pinned)

    var deeSelector = "nixpkgs#dee"

    proc cycleNode(name: string; deps: seq[ContributionDependencyRef];
                   selector: string): ContributionIdentity =
      ContributionIdentity(
        contribution: InterfaceProvisioningContribution(
          targetPackage: name,
          targetInterfaceFingerprint: pinned,
          contributor: Contributor,
          nixProvisioning: @[InterfaceNixProvisioning(
            packageName: name, contributor: Contributor,
            selector: selector, executablePath: "bin/" & name,
            nixpkgsRev: NixRev, nixpkgsNarHash: NarHashA)]),
        providerIdentity: ProviderB,
        dependencies: deps)

    proc tangledResolver(d: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        case d.targetPackage
        of "cee": some(cycleNode("cee", @[coord("dee")], "nixpkgs#cee"))
        of "dee": some(cycleNode("dee", @[coord("why")], deeSelector))
        of "why": some(cycleNode("why", @[coord("cee")], "nixpkgs#why"))
        else: none(ContributionIdentity)

    let straight = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]),
        dependencies = @[coord("cee"), coord("why")]), tangledResolver)
    let flipped = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]),
        dependencies = @[coord("why"), coord("cee")]), tangledResolver)

    check straight.isResolved
    check flipped.isResolved
    check straight.hex == flipped.hex

    # Both are cycle-broken, so both are leaf-padded and say so — the
    # marker and the memo have to hold at the same time.
    check not straight.dependenciesFullyResolved
    check not flipped.dependenciesFullyResolved

    # Non-vacuity control: the equality above is not two constants
    # agreeing. A change inside the tangle moves BOTH orders, and moves
    # them together.
    deeSelector = "nixpkgs#dee-static"
    let straightMoved = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]),
        dependencies = @[coord("cee"), coord("why")]), tangledResolver)
    let flippedMoved = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]),
        dependencies = @[coord("why"), coord("cee")]), tangledResolver)
    check straightMoved.hex != straight.hex
    check straightMoved.hex == flippedMoved.hex

  test "memoisation: a reused sub-graph still owes the depth refusal":
    ## M7 hardening, defect 2, the other soundness half. A memo keyed on
    ## the coordinate alone would serve a sub-graph computed near the
    ## ROOT to a call site near the depth bound, and the refusal that
    ## sub-graph owes at the deeper position would never be raised — a
    ## hex where the unmemoised composer refuses, which is a false
    ## accept and the one failure this module may not have.
    ##
    ## The shape: the same coordinate ``deep-0`` is reached at two
    ## different depths, by a short edge and by a one-hop-longer one,
    ## and it carries a chain long enough that the difference straddles
    ## ``MaxContributionDepth``.
    let fp = targetFingerprint()
    let pinned = repeat('6', 64)

    proc coord(name: string): ContributionDependencyRef =
      ContributionDependencyRef(targetPackage: name,
        contributor: Contributor, targetInterfaceFingerprint: pinned)

    proc straddleNode(name: string; deps: seq[ContributionDependencyRef]):
        ContributionIdentity =
      ContributionIdentity(
        contribution: InterfaceProvisioningContribution(
          targetPackage: name,
          targetInterfaceFingerprint: pinned,
          contributor: Contributor,
          nixProvisioning: @[InterfaceNixProvisioning(
            packageName: name, contributor: Contributor,
            selector: "nixpkgs#" & name, executablePath: "bin/" & name,
            nixpkgsRev: NixRev, nixpkgsNarHash: NarHashA)]),
        providerIdentity: ProviderB,
        dependencies: deps)

    var chainTail = 0

    proc straddleResolver(d: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        if d.targetPackage == "short":
          # depth 1; its dependency ``deep-0`` lands at depth 2.
          return some(straddleNode("short", @[coord("deep-0")]))
        if d.targetPackage == "long":
          return some(straddleNode("long", @[coord("hop")]))
        if d.targetPackage == "hop":
          # depth 2; its dependency ``deep-0`` lands at depth 3.
          return some(straddleNode("hop", @[coord("deep-0")]))
        if not d.targetPackage.startsWith("deep-"):
          return none(ContributionIdentity)
        var level = 0
        try:
          level = parseInt(d.targetPackage["deep-".len .. ^1])
        except ValueError:
          return none(ContributionIdentity)
        var deps: seq[ContributionDependencyRef] = @[]
        if level < chainTail:
          deps.add(coord("deep-" & $(level + 1)))
        some(straddleNode(d.targetPackage, deps))

    # ``short`` is declared FIRST, so the shallow composition of
    # ``deep-0`` is the one that reaches the memo first and would be the
    # one wrongly served to the deeper ``hop`` branch.
    let root = identityOf(contributionDef(fp, nix = @[nixDef()]),
      dependencies = @[coord("short"), coord("long")])

    # ``deep-0`` at depth 2 recurses to ``deep-61`` at depth 63, which is
    # the last node allowed to recurse; at depth 3 that same chain puts
    # ``deep-61`` at depth 64 and it must refuse.
    chainTail = MaxContributionDepth - 2
    let straddling = contributionFingerprint(root, straddleResolver)
    check not straddling.isResolved
    check straddling.hex.len == 0
    check straddling.refusalReason.contains(
      "contribution dependency depth exceeds " & $MaxContributionDepth)

    # Control: one level shorter and BOTH paths fit, so the same graph
    # composes. Without it the case above would pass against a composer
    # that refused this shape for any reason at all.
    chainTail = MaxContributionDepth - 3
    let fitting = contributionFingerprint(root, straddleResolver)
    check fitting.isResolved
    check fitting.hex.len == 64
    check fitting.dependenciesFullyResolved

  test "memoisation: a leaf-folded edge at the bound still owes its refusal":
    ## M7 hardening, defect 2 — the residual the first memo guard left
    ## open, found by verification and MEASURED before it was closed.
    ##
    ## The first guard recorded the recursion HEIGHT a sub-graph
    ## consumed, counting only the levels it RECURSED through. A
    ## dependency the resolver answers ``none`` for folds in as a leaf
    ## and recurses through nothing, so it added nothing to the height —
    ## but the node owning that edge still owes the depth check, and
    ## that check runs BEFORE the resolver is consulted. At exactly
    ## ``depth + 1 + height == MaxContributionDepth`` the memo therefore
    ## served a sub-graph that a fresh composition REFUSES: a hex where
    ## the unmemoised composer refuses, which is the forbidden direction.
    ##
    ## Two shapes are pinned, because the defect is the boundary and not
    ## the degenerate ``height == 0`` case:
    ##
    ##   G1  the shared node is a single level whose only edge is
    ##       leaf-folded (``height == 0``);
    ##   G8  the shared node carries two more levels below it before the
    ##       leaf-folded edge (``height == 2``).
    ##
    ## Both are asserted the oracle-free way. Declaration order is not
    ## an input of this identity, so ``[short, long]`` and
    ## ``[long, short]`` must reach the identical verdict — and under the
    ## defect they did not: the first order was served from the memo and
    ## produced a hex, the second composed the deep branch first, found
    ## no memo entry, and refused. The shipped
    ## "a cycle-touching graph is order-independent" case asserts the
    ## same property and never reaches this graph.
    let fp = targetFingerprint()
    let pinned = repeat('8', 64)

    proc coord(name: string): ContributionDependencyRef =
      ContributionDependencyRef(targetPackage: name,
        contributor: Contributor, targetInterfaceFingerprint: pinned)

    proc boundNode(name: string; deps: seq[ContributionDependencyRef]):
        ContributionIdentity =
      ContributionIdentity(
        contribution: InterfaceProvisioningContribution(
          targetPackage: name,
          targetInterfaceFingerprint: pinned,
          contributor: Contributor,
          nixProvisioning: @[InterfaceNixProvisioning(
            packageName: name, contributor: Contributor,
            selector: "nixpkgs#" & name, executablePath: "bin/" & name,
            nixpkgsRev: NixRev, nixpkgsNarHash: NarHashA)]),
        providerIdentity: ProviderB,
        dependencies: deps)

    var chainTail = 0
    var subHeight = 0
    var shared = true

    # ``root`` -> {``short``, ``long``}. ``short`` reaches the shared
    # sub-graph at depth 2; ``long`` reaches it through
    # ``c-1 .. c-chainTail`` at depth ``chainTail + 2``. The sub-graph is
    # ``sub-0 .. sub-subHeight`` and its deepest node's only dependency is
    # ``ghost``, which the resolver refuses to bind — so that node
    # recurses through nothing and contributes nothing to the height,
    # while still owing the depth check for the edge it owns.
    #
    # ``shared == false`` gives the two branches DISTINCT sub-graph
    # coordinates (``a-`` / ``b-``) of the same shape. The memo can then
    # never serve one branch's answer to the other, so that variant is a
    # memo-free reference for the verdict, computed inside this suite
    # rather than against a patched build.
    proc branchPrefix(viaShort: bool): string =
      if shared: "sub-" elif viaShort: "a-" else: "b-"

    proc subChain(prefix: string; level: int): ContributionIdentity =
      if level < subHeight:
        boundNode(prefix & $level, @[coord(prefix & $(level + 1))])
      else:
        boundNode(prefix & $level, @[coord("ghost")])

    proc boundResolver(d: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        let name = d.targetPackage
        if name == "ghost":
          # Unbindable: folds in as its leaf, so the node above it
          # recurses through nothing.
          return none(ContributionIdentity)
        if name == "short":
          return some(boundNode("short", @[coord(branchPrefix(true) & "0")]))
        if name == "long":
          return some(boundNode("long", @[coord("c-1")]))
        if name.startsWith("c-"):
          var level = 0
          try:
            level = parseInt(name["c-".len .. ^1])
          except ValueError:
            return none(ContributionIdentity)
          if level < chainTail:
            return some(boundNode(name, @[coord("c-" & $(level + 1))]))
          return some(boundNode(name, @[coord(branchPrefix(false) & "0")]))
        for prefix in ["sub-", "a-", "b-"]:
          if name.startsWith(prefix):
            var level = 0
            try:
              level = parseInt(name[prefix.len .. ^1])
            except ValueError:
              return none(ContributionIdentity)
            return some(subChain(prefix, level))
        none(ContributionIdentity)

    proc compose(order: seq[string]): ContributionFingerprint =
      var deps: seq[ContributionDependencyRef] = @[]
      for name in order:
        deps.add(coord(name))
      contributionFingerprint(
        identityOf(contributionDef(fp, nix = @[nixDef()]), dependencies = deps),
        boundResolver)

    proc bothOrders(tag: string): ContributionFingerprint =
      ## The sharp, oracle-free assertion: the two declaration orders
      ## must reach the identical verdict AND the identical hex.
      let straight = compose(@["short", "long"])
      let flipped = compose(@["long", "short"])
      checkpoint tag & ": [short, long] resolved=" & $straight.isResolved &
        " hex=" & straight.hex
      checkpoint tag & ": [long, short] resolved=" & $flipped.isResolved &
        " hex=" & flipped.hex
      check straight.isResolved == flipped.isResolved
      check straight.hex == flipped.hex
      straight

    # ---- G1: the shared node is one level and its only edge is folded.
    # ``sub-0`` is memoised from the ``short`` branch at depth 2 and is
    # asked for again by ``c-62`` at depth 63, where a fresh composition
    # would put it at depth 64 and its ``ghost`` edge must refuse.
    chainTail = MaxContributionDepth - 2
    subHeight = 0
    shared = true
    let g1 = bothOrders("G1")
    check not g1.isResolved
    check g1.hex.len == 0
    check g1.refusalReason.contains(
      "contribution dependency depth exceeds " & $MaxContributionDepth)

    # The memo-free reference for the same shape: distinct sub-graph
    # coordinates per branch, so nothing can be reused. It must reach the
    # same verdict, and it is what the memoised composer disagreed with.
    shared = false
    let g1Reference = compose(@["short", "long"])
    check g1Reference.isResolved == g1.isResolved
    shared = true

    # ---- G8: the same boundary with a three-level shared sub-graph, so
    # the defect is pinned as the boundary ``depth + 1 + height ==
    # MaxContributionDepth`` and not as an artefact of ``height == 0``.
    chainTail = MaxContributionDepth - 4
    subHeight = 2
    shared = true
    let g8 = bothOrders("G8")
    check not g8.isResolved
    check g8.hex.len == 0
    check g8.refusalReason.contains(
      "contribution dependency depth exceeds " & $MaxContributionDepth)

    shared = false
    let g8Reference = compose(@["short", "long"])
    check g8Reference.isResolved == g8.isResolved
    shared = true

    # ---- Non-vacuity. One level shorter and BOTH shapes fit, in both
    # orders, on one hex — so the refusals above are the depth bound and
    # not this fixture being unbuildable. This is also the control that
    # a guard tightened too far would break.
    chainTail = MaxContributionDepth - 3
    subHeight = 0
    let g1Fits = bothOrders("G1 control")
    check g1Fits.isResolved
    check g1Fits.hex.len == 64

    chainTail = MaxContributionDepth - 5
    subHeight = 2
    let g8Fits = bothOrders("G8 control")
    check g8Fits.isResolved
    check g8Fits.hex.len == 64

    # ---- Boundary neighbours. ``sub-0`` sits at depth
    # ``chainTail + 2`` on the long branch and owes the depth check for
    # its ``ghost`` edge there, so the last chain that fits is
    # ``chainTail == 61`` and ``62`` is the first that does not. Sweeping
    # both sides catches an off-by-one in EITHER direction: too loose and
    # 62 resolves, too tight and 61 refuses.
    subHeight = 0
    for tail in (MaxContributionDepth - 4) .. (MaxContributionDepth - 1):
      chainTail = tail
      let neighbour = bothOrders("neighbour chainTail=" & $tail)
      if tail <= MaxContributionDepth - 3:
        check neighbour.isResolved
        check neighbour.hex.len == 64
      else:
        check not neighbour.isResolved
        check neighbour.refusalReason.contains(
          "contribution dependency depth exceeds " & $MaxContributionDepth)

  test "memoisation: an edge-free deepest node is still reused at the bound":
    ## The other side of the fix, and the reason it is the PRECISE one
    ## rather than the blunt one. Tightening the old height comparison by
    ## one would close the hole above, but it would also stop reusing a
    ## sub-graph whose deepest node owns NO dependency edge — that node
    ## owes no depth check, so it is legal exactly one level deeper than
    ## a height-based bound allows. The fix instead tracks the deepest
    ## relative offset at which some node still OWNS a surviving edge,
    ## which is the quantity the depth check is actually about.
    ##
    ## Measuring "was it reused" needs no access to the memo: the memo is
    ## consulted before the resolver, so counting resolver calls for the
    ## shared coordinate distinguishes a hit from a miss. Under the blunt
    ## variant of the fix this case still produces the right hex — it just
    ## recomposes — so the resolver count is what pins reuse.
    let fp = targetFingerprint()
    let pinned = repeat('9', 64)

    proc coord(name: string): ContributionDependencyRef =
      ContributionDependencyRef(targetPackage: name,
        contributor: Contributor, targetInterfaceFingerprint: pinned)

    var tailSelector = "nixpkgs#tail-2"
    var tailZeroCalls = 0

    proc reuseNode(name, selector: string;
                   deps: seq[ContributionDependencyRef]):
        ContributionIdentity =
      ContributionIdentity(
        contribution: InterfaceProvisioningContribution(
          targetPackage: name,
          targetInterfaceFingerprint: pinned,
          contributor: Contributor,
          nixProvisioning: @[InterfaceNixProvisioning(
            packageName: name, contributor: Contributor,
            selector: selector, executablePath: "bin/" & name,
            nixpkgsRev: NixRev, nixpkgsNarHash: NarHashA)]),
        providerIdentity: ProviderB,
        dependencies: deps)

    # ``tail-0 -> tail-1 -> tail-2``, and ``tail-2`` declares NOTHING.
    # The sub-graph is three levels tall but its deepest EDGE-OWNING node
    # is ``tail-1``, one level up. Reached from the long branch at depth
    # 62, ``tail-1`` lands at depth 63 — the last depth allowed to own an
    # edge — so a fresh composition succeeds and the memo must serve it.
    proc reuseResolver(d: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        let name = d.targetPackage
        if name == "short":
          return some(reuseNode("short", "nixpkgs#short", @[coord("tail-0")]))
        if name == "long":
          return some(reuseNode("long", "nixpkgs#long", @[coord("c-1")]))
        if name.startsWith("c-"):
          var level = 0
          try:
            level = parseInt(name["c-".len .. ^1])
          except ValueError:
            return none(ContributionIdentity)
          if level < MaxContributionDepth - 4:
            return some(reuseNode(name, "nixpkgs#" & name,
              @[coord("c-" & $(level + 1))]))
          return some(reuseNode(name, "nixpkgs#" & name, @[coord("tail-0")]))
        case name
        of "tail-0":
          tailZeroCalls.inc
          return some(reuseNode("tail-0", "nixpkgs#tail-0",
            @[coord("tail-1")]))
        of "tail-1":
          return some(reuseNode("tail-1", "nixpkgs#tail-1",
            @[coord("tail-2")]))
        of "tail-2":
          # No dependencies at all: this node owes no depth check, which
          # is exactly why it may legally sit one level below the last
          # edge-owning depth.
          return some(reuseNode("tail-2", tailSelector, @[]))
        else:
          return none(ContributionIdentity)

    proc compose(order: seq[string]): ContributionFingerprint =
      var deps: seq[ContributionDependencyRef] = @[]
      for name in order:
        deps.add(coord(name))
      contributionFingerprint(
        identityOf(contributionDef(fp, nix = @[nixDef()]), dependencies = deps),
        reuseResolver)

    tailZeroCalls = 0
    let straight = compose(@["short", "long"])
    let straightCalls = tailZeroCalls
    checkpoint "tail-0 resolver calls, [short, long]: " & $straightCalls

    # No false refusal: the graph composes.
    check straight.isResolved
    check straight.hex.len == 64
    check straight.dependenciesFullyResolved

    # And it is still KEYED — the shared coordinate was composed once and
    # served from the memo at the bound, not recomposed.
    check straightCalls == 1

    # Declaration order is still not an input.
    tailZeroCalls = 0
    let flipped = compose(@["long", "short"])
    check flipped.isResolved
    check flipped.hex == straight.hex

    # Non-vacuity: the memoised sub-graph is really bound into the root.
    # Moving the DEEPEST, edge-free node's realization metadata moves the
    # root hex, so the reuse above is not reuse of an empty answer.
    tailSelector = "nixpkgs#tail-2-moved"
    tailZeroCalls = 0
    let moved = compose(@["short", "long"])
    check moved.isResolved
    check moved.hex != straight.hex
    check tailZeroCalls == 1

    tailSelector = "nixpkgs#tail-2"
    tailZeroCalls = 0
    check compose(@["short", "long"]).hex == straight.hex

  test "the pending-identity marker is the codebase's, not a private copy":
    ## ``PendingContributionIdentityMarker`` is a deliberate LITERAL copy
    ## of ``cache_key.PendingCacheIdentityOptionKey``:
    ## ``repro_interface_artifacts`` does not depend on
    ## ``repro_binary_cache_client`` and must not grow the dependency for
    ## one string. Nothing prevented the copy from drifting, and a drifted
    ## copy fails OPEN — a provider identity stamped with the real marker
    ## would stop being refused by name and would be diagnosed as merely
    ## malformed, or not at all.
    ##
    ## The guard is this test rather than an import in the library, so the
    ## duplication stays cheap where it matters (the library's dependency
    ## set) and is checked where it costs nothing (a test binary that may
    ## import both). The ``static`` half makes the drift a COMPILE error.
    static:
      doAssert PendingContributionIdentityMarker ==
        PendingCacheIdentityOptionKey,
        "contribution_fingerprint.PendingContributionIdentityMarker has " &
        "drifted from cache_key.PendingCacheIdentityOptionKey"
    check PendingContributionIdentityMarker == PendingCacheIdentityOptionKey

    # And the marker is load-bearing, not decorative: a provider identity
    # carrying the real constant is refused BY NAME.
    let fp = targetFingerprint()
    let pending = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]),
        providerIdentity = PendingCacheIdentityOptionKey),
      noContributionResolver)
    check not pending.isResolved
    check pending.refusalReason.contains(PendingCacheIdentityOptionKey)

  # -------------------------------------------------------------------------
  # Cases added by the retroactive PER-GUARD mutation audit.
  #
  # Every case above had a falsifying mutation. Applying a mutation to
  # each GUARD individually instead measured something weaker: 44 of 95
  # guards in ``contribution_fingerprint.nim`` could be disabled one at a
  # time with this whole suite, the catalog-composition suite and
  # ``t_provisioning_contributions`` all staying green, because several
  # guards happened to cover the same case. The cases below pin the ones
  # whose failure mode is a FALSE ACCEPT — a fingerprint silently
  # produced where the module owes a refusal, or a fingerprint that does
  # not move when declared realization policy changes. The second shape
  # is a direct violation of the invariant this module exists to serve:
  # *changing a Nix attribute, Scoop manifest, archive URL or source
  # recipe MUST change the contribution fingerprint*.
  # -------------------------------------------------------------------------

  test "every required realization field refuses on its own":
    ## Per-guard audit. The existing fail-closed case supplies ONE
    ## malformed field per realization family, so every other required
    ## field in that family was masked by it: measured, the nix selector,
    ## the nixpkgsRev, the tarball url, the scoop bucket, the scoop app,
    ## the scoop manifestChecksum and the from-source recipePath could
    ## each be dropped from the refusal set with the suite green. A
    ## contribution missing any one of them then fingerprints, and a lock
    ## keyed on that hex pins a realization nobody can reproduce.
    let fp = targetFingerprint()

    proc refuses(identity: ContributionIdentity; expect: string) =
      {.cast(gcsafe).}:
        let got = contributionFingerprint(identity, noContributionResolver)
        check not got.isResolved
        check got.hex.len == 0
        check got.refusalReason.contains(expect)

    # Nix: the selector (or an expression file) names WHAT is realized.
    var noSelector = identityOf(contributionDef(fp, nix = @[nixDef()]))
    noSelector.contribution.nixProvisioning[0].selector = ""
    noSelector.contribution.nixProvisioning[0].expressionFile = ""
    refuses(noSelector, "selector")

    # Nix: the revision the attribute is read at.
    var noRev = identityOf(contributionDef(fp, nix = @[nixDef()]))
    noRev.contribution.nixProvisioning[0].nixpkgsRev = ""
    refuses(noRev, "nixpkgsRev")

    # Tarball: the archive location.
    var noUrl = identityOf(contributionDef(fp, tarball = @[tarballDef()]))
    noUrl.contribution.tarballProvisioning[0].url = ""
    refuses(noUrl, "url")

    # Scoop: the bucket and the app, each on its own.
    var noBucket = identityOf(contributionDef(fp, scoop = @[scoopDef()]))
    noBucket.contribution.scoopProvisioning[0].bucket = ""
    refuses(noBucket, "bucket")

    var noApp = identityOf(contributionDef(fp, scoop = @[scoopDef()]))
    noApp.contribution.scoopProvisioning[0].app = ""
    refuses(noApp, "app")

    # Scoop: the manifest checksum is the family's integrity evidence and
    # was never exercised at all — the fail-closed case tests the NIX and
    # TARBALL integrity fields only.
    var badChecksum = identityOf(contributionDef(fp, scoop = @[scoopDef()]))
    badChecksum.contribution.scoopProvisioning[0].manifestChecksum =
      "not-a-checksum"
    refuses(badChecksum, "manifestChecksum")

    # From source: the recipe path.
    refuses(identityOf(contributionDef(fp, nix = @[nixDef()]),
      fromSource = @[FromSourceRealization(
        packageName: "contributionTarget",
        contributor: Contributor,
        recipePath: "",
        recipeDigest: repeat('7', 64))]), "recipePath")

    # A dependency coordinate missing its TARGET PACKAGE, and one whose
    # pinned interface fingerprint is not a digest. The fail-closed case
    # covers only the missing CONTRIBUTOR.
    refuses(identityOf(contributionDef(fp, nix = @[nixDef()]),
      dependencies = @[ContributionDependencyRef(
        targetPackage: "", contributor: Contributor,
        targetInterfaceFingerprint: repeat('1', 64))]),
      "dependency coordinate")

    refuses(identityOf(contributionDef(fp, nix = @[nixDef()]),
      dependencies = @[ContributionDependencyRef(
        targetPackage: "libz", contributor: Contributor,
        targetInterfaceFingerprint: "not-a-digest")]),
      "target interface fingerprint")

    # The contribution's own target package name.
    var noTargetPackage = identityOf(contributionDef(fp, nix = @[nixDef()]))
    noTargetPackage.contribution.targetPackage = ""
    refuses(noTargetPackage, "target package name")

    # Non-vacuity: each family, complete, still resolves.
    check contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()],
        tarball = @[tarballDef()], scoop = @[scoopDef()])),
      noContributionResolver).isResolved

  test "every declared realization field moves the fingerprint":
    ## Per-guard audit. ``prunePaths``, ``stripComponents`` and
    ## ``requiresExecutionProfileChecksum`` are declared realization
    ## policy that the encoders DO fold in, and nothing measured it:
    ## each could be deleted from its encoder with the suite green, and
    ## the result is a lock that does not notice the policy changing —
    ## the aliasing direction, not the refusing one.
    let fp = targetFingerprint()
    let base = identityOf(contributionDef(fp, tarball = @[tarballDef()],
      scoop = @[scoopDef()]))
    let baseHex = hexOf(base, noContributionResolver)

    var pruned = base
    pruned.contribution.tarballProvisioning[0].prunePaths = @["share/doc"]
    check hexOf(pruned, noContributionResolver) != baseHex

    var stripped = base
    stripped.contribution.tarballProvisioning[0].stripComponents = 2
    check hexOf(stripped, noContributionResolver) != baseHex

    var profiled = base
    profiled.contribution.scoopProvisioning[0].
      requiresExecutionProfileChecksum = true
    check hexOf(profiled, noContributionResolver) != baseHex

    # A set-valued field is SORTED, not de-duplicated: a repeated mirror
    # is a different declaration from a single one, and collapsing it
    # would be a semantic edit rather than a normalisation.
    var oneMirror = base
    oneMirror.contribution.tarballProvisioning[0].mirrors =
      @["https://mirror.invalid/a"]
    var twoMirrors = base
    twoMirrors.contribution.tarballProvisioning[0].mirrors =
      @["https://mirror.invalid/a", "https://mirror.invalid/a"]
    check hexOf(oneMirror, noContributionResolver) !=
      hexOf(twoMirrors, noContributionResolver)
    # ...and ordering it IS a normalisation.
    var reversed = base
    reversed.contribution.tarballProvisioning[0].mirrors =
      @["https://mirror.invalid/b", "https://mirror.invalid/a"]
    var forwards = base
    forwards.contribution.tarballProvisioning[0].mirrors =
      @["https://mirror.invalid/a", "https://mirror.invalid/b"]
    check hexOf(reversed, noContributionResolver) ==
      hexOf(forwards, noContributionResolver)

    # The two set-valued fields are FRAMED against each other: one entry
    # in ``mirrors`` and none in ``prunePaths`` is not the same
    # realization as the reverse. Without the element-count prefix the
    # two encode to the same bytes.
    var mirrorOnly = base
    mirrorOnly.contribution.tarballProvisioning[0].mirrors = @["shared"]
    mirrorOnly.contribution.tarballProvisioning[0].prunePaths = @[]
    var pruneOnly = base
    pruneOnly.contribution.tarballProvisioning[0].mirrors = @[]
    pruneOnly.contribution.tarballProvisioning[0].prunePaths = @["shared"]
    check hexOf(mirrorOnly, noContributionResolver) !=
      hexOf(pruneOnly, noContributionResolver)

  test "a from-source realization is spelled the same on either host":
    ## Per-guard audit, and the cross-HOST class specifically.
    ## ``encodeFromSource`` normalises the recipe path's separators and
    ## folds the recipe digest's case. Both could be dropped with the
    ## suite green, and the consequence is not a missing refusal: the
    ## SAME recipe fingerprints differently on Windows and on Linux, so a
    ## lock written on one host is stale on the other with nothing having
    ## changed.
    let fp = targetFingerprint()
    let digest = repeat('a', 64)

    proc fromSourceHex(recipePath, recipeDigest: string;
                       inputs: seq[(string, string)] = @[]): string =
      {.cast(gcsafe).}:
        hexOf(identityOf(contributionDef(fp, nix = @[nixDef()]),
          fromSource = @[FromSourceRealization(
            packageName: "contributionTarget",
            contributor: Contributor,
            recipePath: recipePath,
            recipeDigest: recipeDigest,
            recipeInputs: inputs)]), noContributionResolver)

    check fromSourceHex("recipes\\contribution-target", digest) ==
      fromSourceHex("recipes/contribution-target", digest)
    check fromSourceHex("recipes/contribution-target", digest.toUpperAscii()) ==
      fromSourceHex("recipes/contribution-target", digest)
    # Non-vacuity: normalisation has not flattened either field.
    check fromSourceHex("recipes/other", digest) !=
      fromSourceHex("recipes/contribution-target", digest)

    # A declared recipe input is a (name, value) PAIR, and the name is
    # part of the identity: dropping it from the encoding makes two
    # different input maps the same contribution.
    check fromSourceHex("recipes/x", digest, @[("alpha", "v1")]) !=
      fromSourceHex("recipes/x", digest, @[("beta", "v1")])
    # ...and the map is ordered by (name, value), so two entries sharing a
    # name cannot swap. Without the value tie-break the sort is unstable
    # across them.
    check fromSourceHex("recipes/x", digest, @[("a", "1"), ("a", "2")]) ==
      fromSourceHex("recipes/x", digest, @[("a", "2"), ("a", "1")])
    check fromSourceHex("recipes/x", digest, @[("a", "1"), ("a", "2")]) !=
      fromSourceHex("recipes/x", digest, @[("a", "1"), ("a", "3")])

  test "integrity evidence must be evidence, not evidence-shaped":
    ## Per-guard audit. ``isDigestField`` accepts a bare 64-hex digest or
    ## an SRI spelling, and the SRI branch checks a minimum body length
    ## and the base64 alphabet. Both of those checks could be deleted
    ## with the suite green, because every malformed value the existing
    ## cases use fails at the outer branch instead. "sha256-" followed by
    ## anything then satisfies a REQUIRED integrity field.
    let fp = targetFingerprint()

    proc narHashRefuses(value: string) =
      {.cast(gcsafe).}:
        var identity = identityOf(contributionDef(fp, nix = @[nixDef()]))
        identity.contribution.nixProvisioning[0].nixpkgsNarHash = value
        let got = contributionFingerprint(identity, noContributionResolver)
        check not got.isResolved
        check got.refusalReason.contains("nixpkgsNarHash")

    narHashRefuses("sha256-short")
    narHashRefuses("sha256-" & repeat('!', 44))
    narHashRefuses("sha256-AAAA AAAA AAAA AAAA AAAA AAAA")
    # Non-vacuity: the real SRI spelling and a bare hex both still pass.
    check contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()])),
      noContributionResolver).isResolved
    var hexHash = identityOf(contributionDef(fp, nix = @[nixDef()]))
    hexHash.contribution.nixProvisioning[0].nixpkgsNarHash = repeat('9', 64)
    check contributionFingerprint(hexHash, noContributionResolver).isResolved

  test "a pin's spelling is not part of the contribution's identity":
    ## Per-guard audit. ``normalizedFingerprint`` strips surrounding
    ## whitespace before it folds case and removes the algorithm prefix.
    ## The case fold and the prefix strip are pinned by the provider-
    ## identity case; the STRIP was not, and a pin read out of a file with
    ## a trailing newline would otherwise be a different contribution.
    let fp = targetFingerprint()
    let padded = identityOf(contributionDef("  " & fp & "\n",
      nix = @[nixDef()]))
    check hexOf(padded, noContributionResolver) ==
      hexOf(identityOf(contributionDef(fp, nix = @[nixDef()])),
        noContributionResolver)

    # The same normalisation governs a DEPENDENCY coordinate, which is
    # what de-duplicates the unbound report and keys the memo. Two
    # spellings of one pinned coordinate are one coordinate.
    let unbound = contributionFingerprint(
      identityOf(contributionDef(fp, nix = @[nixDef()]),
        dependencies = @[
          ContributionDependencyRef(targetPackage: "libz",
            contributor: Contributor,
            targetInterfaceFingerprint: repeat('1', 64)),
          ContributionDependencyRef(targetPackage: "libz",
            contributor: Contributor,
            targetInterfaceFingerprint:
              "blake3-256:" & repeat('1', 64).toUpperAscii())]),
      noContributionResolver)
    check unbound.isResolved
    check unbound.unresolvedDependencies.len == 1
    # ...and the payload binds it once, so a coordinate repeated in two
    # spellings is not a different contribution from one spelled once.
    check unbound.hex == hexOf(identityOf(contributionDef(fp,
      nix = @[nixDef()]),
      dependencies = @[ContributionDependencyRef(targetPackage: "libz",
        contributor: Contributor,
        targetInterfaceFingerprint: repeat('1', 64))]),
      noContributionResolver)

  test "a dependency coordinate's package and contributor are framed apart":
    ## Per-guard audit. ``dependencyKey`` separates the target package
    ## from the contributor with a NUL, and the ``visited`` stack is keyed
    ## on it. Concatenating them instead makes ("ab", "c") and ("a", "bc")
    ## the same key, so a perfectly ordinary dependency edge reads as a
    ## CYCLE: it folds in as its leaf, the resolver is never consulted,
    ## and the dependency's realization metadata silently stops being part
    ## of the parent's identity.
    let fp = targetFingerprint()
    var root = identityOf(contributionDef(fp, nix = @[nixDef()]),
      dependencies = @[ContributionDependencyRef(
        targetPackage: "a", contributor: "bc",
        targetInterfaceFingerprint: repeat('1', 64))])
    root.contribution.targetPackage = "ab"
    root.contribution.contributor = "c"

    var depSelector = "nixpkgs#dep-1"
    proc resolver(dep: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        var identity = identityOf(contributionDef(fp,
          nix = @[nixDef(selector = depSelector)]))
        identity.contribution.targetPackage = dep.targetPackage
        identity.contribution.contributor = dep.contributor
        identity.contribution.targetInterfaceFingerprint =
          dep.targetInterfaceFingerprint
        some(identity)

    let bound = contributionFingerprint(root, resolver)
    check bound.isResolved
    check bound.dependenciesFullyResolved
    # The edge is really bound, not merely unreported: the dependency's
    # own realization metadata moves the parent.
    depSelector = "nixpkgs#dep-2"
    let moved = contributionFingerprint(root, resolver)
    check moved.isResolved
    check moved.hex != bound.hex

  test "the memo is keyed on the full dependency coordinate":
    ## Per-guard audit, and the module docstring's own claim: the memo is
    ## keyed on (package, contributor, normalised target interface
    ## fingerprint) and "deliberately not the 2-part ``visited`` key,
    ## which two dependencies pinned to different interface revisions
    ## share". Nothing measured it. Keyed on the 2-part key, the second
    ## dependency is served the FIRST one's sub-fingerprint, and the
    ## parent's identity stops moving with the second dependency's
    ## realization metadata — two revisions of one dependency on one key,
    ## which is the #171 aliasing class in declaration space.
    let fp = targetFingerprint()
    let pinA = repeat('1', 64)
    let pinB = repeat('2', 64)
    let root = identityOf(contributionDef(fp, nix = @[nixDef()]),
      dependencies = @[
        ContributionDependencyRef(targetPackage: "libz",
          contributor: Contributor, targetInterfaceFingerprint: pinA),
        ContributionDependencyRef(targetPackage: "libz",
          contributor: Contributor, targetInterfaceFingerprint: pinB)])

    var selectorForB = "nixpkgs#libz-b1"
    proc resolver(dep: ContributionDependencyRef):
        Option[ContributionIdentity] {.gcsafe.} =
      {.cast(gcsafe).}:
        let selector =
          if dep.targetInterfaceFingerprint == pinA: "nixpkgs#libz-a"
          else: selectorForB
        var identity = identityOf(contributionDef(fp,
          nix = @[nixDef(selector = selector)]))
        identity.contribution.targetPackage = dep.targetPackage
        identity.contribution.contributor = dep.contributor
        identity.contribution.targetInterfaceFingerprint =
          dep.targetInterfaceFingerprint
        some(identity)

    let before = contributionFingerprint(root, resolver)
    check before.isResolved
    check before.dependenciesFullyResolved
    selectorForB = "nixpkgs#libz-b2"
    let after = contributionFingerprint(root, resolver)
    check after.isResolved
    check after.hex != before.hex

  test "a repeated dependency edge is one edge":
    ## Per-guard audit. The dependency hexes are sorted AND
    ## de-duplicated before they are length-prefixed into the payload.
    ## The sort is pinned by the order-independence case; the de-dup was
    ## not, and without it declaring one dependency twice is a different
    ## contribution from declaring it once — which makes the identity
    ## depend on how a catalog happened to spell its edges.
    let fp = targetFingerprint()
    let dep = ContributionDependencyRef(targetPackage: "libz",
      contributor: Contributor, targetInterfaceFingerprint: repeat('1', 64))
    check hexOf(identityOf(contributionDef(fp, nix = @[nixDef()]),
      dependencies = @[dep, dep]), noContributionResolver) ==
      hexOf(identityOf(contributionDef(fp, nix = @[nixDef()]),
        dependencies = @[dep]), noContributionResolver)

  test "a refusal names every cause once, in one order":
    ## Per-guard audit. ``refusals`` is sorted and de-duplicated before
    ## it is reported. Both could be dropped with the suite green,
    ## because every existing refusal case produces exactly one cause.
    ## A refusal list that depends on check order is a diagnostic two
    ## equal inputs disagree about.
    let fp = targetFingerprint()
    var broken = identityOf(contributionDef(fp,
      nix = @[nixDef(), nixDef(selector = "nixpkgs#other")]))
    broken.contribution.contributor = ""
    broken.contribution.nixProvisioning[0].nixpkgsRev = ""
    broken.contribution.nixProvisioning[0].nixpkgsNarHash = ""
    broken.contribution.nixProvisioning[1].nixpkgsRev = ""
    broken.contribution.nixProvisioning[1].nixpkgsNarHash = ""
    broken.providerIdentity = ""
    let got = contributionFingerprint(broken, noContributionResolver)
    check not got.isResolved
    check got.refusals.len > 1
    check got.refusals == got.refusals.sorted(cmp)
    check got.refusals == got.refusals.deduplicate(isSorted = true)

    # De-duplication is reachable, not decorative: two realizations that
    # are broken in the SAME way name the same cause twice.
    var twinned = identityOf(contributionDef(fp,
      nix = @[nixDef(), nixDef()]))
    twinned.contribution.nixProvisioning[0].nixpkgsRev = ""
    twinned.contribution.nixProvisioning[1].nixpkgsRev = ""
    let twin = contributionFingerprint(twinned, noContributionResolver)
    check not twin.isResolved
    check twin.refusals.deduplicate(isSorted = true).len == twin.refusals.len

  test "the canonical encoding is pinned by value, not only by relation":
    ## Per-guard audit, and the only case in this file that pins a
    ## LITERAL. Several encoding guards have no reachable counterexample
    ## — the domain magic of the payload, the record magic, the leaf
    ## magic, the realization- and dependency-count prefixes, the
    ## little-endian width of a length word — because the shapes they
    ## separate cannot be made to coincide with the encoders this module
    ## has. They are still the contract: the module docstring states that
    ## bumping a magic re-keys every contribution, which is only
    ## meaningful if the value is fixed.
    ##
    ## The input is built from LITERALS rather than lifted through
    ## ``toProjectInterface``, deliberately: the value under test is
    ## ``contribution_fingerprint``'s encoding, and folding the DSL's
    ## canonical interface fingerprint into it would make this case go
    ## red whenever an unrelated package declaration moved.
    ##
    ## What it does NOT prove: that the encoding is injective. It pins
    ## the bytes of ONE input. A deliberate re-key must bump
    ## ``ContributionFingerprintMagic`` and update this literal in the
    ## same commit.
    let contribution = InterfaceProvisioningContribution(
      targetPackage: "pinnedTarget",
      targetInterfaceFingerprint: repeat('a', 64),
      contributor: "github:example/pinned-catalog",
      developInterface: false,
      nixProvisioning: @[InterfaceNixProvisioning(
        packageName: "pinnedTarget",
        contributor: "github:example/pinned-catalog",
        selector: "nixpkgs#pinned",
        executablePath: "bin/pinned",
        nixpkgsRef: "github:NixOS/nixpkgs",
        nixpkgsRev: repeat('b', 40),
        nixpkgsNarHash: repeat('c', 64),
        packageId: "pinned@1.0.0")])
    let identity = ContributionIdentity(
      contribution: contribution,
      providerIdentity: repeat('d', 64),
      fromSourceProvisioning: @[FromSourceRealization(
        packageName: "pinnedTarget",
        contributor: "github:example/pinned-catalog",
        recipePath: "recipes/pinned",
        recipeDigest: repeat('e', 64),
        recipeInputs: @[("toolchain", "cmake-3.29.2")])],
      dependencies: @[ContributionDependencyRef(
        targetPackage: "libpinned",
        contributor: "github:example/pinned-catalog",
        targetInterfaceFingerprint: repeat('f', 64))])
    let fingerprint = contributionFingerprint(identity,
      noContributionResolver)
    check fingerprint.isResolved
    check fingerprint.hex == PinnedContributionHex
    check leafContributionIdentityHex(identity.dependencies[0]) ==
      PinnedLeafHex
    check interfaceContributionRecordDigest(contribution) ==
      PinnedRecordDigestHex
    # The three domains are separated by construction, so no value of one
    # can ever be read as a value of another.
    check ContributionFingerprintMagic != ContributionLeafMagic
    check ContributionFingerprintMagic != ContributionRecordMagic
    check ContributionLeafMagic != ContributionRecordMagic
    check fingerprint.hex != PinnedLeafHex
    check fingerprint.hex != PinnedRecordDigestHex

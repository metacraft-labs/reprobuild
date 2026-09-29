## M7 deliverable 4, second half -- "keep downstream typechecking cached for
## realization-only changes" -- at the interface-artifact level.
##
## ``ReproOS-Campaign-Completion.milestones.org`` § M7; normative design
## ``reprobuild-specs/Provisioning-Contributions.md`` § Interface Artifacts:
## contribution records "participate in the catalog project's interface
## fingerprint. They do not participate in the target package's interface
## fingerprint."
##
## A consumer's artifact carries every contribution record its compilation
## registered. Before v18 each one entered the consumer's
## ``interfaceFingerprint`` in full, so a realization-only change of ANY
## imported contributor -- selected or not -- moved the consumer's typecheck
## identity. v18 marks the records the project did not declare as
## ``imported`` (``markImportedContributions``) and fingerprints them by
## coordinate only; the realization metadata left out is re-bound by
## ``importedProvisioningMetadataDigest`` wherever it is read and cached.
## Each case below names the property it pins, in both directions. The
## end-to-end measurement (provider-compile edge, lock identity, CLI cache,
## realized archives) is in
## ``tests/integration/t_e2e_locked_provisioning_contributor_selection``.
##
## No mocks: packages come from the real DSL, contributions are lifted by
## the real ``toProjectInterface``, artifacts go through the real codec.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_hash
import repro_interface_artifacts
import repro_interface_artifacts/contribution_fingerprint
import repro_project_dsl

package impTarget:
  executable impTarget:
    name "imp-target"
    cli:
      subcmd "run":
        flag verbose, bool

package impConsumer:
  defaultToolProvisioning "nix"
  uses:
    "impTarget"

const
  A = "github:example/imp-catalog-a"
  B = "github:example/imp-catalog-b"
  NixpkgsRev = "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"
  NarA = "sha256-" & repeat('A', 43) & "="
  NarA2 = "sha256-" & repeat('D', 43) & "="
  NarB = "sha256-" & repeat('B', 43) & "="
  NarB2 = "sha256-" & repeat('E', 43) & "="

let root = createTempDir("repro-imported-contributions-", "")
let consumerRoot = root / "consumer"
let consumerModule = consumerRoot / "repro.nim"
let catalogFile = root / "catalogs" / "imp_catalog.nim"
let ownCatalogFile = consumerRoot / "catalogs" / "own_catalog.nim"

proc findPackage(name: string; packages = registeredPackages()): PackageDef =
  for pkg in packages:
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

proc def(contributor, selector, narHash: string; file = catalogFile;
         packages = registeredPackages()): ProvisioningContributionDef =
  ProvisioningContributionDef(
    targetPackage: "impTarget",
    targetInterfaceFingerprint:
      canonicalPackageInterfaceFingerprint(findPackage("impTarget", packages),
        packages),
    contributor: contributor,
    nixProvisioning: @[NixPackageProvisioningDef(
      selector: selector, executablePath: "bin/imp-target",
      nixpkgsRef: "github:NixOS/nixpkgs", nixpkgsRev: NixpkgsRev,
      nixpkgsNarHash: narHash, packageId: "imp-target@1",
      lockIdentity: "github:NixOS/nixpkgs/" & NixpkgsRev & "?narHash=" &
        narHash & "#" & selector["nixpkgs#".len .. ^1])],
    sourceFile: file, sourceLine: 1)

proc consumer(defs: seq[ProvisioningContributionDef]; mark = true;
              packages = registeredPackages()): ProjectInterface =
  ## The consumer's interface as extraction produces it: lifted, then its
  ## records marked against the consumer's root recipe.
  result = toProjectInterface(findPackage("impConsumer", packages), packages,
    defs)
  if mark:
    markImportedContributions(result, consumerModule)

proc ifp(pi: ProjectInterface): string =
  toHex(interfaceFingerprint(pi).bytes).toLowerAscii()

proc v17Fingerprint(pi: ProjectInterface): string =
  ## The fingerprint as the v17 codec computed it: every record in full.
  toHex(blake3DomainDigest(encodeInterfacePayload(pi, 17'u16,
    forFingerprint = true), hdMetadataEnvelope).bytes).toLowerAscii()

let base = @[def(A, "nixpkgs#imp-a", NarA), def(B, "nixpkgs#imp-b", NarB)]

suite "imported contribution records and the consumer's typecheck identity":
  test "records declared outside the project are marked imported; inside, unknown or unrooted stay own":
    let pi = consumer(@[def(A, "nixpkgs#imp-a", NarA),
      def(B, "nixpkgs#imp-b", NarB, file = ownCatalogFile),
      def(B, "nixpkgs#imp-b2", NarB, file = "")])
    check pi.provisioningContributions.mapIt(it.imported) ==
      @[true, false, false]
    # The root recipe itself declares its own records -- also when the
    # declaration's file is spelled relative to somewhere else than the
    # process's working directory (the same suffix match that finds the
    # root PACKAGE).
    let rootDeclared = consumer(@[def(A, "nixpkgs#imp-a", NarA,
      file = consumerModule),
      def(B, "nixpkgs#imp-b", NarB, file = "consumer/repro.nim")])
    check rootDeclared.provisioningContributions.mapIt(it.imported) ==
      @[false, false]
    # No root hint: nothing is marked.
    var unrooted = consumer(base, mark = false)
    markImportedContributions(unrooted, "")
    check unrooted.provisioningContributions.allIt(not it.imported)

  test "extraction (artifactFromRegisteredDsl) marks the records its project did not declare":
    # This module is the "project": its packages are declared here, so its
    # own path is the root recipe.
    let here = currentSourcePath()
    resetProvisioningContributionRegistry()
    registerProvisioningContributionDef(def(A, "nixpkgs#imp-a", NarA))
    registerProvisioningContributionDef(def(B, "nixpkgs#imp-b", NarB,
      file = here))
    let rooted = artifactFromRegisteredDsl(here)
    let unrooted = artifactFromRegisteredDsl()
    resetProvisioningContributionRegistry()
    check rooted.projectInterface.provisioningContributions.mapIt(
      (it.contributor, it.imported)) == @[(A, true), (B, false)]
    check unrooted.projectInterface.provisioningContributions.allIt(
      not it.imported)
    check rooted.interfaceFingerprint ==
      interfaceFingerprint(rooted.projectInterface)
    check rooted.interfaceFingerprint != unrooted.interfaceFingerprint

  test "a realization-only change of an imported record keeps the typecheck identity, and the metadata digest moves":
    let before = consumer(base)
    # Selected-or-not is irrelevant here: A's and B's realizations change.
    let changedA = consumer(@[def(A, "nixpkgs#imp-a", NarA2),
      def(B, "nixpkgs#imp-b", NarB)])
    let changedB = consumer(@[def(A, "nixpkgs#imp-a", NarA),
      def(B, "nixpkgs#imp-b-next", NarB2)])
    check ifp(changedA) == ifp(before)
    check ifp(changedB) == ifp(before)
    # The realization metadata is NOT dropped: it is re-bound by the digest
    # every realization reader keys on.
    let digest = importedProvisioningMetadataDigest(before)
    check digest.len == 64
    check importedProvisioningMetadataDigest(changedA) != digest
    check importedProvisioningMetadataDigest(changedB) != digest
    check importedProvisioningMetadataDigest(changedA) !=
      importedProvisioningMetadataDigest(changedB)
    # Before v18 both changes moved it.
    check v17Fingerprint(changedA) != v17Fingerprint(before)
    check v17Fingerprint(changedB) != v17Fingerprint(before)

  test "an interface change of the imported contribution's target still moves the typecheck identity":
    var packages = registeredPackages().filterIt(it.packageName != "impTarget")
    var changed = findPackage("impTarget")
    # A second public executable: the canonical interface moves, while the
    # consumer's own tool use of the first one is byte-identical -- so what
    # moves the consumer is the imported records' target fingerprint.
    changed.executables.add(ExecutableDef(exportName: "impExtra",
      binaryName: "imp-extra"))
    packages.add(changed)
    let before = consumer(base)
    let after = consumer(@[def(A, "nixpkgs#imp-a", NarA, packages = packages),
      def(B, "nixpkgs#imp-b", NarB, packages = packages)], packages = packages)
    check after.toolUses == before.toolUses
    check after.provisioningContributions[0].targetInterfaceFingerprint !=
      before.provisioningContributions[0].targetInterfaceFingerprint
    check ifp(after) != ifp(before)
    # With no imported record, the same change would be invisible here.
    check ifp(consumer(@[], packages = packages)) == ifp(consumer(@[]))

  test "the imported coordinate binds contributor, target fingerprint and develop flag, and multiplicity":
    let before = consumer(base)
    var renamed = before
    renamed.provisioningContributions[1].contributor = B & "-renamed"
    check ifp(renamed) != ifp(before)
    var otherTarget = before
    otherTarget.provisioningContributions[0].targetInterfaceFingerprint =
      repeat('f', 64)
    check ifp(otherTarget) != ifp(before)
    var develop = before
    develop.provisioningContributions[0].developInterface = true
    check ifp(develop) != ifp(before)
    var otherPackage = before
    otherPackage.provisioningContributions[0].targetPackage = "impOther"
    check ifp(otherPackage) != ifp(before)
    # Two imports of one coordinate are not one.
    var doubled = before
    doubled.provisioningContributions.add(before.provisioningContributions[0])
    check ifp(doubled) != ifp(before)
    # Import order is not observable.
    let reversed = consumer(@[base[1], base[0]])
    check ifp(reversed) == ifp(before)
    check importedProvisioningMetadataDigest(reversed) ==
      importedProvisioningMetadataDigest(before)

  test "own records -- a catalog project's -- still enter the fingerprint in full, exactly as v17":
    let own = consumer(base, mark = false)
    check own.provisioningContributions.allIt(not it.imported)
    check ifp(own) == v17Fingerprint(own)
    check importedProvisioningMetadataDigest(own) == ""
    let ownChanged = consumer(@[def(A, "nixpkgs#imp-a", NarA2),
      def(B, "nixpkgs#imp-b", NarB)], mark = false)
    check ifp(ownChanged) != ifp(own)
    # An artifact with no record at all is unchanged too.
    let bare = consumer(@[])
    check ifp(bare) == v17Fingerprint(bare)
    # Marking changes the consumer's identity (it is a different projection),
    # and an own record is never confused with an imported coordinate.
    let marked = consumer(base)
    check ifp(marked) != ifp(own)
    var mixed = own
    mixed.provisioningContributions[0].imported = true
    check ifp(mixed) != ifp(own)
    check ifp(mixed) != ifp(marked)

  test "the ownership flag round-trips through the artifact codec and is not part of the record digest":
    let pi = consumer(@[def(A, "nixpkgs#imp-a", NarA),
      def(B, "nixpkgs#imp-b", NarB, file = ownCatalogFile)])
    let artifact = artifactFor(pi)
    let path = root / "consumer.rbsz"
    writeInterfaceArtifact(path, artifact)
    let decoded = readInterfaceArtifact(path)
    check decoded.projectInterface.provisioningContributions.mapIt(
      it.imported) == @[true, false]
    check decoded.interfaceFingerprint == artifact.interfaceFingerprint
    check interfaceFingerprint(decoded.projectInterface) ==
      artifact.interfaceFingerprint
    var ownCopy = pi.provisioningContributions[0]
    ownCopy.imported = false
    check interfaceContributionRecordDigest(ownCopy) ==
      interfaceContributionRecordDigest(pi.provisioningContributions[0])
    # A corrupted flag byte is refused rather than read as either value.
    # The record opens with its target fingerprint and contributor, each
    # length-prefixed; the flag follows the developInterface byte.
    proc framed(value: string): string =
      let n = value.len
      char(n and 0xff) & char((n shr 8) and 0xff) & char((n shr 16) and 0xff) &
        char((n shr 24) and 0xff) & value
    var bytes = readFile(path)
    # The OWN record's flag is corrupted: read as 0 it would reproduce the
    # stored fingerprint exactly, so only the flag check can refuse it.
    let needle = framed(pi.provisioningContributions[1].
      targetInterfaceFingerprint) & framed(B) & "\x00"
    let marker = bytes.find(needle)
    check marker > 0
    check bytes.find(needle, marker + 1) < 0
    let flagAt = marker + needle.len
    check bytes[flagAt] == '\x00'
    bytes[flagAt] = '\x02'
    writeFile(path, bytes)
    try:
      discard readInterfaceArtifact(path)
      check false
    except CatchableError as err:
      check "ownership flag" in err.msg

  removeDir(root)

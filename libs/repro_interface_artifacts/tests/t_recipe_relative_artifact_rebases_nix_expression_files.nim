## A recipe-relative interface artifact names its nix `expressionFile`s
## relative to the recipe, and a rebased read resolves them at the
## CONSULTING copy.
##
## Hermetic-Builds-And-Path-Independence.md §"Engine-internal recipe
## compiles": the interface-extraction record is served to every copy of a
## recipe, so "what the compile writes is relocatable". The DSL absolutises a
## `nixPackage ..., expressionFile` against the declaring file at macro time
## (`parseNixPackageProvisioning`), and the codec relocated
## `SourceLocation`s only: a copy was served the producing copy's `.nix`
## paths (reprobuild-pm issue 2026-11-11, "a relocated interface artifact
## carries the producing checkout's nix expression paths").
##
## The fingerprint half: an `expressionFile` reaches the interface
## fingerprint (a `SourceLocation` does not), so the digest stored with the
## relative bytes must be the relative form's, the rebased read must carry the
## rebased interface's, and the caller's re-encoded copy must verify on a
## plain read.
##
## The end-to-end half (two real copies sharing an action cache) is
## `tests/integration/t_interface_extraction_copy_names_its_own_nix_expression_files`.
##
## No mocks: plain values written to and read from real temporary files.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts

proc artifactAt(recipeDir: string): ProjectInterfaceArtifact =
  let recipe = recipeDir / "repro.nim"
  var iface = ProjectInterface(projectName: "probe", packageName: "probe",
    location: SourceLocation(file: recipe, line: 3))
  var contribution = InterfaceProvisioningContribution(
    targetPackage: "sh", contributor: "probe-contribution",
    developInterface: true, location: SourceLocation(file: recipe, line: 20))
  contribution.nixProvisioning.add InterfaceNixProvisioning(
    packageName: "sh", contributor: "probe-contribution",
    selector: "probeSh", executablePath: "bin/sh",
    expressionFile: recipeDir / "ci" / "probe.nix",
    packageId: "probeSh", lockIdentity: "probe-identity",
    location: SourceLocation(file: recipe, line: 22))
  iface.provisioningContributions.add(contribution)
  artifactFor(iface)

proc expressionFileOf(artifact: ProjectInterfaceArtifact): string =
  artifact.projectInterface.provisioningContributions[0].nixProvisioning[0].
    expressionFile

suite "a recipe-relative interface artifact relocates nix expression files":

  test "a copy reads its own expression file, with a verifiable fingerprint":
    let root = createTempDir("repro-iface-nix-reloc-", "")
    defer: removeDir(root)
    let copyA = root / "a" / "project"
    let copyB = root / "b" / "project"
    let edgeArtifact = root / "edge" / "project-interface.rbsz"
    let produced = artifactAt(copyA)
    # Positive control: the value the DSL hands the codec is absolute.
    require produced.expressionFileOf == copyA / "ci" / "probe.nix"

    writeInterfaceArtifactRecipeRelative(edgeArtifact, produced, copyA, [])
    let bytes = readFile(edgeArtifact)
    check copyA notin bytes
    check "ci/probe.nix" in bytes
    # The relative bytes verify on their own (the stored digest is the
    # relative form's).
    check readInterfaceArtifact(edgeArtifact).expressionFileOf ==
      "ci/probe.nix"

    let atB = readInterfaceArtifactRebased(edgeArtifact, copyB)
    check atB.expressionFileOf == copyB / "ci" / "probe.nix"
    check atB.projectInterface.provisioningContributions[0].location.file ==
      copyB / "repro.nim"
    # The rebased artifact is the one an extraction AT B computes,
    # fingerprint included.
    check atB.interfaceFingerprint ==
      artifactFor(atB.projectInterface).interfaceFingerprint
    check atB.interfaceFingerprint == artifactAt(copyB).interfaceFingerprint
    # The caller publishes a plain re-encoding; a plain read verifies it.
    let published = root / "b-out" / "project-interface.rbsz"
    writeInterfaceArtifact(published, atB)
    check readInterfaceArtifact(published).expressionFileOf ==
      copyB / "ci" / "probe.nix"
    # The stub is generated from the rebased artifact.
    let stub = nimInterfaceStubText(atB)
    check (copyB / "ci" / "probe.nix") in stub
    check copyA notin stub

  test "an expression file under an anchor stays absolute":
    let root = createTempDir("repro-iface-nix-anchor-", "")
    defer: removeDir(root)
    let anchor = root / "anchor"
    let copyA = root / "a" / "project"
    var produced = artifactAt(copyA)
    produced.projectInterface.provisioningContributions[0].nixProvisioning[0].
      expressionFile = anchor / "pinned.nix"
    produced = artifactFor(produced.projectInterface)
    let edgeArtifact = root / "edge" / "project-interface.rbsz"
    writeInterfaceArtifactRecipeRelative(edgeArtifact, produced, copyA,
      [anchor])
    let atB = readInterfaceArtifactRebased(edgeArtifact, root / "b" / "project")
    check atB.expressionFileOf == anchor / "pinned.nix"
    check atB.interfaceFingerprint ==
      artifactFor(atB.projectInterface).interfaceFingerprint

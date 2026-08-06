import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_tool_profiles

package contributedTool:
  executable contributedTool:
    name "contributed-tool"
    cli:
      subcmd "check":
        flag verbose, bool

provisioningFor "contributedTool":
  developInterface
  contributor "github:metacraft-labs/reprobuild-nix-packages"
  nixPackage "nixpkgs#hello", executablePath = "bin/hello",
    packageId = "hello@2.12.2"

package contributionConsumer:
  defaultToolProvisioning "nix"
  uses:
    "contributedTool"

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

suite "federated provisioning contributions":
  test "contribution binds to canonical interface and survives codec + stub":
    let packages = registeredPackages()
    let target = findPackage("contributedTool")
    let canonical = canonicalPackageInterfaceFingerprint(target, packages)
    let artifact = artifactFromRegisteredDsl(currentSourcePath())

    check artifact.projectInterface.provisioningContributions.len == 1
    let contribution = artifact.projectInterface.provisioningContributions[0]
    check contribution.targetPackage == "contributedTool"
    check contribution.targetInterfaceFingerprint == canonical
    check contribution.contributor ==
      "github:metacraft-labs/reprobuild-nix-packages"
    check contribution.nixProvisioning.len == 1
    check contribution.nixProvisioning[0].contributor == contribution.contributor

    let consumerUse = artifact.projectInterface.toolUses.filterIt(
      it.packageSelector == "contributedTool")[0]
    check consumerUse.nixProvisioning.len == 1
    check consumerUse.nixProvisioning[0].selector == "nixpkgs#hello"

    let roundTrip = decodeProjectInterfaceArtifact(
      encodeProjectInterfaceArtifact(artifact))
    check roundTrip.interfaceFingerprint == artifact.interfaceFingerprint
    check roundTrip.projectInterface.provisioningContributions[0].contributor ==
      contribution.contributor

    let tempRoot = createTempDir("repro-provisioning-contribution", "",
      getCurrentDir())
    defer: removeDir(tempRoot)
    let stub = tempRoot / "catalog_interface.nim"
    writeNimInterfaceStub(stub, artifact)
    let stubSource = readFile(stub)
    check stubSource.contains("registerProvisioningContributionDef")
    check stubSource.contains(contribution.contributor)
    check stubSource.contains(canonical)

    let compileProbe = tempRoot / "compile_probe.nim"
    writeFile(compileProbe,
      "import repro_project_dsl\n" &
      "import catalog_interface\n" &
      "doAssert registeredProvisioningContributions().len == 1\n")
    let (output, exitCode) = execCmdEx(
      "nim c --hints:off --warnings:off --path:" &
        quoteShell(getCurrentDir() / "libs" / "repro_project_dsl" / "src") &
        " --out:" & quoteShell(tempRoot / "compile_probe") & " " &
        quoteShell(compileProbe))
    if exitCode != 0:
      checkpoint output
    check exitCode == 0

  test "realization metadata does not change target interface fingerprint":
    let packages = registeredPackages()
    let target = findPackage("contributedTool")
    let before = canonicalPackageInterfaceFingerprint(target, packages)
    var changed = target
    changed.nixProvisioning.add(NixPackageProvisioningDef(
      selector: "nixpkgs#different",
      executablePath: "bin/different"))
    let after = canonicalPackageInterfaceFingerprint(changed, packages)
    check after == before

  test "contribution metadata changes catalog interface fingerprint":
    let artifact = artifactFromRegisteredDsl(currentSourcePath())
    var changed = artifact.projectInterface
    changed.provisioningContributions[0].nixProvisioning[0].selector =
      "nixpkgs#hello-unfree"
    check interfaceFingerprint(changed) != artifact.interfaceFingerprint

  test "mismatched interface fingerprint is rejected":
    let packages = registeredPackages()
    let consumer = findPackage("contributionConsumer")
    let bad = ProvisioningContributionDef(
      targetPackage: "contributedTool",
      targetInterfaceFingerprint: repeat('0', 64),
      contributor: "github:example/bad-catalog",
      nixProvisioning: @[NixPackageProvisioningDef(
        selector: "nixpkgs#hello", executablePath: "bin/hello")])
    expect ValueError:
      discard toProjectInterface(consumer, packages, @[bad])

  test "interface fingerprint selects among duplicate package names":
    let packages = registeredPackages()
    let consumer = findPackage("contributionConsumer")
    let first = findPackage("contributedTool")
    var alternative = first
    alternative.executables = @[
      ExecutableDef(exportName: "alternative", binaryName: "alternative")]
    let candidates = packages & @[alternative]
    let wanted = canonicalPackageInterfaceFingerprint(alternative, candidates)
    let pinned = ProvisioningContributionDef(
      targetPackage: "contributedTool",
      targetInterfaceFingerprint: wanted,
      contributor: "github:example/pinned-catalog",
      nixProvisioning: @[NixPackageProvisioningDef(
        selector: "nixpkgs#hello", executablePath: "bin/hello")])
    let projected = toProjectInterface(consumer, candidates, @[pinned])
    check projected.provisioningContributions[0].targetInterfaceFingerprint ==
      wanted

    var developing = pinned
    developing.targetInterfaceFingerprint = ""
    developing.developInterface = true
    expect ValueError:
      discard toProjectInterface(consumer, candidates, @[developing])

  test "ambiguous contributors require an explicit selection":
    let old = getEnv("REPRO_PROVISIONING_CONTRIBUTOR")
    defer:
      if old.len > 0: putEnv("REPRO_PROVISIONING_CONTRIBUTOR", old)
      else: delEnv("REPRO_PROVISIONING_CONTRIBUTOR")
    delEnv("REPRO_PROVISIONING_CONTRIBUTOR")
    let useDef = InterfaceToolUse(
      rawConstraint: "tool",
      packageSelector: "tool",
      executableName: "tool",
      nixProvisioning: @[
        InterfaceNixProvisioning(packageName: "tool", contributor: "one",
          selector: "nixpkgs#hello", executablePath: "bin/hello"),
        InterfaceNixProvisioning(packageName: "tool", contributor: "two",
          selector: "nixpkgs#hello", executablePath: "bin/hello")])
    expect ValueError:
      discard nixAcquisitionPlan(useDef)
    putEnv("REPRO_PROVISIONING_CONTRIBUTOR", "two")
    check nixAcquisitionPlan(useDef).nixSelector == "nixpkgs#hello"

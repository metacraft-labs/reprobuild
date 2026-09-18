## ``nonRedistributable`` on a tarball provisioning entry: realize it, never
## publish it.
##
## The case that forces the flag is one a policy document cannot cover,
## because the thing it has to stop is an accident. An upstream archive a
## developer is licensed to download and run, but not to redistribute, is
## ordinary — Agent Harbor's electron-builder MSI target consumes
## ``winCodeSign-2.6.0``, which bundles Microsoft's ``signtool``, and the
## coding-agent catalog has several vendor payloads in the same position.
## Before this flag, realizing one on a machine that happened to have publish
## credentials configured uploaded it to a cache other people pull from, and
## nothing in the recipe could say otherwise.
##
## What is asserted here is the part that decides whether the flag is worth
## having: that it reaches the two places a realize can be driven from.
##
##   * the interface artifact, because a contributed provisioning reaches a
##     consuming compilation only through that artifact and the stub emitted
##     from it — and a field missing from either does not fail to compile, it
##     reconstructs a provisioning that says "publish me";
##   * the store-daemon frame, because a realize routed through the daemon
##     rebuilds the provisioning from that message alone.
##
## It is deliberately NOT part of the prefix identity: the realized bytes are
## the same either way, so two hosts that disagree about the flag must still
## be able to share an entry one of them was entitled to publish. That is
## visible as the absence of an ``addOption`` call in ``toolCacheIdentity``
## rather than asserted here, because the proc is private to the realizer.

import std/[strutils, unittest]

import repro_interface_artifacts
import repro_store_daemon/protocol as daemonProtocol

proc entry(nonRedistributable: bool): InterfaceTarballProvisioning =
  InterfaceTarballProvisioning(
    packageName: "win-code-sign",
    url: "https://example.invalid/winCodeSign-2.6.0.7z",
    sha256: repeat("ab", 32),
    archiveType: "7z",
    executablePath: "windows-10/x64/signtool.exe",
    packageId: "win-code-sign@2.6.0",
    lockIdentity: "tarball:win-code-sign@2.6.0",
    nonRedistributable: nonRedistributable,
    cpu: "x86_64",
    os: "windows")

proc artifactCarrying(declared: bool): ProjectInterfaceArtifact =
  ## Through a CONTRIBUTION, which is the path that matters: a realization
  ## published by another repository is exactly the case where the consumer
  ## has nothing but the artifact to go on.
  result.projectInterface.provisioningContributions = @[
    InterfaceProvisioningContribution(
      targetPackage: "win-code-sign",
      targetInterfaceFingerprint: repeat("0", 64),
      contributor: "github:example/catalog",
      tarballProvisioning: @[entry(declared)])]
  # Decode verifies the envelope's fingerprint against the payload, so a
  # hand-built artifact has to carry the real one or the round trip fails
  # before it can say anything about the field under test.
  result.interfaceFingerprint = interfaceFingerprint(result.projectInterface)

suite "a package can refuse to be republished":
  test "the flag survives the artifact round trip, in both states":
    for declared in [false, true]:
      let restored = decodeProjectInterfaceArtifact(
        encodeProjectInterfaceArtifact(artifactCarrying(declared)))
      check restored.projectInterface.provisioningContributions.len == 1
      let contributed =
        restored.projectInterface.provisioningContributions[0]
      check contributed.tarballProvisioning.len == 1
      check contributed.tarballProvisioning[0].nonRedistributable == declared

  test "the fields around it still land where they belong":
    # The encoding is positional, so a width mistake on the new field does
    # not corrupt the field itself — it corrupts the next one. Reading the
    # neighbours back is what catches that.
    let restored = decodeProjectInterfaceArtifact(
      encodeProjectInterfaceArtifact(artifactCarrying(true)))
    let slice =
      restored.projectInterface.provisioningContributions[0]
        .tarballProvisioning[0]
    check slice.archiveType == "7z"
    check slice.executablePath == "windows-10/x64/signtool.exe"
    check slice.packageId == "win-code-sign@2.6.0"
    check slice.cpu == "x86_64"
    check slice.os == "windows"

  test "declaring it changes the interface fingerprint":
    # Two catalogs whose entries differ only in this flag are making
    # different promises about what a realize may do with the payload, so a
    # consumer pinned to one must not silently accept the other.
    check interfaceFingerprint(artifactCarrying(false).projectInterface) !=
      interfaceFingerprint(artifactCarrying(true).projectInterface)

  test "the daemon frame carries it in both states":
    for declared in [false, true]:
      let request = StoreDaemonExternalRealizeRequest(
        storeRoot: "C:/store",
        tarballUrl: "https://example.invalid/x.7z",
        tarballSha256: repeat("cd", 32),
        archiveType: "7z",
        declaredExecutablePath: "signtool.exe",
        nonRedistributable: declared,
        stripComponents: 1)
      let restored = parseExternalRealizeBody(externalRealizeBody(request))
      check restored.nonRedistributable == declared
      # Same positional argument as above: the field AFTER the new one is
      # what a width mistake destroys, and it is the one the protocol bump
      # exists to protect across versions.
      check restored.stripComponents == 1
      check restored.archiveType == "7z"
      check restored.declaredExecutablePath == "signtool.exe"

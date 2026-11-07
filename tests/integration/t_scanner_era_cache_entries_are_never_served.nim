{.define: reproDaemonParentPrewarmTest.}
# For ``warmToolIdentityCountForTest`` (the warm table is module-private).

## Nothing keyed under the dropped scanners' key versions is ever served.
##
## The ReproOS campaign line (reprobuild ``reproos``, 2026-10-01 to
## 2026-10-07) wrote tool-identity cache entries under key v6 and Nix
## materialization entries under key v2. Both keys bound a Nix
## ``expressionFile`` by the closure the expression-closure scanner
## PREDICTED, a scanner the owner dropped on 2026-10-14 (reprobuild landing
## of the campaign; Edge-Derived-Identities.md §7 rider). An entry written
## under those keys may hold an identity or a realization the scanner
## mis-keyed, so it must never be served again: no key derivation may
## produce a scanner-era key, and a scanner-era entry left on disk -- in
## the keyed cache directory, behind a ``current-key`` stamp, or prewarmed
## into a daemon's tables -- must not be read back.
##
## The scanner-era keys are re-derived HERE from their documented layouts
## (``reproos`` ``a67bc666``: ``toolIdentityCacheKeyInfo`` v6 and
## ``nixMaterializationCacheKey`` v2), independently of the code under
## test, for inputs without an ``expressionFile`` -- the only inputs whose
## scanner-era key does not depend on the deleted scanner itself. An entry
## for an input WITH one cannot be reached at all now: its key is a nonce
## (``t_nix_expression_closure_keys``).

import std/[os, strutils, tempfiles, unittest]

import blake3
import repro_cli_support
import repro_core
import repro_hash
import repro_interface_artifacts
import repro_tool_profiles

proc field(payload: var string; value: string) =
  ## ``repro_cli_support.addCacheField``'s framing.
  payload.add($value.len & ":" & value & "\n")

proc payloadBytes(text: string): seq[byte] =
  for ch in text:
    result.add(byte(ord(ch)))

proc scannerEraToolIdentityKey(artifact: ProjectInterfaceArtifact;
                               modeName: string): string =
  ## Tool-identity key v6 (``reproos`` ``a67bc666``) for an artifact with no
  ## tool uses, no imported contribution, no pins and no cross-repo
  ## producers, in a mode other than path mode: the tag, the mode, the
  ## project, the interface fingerprint, then the (empty) closure section.
  var payload = ""
  payload.field("reprobuild.toolIdentityCache.v6")
  payload.field(modeName)
  payload.field(artifact.projectInterface.projectName)
  payload.field(artifact.projectInterface.packageName)
  payload.field(toHex(artifact.interfaceFingerprint.bytes))
  payload.field("nix-expression-closures.v1")
  payload.field("0")
  toHex(blake3DomainDigest(payloadBytes(payload), hdMetadataEnvelope).bytes)

proc materializationPayload(tag: string; useDef: InterfaceToolUse;
                            plan: NixAcquisitionPlan): string =
  ## The Nix materialization key's layout, v1 and v2 alike, for a plan with
  ## no ``expressionFile`` (both wrote two empty strings for it).
  var payload: seq[byte] = @[]
  payload.writeString(tag)
  payload.writeString(hostOS)
  payload.writeString(hostCPU)
  payload.writeString(useDef.packageSelector)
  payload.writeString(useDef.executableName)
  payload.writeString(plan.packageSelector)
  payload.writeString(plan.packageId)
  payload.writeString(plan.nixSelector)
  payload.writeString(plan.declaredExecutablePath)
  payload.writeString("")
  payload.writeString("")
  payload.writeString(plan.nixpkgsRef)
  payload.writeString(plan.nixpkgsRev)
  payload.writeString(plan.nixpkgsNarHash)
  payload.writeString(plan.lockIdentity)
  let probes = configuredProbes(useDef.packageSelector, useDef.executableName)
  payload.writeU32Le(uint32(probes.len))
  for probe in probes:
    payload.add(byte(ord(probe.kind)))
    payload.writeString(probe.name)
    payload.writeU32Le(uint32(probe.args.len))
    for arg in probe.args:
      payload.writeString(arg)
  var text = newString(payload.len)
  for i, b in payload:
    text[i] = char(b)
  blake3.toHex(blake3.digest(text))

proc emptyArtifact(): ProjectInterfaceArtifact =
  artifactFor(ProjectInterface(projectName: "scannerEraConsumer",
    packageName: "scannerEraConsumer"))

proc plantPoisonedIdentity(outDir, key, modeName: string;
                           artifact: ProjectInterfaceArtifact) =
  ## A scanner-era entry as a campaign-line build left it: the keyed
  ## identity file and the ``current-key`` stamp naming it. The identity is
  ## marked by its project name, so serving it is observable.
  let dir = outDir / "tool-identity-cache"
  createDir(dir)
  writePathOnlyBuildIdentity(dir / (key & ".rbtp"), PathOnlyBuildIdentity(
    projectName: "POISONED-BY-A-SCANNER-ERA-ENTRY",
    interfaceFingerprint: artifact.interfaceFingerprint))
  writeFile(dir / (modeName & ".current-key"), key & "\n")

suite "scanner-era cache entries are never served":

  test "the re-derivation reproduces the scanner-era key's layout":
    # The control that keeps the next cases honest: the helper frames and
    # digests exactly as the key code does, so a key that differs from it
    # differs by version, not by a transcription slip. Same layout, the
    # CURRENT tag, no expression file: the production key must match.
    let artifact = emptyArtifact()
    var payload = ""
    payload.field("reprobuild.toolIdentityCache.v7")
    payload.field("tarball")
    payload.field(artifact.projectInterface.projectName)
    payload.field(artifact.projectInterface.packageName)
    payload.field(toHex(artifact.interfaceFingerprint.bytes))
    check toolIdentityCacheKey(artifact, tpmTarball, pathValue = "") ==
      toHex(blake3DomainDigest(payloadBytes(payload),
        hdMetadataEnvelope).bytes)

  test "no current key is a scanner-era key":
    let artifact = emptyArtifact()
    for (mode, name) in [(tpmNix, "nix"), (tpmTarball, "tarball"),
                         (tpmScoop, "scoop"), (tpmFromSource, "from-source")]:
      checkpoint(name)
      let current = toolIdentityCacheKeyInfo(artifact, mode, pathValue = "")
      check current.cacheable
      check current.key != scannerEraToolIdentityKey(artifact, name)
    let useDef = InterfaceToolUse(rawConstraint: "eraTool",
      packageSelector: "eraTool", executableName: "era-tool",
      nixProvisioning: @[InterfaceNixProvisioning(packageName: "eraTool",
        selector: "nixpkgs#era-tool", executablePath: "bin/era-tool")])
    let plan = NixAcquisitionPlan(packageSelector: "eraTool",
      packageId: "nixpkgs#era-tool", nixSelector: "nixpkgs#era-tool",
      declaredExecutablePath: "bin/era-tool", lockIdentity: "nixpkgs#era-tool")
    let current = nixMaterializationCacheKey(useDef, plan)
    check current.cacheable
    # The control, as for the tool-identity key: the same layout under the
    # CURRENT tag is the production key.
    check current.key == materializationPayload(
      "reprobuild.nix.materialization.v3", useDef, plan)
    check current.key != materializationPayload(
      "reprobuild.nix.materialization.v2", useDef, plan)
    # Nor the pre-scanner v1 key, which bound an expressionFile by the
    # top-level file's bytes alone: versions only move forward.
    check current.key != materializationPayload(
      "reprobuild.nix.materialization.v1", useDef, plan)
    check current.key == nixMaterializationCacheKey(useDef, plan).key

  test "a scanner-era tool identity on disk is not served, cold or prewarmed":
    let outDir = createTempDir("repro-scanner-era-", "")
    defer: removeDir(outDir)
    let artifact = emptyArtifact()
    for (mode, name) in [(tpmNix, "nix"), (tpmTarball, "tarball"),
                         (tpmScoop, "scoop"), (tpmFromSource, "from-source")]:
      checkpoint(name)
      let eraKey = scannerEraToolIdentityKey(artifact, name)
      plantPoisonedIdentity(outDir, eraKey, name, artifact)
      # Cold: the on-disk cache.
      forgetWarmBuildCaches()
      let r0 = warmBuildCacheCounters.toolIdentityResolves
      let cold = warmResolveAndWriteIdentity(artifact, outDir, mode)
      check cold.identity.projectName != "POISONED-BY-A-SCANNER-ERA-ENTRY"
      check warmBuildCacheCounters.toolIdentityResolves - r0 == 1
      # Prewarmed: a daemon parent decoding the stamp a scanner-era build
      # wrote, then a request.
      plantPoisonedIdentity(outDir, eraKey, name, artifact)
      forgetWarmBuildCaches()
      discard prewarmDaemonParentCaches(outDir)
      let r1 = warmBuildCacheCounters.toolIdentityResolves
      let warm = warmResolveAndWriteIdentity(artifact, outDir, mode)
      check warm.identity.projectName != "POISONED-BY-A-SCANNER-ERA-ENTRY"
      check warmBuildCacheCounters.toolIdentityResolves - r1 == 1
    forgetWarmBuildCaches()

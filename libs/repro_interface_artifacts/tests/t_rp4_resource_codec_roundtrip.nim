## RP4 (Provider-Runtime-Protocol-v1 §5) codec round-trip: encode a v12
## ``ProjectInterfaceArtifact`` carrying a non-empty ``publicResources``
## seq (typeId + determinism + attribute schema + entry-point
## descriptors), decode it back, and assert every field survives
## byte-identically. Also verifies:
##
##   * the interface fingerprint stays stable across encode/decode
##     (``publicResources`` is part of the fingerprinted payload);
##   * a v11 (no-resources) envelope still decodes, with
##     ``publicResources`` defaulting to an empty seq
##     (forward/backward-compat, mirroring the v8->v9 precedent);
##   * every ``InterfaceResourceDeterminism`` ordinal survives;
##   * changing an attribute name / a resource op SHIFTS the fingerprint
##     (the schema is falsifiable).
##
## Mirrors ``test_library_codec_roundtrip.nim``.

import std/[os, unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_core
import repro_hash

proc addU16Le(outp: var seq[byte]; value: uint16) =
  outp.add(byte(value and 0xff'u16))
  outp.add(byte((value shr 8) and 0xff'u16))

proc addU32Le(outp: var seq[byte]; value: uint32) =
  outp.add(byte(value and 0xff'u32))
  outp.add(byte((value shr 8) and 0xff'u32))
  outp.add(byte((value shr 16) and 0xff'u32))
  outp.add(byte((value shr 24) and 0xff'u32))

proc encodeV11ProjectInterfaceArtifact(pi: ProjectInterface): seq[byte] =
  ## A v11 envelope has NO publicResources block — the payload is encoded
  ## at version 11 so the reader must default ``publicResources`` empty. Written
  ## by the CURRENT codec: the on-disk payload keeps real locations, while the
  ## InterfaceFingerprint is over the location-normalized payload
  ## (``forFingerprint = true``), matching ``decodeProjectInterfaceArtifact``'s
  ## recompute. (No pre-release artifacts to keep compatible, so this checks
  ## version-gated FIELD decoding, not a legacy fingerprint shape.)
  var payload = encodeInterfacePayload(pi, 11'u16)
  let fingerprint = blake3DomainDigest(
    encodeInterfacePayload(pi, 11'u16, forFingerprint = true), hdMetadataEnvelope)
  payload.add(byte(ord(fingerprint.algorithm)))
  payload.add(byte(ord(fingerprint.domain)))
  payload.add(fingerprint.bytes)
  payload.add(if pi.standardBuildEligible: 1'u8 else: 0'u8)
  result.add([byte(ord('R')), byte(ord('B')), byte(ord('S')), byte(ord('Z'))])
  result.addU16Le(11'u16)
  result.addU16Le(101'u16)
  result.addU32Le(uint32(payload.len))
  result.add(payload)

proc encodePreTi3V12ProjectInterfaceArtifact(pi: ProjectInterface): seq[byte] =
  ## TI3 kept the v12 envelope but changed its fingerprint from the exact wire
  ## payload digest to a location-normalized semantic digest. Reproduce a v12
  ## artifact written before that change so compatibility remains testable.
  var payload = encodeInterfacePayload(pi, 12'u16)
  let fingerprint = blake3DomainDigest(payload, hdMetadataEnvelope)
  payload.add(byte(ord(fingerprint.algorithm)))
  payload.add(byte(ord(fingerprint.domain)))
  payload.add(fingerprint.bytes)
  payload.add(if pi.standardBuildEligible: 1'u8 else: 0'u8)
  result.add([byte(ord('R')), byte(ord('B')), byte(ord('S')), byte(ord('Z'))])
  result.addU16Le(12'u16)
  result.addU16Le(101'u16)
  result.addU32Le(uint32(payload.len))
  result.add(payload)

proc sampleResource(): InterfaceResource =
  InterfaceResource(
    typeId: "vm_harness.container",
    determinism: irdVolatile,
    attributes: @[
      InterfaceResourceAttr(name: "image", nimType: "string",
        location: SourceLocation(file: "reprobuild.nim", line: 5)),
      InterfaceResourceAttr(name: "cpus", nimType: "int",
        location: SourceLocation(file: "reprobuild.nim", line: 6))],
    entrypoints: InterfaceResourceEntrypoints(
      identity: "vm_harness.container.identity",
      digest: "vm_harness.container.digest",
      observe: "vm_harness.container.observe",
      plan: "vm_harness.container.plan",
      apply: "vm_harness.container.apply"),
    location: SourceLocation(file: "reprobuild.nim", line: 4))

suite "interface-artifact codec RP4 (v12) publicResources":

  test "publicResources round-trips through encode/decode":
    var pi: ProjectInterface
    pi.projectName = "rp4RoundTrip"
    pi.packageName = "rp4RoundTrip"
    pi.standardBuildEligible = true
    pi.publicResources.add(sampleResource())
    pi.publicResources.add(InterfaceResource(
      typeId: "vm_harness.exec",
      determinism: irdHostBound,
      attributes: @[
        InterfaceResourceAttr(name: "cmd", nimType: "seq[string]",
          location: SourceLocation(file: "reprobuild.nim", line: 20))],
      entrypoints: InterfaceResourceEntrypoints(
        identity: "vm_harness.exec.identity",
        digest: "vm_harness.exec.digest",
        observe: "vm_harness.exec.observe",
        plan: "vm_harness.exec.plan",
        apply: "vm_harness.exec.apply"),
      location: SourceLocation(file: "reprobuild.nim", line: 18)))
    let artifact = artifactFor(pi)

    let encoded = encodeProjectInterfaceArtifact(artifact)
    let decoded = decodeProjectInterfaceArtifact(encoded)

    check decoded.projectInterface.projectName == "rp4RoundTrip"
    check decoded.projectInterface.standardBuildEligible
    check decoded.projectInterface.publicResources.len == 2

    let r0 = decoded.projectInterface.publicResources[0]
    check r0.typeId == "vm_harness.container"
    check r0.determinism == irdVolatile
    check r0.attributes.len == 2
    check r0.attributes[0].name == "image"
    check r0.attributes[0].nimType == "string"
    check r0.attributes[0].location.line == 5
    check r0.attributes[1].name == "cpus"
    check r0.attributes[1].nimType == "int"
    check r0.entrypoints.identity == "vm_harness.container.identity"
    check r0.entrypoints.digest == "vm_harness.container.digest"
    check r0.entrypoints.observe == "vm_harness.container.observe"
    check r0.entrypoints.plan == "vm_harness.container.plan"
    check r0.entrypoints.apply == "vm_harness.container.apply"
    check r0.location.line == 4

    let r1 = decoded.projectInterface.publicResources[1]
    check r1.typeId == "vm_harness.exec"
    check r1.determinism == irdHostBound
    check r1.attributes[0].nimType == "seq[string]"

    check decoded.interfaceFingerprint == artifact.interfaceFingerprint

  test "round-trip via on-disk file":
    var pi: ProjectInterface
    pi.projectName = "rp4File"
    pi.packageName = "rp4File"
    pi.publicResources.add(sampleResource())
    let artifact = artifactFor(pi)
    let scratch = getTempDir() / "t_rp4_resource_codec_roundtrip.rbsz"
    if fileExists(scratch):
      removeFile(scratch)
    writeInterfaceArtifact(scratch, artifact)
    let readBack = readInterfaceArtifact(scratch)
    check readBack.projectInterface.publicResources.len == 1
    check readBack.projectInterface.publicResources[0].typeId ==
      "vm_harness.container"
    check readBack.interfaceFingerprint == artifact.interfaceFingerprint
    removeFile(scratch)

  test "v11 (no-resources) envelope decodes with an empty publicResources":
    var pi: ProjectInterface
    pi.projectName = "rp4LegacyV11"
    pi.packageName = "rp4LegacyV11"
    pi.publicLibraries.add(InterfaceLibrary(
      name: "core", kind: lkStatic,
      location: SourceLocation(file: "rb.nim", line: 3)))
    let decoded = decodeProjectInterfaceArtifact(
      encodeV11ProjectInterfaceArtifact(pi))
    check decoded.projectInterface.publicResources.len == 0
    # The pre-existing v11 fields still decode.
    check decoded.projectInterface.publicLibraries.len == 1
    check decoded.projectInterface.publicLibraries[0].name == "core"

  test "pre-TI3 v12 wire fingerprint remains decodable and tamper-safe":
    var pi: ProjectInterface
    pi.projectName = "rp4LegacyV12"
    pi.packageName = "rp4LegacyV12"
    pi.publicResources.add(sampleResource())
    let encoded = encodePreTi3V12ProjectInterfaceArtifact(pi)
    let decoded = decodeProjectInterfaceArtifact(encoded)
    check decoded.projectInterface.publicResources.len == 1
    check decoded.projectInterface.publicResources[0].location.line == 4

    var corrupted = encoded
    corrupted[^2] = corrupted[^2] xor 0xff'u8
    expect EnvelopeError:
      discard decodeProjectInterfaceArtifact(corrupted)

  test "empty publicResources round-trips":
    var pi: ProjectInterface
    pi.projectName = "emptyRes"
    pi.packageName = "emptyRes"
    let encoded = encodeProjectInterfaceArtifact(artifactFor(pi))
    let decoded = decodeProjectInterfaceArtifact(encoded)
    check decoded.projectInterface.publicResources.len == 0

  test "every InterfaceResourceDeterminism ordinal survives round-trip":
    for det in InterfaceResourceDeterminism:
      var pi: ProjectInterface
      pi.projectName = "detRoundTrip"
      pi.packageName = "detRoundTrip"
      pi.publicResources.add(InterfaceResource(
        typeId: "r", determinism: det,
        location: SourceLocation(file: "rb.nim", line: 1)))
      let encoded = encodeProjectInterfaceArtifact(artifactFor(pi))
      let decoded = decodeProjectInterfaceArtifact(encoded)
      check decoded.projectInterface.publicResources[0].determinism == det

  test "fingerprint changes when publicResources changes":
    var piA: ProjectInterface
    piA.projectName = "fpRes"
    piA.packageName = "fpRes"
    var piB: ProjectInterface
    piB.projectName = "fpRes"
    piB.packageName = "fpRes"
    piB.publicResources.add(sampleResource())
    check artifactFor(piA).interfaceFingerprint !=
      artifactFor(piB).interfaceFingerprint

  test "renaming an attribute SHIFTS the fingerprint (falsifiable schema)":
    var piA: ProjectInterface
    piA.projectName = "fpAttr"
    piA.packageName = "fpAttr"
    piA.publicResources.add(sampleResource())

    var piB: ProjectInterface
    piB.projectName = "fpAttr"
    piB.packageName = "fpAttr"
    var renamed = sampleResource()
    renamed.attributes[0].name = "imageRENAMED"
    piB.publicResources.add(renamed)

    check artifactFor(piA).interfaceFingerprint !=
      artifactFor(piB).interfaceFingerprint

  test "renaming a resource op (apply) SHIFTS the fingerprint":
    var piA: ProjectInterface
    piA.projectName = "fpOp"
    piA.packageName = "fpOp"
    piA.publicResources.add(sampleResource())

    var piB: ProjectInterface
    piB.projectName = "fpOp"
    piB.packageName = "fpOp"
    var reop = sampleResource()
    reop.entrypoints.apply = "vm_harness.container.applyRENAMED"
    piB.publicResources.add(reop)

    check artifactFor(piA).interfaceFingerprint !=
      artifactFor(piB).interfaceFingerprint

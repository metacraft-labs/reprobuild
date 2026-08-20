import std/unittest

import repro_hash
import repro_interface_artifacts
import repro_project_dsl

proc addU16Le(outp: var seq[byte]; value: uint16) =
  outp.add(byte(value and 0xff'u16))
  outp.add(byte((value shr 8) and 0xff'u16))

proc addU32Le(outp: var seq[byte]; value: uint32) =
  outp.add(byte(value and 0xff'u32))
  outp.add(byte((value shr 8) and 0xff'u32))
  outp.add(byte((value shr 16) and 0xff'u32))
  outp.add(byte((value shr 24) and 0xff'u32))

proc encodeV13ProjectInterfaceArtifact(
    projectInterface: ProjectInterface): seq[byte] =
  var payload = encodeInterfacePayload(projectInterface, 13'u16)
  let fingerprint = blake3DomainDigest(
    encodeInterfacePayload(projectInterface, 13'u16, forFingerprint = true),
    hdMetadataEnvelope)
  payload.add(byte(ord(fingerprint.algorithm)))
  payload.add(byte(ord(fingerprint.domain)))
  payload.add(fingerprint.bytes)
  payload.add(if projectInterface.standardBuildEligible: 1'u8 else: 0'u8)
  result.add([byte(ord('R')), byte(ord('B')), byte(ord('S')), byte(ord('Z'))])
  result.addU16Le(13'u16)
  result.addU16Le(101'u16)
  result.addU32Le(uint32(payload.len))
  result.add(payload)

suite "runtime tool uses interface codec":
  test "runtime closure survives the project interface round trip":
    let runtimeUse = InterfaceToolUse(
      rawConstraint: "hypervisor >=1",
      packageSelector: "hypervisor",
      executableName: "virsh")
    let projectInterface = ProjectInterface(
      projectName: "producer",
      packageName: "producer",
      toolUses: @[runtimeUse],
      runtimeToolUses: @[runtimeUse])
    let artifact = ProjectInterfaceArtifact(
      projectInterface: projectInterface,
      interfaceFingerprint: blake3DomainDigest(
        encodeInterfacePayload(projectInterface, forFingerprint = true),
        hdMetadataEnvelope))

    let decoded = decodeProjectInterfaceArtifact(
      encodeProjectInterfaceArtifact(artifact))

    check decoded.projectInterface.runtimeToolUses.len == 1
    check decoded.projectInterface.runtimeToolUses[0].packageSelector ==
      "hypervisor"
    check decoded.projectInterface.runtimeToolUses[0].executableName == "virsh"

  test "package runtime dependencies project into the runtime closure":
    let projectInterface = toProjectInterface(PackageDef(
      packageName: "producer",
      runtimeDeps: @[PackageUseDef(
        rawConstraint: "hypervisor >=1",
        packageSelector: "hypervisor",
        executableName: "virsh")]))

    check projectInterface.runtimeToolUses.len == 1
    check projectInterface.runtimeToolUses[0].rawConstraint == "hypervisor >=1"
    check projectInterface.runtimeToolUses[0].packageSelector == "hypervisor"
    check projectInterface.runtimeToolUses[0].executableName == "virsh"

  test "v13 interfaces decode with an empty runtime closure":
    let projectInterface = ProjectInterface(
      projectName: "legacy-producer",
      packageName: "legacy-producer",
      toolUses: @[InterfaceToolUse(
        rawConstraint: "nim >=2",
        packageSelector: "nim",
        executableName: "nim")])

    let decoded = decodeProjectInterfaceArtifact(
      encodeV13ProjectInterfaceArtifact(projectInterface))

    check decoded.projectInterface.toolUses.len == 1
    check decoded.projectInterface.runtimeToolUses.len == 0

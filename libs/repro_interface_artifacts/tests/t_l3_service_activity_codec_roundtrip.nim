## Shared-Development-Services L3 codec round-trip: encode a v21
## ``ProjectInterfaceArtifact`` carrying non-empty ``publicServices`` and
## ``publicActivities`` seqs, decode them back, and assert every field
## survives byte-identically. Also verifies:
##
##   * the interface fingerprint stays stable across encode/decode (both
##     seqs are part of the fingerprinted payload);
##   * a v20 (no-services, no-activities) envelope still decodes, with
##     both seqs defaulting to empty, and with the pre-existing v20
##     fields intact (forward/backward-compat, mirroring the v11->v12
##     ``publicResources`` precedent);
##   * every field of every row is falsifiable: renaming a service, a
##     ``config:`` key, a parameter type, or flipping ``hasDefault``,
##     each SHIFTS the fingerprint;
##   * a SourceLocation at any of the three depths the new rows carry
##     does NOT shift it (TI3 — the ``forFingerprint`` flag is threaded
##     all the way down);
##   * a corrupted envelope still fails closed.
##
## Mirrors ``t_rp4_resource_codec_roundtrip.nim``, which mirrors
## ``test_library_codec_roundtrip.nim``.
##
## MOCK POLICY — NO MOCKS. The values are hand-built ``ProjectInterface``
## records (the unit under test is the codec, not the DSL) and every
## digest is the real ``interfaceFingerprint``.
##
## WHICH DISCRIMINATOR IS LOAD-BEARING. Every test here names
## ``publicServices`` / ``publicActivities`` / ``InterfaceActivity`` /
## ``InterfaceConfigKey``, none of which exist at the base commit, so the
## whole file fails to COMPILE there. That is the before-direction, and
## it is the only one available for a field that did not exist; the
## assertions themselves are what keep the after-direction from being
## satisfied by a codec that writes the rows and reads back zeros.

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

proc encodeV20ProjectInterfaceArtifact(pi: ProjectInterface): seq[byte] =
  ## A v20 envelope has NO publicServices / publicActivities block — the
  ## payload is encoded at version 20 so the reader must default both
  ## empty. Written by the CURRENT codec, exactly as
  ## ``encodeV11ProjectInterfaceArtifact`` does in the RP4 test: the
  ## on-disk payload keeps real locations, while the InterfaceFingerprint
  ## is over the location-normalized payload, matching
  ## ``decodeProjectInterfaceArtifact``'s recompute.
  var payload = encodeInterfacePayload(pi, 20'u16)
  let fingerprint = blake3DomainDigest(
    encodeInterfacePayload(pi, 20'u16, forFingerprint = true),
    hdMetadataEnvelope)
  payload.add(byte(ord(fingerprint.algorithm)))
  payload.add(byte(ord(fingerprint.domain)))
  payload.add(fingerprint.bytes)
  payload.add(if pi.standardBuildEligible: 1'u8 else: 0'u8)
  result.add([byte(ord('R')), byte(ord('B')), byte(ord('S')), byte(ord('Z'))])
  result.addU16Le(20'u16)
  result.addU16Le(101'u16)
  result.addU32Le(uint32(payload.len))
  result.add(payload)

proc sampleActivity(): InterfaceActivity =
  InterfaceActivity(
    name: "sso",
    handleType: "InfraPackageSsoHandle",
    params: @[
      InterfaceActivityParam(name: "pg", nimType: "ManagedPostgres",
        location: SourceLocation(file: "repro.nim", line: 11)),
      InterfaceActivityParam(name: "edge", nimType: "EdgeHandle",
        location: SourceLocation(file: "repro.nim", line: 11))],
    config: @[
      InterfaceConfigKey(name: "externalDomain", nimType: "string",
        defaultRepr: "", hasDefault: false,
        description: "The externally visible issuer host.",
        location: SourceLocation(file: "repro.nim", line: 15)),
      InterfaceConfigKey(name: "externalSecure", nimType: "bool",
        defaultRepr: "true", hasDefault: true,
        description: "Whether the issuer URL is https.",
        location: SourceLocation(file: "repro.nim", line: 17)),
      InterfaceConfigKey(name: "port", nimType: "int",
        defaultRepr: "8080", hasDefault: true, description: "",
        location: SourceLocation(file: "repro.nim", line: 19))],
    services: @["zitadel", "bootstrap"],
    location: SourceLocation(file: "repro.nim", line: 11))

proc sampleServices(): seq[InterfaceService] =
  @[
    InterfaceService(name: "zitadel", activityName: "sso",
      handleType: "InfraPackageSsoHandle",
      location: SourceLocation(file: "repro.nim", line: 30)),
    InterfaceService(name: "bootstrap", activityName: "sso",
      handleType: "InfraPackageSsoHandle",
      location: SourceLocation(file: "repro.nim", line: 36)),
    InterfaceService(name: "standalone", activityName: "", handleType: "",
      location: SourceLocation(file: "repro.nim", line: 44))]

proc samplePi(): ProjectInterface =
  result.projectName = "infra"
  result.packageName = "infra"
  result.publicServices = sampleServices()
  result.publicActivities = @[sampleActivity()]

suite "interface-artifact codec L3 (v21) publicServices/publicActivities":

  test "publicServices and publicActivities round-trip":
    let pi = samplePi()
    let artifact = artifactFor(pi)
    let encoded = encodeProjectInterfaceArtifact(artifact)
    let decoded = decodeProjectInterfaceArtifact(encoded)
    let got = decoded.projectInterface
    check got.publicServices.len == 3
    check got.publicServices[0].name == "zitadel"
    check got.publicServices[0].activityName == "sso"
    check got.publicServices[0].handleType == "InfraPackageSsoHandle"
    check got.publicServices[0].location.file == "repro.nim"
    check got.publicServices[0].location.line == 30
    check got.publicServices[2].name == "standalone"
    check got.publicServices[2].activityName == ""
    check got.publicServices[2].handleType == ""
    check got.publicActivities.len == 1
    let act = got.publicActivities[0]
    check act.name == "sso"
    check act.handleType == "InfraPackageSsoHandle"
    check act.location.line == 11
    check act.params.len == 2
    check act.params[0].name == "pg"
    check act.params[0].nimType == "ManagedPostgres"
    check act.params[0].location.line == 11
    check act.params[1].nimType == "EdgeHandle"
    check act.config.len == 3
    check act.config[0].name == "externalDomain"
    check act.config[0].nimType == "string"
    check act.config[0].defaultRepr == ""
    check not act.config[0].hasDefault
    check act.config[0].description ==
      "The externally visible issuer host."
    check act.config[0].location.line == 15
    check act.config[1].hasDefault
    check act.config[1].defaultRepr == "true"
    check act.config[2].name == "port"
    check act.config[2].defaultRepr == "8080"
    check act.config[2].description == ""
    check act.services == @["zitadel", "bootstrap"]
    check decoded.interfaceFingerprint == artifact.interfaceFingerprint

  test "round-trip via on-disk file":
    let pi = samplePi()
    let artifact = artifactFor(pi)
    let path = getTempDir() / "t_l3_service_activity_codec_roundtrip.rbsz"
    writeInterfaceArtifact(path, artifact)
    defer:
      try: removeFile(path)
      except CatchableError: discard
    let decoded = readInterfaceArtifact(path)
    check decoded.projectInterface.publicActivities[0].config[2].defaultRepr ==
      "8080"
    check decoded.projectInterface.publicServices.len == 3
    check decoded.interfaceFingerprint == artifact.interfaceFingerprint

  test "a v20 envelope decodes with both seqs empty":
    var pi: ProjectInterface
    pi.projectName = "infra"
    pi.packageName = "infra"
    # A pre-existing v20 field, so the test can tell "decoded empty" from
    # "decoded nothing".
    pi.publicLibraries = @[InterfaceLibrary(name: "libinfra",
      kind: lkShared, exportedPath: "src",
      location: SourceLocation(file: "repro.nim", line: 3))]
    let encoded = encodeV20ProjectInterfaceArtifact(pi)
    let decoded = decodeProjectInterfaceArtifact(encoded)
    check decoded.projectInterface.publicServices.len == 0
    check decoded.projectInterface.publicActivities.len == 0
    check decoded.projectInterface.publicLibraries.len == 1
    check decoded.projectInterface.publicLibraries[0].name == "libinfra"

  test "a corrupted v21 envelope fails closed":
    let encoded = encodeProjectInterfaceArtifact(artifactFor(samplePi()))
    var corrupted = encoded
    corrupted[^2] = corrupted[^2] xor 0xff'u8
    expect EnvelopeError:
      discard decodeProjectInterfaceArtifact(corrupted)

  test "empty publicServices / publicActivities round-trip":
    var pi: ProjectInterface
    pi.projectName = "empty"
    pi.packageName = "empty"
    let decoded = decodeProjectInterfaceArtifact(
      encodeProjectInterfaceArtifact(artifactFor(pi)))
    check decoded.projectInterface.publicServices.len == 0
    check decoded.projectInterface.publicActivities.len == 0

suite "interface-artifact L3 — every lifted field is falsifiable":

  test "adding a service SHIFTS the fingerprint":
    var bare: ProjectInterface
    bare.projectName = "infra"
    bare.packageName = "infra"
    check artifactFor(bare).interfaceFingerprint !=
      artifactFor(samplePi()).interfaceFingerprint

  test "renaming a service SHIFTS the fingerprint":
    var renamed = samplePi()
    renamed.publicServices[0].name = "zitadelRENAMED"
    check artifactFor(samplePi()).interfaceFingerprint !=
      artifactFor(renamed).interfaceFingerprint

  test "renaming a `config:` key SHIFTS the fingerprint":
    var renamed = samplePi()
    renamed.publicActivities[0].config[2].name = "portRENAMED"
    check artifactFor(samplePi()).interfaceFingerprint !=
      artifactFor(renamed).interfaceFingerprint

  test "changing a `config:` DEFAULT SHIFTS the fingerprint":
    var changed = samplePi()
    changed.publicActivities[0].config[2].defaultRepr = "9090"
    check artifactFor(samplePi()).interfaceFingerprint !=
      artifactFor(changed).interfaceFingerprint

  test "flipping hasDefault SHIFTS the fingerprint":
    # `issuer: string` and `issuer: string = ""` are different
    # declarations and only the first makes the key required. Without
    # this byte the two would hash the same.
    var changed = samplePi()
    changed.publicActivities[0].config[0].hasDefault = true
    check artifactFor(samplePi()).interfaceFingerprint !=
      artifactFor(changed).interfaceFingerprint

  test "changing a parameter TYPE SHIFTS the fingerprint":
    var changed = samplePi()
    changed.publicActivities[0].params[0].nimType = "ManagedMysql"
    check artifactFor(samplePi()).interfaceFingerprint !=
      artifactFor(changed).interfaceFingerprint

  test "changing a `config:` key's TYPE SHIFTS the fingerprint":
    var changed = samplePi()
    changed.publicActivities[0].config[2].nimType = "uint16"
    check artifactFor(samplePi()).interfaceFingerprint !=
      artifactFor(changed).interfaceFingerprint

  test "reordering an activity's service list SHIFTS the fingerprint":
    var changed = samplePi()
    changed.publicActivities[0].services = @["bootstrap", "zitadel"]
    check artifactFor(samplePi()).interfaceFingerprint !=
      artifactFor(changed).interfaceFingerprint

  test "a `config:` key's DOC COMMENT shifts it too, and that is intended":
    # The description is part of what a consumer is shown for a key it
    # must supply, so it is part of the published contract rather than a
    # comment. Asserted so the choice is a measured one rather than an
    # accident of which fields the writer happened to include.
    var changed = samplePi()
    changed.publicActivities[0].config[0].description = "something else"
    check artifactFor(samplePi()).interfaceFingerprint !=
      artifactFor(changed).interfaceFingerprint

suite "interface-artifact L3 — locations do NOT shift the fingerprint (TI3)":

  test "the activity's own location is normalised":
    var moved = samplePi()
    moved.publicActivities[0].location =
      SourceLocation(file: "elsewhere.nim", line: 999)
    check artifactFor(samplePi()).interfaceFingerprint ==
      artifactFor(moved).interfaceFingerprint

  test "a PARAMETER's location is normalised":
    var moved = samplePi()
    moved.publicActivities[0].params[1].location =
      SourceLocation(file: "elsewhere.nim", line: 999)
    check artifactFor(samplePi()).interfaceFingerprint ==
      artifactFor(moved).interfaceFingerprint

  test "a `config:` KEY's location is normalised":
    var moved = samplePi()
    moved.publicActivities[0].config[1].location =
      SourceLocation(file: "elsewhere.nim", line: 999)
    check artifactFor(samplePi()).interfaceFingerprint ==
      artifactFor(moved).interfaceFingerprint

  test "a SERVICE's location is normalised":
    var moved = samplePi()
    moved.publicServices[1].location =
      SourceLocation(file: "elsewhere.nim", line: 999)
    check artifactFor(samplePi()).interfaceFingerprint ==
      artifactFor(moved).interfaceFingerprint

  test "the on-disk artifact still carries the REAL locations (control)":
    # The reason the four tests above are not vacuous: if the writer
    # dropped locations entirely rather than normalising them only for
    # the fingerprint, they would all pass and go-to-definition would be
    # gone.
    let decoded = decodeProjectInterfaceArtifact(
      encodeProjectInterfaceArtifact(artifactFor(samplePi())))
    check decoded.projectInterface.publicActivities[0].params[1].
      location.line == 11
    check decoded.projectInterface.publicActivities[0].config[1].
      location.line == 17
    check decoded.projectInterface.publicServices[1].location.line == 36

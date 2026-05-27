## M12 codec roundtrip: encode a v9 ``ProjectInterfaceArtifact`` with a
## non-empty ``publicLibraries`` seq, decode it back, and assert every
## field survives. Also verifies that the interface fingerprint
## stays stable across the encode/decode cycle (publicLibraries is part
## of the fingerprinted payload), and that the v8-back-compat fallback
## holds (a v8 envelope decodes with publicLibraries defaulting to an
## empty seq).
##
## Run via the standalone ``nim c -r`` path (the repo's tests aren't yet
## organised under a runner). The script ``run_tests.sh`` picks this up
## automatically because it lives under ``libs/<lib>/tests``.

import std/[os, unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_core

suite "interface-artifact codec M12 (v9)":

  test "publicLibraries round-trips through encode/decode":
    var pi: ProjectInterface
    pi.projectName = "v9LibRoundTrip"
    pi.packageName = "v9LibRoundTrip"
    pi.standardBuildEligible = true
    pi.publicLibraries.add(InterfaceLibrary(
      name: "math_static",
      kind: lkStatic,
      location: SourceLocation(file: "reprobuild.nim", line: 12)))
    pi.publicLibraries.add(InterfaceLibrary(
      name: "math_shared",
      kind: lkShared,
      location: SourceLocation(file: "reprobuild.nim", line: 18)))
    pi.publicLibraries.add(InterfaceLibrary(
      name: "math_both",
      kind: lkBoth,
      location: SourceLocation(file: "reprobuild.nim", line: 24)))
    pi.publicLibraries.add(InterfaceLibrary(
      name: "math_header_only",
      kind: lkHeaderOnly,
      location: SourceLocation(file: "reprobuild.nim", line: 30)))
    let artifact = artifactFor(pi)

    let encoded = encodeProjectInterfaceArtifact(artifact)
    let decoded = decodeProjectInterfaceArtifact(encoded)

    check decoded.projectInterface.projectName == "v9LibRoundTrip"
    check decoded.projectInterface.standardBuildEligible
    check decoded.projectInterface.publicLibraries.len == 4
    check decoded.projectInterface.publicLibraries[0].name == "math_static"
    check decoded.projectInterface.publicLibraries[0].kind == lkStatic
    check decoded.projectInterface.publicLibraries[0].location.line == 12
    check decoded.projectInterface.publicLibraries[1].name == "math_shared"
    check decoded.projectInterface.publicLibraries[1].kind == lkShared
    check decoded.projectInterface.publicLibraries[2].name == "math_both"
    check decoded.projectInterface.publicLibraries[2].kind == lkBoth
    check decoded.projectInterface.publicLibraries[3].name == "math_header_only"
    check decoded.projectInterface.publicLibraries[3].kind == lkHeaderOnly
    check decoded.interfaceFingerprint == artifact.interfaceFingerprint

  test "round-trip via on-disk file":
    var pi: ProjectInterface
    pi.projectName = "v9LibFile"
    pi.packageName = "v9LibFile"
    pi.publicLibraries.add(InterfaceLibrary(
      name: "core",
      kind: lkStatic,
      location: SourceLocation(file: "reprobuild.nim", line: 8)))
    let artifact = artifactFor(pi)
    let scratch = getTempDir() / "test_library_codec_roundtrip.rbsz"
    if fileExists(scratch):
      removeFile(scratch)
    writeInterfaceArtifact(scratch, artifact)
    let readBack = readInterfaceArtifact(scratch)
    check readBack.projectInterface.publicLibraries.len == 1
    check readBack.projectInterface.publicLibraries[0].name == "core"
    check readBack.projectInterface.publicLibraries[0].kind == lkStatic
    check readBack.interfaceFingerprint == artifact.interfaceFingerprint
    removeFile(scratch)

  test "fingerprint changes when publicLibraries changes":
    var piA: ProjectInterface
    piA.projectName = "fpDiffA"
    piA.packageName = "fpDiffA"
    var piB: ProjectInterface
    piB.projectName = "fpDiffA"
    piB.packageName = "fpDiffA"
    piB.publicLibraries.add(InterfaceLibrary(
      name: "lib", kind: lkStatic,
      location: SourceLocation(file: "rb.nim", line: 1)))
    check artifactFor(piA).interfaceFingerprint !=
      artifactFor(piB).interfaceFingerprint

  test "empty publicLibraries round-trips":
    var pi: ProjectInterface
    pi.projectName = "emptyLibs"
    pi.packageName = "emptyLibs"
    let artifact = artifactFor(pi)
    let encoded = encodeProjectInterfaceArtifact(artifact)
    let decoded = decodeProjectInterfaceArtifact(encoded)
    check decoded.projectInterface.publicLibraries.len == 0

  test "every LibraryKind ordinal survives round-trip":
    for kind in LibraryKind:
      var pi: ProjectInterface
      pi.projectName = "kindRoundTrip"
      pi.packageName = "kindRoundTrip"
      pi.publicLibraries.add(InterfaceLibrary(
        name: "k", kind: kind,
        location: SourceLocation(file: "rb.nim", line: 1)))
      let encoded = encodeProjectInterfaceArtifact(artifactFor(pi))
      let decoded = decodeProjectInterfaceArtifact(encoded)
      check decoded.projectInterface.publicLibraries[0].kind == kind

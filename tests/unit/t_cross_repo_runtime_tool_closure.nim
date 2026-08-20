import std/[os, unittest]

import repro_build_engine
import repro_cli_support
import repro_hash
import repro_tool_profiles

suite "cross-repository executable runtime closure":
  test "runtime identity paths join the producer channels":
    let runtimeRoot = getTempDir() /
      ("repro-runtime-closure-" & $getCurrentProcessId())
    removeDir(runtimeRoot)
    let runtimeBin = runtimeRoot / "bin"
    createDir(runtimeBin)
    defer: removeDir(runtimeRoot)

    let identity = PathOnlyBuildIdentity(actionIdentities: @[
      ToolActionIdentity(
        packageSelector: "hypervisor",
        executableName: "virsh",
        resolvedExecutablePath: runtimeBin / "virsh",
        pathSearchList: @[runtimeBin],
        pkgConfigSearchList: @[runtimeRoot / "lib" / "pkgconfig"],
        cmakePrefixList: @[runtimeRoot],
        cpathList: @[runtimeRoot / "include"],
        libraryPathList: @[runtimeRoot / "lib"],
        actionFingerprint: weakFingerprintFromText("hypervisor-runtime"))])
    var binDirs: seq[string] = @[]
    var aux = ProducerAuxPaths()

    mergeProducerRuntimeIdentity(identity, binDirs, aux)

    check binDirs == @[runtimeBin]
    check aux.pkgConfigDirs == @[runtimeRoot / "lib" / "pkgconfig"]
    check aux.cmakePrefixDirs == @[runtimeRoot]
    check aux.includeDirs == @[runtimeRoot / "include"]
    check aux.libDirs == @[runtimeRoot / "lib"]

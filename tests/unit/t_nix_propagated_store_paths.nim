import std/[os, sequtils, tempfiles, unittest]

import repro_tool_profiles

suite "Nix propagated store path closure":
  test "recursively includes split-output dependencies once":
    let scratch = createTempDir("repro-nix-propagated-", "")
    defer: removeDir(scratch)

    let devOutput = scratch / "libbsd-dev"
    let runtimeOutput = scratch / "libbsd-runtime"
    let transitiveOutput = scratch / "libmd-runtime"
    createDir(devOutput / "nix-support")
    createDir(runtimeOutput / "nix-support")
    createDir(transitiveOutput)
    writeFile(devOutput / "nix-support" / "propagated-build-inputs",
      runtimeOutput & "\n")
    writeFile(runtimeOutput / "nix-support" /
      "propagated-native-build-inputs", transitiveOutput & "\n")

    var paths = @[devOutput]
    expandNixPropagatedStorePaths(paths)

    check paths == @[devOutput, runtimeOutput, transitiveOutput]

  test "adds propagated runtime directories to cached profile channels":
    let scratch = createTempDir("repro-nix-profile-propagated-", "")
    defer: removeDir(scratch)

    let devOutput = scratch / "fribidi-dev"
    let runtimeOutput = scratch / "fribidi-runtime"
    createDir(devOutput / "nix-support")
    createDir(devOutput / "lib" / "pkgconfig")
    createDir(runtimeOutput / "lib")
    writeFile(devOutput / "nix-support" / "propagated-build-inputs",
      runtimeOutput & "\n")

    var profile = PathOnlyToolProfile(
      installMethod: "nix",
      realizedStorePaths: @[devOutput])
    expandNixProfilePropagatedPaths(profile)

    check profile.realizedStorePaths == @[devOutput, runtimeOutput]
    check absolutePath(runtimeOutput / "lib") in profile.libraryPathList

  test "compiler wrapper contributes its selected libc runtime":
    let scratch = createTempDir("repro-nix-wrapper-runtime-", "")
    defer: removeDir(scratch)

    let wrapper = scratch / "cc-wrapper"
    let runtime = scratch / "libc-runtime"
    let satellite = scratch / "libc-satellite"
    createDir(wrapper / "nix-support")
    createDir(runtime / "nix-support")
    createDir(satellite)
    writeFile(wrapper / "nix-support" / "orig-libc", runtime & "\n")
    writeFile(runtime / "nix-support" / "propagated-build-inputs",
      satellite & "\n" & wrapper & "\n")

    var paths = @[wrapper]
    expandNixPropagatedStorePaths(paths)
    check paths == @[wrapper, runtime, satellite]
    expandNixPropagatedStorePaths(paths)
    check paths == @[wrapper, runtime, satellite]

  test "cached compiler profiles acquire libc without exposing its tools":
    let scratch = createTempDir("repro-nix-cached-wrapper-", "")
    defer: removeDir(scratch)

    let wrapper = scratch / "cc-wrapper"
    let runtime = scratch / "libc-runtime"
    createDir(wrapper / "nix-support")
    createDir(wrapper / "bin")
    createDir(runtime / "lib")
    createDir(runtime / "bin")
    var profile = PathOnlyToolProfile(installMethod: "nix",
      realizedStorePaths: @[wrapper], pathSearchList: @[wrapper / "bin"])
    expandNixProfilePropagatedPaths(profile)
    let oldFingerprint = profile.profileFingerprint
    check profile.libraryPathList.len == 0
    writeFile(wrapper / "nix-support" / "orig-libc", runtime & "\n")

    expandNixProfilePropagatedPaths(profile)
    check profile.realizedStorePaths == @[wrapper, runtime]
    check profile.libraryPathList == @[absolutePath(runtime / "lib")]
    check profile.pathSearchList == @[wrapper / "bin"]
    check profile.profileFingerprint != oldFingerprint
    let newFingerprint = profile.profileFingerprint
    expandNixProfilePropagatedPaths(profile)
    check profile.libraryPathList.count(absolutePath(runtime / "lib")) == 1
    check profile.profileFingerprint == newFingerprint

  test "missing compiler runtime and non-runtime wrapper metadata stay out":
    let scratch = createTempDir("repro-nix-wrapper-metadata-", "")
    defer: removeDir(scratch)

    let wrapper = scratch / "cc-wrapper"
    let headers = scratch / "libc-dev"
    createDir(wrapper / "nix-support")
    createDir(headers / "include")
    writeFile(wrapper / "nix-support" / "orig-libc",
      scratch / "missing-libc" & "\n")
    writeFile(wrapper / "nix-support" / "orig-libc-dev", headers & "\n")
    var paths = @[wrapper]
    expandNixPropagatedStorePaths(paths)
    check paths == @[wrapper]

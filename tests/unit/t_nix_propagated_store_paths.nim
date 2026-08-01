import std/[os, tempfiles, unittest]

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

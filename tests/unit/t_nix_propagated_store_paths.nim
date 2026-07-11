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

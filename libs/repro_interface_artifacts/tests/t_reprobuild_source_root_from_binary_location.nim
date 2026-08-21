import std/[os, tempfiles, unittest]

import repro_interface_artifacts

suite "reprobuild source root from binary location":

  test "local build binary resolves the checkout root":
    let root = createTempDir("reprobuild-source-root-", "")
    defer: removeDir(root)
    let marker = root / "libs" / "repro_project_dsl" / "src" /
      "repro_project_dsl.nim"
    createDir(marker.parentDir)
    writeFile(marker, "")

    let binary = root / "build" / "bin" / "repro"
    check reprobuildSourceRootFromBinaryLocation(binary) == root

  test "unrelated binary layout is not treated as a checkout":
    let root = createTempDir("reprobuild-not-source-root-", "")
    defer: removeDir(root)
    check reprobuildSourceRootFromBinaryLocation(
      root / "build" / "bin" / "repro") == ""

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

  test "build-time package root survives without an ambient override":
    let root = createTempDir("reprobuild-built-package-root-", "")
    defer: removeDir(root)
    let marker = root / "src" / "io_mon.nim"
    createDir(marker.parentDir)
    writeFile(marker, "")

    let envName = "REPROBUILD_TEST_SOURCE_ROOT"
    let hadEnv = existsEnv(envName)
    let oldEnv = getEnv(envName)
    delEnv(envName)
    defer:
      if hadEnv: putEnv(envName, oldEnv)
      else: delEnv(envName)

    check resolveBootstrapPackagePath(
      envName, newSeq[string](), "io_mon.nim", root) == root / "src"

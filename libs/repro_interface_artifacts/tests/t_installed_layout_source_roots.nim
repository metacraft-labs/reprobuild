## An unpacked release archive must find its own source roots.
##
## The release archives (``reprobuild-<ver>-<os>-<arch>.{tar.gz,zip}``) carry
## reprobuild's ``libs/`` under ``share/repro/source`` and the source-only
## inputs under ``share/repro/src``. Nothing sets ``REPROBUILD_SOURCE_ROOT``
## for them -- on Windows ``repro.exe`` is run directly -- so the image seeds
## the roots itself from the prefix it was started from. Without that, the
## first compile of any project fails with ``cannot open file:
## repro_interface_artifacts``.
##
## No mocks: the cases build a real prefix on disk, and the last one copies
## THIS test executable into ``<prefix>/bin`` and runs it as a child, so the
## anchor is the operating system's own answer to "where is my image".

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_interface_artifacts

const ChildFlag = "--installed-layout-child"

if paramCount() == 1 and paramStr(1) == ChildFlag:
  # A clean slate for exactly the variables under test, then the same
  # prologue the CLI runs.
  delEnv("REPROBUILD_SOURCE_ROOT")
  delEnv("REPRO_PUBLIC_CLI_PATH")
  delEnv(SeededSourceEnvironmentVar)
  for (name, _) in InstalledSourcePackageTrees:
    delEnv(name)
  ensureInstalledSourcePackageEnvironment()
  echo "REPROBUILD_SOURCE_ROOT=", getEnv("REPROBUILD_SOURCE_ROOT")
  echo "REPRO_TEST_ADAPTERS_SRC=", getEnv("REPRO_TEST_ADAPTERS_SRC")
  echo "IO_MON_SRC=", getEnv("IO_MON_SRC")
  quit(0)

proc touch(path: string) =
  createDir(path.parentDir)
  writeFile(path, "")

proc makeInstalledPrefix(prefix: string; trees: openArray[string]) =
  touch(prefix / InstalledSourceRootSubdir / "libs" / "repro_project_dsl" /
    "src" / "repro_project_dsl.nim")
  for rel in trees:
    createDir(prefix / InstalledSourceTreesSubdir / rel)

suite "installed-layout source roots":

  test "a prefix with the libs tree yields the source root and shipped inputs":
    let prefix = createTempDir("repro-installed-prefix-", "")
    defer: removeDir(prefix)
    makeInstalledPrefix(prefix, ["reprobuild-test-adapters/src", "io-mon/src"])
    let roots = installedLayoutSourceRoots(prefix)
    check roots.len == 3
    check roots[0] == ("REPROBUILD_SOURCE_ROOT",
      prefix / InstalledSourceRootSubdir)
    check ("IO_MON_SRC", prefix / InstalledSourceTreesSubdir / "io-mon/src") in
      roots
    check ("REPRO_TEST_ADAPTERS_SRC", prefix / InstalledSourceTreesSubdir /
      "reprobuild-test-adapters/src") in roots

  test "input trees are ignored when reprobuild's own libs are absent":
    let prefix = createTempDir("repro-not-installed-", "")
    defer: removeDir(prefix)
    createDir(prefix / InstalledSourceTreesSubdir / "io-mon/src")
    check installedLayoutSourceRoots(prefix).len == 0
    check installedLayoutSourceRoot(prefix) == ""

  test "both the image path and the launcher's public CLI path anchor a prefix":
    let sep = $DirSep
    let prefix = sep & "opt" & sep & "reprobuild-x"
    check installedLayoutPrefixCandidates(prefix / "bin" / "reprobuild", "") ==
      @[prefix]
    # The portable Linux archive runs through its bundled loader, so the
    # image path names the loader in lib/; the launcher's path names bin/.
    check installedLayoutPrefixCandidates(
      prefix / "lib" / "ld-linux-x86-64.so.2", prefix / "bin" / "reprobuild") ==
      @[prefix]
    check installedLayoutPrefixCandidates("", "").len == 0

  test "an image started from <prefix>/bin seeds the prefix's roots":
    let prefix = createTempDir("repro-installed-run-", "")
    defer: removeDir(prefix)
    makeInstalledPrefix(prefix, ["reprobuild-test-adapters/src"])
    let exe = prefix / "bin" / extractFilename(getAppFilename())
    createDir(exe.parentDir)
    copyFile(getAppFilename(), exe)
    inclFilePermissions(exe, {fpUserExec})
    let (output, code) = execCmdEx(quoteShell(exe) & " " & ChildFlag)
    check code == 0
    let expectedRoot = prefix / InstalledSourceRootSubdir
    let expectedAdapters = prefix / InstalledSourceTreesSubdir /
      "reprobuild-test-adapters/src"
    check output.contains("REPROBUILD_SOURCE_ROOT=" & expectedRoot)
    check output.contains("REPRO_TEST_ADAPTERS_SRC=" & expectedAdapters)
    # Not shipped in this prefix, so not seeded from it.
    check output.contains("IO_MON_SRC=\n") or
      output.contains("IO_MON_SRC=\r\n")

  test "an explicit caller value is never replaced":
    let prefix = createTempDir("repro-installed-explicit-", "")
    defer: removeDir(prefix)
    makeInstalledPrefix(prefix, [])
    let name = "REPROBUILD_SOURCE_ROOT"
    let hadValue = existsEnv(name)
    let oldValue = getEnv(name)
    let hadMarker = existsEnv(SeededSourceEnvironmentVar)
    let oldMarker = getEnv(SeededSourceEnvironmentVar)
    defer:
      if hadValue: putEnv(name, oldValue) else: delEnv(name)
      if hadMarker: putEnv(SeededSourceEnvironmentVar, oldMarker)
      else: delEnv(SeededSourceEnvironmentVar)
    putEnv(name, "caller-chosen")
    seedSourcePackageEnvironment(installedLayoutSourceRoots(prefix))
    check getEnv(name) == "caller-chosen"

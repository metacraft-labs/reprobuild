## The provider compiler of an installed prefix is the Nim it ships
## (reprobuild-pm Distribution-And-Packaging.md §5.3, amendment N3, approved
## by Zahary Karadjov, 2026-11-04; the provider-toolchain rule 2 in the
## Distribution-And-Packaging milestone names this route first).
##
## ## The defect this pins
##
## The armv7 installed prefix ships the Nim fork under `nim/`, because the
## appliance compiles providers and profiles itself. Substituted on rpi2,
## its `repro exec -- true` in an empty project ignored that compiler and
## provisioned `nim-source@2.2.10` (a source build of stock Nim on a Pi 2,
## 2.2 GB of tool store, not done after 1500 s; 2026-11-04). The bootstrap
## routes knew of no compiler beside the running image.
##
## ## What is pinned
##
## * an image whose prefix ships `nim/bin/nim` compiles with it, and no
##   bootstrap route runs (no tool-store prefix appears);
## * the shipped compiler must be the fork the prefix records:
##   `nim/.nim-fork-revision` against `nim_fork=` in
##   `share/repro/cross-build-info`, refused by name otherwise, and refused
##   when the record is missing;
## * a compiler outside the bootstrap's `nim >=2.2 <3.0` is refused, not
##   replaced;
## * an image with no `nim/` keeps the per-host routes;
## * a compiler already chosen (a project pin, which publishes
##   `REPRO_NIM_COMPILER` at entry, or the caller's explicit value) wins.
##
## NO MOCKS of the route: real directories in the installed layout. The
## shipped `bin/nim` is a stand-in file: the route reads the compiler's
## version from its `lib/system/compilation.nim`, as the installation
## records it, and never runs it.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_tool_profiles
import repro_test_support/reasoned_skip

const
  ForkRev = "197089cda27f656f8010e2b31b40e0e12f3f209b"

template withEnv(names: openArray[string]; body: untyped) =
  var saved: seq[tuple[name: string; present: bool; value: string]]
  for name in names:
    saved.add((name: name, present: existsEnv(name), value: getEnv(name)))
  try:
    body
  finally:
    for entry in saved:
      if entry.present: putEnv(entry.name, entry.value)
      else: delEnv(entry.name)

proc installedPrefix(root: string; rev = ForkRev; recorded = ForkRev;
                     major = 2, minor = 3, patch = 1;
                     record = true): string =
  ## An installed prefix at `root/prefix`: the engine image, the shipped
  ## Nim and the build record.
  result = root / "prefix"
  createDir(result / "bin")
  writeFile(result / "bin" / "reprobuild", "")
  createDir(result / "nim" / "bin")
  createDir(result / "nim" / "lib" / "system")
  writeFile(result / "nim" / "bin" / addFileExt("nim", ExeExt),
    "#!/bin/sh\nexit 0\n")
  writeFile(result / "nim" / ".nim-fork-revision", rev & "\n")
  writeFile(result / "nim" / "lib" / "system" / "compilation.nim",
    "const\n" &
    "  NimMajor* {.intdefine.}: int = " & $major & "\n" &
    "  NimMinor* {.intdefine.}: int = " & $minor & "\n" &
    "  NimPatch* {.intdefine.}: int = " & $patch & "\n")
  if record:
    createDir(result / "share" / "repro")
    writeFile(result / "share" / "repro" / "cross-build-info",
      "triple=armv7-unknown-linux-gnueabihf\nnim_fork=" & recorded & "\n")

proc refusal(prefix: string): string =
  try:
    discard installedPrefixNim(@[prefix])
    "no refusal"
  except BootstrapNimError as err:
    err.msg

suite "an installed prefix compiles providers with the Nim it ships":

  test "a prefix shipping the recorded fork resolves to it":
    let root = createTempDir("prefix-nim-ok-", "")
    defer: removeDir(root)
    let prefix = installedPrefix(root)
    check installedPrefixNim(@[root / "elsewhere", prefix]) ==
      prefix / "nim" / "bin" / addFileExt("nim", ExeExt)

  test "an image with no nim/ keeps the per-host routes":
    let root = createTempDir("prefix-nim-none-", "")
    defer: removeDir(root)
    createDir(root / "checkout" / "bin")
    check installedPrefixNim(@[root / "checkout"]) == ""

  test "a shipped Nim that is not the recorded fork is refused by name":
    let root = createTempDir("prefix-nim-rev-", "")
    defer: removeDir(root)
    let other = repeat('b', 40)
    let msg = refusal(installedPrefix(root, rev = other))
    checkpoint(msg)
    check other in msg
    check ForkRev in msg
    check "nim/.nim-fork-revision" in msg

  test "a shipped Nim without the build record is refused":
    let root = createTempDir("prefix-nim-norec-", "")
    defer: removeDir(root)
    let msg = refusal(installedPrefix(root, record = false))
    checkpoint(msg)
    check "cross-build-info" in msg

  test "a shipped Nim outside the bootstrap's range is refused, not replaced":
    let root = createTempDir("prefix-nim-range-", "")
    defer: removeDir(root)
    let msg = refusal(installedPrefix(root, major = 3, minor = 0, patch = 0))
    checkpoint(msg)
    check "3.0.0" in msg
    check ">=2.2" in msg

  test "the bootstrap uses the prefix's Nim and provisions none":
    let gcc = findExe("gcc")
    if gcc.len == 0:
      skip("gcc not on PATH; the bootstrap probes the C compiler it is given")
    else:
      let root = createTempDir("prefix-nim-env-", "")
      defer: removeDir(root)
      let prefix = installedPrefix(root)
      let store = root / "tool-store"
      withEnv(["REPRO_NIM_COMPILER", "REPRO_BOOTSTRAP_CC",
               "REPRO_PUBLIC_CLI_PATH", "CC"]):
        delEnv("REPRO_NIM_COMPILER")
        putEnv("REPRO_BOOTSTRAP_CC", gcc)
        # The image the portable launcher names (the second anchor of
        # `runningImagePrefixCandidates`); this test binary's own image
        # lives in no prefix.
        putEnv("REPRO_PUBLIC_CLI_PATH", prefix / "bin" / "reprobuild")
        ensureBootstrapToolchainEnv(tpmPathOnly, store)
        check getEnv("REPRO_NIM_COMPILER") ==
          prefix / "nim" / "bin" / addFileExt("nim", ExeExt)
        check not dirExists(store / "prefixes")

  test "a compiler already chosen (a project pin) wins over the prefix's":
    let gcc = findExe("gcc")
    if gcc.len == 0:
      skip("gcc not on PATH; the bootstrap probes the C compiler it is given")
    else:
      let root = createTempDir("prefix-nim-pin-", "")
      defer: removeDir(root)
      let prefix = installedPrefix(root)
      withEnv(["REPRO_NIM_COMPILER", "REPRO_BOOTSTRAP_CC",
               "REPRO_PUBLIC_CLI_PATH", "CC"]):
        putEnv("REPRO_NIM_COMPILER", root / "pinned" / "bin" / "nim")
        putEnv("REPRO_BOOTSTRAP_CC", gcc)
        putEnv("REPRO_PUBLIC_CLI_PATH", prefix / "bin" / "reprobuild")
        ensureBootstrapToolchainEnv(tpmPathOnly, root / "tool-store")
        check getEnv("REPRO_NIM_COMPILER") == root / "pinned" / "bin" / "nim"

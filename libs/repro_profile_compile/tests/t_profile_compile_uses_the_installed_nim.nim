## An installed reprobuild prefix compiles profiles with the Nim it ships
## (``installedNimCompiler``), and only once it is checked, as the provider
## compile checks it (reprobuild-pm Distribution-And-Packaging.md §5.3,
## amendment N3, approved by Zahary Karadjov, 2026-11-04:
## ``repro_core/installed_prefix_nim.findInstalledPrefixNim``).
##
## Before N3 an installed engine run with a clean environment (a dynamic
## user's transient unit, ``PATH`` systemd's default) found no compiler
## unless the base had one on ``PATH`` -- measured on an armhf add-on test
## bed: "no Nim compiler". The prefix arm fixed that but took
## ``<prefix>/nim/bin/nim`` or ``<prefix>/bin/nim`` with no check at all, so
## a profile compile on the appliance (``deploy_agent``'s compile-profile)
## bypassed the revision and range check the provider compile applies (A15
## re-review, 2026-11-05).
##
## *Mocking.* None: real directories and files; the shipped ``bin/nim`` is
## never run, its release is read from ``lib/system/compilation.nim``.

import std/[os, strutils, tempfiles, unittest]

import repro_profile_compile/compile

const ForkRev = "197089cda27f656f8010e2b31b40e0e12f3f209b"

proc shippedNim(prefix: string; rev = ForkRev) =
  createDir(prefix / "nim" / "bin")
  createDir(prefix / "nim" / "lib" / "system")
  createDir(prefix / "bin")
  writeFile(prefix / "nim" / "bin" / "nim", "")
  writeFile(prefix / "bin" / "nim", "")
  writeFile(prefix / "nim" / ".nim-fork-revision", rev & "\n")
  writeFile(prefix / "nim" / "lib" / "system" / "compilation.nim",
    "const\n  NimMajor* {.intdefine.}: int = 2\n" &
    "  NimMinor* {.intdefine.}: int = 3\n  NimPatch* {.intdefine.}: int = 1\n")

proc record(prefix: string) =
  createDir(prefix / "share" / "repro")
  writeFile(prefix / "share" / "repro" / "cross-build-info",
    "nim_fork=" & ForkRev & "\n")

suite "the profile compile finds the installed prefix's Nim":
  test "the prefix's checked nim is found; a non-reprobuild prefix is ignored":
    let tmp = createTempDir("installed-nim-", "")
    defer: removeDir(tmp)
    let prefix = tmp / "repro"
    shippedNim(prefix)
    record(prefix)
    check installedNimCompiler([prefix]) == prefix / "nim" / "bin" / "nim"
    # A distribution prefix (/usr-like: a bin/nim, no nim/) is skipped.
    let usr = tmp / "usr"
    createDir(usr / "bin")
    writeFile(usr / "bin" / "nim", "")
    check installedNimCompiler([usr, prefix]) == prefix / "nim" / "bin" / "nim"

  test "a bin/nim without nim/ is not taken":
    let tmp = createTempDir("installed-nim-binonly-", "")
    defer: removeDir(tmp)
    let prefix = tmp / "repro"
    createDir(prefix / "bin")
    writeFile(prefix / "bin" / "nim", "")
    record(prefix)
    check installedNimCompiler([prefix]) == ""

  test "a shipped Nim that is not the recorded fork is refused, not used":
    let tmp = createTempDir("installed-nim-rev-", "")
    defer: removeDir(tmp)
    let prefix = tmp / "repro"
    shippedNim(prefix, rev = repeat('b', 40))
    record(prefix)
    try:
      discard installedNimCompiler([prefix])
      check false
    except CompileFailure as err:
      checkpoint(err.msg)
      check "not the fork it records" in err.msg

  test "a shipped Nim without the build record is refused, not used":
    let tmp = createTempDir("installed-nim-norec-", "")
    defer: removeDir(tmp)
    let prefix = tmp / "repro"
    shippedNim(prefix)
    # A reprobuild install (share/repro) without its build record.
    createDir(prefix / "share" / "repro")
    try:
      discard installedNimCompiler([prefix])
      check false
    except CompileFailure as err:
      checkpoint(err.msg)
      check "no build record" in err.msg

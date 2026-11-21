## A cross-built engine prefix runs only where the base's glibc is at least
## the glibc of the sysroot it was linked against (ReproOS add-on mode §7.9,
## the glibc exception). Bootstrap's preflight refuses a ``--profile-compiler``
## in such a prefix on an older glibc, by name, before it would fail at the
## first compile with the loader's "version `GLIBC_2.xx' not found".
##
## *Mocking.* None for the check itself: a real prefix layout on disk
## (``bin/reprobuild`` reached through a ``/usr/local/bin``-style symlink, and
## ``share/repro/cross-build-info`` as ``scripts/cross/build_linux_cross.sh``
## writes it) and the host glibc passed in, because a unit test cannot change
## the glibc it runs on. The preflight hook is checked with the host's real
## ``getconf`` against a prefix that needs a glibc no host has.

import std/[os, strutils, tempfiles, unittest]

import repro_addon/cross_prefix
import repro_addon/preflight

proc makePrefix(root, info: string): string =
  ## A cross prefix at ``root`` with an executable ``bin/reprobuild`` and,
  ## when ``info`` is not empty, its ``cross-build-info``; returns a symlink
  ## to the binary from outside the prefix, as the installer links it.
  createDir(root / "bin")
  let bin = root / "bin" / "reprobuild"
  writeFile(bin, "#!/bin/sh\nexit 0\n")
  setFilePermissions(bin, {fpUserRead, fpUserWrite, fpUserExec})
  if info.len > 0:
    createDir(root / "share" / "repro")
    writeFile(root / CrossBuildInfoRel, info)
  result = root.parentDir / (root.extractFilename & "-link")
  createSymlink(bin, result)

const DebianInfo = "source_revision=abc\ntriple=arm-linux-gnueabihf\n" &
  "sysroot_triple=arm-linux-gnueabihf\n" &
  "sysroot_glibc=ldd (Debian GLIBC 2.41-12) 2.41\n" &
  "sysroot_glibc_version=2.41\n"
const OlderBuildInfo = "triple=arm-linux-gnueabihf\n" &
  "sysroot_glibc=ldd (Ubuntu GLIBC 2.39-0ubuntu8.6) 2.39\n"

suite "a cross prefix needs at least its sysroot's glibc":
  test "the recorded version: sysroot_glibc_version, else ldd's last word":
    check sysrootGlibcVersion(DebianInfo) == "2.41"
    check sysrootGlibcVersion(OlderBuildInfo) == "2.39"
    check sysrootGlibcVersion("triple=x\n") == ""
    check sysrootGlibcVersion("sysroot_glibc=ldd: not found\n") == ""

  test "versions compare by field, numerically":
    check glibcVersionCmp("2.9", "2.10") < 0
    check glibcVersionCmp("2.41", "2.41") == 0
    check glibcVersionCmp("2.41.1", "2.41") > 0

  test "an older host glibc is refused by name; equal or newer is not":
    let tmp = createTempDir("cross-glibc-", "")
    defer: removeDir(tmp)
    let link = makePrefix(tmp / "repro", DebianInfo)
    let refused = crossPrefixGlibcProblem(link, "2.39")
    check "linked against glibc 2.41" in refused
    check "this host has glibc 2.39" in refused
    check (tmp / "repro") in refused   # through the symlink, the prefix
    check crossPrefixGlibcProblem(link, "2.41") == ""
    check crossPrefixGlibcProblem(link, "2.42") == ""
    # A host whose glibc cannot be read cannot run it either.
    check "could not be read" in crossPrefixGlibcProblem(link, "")

  test "a prefix without a cross-build record is not judged":
    let tmp = createTempDir("cross-glibc-", "")
    defer: removeDir(tmp)
    let link = makePrefix(tmp / "nix-like", "")
    check crossPrefixGlibcProblem(link, "2.17") == ""
    check crossPrefixGlibcProblem(tmp / "absent", "2.17") == ""

  test "bootstrap's preflight refuses it before asking the compiler":
    # The host's real glibc (getconf) is older than 999.0, so the probe is
    # never reached: the stand-in binary would answer it with exit 0.
    let tmp = createTempDir("cross-glibc-", "")
    defer: removeDir(tmp)
    let link = makePrefix(tmp / "repro",
                          "sysroot_glibc_version=999.0\n")
    let host = hostGlibcVersion()
    if host.len > 0:
      let problem = profileCompilerProblem(link)
      check "linked against glibc 999.0" in problem
      check ("this host has glibc " & host) in problem
    else:
      # Not a glibc host (getconf absent or another libc): unreadable.
      check "could not be read" in profileCompilerProblem(link)

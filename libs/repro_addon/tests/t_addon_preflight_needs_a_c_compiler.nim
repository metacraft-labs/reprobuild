## A host that compiles profiles needs a C compiler from its base (ReproOS
## add-on mode §13 decision 31): Nim turns a profile into C. The fetch unit
## runs with systemd's default PATH, so the preflight looks there
## (``hostCCompiler``) and refuses a ``--profile-compiler`` on a host with
## none, instead of every later tick failing on ``gcc: not found``.
##
## *Mocking.* None: a real directory standing for the search path.

import std/[os, tempfiles, unittest]

import repro_addon/preflight

suite "the preflight and the host's C compiler":
  test "cc, gcc or clang on the search path is found; none is reported as none":
    let tmp = createTempDir("host-cc-", "")
    defer: removeDir(tmp)
    let empty = tmp / "empty"
    let bin = tmp / "bin"
    createDir(empty)
    createDir(bin)
    check hostCCompiler(empty) == ""
    writeFile(bin / "gcc", "#!/bin/sh\n")
    # Not executable: not a compiler.
    setFilePermissions(bin / "gcc", {fpUserRead, fpUserWrite})
    check hostCCompiler(empty & ":" & bin) == ""
    setFilePermissions(bin / "gcc", {fpUserRead, fpUserWrite, fpUserExec,
                                     fpOthersExec})
    check hostCCompiler(empty & ":" & bin) == bin / "gcc"
    writeFile(bin / "cc", "#!/bin/sh\n")
    setFilePermissions(bin / "cc", {fpUserRead, fpUserExec, fpOthersExec})
    check hostCCompiler(bin) == bin / "cc"

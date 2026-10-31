## A host that compiles profiles needs a Nim and a C compiler (ReproOS
## add-on mode §13 decision 31). Bootstrap's preflight asks the configured
## profile compiler which toolchain it would use (``deploy-agent
## compile-profile --probe-c-compiler``) and refuses ``--profile-compiler``
## when it answers that something is missing, instead of every later tick
## failing on ``gcc: not found``. A compiler not installed yet is not judged.
##
## *Mocking.* The profile compiler is a shell script answering the probe as
## the engine does (exit 0, or exit 1 with its message): the real engine's
## answer depends on the host's toolchain, which a unit test cannot vary.

import std/[os, strutils, tempfiles, unittest]

import repro_addon/preflight

suite "the preflight asks the profile compiler for its toolchain":
  test "a compiler that has one passes; one that has none is refused by its message":
    let tmp = createTempDir("probe-cc-", "")
    defer: removeDir(tmp)
    let good = tmp / "good"
    let bad = tmp / "bad"
    writeFile(good, "#!/bin/sh\n[ \"$3\" = --probe-c-compiler ] && { echo 'cc: /usr/bin/cc'; exit 0; }\nexit 2\n")
    writeFile(bad, "#!/bin/sh\necho 'repro profile compile: no C compiler.' >&2\nexit 1\n")
    for f in [good, bad]:
      setFilePermissions(f, {fpUserRead, fpUserWrite, fpUserExec})
    check profileCompilerProblem(good) == ""
    check "no C compiler" in profileCompilerProblem(bad)
    # Not installed yet: not judged.
    check profileCompilerProblem(tmp / "absent") == ""

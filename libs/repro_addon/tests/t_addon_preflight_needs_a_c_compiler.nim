## A host that compiles profiles needs a Nim and a C compiler (ReproOS
## add-on mode §13 decision 31). Bootstrap's preflight asks the configured
## profile compiler which toolchain it would use (``deploy-agent
## compile-profile --probe-c-compiler``) and refuses ``--profile-compiler``
## when it answers that something is missing, instead of every later tick
## failing on ``gcc: not found``. A compiler not installed yet is not judged.
##
## The probe and every compile search the same ``PATH``
## (``ProfileCompilePath``, systemd's default, ``/usr/local/bin`` included):
## the fetch unit's compile (``agent_split.runProfileCompiler``) and the
## full engine's unprivileged one (``verified_compile``) name it, and so
## does the probe. Before, the probe ran with the host tools' ``PATH``
## (``/usr/sbin:/usr/bin:/sbin:/bin``), so a ``gcc`` the operator installed
## under ``/usr/local/bin`` was judged missing by the probe.
##
## *Mocking.* The profile compiler is a shell script answering the probe as
## the engine does (exit 0, or exit 1 with its message): the real engine's
## answer depends on the host's toolchain, which a unit test cannot vary.

import std/[os, strutils, tempfiles, unittest]

import repro_addon/agent_split
import repro_addon/host_exec
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

  test "the probe and the fetch unit's compile search one PATH, /usr/local/bin included":
    let tmp = createTempDir("probe-cc-path-", "")
    defer: removeDir(tmp)
    # A "compiler" that reports the PATH it was given, as its failure.
    let echoPath = tmp / "echo-path"
    writeFile(echoPath, "#!/bin/sh\necho \"$PATH\"\nexit 1\n")
    setFilePermissions(echoPath, {fpUserRead, fpUserWrite, fpUserExec})
    check "/usr/local/bin" in ProfileCompilePath.split(':')
    check "/usr/bin" in ProfileCompilePath.split(':')
    # The last line: a host's preload shim may print diagnostics first.
    check profileCompilerProblem(echoPath).splitLines()[^1] ==
      ProfileCompilePath
    let compile = runProfileCompiler([echoPath, "deploy-agent",
      "compile-profile"])
    check compile.exitCode == 1
    check compile.output.strip().splitLines()[^1] == ProfileCompilePath

  test "a C compiler found only on the compile PATH passes the probe":
    let tmp = createTempDir("probe-cc-local-", "")
    defer: removeDir(tmp)
    let localBin = tmp / "local-bin"
    createDir(localBin)
    let gcc = localBin / "gcc"
    writeFile(gcc, "#!/bin/sh\nexit 0\n")
    setFilePermissions(gcc, {fpUserRead, fpUserWrite, fpUserExec})
    # The engine's answer, by a PATH lookup as resolveProfileCCompiler
    # makes it: present only where the compile PATH reaches.
    let probe = tmp / "probe"
    # Shell builtins only: the search must not need a tool from PATH.
    writeFile(probe, "#!/bin/sh\nIFS=:\nfor d in $PATH; do\n" &
      "  [ -x \"$d/gcc\" ] && { echo \"cc: $d/gcc\"; exit 0; }\ndone\n" &
      "echo 'repro profile compile: no C compiler.'\nexit 1\n")
    setFilePermissions(probe, {fpUserRead, fpUserWrite, fpUserExec})
    check profileCompilerProblem(probe, searchPath = localBin & ":/usr/bin") == ""
    check "no C compiler" in profileCompilerProblem(probe,
      searchPath = HostToolPath)

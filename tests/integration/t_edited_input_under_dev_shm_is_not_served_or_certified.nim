## A project whose tree is on ``/dev/shm`` gets the same answer as anywhere else.
## The monitor's reads under ``/dev/`` used to be dropped as device state, so such
## a project's edges had no inputs: an edited input was a hit, and an input edited
## to fail produced a certificate for content that fails.
##
## Uses the tmpfs that had the fault, not a stand-in, so the fixture's scratch goes
## under a directory of its own on ``/dev/shm``. ``/run/user/<uid>`` is tmpfs too
## and always worked, so the file system was never the variable: the path was.
##
## NO MOCKS: real repositories, the built ``repro``, the real provider, engine and
## monitor. Skip rule: Linux only (``/dev/shm`` writable), ``git`` and
## ``ssh-keygen`` present.
##
## Falsifiability: removing ``isOrdinaryFileUnderRuntimeMount`` from
## ``isVolatileRuntimeStatePath`` fails the re-execution check and the withheld
## certificate check below.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_workspace_mode_fixture

const buildLines =
  "    certificate \"side-suite\", side\n" &
  "    discard aggregate(\"test\", @[side])\n"

proc devShmUsable(): bool =
  ## Whether a directory can be made there, which is what the fixture needs.
  try:
    removeDir(createTempDir("repro-probe-", "", "/dev/shm"))
    true
  except CatchableError, OSError:
    false

suite "an input under /dev/shm":
  test "an edit re-executes, and a failing input gets no certificate":
    if not defined(linux) or not devShmUsable() or findExe("git").len == 0 or
        findExe("ssh-keygen").len == 0:
      skip("needs a writable /dev/shm, git and ssh-keygen; this test certifies " &
        "real repositories on that tmpfs")
    else:
      let scratch = createTempDir("repro-devshm-", "", "/dev/shm")
      defer: removeDir(scratch)
      let savedTmp = getEnv("TMPDIR")
      putEnv("TMPDIR", scratch)
      defer: putEnv("TMPDIR", savedTmp)
      var fx = setupWorkspaceCertifyFixture("devshm", ["side"], buildLines)
      check fx.app.startsWith("/dev/shm/")

      let first = fx.reproIn(["certify", "--tool-provisioning=path"])
      checkpoint(first.output)
      check first.code == 0
      let ran = fx.executedOutputs().len
      check ran == 1

      # An edit of the same length: the file's content is all that differs.
      writeFile(fx.app / "src" / "side.txt", "side v2\n")
      let edited = fx.contentNow()
      let second = fx.reproIn(["certify", "--tool-provisioning=path"])
      checkpoint(second.output)
      check second.code == 0
      check fx.executedOutputs().len == ran + 1
      check readFile(fx.app / "build" / "side-out") == "side v2\n"
      check fx.certificatesFor(edited, "side-suite").len == 1

      writeFile(fx.app / "src" / "side.txt", "FAIL now\n")
      let failing = fx.contentNow()
      let third = fx.reproIn(["certify", "--tool-provisioning=path"])
      checkpoint(third.output)
      check third.code != 0
      check fx.certificatesFor(failing, "side-suite").len == 0
      check fx.certificatesFor(failing, "test").len == 0

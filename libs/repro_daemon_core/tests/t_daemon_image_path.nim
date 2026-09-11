## `binary-path:` must name a file that is there.
##
## Distribution-And-Packaging M1's N21. Inside an AppImage, `repro daemon
## status` reported
##
##   binary-path: /usr/bin/repro.real
##
## on a host where `/usr/bin/repro.real` does not exist, while
## `source-image-path:` and `running-image-path:` on the SAME report
## carried the true `/tmp/.mount_<random>/usr/bin/repro.real`.
##
## The field was `getAppFilename()` and nothing else, so whatever the
## platform answered was printed unchecked. `daemonImagePath` is that
## field with a fallback chain, and each candidate is used only if it is
## on disk.
##
## AND WHY `getAppFilename()` ANSWERED THAT IS NO LONGER OPEN (M1's N27).
## Nim reads `/proc/self/exe` on Linux, and for a process whose image is on
## the AppImage's squashfuse mount the kernel answers the path WITH THE
## MOUNT POINT STRIPPED. Measured at this tip in `debian:trixie-slim` +
## `fuse3` (`--device /dev/fuse --cap-add SYS_ADMIN`):
## `readlink /proc/<daemon-pid>/exe` is `/usr/bin/repro.real`, the same
## process's `argv[0]` is `/tmp/.mount_reprobNdBCIC/usr/bin/repro.real`,
## and `/usr/bin/repro.real` does not exist on that host. So `argv[0]` --
## what `AppRun` execs with -- is the candidate that can answer, and
## `launchPath` is it.
##
## AND WHICH BRANCH AN APPIMAGE ACTUALLY TAKES IS M1's N30, INSTRUMENTED
## RATHER THAN REASONED ABOUT -- the eighth pass, in the same container
## shape, over the AppImage the seventh pass shipped (sha256
## aa9bdd0e...). The answer is NOT the first branch, which is what the
## record had narrowed it to. `repro daemon start` prints the TRUE
## `binary-path: /tmp/.mount_reprobHcELMl/usr/bin/repro.real`, because
## the process printing it still holds the mount. A later `repro daemon
## status` is a SECOND AppImage run asking the DAEMON, and by then the
## first run has exited and taken its squashfuse mount with it:
## `ls /tmp/.mount_*` answers "No such file or directory", the daemon's
## `/proc/<pid>/mountinfo` has ZERO entries mentioning it, and all four
## candidates fail `fileExists` -- the mount-stripped `/usr/bin/repro.real`,
## `argv[0]`, the configured source and the running image alike. So the
## proc ran off the END of the chain and returned `appFilename`
## unverified. `source-image-path:` and `running-image-path:` printed the
## true path on that same report because they are STRINGS CAPTURED AT
## DAEMON INIT and never re-checked, not because they resolved better.
## The fallback now promotes the launch path, and the AppImage arm of the
## milestone record is where that is shown on shipped bytes.
##
## WHAT N27's RECORD GOT WRONG, corrected here because this file is where
## it was written. It said `repro daemon status` on a running daemon
## "prints the HANDSHAKE's identity". It does not: `queryUserDaemonStatus`
## returns `parseStatusBody` of the `udkStatusResponse` frame, which is
## `statusFor` -- the producer N21 had ALREADY guarded -- and
## `connectUserDaemon` reads only `major` and `featureFlags` out of
## `parseHelloAck`. `parsed.daemon` is parsed and never read by any
## caller. The `handleHello` guard is correct hardening and stays; the
## file-versus-live disagreement it was credited with cannot arise on
## that path. Both call sites go through this proc regardless.
##
## WHAT THESE CASES DO AND DO NOT CLAIM. They are about the RESOLUTION,
## which is the part that can be tested anywhere. They do not run an
## AppImage; the AppImage measurement is in the milestone record.

import std/[os, unittest]

import repro_daemon_core/runtime

proc tempTree(): string =
  result = getTempDir() / "repro-n21-image-path"
  createDir(result)

suite "the daemon's reported image path is checked before it is printed":

  setup:
    let dir = tempTree()
    let present = dir / "present.bin"
    let alsoPresent = dir / "also-present.bin"
    writeFile(present, "x")
    writeFile(alsoPresent, "y")
    let absent = dir / "absent.bin"
    removeFile(absent)

  teardown:
    removeDir(dir)

  test "an existing app filename wins, unchanged":
    # The ordinary case, and the one that must not change: on every host
    # where the platform answers correctly the reported value is exactly
    # what it always was.
    doAssert daemonImagePath(present, alsoPresent, alsoPresent) == present

  test "an app filename naming nothing falls back to the launch path":
    # THE DEFECT. Before the fix this returned `absent` -- a status line
    # naming a file that is not there.
    doAssert daemonImagePath(absent, present, "") == present

  test "and then to the running image":
    doAssert daemonImagePath(absent, "", present) == present
    doAssert daemonImagePath(absent, absent, present) == present

  test "when nothing on the chain exists the platform's answer is kept":
    # Not blanked. A daemon that cannot find its own image on disk is a
    # real situation (a deleted or replaced binary), and an empty field
    # would be a worse report than an unverifiable one. With NO launch
    # path there is nothing better to say, so the platform's answer
    # stands -- and `sourceExe`/`runningImage` do NOT displace it, which
    # is deliberate: neither is on disk either, so neither is evidence.
    doAssert daemonImagePath(absent, absent, absent) == absent
    doAssert daemonImagePath(absent, "", "") == absent

  test "N30: with nothing on disk the LAUNCH path beats the platform's answer":
    # THE BRANCH AN APPIMAGE TAKES, and the one the record had ruled out.
    # By the time a live `repro daemon status` reaches the daemon, the
    # mount the daemon was launched from is gone, so EVERY candidate
    # fails `fileExists` -- including `argv[0]`. Before this, the chain
    # ran off its end and returned the mount-stripped
    # `/usr/bin/repro.real`: a path that never existed anywhere. `argv[0]`
    # at least names a location this image really did occupy.
    let gone = dir / "gone.bin"
    removeFile(gone)
    doAssert not fileExists(gone)
    doAssert daemonImagePath(absent, "", "", launchPath = gone) == gone
    # It is the FALLBACK, not a new winner: anything on disk still wins,
    # in the order it always did.
    doAssert daemonImagePath(present, "", "",
      launchPath = gone) == present
    doAssert daemonImagePath(absent, present, "",
      launchPath = gone) == present
    doAssert daemonImagePath(absent, "", present,
      launchPath = gone) == present
    # And an empty launch path still leaves the platform's answer alone,
    # which is the previous case's contract restated from this side.
    doAssert daemonImagePath(absent, "", "", launchPath = "") == absent

  test "an empty candidate is skipped rather than returned":
    doAssert daemonImagePath("", present, "") == present
    doAssert daemonImagePath("", "", present) == present

  test "the LAUNCH path answers when the platform's does not":
    # N27's arm. Inside an AppImage `getAppFilename()` is the AppDir-
    # relative path with the mount stripped, and `argv[0]` is the only
    # candidate carrying the mount point. It sits between the platform's
    # answer and the configured one, and it does NOT displace a platform
    # answer that is actually on disk.
    doAssert daemonImagePath(absent, "", "", launchPath = present) == present
    doAssert daemonImagePath(present, "", "", launchPath = alsoPresent) ==
      present
    doAssert daemonImagePath(absent, alsoPresent, "", launchPath = present) ==
      present
    # A launch path naming nothing is skipped like every other candidate.
    doAssert daemonImagePath(absent, alsoPresent, "", launchPath = absent) ==
      alsoPresent
    # ...and the default keeps every existing caller's behaviour.
    doAssert daemonImagePath(absent, present, "") == present

  test "daemonLaunchPath is absolute or empty, never a bare name":
    # It feeds a `fileExists` and then a status field, so a relative
    # `argv[0]` resolved against whatever the daemon's cwd happens to be
    # is exactly the kind of guess this chain exists to stop printing.
    let launch = daemonLaunchPath()
    # THE VACUITY FLOOR, added after the seventh-pass review pointed out
    # that everything below used to sit under `if launch.len > 0:` -- a
    # shape `check_vacuous_test_cases.py` cannot see, because the case
    # does have assertions. Both suite runners invoke this binary by an
    # absolute path, so an empty answer here is a regression in
    # `daemonLaunchPath` rather than an environment this case may skip.
    doAssert launch.len > 0, "argv[0] was not absolute: " & paramStr(0)
    doAssert isAbsolute(launch), launch
    # This binary was started by the suite runner, so argv[0] names a
    # real file; a value that did not would make the case vacuous.
    doAssert fileExists(launch), launch

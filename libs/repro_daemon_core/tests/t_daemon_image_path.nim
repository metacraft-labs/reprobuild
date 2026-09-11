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
## THE OTHER HALF OF N27 WAS NOT A PLATFORM QUESTION AT ALL. N21 guarded
## `statusFor`, which is what the STATUS FILE is written from, and left
## `handleHello` building the daemon's identity from a raw
## `getAppFilename()`. `repro daemon status` on a RUNNING daemon prints
## the HANDSHAKE's identity, so inside one AppImage run the status file
## said `binary=/tmp/.mount_<rand>/usr/bin/repro.real` and the live
## `binary-path:` said `/usr/bin/repro.real`. Both call sites now go
## through this proc.
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
    # would be a worse report than an unverifiable one.
    doAssert daemonImagePath(absent, absent, absent) == absent
    doAssert daemonImagePath(absent, "", "") == absent

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
    if launch.len > 0:
      doAssert isAbsolute(launch), launch
      # This binary was started by the suite runner, so argv[0] names a
      # real file; a value that did not would make the case vacuous.
      doAssert fileExists(launch), launch

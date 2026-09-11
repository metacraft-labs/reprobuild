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
## WHAT THESE CASES DO AND DO NOT CLAIM. They are about the RESOLUTION,
## which is the part that was missing and the part that can be tested
## anywhere. They do not reproduce the AppImage observation and they do
## not explain why `getAppFilename()` answered a prefix-rooted path under
## a FUSE mount -- that is still open and is recorded as such. What is
## closed is that a status field can no longer name a file the daemon
## never looked for.

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

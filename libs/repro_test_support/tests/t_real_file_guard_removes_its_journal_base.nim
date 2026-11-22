## `repro_test_support/real_file_guard`: a restore puts the saved files back,
## deletes its journal, and then deletes the journal base
## (`repro-test-real-file-journal`) when no other journal is left in it, but
## never a base that still holds another run's journal.
##
## The base matters to the Windows procedure that runs the legs which use
## the guard: it checks afterwards that the base is absent, which shows that
## every leg restored what it saved. Before the base was removed, a clean run
## left an empty base behind and that check could not tell a clean run from
## a dead one without listing the base's children.
##
## Also `pathsOutside`, which picks the files a leg must save: those that do
## not lie inside its scratch directory, a path on another drive included.
##
## Hermetic: every path is under a scratch directory, and the journal base is
## a directory named like the real one inside it (`saveRealFiles` takes the
## journal path, so nothing reads `%LOCALAPPDATA%` or `$XDG_STATE_HOME`). No
## mocks: the real save and restore, on real files.

import std/[os, tempfiles, unittest]

import repro_test_support/real_file_guard

suite "real_file_guard journal base":
  test "a restore removes its journal and the base it leaves empty":
    let scratch = createTempDir("real-file-guard-base", "")
    defer: removeDir(scratch)
    let base = scratch / "repro-test-real-file-journal"
    let target = scratch / "profile.ps1"
    writeFile(target, "original\n")
    let guard = saveRealFiles([target], base / "leg")
    check dirExists(base / "leg")
    writeFile(target, "changed by the leg\n")
    restoreRealFiles(guard)
    check readFile(target) == "original\n"
    check not dirExists(base / "leg")
    check not dirExists(base)

  test "a restore keeps a base that still holds another journal":
    let scratch = createTempDir("real-file-guard-base", "")
    defer: removeDir(scratch)
    let base = scratch / "repro-test-real-file-journal"
    let a = scratch / "a.ps1"
    let b = scratch / "b.ps1"
    writeFile(a, "a\n")
    writeFile(b, "b\n")
    let first = saveRealFiles([a], base / "first")
    let second = saveRealFiles([b], base / "second")
    restoreRealFiles(first)
    check not dirExists(base / "first")
    check dirExists(base / "second")
    check fileExists(base / "second" / "manifest.txt")
    restoreRealFiles(second)
    check not dirExists(base)

  test "a directory not named like the base is never removed":
    let scratch = createTempDir("real-file-guard-base", "")
    defer: removeDir(scratch)
    let parent = scratch / "some-other-parent"
    let target = scratch / "c.ps1"
    writeFile(target, "c\n")
    restoreRealFiles(saveRealFiles([target], parent / "leg"))
    check not dirExists(parent / "leg")
    check dirExists(parent)

  test "nothing to save writes no journal and no base":
    let scratch = createTempDir("real-file-guard-base", "")
    defer: removeDir(scratch)
    let base = scratch / "repro-test-real-file-journal"
    restoreRealFiles(saveRealFiles(newSeq[string](), base / "leg"))
    check not dirExists(base)

suite "real_file_guard pathsOutside":
  test "only paths outside the scratch directory are returned":
    let scratch = createTempDir("real-file-guard-outside", "")
    defer: removeDir(scratch)
    let inside = scratch / "home" / "Documents" / "Profile.ps1"
    # A sibling whose name only starts with the scratch's name is outside.
    let prefixed = scratch & "-other" / "Profile.ps1"
    let above = parentDir(scratch) / "Profile.ps1"
    check pathsOutside([inside, prefixed, above, scratch], scratch) ==
      @[prefixed, above]
    # A relative path cannot be placed: it counts as outside.
    check pathsOutside(["Documents" / "Profile.ps1"], scratch) ==
      @["Documents" / "Profile.ps1"]

  when defined(windows):
    test "a path on another drive is outside":
      # `relativePath` returns such a path unchanged, which `isRelativeTo`
      # reads as inside; the guard must save it.
      let scratch = createTempDir("real-file-guard-outside", "")
      defer: removeDir(scratch)
      let other = (if scratch[0] in {'D', 'd'}: "E:" else: "D:") &
        "\\Users\\someone\\Documents\\Profile.ps1"
      check pathsOutside([other], scratch) == @[other]

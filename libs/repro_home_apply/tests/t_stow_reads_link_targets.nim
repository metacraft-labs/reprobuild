## The stow materializer reads an existing link's target from the link, and
## never takes the link's own path for it (reprobuild-pm issue
## 2026-10-26-windows-stow-drift-names-the-link-itself-as-its-different-source).
##
## On Windows Nim's `os.expandSymlink` returns its argument, and the stow
## code used it in two places:
##
## * the drift DETAIL (`readLinkTargetBestEffort`, and the plan's own copy
##   of the call), which printed every conflicting link as pointing at
##   itself; and
## * a DECISION: `isRecordedStowTarget` recognises a link the current
##   generation made to a source that has since moved away (the link now
##   dangles) by comparing the link's text with the recorded source. On
##   Windows that text was the link's path, never the recorded source, so
##   Reprobuild's own unchanged link was refused as drift.
##
## Each case below holds on every host and failed on Windows before the fix;
## the POSIX run pins the behaviour `readlink` already gave. Real links in a
## fresh temporary directory, the real stow helpers; no mocks. On Windows the
## links need the symlink privilege or Developer Mode (eli-pc has it).

import std/[os, tempfiles, unittest]

import repro_home_generations
import repro_home_apply/stow

proc scratch(): string =
  result = createTempDir("repro-stow-link-target-", "")
  createDir(result / "profile" / "stow" / "pkg")
  createDir(result / "home")

proc cleanup(root: string) =
  try: removeDir(root) except OSError: discard

suite "stow reads where an existing link points":

  test "the detail names the link's target, absolute, never the link":
    let root = scratch()
    defer: cleanup(root)
    let other = root / "elsewhere.txt"
    writeFile(other, "unrelated\n")
    let link = root / "home" / ".rc"
    createSymlink(other, link)
    let shown = readLinkTargetBestEffort(link)
    # Positive control: what `expandSymlink` answered on Windows.
    check shown != link
    check shown == other

  test "a relative link is shown resolved against its own directory":
    let root = scratch()
    defer: cleanup(root)
    writeFile(root / "elsewhere.txt", "unrelated\n")
    let link = root / "home" / ".rc"
    createSymlink(".." / "elsewhere.txt", link)
    check readLinkTargetBestEffort(link) == root / "elsewhere.txt"

  test "a regular file has no link target":
    let root = scratch()
    defer: cleanup(root)
    writeFile(root / "home" / ".rc", "plain\n")
    check readLinkTargetBestEffort(root / "home" / ".rc") == ""

  test "a link to the source is the source; a link elsewhere is not":
    let root = scratch()
    defer: cleanup(root)
    let source = root / "profile" / "stow" / "pkg" / ".rc"
    writeFile(source, "wanted\n")
    let other = root / "elsewhere.txt"
    writeFile(other, "unrelated\n")
    createSymlink(source, root / "home" / ".good")
    createSymlink(other, root / "home" / ".bad")
    check linkPointsAtSource(root / "home" / ".good", source)
    check not linkPointsAtSource(root / "home" / ".bad", source)

  test "our own link to a source that moved away is recognised, not drift":
    let root = scratch()
    defer: cleanup(root)
    # The current generation linked `.rc` to `old/.rc`; the profile then
    # moved the file to `new/.rc` and `old/.rc` is gone, so the link dangles.
    let oldSource = root / "profile" / "stow" / "old" / ".rc"
    let newSource = root / "profile" / "stow" / "pkg" / ".rc"
    writeFile(newSource, "moved\n")
    let target = root / "home" / ".rc"
    createSymlink(oldSource, target)
    let rec = GeneratedFile(absoluteOutputPath: target,
      ownershipPolicy: gfoStowSymlink, stowSource: oldSource)
    check isRecordedStowTarget(target, newSource, rec)

  test "control: a link the generation did not record stays drift":
    let root = scratch()
    defer: cleanup(root)
    let oldSource = root / "profile" / "stow" / "old" / ".rc"
    let newSource = root / "profile" / "stow" / "pkg" / ".rc"
    writeFile(newSource, "moved\n")
    let target = root / "home" / ".rc"
    # Points somewhere else than the recorded source — someone else's link.
    createSymlink(root / "someone-elses.rc", target)
    let rec = GeneratedFile(absoluteOutputPath: target,
      ownershipPolicy: gfoStowSymlink, stowSource: oldSource)
    check not isRecordedStowTarget(target, newSource, rec)

  when not defined(windows):
    test "a dangling link whose text only LEXICALLY names the source is not it":
      # POSIX resolves `..` physically. `home/cfg` is a symlink to
      # `a/b/cfg`, so `home/cfg/.rc -> ../../profile/stow/pkg/.rc` really
      # leads to `a/profile/stow/pkg/.rc`, which does not exist. Joined
      # lexically to `home/cfg` the same text names the stow source. The
      # kernel's answer is the one that counts: neither the materializer's
      # "already correct" verdict nor the generation-ownership check may
      # be taken from the lexical join.
      let root = scratch()
      defer: cleanup(root)
      let source = root / "profile" / "stow" / "pkg" / ".rc"
      writeFile(source, "wanted\n")
      createDir(root / "a" / "b" / "cfg")
      createSymlink(root / "a" / "b" / "cfg", root / "home" / "cfg")
      let link = root / "home" / "cfg" / ".rc"
      let text = ".." / ".." / "profile" / "stow" / "pkg" / ".rc"
      createSymlink(text, link)
      # Control: the lexical join does name the source, and the link
      # really dangles.
      check normalizedPath(parentDir(link) / text) == source
      check not fileExists(link)
      check not linkPointsAtSource(link, source)
      let rec = GeneratedFile(absoluteOutputPath: link,
        ownershipPolicy: gfoStowSymlink, stowSource: source)
      check not isRecordedStowTarget(link, root / "elsewhere.rc", rec)

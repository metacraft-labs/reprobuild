## `fs.preserveTree` re-run over what an earlier run, or another writer, left
## in its output root.
##
## The output root of a preserveTree action is a CONTAINER directory output
## (Incremental-Invalidation, "Non-regular outputs"): the action owns the
## entries it mirrors, and other writers may add entries of their own. What a
## re-run finds there is therefore not guaranteed to be what it wrote last
## time. The defect these cases pin (seen staging CodeTracer's macOS dmg)
## is that the executor wrote each entry THROUGH whatever was already
## on its path: a symlink left at an ancestor of an entry sent the copy into
## the link's target -- there, into `/nix/store`, where it failed with
## `Permission denied` and could not be cleaned up without root -- and the
## stale entries of the previous run were unlinked only AFTER copying, by a
## path that could by then resolve through a symlink the same run had just
## created.
##
## Each case drives a real `bakPreserveTree` action through
## `executeBuiltinAction` -- the engine's own executor -- against a real
## directory tree in a fresh temporary root. Nothing is mocked: the source
## tree, the output tree, the symlinks and the read-only directory outside
## the root are all real filesystem objects, because the property under test
## is exactly how the executor treats them.
##
## On Windows a link to a directory that another writer left in the output
## tree is made as a directory junction, which needs no privilege, so the
## Windows branch of the no-follow removal is exercised there too. The cases
## that need a file symlink or a relative one -- which the source tree's
## links are -- are skipped there, with the reason.

import std/[algorithm, os, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip

import repro_build_engine

const NoUnprivilegedSymlinks =
  "this case needs a file symlink or a relative one, and creating either " &
    "on Windows needs a privilege the suite does not assume (the cases " &
    "with a directory link use a junction there instead)"

const
  SourceRoot = "src/tree"
  OutputRoot = "out/mirror"
  ActionId = "stage/mirror"

proc manifestOutput(): string =
  ".repro/preserve-tree/" & ActionId.replace('/', '_') & ".manifest"

proc fileEntry(relative: string): string =
  "file\t" & relative

proc symlinkEntry(relative, target: string): string =
  "symlink\t" & relative & "\t" & target

proc mirrorAction(root: string; entries: openArray[string]): BuildAction =
  ## The action shape the DSL's `fs.preserveTree` lowers to: the roots in
  ## `builtinText`, one encoded entry per mirrored path, and the manifest as
  ## one of its outputs.
  var outputs = @[OutputRoot, manifestOutput()]
  for raw in entries:
    outputs.add(OutputRoot & "/" & raw.split('\t')[1])
  builtinAction(bakPreserveTree, ActionId,
    cwd = root,
    outputs = outputs,
    text = SourceRoot & "\n" & OutputRoot,
    entries = entries,
    cacheable = false,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc runMirror(root: string; entries: openArray[string]): ActionResult =
  result = executeBuiltinAction(mirrorAction(root, entries))
  checkpoint("preserveTree status=" & $result.status & " stderr=" &
    result.stderr)

proc linkDirectory(target, link: string) =
  ## A link at `link` to the directory `target` (absolute): a symlink, or on
  ## Windows a directory junction, which an unprivileged process may create.
  when defined(windows):
    doAssert execShellCmd("cmd /c mklink /J \"" & link & "\" \"" & target &
      "\" > NUL") == 0, "mklink /J failed for " & link
  else:
    createSymlink(target, link)

proc isLink(path: string): bool =
  symlinkExists(path)

proc isRealDir(path: string): bool =
  dirExists(path) and not symlinkExists(path)

proc isRealFile(path: string): bool =
  fileExists(path) and not symlinkExists(path)

proc listing(dir: string): seq[string] =
  for kind, child in walkDir(dir, relative = true):
    result.add($kind & ":" & child)
  result.sort()

proc makeReadOnlyTree(dir: string) =
  ## A directory the build has no right to write into -- the stand-in for the
  ## `dr-xr-xr-x root wheel` store directory of the issue -- holding one
  ## read-only file of the same name as the entry the mirror is about to
  ## write.
  createDir(dir)
  writeFile(dir / "file.txt", "outside, must not change\n")
  setFilePermissions(dir / "file.txt", {fpUserRead, fpGroupRead, fpOthersRead})
  setFilePermissions(dir, {fpUserRead, fpUserExec, fpGroupRead, fpGroupExec,
    fpOthersRead, fpOthersExec})

proc makeWritable(dir: string) =
  ## Cleanup only: lets `removeDir` take the read-only tree down again.
  if dirExists(dir):
    setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
    for kind, child in walkDir(dir):
      if kind == pcFile:
        setFilePermissions(child, {fpUserRead, fpUserWrite})

suite "preserveTree re-run over its own previous output":

  test "a symlinked ancestor is replaced by a directory, never followed":
    let root = createTempDir("repro-preserve-ancestor-link-", "")
    let outside = createTempDir("repro-preserve-outside-", "")
    let readOnly = outside / "ro"
    defer:
      makeWritable(readOnly)
      removeDir(outside)
      removeDir(root)
    createDir(root / SourceRoot / "sub")
    writeFile(root / SourceRoot / "sub" / "file.txt", "from the source\n")
    makeReadOnlyTree(readOnly)
    let before = listing(readOnly)
    # What an earlier run (or an older staging) left behind: the entry's
    # parent directory is a link to a directory OUTSIDE the root.
    createDir(root / OutputRoot)
    linkDirectory(readOnly, root / OutputRoot / "sub")
    require isLink(root / OutputRoot / "sub")

    let res = runMirror(root, [fileEntry("sub/file.txt")])
    check res.status == asSucceeded
    check isRealDir(root / OutputRoot / "sub")
    check isRealFile(root / OutputRoot / "sub" / "file.txt")
    check readFile(root / OutputRoot / "sub" / "file.txt") ==
      "from the source\n"
    # The link's target is untouched.
    check listing(readOnly) == before
    check readFile(readOnly / "file.txt") == "outside, must not change\n"

  test "a regular file in the way of an entry's directory is replaced":
    let root = createTempDir("repro-preserve-ancestor-file-", "")
    defer: removeDir(root)
    createDir(root / SourceRoot / "sub")
    writeFile(root / SourceRoot / "sub" / "file.txt", "nested\n")
    createDir(root / OutputRoot)
    writeFile(root / OutputRoot / "sub", "a file where a directory goes\n")

    let res = runMirror(root, [fileEntry("sub/file.txt")])
    check res.status == asSucceeded
    check isRealDir(root / OutputRoot / "sub")
    check readFile(root / OutputRoot / "sub" / "file.txt") == "nested\n"

  test "a symlinked output root is replaced by a directory, never followed":
    let root = createTempDir("repro-preserve-root-link-", "")
    let outside = createTempDir("repro-preserve-outside-", "")
    defer:
      removeDir(outside)
      removeDir(root)
    createDir(root / SourceRoot)
    writeFile(root / SourceRoot / "file.txt", "from the source\n")
    writeFile(outside / "file.txt", "outside, must not change\n")
    createDir(root / "out")
    linkDirectory(outside, root / OutputRoot)
    require isLink(root / OutputRoot)

    let res = runMirror(root, [fileEntry("file.txt")])
    check res.status == asSucceeded
    check isRealDir(root / OutputRoot)
    check readFile(root / OutputRoot / "file.txt") == "from the source\n"
    check readFile(outside / "file.txt") == "outside, must not change\n"

  test "an entry that turns from a directory symlink into a directory":
    # Run 1 mirrors `dir-link -> real-dir`; the source then replaces the link
    # with a real directory holding a file. Run 2 must not write that file
    # through the mirrored link into `real-dir`, and must not leave the
    # declared output `dir-link/x.txt` missing by unlinking `dir-link`
    # after the copy.
    when defined(windows):
      skip(NoUnprivilegedSymlinks)
    else:
      let root = createTempDir("repro-preserve-link-to-dir-", "")
      defer: removeDir(root)
      let src = root / SourceRoot
      createDir(src / "real-dir")
      writeFile(src / "real-dir" / "a.txt", "a\n")
      createSymlink("real-dir", src / "dir-link")
      let first = runMirror(root, [fileEntry("real-dir/a.txt"),
        symlinkEntry("dir-link", "real-dir")])
      require first.status == asSucceeded
      require isLink(root / OutputRoot / "dir-link")

      removeFile(src / "dir-link")
      createDir(src / "dir-link")
      writeFile(src / "dir-link" / "x.txt", "x\n")
      let second = runMirror(root, [fileEntry("real-dir/a.txt"),
        fileEntry("dir-link/x.txt")])
      check second.status == asSucceeded
      check isRealDir(root / OutputRoot / "dir-link")
      check isRealFile(root / OutputRoot / "dir-link" / "x.txt")
      check readFile(root / OutputRoot / "dir-link" / "x.txt") == "x\n"
      check not fileExists(root / OutputRoot / "real-dir" / "x.txt")
      check readFile(root / OutputRoot / "real-dir" / "a.txt") == "a\n"

  test "an entry that turns from a directory into a directory symlink":
    # The reverse transition. Run 1 mirrors a real `dir-link/x.txt`; run 2
    # finds `dir-link -> real-dir`, and `real-dir/x.txt` exists too. The
    # previous run's stale `dir-link/x.txt` must be removed BEFORE the new
    # link is created: removed after, its path resolves through the link and
    # deletes the current entry `real-dir/x.txt`.
    when defined(windows):
      skip(NoUnprivilegedSymlinks)
    else:
      let root = createTempDir("repro-preserve-dir-to-link-", "")
      defer: removeDir(root)
      let src = root / SourceRoot
      createDir(src / "real-dir")
      writeFile(src / "real-dir" / "x.txt", "real\n")
      createDir(src / "dir-link")
      writeFile(src / "dir-link" / "x.txt", "old\n")
      let first = runMirror(root, [fileEntry("dir-link/x.txt"),
        fileEntry("real-dir/x.txt")])
      require first.status == asSucceeded

      removeDir(src / "dir-link")
      createSymlink("real-dir", src / "dir-link")
      let second = runMirror(root, [symlinkEntry("dir-link", "real-dir"),
        fileEntry("real-dir/x.txt")])
      check second.status == asSucceeded
      check isLink(root / OutputRoot / "dir-link")
      check expandSymlink(root / OutputRoot / "dir-link") == "real-dir"
      check isRealFile(root / OutputRoot / "real-dir" / "x.txt")
      check readFile(root / OutputRoot / "real-dir" / "x.txt") == "real\n"

  test "an entry that turns from a directory into a file":
    let root = createTempDir("repro-preserve-dir-to-file-", "")
    defer: removeDir(root)
    let src = root / SourceRoot
    createDir(src / "thing")
    writeFile(src / "thing" / "a.txt", "a\n")
    let first = runMirror(root, [fileEntry("thing/a.txt")])
    require first.status == asSucceeded

    removeDir(src / "thing")
    writeFile(src / "thing", "now a file\n")
    let second = runMirror(root, [fileEntry("thing")])
    check second.status == asSucceeded
    check isRealFile(root / OutputRoot / "thing")
    check readFile(root / OutputRoot / "thing") == "now a file\n"

  test "a destination symlink is replaced, not written through":
    when defined(windows):
      skip(NoUnprivilegedSymlinks)
    else:
      let root = createTempDir("repro-preserve-dest-link-", "")
      let outside = createTempDir("repro-preserve-outside-", "")
      defer:
        removeDir(outside)
        removeDir(root)
      createDir(root / SourceRoot)
      writeFile(root / SourceRoot / "file.txt", "from the source\n")
      writeFile(outside / "victim.txt", "outside, must not change\n")
      createDir(root / OutputRoot)
      createSymlink(outside / "victim.txt", root / OutputRoot / "file.txt")

      let res = runMirror(root, [fileEntry("file.txt")])
      check res.status == asSucceeded
      check isRealFile(root / OutputRoot / "file.txt")
      check readFile(root / OutputRoot / "file.txt") == "from the source\n"
      check readFile(outside / "victim.txt") == "outside, must not change\n"

  test "entries the action does not own are left alone":
    # Container semantics: another writer's entries in the output root --
    # CodeTracer copies `public/ui.js` into such a root -- survive a re-run,
    # including a directory link that is on no entry's path, whose target is
    # not touched either.
    let root = createTempDir("repro-preserve-foreign-", "")
    let outside = createTempDir("repro-preserve-outside-", "")
    defer:
      removeDir(outside)
      removeDir(root)
    createDir(root / SourceRoot / "sub")
    writeFile(root / SourceRoot / "sub" / "file.txt", "one\n")
    writeFile(outside / "kept.txt", "outside\n")
    let first = runMirror(root, [fileEntry("sub/file.txt")])
    require first.status == asSucceeded
    writeFile(root / OutputRoot / "ui.js", "another writer\n")
    writeFile(root / OutputRoot / "sub" / "extra.txt", "another writer\n")
    linkDirectory(outside, root / OutputRoot / "foreign-link")

    writeFile(root / SourceRoot / "sub" / "file.txt", "two\n")
    let second = runMirror(root, [fileEntry("sub/file.txt")])
    check second.status == asSucceeded
    check readFile(root / OutputRoot / "sub" / "file.txt") == "two\n"
    check readFile(root / OutputRoot / "ui.js") == "another writer\n"
    check readFile(root / OutputRoot / "sub" / "extra.txt") ==
      "another writer\n"
    check isLink(root / OutputRoot / "foreign-link")
    check readFile(outside / "kept.txt") == "outside\n"

  test "a file the source dropped is removed from the mirror":
    let root = createTempDir("repro-preserve-dropped-", "")
    defer: removeDir(root)
    createDir(root / SourceRoot / "debug")
    writeFile(root / SourceRoot / "debug" / "keep.svg", "keep\n")
    writeFile(root / SourceRoot / "debug" / "drop.svg", "drop\n")
    let first = runMirror(root, [fileEntry("debug/drop.svg"),
      fileEntry("debug/keep.svg")])
    require first.status == asSucceeded
    removeFile(root / SourceRoot / "debug" / "drop.svg")
    let second = runMirror(root, [fileEntry("debug/keep.svg")])
    check second.status == asSucceeded
    check not fileExists(root / OutputRoot / "debug" / "drop.svg")
    check readFile(root / OutputRoot / "debug" / "keep.svg") == "keep\n"

  test "an entry that would escape the output root is refused":
    let root = createTempDir("repro-preserve-escape-", "")
    defer: removeDir(root)
    createDir(root / SourceRoot)
    writeFile(root / "src" / "escaped.txt", "x\n")
    let res = runMirror(root, [fileEntry("../escaped.txt")])
    check res.status == asFailed
    check "outside" in res.stderr
    check not fileExists(root / "out" / "escaped.txt")

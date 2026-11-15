## An install mirror's realization id covers every property of its tree that
## the published prefix carries: a file's executable bit, a symbolic link's
## target text, and a directory's presence -- not only regular-file content.
##
## Issue: reprobuild-pm
## issues/2026-11-12-the-realization-hash-envelope-omits-the-recipe-itself-runtimedeps-and-environment-values.md
## ("editing a build: block without a version bump reuses the stale prefix";
## "different runtime-dep resolutions collide on one prefix").
##
## ``publishInstallMirrorToStore`` keys the prefix on a digest of the mirror
## tree. When that digest saw only regular-file bytes (a symlink was hashed by
## the CONTENT it resolved to, the exec bit and directories not at all), two
## builds of one package+version that differed only in those properties got
## ONE realization id, and the store's pre-flight -- the index already has a
## row for the id -- served the first build's prefix for the second. These
## cases are what a changed ``build:`` block or a different runtime-dep
## resolution produce in practice: a ``chmod +x`` added to an install step, a
## ``libfoo.so`` link re-pointed from ``libfoo.so.1`` to ``libfoo.so.2``, or a
## link into dependency A's prefix replaced by one into dependency B's whose
## file is byte-identical.
##
## Every case goes through the production entry point against a real temp
## store and asserts two things: the two mirrors get distinct realization
## ids, and the second publish's prefix carries the SECOND tree's property
## (so the stale first prefix was not served). No mocks.

import std/[algorithm, os, tempfiles, unittest]

import repro_local_store
import repro_project_dsl/install_mirror_publish

const WritePermissions = {fpUserWrite, fpGroupWrite, fpOthersWrite}

proc makeTreeWritable(root: string) =
  ## The publisher strips write bits from the prefix, and a hardlinked
  ## materialization shares inodes with the source mirror, so both trees
  ## need their write bits back before the scratch directory can go.
  if not dirExists(root):
    return
  var dirs = @[root]
  for entry in walkDirRec(root, yieldFilter = {pcFile, pcDir},
                          relative = true):
    let path = root / entry
    if dirExists(path):
      dirs.add(path)
    else:
      try:
        var p = getFilePermissions(path)
        for w in WritePermissions: p.incl(w)
        setFilePermissions(path, p)
      except OSError: discard
  dirs.sort(proc (a, b: string): int = cmp(b.len, a.len))
  for dir in dirs:
    var p = getFilePermissions(dir)
    p.incl(fpUserWrite)
    setFilePermissions(dir, p)

proc removeScratch(root: string) =
  try:
    makeTreeWritable(root)
    removeDir(root)
  except OSError:
    discard

proc publish(scratch, label, sourceDir: string): InstallMirrorPublishResult =
  ## Both mirrors are one package at one version, published into one store:
  ## exactly the situation of a rebuild with an edited recipe and no version
  ## bump.
  publishInstallMirrorToStore(scratch / ("recipes-" & label), "tiny",
    "1.0.0", sourceDir, scratch / "store")

suite "install-mirror realization id covers modes, links and directories":

  when not defined(windows):
    test "an exec-bit-only difference yields a distinct prefix with its mode":
      let scratch = createTempDir("im-realization-exec-", "")
      defer: removeScratch(scratch)
      let plain = scratch / "plain"
      let exec = scratch / "exec"
      for root in [plain, exec]:
        createDir(root / "bin")
        writeFile(root / "bin" / "tool", "#!/bin/sh\necho tool\n")
      var p = getFilePermissions(exec / "bin" / "tool")
      p.incl({fpUserExec, fpGroupExec, fpOthersExec})
      setFilePermissions(exec / "bin" / "tool", p)
      check fpUserExec notin getFilePermissions(plain / "bin" / "tool")

      let first = publish(scratch, "plain", plain)
      let second = publish(scratch, "exec", exec)
      checkpoint "first:  " & first.realizationHashHex & " " & first.absolutePath
      checkpoint "second: " & second.realizationHashHex & " " & second.absolutePath
      check first.realizationHashHex != second.realizationHashHex
      check first.absolutePath != second.absolutePath
      check fpUserExec in getFilePermissions(second.absolutePath / "bin" / "tool")
      check fpUserExec notin getFilePermissions(first.absolutePath / "bin" / "tool")

    test "a relative symlink re-pointed at a byte-identical sibling is distinct":
      let scratch = createTempDir("im-realization-link-", "")
      defer: removeScratch(scratch)
      let one = scratch / "one"
      let two = scratch / "two"
      for root in [one, two]:
        createDir(root / "lib")
        writeFile(root / "lib" / "libfoo.so.1", "ELF same bytes\n")
        writeFile(root / "lib" / "libfoo.so.2", "ELF same bytes\n")
      createSymlink("libfoo.so.1", one / "lib" / "libfoo.so")
      createSymlink("libfoo.so.2", two / "lib" / "libfoo.so")

      let first = publish(scratch, "one", one)
      let second = publish(scratch, "two", two)
      checkpoint "first:  " & first.realizationHashHex & " " & first.absolutePath
      checkpoint "second: " & second.realizationHashHex & " " & second.absolutePath
      check first.realizationHashHex != second.realizationHashHex
      check first.absolutePath != second.absolutePath
      check symlinkExists(second.absolutePath / "lib" / "libfoo.so")
      check expandSymlink(second.absolutePath / "lib" / "libfoo.so") ==
        "libfoo.so.2"
      check expandSymlink(first.absolutePath / "lib" / "libfoo.so") ==
        "libfoo.so.1"

    test "an absolute link into a different runtime dependency is distinct":
      # The runtime-dep case from the issue: the mirror links into a
      # dependency's prefix outside the tree, and two resolutions of that
      # dependency hold byte-identical files at different paths.
      let scratch = createTempDir("im-realization-dep-", "")
      defer: removeScratch(scratch)
      let depA = scratch / "deps" / "dep-A"
      let depB = scratch / "deps" / "dep-B"
      for dep in [depA, depB]:
        createDir(dep)
        writeFile(dep / "libdep.so", "ELF dependency bytes\n")
      let viaA = scratch / "via-a"
      let viaB = scratch / "via-b"
      createDir(viaA / "lib")
      createDir(viaB / "lib")
      createSymlink(depA / "libdep.so", viaA / "lib" / "libdep.so")
      createSymlink(depB / "libdep.so", viaB / "lib" / "libdep.so")

      let first = publish(scratch, "via-a", viaA)
      let second = publish(scratch, "via-b", viaB)
      checkpoint "first:  " & first.realizationHashHex & " " & first.absolutePath
      checkpoint "second: " & second.realizationHashHex & " " & second.absolutePath
      check first.realizationHashHex != second.realizationHashHex
      check first.absolutePath != second.absolutePath
      check expandSymlink(second.absolutePath / "lib" / "libdep.so") ==
        depB / "libdep.so"

  test "a directory-only difference yields a distinct realization id":
    # Only the id is asserted here: the store's materializer copies files
    # and file links, so the empty directory itself does not reach the
    # prefix (a separate gap; see the report that accompanied this test).
    let scratch = createTempDir("im-realization-dir-", "")
    defer: removeScratch(scratch)
    let bare = scratch / "bare"
    let withDir = scratch / "with-dir"
    for root in [bare, withDir]:
      createDir(root / "share")
      writeFile(root / "share" / "data", "data\n")
    createDir(withDir / "var" / "empty")

    let first = publish(scratch, "bare", bare)
    let second = publish(scratch, "with-dir", withDir)
    check first.realizationHashHex != second.realizationHashHex

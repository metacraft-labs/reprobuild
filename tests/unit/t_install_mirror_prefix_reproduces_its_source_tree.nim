## A published install-mirror prefix is the tree its realization id was
## computed from: a symbolic link to a directory stays a link, an empty
## directory is present, a symbolic link to a file stays a link with its
## target text, and an executable stays executable -- on the hardlink arm AND
## on the copy arm.
##
## Issue: reprobuild-pm
## issues/2026-11-15-store-materialization-drops-directory-links-and-empty-directories-and-the-copy-fallback-follows-symlinks.md
##
## Spec: reprobuild-pm ``spec/Local-Content-Addressed-Store.md``
## §"Write Protocol" step 3 (the laid-out stage is the realized tree, entry
## for entry) and §"Realization Hash (normative)" (the id determines the
## prefix's bytes, symbolic-link targets and directory presence included).
##
## ``publishInstallMirrorToStore`` keys the prefix on the source mirror's
## ``tree-v2`` digest, which covers directory links, empty directories and
## link target text. The store's ``materializeDirectory`` used to walk only
## files and file links, so a ``lib64 -> lib`` link and an empty directory
## never reached the prefix, and on the copy arm ``copyFile`` followed a file
## link and published the bytes it resolved to as a regular file, and dropped
## the executable bit (``copyFile`` creates the default mode). One source
## tree then published as two different trees, depending on whether the store
## and the source shared a filesystem.
##
## The property asserted is the strong one: ``storeTreeDigest`` of the
## published prefix equals ``storeTreeDigest`` of the source mirror. It also
## asserts that making the prefix read-only does not reach through a
## preserved link and strip the write bits of the file it points at.
##
## MOCK POLICY. The publish, the store and the filesystem are real. The one
## seam is ``materializeLinkAttemptHook``, the store's documented test seam,
## used in the copy-arm case to make every hardlink attempt report
## ``loCrossDevice`` -- what ``link(2)`` returns when the store and the source
## are on different filesystems, which a single temp directory cannot
## provide. It replaces only the link attempt; the copy that follows is the
## production copy path.

import std/[algorithm, os, tempfiles, unittest]

import repro_local_store
import repro_project_dsl/install_mirror_publish

const WritePermissions = {fpUserWrite, fpGroupWrite, fpOthersWrite}

proc makeTreeWritable(root: string) =
  ## The publisher strips write bits from the prefix, and a hardlinked
  ## materialization shares inodes with the source mirror.
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
    try:
      var p = getFilePermissions(dir)
      p.incl(fpUserWrite)
      setFilePermissions(dir, p)
    except OSError: discard

proc removeScratch(root: string) =
  try:
    makeTreeWritable(root)
    removeDir(root)
  except OSError:
    discard

proc makeMirror(root, depFile: string) =
  ## The three shapes the issue names, plus ordinary files so the hardlink
  ## arm has something to link.
  createDir(root / "usr" / "lib")
  writeFile(root / "usr" / "lib" / "libfoo.so.1", "ELF libfoo bytes\n")
  createSymlink("libfoo.so.1", root / "usr" / "lib" / "libfoo.so")
  # A link to a directory carrying the layout.
  createSymlink("lib", root / "usr" / "lib64")
  # A link to a file outside the tree (a runtime dependency's prefix).
  createSymlink(depFile, root / "usr" / "lib" / "libdep.so")
  # An empty directory.
  createDir(root / "var" / "empty")
  # An executable: the copy arm must carry the mode, as the hardlink arm
  # does by sharing the inode.
  createDir(root / "bin")
  writeFile(root / "bin" / "tool", "#!/bin/sh\necho tool\n")
  setFilePermissions(root / "bin" / "tool", {fpUserRead, fpUserWrite,
    fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

suite "an install-mirror prefix reproduces its source tree":

  when not defined(windows):
    for forceCopy in [false, true]:
      let arm = if forceCopy: "copy" else: "hardlink"
      test "directory links, empty directories and file links survive the " &
          arm & " arm":
        let scratch = createTempDir("im-prefix-tree-" & arm & "-", "")
        defer:
          materializeLinkAttemptHook = nil
          removeScratch(scratch)
        let dep = scratch / "deps" / "dep-A"
        createDir(dep)
        writeFile(dep / "libdep.so", "ELF dependency bytes\n")
        let mirror = scratch / "mirror"
        makeMirror(mirror, dep / "libdep.so")

        if forceCopy:
          materializeLinkAttemptHook = proc (src, dst: string): LinkAttempt =
            LinkAttempt(outcome: loCrossDevice,
              message: "test seam: the store is on another filesystem")

        let published = publishInstallMirrorToStore(scratch / "recipes",
          "tiny", "1.0.0", mirror, scratch / "store")
        let prefix = published.absolutePath
        checkpoint "prefix: " & prefix

        check symlinkExists(prefix / "usr" / "lib64")
        if symlinkExists(prefix / "usr" / "lib64"):
          check expandSymlink(prefix / "usr" / "lib64") == "lib"
        check dirExists(prefix / "var" / "empty")
        check symlinkExists(prefix / "usr" / "lib" / "libfoo.so")
        if symlinkExists(prefix / "usr" / "lib" / "libfoo.so"):
          check expandSymlink(prefix / "usr" / "lib" / "libfoo.so") ==
            "libfoo.so.1"
        check symlinkExists(prefix / "usr" / "lib" / "libdep.so")
        if symlinkExists(prefix / "usr" / "lib" / "libdep.so"):
          check expandSymlink(prefix / "usr" / "lib" / "libdep.so") ==
            dep / "libdep.so"
        check fpUserExec in getFilePermissions(prefix / "bin" / "tool")
        check storeTreeDigest(prefix) == storeTreeDigest(mirror)
        # The publisher makes the prefix read-only. ``chmod`` follows a
        # link, so a pass that touched the preserved ``libdep.so`` link
        # would have stripped the write bits of the dependency's own file.
        check fpUserWrite in getFilePermissions(dep / "libdep.so")

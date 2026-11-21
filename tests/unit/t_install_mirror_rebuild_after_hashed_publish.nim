## Regression: in hashed install-mirror mode a recipe could not be
## rebuilt in place. The install-mirror action makes the recipe's mirror
## read-only after publishing it (`emitInstallMirrorReadOnlyEnforcement`),
## and the next build of the same recipe begins by `rm -rf`-ing that
## mirror, which then fails with "Permission denied" — so changing any
## input of a hashed-mode recipe could never land it at a new prefix
## (Immutable-Install-Mirror-Prefixes.md §"Validation").
##
## Runs the real snippets with the real `sh`, against a real tree whose
## file is hardlinked into a stand-in store prefix, the way the store may
## realize a mirror. The unlock must make the mirror's DIRECTORIES
## writable so the rebuild can clear it, and must leave every FILE's mode
## alone, because a hardlinked file's mode is the store prefix's too.
##
## Root ignores a directory's write bit, so under euid 0 the fixture could
## not express the defect at all. There the tree is handed to an
## unprivileged uid and every snippet runs as that uid, so the case asserts
## the same thing whoever runs the suite.

import std/[os, osproc, tempfiles, unittest]

when defined(posix):
  import std/posix

import repro_project_dsl/install_mirror_resolver

const unprivilegedId = 65534 # nobody / nogroup

proc runningAsRoot(): bool =
  when defined(posix): geteuid() == 0
  else: false

when defined(posix):
  proc setgroups(size: csize_t; list: ptr Gid): cint
    {.importc, header: "<grp.h>".}

  proc shAsUnprivileged(script: string): int =
    ## Runs `sh -c script` with root's privileges dropped, so permission
    ## bits bind the way they do for an ordinary build user.
    let argv = allocCStringArray(["sh", "-c", script])
    defer: deallocCStringArray(argv)
    let pid = fork()
    if pid == 0:
      var gid = Gid(unprivilegedId)
      if setgroups(1, addr gid) != 0 or setgid(gid) != 0 or
          setuid(Uid(unprivilegedId)) != 0:
        exitnow(126)
      discard execvp("sh", argv)
      exitnow(127)
    var status: cint
    if pid < 0 or waitpid(pid, status, 0) != pid:
      return -1
    if WIFEXITED(status): int(WEXITSTATUS(status)) else: -1

proc sh(script: string): tuple[output: string; code: int] =
  when defined(posix):
    if runningAsRoot():
      return ("(ran as uid " & $unprivilegedId & "; output not captured)",
              shAsUnprivileged(script))
  let (output, code) = execCmdEx("sh -c " & quoteShell(script))
  (output, code)

proc fixtureDir(prefix: string): string =
  ## Under root the snippets run as `unprivilegedId`, which must be able to
  ## reach the fixture. The suite's TMPDIR and the dev shell's are private
  ## to root, so root's fixture goes directly under `/tmp`, which every uid
  ## can traverse.
  if runningAsRoot(): createTempDir(prefix, "", "/tmp")
  else: createTempDir(prefix, "")

proc handToSnippetUser(tmp: string): bool =
  ## Under root, gives the fixture to `unprivilegedId` and confirms that uid
  ## can enter it, so an unreachable fixture fails here, by name, rather
  ## than as a misleading assertion further on. Nothing to do otherwise.
  if not runningAsRoot():
    return true
  execCmd("chown -R -h " & $unprivilegedId & ":" & $unprivilegedId & " " &
          quoteShell(tmp)) == 0 and
    sh("cd " & quoteShell(tmp)).code == 0

suite "install mirror — a hashed-mode recipe rebuilds in place":
  test "the clear runs in exactly the modes that make the mirror read-only":
    # Legacy mode emits nothing, so legacy actions and their cache keys are
    # unchanged; every other mode leaves the mirror read-only and must clear
    # it, or its next build fails as the issue describes.
    let root = "/tmp/some/mirror"
    for mode in InstallMirrorMode:
      checkpoint $mode
      check (emitInstallMirrorClearPrevious(root, mode) == "") ==
        (emitInstallMirrorReadOnlyEnforcement(root, mode) == "")
      check (emitInstallMirrorClearPrevious(root, mode) == "") ==
        (mode == immLegacy)
    check emitInstallMirrorClearPrevious("", immHashed) == ""

  test "a first hashed build, with no previous mirror, clears nothing and succeeds":
    let tmp = fixtureDir("mirror-first-build-")
    # A space in the path, as a recipe directory may have one: an unquoted
    # expansion in the snippet would split it and skip the unlock.
    let mirror = tmp / "my recipe" / ".repro" / "output" / "install"
    require handToSnippetUser(tmp)
    let first = sh("set -e; " &
                   emitInstallMirrorClearPrevious(mirror, immHashed) &
                   ": > " & quoteShell(tmp / "reached"))
    checkpoint first.output
    check first.code == 0
    check fileExists(tmp / "reached")
    check not dirExists(mirror)
    removeDir(tmp)

  test "the read-only mirror is cleared after the unlock, store files stay read-only":
    let tmp = fixtureDir("mirror-rebuild-")
    # A space in the path, as a recipe directory may have one: an unquoted
    # expansion in the snippet would split it and skip the unlock.
    let mirror = tmp / "my recipe" / ".repro" / "output" / "install"
    createDir(mirror / "usr" / "bin")
    createDir(mirror / "usr" / ".hidden-dir")
    writeFile(mirror / "usr" / "bin" / "tool", "#!/bin/sh\n")
    # Populated, so only the hidden-entry globs can make it removable.
    writeFile(mirror / "usr" / ".hidden-dir" / "data", "")
    createDir(mirror / "usr" / "..dotdot-dir")
    writeFile(mirror / "usr" / "..dotdot-dir" / "data", "")
    writeFile(mirror / ".stamp", "")
    createDir(tmp / "store")
    createHardlink(mirror / "usr" / "bin" / "tool", tmp / "store" / "tool")
    createSymlink(tmp / "store", mirror / "usr" / "store-link")
    # A read-only store directory behind the symlink: following the link
    # would make it writable, which the unlock must never do.
    let readOnlyDir = {fpUserRead, fpUserExec, fpGroupRead, fpGroupExec,
                       fpOthersRead, fpOthersExec}
    require handToSnippetUser(tmp)
    setFilePermissions(tmp / "store", readOnlyDir)
    # The previous build's publish and enforcement.
    check sh(emitInstallMirrorReadOnlyEnforcement(mirror, immHashed)).code == 0
    check fpUserWrite notin getFilePermissions(mirror / "usr" / "bin")
    # Without the unlock, the rebuild's clobber fails: the defect.
    let before = sh("rm -rf " & quoteShell(mirror / "usr"))
    check before.code != 0
    check dirExists(mirror / "usr" / "bin")
    # With the clear, the whole previous mirror is gone, root files
    # included (the mirror action rewrites those in place), and a new one
    # can be laid out.
    # Under `set -e`, as the mirror action runs it, so a clear that leaves
    # anything behind fails here rather than in the next build.
    let after = sh("set -e; " &
                   emitInstallMirrorClearPrevious(mirror, immHashed) &
                   "mkdir -p " & quoteShell(mirror / "usr") & " && : > " &
                   quoteShell(mirror / ".stamp"))
    checkpoint after.output
    check after.code == 0
    check dirExists(mirror / "usr")
    check not dirExists(mirror / "usr" / "bin")
    check not dirExists(mirror / "usr" / ".hidden-dir")
    check not dirExists(mirror / "usr" / "..dotdot-dir")
    check readFile(mirror / ".stamp") == ""
    # The store's hardlinked file kept its read-only mode, and the
    # symlinked directory was not followed into the store.
    check fileExists(tmp / "store" / "tool")
    check fpUserWrite notin getFilePermissions(tmp / "store" / "tool")
    check fpUserWrite notin getFilePermissions(tmp / "store")
    discard execCmd("chmod -R u+w " & quoteShell(tmp))
    removeDir(tmp)

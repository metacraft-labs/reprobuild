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

import std/[os, osproc, tempfiles, unittest]

import repro_project_dsl/install_mirror_resolver

proc sh(script: string): tuple[output: string; code: int] =
  let (output, code) = execCmdEx("sh -c " & quoteShell(script))
  (output, code)

suite "install mirror — a hashed-mode recipe rebuilds in place":
  test "legacy mode emits no unlock, so legacy actions are unchanged":
    check emitInstallMirrorClearPrevious("/tmp/some/mirror", immLegacy) == ""
    check emitInstallMirrorClearPrevious("", immHashed) == ""

  test "the read-only mirror is cleared after the unlock, store files stay read-only":
    let tmp = createTempDir("mirror-rebuild-", "")
    let mirror = tmp / "recipe" / ".repro" / "output" / "install"
    createDir(mirror / "usr" / "bin")
    createDir(mirror / "usr" / ".hidden-dir")
    writeFile(mirror / "usr" / "bin" / "tool", "#!/bin/sh\n")
    writeFile(mirror / ".stamp", "")
    createDir(tmp / "store")
    createHardlink(mirror / "usr" / "bin" / "tool", tmp / "store" / "tool")
    createSymlink(tmp / "store", mirror / "usr" / "store-link")
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
    let after = sh(emitInstallMirrorClearPrevious(mirror, immHashed) &
                   "mkdir -p " & quoteShell(mirror / "usr") & " && : > " &
                   quoteShell(mirror / ".stamp"))
    checkpoint after.output
    check after.code == 0
    check dirExists(mirror / "usr")
    check not dirExists(mirror / "usr" / "bin")
    check readFile(mirror / ".stamp") == ""
    # The store's hardlinked file kept its read-only mode, and the
    # symlinked directory was not followed into the store.
    check fileExists(tmp / "store" / "tool")
    check fpUserWrite notin getFilePermissions(tmp / "store" / "tool")
    discard execCmd("chmod -R u+w " & quoteShell(tmp))
    removeDir(tmp)

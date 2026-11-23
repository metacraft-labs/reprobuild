## A sibling source root reaches a compile's command line spelled relative to
## the checkout, so its name is the same at every revision of the sibling.
##
## WHY THIS EXISTS. `repro.nim` puts every source-only root (io-mon, runquota,
## reprobuild-ct-test-runner, nimcrypto, nim-bearssl) on the `--path:` of every
## test compile, and the declared ones into its environment too. Both are in
## the weak fingerprint. The dev shell used to export a flake-overridden
## sibling as its content-hashed store copy, `/nix/store/<hash>-source/src`,
## so one commit to one sibling renamed a `--path:` element of every compile
## and all ~1,866 `.#test-builds` compiles missed — including those that never
## import the sibling (reprobuild-specs issue
## 2026-09-24-sibling-bump-invalidates-every-test-compile). The shell now
## exports the checkout path for an overridden sibling, and
## `workspaceRelativeSourcePath` spells it `../<sibling>/...`.
##
## ASSERTED, against the real helper:
##
##   1. A sibling checkout beside the project is spelled `../<sibling>/...`,
##      and the same sibling seen from a second worktree laid out the same way
##      gets the SAME spelling — which is what makes two such worktrees share a
##      weak key.
##   2. A directory inside the project is spelled relative to it.
##   3. A store path, a relative path, and a path outside the workspace are
##      returned UNCHANGED: a store path is already stable per pin (it is what
##      CI, which has no sibling checkouts, compiles), and a checkout somewhere
##      else is left as its owner named it.
##   4. A project directly under the filesystem root does not turn every
##      absolute path into a relative one.
##   5. The relative spelling names the same directory: resolved against the
##      project root it is the original path (checked on a real directory tree,
##      so the positive control is the filesystem, not the helper).

import std/[os, unittest]

import repro_dsl_stdlib/source_only_packages

suite "sibling source roots are spelled relative to the checkout":
  test "a sibling checkout becomes ../<sibling>, identically from two worktrees":
    check workspaceRelativeSourcePath("/ws/io-mon/src", "/ws/reprobuild") ==
      "../io-mon/src"
    check workspaceRelativeSourcePath("/ws/io-mon/src", "/ws/wt-other") ==
      "../io-mon/src"
    check workspaceRelativeSourcePath("/ws/runquota", "/ws/reprobuild") ==
      "../runquota"
    # A trailing separator or a `.` segment does not change the spelling.
    check workspaceRelativeSourcePath("/ws/./runquota/", "/ws/reprobuild/") ==
      "../runquota"

  test "a directory inside the project is spelled relative to it":
    check workspaceRelativeSourcePath("/ws/reprobuild/libs/nimcrypto",
      "/ws/reprobuild") == "libs/nimcrypto"

  test "store paths, relative paths and outside paths are left alone":
    const store = "/nix/store/fh122b7ccxfzqjp21y0h9vkjs71qw113-source/src"
    check workspaceRelativeSourcePath(store, "/ws/reprobuild") == store
    check workspaceRelativeSourcePath("../io-mon/src", "/ws/reprobuild") ==
      "../io-mon/src"
    check workspaceRelativeSourcePath("/elsewhere/io-mon/src",
      "/ws/reprobuild") == "/elsewhere/io-mon/src"
    check workspaceRelativeSourcePath("", "/ws/reprobuild") == ""
    check workspaceRelativeSourcePath("/ws/io-mon/src", "") == "/ws/io-mon/src"

  test "a project under the filesystem root does not relativize everything":
    check workspaceRelativeSourcePath(
      "/nix/store/abc-source/src", "/reprobuild") ==
      "/nix/store/abc-source/src"

  test "the relative spelling names the same directory on disk":
    let base = getTempDir() / "t_sibling_source_paths_" & $getCurrentProcessId()
    let project = base / "reprobuild"
    let sibling = base / "io-mon" / "src"
    createDir(project)
    createDir(sibling)
    writeFile(sibling / "io_mon.nim", "")
    try:
      let spelled = workspaceRelativeSourcePath(sibling, project)
      check spelled == "../io-mon/src"
      check fileExists(project / spelled / "io_mon.nim")
      check sameFile(project / spelled, sibling)
    finally:
      removeDir(base)

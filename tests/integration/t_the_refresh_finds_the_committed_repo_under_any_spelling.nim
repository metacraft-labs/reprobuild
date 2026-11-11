## NF-2 (Nix-Flake-Coexistence.md §3.1; Workspace-And-Develop-Mode.md
## §"VCS Hook Integration") — **the dirty-sibling scope of a flake-lock refresh
## finds the committed repo in the workspace membership however its path is
## spelled**.
##
## ## The defect this pins
##
## The refresh scopes its dirty-sibling check to the committed repo's develop
## set closure. To find that closure it has to know WHICH membership repo is
## being committed, and it answered that by comparing the `--current-repo`
## path with each member's `<workspace-root>/<path>` as STRINGS, after
## `absolutePath` on both — which neither resolves `.`/`..`, nor drops a
## trailing separator, nor follows a symlink, nor unifies separators. So the
## same directory spelled differently was "not a member of its own
## workspace": the closure was declared UNKNOWN and the check silently
## narrowed to the repos whose pins the refresh would move. On Windows the
## managed hook's own spelling (`git rev-parse --show-toplevel` prints
## `M:/m/...`, the membership join gives `M:\m\...`) hit it on every commit.
##
## In this fixture `app` depends on `epsilon`, which no flake input names. So
## `epsilon` is in the dirt scope ONLY when the closure was found, and its
## presence there is the observable difference.
##
## ## What is asserted
##
## For the canonical spelling (the control) and for each alias of the SAME
## directory — a trailing separator, a `.` segment, a `..` detour, and a path
## through a symlink to the workspace — the refresh:
##
##   1. does not report the closure as UNKNOWN; and
##   2. probes `epsilon`, the develop-set dependency that is not a flake input.
##
## Test-double policy: NO mocks, doubles or fakes. Real git checkouts, a real
## symlink, and the real `./build/bin/repro` run as `repro flake refresh-lock`
## with an explicit `--current-repo`. See `nf2_flake_lock_fixture.nim`.

import std/[os, strutils, unittest]

import nf2_flake_lock_fixture
import repro_test_support/reasoned_skip

suite "NF-2: the refresh finds the committed repo under any spelling":

  test "t_the_refresh_finds_the_committed_repo_under_any_spelling":
    if not nf2Prerequisites(
        "t_the_refresh_finds_the_committed_repo_under_any_spelling"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupNf2Fixture("spelling")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      let alias = fx.scratch / "ws-alias"
      createSymlink(fx.ws, alias)
      check expandFilename(alias) == expandFilename(fx.ws)

      # Joined by hand, not with `/`: `joinPath` would normalize the `.` and
      # `..` segments away before the spelling reached the binary.
      let spellings = [
        ("canonical", fx.app),
        ("trailing separator", fx.app & $DirSep),
        ("dot segment", fx.ws & $DirSep & "." & $DirSep & "app"),
        ("parent detour",
          fx.ws & $DirSep & "alpha" & $DirSep & ".." & $DirSep & "app"),
        ("symlinked workspace", alias / "app"),
      ]
      for (label, spelling) in spellings:
        checkpoint("spelling (" & label & "): " & spelling)
        let res = run(q(fx.repro) & " flake refresh-lock" &
          " --tool-provisioning=path" &
          " --workspace-root=" & q(fx.ws) &
          " --current-repo=" & q(spelling), cwd = fx.app)
        if res.code != 0 or res.output.contains("UNKNOWN") or
            "epsilon" notin res.output.split("dirt-scope: ")[^1]:
          checkpoint("refresh output for the " & label & " spelling:\n" &
            res.output)
        check res.code == 0
        check not res.output.contains("UNKNOWN")
        check res.output.contains("dirt-scope: ")
        check "epsilon" in
          res.output.split("dirt-scope: ")[^1].strip().split(",")

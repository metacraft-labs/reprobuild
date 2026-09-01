## NF-2 (Nix-Flake-Coexistence.md §3.1; Unified-Locking-And-Hooks.md §13.3) —
## **a sibling checked out as a linked git worktree is refreshed and is
## blocked on, exactly like an ordinary clone**.
##
## ## The defect this pins
##
## In an ordinary clone `.git` is a DIRECTORY. In a linked worktree — which is
## how `repro branch ../<name>` forks a workspace, and the shape M19's own lock
## code goes out of its way to anchor correctly — `.git` is a regular FILE
## holding a `gitdir:` pointer. Code that asks `dirExists(dir / ".git")`
## therefore answers "not a repo" for every linked worktree.
##
## Both NF-2 callers of that question failed OPEN in the dangerous direction:
##
##   1. the commit-path PRE-FILTER (`refreshFlakeLockAtCommit`) skipped the
##      input, found no candidate, and reported `up-to-date` — "nothing can
##      possibly have moved" — for a sibling that had in fact moved. The
##      pre-filter is only sound because it is a SUPERSET of the override set,
##      and this made it a strict subset: a needed refresh was silently
##      skipped, which is §3.1 reintroduced by the very mechanism added to
##      record it.
##   2. the DIRTY-SIBLING scope (`flakeRefreshDirtyScope`) dropped the repo, so
##      a worktree dependency with uncommitted work did not suppress the
##      refresh and its HEAD was filed anyway — a pin describing content
##      nobody else can obtain, which is the exact thing the inherited policy
##      forbids.
##
## Both are the "looks like it is working while doing nothing" shape, and
## neither is visible in the outcome: the log says `up-to-date`, which is also
## what a genuinely unchanged workspace says.
##
## ## What is asserted
##
##   1. a moved worktree sibling IS recorded by the commit-path hook (assert 1
##      is the pre-filter regression: before the fix the log said `up-to-date`
##      and the lock was untouched);
##   2. the worktree sibling appears in the reported `dirt-scope`, so it is
##      being probed rather than merely happening to pass;
##   3. a DIRTY worktree sibling suppresses the refresh, which is the second
##      caller — before the fix it did not block and the pin was filed.
##
## Test-double policy: NO mocks, doubles or fakes. A real `git worktree add`,
## real commits, and the real `./build/bin/repro` driven through the exact argv
## the `post-commit` dispatcher uses. See `nf2_flake_lock_fixture.nim`.

import std/[os, strutils, unittest]

import nf2_flake_lock_fixture

suite "NF-2: a worktree sibling is not invisible to the refresh":

  test "t_a_worktree_sibling_is_not_invisible_to_the_refresh":
    if not nf2Prerequisites(
        "t_a_worktree_sibling_is_not_invisible_to_the_refresh"):
      skip()
    else:
      let fx = setupNf2Fixture("worktree")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # ---- turn `alpha` into a LINKED WORKTREE at the same revision. -------
      # The workspace path `ws/alpha` keeps its name, its revision and its
      # `flake.nix`; only the SHAPE of its `.git` changes, from a directory to
      # a `gitdir:` file. Nothing else about the fixture moves, so anything
      # that behaves differently below does so purely because of that shape.
      let alphaDir = siblingDir(fx, "alpha")
      let host = fx.scratch / "alpha-host"
      discard requireCmd(q(fx.gitBin) & " clone -q " &
        q(originUrl(fx, "alpha")) & " " & q(host))
      discard requireCmd(q(fx.gitBin) & " -C " & q(host) &
        " config user.email tester@example.invalid")
      discard requireCmd(q(fx.gitBin) & " -C " & q(host) &
        " config user.name \"NF2 Tester\"")
      # Park the host clone on a throwaway branch: git refuses to check the
      # same branch out in two worktrees, and `main` is the one the workspace
      # path must end up holding.
      discard requireCmd(q(fx.gitBin) & " -C " & q(host) &
        " checkout -q -b parking")
      removeDir(alphaDir)
      discard requireCmd(q(fx.gitBin) & " -C " & q(host) &
        " worktree add -q " & q(alphaDir) & " main")
      discard requireCmd(q(fx.gitBin) & " -C " & q(alphaDir) &
        " config user.email tester@example.invalid")
      discard requireCmd(q(fx.gitBin) & " -C " & q(alphaDir) &
        " config user.name \"NF2 Tester\"")
      # The shape that breaks the naive check, asserted rather than assumed —
      # if a future git stops doing this the test must say so, not pass.
      check fileExists(alphaDir / ".git")
      check not dirExists(alphaDir / ".git")
      check headOf(fx, alphaDir) == fx.seedSha[0]

      # ---- (1) a moved worktree sibling is recorded. -----------------------
      let newAlpha = moveSibling(fx, "alpha", "revision 2")
      check newAlpha != fx.seedSha[0]
      let commit = tryCommitInApp(fx, "build against the worktree sibling")
      if commit.code != 0:
        checkpoint("git commit failed:\n" & commit.output)
      check commit.code == 0
      let after = readFile(lockPath(fx))
      let log = lastFlakeLogLine(fx)
      if not after.contains(newAlpha):
        checkpoint("the worktree sibling was INVISIBLE to the refresh.\n" &
          "log line: " & log & "\ncommit output:\n" & commit.output)
      check after.contains(newAlpha)
      check lockInCommit(fx) == after
      check fx.seedSha[0] notin nodeText(after, "alpha-src")
      check log.contains("flake-lock refreshed")
      # Stated directly: the pre-filter must not have short-circuited.
      check not log.contains("up-to-date")

      # ---- (2) it is inside the probed dirty scope. ------------------------
      check log.contains("dirt-scope: ")
      check "alpha" in log.split("dirt-scope: ")[^1].split(",")

      # ---- (3) a DIRTY worktree sibling suppresses the refresh. ------------
      let newBeta = moveSibling(fx, "beta", "revision 2")
      dirtySibling(fx, "alpha")
      check gitIn(fx, alphaDir, "status --porcelain").strip().len > 0
      let before = readFile(lockPath(fx))
      let second = tryCommitInApp(fx,
        "commit beside a dirty worktree sibling")
      check second.code == 0
      let blocked = readFile(lockPath(fx))
      if blocked != before:
        checkpoint("a dirty WORKTREE sibling did not block; log:\n" &
          preCommitLog(fx))
      check blocked == before
      check newBeta notin blocked
      check lastFlakeLogLine(fx).contains("skipped-dirty-sibling")
      check lastFlakeLogLine(fx).contains("alpha")

      # ---- (4) clean it, and the refresh resumes. --------------------------
      # So (3) is a scope result rather than a mechanism that stopped working.
      discard requireCmd(q(fx.gitBin) & " -C " & q(alphaDir) &
        " checkout -- marker.txt")
      let resumed = run(q(fx.repro) &
        " flake refresh-lock --all --tool-provisioning=path", cwd = fx.app)
      check resumed.code == 0
      check readFile(lockPath(fx)).contains(newBeta)

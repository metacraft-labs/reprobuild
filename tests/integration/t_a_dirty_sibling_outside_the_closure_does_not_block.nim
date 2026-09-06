## NF-2 (Workspace-And-Develop-Mode.md §"Reproducibility And `repro check`";
## RA-21's `developSetClosure`) — **the scoping rule**.
##
##   > an unrelated dirty repo elsewhere in the workspace MUST NOT block a push
##   > of `R`
##
## The dirty-sibling policy of the case next door is scoped to the committed
## repo's **dependency closure**, never to the workspace. A workspace here
## holds 138 repos; if any one of them being dirty suppressed every other
## repo's lock refresh, the refresh would in practice never run — and it would
## fail silently, which is the shape of every defect this campaign is about.
##
## ## The fixture's closure, and what sits either side of it
##
## `app`'s lock entry declares `depends = "alpha,beta,epsilon"`, so
## `developSetClosure(repos, "app")` is `{app, alpha, beta, epsilon}`:
##
##   * `delta` is a real workspace repo, a real checkout, and named by NO flake
##     input and NO `depends` edge — the "unrelated repo elsewhere in the
##     workspace" the rule is about. Dirty, it must NOT block;
##   * `epsilon` is IN the closure but is named by no flake input. Dirty, it
##     MUST block, because the policy is inherited verbatim and it speaks of a
##     develop-mode *dependency*, not of a lock entry;
##   * `alpha` is both a dependency and a flake input; the case next door
##     covers it.
##
## Asserting both sides matters. A scope that is too wide and a scope that is
## too narrow are different bugs, and a case that only pins one of them leaves
## the other free to move.
##
## ## Mutation (from the milestone): widen to every repo in the workspace ⇒ RED
##
## `delta`'s dirt then suppresses the refresh, and assert (1) reads the seed
## revision where `alpha`'s second commit was expected.
##
## Test-double policy: NO mocks, doubles or fakes. See the header of
## `nf2_flake_lock_fixture.nim`.

import std/[os, strutils, unittest]

import nf2_flake_lock_fixture

suite "NF-2: a dirty sibling outside the closure does not block":

  test "t_a_dirty_sibling_outside_the_closure_does_not_block":
    if not nf2Prerequisites(
        "t_a_dirty_sibling_outside_the_closure_does_not_block"):
      skip()
    else:
      let fx = setupNf2Fixture("closure")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      let newAlpha = moveSibling(fx, "alpha", "revision 2")

      # `delta`: a real, dirty, entirely unrelated repo of the same workspace.
      dirtySibling(fx, "delta")
      check gitIn(fx, siblingDir(fx, "delta"),
        "status --porcelain").strip().len > 0

      let commit = tryCommitInApp(fx,
        "commit beside an unrelated dirty repo")
      if commit.code != 0:
        checkpoint("git commit failed:\n" & commit.output)
      check commit.code == 0

      # ---- (1) the refresh happened anyway. -------------------------------
      let after = readFile(lockPath(fx))
      if not after.contains(newAlpha):
        checkpoint("log:\n" & preCommitLog(fx) & "\nlock:\n" & after)
      check after.contains(newAlpha)
      # …and the commit carries it.
      check lockInCommit(fx) == after
      check fx.seedSha[0] notin nodeText(after, "alpha-src")
      let log = lastFlakeLogLine(fx)
      check log.contains("flake-lock refreshed")
      check not log.contains("skipped-dirty-sibling")
      # `delta` is not even mentioned by the flake-lock line: it was never in
      # scope, so it was never probed. (Scoped to the flake-lock line rather
      # than to the whole log so an unrelated diagnostic that happens to name
      # a repo cannot decide this assertion either way.)
      check "delta" notin log
      # The scope, stated exactly: the three flake inputs backed by workspace
      # checkouts, plus `epsilon` (a declared dependency of `app`, reached
      # through `developSetClosure`). `delta` is absent, and so is `app` — a
      # repo is not its own dependency and `flake.lock` carries no pin for it.
      check log.contains("dirt-scope: alpha,beta,epsilon,gamma")

      # ---- (2) the other side of the scope: a closure member DOES block. --
      # `epsilon` is declared as a dependency of `app` and is named by no flake
      # input. The policy is about develop-mode DEPENDENCIES, so its dirt
      # suppresses the refresh even though `flake.lock` carries no pin for it.
      let newBeta = moveSibling(fx, "beta", "revision 2")
      dirtySibling(fx, "epsilon")
      let before = readFile(lockPath(fx))
      let second = tryCommitInApp(fx, "commit beside a dirty dependency")
      check second.code == 0
      let blocked = readFile(lockPath(fx))
      if blocked != before:
        checkpoint("log:\n" & preCommitLog(fx))
      check blocked == before
      check lockInCommit(fx) == before
      check newBeta notin blocked
      check lastFlakeLogLine(fx).contains("skipped-dirty-sibling")
      check lastFlakeLogLine(fx).contains("epsilon")

      # ---- (3) clean it, and the refresh resumes. -------------------------
      # So (2) is a scope result rather than a mechanism that stopped working.
      discard requireCmd(q(fx.gitBin) & " -C " &
        q(siblingDir(fx, "epsilon")) & " checkout -- marker.txt")
      let resumed = run(q(fx.repro) &
        " flake refresh-lock --all --tool-provisioning=path", cwd = fx.app)
      check resumed.code == 0
      check readFile(lockPath(fx)).contains(newBeta)
      # …and `delta` is STILL dirty throughout, having blocked nothing.
      check gitIn(fx, siblingDir(fx, "delta"),
        "status --porcelain").strip().len > 0

## NF-3 — **a sibling that is a LINKED WORKTREE is substituted, reported and
## gated exactly like an ordinary clone.**
##
## Spec: Nix-Flake-Coexistence.md §3.1 (a sibling ahead of its pin is a
## revision you publish without having built it) and §3.3; the shape itself is
## `repro branch ../<name>`, which forks a workspace by creating linked
## worktrees — so this is the ordinary state of every second workspace on a
## machine, not an exotic one.
##
## ## The distinction under test
##
## In an ordinary clone `.git` is a DIRECTORY. In a linked worktree it is a
## regular FILE holding a `gitdir:` pointer. Code that asks `dirExists(dir &
## "/.git")` therefore answers "not a repository" for every worktree, and every
## consumer of that answer fails OPEN in the dangerous direction: the input is
## dropped, nothing is substituted for it as far as the tool can see, and the
## report says the workspace is clean while nix builds from a checkout that has
## moved. That is §3.1 reintroduced quietly.
##
## `flakeSiblingIsGitCheckout` accepts both shapes, and until this case nothing
## in NF-3 exercised the second one: the mutation replacing it with
## `dirExists(…)` alone survived the whole NF-3 suite.
##
## ## What is asserted
##
##   1. the fixture really did produce the second shape — `.git` is a FILE, not
##      a directory. Without this the rest of the case could pass over an
##      ordinary clone and prove nothing;
##   2. the drift report NAMES the worktree sibling, with its distance;
##   3. `override-args` really substitutes it — so the shell is building it,
##      which is what makes (4) matter;
##   4. the pre-push gate REFUSES on it.
##
## ## Mutation
##
## `flakeSiblingIsGitCheckout` ⇒ `dirExists(extendedPath(dir / ".git"))` alone
## ⇒ RED on (2), (3) and (4): the input is reported "NOT substituted … not a
## git checkout", the arguments omit it, and the gate passes a push whose lock
## does not describe what was built.
##
## Test-double policy: NO mocks, doubles or fakes. The worktree is made by a
## real `git worktree add`. See the headers of `nf2_flake_lock_fixture.nim` and
## `nf3_override_state_fixture.nim`.

import std/[json, os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-3: a linked-worktree sibling is reported and gated":

  test "t_a_linked_worktree_sibling_is_reported_and_gated":
    const caseName = "t_a_linked_worktree_sibling_is_reported_and_gated"
    if not nf3Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("worktree")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      removePreCommitDispatch(fx)

      let seeded = makeSiblingALinkedWorktree(fx, "gamma")
      check seeded == fx.seedSha[2]

      # ---- (1) it really is the OTHER shape -------------------------------
      let dotGit = siblingDir(fx, "gamma") / ".git"
      check fileExists(dotGit)
      check not dirExists(dotGit)
      checkpoint("gamma/.git contents: " & readFile(dotGit).strip())
      check readFile(dotGit).strip().startsWith("gitdir:")
      # …and it is a flake, so nothing else can be the reason it binds.
      check fileExists(siblingDir(fx, "gamma") / "flake.nix")

      # Move it two commits ahead of the revision `flake.lock` pins.
      let gammaHead = advanceSibling(fx, "gamma", 2)
      check gammaHead != seeded

      # ---- (2) the report names it, with its distance ---------------------
      let status = flakeStatus(fx, "--json")
      check status.code == 0
      let doc = parseJson(status.stdout)
      checkpoint("report:\n" & pretty(doc, indent = 2))
      let row = statusRow(doc, "gamma-src")
      check not row.isNil
      if not row.isNil:
        check row["relation"].getStr() == "ahead"
        check row["aheadBy"].getInt() == 2
        check row["sibling"].getStr() == gammaHead
        check row["path"].getStr() == siblingDir(fx, "gamma")
      check doc["rows"].len == 3
      let text = flakeStatus(fx)
      checkpoint("override-status stderr:\n" & text.stderr)
      check text.stderr.contains("'gamma'")
      check text.stderr.contains("2 commit(s) AHEAD")
      check not text.stderr.contains("is not a git checkout")

      # ---- (3) the shell really is given it -------------------------------
      let args = flakeArgs(fx, "--all")
      checkpoint("override-args stdout: " & args.stdout)
      check args.code == 0
      check args.stdout.contains("--override-input gamma-src")
      check args.stdout.contains("git+file://" & siblingDir(fx, "gamma"))

      # ---- (4) and the gate refuses on it ---------------------------------
      publishRepo(fx, fx.app)
      publishRepo(fx, siblingDir(fx, "alpha"))
      publishRepo(fx, siblingDir(fx, "beta"))
      discard gitIn(fx, siblingDir(fx, "gamma"), "push -q origin HEAD:main")
      publishRepo(fx, siblingDir(fx, "delta"))
      publishRepo(fx, siblingDir(fx, "epsilon"))
      commitLockAndPublish(fx, "a lock that predates the worktree's commits")
      let gate = gatePrePush(fx)
      checkpoint("gate output:\n" & gate.output)
      check gate.code == 2
      check hasGateFailure(gate.report, "flake_lock_stale")
      if hasGateFailure(gate.report, "flake_lock_stale"):
        let evidence =
          gateFailureOf(gate.report, "flake_lock_stale")["evidence"].getStr()
        checkpoint("evidence: " & evidence)
        check evidence.contains("input=gamma-src")
        check evidence.contains("relation=ahead")
        check evidence.contains("ahead=2")

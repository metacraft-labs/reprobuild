## TC-8d — a certificate issued on a MODIFIED working tree covers the commit
## made from it afterwards, with no second run (test-certificates Standard
## §3.2.2: test, then commit).
##
## The tested working tree carries a tracked edit, an added (staged) file, a
## deleted file and an untracked scratch file. ``repro test --certify`` issues
## a certificate whose ``content`` is that tree's content id — computed here
## with git alone — and whose ``base`` is HEAD. Then, with nothing re-run:
##   1. ``git commit -a`` records exactly that content: the production
##      verifier (registered signature, content match, the lock read from the
##      content) reports the new commit COVERED;
##   2. a message-only ``git commit --amend``: still covered;
##   3. a rebase of that commit onto a moved base: NOT covered — the tree now
##      also carries the base's change;
##   4. a second certified edit committed by staging only part of it (one of
##      the two changed files, the non-interactive form of ``git add -p``):
##      NOT covered.
## A fifth case is the falsifiability row the milestone names: the siblings
## are checked against the ``repro.lock`` IN THE TESTED WORKING TREE, not
## HEAD's. lib-b moves, ``repro lock refresh`` re-pins it in the working tree
## WITHOUT committing, and issuance succeeds; committing it is then covered.
## Checking the siblings against HEAD's lock refuses that state.
##
## The project is a COMMITTED-LOCK project (no lock record store), which until
## TC-8d could be verified but could not issue.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the
## production verifier. Skip rule: ``git`` or ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_working_tree_fixture

suite "TC-8d — certify the working tree before committing":

  test "t_working_tree_certificate_covers_the_commit_made_from_it":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      var fx = setupCertifyFixture("tc8d-covers")
      defer: removeDir(fx.sib.scratch)
      let app = fx.sib.app
      # A tracked file the change will delete.
      writeFile(app / "doomed.txt", "about to go\n")
      discard fx.gitIn(app, "add doomed.txt")
      discard fx.gitIn(app, "commit -q -m doomed")
      let base = fx.sib.headOf(app)

      # ---- the modified working tree ------------------------------------
      writeFile(app / "README.md", "app fixture, edited\n")      # tracked edit
      writeFile(app / "added.txt", "a new file\n")               # added file
      discard fx.gitIn(app, "add added.txt")
      removeFile(app / "doomed.txt")                             # deleted file
      writeFile(app / "notes.scratch", "not part of anything\n")  # untracked
      let tested = fx.workingTreeContentId(app)
      check tested != treeContentId(fx.sib.gitBin, app, base)

      let fixtureJson = fx.writeFixtureJson("t-unit", "exit 0")
      let res = fx.certify(fixtureJson)
      checkpoint(res.output)
      check res.code == 0
      check fx.runs == 1
      let certs = fx.issuedFor(tested)
      check certs.len == 1
      if certs.len == 1:
        let cert = certs[0]
        check cert.vcs.content == tested
        check cert.vcs.base == base
        # The untracked scratch file was present, and this path captures no
        # read set: the default mode issues and says so.
        check cert.vcs.untracked
        check cert.isSigned
        check "t-unit" in cert.targets
      check "no read set was captured" in res.output

      # ---- 1. commit -a records the tested content: covered, no re-run ---
      discard fx.gitIn(app, "commit -q -a -m tested-change")
      let committed = fx.sib.headOf(app)
      check treeContentId(fx.sib.gitBin, app, committed) == tested
      let atCommit = fx.coverageAt(app, committed, "t-unit")
      checkpoint("at commit: untrusted=" & $atCommit.untrusted &
        " unevaluated=" & $atCommit.unevaluated)
      check atCommit.outcome == voCovered
      check fx.runs == 1

      # ---- 2. a message-only amend: still covered -----------------------
      discard fx.gitIn(app, "commit -q --amend -m reworded")
      let amended = fx.sib.headOf(app)
      check amended != committed
      check fx.coverageAt(app, amended, "t-unit").outcome == voCovered

      # ---- 3. rebased onto a moved base: not covered --------------------
      discard fx.gitIn(app, "checkout -q -b moved-base " & base)
      writeFile(app / "upstream-change.txt", "someone else's work\n")
      discard fx.gitIn(app, "add upstream-change.txt")
      discard fx.gitIn(app, "commit -q -m upstream")
      discard fx.gitIn(app, "checkout -q main")
      discard fx.gitIn(app, "branch -q kept-amended " & amended)
      discard fx.gitIn(app, "rebase -q moved-base")
      let rebased = fx.sib.headOf(app)
      check treeContentId(fx.sib.gitBin, app, rebased) != tested
      check fx.coverageAt(app, rebased, "t-unit").outcome != voCovered
      discard fx.gitIn(app, "reset -q --hard kept-amended")

      # ---- 4. part of a certified change committed: not covered ----------
      writeFile(app / "README.md", "app fixture, edited twice\n")
      writeFile(app / "added.txt", "a new file, edited\n")
      let second = fx.workingTreeContentId(app)
      let res2 = fx.certify(fixtureJson)
      checkpoint(res2.output)
      check res2.code == 0
      check fx.issuedFor(second).len == 1
      discard fx.gitIn(app, "add README.md")
      discard fx.gitIn(app, "commit -q -m partial")
      let partial = fx.sib.headOf(app)
      check treeContentId(fx.sib.gitBin, app, partial) != second
      check fx.coverageAt(app, partial, "t-unit").outcome != voCovered
      discard fx.gitIn(app, "commit -q -a -m rest")

      # ---- 5. the siblings are checked against the TESTED lock -----------
      # lib-b moves (published). HEAD's repro.lock still pins its old commit;
      # the working tree's is re-pinned and NOT committed. That is the lock
      # the tests run with, so issuance succeeds.
      discard fx.sib.advance("lib-b")
      let refreshed = runCmd(q(fx.sib.repro) & " lock refresh " & q(app))
      checkpoint(refreshed.output)
      check refreshed.code == 0
      check fx.gitIn(app, "status --porcelain repro.lock").strip().len > 0
      let relocked = fx.workingTreeContentId(app)
      let res3 = fx.certify(fixtureJson)
      checkpoint(res3.output)
      check res3.code == 0
      check fx.issuedFor(relocked).len == 1
      discard fx.gitIn(app, "commit -q -a -m relock")
      check fx.coverageAt(app, fx.sib.headOf(app), "t-unit").outcome ==
        voCovered

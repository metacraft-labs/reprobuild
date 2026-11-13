## TC-8d — a tested state with no honest content id (test-certificates
## Content-Id §3) yields no certificate, with the remedy for that state; the
## tests still run and the run's exit code is unchanged (Interactive-UX
## Principle 2).
##
## Each state is made with real git in the attested repository, and each is
## left again before the next:
##   1. an unmerged entry (a conflicted merge)          → "resolve the conflicts";
##   2. an assume-unchanged entry                       → "--no-assume-unchanged";
##   3. a skip-worktree entry whose file is present     → "--no-skip-worktree";
##   4. a submodule with modified tracked content       → "nested repository".
## And the boundary the codetracer review drew for case 4: a submodule whose
## only change is an UNTRACKED file is not modified content, and is certified.
##
## Falsifiability: issuing without the probe names a tree the working tree
## does not hold (an assume-unchanged edit is invisible to ``add --update``),
## and every case here then finds a certificate in the store.
##
## NO MOCKS: real repositories, the built ``repro``. Skip rule: ``git`` or
## ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support
import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_working_tree_fixture

proc expectWithheld(fx: CertifyFixture; fixtureJson, reason,
                    remedy: string) =
  let before = fx.runs
  let res = fx.certify(fixtureJson)
  checkpoint(res.output)
  check res.code == 0               # the passing test still ran and passed
  check fx.runs == before + 1
  check not fx.anyCertificateIssued()
  check "no certificate" in res.output
  check reason in res.output
  check remedy in res.output

suite "TC-8d — states with no content id are not certified":

  test "t_issuance_refuses_states_with_no_content_id":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      var fx = setupCertifyFixture("tc8d-no-content-id")
      defer: removeDir(fx.sib.scratch)
      let app = fx.sib.app
      let fixtureJson = fx.writeFixtureJson("t-unit", "exit 0")

      # ---- 1. unmerged entries ---------------------------------------------
      discard fx.gitIn(app, "checkout -q -b theirs")
      writeFile(app / "README.md", "theirs\n")
      discard fx.gitIn(app, "commit -q -a -m theirs")
      discard fx.gitIn(app, "checkout -q main")
      writeFile(app / "README.md", "ours\n")
      discard fx.gitIn(app, "commit -q -a -m ours")
      check runCmd(q(fx.sib.gitBin) & " -C " & q(app) &
        " merge -q theirs").code != 0
      fx.expectWithheld(fixtureJson, "unmerged entries", "resolve the conflicts")
      discard fx.gitIn(app, "merge --abort")

      # ---- 2. assume-unchanged ---------------------------------------------
      discard fx.gitIn(app, "update-index --assume-unchanged README.md")
      writeFile(app / "README.md", "edited behind git's back\n")
      fx.expectWithheld(fixtureJson, "assume-unchanged",
        "--no-assume-unchanged")
      discard fx.gitIn(app, "update-index --no-assume-unchanged README.md")
      discard fx.gitIn(app, "checkout -q -- README.md")

      # ---- 3. skip-worktree with the file present --------------------------
      discard fx.gitIn(app, "update-index --skip-worktree README.md")
      fx.expectWithheld(fixtureJson, "skip-worktree", "--no-skip-worktree")
      discard fx.gitIn(app, "update-index --no-skip-worktree README.md")

      # ---- 4. a submodule with modified content ----------------------------
      var libC = ""
      for (name, origin) in fx.sib.origins:
        if name == "lib-c": libC = origin
      discard fx.gitIn(app, "-c protocol.file.allow=always submodule add -q " &
        q(fileUrl(libC)) & " vendored")
      discard fx.gitIn(app, "commit -q -m vendored")
      let sub = app / "vendored"
      writeFile(sub / "README.md", "edited inside the submodule\n")
      fx.expectWithheld(fixtureJson, "nested repository has modified content",
        "inside the nested repository")
      discard fx.gitIn(sub, "checkout -q -- README.md")

      # ---- the boundary: only an untracked file inside the submodule --------
      writeFile(sub / "scratch.txt", "untracked inside the submodule\n")
      let content = fx.workingTreeContentId(app)
      let res = fx.certify(fixtureJson)
      checkpoint(res.output)
      check res.code == 0
      check fx.issuedFor(content).len == 1

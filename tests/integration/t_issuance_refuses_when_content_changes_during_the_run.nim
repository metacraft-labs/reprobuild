## TC-8d — one tested state (test-certificates Standard §3.2): the content id
## is computed before the first test command and after the last one, and a
## run during which the tested state changed yields no certificate.
##
##   1. A test command that rewrites a tracked file: no certificate, the
##      message names the file, and the run's exit code is unchanged (0 — the
##      test passed).
##   2. A test command that commits in a develop-mode sibling (lib-b): no
##      certificate, the message names the sibling. Siblings are outside the
##      content, so they are observed again after the run.
##   3. ``repro certify --check-set`` whose check set rewrites a tracked file
##      (an autofix): no certificate (exit 2, "not certifiable"). The content
##      comparison decides this, not a cleanliness check — the same check set
##      over the same modified-but-unchanging tree is certified.
##   4. Control: the same fixture with a command that changes nothing issues.
##
## Falsifiability: dropping the after-run content id issues in case 1, for
## content the tests never ran against.
##
## NO MOCKS: real repositories, the built ``repro``. Skip rule: ``git`` or
## ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support
import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_working_tree_fixture

suite "TC-8d — issuance needs one tested state":

  test "t_issuance_refuses_when_content_changes_during_the_run":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      var fx = setupCertifyFixture("tc8d-changes")
      defer: removeDir(fx.sib.scratch)
      let app = fx.sib.app
      writeFile(app / "README.md", "app fixture, modified before the run\n")
      let before = fx.workingTreeContentId(app)

      # ---- 1. a test rewrites a tracked file mid-run ----------------------
      let rewriting = fx.writeFixtureJson("t-rewrite",
        "echo 'written by the test' >> " & q(app / "README.md"))
      let res1 = fx.certify(rewriting)
      checkpoint(res1.output)
      check res1.code == 0                      # the test passed
      check fx.runs == 1
      check not fx.anyCertificateIssued()
      check "no certificate" in res1.output
      check "changed while the tests ran" in res1.output
      check "README.md" in res1.output
      check before in res1.output
      # Put the file back as it was before the run.
      writeFile(app / "README.md", "app fixture, modified before the run\n")
      check fx.workingTreeContentId(app) == before

      # ---- 2. a develop-mode sibling moves mid-run -------------------------
      let libB = fx.sib.ws / "lib-b"
      let moving = fx.writeFixtureJson("t-sibling",
        q(fx.sib.gitBin) & " -C " & q(libB) &
        " commit -q --allow-empty -m moved-during-the-run")
      let res2 = fx.certify(moving)
      checkpoint(res2.output)
      check res2.code == 0
      check fx.runs == 2
      check not fx.anyCertificateIssued()
      check "sibling changed while the tests ran" in res2.output
      check libB in res2.output
      discard fx.gitIn(libB, "reset -q --hard HEAD~1")

      # ---- 3. a check set that autofixes a tracked file --------------------
      let autofix = runShell(shellCommand(@[
        fx.sib.repro, "certify", "--check-set",
        "--check-set-command=echo reformatted >> " & q(app / "README.md"),
        "--workspace-root=" & fx.sib.ws,
        "--current-repo=" & app],
        daemonKeyEnv(fx.daemonKey, certifyKeyId)), app)
      checkpoint(autofix.output)
      check autofix.code == 2
      check not fx.anyCertificateIssued()
      check "changed while the tests ran" in autofix.output
      writeFile(app / "README.md", "app fixture, modified before the run\n")
      # The same modified tree, with a check set that leaves it alone, IS
      # certified: modification is not the reason.
      let steady = runShell(shellCommand(@[
        fx.sib.repro, "certify", "--check-set",
        "--check-set-command=true",
        "--workspace-root=" & fx.sib.ws,
        "--current-repo=" & app],
        daemonKeyEnv(fx.daemonKey, certifyKeyId)), app)
      checkpoint(steady.output)
      check steady.code == 0
      let checkSet = fx.issuedFor(before)
      check checkSet.len == 1
      if checkSet.len == 1:
        check checkSet[0].targets == @["pre-commit"]

      # ---- 4. control: a command that changes nothing issues --------------
      let quiet = fx.writeFixtureJson("t-quiet", "exit 0")
      let res4 = fx.certify(quiet)
      checkpoint(res4.output)
      check res4.code == 0
      var unit = false
      for cert in fx.issuedFor(before):
        if "t-quiet" in cert.targets: unit = true
      check unit

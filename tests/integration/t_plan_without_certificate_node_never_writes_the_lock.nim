## HL-10 — a plan without a certificate-producing node never writes a lock
## (Unified-Locking-And-Hooks.md §13.3: "Build-time refresh is rejected,
## except in a plan that produces a test certificate"; §13.7.3 item 6;
## §13.7.6 second obligation; Test-Certificates D15).
##
## Fixture: ``lock_update_node_fixture.nim`` (no certificate policy) with the
## managed hooks installed. lib-b advances after the lock was written, so the
## lock-update node WOULD re-pin. Then each of these leaves ``repro.lock``,
## the index and the lock-update log untouched:
##
##   * ``repro test lone-out`` — an unmarked sub-target, so the plan has no
##     certificate-producing node;
##   * ``repro test --no-certify`` and ``repro certify --no-certify`` — the
##     certificate opt-out adds no node;
##   * ``repro test --dry-run`` — a run that executes nothing adds no node.
##
## The commit-time hook then re-pins and stages the lock exactly as decided on
## 2026-09-30. A final control shows the same state is NOT left alone by a
## plain ``repro test`` (its plan has the implicit ``test`` node), so the
## cases above are not vacuous: adding the node to every plan reddens them.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider and engine, real ``git commit`` through the installed hooks.
## Skip rule: ``git`` or ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./lock_update_node_fixture

suite "HL-10 — no certificate-producing node, no lock write":

  test "t_plan_without_certificate_node_never_writes_the_lock":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test runs real repositories")
    else:
      var fx = setupLockUpdateFixture("hl10-noplan")
      defer: removeDir(fx.cf.sib.scratch)
      fx.ensureHooks()
      let ws = fx.cf.sib.ws
      let libBNext = fx.cf.sib.advance("lib-b")
      let lockBefore = fx.lockText()
      check libBNext notin lockBefore
      let indexBefore = fx.indexEntries()

      for args in [@["test", "lone-out"], @["test", "--no-certify"],
                   @["certify", "--no-certify"], @["test", "--dry-run"]]:
        let run = fx.reproIn(args & @["--tool-provisioning=path"])
        checkpoint("repro " & args.join(" ") & ":\n" & run.output)
        check run.code == 0
        check "lock-update" notin run.output
        check fx.lockText() == lockBefore
        check fx.indexEntries() == indexBefore
        check not fileExists(lockUpdateLogPath(ws))
      check fx.storedCount() == 0

      # The commit-time hook is still the writer for such plans.
      writeFile(fx.app / "README.md", "app fixture, edited\n")
      let commit = fx.gitApp("commit", "-a", "-m", "edit")
      checkpoint("git commit:\n" & commit.output)
      check commit.code == 0
      check libBNext in fx.mustGitApp("show", "HEAD:repro.lock")
      check "repro-lock re-pinned lib-b" in fx.preCommitLog()

      # Control: a plan WITH a certificate-producing node does write.
      let libBThird = fx.cf.sib.advance("lib-b")
      let control = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("control, repro test:\n" & control.output)
      check control.code == 0
      check libBThird in fx.lockText()
      check fileExists(lockUpdateLogPath(ws))

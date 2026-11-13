## HL-10 — a certifying run refreshes the committed locks BEFORE its tests
## (Unified-Locking-And-Hooks.md §13.3 amended, §13.7.3, §13.7.6 first
## obligation; Test-Certificates D14 (1), D15).
##
## Fixture: ``lock_update_node_fixture.nim`` with a ``required`` policy for
## ``test``, so the TC-8g gate refuses any commit no certificate covers, and
## the managed hooks installed by ``repro hooks ensure --vcs``. ``lockreader``
## is a test command whose input is ``repro.lock``: it records the lock the
## tests saw. Three states, each needing a different part of the re-pin, and
## for each a plain ``repro test`` followed by a plain ``git commit -a``:
##
##   A. lib-b advanced after the lock was written (a REVISION moved);
##   B. every revision matches, but lib-c's entry records a fetch ``url``
##      that is not its checkout's canonical one (§13.3: a re-observation
##      rewrites it);
##   C. every revision matches, and a (legacy) manifest edge names lib-d: the
##      writers plan NOTHING (§13.3 amended 2026-11-05: the re-pin adds no
##      entry; a dependency the recipe declares is added by `repro lock
##      refresh`, and the pre-push gate refuses a lock that lacks one). This
##      state used to expect lib-d to be added.
##
## In A and B: the run prints the change, the lock-update node rewrites
## ``repro.lock`` and stages it (and touches no other index entry), the test
## command reads the refreshed lock, the certificate names the content that
## includes it, and the commit leaves ``repro.lock`` byte-identical, records
## exactly the certified tree, and passes the TC-8g gate: the managed refresh
## found nothing to do. In C the run and the commit leave ``repro.lock``
## byte-identical and the certificate still covers the commit. B reddens if the node is narrowed to
## revisions; B and C also check the would-write predicate
## (``planCommitTimeLockWriters``) before the run.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider, engine and monitor, real ``git commit`` through the installed
## hooks, the production verifier. Skip rule: ``git`` or ``ssh-keygen``
## missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import repro_tool_profiles
import ./lock_update_node_fixture

proc certifyAndCommit(fx: WorkspaceCertifyFixture; label, expectChange,
                      expectInLock: string) =
  ## One state: ``repro test``, then ``git commit -a``, with every check.
  let before = fx.lockText()
  let otherEntries = fx.indexEntries(skipPaths = ["repro.lock"])
  let run = fx.reproIn(["test", "--tool-provisioning=path"])
  checkpoint(label & " — repro test:\n" & run.output)
  check run.code == 0
  check ("repro lock-update: " & expectChange) in run.output
  let after = fx.lockText()
  check after != before
  check expectInLock in after
  # Staged, and nothing else in the index was touched.
  check fx.stagedLock() == after
  check fx.indexEntries(skipPaths = ["repro.lock"]) == otherEntries
  # The test command ran against the refreshed lock.
  check fx.lockSeenByTests() == after
  # The certificate names the content that carries it.
  let content = fx.contentNow()
  let certs = fx.certificatesFor(content, "test")
  check certs.len == 1
  if certs.len == 1:
    check certs[0].vcs.content == content
  # The commit: nothing re-pinned, the tested tree recorded, the gate passes.
  let logBefore = fx.preCommitLog().len
  let commit = fx.gitApp("commit", "-a", "-m", label)
  checkpoint(label & " — git commit:\n" & commit.output)
  check commit.code == 0
  check fx.lockText() == after
  check fx.headContent() == content
  let appended = fx.preCommitLog().lastLinesSince(logBefore)
  checkpoint(label & " — pre-commit log:\n" & appended)
  check "repro-lock up-to-date" in appended
  check "re-pinned" notin appended
  check "certificate-gate covered" in appended
  check repinCauseLine notin commit.output

suite "HL-10 — the certifying run refreshes the lock before testing":

  test "t_certifying_run_refreshes_the_lock_before_testing":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "in real repositories")
    else:
      var fx = setupLockUpdateFixture("hl10-before", requireTest = true)
      defer: removeDir(fx.cf.sib.scratch)
      fx.ensureHooks()
      let ws = fx.cf.sib.ws

      # ---- A. a sibling revision moved -------------------------------------
      writeFile(fx.app / "README.md", "app fixture, edited for A\n")
      let libBNext = fx.cf.sib.advance("lib-b")
      check libBNext notin fx.lockText()
      fx.certifyAndCommit("A", "repro-lock re-pinned lib-b", libBNext)

      # ---- B. only a url is stale ------------------------------------------
      let realUrl = urlOf(fx.lockText(), "lib-c")
      let planted = fx.lockText().withUrl("lib-c",
        "file:///never-published/lib-c.git")
      writeFile(fx.app / "repro.lock", planted)
      writeFile(fx.app / "README.md", "app fixture, edited for B\n")
      # Committed past the hooks, so the stale url is what HEAD records.
      discard fx.mustGitApp("commit", "--no-verify", "-a", "-m", "plant B")
      check "never-published" in fx.lockText()
      let planB = planCommitTimeLockWriters(ws, fx.app, tpmPathOnly,
        PinRegressionAllowance())
      check planB.wouldWrite == @[fx.app / "repro.lock"]
      check planB.refused.len == 0
      writeFile(fx.app / "README.md", "app fixture, edited again for B\n")
      fx.certifyAndCommit("B", "repro-lock refreshed sibling coordinates",
        "url = \"" & realUrl & "\"")
      check "never-published" notin fx.lockText()

      # ---- C. the commit-time writers ADD no sibling -----------------------
      # A manifest edge app → lib-d used to be added here. A fragment declares
      # no dependency now (owner decision 2026-11-05), and adding one the
      # recipe declares needs the recipe's solve, which is `repro lock
      # refresh`'s job, not a re-pin's: with every pin current, the would-write
      # predicate plans nothing, and the lock still carries no lib-d.
      check depEntry(fx.lockText(), "lib-d").len == 0
      writeFile(ws / "repos" / "app.toml",
        readFile(ws / "repos" / "app.toml") & "depends = [\"lib-d\"]\n")
      let planC = planCommitTimeLockWriters(ws, fx.app, tpmPathOnly,
        PinRegressionAllowance())
      check planC.wouldWrite.len == 0
      check planC.refused.len == 0
      # And the certifying run agrees with the predicate: its lock-update
      # node writes nothing, the commit re-pins nothing, and the certificate
      # covers the commit with the lock exactly as it was.
      let beforeC = fx.lockText()
      writeFile(fx.app / "README.md", "app fixture, edited for C\n")
      let runC = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("C — repro test:\n" & runC.output)
      check runC.code == 0
      check fx.lockText() == beforeC
      check fx.stagedLock() == beforeC
      check fx.lockSeenByTests() == beforeC
      let contentC = fx.contentNow()
      check fx.certificatesFor(contentC, "test").len == 1
      let logBeforeC = fx.preCommitLog().len
      let commitC = fx.gitApp("commit", "-a", "-m", "C")
      checkpoint("C — git commit:\n" & commitC.output)
      check commitC.code == 0
      check fx.lockText() == beforeC
      check fx.headContent() == contentC
      let appendedC = fx.preCommitLog().lastLinesSince(logBeforeC)
      checkpoint("C — pre-commit log:\n" & appendedC)
      check "repro-lock up-to-date" in appendedC
      check "re-pinned" notin appendedC
      check "certificate-gate covered" in appendedC
      check depEntry(fx.lockText(), "lib-d").len == 0

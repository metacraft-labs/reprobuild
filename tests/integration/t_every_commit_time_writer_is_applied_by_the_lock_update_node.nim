## HL-10 — every writer the managed ``pre-commit`` hook can run is applied by
## the lock-update node, and is seen by the would-write predicate
## (Unified-Locking-And-Hooks.md §13.3, §13.6, §13.7.3 item 2, §13.7.6 fifth
## obligation).
##
## The hook's writers today are the ``repro.lock`` sibling re-pin and the
## ``flake.lock`` refresh. (Pre-Commit-Check-Sets PCS-5's managed block is not
## built; when it is, it becomes a third case here.) The hook and the node
## both call ONE step, ``applyCommitTimeLockWriters`` (the node with
## ``ctwsLockUpdateNode``), and the predicate is ``planCommitTimeLockWriters``.
## For each writer, a state in which THAT WRITER ALONE would write:
##
##   1. ``repro.lock`` (end to end): the ``lock_update_node_fixture`` workspace
##      with a ``required`` policy and the managed hooks; ``repro.lock``
##      records a ``ref`` for lib-c that names no published branch. The
##      predicate names exactly ``repro.lock``; ``repro test`` brings it
##      current and stages it; the certificate covers the content; and
##      ``git commit -a`` leaves the lock byte-identical and passes the gate.
##   2. ``flake.lock``: the NF-2 workspace (``nf2_flake_lock_fixture``), where
##      ``flake.nix`` inputs name develop-mode sibling flakes and the hook's
##      flake refresh is live; sibling ``alpha`` advances and is published.
##      The predicate names exactly ``flake.lock``; the node's writer step
##      (``applyCommitTimeLockWriters(ctwsLockUpdateNode, …)``, the call the
##      node's executor makes) rewrites and stages it; and a real
##      ``git commit`` through the installed hook leaves it byte-identical,
##      the hook logging ``flake-lock up-to-date``. This case drives the
##      node's step in-process rather than through ``repro test``: the NF-2
##      workspace is the shape in which a flake input is substituted by a
##      checkout (a manifest workspace keeps it pinned, so neither writer
##      would act), and it has no certificate-producing project.
##
## A writer added to the hook but not to the shared step would leave its
## state for the hook to write at commit time, which the gate refuses.
##
## NO MOCKS: real repositories, the built ``repro``, real ``git commit``
## through the installed hooks. ``nix`` itself is not run: the refresh
## rewrites ``flake.lock`` from git state, and the assertions are on its
## content (as in the NF-2 tests). Skip rule: ``git`` or ``ssh-keygen``
## missing, or ``./build/bin/repro`` unbuilt.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import repro_tool_profiles
import ./lock_update_node_fixture
from ./nf2_flake_lock_fixture as nf2 import nil

proc applyAndCommit(fx: WorkspaceCertifyFixture; label: string;
                    writes, keeps: string) =
  ## ``repro test`` then ``git commit -a``: ``writes`` is refreshed and staged
  ## by the node, ``keeps`` is left byte-identical, and the commit changes
  ## neither and is covered.
  let keptBefore = readFile(fx.app / keeps)
  let writtenBefore = readFile(fx.app / writes)
  let run = fx.reproIn(["test", "--tool-provisioning=path"])
  checkpoint(label & " — repro test:\n" & run.output)
  check run.code == 0
  let written = readFile(fx.app / writes)
  check written != writtenBefore
  check readFile(fx.app / keeps) == keptBefore
  check fx.mustGitApp("show", ":" & writes) == written
  let content = fx.contentNow()
  check fx.certificatesFor(content, "test").len == 1
  let logBefore = fx.preCommitLog().len
  let commit = fx.gitApp("commit", "-a", "-m", label)
  checkpoint(label & " — git commit:\n" & commit.output)
  check commit.code == 0
  check readFile(fx.app / writes) == written
  check readFile(fx.app / keeps) == keptBefore
  check fx.headContent() == content
  let appended = fx.preCommitLog().lastLinesSince(logBefore)
  checkpoint(label & " — pre-commit log:\n" & appended)
  check "certificate-gate covered" in appended
  check "staged into this commit" notin appended

suite "HL-10 — every commit-time writer is applied by the node":

  test "t_every_commit_time_writer_is_applied_by_the_lock_update_node":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0 or
        not nf2.nf2Prerequisites("t_every_commit_time_writer_is_applied_" &
          "by_the_lock_update_node"):
      skip("git or ssh-keygen not on PATH, or ./build/bin/repro unbuilt")
    else:
      # ---- 1. the repro.lock re-pin alone would write ----------------------
      block:
        var fx = setupLockUpdateFixture("hl10-writers", requireTest = true)
        defer: removeDir(fx.cf.sib.scratch)
        let ws = fx.cf.sib.ws
        fx.ensureHooks()
        writeFile(fx.app / "repro.lock",
          fx.lockText().withRef("lib-c", "never-published"))
        discard fx.mustGitApp("commit", "--no-verify", "-q", "-a", "-m",
          "plant a stale ref")
        let plan = planCommitTimeLockWriters(ws, fx.app, tpmPathOnly,
          PinRegressionAllowance())
        checkpoint("repro.lock plan: " & $plan.wouldWrite & " failures: " &
          $plan.failures)
        check plan.wouldWrite == @[fx.app / "repro.lock"]
        check plan.refused.len == 0
        check plan.failures.len == 0
        writeFile(fx.app / "README.md", "app fixture, edited\n")
        fx.applyAndCommit("repro.lock", writes = "repro.lock",
          keeps = "README.md")
        check "never-published" notin fx.lockText()

      # ---- 2. the flake.lock refresh alone would write ---------------------
      block:
        let fx = nf2.setupNf2Fixture("hl10-flake")
        defer: removeDir(fx.scratch)
        nf2.isolateNf2Config(fx)
        defer: nf2.releaseNf2Config()
        let lockPath = nf2.lockPath(fx)
        let moved = nf2.moveAndPublishSibling(fx, "alpha", "advanced")
        check moved notin readFile(lockPath)
        let plan = planCommitTimeLockWriters(fx.ws, fx.app, tpmPathOnly,
          PinRegressionAllowance())
        checkpoint("flake.lock plan: " & $plan.wouldWrite & " failures: " &
          $plan.failures)
        check plan.wouldWrite == @[lockPath]
        check plan.refused.len == 0
        check plan.failures.len == 0
        let outcome = applyCommitTimeLockWriters(ctwsLockUpdateNode, fx.ws,
          fx.app, tpmPathOnly, "hl10", PinRegressionAllowance())
        checkpoint("node step: written " & $outcome.written & " failures " &
          $outcome.failures & " not staged " & $outcome.notStaged)
        check outcome.written == @[lockPath]
        check outcome.refused.len == 0
        check outcome.failures.len == 0
        check outcome.notStaged.len == 0
        let refreshed = readFile(lockPath)
        check moved in refreshed
        check nf2.gitIn(fx, fx.app, "show :flake.lock") == refreshed
        check planCommitTimeLockWriters(fx.ws, fx.app, tpmPathOnly,
          PinRegressionAllowance()).wouldWrite.len == 0
        let logBefore = nf2.preCommitLog(fx).len
        let commit = nf2.tryCommitInApp(fx, "after the node")
        checkpoint("git commit:\n" & commit.output)
        check commit.code == 0
        check readFile(lockPath) == refreshed
        check nf2.gitIn(fx, fx.app, "show HEAD:flake.lock") == refreshed
        let appended = nf2.preCommitLog(fx).lastLinesSince(logBefore)
        checkpoint("pre-commit log:\n" & appended)
        check "flake-lock up-to-date" in appended
        check "staged into this commit" notin appended

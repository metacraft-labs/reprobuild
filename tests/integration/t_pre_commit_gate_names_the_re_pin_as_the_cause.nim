## TC-8g — when THIS commit's managed lock refresh re-pinned and staged a
## lock, the certificate gate's "uncovered" diagnostic names that re-pin as
## the cause (Unified-Locking-And-Hooks §13.3 amended, §13.7; HL-10's second
## test reads this line).
##
## Fixture: ``committed_lock_siblings_fixture.nim`` (a real manifest
## workspace, app → lib-b → lib-c), with a ``required`` certificate policy
## recorded in app's committed ``repro.lock`` (TC-9d) and the hooks
## ``repro hooks ensure --vcs`` installs.
## No certificate exists, so every commit is uncovered; what is asserted is
## WHY the gate says so:
##
##   1. nothing moved: the commit is refused and no re-pin is named;
##   2. lib-b advanced: the refresh re-pins and stages ``repro.lock``, the
##      gate refuses and names that re-pin as the cause;
##   3. the retry: the lock is already re-pinned (staged by the refused
##      attempt), this commit's refresh writes nothing, and the gate — still
##      refusing — no longer names a re-pin. A note an earlier attempt left
##      is never attributed to a later commit.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, real
## ``git commit``. Skip rule: ``git`` missing.

import std/[os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import repro_lock/certificate_policy
import repro_workspace_manifests
import ./committed_lock_siblings_fixture
import ./every_branch_policy

const causeLine = "this commit's lock refresh re-pinned and staged repro.lock"

proc requireCertificates(fx: SiblingFixture) =
  ## Record a ``required`` certificate policy in app's committed
  ## ``repro.lock`` — the only place a gate reads one since TC-9d. The
  ## snapshot is one rule for every branch (t-unit, required on this
  ## platform),
  ## rendered by the production renderer and spliced in by the production
  ## splicer, then committed with ``--no-verify`` (the policy commit is not
  ## what a case judges).
  let path = fx.app / "repro.lock"
  let snapshot = everyBranchSnapshot(pmRequired, ["t-unit"],
    [currentPlatformTag()], name = "app")
  writeFile(path, replaceCertificatePolicySection(readFile(path), snapshot))
  discard fx.git(fx.app, "add repro.lock")
  discard fx.git(fx.app, "commit --no-verify -q -m " & q("certificate policy"))

proc commitInApp(fx: SiblingFixture; label: string):
    tuple[code: int; output: string] =
  writeFile(fx.app / (label & ".txt"), label & "\n")
  discard fx.git(fx.app, "add " & q(label & ".txt"))
  runCmd("env REPROBUILD_REPRO=" & q(fx.repro) & " " & q(fx.gitBin) &
    " -C " & q(fx.app) & " commit -m " & q(label))

suite "TC-8g — the gate names this commit's re-pin as the cause":

  test "t_pre_commit_gate_names_the_re_pin_as_the_cause":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var fx = setupSiblingFixture("tc8g-repin")
      defer: removeDir(fx.scratch)
      putEnv("TEST_CERTIFICATES_DIR", fx.scratch / "store-user")
      putEnv("TEST_CERTIFICATES_SYSTEM_DIR", fx.scratch / "store-system")
      fx.refreshAndPublishLock()
      fx.requireCertificates()
      let ensured = runCmd("env REPROBUILD_REPRO=" & q(fx.repro) & " " &
        q(fx.repro) & " hooks ensure --vcs " & q(fx.app))
      checkpoint(ensured.output)
      check ensured.code == 0

      # ---- 1. nothing moved: uncovered, no re-pin named --------------------
      let head0 = fx.headOf(fx.app)
      let c1 = fx.commitInApp("unrelated")
      checkpoint("nothing moved:\n" & c1.output)
      check c1.code != 0
      check fx.headOf(fx.app) == head0
      check "no trusted certificate covers" in c1.output
      check causeLine notin c1.output

      # ---- 2. lib-b advanced: the re-pin is named as the cause -------------
      let libBNext = fx.advance("lib-b")
      let c2 = fx.commitInApp("after-lib-b")
      checkpoint("lib-b advanced:\n" & c2.output)
      check c2.code != 0
      check fx.headOf(fx.app) == head0
      check "no trusted certificate covers" in c2.output
      check causeLine in c2.output
      # The refresh did stage it: the index carries the new pin.
      check libBNext in fx.git(fx.app, "show :repro.lock")

      # ---- 3. the retry: nothing re-pinned now, nothing named --------------
      let c3 = runCmd("env REPROBUILD_REPRO=" & q(fx.repro) & " " &
        q(fx.gitBin) & " -C " & q(fx.app) & " commit -m retry")
      checkpoint("retry:\n" & c3.output)
      check c3.code != 0
      check "no trusted certificate covers" in c3.output
      check causeLine notin c3.output

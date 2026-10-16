## TC-9b with HL-10 — the certifying run's lock-update node records the
## policy snapshot, the commit-time hook carries it untouched, and a stale
## snapshot is reported (Test-Certificates.md §"The policy snapshot in
## `repro.lock`": "Who writes it", "Staleness is reported, not repaired at
## commit"; Unified-Locking-And-Hooks HL-10).
##
## Fixture: ``lock_update_node_fixture.nim`` (a real manifest workspace, app →
## lib-b → lib-c, lib-d, the managed hooks installed). On top of it, lib-b
## becomes the SHARED POLICY PACKAGE: it carries
## ``policy/team_policy.nim``. app imports that module and enacts the
## policy; its ``test`` aggregate is the certificate the policy requires.
##
##   1. A plain ``repro test``: the lock-update node re-pins lib-b AND records
##      the snapshot (naming ``lib-b``), stages repro.lock, the tests read
##      that lock, and a certificate is issued for the content carrying it.
##      ``git commit -a`` then finds nothing to do (``repro-lock
##      up-to-date``), leaves the lock byte-identical and records the tested
##      tree. ``repro health`` reports the snapshot current.
##   2. lib-b's policy changes (a new published revision). ``repro health``
##      reports ``certificate_policy_snapshot_stale`` as a WARNING with the
##      remedy ``repro lock refresh`` -- never a failure.
##   3. A commit in app: the hook re-pins lib-b and does NOT write the
##      snapshot -- it is byte-identical to the one step 1 recorded, although
##      the pin moved.
##   4. ``repro test`` again: the node rewrites the snapshot to the new rule
##      ("snapshot updated") and the next commit leaves it as the node wrote
##      it. Health is current again.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider, engine and monitor, real ``git commit`` through the installed
## hooks. Skip rule: ``git`` or ``ssh-keygen`` missing.

import std/[json, os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import repro_test_support
import repro_lock/certificate_policy

import ./lock_update_node_fixture

proc teamPolicy(mode: string): string =
  "import repro_certificates\n\n" &
    "const teamPolicy* = certificatePolicy \"team\":\n" &
    "  rule \"main\":\n" &
    "    gateMode " & mode & "\n" &
    "    requires \"test\"\n"

proc healthRow(fx: WorkspaceCertifyFixture): JsonNode =
  ## ``repro health app --json``'s ``certificate-policy-snapshot`` row, or nil.
  let res = runShell(shellCommand(@[fx.cf.sib.repro, "health", "app",
    "--json", "--workspace-root=" & fx.cf.sib.ws],
    @[(name: "REPROBUILD_REPRO", value: fx.cf.sib.repro)]), fx.app)
  checkpoint("repro health:\n" & res.output)
  let start = res.output.find("{")
  if start < 0:
    return nil
  for entry in parseJson(res.output[start .. ^1])["checks"]:
    if entry["name"].getStr() == "certificate-policy-snapshot":
      return entry
  nil

proc snapshotOf(lock: string): string =
  splitCertificatePolicySection(lock).policySection

suite "TC-9b — the node records the snapshot, the hook carries it":

  test "t_certifying_run_records_the_policy_snapshot_the_hook_carries":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen is not on PATH; this test signs certificates " &
        "in real repositories")
    else:
      let fx = setupLockUpdateFixture("tc9b-node")
      let libB = fx.cf.sib.ws / "lib-b"
      # lib-b becomes the shared policy package.
      createDir(libB / "policy")
      writeFile(libB / "policy" / "team_policy.nim", teamPolicy("advisory"))
      discard fx.cf.gitIn(libB, "add -A")
      discard fx.cf.gitIn(libB, "commit -q -m policy")
      discard fx.cf.gitIn(libB, "push -q origin main")
      # app adopts it. lib-b is already a develop-set sibling the lock pins;
      # this fixture's recipe gets its typed tool through `usesImportPath`,
      # which takes over `uses:` imports, so the policy module is imported by
      # its path in the sibling checkout (the `uses:` import itself is what
      # the other TC-9b tests exercise).
      let recipe = readFile(fx.app / "repro.nim")
      writeFile(fx.app / "repro.nim", recipe.replace(
        "import repro_project_dsl\n",
        "import repro_project_dsl\nimport \"../lib-b/policy/team_policy\"\n").replace(
        "  uses:\n", "  enactCertificatePolicy teamPolicy\n  uses:\n"))
      discard fx.mustGitApp("commit", "-q", "-a", "-m", "adopt the policy")
      fx.ensureHooks()
      let libBPin1 = fx.cf.sib.headOf(libB)

      # (1) The node records the snapshot; the commit carries it.
      let run1 = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("repro test (1):\n" & run1.output)
      check run1.code == 0
      check "repro lock-update: repro.lock: certificate policy snapshot " &
        "recorded" in run1.output
      let lock1 = fx.lockText()
      let snapshot1 = snapshotOf(lock1)
      check "name = \"team\"" in snapshot1
      check "package = \"lib-b\"" in snapshot1
      check "gate_mode = \"advisory\"" in snapshot1
      check ("revision = \"" & libBPin1 & "\"") in depEntry(lock1, "../lib-b")
      check fx.stagedLock() == lock1
      check fx.lockSeenByTests() == lock1
      let content1 = fx.contentNow()
      check fx.certificatesFor(content1, "test").len == 1
      let logBefore1 = fx.preCommitLog().len
      let commit1 = fx.gitApp("commit", "-a", "-m", "certified")
      checkpoint("git commit (1):\n" & commit1.output)
      check commit1.code == 0
      check fx.lockText() == lock1
      check fx.headContent() == content1
      check "repro-lock up-to-date" in
        fx.preCommitLog().lastLinesSince(logBefore1)
      let row1 = fx.healthRow()
      check not row1.isNil
      if not row1.isNil:
        check row1["status"].getStr() == "ok"

      # (2) The policy moves; health reports the snapshot stale, as a warning.
      writeFile(libB / "policy" / "team_policy.nim", teamPolicy("required"))
      discard fx.cf.gitIn(libB, "commit -q -a -m stricter")
      discard fx.cf.gitIn(libB, "push -q origin main")
      let libBPin2 = fx.cf.sib.headOf(libB)
      let row2 = fx.healthRow()
      check not row2.isNil
      if not row2.isNil:
        check row2["status"].getStr() == "warn"
        check CertificatePolicySnapshotStale in row2["detail"].getStr()
        check "repro lock refresh" in row2["remedy"].getStr()

      # (3) A commit: the hook re-pins lib-b and never writes the snapshot.
      writeFile(fx.app / "README.md", "app fixture, edited\n")
      let logBefore3 = fx.preCommitLog().len
      let commit3 = fx.gitApp("commit", "-a", "-m", "an edit")
      checkpoint("git commit (3):\n" & commit3.output)
      check commit3.code == 0
      let lock3 = fx.lockText()
      check ("revision = \"" & libBPin2 & "\"") in depEntry(lock3, "../lib-b")
      check snapshotOf(lock3) == snapshot1
      check "re-pinned" in fx.preCommitLog().lastLinesSince(logBefore3)

      # (4) The certifying run brings the snapshot up to the new rule.
      let run4 = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("repro test (4):\n" & run4.output)
      check run4.code == 0
      check "repro lock-update: repro.lock: certificate policy snapshot " &
        "updated" in run4.output
      let lock4 = fx.lockText()
      check "gate_mode = \"required\"" in snapshotOf(lock4)
      check fx.stagedLock() == lock4
      let content4 = fx.contentNow()
      check fx.certificatesFor(content4, "test").len == 1
      let commit4 = fx.gitApp("commit", "-a", "-m", "recertified")
      checkpoint("git commit (4):\n" & commit4.output)
      check commit4.code == 0
      check fx.lockText() == lock4
      check fx.headContent() == content4
      let row4 = fx.healthRow()
      check not row4.isNil
      if not row4.isNil:
        check row4["status"].getStr() == "ok"

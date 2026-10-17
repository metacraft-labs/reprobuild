## TC-9d — a ``[certificates]`` table in ``projects/<p>.toml`` is a LOUD
## error, never silently ignored (Test-Certificates.md §"The per-project
## ``[certificates]`` table is not supported"; operator decision D18):
## ignoring it would turn a ``required`` into ``off`` without a word. The
## message names the file, the table, and what to do in the terms of the
## policy design — declare a certificate policy (``certificatePolicy``),
## enact it (``enactCertificatePolicy``) and record it (``repro lock
## refresh``).
##
## The TC-8c store workspace (a real manifest workspace, developer clone and
## upstream bare), its project manifest given a ``required`` table
## (``t-unit`` on this platform):
##
##   1. the client pre-push gate does not load the workspace: it fails, and
##      its output names the manifest file, the table and the remedy;
##   2. ``repro ci plan`` refuses the same way;
##   3. ``repro health`` fails its manifest row with the remedy;
##   4. ``repro hooks ensure --vcs <workspace>`` (the workspace sweep) fails
##      the same way;
##   5. a ``git commit`` through the installed hooks says it on stderr (the
##      pre-commit gate is early feedback, not the enforcement point, so it
##      does not refuse on it);
##   6. an EMPTY ``[certificates]`` table is refused too, even one whose
##      header carries a trailing comment;
##   7. with the table removed and the requirement declared as a policy
##      instead (one rule for every branch, recorded in lib-a's
##      ``repro.lock``), the workspace loads again and the push is judged by
##      that policy: refused with no certificate and with one for another
##      platform only, accepted with one for this platform.
##
## Falsifiability: read the table instead of refusing it (or drop the
## refusal) → 1–4 and 6 pass the workspace load; stop reading the snapshot
## → 7's uncovered pushes are accepted.
##
## NO MOCKS: real repositories, real signatures (``ssh-keygen``), the built
## ``repro``. Skip rule: ``git`` or ``ssh-keygen`` missing.

import std/[json, os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip

include policy_gate_fixture

proc projectFile(fx: StoreFixture): string =
  fx.workspaceRoot / "projects" / "lib-a.toml"

proc withTable(fx: StoreFixture; table: string) =
  ## The fixture's project manifest with ``table`` before its first
  ## ``[[remote]]``, where a top-level table must go.
  let body = storeProjectToml(fileUrl(fx.upstreamBare))
  let at = body.find("[[remote]]")
  doAssert at > 0
  writeFile(fx.projectFile, body[0 ..< at] & table & body[at .. ^1])

proc withoutTable(fx: StoreFixture) =
  writeFile(fx.projectFile, storeProjectToml(fileUrl(fx.upstreamBare)))

proc namesTheRemedy(output: string): bool =
  ## The remedy is stated in the policy design's own terms.
  "certificatePolicy" in output and "enactCertificatePolicy" in output and
    "repro lock refresh" in output and "migrate-policy" notin output

proc namesTheTable(fx: StoreFixture; output: string): bool =
  fx.projectFile in output and "[certificates]" in output and
    namesTheRemedy(output)

suite "TC-9d — the retired [certificates] table is a loud error":

  test "t_legacy_certificates_table_is_a_loud_error_naming_the_policy":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "and commits in real repositories")
    else:
      let host = currentPlatformTag()
      # lib-a starts with a policy that gates nothing on main (its one rule
      # is for another branch): enough for `hooks ensure` to generate the
      # pre-commit certificate phase step 5 fires, and nothing a push of
      # main is judged by.
      let fx = setupStoreFixture(snapshotOf([policyRule(["elsewhere"],
        pmRequired, [req("t-unit", host)])]), "tc9d-loud",
        recordStore = false)
      defer: removeDir(fx.scratch)
      # The hooks go in while the workspace still loads.
      fx.ensureHooks()
      fx.withTable("[certificates]\ngate_mode = \"required\"\n" &
        "required_targets = [\"t-unit\"]\n" &
        "required_platforms = [\"" & host & "\"]\n\n")

      # ---- 1. the client pre-push gate does not load the workspace ------
      let head = fx.head
      let push = checkPrePush(fx, head)
      checkpoint("pre-push with the table:\n" & push.output)
      check push.code != 0
      check fx.namesTheTable(push.output)

      # ---- 2. repro ci plan ----------------------------------------------
      let plan = runArgv(@[fx.reproBin, "ci", "plan", "--platform=" & host,
        "--workspace-root=" & fx.workspaceRoot,
        "--current-repo=" & fx.libAPath, "--json"])
      checkpoint("ci plan with the table:\n" & plan.output)
      check plan.code == 1
      check fx.namesTheTable(plan.output)

      # ---- 3. repro health: the manifest row, with the remedy ------------
      let health = runArgv(@[fx.reproBin, "health",
        "--workspace-root=" & fx.workspaceRoot, "--json"])
      checkpoint("health with the table:\n" & health.output)
      let start = health.output.find('{')
      check start >= 0
      if start >= 0:
        var manifestRow: JsonNode = nil
        for row in parseJson(health.output[start .. ^1])["checks"]:
          if row["name"].getStr() == "manifest":
            manifestRow = row
        check manifestRow != nil
        if manifestRow != nil:
          check manifestRow["status"].getStr() == "fail"
          check fx.projectFile in manifestRow["detail"].getStr()
          check namesTheRemedy(manifestRow["remedy"].getStr())

      # ---- 4. the workspace-wide hooks sweep -----------------------------
      let sweep = runArgv(@[fx.reproBin, "hooks", "ensure", "--vcs",
        fx.workspaceRoot], fx.workspaceRoot, fx.hookEnv)
      checkpoint("hooks ensure with the table:\n" & sweep.output)
      check sweep.code != 0
      check fx.namesTheTable(sweep.output)

      # ---- 5. a commit says it out loud ----------------------------------
      writeFile(fx.libAPath / "a.txt", "alpha\n")
      discard fx.mustGit("add", "a.txt")
      let committed = fx.commit("-m", "with the table")
      checkpoint("commit with the table:\n" & committed.output)
      check committed.code == 0
      check fx.namesTheTable(committed.output)

      # ---- 6. an empty table is refused too ------------------------------
      fx.withTable("[certificates]\n\n")
      let empty = checkPrePush(fx, head)
      checkpoint("pre-push with an empty table:\n" & empty.output)
      check empty.code != 0
      check fx.namesTheTable(empty.output)
      # ... including when its header carries a trailing comment.
      fx.withTable("[certificates]  # retired\n\n")
      let commented = checkPrePush(fx, head)
      checkpoint("pre-push with an empty, commented table:\n" &
        commented.output)
      check commented.code != 0
      check fx.namesTheTable(commented.output)

      # ---- 7. table removed, policy declared: judged by the policy -------
      fx.withoutTable()
      let policyCommit = fx.commitPolicy(
        requiredPolicy(@["t-unit"], @[host]), "the certificate policy")
      let published = runArgv(@["git", "-C", fx.libAPath, "push",
        "--no-verify", "origin", "main"])
      checkpoint(published.output)
      check published.code == 0
      let content = "git-tree-sha1:" & gitOut(fx.libAPath, "rev-parse",
        policyCommit & "^{tree}")

      proc judged(label: string; accepted: bool) =
        let gate = checkPrePush(fx, policyCommit)
        checkpoint(label & ": gate:\n" & gate.output)
        check "[certificates]" notin gate.output
        if accepted:
          check gate.code == 0
        else:
          check gate.code == 2
          check "certificate-coverage" in failureProperties(gate.report)

      judged("no certificate", accepted = false)
      fx.certifyTargets(content, @["t-unit"], platform = "plan9/mips")
      judged("another platform only", accepted = false)
      fx.certifyTargets(content, @["t-unit"])
      judged("this platform", accepted = true)

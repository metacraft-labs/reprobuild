## Workspace-Manifest-Optional MO-13 — three follow-up deferrals:
##
##   (c) [corrects MO-5] the dedicated evidence-PUBLISH verb. MO-5 wired the
##       gather + putEvidence building blocks and the gate-side CONSUME path
##       but no verb an owner runs to PUBLISH an evidence-only repo's
##       source-free ``WorkspaceVcsEvidence`` to its store.
##       ``publishRoutedEvidence`` (the worker ``repro workspace
##       publish-evidence`` dispatches to) gathers + publishes; we read it back
##       with ``getEvidence``. Falsifiable: revert the verb worker to a no-op →
##       nothing in the store → the read-back is empty.
##
##   (b) [corrects MO-1] ``--lock <file>`` on ``repro test``'s sharding /
##       fixture execution path. MO-1 threaded ``--lock`` through the
##       verb-alias build only; the shard runner ignored it. We run
##       ``repro test --shard 1/1 --fixture-from=... --lock=<file>`` and assert
##       the shard report records the resolved lock provenance (path + the
##       lock's ``inputs_digest``), proving the sharded run consumed the LOCKED
##       graph. Falsifiable: revert the threading → the report omits the lock
##       fields.
##
##   (d) [corrects MO-9] the gate's git-native integrity check, non-conservative
##       where SAFE. MO-9 SKIPPED a lock refreshed before a repo's first commit
##       (a ``blake3:`` pre-commit tree hash) on a git checkout. MO-13 verifies
##       it: a tampered pre-commit hash now FAILS with a clear diagnostic
##       instead of being silently skipped. Folded here (assertions in the
##       ``item (d)`` block below). Falsifiable: revert the non-conservative
##       branch → the tampered pre-commit integrity is skipped → no failure.
##
## Skip rule: ``git`` missing on PATH / ``./build/bin/repro`` absent.

import std/[json, options, os, osproc, strutils, tables, tempfiles, unittest]

import repro_lock_store
import repro_cli_support
import repro_lock
import repro_workspace_manifests
import git_tool
import evidence

import "../e2e/sharding/sharding_test_support"

const reproBinary = "./build/bin/repro"

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  doAssert res.code == 0, "command failed: " & command & "\n" & res.output
  res.output

proc seedPublishedRepo(gitBin, originPath, workPath: string): string =
  ## A clean, PUBLISHED git checkout (the owner's evidence-only repo).
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email t@e.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " config user.name T")
  writeFile(workPath / "lib.txt", "private lib\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add lib.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m c1")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

proc makeFixture(workspace: string): FixtureSpec =
  let trueScript = workspace / "noop.sh"
  writeTrueScript(trueScript)
  result.fallbackBuildCostNs = 1_000_000_000'i64
  result.fallbackTestCostNs = 1_000_000_000'i64
  result.policy = "independent"
  for i in 1 .. 2:
    result.actions.add(FixtureActionSpec(
      id: 100 + i, commandStatsId: "cmd-" & $i, deps: @[],
      buildCmd: @[trueScript]))
    result.edges.add(FixtureEdgeSpec(
      id: 200 + i, selector: "fixture::test" & $i,
      historyKey: "fixture::test" & $i, buildDeps: @[100 + i],
      testName: "fixture-test-" & $i, testCmd: @[trueScript]))

suite "MO-13: evidence-publish verb + --lock on test sharding + gate integrity":

  test "t_evidence_publish_verb_and_lock_flag_on_test_sharding":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    elif not fileExists(reproBinary):
      skip()
    else:
      # ================= item (c): evidence-publish verb =================
      block evidencePublish:
        let ws = createTempDir("repro-mo13-evidence-", "")
        defer: removeDir(ws)

        let origin = ws / "origin.git"
        let secretWork = ws / "secret"
        let headSha = seedPublishedRepo(gitBin, origin, secretWork)

        # A host bootstrap config routing the personal tier to a committed-file
        # backend — the SAME on-disk path the verb worker reads via
        # ``loadLockingRouting``.
        # NOTE: the pinned toml-serialization requires INLINE-table arrays
        # (no ``[[locking.route]]`` double-bracket form).
        writeFile(ws / ".repro-workspace.toml",
          "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
          "[manifest]\n" &
          "url = \"file:///dev/null\"\n\n" &
          "[locking]\n" &
          "route = [{ visibility = \"personal\", " &
          "backend = \"committed-file\", path = \"evidence-store\" }]\n")

        let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
        let secretRepo = ResolvedRepo(name: "secret", path: "secret",
          visibility: wvPersonal, participation: "evidence-only")

        # The verb worker: gather the source-free triple + putEvidence it.
        let outcomes = publishRoutedEvidence(
          ws, @[secretRepo], "demo", identity, 1234'i64)
        check outcomes.len == 1
        check outcomes[0].published
        check outcomes[0].repoName == "secret"
        check outcomes[0].headSha == headSha

        # The evidence is now READABLE from the repo's assigned backend.
        let store: LockStore = newCommittedFileLockStore(ws / "evidence-store")
        let readBack = store.getEvidence("demo", "secret")
        check readBack.len == 3
        var rbHead = ""
        var rbClean, rbPub = false
        for rec in readBack:
          case rec.op
          of wvqHeadSha: rbHead = rec.headSha
          of wvqIsClean: rbClean = rec.isClean
          of wvqIsPublished: rbPub = rec.isPublished
        check rbHead == headSha   # gathered from the live checkout, published
        check rbClean
        check rbPub

      # ============ item (b): --lock on repro test sharding ==============
      block lockOnSharding:
        let proj = createTempDir("repro-mo13-shard-", "")
        defer: removeDir(proj)
        # A solvable project + its committed lock.
        writeFile(proj / "repro.solver", solverInputs)
        let refresh = run(reproBinary & " lock refresh " & q(proj))
        check refresh.code == 0
        let lockPath = proj / "repro.lock"
        check fileExists(lockPath)
        let lockDigest = readFile(lockPath)

        # Run a sharded fixture run WITH --lock pointing at the committed lock.
        let fixturePath = proj / "fixture.json"
        writeFixture(fixturePath, makeFixture(proj))
        let reportPath = proj / "shard-report.json"
        let res = runRepro(@["test", "--shard", "1/1",
          "--fixture-from=" & fixturePath,
          "--lock=" & lockPath,
          "--report=" & reportPath], proj)
        checkpoint(res.output)
        check res.code == 0

        # The shard report records the lock provenance the run consumed: the
        # resolved lock FILE and the lock's content digest (inputs_digest).
        let report = readShardReport(reportPath)
        check report{"lock_flag"}.getStr() == "--lock=" & lockPath
        check report{"lock_file"}.getStr() == lockPath
        check report{"locked_inputs_digest"}.getStr().len > 0
        # Sanity: the recorded digest is the lock's OWN inputs_digest.
        check report{"locked_inputs_digest"}.getStr() in lockDigest

      # ====== item (d): gate verifies a pre-commit blake3 integrity ======
      # MO-9 conservatively SKIPPED a lock whose integrity is a ``blake3:``
      # tree hash (recorded before the repo's first commit) on a git checkout.
      # MO-13 verifies it where SAFE: a tampered pre-commit hash now FAILS.
      block gateNonConservative:
        let ws = createTempDir("repro-mo13-gate-", "")
        defer: removeDir(ws)
        let repoDir = ws / "precommit"
        createDir(repoDir)
        discard requireGit(q(gitBin) & " init -b main " & q(repoDir))
        writeFile(repoDir / "content.txt", "pre-commit working tree\n")

        # The genuine pre-commit tree hash (no HEAD yet -> blake3 NAR hash).
        let goodIntegrity = computeDepIntegrity(repoDir, "")
        check goodIntegrity.startsWith("blake3:")

        proc ldWith(integrity: string): LockedDependencies =
          LockedDependencies(schema: SolvedGraphLockSchemaV2, deps: @[
            LockedDep(name: "precommit", path: "precommit",
              coordinates: Coordinates(kind: ckVcs, url: "", gitRef: "",
                revision: ""),  # empty revision: lock predates first commit
              integrity: integrity, visibility: "personal")])

        # Untampered pre-commit integrity now VERIFIES (and passes) even though
        # a ``.git`` is present and there is no concrete revision — previously
        # this whole case was silently skipped.
        check verifyLockedIntegrityAtCoordinates(
          ws, ldWith(goodIntegrity)).len == 0

        # Tampered pre-commit integrity is now REFUSED with a clear diagnostic
        # (the load-bearing falsifiable assertion: MO-9 would have skipped it).
        let badIntegrity = "blake3:" & "0".repeat(64)
        let failures = verifyLockedIntegrityAtCoordinates(
          ws, ldWith(badIntegrity))
        check failures.len == 1
        check failures[0].name == "precommit"
        check failures[0].expected == badIntegrity
        check failures[0].diagnostic.len > 0

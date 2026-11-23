## HL-10 (push half) — a pushed commit whose tree differs from certified
## content ONLY in ``repro.lock`` is refused as uncovered, and the client
## pre-push gate names the certified content, the commit it was tested on top
## of, and the lock file that differs (Test-Certificates.md §"Gate
## integration — push requirement"; Unified-Locking-And-Hooks.md §13.7.3
## item 4, §13.7.6).
##
## Fixture: ``lock_only_push_fixture.nim`` (a committed-lock lib-a under a
## ``required`` policy for ``t-unit``, a scratch local store, a registered
## key). Steps:
##
##   1. b.txt is added and the working tree certified (content C1, on top of
##      HEAD B0). Then ``repro.lock`` is rewritten — the same requirement, other
##      bytes, as a re-pin after testing would — and committed as P1, which is
##      published. The real ``repro check --mode=pre-push`` refuses P1 with
##      ``certificate-coverage``; its evidence names C1, B0's short id and
##      ``repro.lock``, and its remediation leads with testing the pushed
##      content. The verdict is unchanged by the search (exit 2).
##   2. The bound: 70 more content directories, each naming a real tree of the
##      repository that differs in non-lock files, are made NEWER than C1's.
##      The search considers the newest 64 only, so C1 falls outside it: the
##      search reports ``truncated`` and the gate makes no claim. Made older
##      again, C1 is named again — and the search over the full 64 is timed
##      in-process and the gate's wall time printed (the measured cost the
##      milestone records).
##   3. Control: a certificate for P1's own tree makes the push covered, and
##      no cause is printed.
##
## Falsifiability: drop the search from the gate → step 1's cause assertions
## fail; ignore the bound → step 2's truncated case names C1; claim a
## neighbour whose difference includes a non-lock file → the companion test
## ``t_push_with_a_non_lock_change_makes_no_lock_only_claim`` fails.
##
## NO MOCKS: real repositories, the built ``repro``, the production store
## writer and verifier. Skip rule: ``git`` or ``ssh-keygen`` missing.

import repro_test_support/reasoned_skip
import std/[json, os, osproc, strutils, times, unittest]

include lock_only_push_fixture

proc syntheticTrees(fx: StoreFixture; count: int): seq[string] =
  ## ``count`` real trees in lib-a's object database, each holding one file
  ## of its own — all differing from any lib-a commit in non-lock files.
  ## One ``git hash-object`` and one ``git mktree --batch``.
  let blobFile = fx.scratch / "synthetic-blob"
  writeFile(blobFile, "synthetic\n")
  let blob = gitOut(fx.libAPath, "hash-object", "-w", blobFile)
  doAssert blob.len == 40, blob
  var batch = ""
  for i in 0 ..< count:
    batch.add("100644 blob " & blob & "\tsynthetic-" & $i & ".txt\n\n")
  let input = fx.scratch / "mktree-input"
  writeFile(input, batch)
  let res = execCmdEx(quoteShellCommand(@["git", "-C", fx.libAPath, "mktree",
    "--batch"]) & " < " & quoteShell(input))
  doAssert res.exitCode == 0, res.output
  for line in res.output.splitLines():
    if line.strip().len == 40:
      result.add(line.strip())
  doAssert result.len == count, res.output

proc setTreeDirTimes(root: string; trees: seq[string]; at: Time) =
  for t in trees:
    setLastModificationTime(root / "v1" / "git-tree-sha1" / t, at)

suite "HL-10 — a lock-only push difference names the certified content":

  test "t_push_of_a_lock_only_change_names_the_certified_content":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "in real repositories")
    else:
      let fx = setupLockOnlyFixture("hl10-lock-only")
      defer: removeDir(fx.scratch)

      # ---- 1. certified, then the lock rewritten and pushed -------------
      writeFile(fx.libAPath / "b.txt", "b\n")
      let (c1, b0) = fx.certifyWorkingTree()
      fx.relockPolicy()
      let p1 = fx.commitAll("re-pinned after testing")
      fx.publish()
      let p1Content = "git-tree-sha1:" & gitOut(fx.libAPath, "rev-parse",
        p1 & "^{tree}")
      check p1Content != c1
      let gate = checkPrePush(fx, p1)
      checkpoint("gate:\n" & gate.output)
      check gate.code == 2
      check failureProperties(gate.report) == @["certificate-coverage"]
      let evidence = failureField(gate.report, "certificate-coverage",
        "evidence")
      check evidence.startsWith("uncovered: ")
      check ("certified content " & c1 & " (tested on top of commit " &
        b0[0 ..< 12] & ") differs from the pushed tree only in repro.lock") in
        evidence
      check lockOnlyCauseMarker in evidence
      let remediation = failureField(gate.report, "certificate-coverage",
        "remediation")
      check remediation.startsWith("test the content you push")

      # ---- 2. the bound -------------------------------------------------
      let extra = fx.syntheticTrees(LockOnlyNeighbourScanLimit + 6)
      for t in extra:
        let dir = fx.userRoot / "v1" / "git-tree-sha1" / t
        createDir(dir)
        writeFile(dir / "placeholder.toml", "")
      let c1Dir = fx.userRoot / "v1" / "git-tree-sha1" /
        c1["git-tree-sha1:".len .. ^1]
      check dirExists(c1Dir)
      let now = getTime()
      setLastModificationTime(c1Dir, now - initDuration(hours = 2))
      setTreeDirTimes(fx.userRoot, extra, now - initDuration(minutes = 1))
      let requires = @[PolicyRequirement(certificate: "t-unit",
        platforms: @[currentPlatformTag()])]
      let keys = readRegisteredKeyStoreChecked(
        registeredKeyStorePath(fx.workspaceRoot))
      let state = commitUnderEvaluation(fx.libAPath, p1)
      let hidden = findLockOnlyCertifiedNeighbours(state, requires, keys,
        committedLockSource())
      checkpoint("hidden: " & $hidden)
      check hidden.truncated
      check hidden.considered == LockOnlyNeighbourScanLimit
      check hidden.neighbours.len == 0
      check hidden.problems.len == 0
      let hiddenGate = checkPrePush(fx, p1)
      check hiddenGate.code == 2
      check lockOnlyCauseMarker notin failureField(hiddenGate.report,
        "certificate-coverage", "evidence")

      # C1 newest again: found, with a full 64-directory scan behind it.
      setLastModificationTime(c1Dir, now)
      setTreeDirTimes(fx.userRoot, extra, now - initDuration(hours = 1))
      let started = epochTime()
      let found = findLockOnlyCertifiedNeighbours(state, requires, keys,
        committedLockSource())
      let searchMs = (epochTime() - started) * 1000.0
      check found.truncated
      check found.considered == LockOnlyNeighbourScanLimit
      check found.neighbours.len == 1
      if found.neighbours.len == 1:
        check found.neighbours[0].contentId == c1
        check found.neighbours[0].differing == @["repro.lock"]
        check found.neighbours[0].bases == @[b0]
        check found.neighbours[0].coversAll
      let gateStarted = epochTime()
      let fullGate = checkPrePush(fx, p1)
      let gateMs = (epochTime() - gateStarted) * 1000.0
      check fullGate.code == 2
      check ("certified content " & c1) in failureField(fullGate.report,
        "certificate-coverage", "evidence")
      echo "lock-only search over " & $found.considered &
        " content directories: " & formatFloat(searchMs, ffDecimal, 1) &
        " ms in-process; whole pre-push gate: " &
        formatFloat(gateMs, ffDecimal, 1) & " ms"

      # ---- 3. control: P1's own certificate covers it --------------------
      check publishCertificateToLocalStore(signedCertFor(fx, p1Content, p1),
        fx.libAPath).written
      let covered = checkPrePush(fx, p1)
      checkpoint("covered:\n" & covered.output)
      check covered.code == 0
      check lockOnlyCauseMarker notin covered.output

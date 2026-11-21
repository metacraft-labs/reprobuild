## TC-8g — the pre-commit certificate gate judges the index being committed
## (test-certificates Standard §5.1, Content-Id §5), through the hooks
## ``repro hooks ensure --vcs`` installs and real ``git commit`` invocations.
##
## Under ``gate_mode = required`` (the policy in lib-a's committed
## ``repro.lock`` is one rule for every branch, ``everyBranchSnapshot``, which
## sets no ``commit_gate``, so the commit gate takes ``gate_mode``, operator decision
## D7; TC-9d), with a registered-signed certificate published to the local
## store for the content named in each case:
##
##   1. A fully staged, certified change commits; the gate's log line says it
##      found the content covered (so "passed" is not "never ran").
##   2. A partial ``git add`` — one of two certified edits staged — is
##      REFUSED: the index differs from the certified working tree. HEAD does
##      not move, and ``.git/index`` is byte-identical to the index git handed
##      the hooks (snapshotted by a chained hook that runs before the gate).
##   3. ``git commit -a`` of the certified working tree commits: the gate
##      judged git's temporary ``index.lock``, not the stale ``.git/index``.
##   4. ``git commit <path>`` is judged on git's temporary ``next-index``
##      file: with an UNCOVERED change staged in ``.git/index``, committing
##      only the certified path succeeds, and committing only the uncertified
##      path is refused.
##   5. A chained ``.repro-local`` hook that rewrites a file and stages it is
##      caught: the certificate for what the developer staged no longer
##      covers what the commit would record, so it is refused; certifying the
##      rewritten content lets the same commit through.
##   6. Under ``advisory`` the partial add is reported and the commit
##      proceeds.
##   7. Under ``off`` an uncovered commit proceeds and the gate neither
##      prints nor logs anything; under ``required`` a certificate that sits
##      only under the store's SYSTEM root covers the commit (the gate
##      searches both roots, Transport §2).
##
## Falsifiability (applied, rebuilt, run, reverted — see the milestone):
##   * the gate phase moved ahead of the chained ``.repro-local`` → case 5's
##     first commit passes;
##   * the gate computing the default index instead of the one git hands the
##     hook → case 3 and case 4 refuse the covered commits.
##
## NO MOCKS: real repositories, the real hooks, real ``git commit``, the
## production store and verifier, signatures by the real ``ssh-keygen``.
## Skip rule: ``git`` or ``ssh-keygen`` missing.

import repro_test_support/reasoned_skip
import std/[os, osproc, sequtils, strutils, unittest]

include pre_commit_gate_fixture

proc toolsMissing(): bool =
  findExe("git").len == 0 or findExe("ssh-keygen").len == 0

suite "TC-8g — the pre-commit gate judges the index being committed":

  test "t_pre_commit_gate_judges_the_index_being_committed":
    if toolsMissing():
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "and commits in real repositories")
    else:
      let fx = setupStoreFixture(
        requiredPolicy(@["t-unit"], @[currentPlatformTag()]), "tc8g-judges")
      defer: removeDir(fx.scratch)
      fx.ensureHooks()
      check fileExists(fx.libAPath / ".git" / "hooks" / "pre-commit")

      # ---- 1. a fully staged, certified change commits -------------------
      writeFile(fx.libAPath / "a.txt", "alpha\n")
      writeFile(fx.libAPath / "b.txt", "beta\n")
      discard fx.mustGit("add", "a.txt", "b.txt")
      fx.certify(fx.indexContentId)
      let before1 = fx.head
      let c1 = fx.commit("-m", "covered")
      checkpoint("case 1:\n" & c1.output)
      check c1.code == 0
      check fx.head != before1
      check fx.gateLogLines("covered") == 1

      # ---- 2. a partial add is refused; the index is left alone ----------
      writeFile(fx.libAPath / "a.txt", "alpha 2\n")
      writeFile(fx.libAPath / "b.txt", "beta 2\n")
      # The tests ran on the whole working tree: both edits.
      fx.certify(workingTreeContentId(fx.libAPath))
      discard fx.mustGit("add", "a.txt")          # only a.txt is staged
      # `git commit` itself refreshes the index (stat data, cache-tree) before
      # it runs any hook, so the snapshot is taken INSIDE the commit, by a
      # chained user hook that runs before the managed phases: whatever
      # differs afterwards was written by the refresh or the gate.
      let snapshot = fx.scratch / "index-before-gate"
      let snapLocal = fx.libAPath / ".git" / "hooks" / "pre-commit.repro-local"
      writeFile(snapLocal, "#!/bin/sh\ncp \"${GIT_INDEX_FILE:-.git/index}\" " &
        quoteShell(snapshot) & "\n")
      setFilePermissions(snapLocal, {fpUserRead, fpUserWrite, fpUserExec})
      let before2 = fx.head
      let c2 = fx.commit("-m", "partial")
      checkpoint("case 2:\n" & c2.output)
      check c2.code != 0
      check fx.head == before2
      check "no trusted certificate covers the content being committed" in
        c2.output
      check "REFUSED (commit_gate = required)" in c2.output
      check "--no-verify" in c2.output
      check "not the enforcement point" in c2.output
      check fileExists(snapshot)
      if fileExists(snapshot):
        check readFile(fx.indexPath) == readFile(snapshot)
      removeFile(snapLocal)
      check fx.gateLogLines("refused not-covered") == 1

      # ---- 3. commit -a: judged on git's temporary index.lock ------------
      # .git/index still holds only a.txt's edit (uncovered); `-a` records
      # the whole working tree, which is the certified content.
      let c3 = fx.commit("-a", "-m", "all of it")
      checkpoint("case 3:\n" & c3.output)
      check c3.code == 0
      check fx.head != before2
      check gitOut(fx.libAPath, "status", "--porcelain").len == 0

      # ---- 4. commit <path>: judged on git's temporary next-index --------
      writeFile(fx.libAPath / "a.txt", "alpha 3\n")
      writeFile(fx.libAPath / "b.txt", "beta 3\n")
      discard fx.mustGit("add", "b.txt")   # .git/index: an UNCOVERED change
      fx.certify(fx.treeWith([("a.txt", "alpha 3\n")]))
      let before4 = fx.head
      let refused4 = fx.commit("-m", "only b", "--", "b.txt")
      checkpoint("case 4, uncovered path:\n" & refused4.output)
      check refused4.code != 0
      check fx.head == before4
      let c4 = fx.commit("-m", "only a", "--", "a.txt")
      checkpoint("case 4, certified path:\n" & c4.output)
      check c4.code == 0
      check fx.head != before4
      # b.txt is still staged and still uncommitted.
      check gitOut(fx.libAPath, "diff", "--cached", "--name-only") == "b.txt"
      discard fx.mustGit("reset", "-q", "--hard", "HEAD")

      # ---- 5. a chained user hook that restages a rewritten file ---------
      let local = fx.libAPath / ".git" / "hooks" / "pre-commit.repro-local"
      check not fileExists(local)
      writeFile(local, "#!/bin/sh\n" &
        "# a formatter: normalises c.txt and restages it\n" &
        "if [ -f c.txt ]; then\n" &
        "  printf 'formatted\\n' >> c.txt\n" &
        "  git add c.txt\n" &
        "fi\n")
      setFilePermissions(local, {fpUserRead, fpUserWrite, fpUserExec})
      writeFile(fx.libAPath / "c.txt", "gamma\n")
      discard fx.mustGit("add", "c.txt")
      fx.certify(fx.indexContentId)      # what the developer staged and tested
      let before5 = fx.head
      let c5 = fx.commit("-m", "formatted by the hook")
      checkpoint("case 5, rewritten after the developer's tests:\n" &
        c5.output)
      check c5.code != 0
      check fx.head == before5
      check "no trusted certificate covers" in c5.output
      # The hook appended once; certify the content it produces on the retry
      # (it appends again, so: the staged bytes plus one more line).
      let retried = readFile(fx.libAPath / "c.txt") & "formatted\n"
      fx.certify(fx.treeWith([("c.txt", retried)]))
      let c5b = fx.commit("-m", "formatted by the hook")
      checkpoint("case 5, rewritten content certified:\n" & c5b.output)
      check c5b.code == 0
      check gitOut(fx.libAPath, "show", "HEAD:c.txt") & "\n" == retried
      removeFile(local)

  test "advisory: a partial add is reported and the commit proceeds":
    if toolsMissing():
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "and commits in real repositories")
    else:
      let fx = setupStoreFixture(requiredPolicy(@["t-unit"],
        @[currentPlatformTag()], mode = "advisory"), "tc8g-advisory")
      defer: removeDir(fx.scratch)
      fx.ensureHooks()
      writeFile(fx.libAPath / "a.txt", "alpha\n")
      writeFile(fx.libAPath / "README.md", "edited\n")
      fx.certify(workingTreeContentId(fx.libAPath))
      discard fx.mustGit("add", "a.txt")      # README.md left unstaged
      let before = fx.head
      let res = fx.commit("-m", "partial, advisory")
      checkpoint(res.output)
      check res.code == 0
      check fx.head != before
      check "no trusted certificate covers the content being committed" in
        res.output
      check "advisory: the commit proceeds" in res.output
      check fx.gateLogLines("reported not-covered") == 1

  test "off does nothing, and the system root of the store counts":
    if toolsMissing():
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "and commits in real repositories")
    else:
      # ---- off: no judgement at all -------------------------------------
      let off = setupStoreFixture(requiredPolicy(@["t-unit"],
        @[currentPlatformTag()], mode = "off"), "tc8g-off")
      defer: removeDir(off.scratch)
      off.ensureHooks()
      writeFile(off.libAPath / "a.txt", "uncovered\n")
      discard off.mustGit("add", "a.txt")
      let beforeOff = off.head
      let resOff = off.commit("-m", "uncovered, gate off")
      checkpoint(resOff.output)
      check resOff.code == 0
      check off.head != beforeOff
      check "certificate gate" notin resOff.output
      check "certificate-gate" notin off.gateLog

      # ---- required, with the certificate under the SYSTEM root only ----
      let fx = setupStoreFixture(
        requiredPolicy(@["t-unit"], @[currentPlatformTag()]), "tc8g-sysroot")
      defer: removeDir(fx.scratch)
      fx.ensureHooks()
      writeFile(fx.libAPath / "a.txt", "alpha\n")
      discard fx.mustGit("add", "a.txt")
      fx.certify(fx.indexContentId)              # lands in the user root
      createDir(fx.systemRoot.parentDir)
      moveDir(fx.userRoot, fx.systemRoot)  # where a system-wide producer writes
      check not dirExists(fx.userRoot)
      let before = fx.head
      let res = fx.commit("-m", "covered from the system root")
      checkpoint(res.output)
      check res.code == 0
      check fx.head != before
      check fx.gateLogLines("covered") == 1

  test "an incomplete store search is reported apart from none found":
    # Transport §2.1/§5, Tooling §2 (find exit 3 vs 1): when a store root
    # could not be read, finding nothing is not "no certificate": the gate
    # says the search was INCOMPLETE and refuses as UNVERIFIABLE, whose
    # remedy is not "run 'repro certify'". The control — the same commit
    # with every root readable — reports the completed empty search.
    if toolsMissing():
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "and commits in real repositories")
    elif defined(windows):
      skip("POSIX permission bits are what make the system root unreadable")
    else:
      let fx = setupStoreFixture(
        requiredPolicy(@["t-unit"], @[currentPlatformTag()]), "tc8g-partial")
      defer: removeDir(fx.scratch)
      fx.ensureHooks()
      writeFile(fx.libAPath / "a.txt", "uncovered\n")
      discard fx.mustGit("add", "a.txt")
      # Control: every root readable, nothing stored.
      let complete = fx.commit("-m", "uncovered, complete search")
      checkpoint("complete search:\n" & complete.output)
      check complete.code != 0
      check "no certificate found in the local store" in complete.output
      check "search INCOMPLETE" notin complete.output
      # The system root exists and cannot be read.
      createDir(fx.systemRoot / "v1")
      setFilePermissions(fx.systemRoot, {})
      defer: setFilePermissions(fx.systemRoot,
        {fpUserRead, fpUserWrite, fpUserExec})
      var readable = true
      try:
        for _ in walkDir(fx.systemRoot, checkDir = true): discard
      except OSError:
        readable = false
      if readable:
        skip("this process can list a mode-000 directory (it runs as " &
          "root), so an unreadable system root cannot be constructed here")
      else:
        let before = fx.head
        let partial = fx.commit("-m", "uncovered, incomplete search")
        checkpoint("incomplete search:\n" & partial.output)
        check partial.code != 0
        check fx.head == before
        check "search INCOMPLETE" in partial.output
        check "could not be established" in partial.output
        check "no certificate found in the local store" notin partial.output
        check fx.gateLogLines("refused unverifiable") == 1

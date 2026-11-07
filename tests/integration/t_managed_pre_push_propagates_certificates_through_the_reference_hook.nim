## A ``git push`` through reprobuild's managed ``pre-push`` hook carries the
## local store's certificates to the remote through the linked reference
## library's ``prePushHook`` (test-certificates Tooling §4), and that call never
## decides the push.
##
## Setup: a real clone with the real generated hooks, pushing to a real bare over
## ``file://``; certificates signed by the real path and placed in the store by
## the real delivery; no ``test-certificates`` executable on ``PATH``. Nothing in
## these cases writes a note except what the push runs. No mocks: every failure
## below is a real one, produced by the receiving repository's real hook or the
## clone's real configuration.
##
## Scenarios and what each would catch:
##
##   * PROPAGATES. Two commits, each certified, one push: the note for each
##     commit's tree is on the remote (Tooling §4.2: every commit the push
##     introduces, not only the tip). The commit before them is certified in
##     the store too and gets no note: the remote already has it.
##   * DECLARED SCOPES (§3.1). A certificate for a declared scope is noted on
##     the scoped tree, not on the commit's tree.
##   * A LINKED WORKTREE, pushing a new branch. The hook propagates from the
##     worktree's own state, and the remote-tracking refs bound what a new
##     branch introduces (§4.2), so the certified seed commit gets no note.
##   * BEFORE THE GATE. A push the publication gate refuses has already carried
##     its notes, and when they arrive the gate has not yet left its report.
##   * A NOTES PUSH (§4.1). Pushing only the notes ref introduces nothing, so a
##     stored certificate is not published from inside it.
##   * NOTHING TO CARRY. No certificate means no notes ref on the remote, and a
##     line saying so (§4.3: no network operation).
##   * A REMOTE THAT REFUSES the notes ref: reported, the branch still lands.
##   * AN INVALID SCOPE DECLARATION (§3.1): reported, the branch still lands,
##     and nothing is carried.
##   * THE TIME BUDGET (§4.3). A remote that holds the notes push open costs the
##     push no more than the budget. The failure is reported, the branch lands,
##     and the stalled process tree is gone: the library's group kill reached it
##     from inside the dispatcher.
##   * A BAD BUDGET VALUE is reported and the default used; there is no
##     unlimited setting.
##   * THE OPT-OUT (§4.3) is honoured and reported, and nothing is propagated.
##   * AN IGNORED SIGCHLD, inherited from the parent, breaks neither the
##     library's wait for its children nor the push.

import std/[times, unittest]

include certificate_push_fixture

const stallSeconds = "30719"
  ## A sleep length nothing else on the host uses, so ``pgrep`` finds only ours.

proc stalledProcessGone(): bool =
  ## The stalled hook's ``sleep`` has exited, allowing for the kill to land.
  for _ in 0 .. 50:
    if execCmdEx("pgrep -f 'sleep " & stallSeconds & "'").exitCode != 0:
      return true
    sleep(100)

suite "the managed pre-push hook propagates through the reference library":
  test "a push carries the certificates of every commit it introduces":
    let fx = setupStoreFixture("", "prop-all")
    defer: removeDir(fx.scratch)
    installHooks(fx)
    let first = newCommit(fx, "first.txt", "first\n")
    let second = newCommit(fx, "second.txt", "second\n")
    storeCertificateFor(fx, fx.seedSha)
    storeCertificateFor(fx, first)
    storeCertificateFor(fx, second)
    check not remoteHasNotes(fx.upstreamBare)

    let pushed = plainPush(fx)
    checkpoint(pushed.output)
    check pushed.code == 0
    check upstreamTip(fx) == second
    check "2 certified tree(s)" in pushed.output
    let firstTree = gitOut(fx.libAPath, "rev-parse", first & "^{tree}")
    let secondTree = gitOut(fx.libAPath, "rev-parse", second & "^{tree}")
    check ("git-tree-sha1:" & firstTree) in noteOnRemote(fx.upstreamBare,
      firstTree)
    check ("git-tree-sha1:" & secondTree) in noteOnRemote(fx.upstreamBare,
      secondTree)
    let seedTree = gitOut(fx.libAPath, "rev-parse", fx.seedSha & "^{tree}")
    check noteOnRemote(fx.upstreamBare, seedTree) == ""

  test "a certificate for a declared scope travels on the scoped tree":
    let fx = setupStoreFixture("", "prop-scope")
    defer: removeDir(fx.scratch)
    installHooks(fx)
    createDir(fx.libAPath / "docs")
    let commit = newCommit(fx, "docs/guide.md", "guide\n")
    discard gitOut(fx.libAPath, "config", "testCertificatesScope.docs.path",
      "docs")
    # Content-Id §4.1: the in-scope entries at their full paths. `docs` is a
    # top-level entry, so the scoped tree holds exactly that one.
    let entry = gitOut(fx.libAPath, "ls-tree", commit, "docs")
    let scopedTree = runArgv(@["sh", "-c", "printf '%s\\n' " &
      quoteShell(entry) & " | git -C " & quoteShell(fx.libAPath) &
      " mktree"]).output.strip()
    var cert = TestCertificate(
      schema: testCertificateSchemaV1, framework: reprobuildFrameworkId,
      project: "lib-a", platform: currentPlatformTag(), targets: @["t-unit"],
      result: tcrPassed, issuedAt: "2026-10-11T00:00:00Z", issuer: "fixture",
      vcs: TestCertificateVcs(repo: "lib-a", paths: @["docs"],
        content: "git-tree-sha1:" & scopedTree, untracked: false, base: commit),
      commands: @[TestCertificateCommand(argv: @["sh", "-c", "exit 0"])])
    signCertificateOnIssuance(cert, storeKeyId, fx.daemonKey)
    doAssert publishCertificateToLocalStore(cert, fx.libAPath).written

    let pushed = plainPush(fx)
    checkpoint(pushed.output)
    check pushed.code == 0
    check ("git-tree-sha1:" & scopedTree) in noteOnRemote(fx.upstreamBare,
      scopedTree)
    let fullTree = gitOut(fx.libAPath, "rev-parse", commit & "^{tree}")
    check noteOnRemote(fx.upstreamBare, fullTree) == ""

  test "a push from a linked worktree propagates that worktree's commit":
    let fx = setupStoreFixture("", "prop-worktree")
    defer: removeDir(fx.scratch)
    installHooks(fx)
    let wt = fx.scratch / "wt"
    discard gitOut(fx.libAPath, "worktree", "add", "-q", "-b", "side", wt)
    writeFile(wt / "side.txt", "side\n")
    discard gitOut(wt, "add", "side.txt")
    discard gitOut(wt, "commit", "-m", "side")
    let commit = gitOut(wt, "rev-parse", "HEAD")
    storeCertificateFor(fx, commit)
    storeCertificateFor(fx, fx.seedSha)

    let pushed = runArgv(@["git", "-C", wt, "push", "origin", "side"],
      env = @[(name: "PATH", value: pathWithoutTool()),
              (name: "REPROBUILD_REPRO", value: fx.reproBin)])
    checkpoint(pushed.output)
    check pushed.code == 0
    let tree = gitOut(wt, "rev-parse", "HEAD^{tree}")
    check ("git-tree-sha1:" & tree) in noteOnRemote(fx.upstreamBare, tree)
    let seedTree = gitOut(wt, "rev-parse", fx.seedSha & "^{tree}")
    check noteOnRemote(fx.upstreamBare, seedTree) == ""

  test "a push the gate refuses has already carried its notes":
    let fx = setupStoreFixture("", "prop-order")
    defer: removeDir(fx.scratch)
    installHooks(fx)
    let commit = newCommit(fx, "order.txt", "order\n")
    storeCertificateFor(fx, commit)
    # An uncommitted change to a tracked file: the publication gate refuses it.
    writeFile(fx.libAPath / "order.txt", "changed and not committed\n")
    # The gate leaves a report when it finishes. What the receiving side finds
    # when the notes arrive tells the order apart; the order of output lines
    # cannot, because the gate's stdout is flushed only when the process ends.
    let reports = fx.workspaceRoot / ".repro" / "build" / "reports"
    let seenByRemote = fx.scratch / "reports-when-notes-arrived"
    installRemoteHook(fx, "if grep -q refs/notes/; then ls " &
      quoteShell(reports) & " > " & quoteShell(seenByRemote) &
      " 2>/dev/null; fi\nexit 0\n")

    let pushed = plainPush(fx)
    checkpoint(pushed.output)
    check pushed.code != 0
    check upstreamTip(fx) == fx.seedSha
    let tree = gitOut(fx.libAPath, "rev-parse", commit & "^{tree}")
    check ("git-tree-sha1:" & tree) in noteOnRemote(fx.upstreamBare, tree)
    check "1 certified tree(s)" in pushed.output
    check "uncommitted" in pushed.output
    check fileExists(seenByRemote)
    check "check-" notin readFile(seenByRemote)
    # The control: the gate did leave its report, so its absence above is real.
    check fileExists(reports / "check-failure-report.json") or
      fileExists(reports / "check-report.json")

  test "pushing only the notes ref publishes nothing from inside its hook":
    let fx = setupStoreFixture("", "prop-notes-only")
    defer: removeDir(fx.scratch)
    installHooks(fx)
    let commit = newCommit(fx, "notes.txt", "notes\n")
    storeCertificateFor(fx, commit)
    let seedTree = gitOut(fx.libAPath, "rev-parse", fx.seedSha & "^{tree}")
    discard gitOut(fx.libAPath, "notes", "--ref", certificateNotesRef, "add",
      "-m", "by hand", seedTree)

    let pushed = plainPush(fx, @[certificateNotesRef])
    checkpoint(pushed.output)
    check "certified tree(s)" notin pushed.output
    let tree = gitOut(fx.libAPath, "rev-parse", commit & "^{tree}")
    check noteOnRemote(fx.upstreamBare, tree) == ""

  test "with nothing to carry the remote gets no notes ref":
    let fx = setupStoreFixture("", "prop-none")
    defer: removeDir(fx.scratch)
    installHooks(fx)
    let commit = newCommit(fx, "plain.txt", "plain\n")

    let pushed = plainPush(fx)
    checkpoint(pushed.output)
    check pushed.code == 0
    check upstreamTip(fx) == commit
    check "nothing to propagate" in pushed.output
    check not remoteHasNotes(fx.upstreamBare)

  test "a remote that refuses the notes ref does not fail the push":
    let fx = setupStoreFixture("", "prop-refused")
    defer: removeDir(fx.scratch)
    installHooks(fx)
    let commit = newCommit(fx, "refused.txt", "refused\n")
    storeCertificateFor(fx, commit)
    installRemoteHook(fx, "if grep -q refs/notes/; then exit 1; fi\n")

    let pushed = plainPush(fx)
    checkpoint(pushed.output)
    check pushed.code == 0
    check upstreamTip(fx) == commit
    check "NOT fully propagated" in pushed.output
    check not remoteHasNotes(fx.upstreamBare)

  test "an invalid scope declaration is reported and does not fail the push":
    let fx = setupStoreFixture("", "prop-badscope")
    defer: removeDir(fx.scratch)
    installHooks(fx)
    let commit = newCommit(fx, "scope.txt", "scope\n")
    storeCertificateFor(fx, commit)
    discard gitOut(fx.libAPath, "config", "testCertificatesScope.bad.path",
      "/not/a/scope/path/")

    let pushed = plainPush(fx)
    checkpoint(pushed.output)
    check pushed.code == 0
    check upstreamTip(fx) == commit
    check "NOT fully propagated" in pushed.output
    check not remoteHasNotes(fx.upstreamBare)

  test "a stalled remote costs the push only the budget, and is stopped":
    let fx = setupStoreFixture("", "prop-budget")
    defer: removeDir(fx.scratch)
    installHooks(fx)
    let commit = newCommit(fx, "budget.txt", "budget\n")
    storeCertificateFor(fx, commit)
    # Holds only the notes push open. The branch push that follows goes through.
    installRemoteHook(fx, "if grep -q refs/notes/; then sleep " &
      stallSeconds & "; fi\n")

    let started = epochTime()
    let pushed = plainPush(fx,
      env = @[(name: "TEST_CERTIFICATES_HOOK_TIMEOUT", value: "2")])
    let elapsed = epochTime() - started
    checkpoint(pushed.output)
    checkpoint("elapsed: " & $elapsed)
    check pushed.code == 0
    check upstreamTip(fx) == commit
    check "NOT fully propagated" in pushed.output
    check not remoteHasNotes(fx.upstreamBare)
    check elapsed < 45.0
    check stalledProcessGone()

  test "a budget that is not a number is reported, and the push carries on":
    let fx = setupStoreFixture("", "prop-badbudget")
    defer: removeDir(fx.scratch)
    installHooks(fx)
    let commit = newCommit(fx, "value.txt", "value\n")
    storeCertificateFor(fx, commit)

    let pushed = plainPush(fx,
      env = @[(name: "TEST_CERTIFICATES_HOOK_TIMEOUT", value: "forever")])
    checkpoint(pushed.output)
    check pushed.code == 0
    check "ignored TEST_CERTIFICATES_HOOK_TIMEOUT=forever" in pushed.output
    check remoteHasNotes(fx.upstreamBare)

  test "the opt-out is honoured and reported":
    let fx = setupStoreFixture("", "prop-optout")
    defer: removeDir(fx.scratch)
    installHooks(fx)
    let commit = newCommit(fx, "optout.txt", "optout\n")
    storeCertificateFor(fx, commit)

    let pushed = plainPush(fx,
      env = @[(name: "TEST_CERTIFICATES_HOOK", value: "off")])
    checkpoint(pushed.output)
    check pushed.code == 0
    check upstreamTip(fx) == commit
    check "TEST_CERTIFICATES_HOOK=off" in pushed.output
    check not remoteHasNotes(fx.upstreamBare)

  test "an inherited ignored SIGCHLD neither hangs nor breaks the push":
    let fx = setupStoreFixture("", "prop-sigchld")
    defer: removeDir(fx.scratch)
    installHooks(fx)
    let commit = newCommit(fx, "chld.txt", "chld\n")
    storeCertificateFor(fx, commit)

    # `trap ''` sets SIG_IGN, which every child inherits through exec.
    let pushed = runArgv(@["sh", "-c", "trap '' CHLD; exec git -C " &
      quoteShell(fx.libAPath) & " push origin main"],
      env = @[(name: "PATH", value: pathWithoutTool()),
              (name: "REPROBUILD_REPRO", value: fx.reproBin)])
    checkpoint(pushed.output)
    check pushed.code == 0
    check upstreamTip(fx) == commit
    let tree = gitOut(fx.libAPath, "rev-parse", commit & "^{tree}")
    check ("git-tree-sha1:" & tree) in noteOnRemote(fx.upstreamBare, tree)

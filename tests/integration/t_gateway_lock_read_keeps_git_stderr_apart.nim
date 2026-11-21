## The gateway reads git's stdout as data and keeps stderr for failed reads.
## Real local git repositories and gateway hooks, with GIT_TRACE=2 as the
## successful-command stderr trigger. Direct reads assert the exact stored
## blob (including CRLF and a missing final newline), every lock status,
## failed-step diagnostics, the published anchor and observed remote config.
## A real push exercises the receiving quarantine through the built CLI.
## Merging stderr again fails the present/status, anchor, wiring and push
## assertions; rebuilding stdout line by line fails the byte assertions;
## dropping stderr fails the failed-object diagnostic assertions.
## No network, mocks, skips or alternative binaries.

import std/[os, osproc, strutils, unittest]

include policy_gate_fixture

template withTrace(body: untyped) =
  let hadTrace = existsEnv("GIT_TRACE")
  let oldTrace = getEnv("GIT_TRACE")
  putEnv("GIT_TRACE", "2")
  try:
    body
  finally:
    if hadTrace: putEnv("GIT_TRACE", oldTrace)
    else: delEnv("GIT_TRACE")

proc exactBlob(fx: StoreFixture; oid: string): string =
  let path = fx.scratch / "exact-stdout"
  let err = fx.scratch / "exact-stderr"
  let code = execCmd(quoteShellCommand(@["git", "-C", fx.libAPath,
    "cat-file", "blob", oid]) & " >" & quoteShell(path) &
    " 2>" & quoteShell(err))
  doAssert code == 0, readFile(err)
  result = readFile(path)
  # Positive control: the same successful read really printed stderr.
  check "trace:" in readFile(err)

proc commitBody(fx: StoreFixture; body: string): string =
  writeFile(fx.libAPath / "repro.lock", body)
  discard fx.mustGit("add", "repro.lock")
  discard fx.mustGit("commit", "--no-verify", "-qm", "lock bytes")
  fx.head

suite "gateway lock reads keep git stderr apart":
  test "exact blobs, lock states and failed read diagnostics":
    let fx = setupStoreFixture("", "lock-stderr-bytes", recordStore = false)
    defer: removeDir(fx.scratch)
    let absent = fx.head
    let base = policyLock("")
    var cases: seq[tuple[commit, oid, body: string; status: GatewayLockStatus]]
    for body in [base, base.strip(), base.replace("\n", "\r\n"), " \r\n\t"]:
      let commit = fx.commitBody(body)
      let oid = gitOut(fx.libAPath, "rev-parse", commit & ":repro.lock")
      cases.add((commit, oid, body,
        if body.strip().len == 0: glrEmpty else: glrPresent))
    withTrace:
      for c in cases:
        let expected = fx.exactBlob(c.oid)
        check expected == c.body
        let read = gatewayReadPushedLock("git", fx.libAPath, c.commit)
        checkpoint(read.diagnostic)
        check read.status == c.status
        check read.blobId == c.oid
        check read.blob == expected
        check read.diagnostic == ""
      check gatewayReadPushedLock("git", fx.libAPath, absent).status == glrAbsent
      let missing = gatewayReadPushedLock("git", fx.libAPath, "1".repeat(40))
      check missing.status == glrUnreadable
      check "fatal:" in missing.diagnostic
      check "cat-file -t" in missing.diagnostic
      check "trace:" in missing.diagnostic
    # Remove a blob while its commit and tree stay readable: step 3 must
    # preserve the original stderr diagnostic and never report absence.
    let victim = cases[0]
    let obj = fx.libAPath / ".git" / "objects" / victim.oid[0..1] /
      victim.oid[2..^1]
    require fileExists(obj)
    removeFile(obj)
    withTrace:
      let gone = gatewayReadPushedLock("git", fx.libAPath, victim.commit)
      check gone.status == glrUnreadable
      check gone.blobId == victim.oid
      check gone.blob == ""
      check "fatal:" in gone.diagnostic
      check "trace:" in gone.diagnostic
    # A separate missing tree exercises step 2 rather than step 1 or 3.
    let tree = gitOut(fx.libAPath, "rev-parse", cases[^1].commit & "^{tree}")
    let treeObj = fx.libAPath / ".git" / "objects" / tree[0..1] / tree[2..^1]
    require fileExists(treeObj)
    removeFile(treeObj)
    withTrace:
      let goneTree = gatewayReadPushedLock("git", fx.libAPath, cases[^1].commit)
      check goneTree.status == glrUnreadable
      check "git ls-tree" in goneTree.diagnostic
      check "fatal:" in goneTree.diagnostic
      check "trace:" in goneTree.diagnostic

  test "traced real gateway push, anchor and remote config":
    let snapshot = snapshotOf([policyRule(["main"], pmOff, @[])])
    let fx = setupStoreFixture(snapshot, "lock-stderr-push", recordStore = false)
    defer: removeDir(fx.scratch)
    let cache = fx.scratch / "cache" / "clones"
    let wired = ensureGatewayForRepo("git", fx.workspaceRoot, "lib-a",
      fx.libAPath, cacheRoot = cache)
    require wired.outcome == gwoWired
    let before = observeWorkspaceGateways(fx.workspaceRoot, cacheRoot = cache)
    require before.wired == 1
    let next = fx.newCommit("next.txt", "incoming quarantine\n")
    let oid = gitOut(fx.libAPath, "rev-parse", next & ":repro.lock")
    withTrace:
      let anchor = gatewayRatchetAnchor("git", wired.gatewayDir,
        fileUrl(fx.upstreamBare), BranchRef(kind: brkBranch, name: "main"))
      checkpoint(anchor.source & " " & anchor.detail)
      check anchor.found
      check anchor.commit == fx.seedSha
      check anchor.mode == pmOff
      check "sets gate_mode off" in anchor.detail
      let broken = gatewayRatchetAnchor("git", wired.gatewayDir,
        fx.scratch / "missing-upstream", BranchRef(kind: brkBranch, name: "main"))
      check not broken.found
      check "fatal:" in broken.source
      check "trace:" in broken.source
      let observed = observeWorkspaceGateways(fx.workspaceRoot, cacheRoot = cache)
      check observed.wired == before.wired
      check observed.repos.len == before.repos.len
      if observed.repos.len == 1:
        check observed.repos[0].pushurl == before.repos[0].pushurl
        check observed.repos[0].upstreamUrl == before.repos[0].upstreamUrl
      let pushed = pushToGateway(fx, @["main:refs/heads/main"])
      checkpoint(pushed.output)
      check "trace:" in pushed.output
      check pushed.code == 0
      let read = gatewayReadPushedLock("git", wired.gatewayDir, next)
      check read.status == glrPresent
      check read.blobId == oid
      check read.blob == fx.exactBlob(oid)
      check read.diagnostic == ""
    check fx.upstreamTip == next

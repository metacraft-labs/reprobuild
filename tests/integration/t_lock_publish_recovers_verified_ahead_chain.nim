## Lock publication recovery — remote reachability, not index emptiness.
##
## Every case uses real working repositories and local bare remotes. The main
## recovery case creates an already-committed (therefore no-staged-diff) lock,
## makes the push URL fail, proves the backend and an independent source remote
## did not advance, then retries normally and proves the exact lock blob is
## reachable from the freshly fetched backend tip before the source branch is
## allowed to advance. Thus ``no staged changes`` cannot be mistaken for
## ``nothing to publish``.
##
## Additional cases cover a concurrent disjoint lock-only remote advance that
## landed before the first fetch (the stale record-store checkout: the local
## chain is verified from the merge-base, replayed onto the fetched tip,
## re-verified, and both records survive), a byte-identical record already
## published (the replay settles as nothing-to-publish), a remote non-lock
## advance (kept; the local lock commit is replayed onto it), a local non-lock
## ahead or divergent commit, unrelated histories, a divergent chain that
## carries a commit this checkout saw published before the upstream rewrote it
## away (refused: replaying it would republish removed history), dirty index/tree,
## rename, symlink, wrong record identity, deletion, executable mode, corrupt
## expected TOML, and fetch failure. A final real race installs the canonical
## hook bundle and uses a preserved hook to advance the remote during every
## actual Git push until the bounded retry budget is exhausted. It proves fresh
## retries retain the verified local head, consume every one-use capability,
## preserve every concurrent record, and leave no capability files. Every
## unsafe chain fails without reset, force-push, or remote mutation. It runs on
## every supported OS with Git; mode/symlink cases are POSIX-specific while the
## history/reachability matrix is cross-platform. Advancing either bare tip
## contrary to an assertion makes the suite fail. No mocks, ignored tests, or
## network access are used.
##
## The last two cases pin INVARIANT 14 — a published lock record is immutable —
## as a property over BYTES rather than over a refusal message: for a key that
## is already published, the blob object id reachable from the upstream ref is
## identical before and after the operation. One drives a stale store whose
## checkout never saw the published record; the other drives a real lost
## compare-and-swap that lands the competing record at the same key mid-push,
## which is the only point at which the collision can be observed at all.

import std/[os, sequtils, strutils, tempfiles, unittest]

when not defined(windows):
  import std/osproc

import repro_cli_support
import git_tool

when defined(windows):
  import repro_test_support

proc q(value: string): string =
  when defined(windows):
    # Command strings are evaluated by Git-for-Windows sh (see run below).
    # Quote even space-free drive paths so backslashes remain literal.
    "'" & value.replace("'", "'\"'\"'") & "'"
  else:
    quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  when defined(windows):
    let shell = findExe("sh")
    if shell.len == 0:
      return (127, "Git hook shell is unavailable")
    let res = runShell(shellCommand(@[shell, "-c", command]))
    (res.code, res.output)
  else:
    let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
    (res.exitCode, res.output)

proc require(command: string): string =
  let res = run(command)
  if res.code != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
    quit 1
  res.output

type Fixture = object
  scratch: string
  gitBin: string
  origin: string
  repo: string
  base: string
  identity: GitToolIdentity

proc git(fx: Fixture; args: string): string =
  require(q(fx.gitBin) & " -C " & q(fx.repo) & " " & args)

proc bareHead(fx: Fixture): string =
  require(q(fx.gitBin) & " --git-dir=" & q(fx.origin) &
    " rev-parse refs/heads/main").strip()

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-lock-recovery-", "")
  result.gitBin = gitBin
  result.origin = result.scratch / "locks-origin.git"
  let seed = result.scratch / "seed"
  result.repo = result.scratch / "locks"
  discard require(q(gitBin) & " init --bare -b main " & q(result.origin))
  discard require(q(gitBin) & " init -b main " & q(seed))
  discard require(q(gitBin) & " -C " & q(seed) &
    " config user.email tester@example.invalid")
  discard require(q(gitBin) & " -C " & q(seed) &
    " config user.name 'Lock Recovery Tester'")
  writeFile(seed / "README.md", "backend\n")
  discard require(q(gitBin) & " -C " & q(seed) & " add README.md")
  discard require(q(gitBin) & " -C " & q(seed) & " commit -m seed")
  discard require(q(gitBin) & " -C " & q(seed) &
    " remote add origin " & q(result.origin))
  discard require(q(gitBin) & " -C " & q(seed) &
    " push -u origin main")
  discard require(q(gitBin) & " clone " & q(result.origin) & " " &
    q(result.repo))
  discard require(q(gitBin) & " -C " & q(result.repo) &
    " config user.email tester@example.invalid")
  discard require(q(gitBin) & " -C " & q(result.repo) &
    " config user.name 'Lock Recovery Tester'")
  result.base = result.bareHead()
  result.identity = ensureGitToolResolvable(tpmPathOnly, getEnv("PATH"))
  removeDir(seed)

proc lockRel(repoName, oid: string): string =
  "locks/app/" & repoName & "/" & oid & ".toml"

proc validLock(repoName, oid: string): string =
  "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
  "[lock]\nproject = \"app\"\n" &
  "created_at = \"2026-07-22T00:00:00Z\"\n\n" &
  "[[repo]]\nname = \"" & repoName & "\"\n" &
  "path = \"" & repoName & "\"\nremote = \"origin\"\n" &
  "revision = \"" & oid & "\"\n"

proc expected(repoName, repoPath, oid: string): ExpectedLockRecord =
  ExpectedLockRecord(project: "app", repoName: repoName, repoPath: repoPath,
    oid: oid, relPath: lockRel(repoName, oid))

proc writeLock(repo, repoName, oid: string) =
  let rel = lockRel(repoName, oid)
  createDir((repo / rel).parentDir())
  writeFile(repo / rel, validLock(repoName, oid))

proc commitAll(fx: Fixture; message: string) =
  discard fx.git("add -A")
  discard fx.git("commit -m " & q(message))

proc remoteHas(fx: Fixture; rel: string): bool =
  run(q(fx.gitBin) & " --git-dir=" & q(fx.origin) &
    " cat-file -e " & q("refs/heads/main:" & rel)).code == 0

proc sourceRoot(): string = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  let configured = getEnv("REPROBUILD_REPRO")
  result = if configured.len > 0: configured
    else: sourceRoot() / "build" / "bin" / addFileExt("repro", ExeExt)
  if not fileExists(result):
    checkpoint("required exact repro CLI is missing: " & result)
    quit 1

proc installHooks(fx: Fixture) =
  let repro = reproBinary()
  let installed = run("env REPROBUILD_REPRO=" & q(repro) & " " & q(repro) &
    " hooks ensure --vcs --workspace-root=" & q(fx.repo) & " " & q(fx.repo))
  if installed.code != 0:
    checkpoint("hook ensure failed:\n" & installed.output)
    quit 1

proc publishWithHookCli(fx: Fixture;
    exactExpected: seq[ExpectedLockRecord]): LockPublishResult =
  ## The installed dispatcher intentionally resolves its CLI at hook runtime.
  ## Keep this real-push test hermetic when a developer's PATH contains an
  ## older repro that predates hook protocol v2.
  let prior = getEnv("REPROBUILD_REPRO")
  putEnv("REPROBUILD_REPRO", reproBinary())
  defer:
    if prior.len > 0: putEnv("REPROBUILD_REPRO", prior)
    else: delEnv("REPROBUILD_REPRO")
  publishWorkspaceLock(fx.identity, fx.repo, exactExpected)

suite "lock publication recovers verified ahead chains":
  test "failed no-staged push is retained and retry reaches backend first":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let oid = repeat('a', 40)
      let rel = lockRel("app", oid)
      writeLock(fx.repo, "app", oid)
      fx.commitAll("local lock")
      let retainedHead = fx.git("rev-parse HEAD").strip()
      check fx.git("diff --cached --name-only").strip().len == 0

      # An independent source remote stays unchanged until backend completion.
      let sourceOrigin = fx.scratch / "source-origin.git"
      let source = fx.scratch / "source"
      discard require(q(gitBin) & " init --bare -b main " & q(sourceOrigin))
      discard require(q(gitBin) & " init -b main " & q(source))
      discard require(q(gitBin) & " -C " & q(source) &
        " config user.email tester@example.invalid")
      discard require(q(gitBin) & " -C " & q(source) &
        " config user.name 'Source Tester'")
      writeFile(source / "main.txt", "seed\n")
      discard require(q(gitBin) & " -C " & q(source) & " add main.txt")
      discard require(q(gitBin) & " -C " & q(source) & " commit -m seed")
      discard require(q(gitBin) & " -C " & q(source) &
        " remote add origin " & q(sourceOrigin))
      discard require(q(gitBin) & " -C " & q(source) &
        " push -u origin main")
      let sourceRemoteBefore = require(q(gitBin) & " --git-dir=" &
        q(sourceOrigin) & " rev-parse main").strip()
      writeFile(source / "main.txt", "unpublished\n")
      discard require(q(gitBin) & " -C " & q(source) & " add main.txt")
      discard require(q(gitBin) & " -C " & q(source) &
        " commit -m unpublished")

      let missing = fx.scratch / "missing" / "origin.git"
      discard fx.git("remote set-url --push origin " & q(missing))
      let exact = @[expected("app", "app", oid)]
      let first = publishWorkspaceLock(fx.identity, fx.repo, exact)
      check first.outcome == lpoFailed
      check fx.bareHead() == fx.base
      check fx.git("rev-parse HEAD").strip() == retainedHead
      check fx.git("diff --cached --name-only").strip().len == 0
      check require(q(gitBin) & " --git-dir=" & q(sourceOrigin) &
        " rev-parse main").strip() == sourceRemoteBefore

      discard fx.git("remote set-url --push origin " & q(fx.origin))
      let retry = publishWorkspaceLock(fx.identity, fx.repo, exact)
      check retry.outcome == lpoPublished
      check fx.remoteHas(rel)
      check fx.git("symbolic-ref --short HEAD").strip() == "main"
      check fx.git("rev-parse --symbolic-full-name '@{u}'").strip() ==
        "refs/remotes/origin/main"
      # Only now may the independent source advance.
      discard require(q(gitBin) & " -C " & q(source) & " push origin main")
      check require(q(gitBin) & " --git-dir=" & q(sourceOrigin) &
        " rev-parse main").strip() != sourceRemoteBefore
      let complete = publishWorkspaceLock(fx.identity, fx.repo, exact)
      check complete.outcome == lpoNothingToPublish
      check fx.remoteHas(rel)
      check fx.git("symbolic-ref --short HEAD").strip() == "main"
      check fx.git("rev-parse --symbolic-full-name '@{u}'").strip() ==
        "refs/remotes/origin/main"

  test "concurrent disjoint lock-only remote advance is preserved":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let localOid = repeat('b', 40)
      let remoteOid = repeat('c', 40)
      writeLock(fx.repo, "app", localOid)
      fx.commitAll("local lock")

      let other = fx.scratch / "other"
      discard require(q(gitBin) & " clone " & q(fx.origin) & " " & q(other))
      discard require(q(gitBin) & " -C " & q(other) &
        " config user.email tester@example.invalid")
      discard require(q(gitBin) & " -C " & q(other) &
        " config user.name 'Concurrent Tester'")
      writeLock(other, "other", remoteOid)
      discard require(q(gitBin) & " -C " & q(other) & " add locks")
      discard require(q(gitBin) & " -C " & q(other) & " commit -m concurrent")
      discard require(q(gitBin) & " -C " & q(other) & " push origin main")

      # The other publisher landed BEFORE this publish fetched, so the local
      # lock commit already diverges from the tip the first fetch sees. This
      # is the stale record-store checkout of reprobuild-pm issue
      # 2026-11-05-pre-push-gate-refuses-a-lock-commit-made-on-a-stale-
      # record-store-instead-of-replaying-it: the verified lock-only local
      # side is replayed onto the fetched tip and published.
      let localHead = fx.git("rev-parse HEAD").strip()
      let remoteHead = fx.bareHead()
      check run(q(gitBin) & " -C " & q(fx.repo) &
        " merge-base --is-ancestor HEAD " & q(remoteHead)).code != 0
      let pub = publishWorkspaceLock(fx.identity, fx.repo,
        @[expected("app", "app", localOid)])
      checkpoint(pub.diagnostic)
      check pub.outcome == lpoPublished
      check fx.git("symbolic-ref --short HEAD").strip() == "main"
      check fx.git("rev-parse --symbolic-full-name '@{u}'").strip() ==
        "refs/remotes/origin/main"
      check fx.git("rev-parse HEAD").strip() != localHead
      check fx.bareHead() == fx.git("rev-parse HEAD").strip()
      # Replayed, not merged: the other publisher's tip is the new parent.
      check fx.git("rev-parse HEAD^").strip() == remoteHead
      check fx.remoteHas(lockRel("app", localOid))
      check fx.remoteHas(lockRel("other", remoteOid))
      let again = publishWorkspaceLock(fx.identity, fx.repo,
        @[expected("app", "app", localOid)])
      check again.outcome == lpoNothingToPublish

  test "a stale chain whose records are already published identically settles":
    let gitBin = findExe("git")
    doAssert gitBin.len > 0, "Git is required for stale-store replay regression"
    block:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let oid = repeat('9', 40)
      let rel = lockRel("app", oid)
      writeLock(fx.repo, "app", oid)
      fx.commitAll("local lock")
      # Another publisher files the byte-identical record first: the replay
      # drops our commit as already applied, which is completion.
      let other = fx.scratch / "same-bytes"
      discard require(q(gitBin) & " clone " & q(fx.origin) & " " & q(other))
      discard require(q(gitBin) & " -C " & q(other) &
        " config user.email tester@example.invalid")
      discard require(q(gitBin) & " -C " & q(other) &
        " config user.name 'Same Bytes'")
      writeLock(other, "app", oid)
      discard require(q(gitBin) & " -C " & q(other) & " add locks")
      discard require(q(gitBin) & " -C " & q(other) & " commit -m same")
      discard require(q(gitBin) & " -C " & q(other) & " push origin main")
      let remoteHead = fx.bareHead()
      let pub = publishWorkspaceLock(fx.identity, fx.repo,
        @[expected("app", "app", oid)])
      checkpoint(pub.diagnostic)
      check pub.outcome == lpoNothingToPublish
      check fx.bareHead() == remoteHead
      check fx.remoteHas(rel)
      check fx.git("symbolic-ref --short HEAD").strip() == "main"

  test "non-lock local or remote movement is never rebased or pushed":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      block localNonLock:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        writeFile(fx.repo / "README.md", "local non-lock\n")
        fx.commitAll("non-lock")
        let remoteBefore = fx.bareHead()
        let pub = publishWorkspaceLock(fx.identity, fx.repo)
        check pub.outcome == lpoFailed
        check fx.bareHead() == remoteBefore

      block remoteNonLock:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let oid = repeat('d', 40)
        writeLock(fx.repo, "app", oid)
        fx.commitAll("local lock")
        let other = fx.scratch / "other"
        discard require(q(gitBin) & " clone " & q(fx.origin) & " " & q(other))
        discard require(q(gitBin) & " -C " & q(other) &
          " config user.email tester@example.invalid")
        discard require(q(gitBin) & " -C " & q(other) &
          " config user.name 'Remote Mover'")
        writeFile(other / "README.md", "remote non-lock\n")
        discard require(q(gitBin) & " -C " & q(other) & " add README.md")
        discard require(q(gitBin) & " -C " & q(other) & " commit -m movement")
        discard require(q(gitBin) & " -C " & q(other) & " push origin main")
        let remoteBefore = fx.bareHead()
        # The REMOTE movement is somebody else's published history and is
        # kept as it is; only the verified local lock-only commit moves, onto
        # it. Nothing non-lock is rebased or pushed by this publisher.
        let pub = publishWorkspaceLock(fx.identity, fx.repo,
          @[expected("app", "app", oid)])
        checkpoint(pub.diagnostic)
        check pub.outcome == lpoPublished
        check fx.git("rev-parse HEAD^").strip() == remoteBefore
        check fx.bareHead() == fx.git("rev-parse HEAD").strip()
        check fx.remoteHas(lockRel("app", oid))
        check require(q(gitBin) & " --git-dir=" & q(fx.origin) &
          " show refs/heads/main:README.md") == "remote non-lock\n"

      block divergentLocalNonLock:
        # A divergent local side that is not lock-only is never replayed: the
        # stale-checkout replay holds it to the strictly-ahead proof.
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let oid = repeat('8', 40)
        writeLock(fx.repo, "app", oid)
        fx.commitAll("local lock")
        writeFile(fx.repo / "README.md", "local non-lock\n")
        fx.commitAll("local non-lock")
        let localHead = fx.git("rev-parse HEAD").strip()
        let other = fx.scratch / "other"
        discard require(q(gitBin) & " clone " & q(fx.origin) & " " & q(other))
        discard require(q(gitBin) & " -C " & q(other) &
          " config user.email tester@example.invalid")
        discard require(q(gitBin) & " -C " & q(other) &
          " config user.name 'Remote Mover'")
        writeLock(other, "other", repeat('7', 40))
        discard require(q(gitBin) & " -C " & q(other) & " add locks")
        discard require(q(gitBin) & " -C " & q(other) & " commit -m other")
        discard require(q(gitBin) & " -C " & q(other) & " push origin main")
        let remoteBefore = fx.bareHead()
        let pub = publishWorkspaceLock(fx.identity, fx.repo,
          @[expected("app", "app", oid)])
        checkpoint(pub.diagnostic)
        check pub.outcome == lpoFailed
        check "unverified local backend state" in pub.diagnostic
        check "README.md" in pub.diagnostic
        check fx.bareHead() == remoteBefore
        check fx.git("rev-parse HEAD").strip() == localHead
        check fx.git("symbolic-ref --short HEAD").strip() == "main"

      block unrelatedHistory:
        # A store whose history shares nothing with the upstream (a rewritten
        # store, or a wrong remote) is not a lock-only divergence.
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let oid = repeat('6', 40)
        discard fx.git("checkout --orphan rewritten")
        discard fx.git("rm -rf --quiet .")
        writeLock(fx.repo, "app", oid)
        fx.commitAll("orphan lock")
        discard fx.git("branch -M main")
        discard fx.git("branch --set-upstream-to=origin/main main")
        let localHead = fx.git("rev-parse HEAD").strip()
        let remoteBefore = fx.bareHead()
        let pub = publishWorkspaceLock(fx.identity, fx.repo,
          @[expected("app", "app", oid)])
        checkpoint(pub.diagnostic)
        check pub.outcome == lpoFailed
        check "shares no history" in pub.diagnostic
        check fx.bareHead() == remoteBefore
        check fx.git("rev-parse HEAD").strip() == localHead

  test "a stale chain that carries history the upstream rewrote away is refused":
    # A partial rewrite keeps the unchanged prefix, so the stale checkout and
    # the rewritten upstream still share a merge-base. The stretch from that
    # merge-base to HEAD is then not only this checkout's unpublished record:
    # it also holds a commit this checkout once saw published, which the
    # rewrite removed. Replaying it would republish the removed history, so
    # the divergence is refused and nothing moves on either side.
    let gitBin = findExe("git")
    doAssert gitBin.len > 0, "Git is required for the rewritten-store regression"
    block:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let removedOid = repeat('5', 40)
      writeLock(fx.repo, "removed", removedOid)
      fx.commitAll("published, then rewritten away")
      discard fx.git("push origin main")
      let publishedThenRemoved = fx.git("rev-parse HEAD").strip()

      let rewriter = fx.scratch / "rewriter"
      discard require(q(gitBin) & " clone " & q(fx.origin) & " " & q(rewriter))
      discard require(q(gitBin) & " -C " & q(rewriter) &
        " config user.email tester@example.invalid")
      discard require(q(gitBin) & " -C " & q(rewriter) &
        " config user.name 'History Rewriter'")
      discard require(q(gitBin) & " -C " & q(rewriter) &
        " reset --hard " & q(fx.base))
      writeLock(rewriter, "other", repeat('4', 40))
      discard require(q(gitBin) & " -C " & q(rewriter) & " add locks")
      discard require(q(gitBin) & " -C " & q(rewriter) & " commit -m other")
      discard require(q(gitBin) & " -C " & q(rewriter) &
        " push --force origin main")
      let rewrittenTip = fx.bareHead()

      # The stale checkout commits this operation's record on its old tip.
      let oid = repeat('3', 40)
      writeLock(fx.repo, "app", oid)
      fx.commitAll("local lock")
      let localHead = fx.git("rev-parse HEAD").strip()
      # The checkout is not fetched here, as in the field: the shape is
      # asserted on the bare. The published commit is no longer upstream,
      # and the unchanged prefix is still shared.
      check run(q(gitBin) & " --git-dir=" & q(fx.origin) &
        " merge-base --is-ancestor " & q(publishedThenRemoved) & " " &
        q(rewrittenTip)).code != 0
      check run(q(gitBin) & " --git-dir=" & q(fx.origin) &
        " merge-base --is-ancestor " & q(fx.base) & " " &
        q(rewrittenTip)).code == 0

      let pub = publishWorkspaceLock(fx.identity, fx.repo,
        @[expected("app", "app", oid)])
      checkpoint(pub.diagnostic)
      check pub.outcome == lpoFailed
      check publishedThenRemoved in pub.diagnostic
      check fx.bareHead() == rewrittenTip
      check not fx.remoteHas(lockRel("removed", removedOid))
      check not fx.remoteHas(lockRel("app", oid))
      check fx.git("rev-parse HEAD").strip() == localHead
      check fx.git("symbolic-ref --short HEAD").strip() == "main"

  test "delete unsafe mode and corrupt expected record all fail closed":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      block deletion:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let one = repeat('e', 40)
        let two = repeat('f', 40)
        writeLock(fx.repo, "app", one)
        writeLock(fx.repo, "other", two)
        let seed = publishWorkspaceLock(fx.identity, fx.repo)
        check seed.outcome == lpoPublished
        removeFile(fx.repo / lockRel("app", one))
        fx.commitAll("delete lock")
        let remoteBefore = fx.bareHead()
        let pub = publishWorkspaceLock(fx.identity, fx.repo)
        check pub.outcome == lpoFailed
        check fx.bareHead() == remoteBefore

      when defined(posix):
        block unsafeMode:
          let fx = setupFixture(gitBin)
          defer: removeDir(fx.scratch)
          let oid = repeat('1', 40)
          writeLock(fx.repo, "app", oid)
          let path = fx.repo / lockRel("app", oid)
          var permissions = getFilePermissions(path)
          permissions.incl(fpUserExec)
          setFilePermissions(path, permissions)
          let pub = publishWorkspaceLock(fx.identity, fx.repo)
          check pub.outcome == lpoFailed
          check fx.bareHead() == fx.base

      block corrupt:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let oid = repeat('2', 40)
        let rel = lockRel("app", oid)
        createDir((fx.repo / rel).parentDir())
        writeFile(fx.repo / rel, "not valid lock TOML\n")
        let pub = publishWorkspaceLock(fx.identity, fx.repo)
        check pub.outcome == lpoFailed
        check fx.bareHead() == fx.base

  test "dirty index tree rename symlink and wrong record identity are refused":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      block dirtyTree:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let oid = repeat('3', 40)
        let rel = lockRel("app", oid)
        writeLock(fx.repo, "app", oid)
        fx.commitAll("verified local lock")
        writeFile(fx.repo / rel, validLock("app", oid) & "# dirty tree\n")
        let before = fx.bareHead()
        let pub = publishWorkspaceLock(fx.identity, fx.repo)
        check pub.outcome == lpoFailed
        check "canonical additions only" in pub.diagnostic
        check fx.bareHead() == before
        check fx.git("status --porcelain").strip().len > 0

      block dirtyIndex:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let oid = repeat('4', 40)
        let rel = lockRel("app", oid)
        writeLock(fx.repo, "app", oid)
        fx.commitAll("verified local lock")
        writeFile(fx.repo / rel, validLock("app", oid) & "# dirty index\n")
        discard fx.git("add " & q(rel))
        let before = fx.bareHead()
        let pub = publishWorkspaceLock(fx.identity, fx.repo)
        check pub.outcome == lpoFailed
        check fx.bareHead() == before
        check fx.git("status --porcelain").strip().len > 0

      block renameRecord:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let oldOid = repeat('5', 40)
        let newOid = repeat('6', 40)
        writeLock(fx.repo, "app", oldOid)
        check publishWorkspaceLock(fx.identity, fx.repo).outcome == lpoPublished
        let before = fx.bareHead()
        let oldRel = lockRel("app", oldOid)
        let newRel = lockRel("app", newOid)
        discard fx.git("mv " & q(oldRel) & " " & q(newRel))
        writeFile(fx.repo / newRel, validLock("app", newOid))
        let pub = publishWorkspaceLock(fx.identity, fx.repo)
        check pub.outcome == lpoFailed
        check fx.bareHead() == before

      when defined(posix):
        block symlinkRecord:
          let fx = setupFixture(gitBin)
          defer: removeDir(fx.scratch)
          let oid = repeat('7', 40)
          let rel = lockRel("app", oid)
          createDir((fx.repo / rel).parentDir())
          let target = fx.scratch / "outside-lock.toml"
          writeFile(target, validLock("app", oid))
          createSymlink(target, fx.repo / rel)
          let pub = publishWorkspaceLock(fx.identity, fx.repo)
          check pub.outcome == lpoFailed
          check fx.bareHead() == fx.base

      block wrongIdentity:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let oid = repeat('8', 40)
        let rel = lockRel("app", oid)
        createDir((fx.repo / rel).parentDir())
        writeFile(fx.repo / rel,
          "[[repo]]\nname = \"other\"\npath = \"app\"\nrevision = \"" &
            oid & "\"\n")
        let pub = publishWorkspaceLock(fx.identity, fx.repo)
        check pub.outcome == lpoFailed
        check pub.diagnostic.startsWith(
          "cannot bind staged lock to an exact repository coordinate:")
        check fx.bareHead() == fx.base

  test "fetch failure retains the exact verified local-only chain":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let oid = repeat('9', 40)
      let rel = lockRel("app", oid)
      writeLock(fx.repo, "app", oid)
      fx.commitAll("local lock before fetch failure")
      let retained = fx.git("rev-parse HEAD").strip()
      let missing = fx.scratch / "auth-or-fetch-unavailable.git"
      discard fx.git("remote set-url origin " & q(missing))
      let pub = publishWorkspaceLock(fx.identity, fx.repo,
        @[expected("app", "app", oid)])
      check pub.outcome == lpoFailed
      check "fetch" in pub.diagnostic
      check fx.git("rev-parse HEAD").strip() == retained
      check require(q(gitBin) & " --git-dir=" & q(fx.origin) &
        " rev-parse refs/heads/main").strip() == fx.base
      check not fx.remoteHas(rel)

  test "exact repository path rejects fresh recovery race and root transplants":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      proc writeMinimal(fx: Fixture; oid, repoPath: string) =
        let rel = lockRel("app", oid)
        createDir((fx.repo / rel).parentDir())
        writeFile(fx.repo / rel,
          "[[repo]]\nname = \"app\"\npath = \"" & repoPath &
            "\"\nrevision = \"" & oid & "\"\n")

      block freshWrongPath:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let oid = repeat('a', 40)
        fx.writeMinimal(oid, "other")
        let pub = publishWorkspaceLock(fx.identity, fx.repo,
          @[expected("app", "app", oid)])
        check pub.outcome == lpoFailed
        check "exact operation" in pub.diagnostic or
          "trigger identity" in pub.diagnostic
        check fx.bareHead() == fx.base

      block noStagedWrongPath:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let oid = repeat('b', 40)
        fx.writeMinimal(oid, "other")
        fx.commitAll("wrong-path local lock")
        let localBefore = fx.git("rev-parse HEAD").strip()
        let pub = publishWorkspaceLock(fx.identity, fx.repo,
          @[expected("app", "app", oid)])
        check pub.outcome == lpoFailed
        check fx.git("rev-parse HEAD").strip() == localBefore
        check fx.bareHead() == fx.base

      block raceWrongPath:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let oid = repeat('c', 40)
        fx.writeMinimal(oid, "other")
        fx.commitAll("wrong-path raced lock")
        let localBefore = fx.git("rev-parse HEAD").strip()
        let other = fx.scratch / "other"
        discard require(q(gitBin) & " clone " & q(fx.origin) & " " & q(other))
        discard require(q(gitBin) & " -C " & q(other) &
          " config user.email tester@example.invalid")
        discard require(q(gitBin) & " -C " & q(other) &
          " config user.name 'Path Race Tester'")
        writeLock(other, "other", repeat('d', 40))
        discard require(q(gitBin) & " -C " & q(other) & " add locks")
        discard require(q(gitBin) & " -C " & q(other) & " commit -m race")
        discard require(q(gitBin) & " -C " & q(other) & " push origin main")
        let remoteBefore = fx.bareHead()
        let pub = publishWorkspaceLock(fx.identity, fx.repo,
          @[expected("app", "app", oid)])
        check pub.outcome == lpoFailed
        check fx.git("rev-parse HEAD").strip() == localBefore
        check fx.bareHead() == remoteBefore

      for (bodyPath, expectedPath) in [("app", "."), (".", "app")]:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let oid = repeat(if bodyPath == ".": 'e' else: 'f', 40)
        fx.writeMinimal(oid, bodyPath)
        let pub = publishWorkspaceLock(fx.identity, fx.repo,
          @[expected("app", expectedPath, oid)])
        check pub.outcome == lpoFailed
        check fx.bareHead() == fx.base

  test "real repeated non-fast-forward races exhaust the bounded retry safely":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let localOid = repeat('a', 40)
      let localRel = lockRel("app", localOid)
      writeLock(fx.repo, "app", localOid)
      fx.commitAll("local lock raced repeatedly")

      # Prepare nine descendant tips. The retry budget is eight, so a preserved
      # pre-push hook can advance the real bare remote once per attempt without
      # inventing Git output or calling the managed hook directly.
      let other = fx.scratch / "racer"
      discard require(q(gitBin) & " clone " & q(fx.origin) & " " & q(other))
      discard require(q(gitBin) & " -C " & q(other) &
        " config user.email tester@example.invalid")
      discard require(q(gitBin) & " -C " & q(other) &
        " config user.name 'Remote Race Tester'")
      var racingTips: seq[string]
      for index in 1 .. 9:
        let marker = align($index, 40, '0')
        writeLock(other, "race-" & $index, marker)
        discard require(q(gitBin) & " -C " & q(other) & " add locks")
        discard require(q(gitBin) & " -C " & q(other) &
          " commit -m " & q("race " & $index))
        racingTips.add(require(q(gitBin) & " -C " & q(other) &
          " rev-parse HEAD").strip())
      let tipsFile = fx.scratch / "racing-tips"
      writeFile(tipsFile, racingTips.join("\n") & "\n")
      let countFile = fx.scratch / "race-count"
      let userLog = fx.scratch / "preserved-hook.log"
      let hook = fx.repo / ".git" / "hooks" / "pre-push"
      createDir(hook.parentDir())
      writeFile(hook,
        "#!/usr/bin/env sh\nset -eu\n" &
        "n=1\nif [ -f " & q(countFile) & " ]; then n=$(cat " &
          q(countFile) & "); fi\n" &
        "sha=$(sed -n \"${n}p\" " & q(tipsFile) & ")\n" &
        "test -n \"$sha\"\n" &
        "next=$((n + 1)); printf '%s\\n' \"$next\" > " & q(countFile) &
          "\n" &
        q(gitBin) & " -C " & q(other) &
          " push --no-verify origin \"$sha:refs/heads/main\"\n" &
        "printf 'cap=%s legacy=%s dispatcher=%s\\n' " &
          "\"${REPROBUILD_INTERNAL_HOOK_CAPABILITY:-}\" " &
          "\"${REPROBUILD_HOOK_ACTIVE:-}\" " &
          "\"${REPROBUILD_HOOK_DISPATCH_PROTOCOL:-}\" >> " & q(userLog) &
          "\n")
      var perms = getFilePermissions(hook)
      perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
      setFilePermissions(hook, perms)
      installHooks(fx)

      let pub = publishWithHookCli(fx,
        @[expected("app", "app", localOid)])
      check pub.outcome == lpoFailed
      check "kept racing" in pub.diagnostic
      check readFile(countFile).strip() == "10"
      check fx.bareHead() == racingTips[^1]
      check not fx.remoteHas(localRel)
      for index in 1 .. 9:
        let marker = align($index, 40, '0')
        check fx.remoteHas(lockRel("race-" & $index, marker))
      let retained = fx.git("rev-parse HEAD").strip().toLowerAscii()
      check pub.verifiedLocalHead == retained
      check readFile(userLog).splitLines().allIt(
        it.len == 0 or it == "cap= legacy= dispatcher=")
      let common = fx.git("rev-parse --git-common-dir").strip()
      let capDir = (if common.isAbsolute: common else: fx.repo / common) /
        "reprobuild" / "hook-capabilities"
      if dirExists(capDir): check toSeq(walkDir(capDir)).len == 0

  test "one observed push race rebases the named branch and then noops":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let localOid = repeat('1', 40)
      let remoteOid = repeat('2', 40)
      writeLock(fx.repo, "app", localOid)
      fx.commitAll("local lock for one race")

      let other = fx.scratch / "single-racer"
      discard require(q(gitBin) & " clone " & q(fx.origin) & " " & q(other))
      discard require(q(gitBin) & " -C " & q(other) &
        " config user.email tester@example.invalid")
      discard require(q(gitBin) & " -C " & q(other) &
        " config user.name 'Single Race Tester'")
      writeLock(other, "other", remoteOid)
      discard require(q(gitBin) & " -C " & q(other) & " add locks")
      discard require(q(gitBin) & " -C " & q(other) & " commit -m race")
      let racingTip = require(q(gitBin) & " -C " & q(other) &
        " rev-parse HEAD").strip()
      let marker = fx.scratch / "single-race-fired"
      let hook = fx.repo / ".git" / "hooks" / "pre-push"
      createDir(hook.parentDir())
      writeFile(hook,
        "#!/usr/bin/env sh\nset -eu\n" &
        "if [ ! -f " & q(marker) & " ]; then\n" &
        "  : > " & q(marker) & "\n" &
        "  " & q(gitBin) & " -C " & q(other) &
          " push --no-verify origin " & q(racingTip & ":refs/heads/main") &
          "\nfi\n")
      var perms = getFilePermissions(hook)
      perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
      setFilePermissions(hook, perms)
      installHooks(fx)

      let exact = @[expected("app", "app", localOid)]
      let pub = publishWithHookCli(fx, exact)
      check pub.outcome == lpoPublished
      check fileExists(marker)
      check fx.remoteHas(lockRel("app", localOid))
      check fx.remoteHas(lockRel("other", remoteOid))
      check fx.git("symbolic-ref --short HEAD").strip() == "main"
      check fx.git("rev-parse --symbolic-full-name '@{u}'").strip() ==
        "refs/remotes/origin/main"
      let complete = publishWithHookCli(fx, exact)
      check complete.outcome == lpoNothingToPublish
      check fx.git("symbolic-ref --short HEAD").strip() == "main"

  # ------------------------------------------------------------------
  # INVARIANT 14 (push-hook-publication-protocol.md) — IMMUTABILITY BINDS
  # PUBLISHED RECORDS. Two shapes of the SAME violation, both observed in
  # production rather than imagined.
  #
  # On 2026-09-16 a local pre-push gate run published an `M` commit over
  # `locks/codetracer/codetracer/3168f9ec....toml`, 261 insertions and 175
  # deletions over a record published on 2026-09-10 and amended since. It
  # destroyed the amendment and moved every sibling pin backwards onto the
  # publishing workspace's feature branches, and it reported `OK`. Its
  # reflog is the whole mechanism:
  #
  #   41298411 reset: moving to origin/latest        (store parks at a tip)
  #   b28e332b commit: Publish 1 workspace lock entry     (an `M`, not `A`)
  #   76f6f1d2 rebase (start): checkout origin/latest      (the push raced)
  #   5536b109 rebase (pick): Publish 1 workspace lock entry
  #
  # The bytes that reached the remote were the REBASED ones, so the last
  # gate a rewrite has to pass is the non-fast-forward re-apply — not the
  # staging check that ran before it.
  #
  # These cases assert the PROPERTY, not the symptom: for a key that is
  # already published, the bytes reachable from the upstream ref are
  # IDENTICAL before and after the operation. They compare the blob's object
  # id, a hash over the exact bytes, so a rewrite of any size fails here —
  # including one whose repo coordinates happen to agree, which is precisely
  # the class the writer's coordinate comparison cannot see.
  #
  # Falsifiable: teach `rebaseVerifiedLockChain` to resolve the collision in
  # favour of the replayed commit (`rebase -X theirs`) AND relax
  # `verifyLockOnlyAheadChain`'s additions-only rule to accept `M`, and the
  # race case publishes the overwrite and fails here. Relaxing either one
  # alone still refuses, which is the point: both are load-bearing.
  proc lockWithSibling(repoName, oid, siblingName, siblingOid: string): string =
    validLock(repoName, oid) &
      "\n[[repo]]\nname = \"" & siblingName & "\"\n" &
      "path = \"" & siblingName & "\"\nremote = \"origin\"\n" &
      "revision = \"" & siblingOid & "\"\n"

  proc remoteBlobId(fx: Fixture; rel: string): string =
    ## The object id of the blob the upstream ref reaches at ``rel``. A hash
    ## over the file's exact bytes, so "unchanged" here means byte-unchanged
    ## and not merely "still parses the same".
    let res = run(q(fx.gitBin) & " --git-dir=" & q(fx.origin) &
      " rev-parse " & q("refs/heads/main:" & rel))
    if res.code != 0: "" else: res.output.strip()

  test "a stale store never rewrites a record already published at its key":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let oid = repeat('e', 40)
      let rel = lockRel("app", oid)

      # Somebody else publishes the record for this key first, pinning a
      # sibling at `aaa...`. Our checkout never learns about it — this is the
      # stale store the incident's reflog shows parked at an old tip.
      let other = fx.scratch / "publisher"
      discard require(q(gitBin) & " clone " & q(fx.origin) & " " & q(other))
      discard require(q(gitBin) & " -C " & q(other) &
        " config user.email tester@example.invalid")
      discard require(q(gitBin) & " -C " & q(other) &
        " config user.name 'Prior Publisher'")
      createDir((other / rel).parentDir())
      writeFile(other / rel,
        lockWithSibling("app", oid, "sibling", repeat('a', 40)))
      discard require(q(gitBin) & " -C " & q(other) & " add locks")
      discard require(q(gitBin) & " -C " & q(other) & " commit -m published")
      discard require(q(gitBin) & " -C " & q(other) & " push origin main")
      let publishedTip = fx.bareHead()
      let publishedBlob = fx.remoteBlobId(rel)
      check publishedBlob.len > 0

      # Our workspace generates ITS answer for the same key: the same self
      # coordinate (the path demands it), a different sibling pin. This is
      # the difference the writer's coordinate comparison is blind to
      # whenever the stale checkout does not hold the record at all.
      createDir((fx.repo / rel).parentDir())
      writeFile(fx.repo / rel,
        lockWithSibling("app", oid, "sibling", repeat('b', 40)))
      fx.commitAll("stale store lock")
      let localHead = fx.git("rev-parse HEAD").strip()

      let pub = publishWorkspaceLock(fx.identity, fx.repo,
        @[expected("app", "app", oid)])
      check pub.outcome != lpoPublished
      check fx.bareHead() == publishedTip
      check fx.remoteBlobId(rel) == publishedBlob
      # Nothing local was rewritten or reset on the operator's behalf either.
      check fx.git("rev-parse HEAD").strip() == localHead
      check fx.git("symbolic-ref --short HEAD").strip() == "main"
      # The stale-checkout replay must name the collision, not report it as a
      # divergence or a merge failure.
      check "already published at" in pub.diagnostic
      check "immutable" in pub.diagnostic
      check rel in pub.diagnostic

  test "a push race at one key leaves the published bytes byte-identical":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let oid = repeat('d', 40)
      let rel = lockRel("app", oid)

      # Our record is an honest ADDITION against the tip we can see, so it
      # passes the writer, the staging check and the ahead-chain verifier.
      # The collision exists only on the remote and only becomes visible
      # after the push is rejected — which is the state the re-apply runs in.
      createDir((fx.repo / rel).parentDir())
      writeFile(fx.repo / rel,
        lockWithSibling("app", oid, "sibling", repeat('b', 40)))
      fx.commitAll("local lock for a colliding race")

      let other = fx.scratch / "collide-racer"
      discard require(q(gitBin) & " clone " & q(fx.origin) & " " & q(other))
      discard require(q(gitBin) & " -C " & q(other) &
        " config user.email tester@example.invalid")
      discard require(q(gitBin) & " -C " & q(other) &
        " config user.name 'Colliding Race Tester'")
      createDir((other / rel).parentDir())
      writeFile(other / rel,
        lockWithSibling("app", oid, "sibling", repeat('a', 40)))
      discard require(q(gitBin) & " -C " & q(other) & " add locks")
      discard require(q(gitBin) & " -C " & q(other) & " commit -m collide")
      let racingTip = require(q(gitBin) & " -C " & q(other) &
        " rev-parse HEAD").strip()
      let racingBlob = require(q(gitBin) & " -C " & q(other) &
        " rev-parse HEAD:" & q(rel)).strip()

      # A third-party pre-push hook lands the competing record between our
      # advertisement and our ref update: a real lost compare-and-swap, not a
      # simulated one.
      let marker = fx.scratch / "collide-race-fired"
      let hook = fx.repo / ".git" / "hooks" / "pre-push"
      createDir(hook.parentDir())
      writeFile(hook,
        "#!/usr/bin/env sh\nset -eu\n" &
        "if [ ! -f " & q(marker) & " ]; then\n" &
        "  : > " & q(marker) & "\n" &
        "  " & q(gitBin) & " -C " & q(other) &
          " push --no-verify origin " & q(racingTip & ":refs/heads/main") &
          "\nfi\n")
      var perms = getFilePermissions(hook)
      perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
      setFilePermissions(hook, perms)

      let pub = publishWorkspaceLock(fx.identity, fx.repo,
        @[expected("app", "app", oid)])
      check fileExists(marker)
      check pub.outcome != lpoPublished
      check fx.bareHead() == racingTip
      check fx.remoteBlobId(rel) == racingBlob
      check fx.git("symbolic-ref --short HEAD").strip() == "main"
      # The refusal must NAME the condition. Reported as a merge failure it is
      # indistinguishable from a broken checkout, and the operator's next move
      # is to "fix the conflict" — which is how a published record gets
      # rewritten by hand after the tool declined to rewrite it.
      check "already published at" in pub.diagnostic
      check "immutable" in pub.diagnostic
      check rel in pub.diagnostic

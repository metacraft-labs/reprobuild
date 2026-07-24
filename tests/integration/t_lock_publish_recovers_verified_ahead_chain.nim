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
## Additional cases cover a concurrent disjoint lock-only remote advance (the
## local chain is verified, rebased, re-verified, and both records survive), a
## remote non-lock advance, a local non-lock ahead commit, dirty index/tree,
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

      let localHead = fx.git("rev-parse HEAD").strip()
      let remoteHead = fx.bareHead()
      let pub = publishWorkspaceLock(fx.identity, fx.repo,
        @[expected("app", "app", localOid)])
      check pub.outcome == lpoFailed
      check "not a fast-forward" in pub.diagnostic or
        "unverified local backend state" in pub.diagnostic
      check fx.git("rev-parse HEAD").strip() == localHead
      check fx.git("symbolic-ref --short HEAD").strip() == "main"
      check fx.git("rev-parse --symbolic-full-name '@{u}'").strip() ==
        "refs/remotes/origin/main"
      check fx.bareHead() == remoteHead
      check not fx.remoteHas(lockRel("app", localOid))
      check fx.remoteHas(lockRel("other", remoteOid))

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
        let pub = publishWorkspaceLock(fx.identity, fx.repo,
          @[expected("app", "app", oid)])
        check pub.outcome == lpoFailed
        check fx.bareHead() == remoteBefore

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

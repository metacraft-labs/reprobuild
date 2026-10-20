## The detached cache push that ``repro hooks dispatch post-commit`` fires does
## not keep the hook's caller's output pipe open.
##
## THE DEFECT THIS PINS (reprobuild-pm issue 2026-10-20, "on Windows the
## detached post-commit cache push inherits every inheritable handle of the
## hook, including the caller's output pipe"). git runs ``post-commit`` with
## its output on whatever git's caller supplied. A caller that captures
## ``git commit``'s output -- ``$(...)`` in a shell, a test runner, an agent's
## command tool -- hands the hook the write end of a pipe, and that end is
## inheritable, because it had to be for the hook to receive it.
## ``spawnDetachedNoShell`` started ``repro hooks cache-push`` with
## ``bInheritHandles = TRUE`` and no handle list, so the write end was
## duplicated into a process that lives until the push, and any shared-bare gc
## after it, finishes. The hook returned at once and its caller still saw no
## EOF. This is the defect ``t_auto_started_daemon_does_not_hold_callers_pipe``
## pins for the daemon launch, at a second spawn site.
##
## THE SHAPE OF THE CASE:
##
##   this test (git's caller: reads the pipe to EOF)
##     └─ repro hooks dispatch post-commit, stdout+stderr on ONE pipe
##          └─ repro hooks cache-push (detached)
##               └─ git push → the shared bare's pre-receive, held open
##
## The shared bare carries a ``pre-receive`` hook that marks that it started,
## sleeps ``HoldSeconds`` and marks that it finished, so the cache push is
## still running for a known window after the dispatch exits. The case
## requires the pipe to reach EOF inside that window. Two controls keep it
## honest: the hold must NOT have finished when EOF is seen (EOF because the
## push had already ended proves nothing), and the cache ref must land
## afterwards with the hold having run (a "fix" that never starts the push
## also gives a prompt EOF).
##
## Runs on every platform. On POSIX the push is started through ``setsid ...
## </dev/null >/dev/null 2>&1 &``, which gives the child its own stdio; the
## case pins that this stays so.
##
## Hermetic: a local bare upstream and a shared bare under one
## ``createTempDir``, with ``REPRO_WORKSPACE_CLONES`` pointing into it so the
## detached child resolves the same cache root. No network.

import std/[monotimes, os, osproc, strutils, tempfiles, times, unittest]

import repro_test_support
import repro_workspace_manifests
import shared_clones

const
  HoldSeconds = 15
    ## How long the shared bare's pre-receive keeps the cache push running.
  EofBudgetMs = 8_000
    ## How long after the dispatch exits the pipe may stay open. Well inside
    ## ``HoldSeconds``, so an EOF that only arrives when the push ends cannot
    ## pass; the fixed path reaches EOF as the dispatch exits.
  DispatchDeadlineMs = 120_000
    ## The dispatch must exit on its own; past this the case kills it and
    ## fails rather than wedging the suite.
  PushLandingDeadlineMs = 90_000

proc nowMs(): int64 = getMonoTime().ticks div 1_000_000

type PipeState = enum
  psEof, psOpen

when defined(windows):
  import std/winlean

  const ErrorBrokenPipe = 109

  proc drainUntilEof(handle: FileHandle; timeoutMs: int;
                     collected: var string): PipeState =
    ## Read the pipe until every writer has closed it (EOF, which a pipe
    ## reports as ERROR_BROKEN_PIPE) or ``timeoutMs`` passes with a writer
    ## still holding it. PeekNamedPipe bounds every wait.
    let pipe = Handle(handle)
    let deadline = nowMs() + timeoutMs
    var buffer: array[4096, char]
    while true:
      var available: int32 = 0
      if not peekNamedPipe(pipe, nil, 0, nil, addr available, nil):
        let error = osLastError()
        if error.int32 == ErrorBrokenPipe:
          return psEof
        raiseOSError(error, "PeekNamedPipe on the dispatch's stdout")
      if available > 0:
        var got: int32 = 0
        if readFile(pipe, addr buffer[0], int32(buffer.len), addr got,
            nil) != 0 and got > 0:
          for i in 0 ..< int(got):
            collected.add buffer[i]
        continue
      if nowMs() >= deadline:
        return psOpen
      sleep(50)
else:
  import std/posix

  proc drainUntilEof(handle: FileHandle; timeoutMs: int;
                     collected: var string): PipeState =
    ## Read the pipe until every writer has closed it (``read`` returns 0) or
    ## ``timeoutMs`` passes with a writer still holding it. ``poll`` bounds
    ## every wait.
    let fd = cint(handle)
    let deadline = nowMs() + timeoutMs
    var buffer: array[4096, char]
    while true:
      let remaining = max(0'i64, deadline - nowMs())
      var pfd = TPollfd(fd: fd, events: POLLIN)
      let ready = posix.poll(addr pfd, 1, cint(min(remaining, 200'i64)))
      if ready > 0:
        let got = posix.read(fd, addr buffer[0], buffer.len)
        if got == 0:
          return psEof
        if got > 0:
          for i in 0 ..< got:
            collected.add buffer[i]
          continue
        if errno != EINTR:
          raiseOSError(osLastError(), "read on the dispatch's stdout")
      if nowMs() >= deadline:
        return psOpen

proc reproBinary(): string =
  let root = currentSourcePath().parentDir.parentDir.parentDir
  requireBinary(root / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc git(gitBin: string; args: varargs[string]): string =
  let res = runShell(shellCommand(@[gitBin] & @args))
  doAssert res.code == 0,
    "fixture git step failed: git " & args.join(" ") & "\n" & res.output
  res.output

proc configIdentity(gitBin, repo: string) =
  discard git(gitBin, "-C", repo, "config", "user.email",
    "tester@example.invalid")
  discard git(gitBin, "-C", repo, "config", "user.name", "Pipe Tester")

proc killProcessTree(pid: int) =
  try:
    when defined(windows):
      let taskkill = findExe("taskkill")
      if taskkill.len > 0:
        discard runShell(shellCommand(@[taskkill, "/F", "/T", "/PID", $pid]))
    else:
      discard posix.kill(Pid(pid), SIGKILL)
  except CatchableError:
    discard

proc sweepStrayProcesses(marker: string) =
  ## Kill, as a tree, anything still alive whose command line names
  ## ``marker`` (the scratch directory's basename): the held cache push, its
  ## git children and the shared-bare gc that follows it. See
  ## ``t_post_commit_dispatch_returns_and_detached_push_lands`` for why the
  ## basename and why a tree.
  try:
    when defined(windows):
      let powershell = findExe("powershell")
      if powershell.len == 0:
        return
      let script =
        "$m = '" & marker.replace("'", "''") & "'; " &
        "Get-CimInstance Win32_Process | Where-Object { " &
        "$_.ProcessId -ne $PID -and $_.CommandLine -and " &
        "$_.CommandLine.Contains($m) } | ForEach-Object { $_.ProcessId }"
      let found = runShell(shellCommand(@[powershell, "-NoProfile",
        "-NonInteractive", "-Command", script]))
      for line in found.output.splitLines:
        let pid = line.strip()
        if pid.len > 0 and pid.allCharsInSet({'0' .. '9'}):
          killProcessTree(parseInt(pid))
    else:
      let pkill = findExe("pkill")
      if pkill.len > 0:
        discard runShell(shellCommand(@[pkill, "-9", "-f", marker]))
  except CatchableError:
    discard

type Fixture = object
  workspaceName: string
  repoPath: string
  bare: string
  cacheRoot: string

proc buildFixture(gitBin, scratch: string): Fixture =
  ## One workspace with one repo (``lib-a``) cloned from a local bare upstream
  ## and wired to its shared bare: the shape the post-commit cache push runs
  ## in. Same layout as the W4 dispatch test's fixture.
  let origin = scratch / "origin.git"
  let seed = scratch / "seed"
  discard git(gitBin, "init", "--bare", "-b", "main", origin)
  discard git(gitBin, "init", "-b", "main", seed)
  configIdentity(gitBin, seed)
  writeFile(seed / "README.md", "pipe fixture\n")
  discard git(gitBin, "-C", seed, "add", "README.md")
  discard git(gitBin, "-C", seed, "commit", "-m", "base")
  discard git(gitBin, "-C", seed, "push", origin, "main")
  let originUrl = fileUrl(origin)

  let workspaceRoot = scratch / "workspace"
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  result.workspaceName = extractFilename(workspaceRoot)
  writeFile(workspaceRoot / "projects" / "lib-a.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"lib-a\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & originUrl & "\"\n\n" &
    "includes = [\n  \"repos/lib-a.toml\",\n]\n")
  writeFile(workspaceRoot / "repos" / "lib-a.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"lib-a\"\npath = \"lib-a\"\n" &
    "remote = \"lib-a-origin\"\nrevision = \"main\"\n")
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

  let lockStore = workspaceRoot / ".repro" / "manifests"
  createDir(lockStore)
  discard git(gitBin, "init", "-b", "main", lockStore)
  configIdentity(gitBin, lockStore)
  writeFile(lockStore / ".gitkeep", "")
  discard git(gitBin, "-C", lockStore, "add", "-A")
  discard git(gitBin, "-C", lockStore, "commit", "-m", "seed lock store")

  result.cacheRoot = scratch / "clones-cache"
  let refreshed = refreshSharedBare(gitBin, result.cacheRoot, originUrl)
  doAssert refreshed.ok, "fixture: shared bare refresh failed"
  result.bare = refreshed.sharedBarePath

  result.repoPath = workspaceRoot / "lib-a"
  discard git(gitBin, "clone", "--branch", "main", originUrl, result.repoPath)
  configIdentity(gitBin, result.repoPath)
  doAssert wireAlternates(result.repoPath, result.bare).ok,
    "fixture: alternates wiring failed"

proc holdCachePushes(bare: string) =
  ## A pre-receive in the shared bare that keeps every push into it running
  ## for ``HoldSeconds``. It runs with the bare as its working directory, so
  ## its markers land there.
  let hook = bare / "hooks" / "pre-receive"
  createDir(hook.parentDir)
  writeFile(hook,
    "#!/bin/sh\n" &
    "cat >/dev/null\n" &
    ": > hold-started\n" &
    "sleep " & $HoldSeconds & "\n" &
    ": > hold-finished\n")
  when not defined(windows):
    setFilePermissions(hook, {fpUserRead, fpUserWrite, fpUserExec})

proc cacheRefSha(gitBin, bare, workspaceName: string): string =
  let probe = runShell(shellCommand(@[gitBin, "-C", bare, "rev-parse",
    "--verify", "--quiet", "refs/cache/" & workspaceName & "/main"]))
  if probe.code != 0: "" else: probe.output.strip()

proc teardown(scratch: string) =
  let marker = extractFilename(scratch)
  for round in 0 .. 1:
    sweepStrayProcesses(marker)
    try:
      removeDirEventually(scratch, attempts = 50, sleepMs = 100)
      return
    except CatchableError as err:
      if round == 1:
        stderr.writeLine("teardown: scratch not removed (" & err.msg & "): " &
          scratch)

suite "post-commit cache push stdio":
  test "the detached cache push does not hold the hook caller's pipe open":
    let gitBin = findExe("git")
    doAssert gitBin.len > 0, "this case drives real git pushes; install git"
    let reproBin = reproBinary()
    let scratch = createTempDir("repro-pc-pipe-", "")
    defer: teardown(scratch)

    let fx = buildFixture(gitBin, scratch)
    holdCachePushes(fx.bare)
    putEnv("REPRO_WORKSPACE_CLONES", fx.cacheRoot)
    defer: delEnv("REPRO_WORKSPACE_CLONES")

    writeFile(fx.repoPath / "feature.txt", "new work\n")
    discard git(gitBin, "-C", fx.repoPath, "add", "feature.txt")
    discard git(gitBin, "-C", fx.repoPath, "commit", "-m", "lib-a feature")
    let expectedSha = git(gitBin, "-C", fx.repoPath, "rev-parse",
      "HEAD").strip()
    check cacheRefSha(gitBin, fx.bare, fx.workspaceName) == ""

    # git's caller: the hook's stdout and stderr on one pipe this case reads.
    let dispatch = startProcess(reproBin, workingDir = fx.repoPath,
      args = ["hooks", "dispatch", "post-commit", "--repo-root", fx.repoPath,
        "--"],
      options = {poStdErrToStdOut})
    let pipe = dispatch.outputHandle
    var output = ""
    var state = psOpen
    let dispatchDeadline = nowMs() + DispatchDeadlineMs
    while dispatch.running and nowMs() < dispatchDeadline:
      state = drainUntilEof(pipe, 200, output)
      if state == psEof:
        break
    let dispatchExit = dispatch.peekExitCode()
    if dispatchExit == -1:
      killProcessTree(dispatch.processID)
    checkpoint("dispatch exit=" & $dispatchExit & ", output:\n" & output)
    check dispatchExit == 0

    # THE PROPERTY. The dispatch is gone; the only processes that could still
    # hold the write end are the cache push it started and that push's
    # children, which the pre-receive keeps alive.
    let eofWait = nowMs()
    if state != psEof:
      state = drainUntilEof(pipe, EofBudgetMs, output)
    let eofAfterMs = nowMs() - eofWait
    let holdFinishedAtEof = fileExists(fx.bare / "hold-finished")
    checkpoint("pipe " & $state & " " & $eofAfterMs &
      " ms after the dispatch exited")
    check state == psEof
    # Control: the push was still being held when EOF arrived, so the EOF is
    # not the push having ended.
    check not holdFinishedAtEof

    # Control: the detached push really ran, through the hold.
    var landed = ""
    let landingDeadline = nowMs() + PushLandingDeadlineMs
    while nowMs() < landingDeadline:
      landed = cacheRefSha(gitBin, fx.bare, fx.workspaceName)
      if landed.len > 0:
        break
      sleep(200)
    check landed == expectedSha
    check fileExists(fx.bare / "hold-started")
    dispatch.close()

## W4 — ``repro hooks dispatch post-commit`` RETURNS, and the detached
## cache push it fires ACTUALLY RUNS.
##
## The property under test is a LIVE PROCESS STATE, not a return value.
## ``spawnAsyncCachePush``'s own docstring says it exists to "return
## immediately so the originating commit is never blocked"; on Windows it
## did the opposite. ``cachePushSpawnCommand`` built ``start /b "" <child>``
## and ``spawnAsyncCachePush`` handed it to ``cmd.exe`` after
## ``quoteShell``, which escapes an embedded ``"`` as ``\"`` — the
## ``CommandLineToArgvW`` convention, which ``cmd.exe`` does not implement.
## The empty ``start`` title arrived as ``\"\"``, cmd's quote state broke,
## two ``cmd.exe`` generations sat alive at ~0 CPU forever, the cache-push
## child was never started, and the hook — the real git ``post-commit``
## path — never returned. A ``git commit`` in a hooked Windows workspace
## therefore hung.
##
## Two assertions, and BOTH are load-bearing:
##
##   1. the dispatch RETURNS inside a bounded budget. Falsifiable: the
##      pre-fix binary never returns; the case kills the tree at the hard
##      deadline and fails, it does not hang the suite.
##   2. the detached child ACTUALLY RAN — ``refs/cache/<workspace>/main``
##      lands in the shared bare at the just-committed sha. Falsifiable by
##      a negative control taken before the commit, and load-bearing in a
##      way (1) is not: a "fix" that returns fast by never spawning the
##      pusher satisfies (1) and fails here.
##
## The second case re-runs the whole thing under a QUOTE-HOSTILE fixture —
## an ancestor directory containing a space and a workspace directory
## named with ``&`` — because those are exactly the characters a
## ``cmd.exe`` command line cannot survive unquoted, and
## ``quoteShellWindows`` quotes on whitespace only (``&`` is left bare).
## Legal on NTFS, fatal to a shell round-trip, invisible to a shell-free
## ``CreateProcessW`` spawn.
##
## Process hygiene: every case kills the dispatch tree if it is still
## alive, then sweeps any process whose command line still mentions the
## per-case scratch directory NAME — including the detached child's own
## opportunistic ``git gc`` over the shared bare, which is what still
## holds the fixture open once the ref has landed. Orphans from this exact
## defect outlived the sessions that produced them (one past 12 minutes,
## another past 15, both with their parents gone); a test that reproduces
## the defect must not reproduce that too.
##
## Hermetic: local ``git init --bare`` upstream + shared bare under one
## ``createTempDir``, ``REPRO_WORKSPACE_CLONES`` pinned into that tempdir
## so the detached child resolves the SAME cache root. No network.

import std/[os, osproc, strutils, tempfiles, times, unittest]

import repro_test_support
import repro_workspace_manifests
import shared_clones

const
  HookHardDeadlineMs = 120_000
    ## When the dispatch has not returned by here the case gives up,
    ## kills the tree and FAILS. It is a ceiling, not the budget — it
    ## exists so a hang is a red test in ~2 minutes instead of a wedged
    ## suite (the defect ran out a 900 s runner ceiling once already).
  HookPromptBudgetMs = 60_000
    ## The actual promptness assertion. The fixed path measures 0.56-0.76 s
    ## on this host, so this is ~80x headroom: it cannot flake on a loaded
    ## machine, and the regression it exists to catch does not return at
    ## all. The property being pinned is BOUNDEDNESS, not latency — a
    ## tighter budget would trade the one for the other.
  PushLandingDeadlineMs = 60_000
    ## Budget for the DETACHED child to complete its push. Bounded for
    ## the same reason: a child that never starts must fail the case, not
    ## stall it.
  PollIntervalMs = 50

proc q(value: string): string = quoteShell(value)

proc repoRootDir(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRootDir() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc gitMust(command: string; cwd = ""): string =
  ## Fixture git step. Deliberately ``doAssert`` and NOT ``quit 1``: a
  ## fixture that quits mid-case takes the binary's remaining cases with
  ## it and nothing reconciles the loss.
  let res = runCmd(command, cwd)
  doAssert res.code == 0,
    "fixture git step failed: " & command & "\nexit=" & $res.code &
    "\n" & res.output
  res.output

proc psQuote(value: string): string =
  "'" & value.replace("'", "''") & "'"

proc killProcessTree(pid: int) =
  ## Kill ``pid``, and on Windows its descendants too (``taskkill /T``).
  ## ``Process.kill`` would leave the wedged ``cmd.exe`` generations
  ## behind, which is precisely how this defect produced orphans in the
  ## first place. POSIX has no ``/T`` here — the child is not in its own
  ## process group — so descendants are left to the marker sweep below,
  ## which reaches them by command line rather than by parentage.
  try:
    when defined(windows):
      let taskkill = findExe("taskkill")
      if taskkill.len > 0:
        discard runShell(shellCommand(@[taskkill, "/F", "/T", "/PID", $pid]))
    else:
      let kill = findExe("kill")
      if kill.len > 0:
        discard runShell(shellCommand(@[kill, "-9", $pid]))
  except CatchableError:
    discard

proc sweepStrayProcesses(marker: string) =
  ## Last-resort cleanup: kill anything still alive whose command line
  ## mentions ``marker``. Catches the failure mode ``killProcessTree``
  ## structurally cannot — a detached child that OUTLIVED the dispatch
  ## process, so there is no tree left to walk.
  ##
  ## ``marker`` must be the scratch directory's BASENAME, not its full
  ## path. The hook passes its ``--repo-root`` through with FORWARD
  ## slashes while ``createTempDir`` hands back a backslash path, so a
  ## full-path match silently finds nothing — and a sweep that silently
  ## finds nothing is indistinguishable from a clean run. The basename
  ## carries ``createTempDir``'s random suffix, so it is still specific
  ## to this case and cannot reach anything it did not start.
  ##
  ## Each match is killed as a TREE, not as a process. Killing only the
  ## match is what leaked the fixture twice while this test was being
  ## written: the detached ``repro hooks cache-push`` matches, but the
  ## ``git gc`` / ``git repack`` it spawns does not — those command lines
  ## carry no path at all, only an inherited CWD *inside* the fixture,
  ## and on Windows a live CWD is enough to make the directory
  ## undeletable. Orphaning them is the same mistake in miniature that
  ## this milestone is about.
  try:
    when defined(windows):
      let powershell = findExe("powershell")
      if powershell.len == 0:
        return
      let script =
        "$m = " & psQuote(marker) & "; " &
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

type BoundedRun = object
  returned: bool
  code: int
  elapsedMs: int

proc runBounded(exe: string; args: seq[string]; cwd: string;
                deadlineMs: int): BoundedRun =
  ## Run ``exe`` and wait AT MOST ``deadlineMs`` for it to exit. Uses
  ## ``poParentStreams`` on purpose: no pipes means no second way to
  ## block, so a non-return here can only be the child's own doing.
  let started = epochTime()
  let child = startProcess(exe, workingDir = cwd, args = args,
    options = {poParentStreams})
  result.code = -1
  result.returned = false
  while int((epochTime() - started) * 1000.0) < deadlineMs:
    let peeked = child.peekExitCode()
    if peeked != -1:
      result.code = peeked
      result.returned = true
      break
    sleep(PollIntervalMs)
  result.elapsedMs = int((epochTime() - started) * 1000.0)
  if not result.returned:
    killProcessTree(child.processID)
  try:
    child.close()
  except CatchableError:
    discard

type Fixture = object
  scratch: string
  workspaceRoot: string
  workspaceName: string
  repoPath: string
  bare: string
  cacheRoot: string

proc configIdentity(gitBin, repoPath: string) =
  discard gitMust(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard gitMust(q(gitBin) & " -C " & q(repoPath) &
    " config user.name " & q("W4 Tester"))

proc buildFixture(gitBin, scratch, workspaceSubPath: string): Fixture =
  ## One metadata-only workspace with a single repo (``lib-a``) cloned
  ## from a local bare upstream and wired to a per-upstream shared bare,
  ## i.e. the RA-4 post-commit shape.
  ##
  ## ``workspaceSubPath`` is the workspace directory RELATIVE to
  ## ``scratch`` and may contain separators, so a case can put its
  ## quote-hostile characters BELOW the scratch root. That placement is
  ## not cosmetic: the shared bare's path is derived from the origin URL
  ## with spaces sanitized to ``_``, so a space in the scratch root
  ## renames the very directory the teardown sweep matches on and the
  ## opportunistic ``git gc`` escapes it.
  result.scratch = scratch
  let origin = scratch / "origin.git"
  let seedPath = scratch / "seed"
  discard gitMust(q(gitBin) & " init --bare -b main " & q(origin))
  discard gitMust(q(gitBin) & " init -b main " & q(seedPath))
  configIdentity(gitBin, seedPath)
  writeFile(seedPath / "README.md", "w4 fixture\n")
  discard gitMust(q(gitBin) & " -C " & q(seedPath) & " add README.md")
  discard gitMust(q(gitBin) & " -C " & q(seedPath) & " commit -m base")
  discard gitMust(q(gitBin) & " -C " & q(seedPath) &
    " remote add origin " & q(origin))
  discard gitMust(q(gitBin) & " -C " & q(seedPath) & " push origin main")
  let originUrl = fileUrl(origin)

  result.workspaceRoot = scratch / workspaceSubPath
  createDir(result.workspaceRoot)
  result.workspaceName = extractFilename(result.workspaceRoot)

  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  writeFile(result.workspaceRoot / "projects" / "lib-a.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"lib-a\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & originUrl & "\"\n\n" &
    "includes = [\n  \"repos/lib-a.toml\",\n]\n")
  writeFile(result.workspaceRoot / "repos" / "lib-a.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"lib-a\"\npath = \"lib-a\"\n" &
    "remote = \"lib-a-origin\"\nrevision = \"main\"\n")
  writeWorkspaceBranch(result.workspaceRoot, project = "lib-a", branch = "main")

  # A real ``.repro/manifests`` checkout so the manifest-backed lock route
  # is DECLARED rather than inferred (Unified-Locking-And-Hooks.md §10).
  let lockStore = result.workspaceRoot / ".repro" / "manifests"
  createDir(lockStore)
  discard gitMust(q(gitBin) & " init -b main " & q(lockStore))
  configIdentity(gitBin, lockStore)
  writeFile(lockStore / ".gitkeep", "")
  discard gitMust(q(gitBin) & " -C " & q(lockStore) & " add -A")
  discard gitMust(q(gitBin) & " -C " & q(lockStore) &
    " commit -m " & q("seed lock store"))

  result.cacheRoot = scratch / "clones-cache"
  let refreshed = refreshSharedBare(gitBin, result.cacheRoot, originUrl)
  doAssert refreshed.ok, "fixture: shared bare refresh failed"
  result.bare = refreshed.sharedBarePath

  result.repoPath = result.workspaceRoot / "lib-a"
  discard gitMust(q(gitBin) & " clone --branch main " & q(originUrl) &
    " " & q(result.repoPath))
  configIdentity(gitBin, result.repoPath)
  doAssert wireAlternates(result.repoPath, result.bare).ok,
    "fixture: alternates wiring failed"

proc cacheRefSha(gitBin, bare, workspaceName: string): string =
  ## The ref name is ``q()``-quoted like every other argument: the
  ## quote-hostile case names its workspace ``ws&x``, and on POSIX
  ## ``execCmdEx`` really does go through ``/bin/sh``, where a bare ``&``
  ## would background the command. (A git ref name always uses ``/``, on
  ## every platform — see ``shared_clones.pushCacheRef``.)
  let probe = runCmd(q(gitBin) & " -C " & q(bare) &
    " rev-parse --verify --quiet " &
    q("refs/cache/" & workspaceName & "/main"))
  if probe.code != 0: "" else: probe.output.strip()

type HookObservation = object
  ## What one run of the real post-commit hook DID. Deliberately a record
  ## of observations with no assertions in it: ``check`` outside a ``test``
  ## body silently does nothing (``unittest``'s ``fail`` is guarded by
  ## ``when declared(testStatusIMPL)``, which is injected by the ``test``
  ## template and by nothing else), so a helper proc that "checks" prints
  ## failures and still reports ``[OK]``. Observed here on the first run of
  ## this very file. Every assertion therefore lives in a ``test`` body.
  refBefore: string      ## negative control, taken before the hook runs
  returned: bool         ## did the dispatch process EXIT within the ceiling
  exitCode: int          ## its exit code (-1 if it never returned)
  elapsedMs: int         ## how long it took to return / hit the ceiling
  refAfter: string       ## the cache ref the DETACHED child was to push
  expectedSha: string    ## the just-committed sha it must equal

proc observeHook(gitBin, scratch, workspaceSubPath: string): HookObservation =
  ## Build the fixture, commit, fire the REAL post-commit dispatch under a
  ## hard ceiling, and report what happened. Parameterized only by the
  ## shape of the scratch paths so the plain and the quote-hostile
  ## fixtures share one body.
  let reproBin = reproBinary()
  let fx = buildFixture(gitBin, scratch, workspaceSubPath)

  putEnv("REPRO_WORKSPACE_CLONES", fx.cacheRoot)
  defer: delEnv("REPRO_WORKSPACE_CLONES")

  writeFile(fx.repoPath / "feature.txt", "new work\n")
  discard gitMust(q(gitBin) & " -C " & q(fx.repoPath) & " add feature.txt")
  discard gitMust(q(gitBin) & " -C " & q(fx.repoPath) &
    " commit -m " & q("lib-a feature"))
  result.expectedSha = gitMust(q(gitBin) & " -C " & q(fx.repoPath) &
    " rev-parse HEAD").strip()

  result.refBefore = cacheRefSha(gitBin, fx.bare, fx.workspaceName)

  let run = runBounded(reproBin,
    @["hooks", "dispatch", "post-commit", "--repo-root", fx.repoPath, "--"],
    fx.repoPath, HookHardDeadlineMs)
  result.returned = run.returned
  result.exitCode = run.code
  result.elapsedMs = run.elapsedMs

  # Wait, bounded, for the DETACHED child to land the cache ref.
  let deadline = epochTime() + PushLandingDeadlineMs.float / 1000.0
  while epochTime() < deadline:
    result.refAfter = cacheRefSha(gitBin, fx.bare, fx.workspaceName)
    if result.refAfter.len > 0:
      break
    sleep(PollIntervalMs)

proc teardown(scratch: string) =
  ## Kill first, THEN delete — in that order, in one place, so the order
  ## does not depend on how ``defer`` unwinds.
  ##
  ## The detached child does more than the push: on a never-maintained
  ## shared bare it also runs the opportunistic ``git gc``
  ## (``maintainSharedBare``), which is still holding the bare open at the
  ## moment the ref lands and the case stops waiting. That is what the
  ## sweep is for.
  ##
  ## A scratch directory the OS will not release is a cleanup nuisance and
  ## NOT a verdict on the invariant under test, so removal failure is
  ## reported and swallowed rather than turned into a red case. The kill
  ## is what actually matters here, and it has already happened.
  ##
  ## Two rounds, not one. The first-run-after-a-rebuild case is cold — the
  ## 36 MB binary is being paged in and the shared bare is being gc'd —
  ## and a single sweep-then-delete loses that race often enough to leave
  ## a directory behind. Sweeping again between attempts costs nothing on
  ## the common path (the first round already succeeded and the loop is
  ## not entered a second time).
  let marker = extractFilename(scratch)
  for round in 0 .. 1:
    sweepStrayProcesses(marker)
    try:
      removeDirEventually(scratch, attempts = 50, sleepMs = 100)
      return
    except CatchableError as err:
      if round == 1:
        stderr.writeLine("W4 teardown: scratch not removed (" & err.msg &
          "): " & scratch)

proc requireGitBin(): string =
  result = findExe("git")
  doAssert result.len > 0,
    "W4 blocker: this gate drives a real git post-commit hook and there " &
    "is no residual assertion left once git is missing; install git."

suite "W4 — post-commit dispatch returns and its detached push runs":

  test "test_w4_post_commit_dispatch_returns_and_detached_push_lands":
    let gitBin = requireGitBin()
    let scratch = createTempDir("repro-w4-postcommit-", "")
    defer: teardown(scratch)

    let obs = observeHook(gitBin, scratch, "workspace")
    checkpoint("post-commit dispatch returned=" & $obs.returned &
      " exit=" & $obs.exitCode & " after " & $obs.elapsedMs & " ms")

    # Negative control: without this, (2) could pass on a pre-existing ref.
    check obs.refBefore == ""
    # (1) It RETURNED. This is the assertion the defect fails: the pre-fix
    # binary blocks on two wedged ``cmd.exe`` generations indefinitely.
    check obs.returned
    # And it returned PROMPTLY — the hook must never block a commit.
    check obs.elapsedMs < HookPromptBudgetMs
    # Best-effort by contract: a post-commit hook never fails the commit.
    check obs.exitCode == 0
    # (2) The DETACHED child actually ran. NOT implied by (1): a spawn that
    # is simply dropped returns instantly and lands nothing.
    check obs.refAfter == obs.expectedSha

  test "test_w4_post_commit_dispatch_survives_quote_hostile_paths":
    # A space in an ancestor directory (``C:\Program Files``-shaped) and a
    # ``&`` in the workspace name. ``quoteShellWindows`` quotes on
    # whitespace only, so the ``&`` reaches a shell command line bare and
    # cmd.exe reads it as a command separator; the space forces the quotes
    # whose escaping broke the shell round-trip in the first place. Both
    # are legal on NTFS and invisible to a shell-free spawn.
    #
    # The space sits BELOW the scratch root, not in it: the shared bare is
    # named after the origin URL with spaces sanitized to ``_``, so a
    # space in the scratch root would rename the directory the teardown
    # sweep matches on and leak the opportunistic ``git gc``. Both hostile
    # characters still reach ``--repo-root`` / ``--workspace-name``, which
    # is what the fix has to survive.
    let gitBin = requireGitBin()
    let scratch = createTempDir("repro-w4-hostile-", "")
    defer: teardown(scratch)

    let obs = observeHook(gitBin, scratch, "has space" / "ws&x")
    checkpoint("post-commit dispatch returned=" & $obs.returned &
      " exit=" & $obs.exitCode & " after " & $obs.elapsedMs & " ms")

    check obs.refBefore == ""
    check obs.returned
    check obs.elapsedMs < HookPromptBudgetMs
    check obs.exitCode == 0
    check obs.refAfter == obs.expectedSha

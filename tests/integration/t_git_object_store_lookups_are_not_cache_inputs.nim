## A by-name lookup in a git object store is content-addressed, and the
## store's churn must not invalidate an action that only looked objects up.
##
## Issue: `reprobuild-pm/issues/2026-09-30-flake-dev-env-invalidated-by-git-
## loose-object-probes.md`. The dev-env introspection edge runs
## `nix print-dev-env`, which fetches the flake as `git+file` and therefore
## reads and probes paths inside the repository's object store. That store is
## shared by every worktree of the checkout and written concurrently by every
## agent committing into it, so a loose object appearing, an existing object
## being re-written (git FRESHENS its mtime), or a repack moving objects into a
## pack changed the recorded metadata and missed the edge:
##
##   p1 introspection cdMiss | input metadata changed: …/.git/objects/23/8b3c…
##
## although nothing the action could observe had changed — a git object is
## named by the hash of its content, so a name resolves to the same bytes
## whether it is loose, packed, freshened or repacked.
##
## MOCK POLICY — NO MOCKS. The scenario suites drive the real `runBuild`
## scheduler, the real per-edge `ActionCache` in `repro_local_store`, the
## graph-built io-monitor (`build/bin/repro internal io monitor` plus the
## graph-built shim), a real `git` and a real `/bin/sh`, against real
## repositories in a real temporary directory. What is under test is what the
## monitor RECORDS when real git touches a real object store; a hand-built
## evidence set would assert only what its author believed git does, and the
## measured set (loose objects read AND probed, pack/idx/rev read, the pack
## directory enumerated) is wider than the belief that motivated the issue.
## The predicate suite at the end is the unit-level half and is likewise
## mock-free: it asks the exported predicate about paths inside repositories
## that `git init` really created, because the predicate's soundness rests
## on a filesystem check (is the parent a git directory?) that a string-only
## fixture could not exercise.
##
## WHY `ffpTimestamp`. It is the engine default (`action()`), and it is the
## policy under which the issue's own message — `input metadata changed` —
## is produced: a freshened object keeps its bytes and moves its mtime, which
## `ffpHybrid` would cut off by rehashing and therefore hide.
##
## THE CONTROLS ARE THE POINT as much as the positive cases. An elision that
## drops a genuine input serves a stale result, which is strictly worse than
## the miss being fixed, so every positive case is paired with one an
## over-broad predicate would fail:
##
## * a commit that moves the branch ref MUST still invalidate — refs and HEAD
##   decide which object names are looked up and stay observed;
## * a NON-git tree shaped exactly like an object store MUST still invalidate
##   when the file changes — the shape alone licenses nothing;
## * `objects/info/alternates` appearing MUST still invalidate — it decides
##   WHERE names are looked up, so it is not a by-name lookup itself.
##
## THE KEY IS CHECKED ON EVERY PLATFORM, PUBLICATION ONLY WHERE IT EXISTS.
## Each scenario first asks `cacheInputPaths` / `cacheEnumeratedDirectories`
## what the key WOULD be built from, over the evidence the monitor really
## recorded in run 1: no observed by-name object-store entry may be in it,
## while `HEAD`, `refs/heads/main` and `objects/info/alternates` (and, in the
## lookalike control, the lookalike file) must be. That is the classification
## itself, and it needs no published record. The reuse half — a second run
## hitting after the store moved — needs one, and on macOS there
## never is: io-mon's `docs/usage.md` ("macOS limitation
## (normative)", io-mon 57ce305) makes every capture there carry an
## `mrEventLoss` tree-lifetime marker and grade `mcIncomplete`, consumers
## MUST conservatively rebuild, and nothing promotes such a capture to
## complete. So where `NoTreeLifetimeGuard` holds, the publication-dependent
## assertions are replaced by the specified fail-closed behaviour — the
## marker and `monitor-loss` are reported, no record exists, and the next run
## re-launches and reads the current store — and Linux keeps every reuse
## assertion unchanged. Neither arm filters or overrides the loss.
##
## TWO HOST FACTS THE FIXTURE ACCOMMODATES, both measured on macOS:
##
## * `/bin/sh` is SIP-protected, so the kernel strips the shim's injection
##   from it and from everything it spawns — git included — and run 1 would
##   observe only `/bin/sh`. On macOS the script is written to a `#!/bin/sh`
##   file run as argv[0], which io-mon's shebang handling hands to its shipped
##   non-SIP shell (the same route as `t_da1i_evidence_scope_reaches_io_mon`).
## * `/tmp` (and so a dev shell's `TMPDIR`) is a firmlink to `/private/tmp`;
##   git canonicalises its git directory and the macOS shim records
##   `F_GETPATH` spellings. The fixture root is resolved once, so every
##   prefix this file compares against is spelled as the monitor spells it.

import std/[os, osproc, sequtils, strutils, tempfiles, times, unittest]

import repro_build_engine
import repro_core
import repro_local_store
import repro_test_support
import repro_test_support/descendant_guard_expectations
import repro_test_support/reasoned_skip

const RepoRootMarker = "repro.nim"

const NoGitReason =
  "no `git` on PATH: every case here drives or inspects a real git " &
  "repository, so without one there is nothing to observe"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

var cachedMonitorTools: MonitorTools
var cachedMonitorToolsReady = false

proc monitorTools(repoRoot: string): MonitorTools =
  if not cachedMonitorToolsReady:
    cachedMonitorTools = prepareMonitorTools(repoRoot,
      repoRoot / "build" / "test-monitor-git-objects", "git-objects-monitor")
    putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
    cachedMonitorToolsReady = true
  cachedMonitorTools

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

const ReuseDecisions = {cdHit, cdHybridCutoff}

proc gitExe(): string =
  ## The REAL git image, symlinks resolved. On a Nix host `findExe` answers
  ## with a profile symlink (`~/.nix-profile/bin/git`); handing the action the
  ## resolved store path keeps the profile's own symlink chain — which is not
  ## what this suite is about — out of the recorded input set.
  result = findExe("git")
  if result.len > 0:
    try:
      result = expandFilename(result)
    except OSError:
      discard

proc isVolatilePrefix(path: string): bool =
  ## Mirrors the engine's `isVolatileMonitorPath`: anything the monitor records
  ## under these prefixes is dropped before the key sees it, so a fixture
  ## there would make every assertion below vacuous. Same guard, same reason
  ## as `t_executed_binary_is_a_recorded_input.nim`.
  for prefix in ["/run", "/proc", "/sys", "/dev"]:
    if path == prefix or path.startsWith(prefix & "/"):
      return true
  false

proc nonVolatileTempBase(): string =
  result = getTempDir()
  if result.isVolatilePrefix():
    result = "/tmp"

type Fixture = object
  root: string
  home: string
  repo: string       ## the work tree; its git directory is `repo/.git`
  workRoot: string   ## the action's cwd
  logDir: string
  cacheRoot: string
  git: string

proc gitDir(f: Fixture): string = f.repo / ".git"
proc logPath(f: Fixture; name: string): string = f.logDir / (name & ".log")

proc gitEnv(f: Fixture): seq[string] =
  ## Everything git could read from the HOST is pinned to the fixture: no
  ## system config, a fixture `$HOME`, and a fixed identity. Both for the
  ## harness's own git calls and for the action, so a developer's
  ## `~/.gitconfig` (a `gc.auto`, a `core.fsmonitor`, a hook path) can neither
  ## mutate the store behind the test's back nor enter the action's key.
  @["HOME=" & f.home,
    "XDG_CONFIG_HOME=" & f.home / ".config",
    "GIT_CONFIG_NOSYSTEM=1",
    "GIT_AUTHOR_NAME=fixture", "GIT_AUTHOR_EMAIL=fixture@example.invalid",
    "GIT_COMMITTER_NAME=fixture",
    "GIT_COMMITTER_EMAIL=fixture@example.invalid",
    "LC_ALL=C",
    "PATH=" & f.git.parentDir]

proc git(f: Fixture; args: varargs[string]): string =
  var cmd = quoteShell(f.git)
  for arg in args:
    cmd.add(' ')
    cmd.add(quoteShell(arg))
  var envPrefix = "env -i"
  for item in f.gitEnv():
    envPrefix.add(' ')
    envPrefix.add(quoteShell(item))
  let (output, code) = execCmdEx(envPrefix & " " & cmd, workingDir = f.repo)
  if code != 0:
    raise newException(OSError,
      "git " & args.join(" ") & " failed (" & $code & "): " & output)
  output.strip()

proc commitFile(f: Fixture; content: string) =
  writeFile(f.repo / "a.txt", content)
  discard f.git("add", "a.txt")
  discard f.git("commit", "-q", "-m", "commit " & content)

proc looseObjectPath(f: Fixture; oid: string): string =
  f.gitDir / "objects" / oid[0 .. 1] / oid[2 .. ^1]

proc makeFixture(prefix: string): Fixture =
  # Resolved, because the monitor records resolved spellings (see the header):
  # an unresolved `/tmp/...` root would make every prefix comparison below
  # miss paths the monitor did record under `/private/tmp/...`.
  let root = expandFilename(
    createTempDir(prefix, "", dir = nonVolatileTempBase()))
  if root.isVolatilePrefix():
    raise newException(IOError,
      "fixture root " & root & " is under a volatile prefix the engine drops " &
      "from evidence; this suite cannot assert anything from there")
  result = Fixture(
    root: root,
    home: root / "home",
    repo: root / "repo",
    workRoot: root / "work",
    logDir: root / "work" / "out",
    cacheRoot: root / "cache",
    git: gitExe())
  createDir(result.home)
  createDir(result.repo)
  createDir(result.logDir)
  discard result.git("init", "-q", "-b", "main")
  # Nothing may repack, prune or write a commit-graph behind the test's back:
  # each scenario moves the store itself, deliberately, and an automatic gc
  # between two runs would make "what changed" unknowable.
  discard result.git("config", "gc.auto", "0")
  discard result.git("config", "maintenance.auto", "false")
  discard result.git("config", "core.commitGraph", "false")
  result.commitFile("one")

proc monitoredEdge(f: Fixture; id: string; script: string): BuildAction =
  ## NOTE what is NOT here: nothing under the repository is declared. Under
  ## `dgAutomaticMonitor` every path the action depends on comes from the
  ## monitor, which is exactly how the dev-env introspection edge sees the
  ## flake's object store.
  let command =
    when defined(macosx):
      # A SIP-protected `/bin/sh` root would strip injection from git too
      # (see the header); a `#!/bin/sh` file lets io-mon substitute its
      # non-SIP shell. Linux keeps `/bin/sh -c`: nothing strips injection
      # there, and the file would only add one more recorded input.
      let scriptPath = f.root / "scripts" / (id.replace('/', '-') & ".sh")
      createDir(scriptPath.parentDir)
      writeFile(scriptPath, "#!/bin/sh\n" & script & "\n")
      setFilePermissions(scriptPath, {fpUserRead, fpUserWrite, fpUserExec})
      @[scriptPath]
    else:
      @["/bin/sh", "-c", script]
  action(id, command,
    cwd = f.workRoot,
    inputs = [],
    outputs = [],
    env = f.gitEnv(),
    cacheable = true,
    weakFingerprint = weakFingerprintFromText("git-object-store." & id),
    dependencyPolicy = automaticMonitorGatheringPolicy(),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc gitReadEdge(f: Fixture; name: string): BuildAction =
  ## The read side of `nix`'s git+file fetch, in miniature: resolve HEAD to a
  ## commit, walk to its tree, read a blob. Every object is looked up BY NAME,
  ## and each name is decided by `HEAD` / `refs/heads/main`, which the action
  ## also reads. The log line records both the run and what was read, so
  ## "re-ran" and "re-ran and saw the new content" are separately observable.
  let g = quoteShell(f.git)
  let repo = quoteShell(f.repo)
  f.monitoredEdge("git-objects/" & name,
    g & " -C " & repo & " cat-file -p HEAD > /dev/null && " &
    "echo \"ran $(" & g & " -C " & repo & " show HEAD:a.txt)\" >> " &
    quoteShell(f.logPath(name)))

proc monitoredConfig(repoRoot, cacheRoot: string): BuildEngineConfig =
  let tools = monitorTools(repoRoot)
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.fallbackToRunQuotaBypass = true
  result.maxParallelism = 1'u32
  result.monitorCliPath = tools.monitorCliPath
  result.monitorCliArgs = tools.monitorCliArgs

proc runLines(f: Fixture; name: string): seq[string] =
  let p = f.logPath(name)
  if not fileExists(p):
    return @[]
  p.readFile.splitLines.filterIt(it.strip().len > 0)

proc observedUnder(r: ActionResult; dir: string): seq[string] =
  ## Every OBSERVED path under `dir`, across reads and probes — the
  ## denominator that keeps the positive cases honest. A hit after the store
  ## moved proves nothing unless the first run demonstrably looked inside it.
  let prefix = dir.replace('\\', '/') & "/"
  for path in r.evidence.monitorReads.toSeq & r.evidence.monitorProbes.toSeq:
    if path.replace('\\', '/').startsWith(prefix):
      result.add(path)

proc recordedInputsUnder(f: Fixture; edge: BuildAction; dir: string):
    seq[string] =
  var cache = openActionCache(f.cacheRoot / "action-cache")
  let hot = cache.readHotRecord(edge.weakFingerprint)
  if not hot.found:
    return @[]
  let prefix = dir.replace('\\', '/') & "/"
  for input in hot.record.inputs:
    if input.path.replace('\\', '/').startsWith(prefix) or
        input.path.replace('\\', '/') == dir.replace('\\', '/'):
      result.add(input.path)

proc checkFailsClosed(f: Fixture; edge: BuildAction; r0: ActionResult) =
  ## Where `NoTreeLifetimeGuard` holds, the specified outcome of run 1 in
  ## place of a published record (io-mon `docs/usage.md`, "macOS
  ## limitation (normative)"): the capture carries this platform's exact
  ## tree-lifetime marker, the engine reports the skip as `monitor-loss`, and
  ## nothing was published — so a later run cannot reuse it and must rebuild.
  ## Asserting all three keeps the arm from passing on an unrelated failure
  ## (a run that published nothing because it observed nothing, say).
  var markers = 0
  for diagnostic in r0.evidence.diagnostics:
    const lead = "monitor loss: "
    if diagnostic.startsWith(lead) and
        diagnostic[lead.len .. ^1].isTreeLifetimeLimitation:
      inc markers
  checkpoint(edge.id & " diagnostics: " & $r0.evidence.diagnostics)
  checkpoint(edge.id & " publish skipped: " & r0.cachePublishSkipReason)
  check markers == 1
  check "monitor-loss" in r0.cachePublishSkipReason
  var cache = openActionCache(f.cacheRoot / "action-cache")
  check not cache.readHotRecord(edge.weakFingerprint).found

proc checkKeyClassification(f: Fixture; edge: BuildAction; r0: ActionResult) =
  ## The classification under test, asked of the evidence the monitor REALLY
  ## recorded in run 1 rather than of a published record, so it holds on every
  ## platform (see the header). Every observed by-name object-store entry must
  ## be absent from the key, and what decides which names are looked up —
  ## `HEAD`, the branch ref, `objects/info/alternates` — must be in it.
  let objects = f.gitDir / "objects"
  let inputs = edge.cacheInputPaths(r0.evidence)
  let enumerated = edge.cacheEnumeratedDirectories(r0.evidence)
  let byName = r0.observedUnder(objects).filterIt(isGitObjectStorePath(it))
  # The denominator: a loose object (the issue's own `objects/<2>/<38>`
  # shape) must be among what was observed, or "none is in the key" would
  # hold of an evidence set that never reached the store at all.
  let head = f.git("rev-parse", "HEAD")
  checkpoint(edge.id & " by-name observed: " & $byName)
  check f.looseObjectPath(head) in byName
  for path in byName:
    checkpoint(path)
    check path notin inputs
    check path notin enumerated
  for path in r0.evidence.monitorDirectoryEnumerations.toSeq:
    if path.isGitObjectStorePath:
      checkpoint(path)
      check path notin enumerated
  check (f.gitDir / "HEAD") in inputs
  check (f.gitDir / "refs" / "heads" / "main") in inputs
  check (objects / "info" / "alternates") in inputs

type FirstRun = object
  config: BuildEngineConfig
  result: ActionResult

proc firstRun(f: Fixture; repoRoot: string; edge: BuildAction;
              name: string): FirstRun =
  ## Run 1: execute, publish where the platform can, and prove the action
  ## really looked inside the object store — otherwise every "still a hit"
  ## below is vacuous. The observation precondition holds on EVERY platform.
  result.config = monitoredConfig(repoRoot, f.cacheRoot)
  let first = runBuild(graph([edge]), result.config)
  let r0 = first.byId(edge.id)
  result.result = r0
  let seen = r0.observedUnder(f.gitDir / "objects")
  checkpoint(name & " first: status=" & $r0.status & " launched=" &
    $r0.launched & " stderr=" & r0.stderr)
  checkpoint(name & " observed under objects/: " & $seen.len & " " & $seen)
  check r0.status == asSucceeded
  check r0.launched
  check f.runLines(name).len == 1
  check seen.len > 0
  f.checkKeyClassification(edge, r0)
  if NoTreeLifetimeGuard:
    f.checkFailsClosed(edge, r0)

proc secondRun(f: Fixture; config: BuildEngineConfig; edge: BuildAction;
               name: string): ActionResult =
  let second = runBuild(graph([edge]), config)
  result = second.byId(edge.id)
  checkpoint(name & " second: status=" & $result.status & " decision=" &
    $result.cacheDecision & " launched=" & $result.launched & " missReason=" &
    result.cacheMissReason)

proc checkReuse(f: Fixture; r: ActionResult; name: string) =
  ## The positive cases' run 2, after the store moved under names run 1 read.
  ## Where records are published the edge must be reused without running.
  ## Where `NoTreeLifetimeGuard` holds nothing was published (run 1 checked
  ## that), so the specified outcome is a conservative rebuild: the edge
  ## re-launches, succeeds, and reads the same content through the moved
  ## store. That arm says nothing about the elision — `checkKeyClassification`
  ## carries it there — and must not be read as a reuse result.
  if NoTreeLifetimeGuard:
    check r.status == asSucceeded
    check r.cacheDecision notin ReuseDecisions
    check r.launched
    check f.runLines(name) == @["ran one", "ran one"]
  else:
    check r.cacheDecision in ReuseDecisions
    check not r.launched
    check f.runLines(name).len == 1

suite "a git object store's churn does not invalidate a by-name lookup":

  test "an object git re-writes (freshens) does not invalidate":
    ## The cheapest and most frequent form of the issue. Writing an object
    ## that already exists makes git `utime` the existing loose file
    ## (`freshen_loose_object`) rather than write it again: same name, same
    ## bytes, new mtime. Every `git add` of unchanged content and every commit
    ## that re-creates an existing tree does this, in a store several agents
    ## share. Under `ffpTimestamp` the recorded loose object's metadata moves
    ## and, before the fix, the edge missed with exactly the issue's message.
    if gitExe().len == 0:
      skip(NoGitReason)
    else:
      let repoRoot = findRepoRoot()
      let f = makeFixture("repro-git-objects-freshen-")
      defer: removeDir(f.root)
      let edge = f.gitReadEdge("freshen")
      let config = f.firstRun(repoRoot, edge, "freshen").config
      let blob = f.git("rev-parse", "HEAD:a.txt")
      let loose = f.looseObjectPath(blob)
      check fileExists(loose)
      let before = getLastModificationTime(loose)
      # A filesystem whose mtime granularity is coarser than the run would
      # make the freshen invisible; wait it out rather than assume.
      sleep(20)
      discard f.git("hash-object", "-w", "a.txt")
      let after = getLastModificationTime(loose)
      checkpoint("freshen: blob " & blob & " mtime " & $before & " -> " &
        $after)
      # Precondition: the store really moved under a name the action read.
      check after != before
      let r = f.secondRun(config, edge, "freshen")
      f.checkReuse(r, "freshen")

  test "objects moving from loose into a pack do not invalidate":
    ## `git repack -a -d` + `git prune-packed`: every loose object the first
    ## run read is deleted and the same names now resolve inside a new pack.
    ## Refs are untouched (deliberately NOT `git gc`, which also packs refs
    ## and would make this a ref change). Before the fix this missed on the
    ## vanished loose objects and on the pack directory's new membership.
    if gitExe().len == 0:
      skip(NoGitReason)
    else:
      let repoRoot = findRepoRoot()
      let f = makeFixture("repro-git-objects-repack-")
      defer: removeDir(f.root)
      let edge = f.gitReadEdge("repack")
      let config = f.firstRun(repoRoot, edge, "repack").config
      let head = f.git("rev-parse", "HEAD")
      let refBefore = readFile(f.gitDir / "refs" / "heads" / "main")
      discard f.git("repack", "-a", "-d", "-q")
      discard f.git("prune-packed")
      # Preconditions: the commit is no longer loose, a pack now exists, and
      # the ref the action read is byte-identical.
      check not fileExists(f.looseObjectPath(head))
      check toSeq(walkFiles(f.gitDir / "objects" / "pack" / "pack-*.pack")).len == 1
      check readFile(f.gitDir / "refs" / "heads" / "main") == refBefore
      let r = f.secondRun(config, edge, "repack")
      f.checkReuse(r, "repack")

  test "control: a commit that moves the branch invalidates":
    ## The other half of the soundness argument: the object NAMES the action
    ## resolves are decided by HEAD and the ref, which stay observed. A new
    ## commit changes the ref, so the edge must re-run and see new content.
    if gitExe().len == 0:
      skip(NoGitReason)
    else:
      let repoRoot = findRepoRoot()
      let f = makeFixture("repro-git-objects-commit-")
      defer: removeDir(f.root)
      let edge = f.gitReadEdge("commit")
      let config = f.firstRun(repoRoot, edge, "commit").config
      # The ref really is a recorded input (the guarantee this control leans
      # on), not merely something the engine happened to notice. Without a
      # published record (`NoTreeLifetimeGuard`) `firstRun` has already
      # checked the ref is in the key the record would have been built from.
      if not NoTreeLifetimeGuard:
        check f.recordedInputsUnder(edge, f.gitDir / "refs").len > 0
      sleep(20)
      f.commitFile("two")
      let r = f.secondRun(config, edge, "commit")
      check r.cacheDecision notin ReuseDecisions
      check r.launched
      check f.runLines("commit") == @["ran one", "ran two"]

  test "control: objects/info/alternates appearing invalidates":
    ## `alternates` decides WHERE names are looked up. It is not named by its
    ## content and is not a by-name lookup, so it must stay observed: the
    ## first run probed it absent, and it appearing must re-run the edge.
    if gitExe().len == 0:
      skip(NoGitReason)
    else:
      let repoRoot = findRepoRoot()
      let f = makeFixture("repro-git-objects-alternates-")
      defer: removeDir(f.root)
      let edge = f.gitReadEdge("alternates")
      let config = f.firstRun(repoRoot, edge, "alternates").config
      let alternates = f.gitDir / "objects" / "info" / "alternates"
      # As in the commit control: without a published record, `firstRun`'s
      # key check is what shows `alternates` is kept.
      if not NoTreeLifetimeGuard:
        check alternates in f.recordedInputsUnder(edge, f.gitDir / "objects")
      let other = f.root / "other.git"
      discard f.git("init", "-q", "--bare", other)
      writeFile(alternates, other / "objects" & "\n")
      let r = f.secondRun(config, edge, "alternates")
      check r.cacheDecision notin ReuseDecisions
      check r.launched
      # The miss can only NAME `alternates` when there was a record to
      # compare it against; without one the rebuild is unconditional, and
      # the run must still have seen the store as it now is.
      if NoTreeLifetimeGuard:
        check f.runLines("alternates") == @["ran one", "ran one"]
      else:
        check "alternates" in r.cacheMissReason

  test "`git -C` paths are not re-anchored on the action's cwd":
    ## Issue: `reprobuild-pm/issues/2026-10-18-macos-shim-records-relative-
    ## paths-the-engine-anchors-on-the-action-cwd.md`. `git -C <repo>`
    ## chdir()s into the repository and then opens `.git/HEAD`,
    ## `.git/objects/xx/...` and probes `.mailmap` and `HEAD:a.txt` by
    ## RELATIVE path. The macOS monitor recorded those strings verbatim and
    ## the evidence fold joined them onto the action's cwd, so the key carried
    ## phantom inputs `<work>/.git/HEAD`, `<work>/.git/objects/...`,
    ## `<work>/.mailmap` that git never looked at — creating any of them in
    ## the action's cwd would have missed the cache. Every relative path has
    ## to be anchored on the directory the process was in when it made the
    ## call.
    ##
    ## The action's cwd is `work/`, and git does nothing there but name it
    ## (its startup `getcwd`). So no path BELOW `work/` may be observed,
    ## enumerated or folded into the key. The key is asked of the evidence
    ## (`cacheInputPaths` / `cacheEnumeratedDirectories`), as
    ## `checkKeyClassification` does, so the case holds where no record is
    ## published (see the header). The positive half — the repository's own
    ## `.git` was observed — keeps the negative half from passing on an empty
    ## capture.
    ##
    ## git is the action's root process (the resolved Nix image, not SIP
    ## protected), so neither a `/bin/sh` root nor the script route stands
    ## between the monitor and the calls this case inspects.
    if gitExe().len == 0:
      skip(NoGitReason)
    else:
      let repoRoot = findRepoRoot()
      let f = makeFixture("repro-git-objects-anchor-")
      defer: removeDir(f.root)
      let edge = action("git-objects/anchor",
        [f.git, "-C", f.repo, "show", "HEAD:a.txt"],
        cwd = f.workRoot,
        inputs = [],
        outputs = [],
        env = f.gitEnv(),
        cacheable = true,
        weakFingerprint = weakFingerprintFromText("git-object-store.anchor"),
        dependencyPolicy = automaticMonitorGatheringPolicy(),
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let config = monitoredConfig(repoRoot, f.cacheRoot)
      let r0 = runBuild(graph([edge]), config).byId(edge.id)
      checkpoint("anchor: status=" & $r0.status & " stderr=" & r0.stderr)
      check r0.status == asSucceeded
      check r0.launched
      check r0.observedUnder(f.gitDir).len > 0
      check (f.gitDir / "HEAD") in edge.cacheInputPaths(r0.evidence)
      let work = f.workRoot
      let underWork = proc(path: string): bool =
        path.replace('\\', '/').startsWith(work.replace('\\', '/') & "/")
      let phantoms = r0.observedUnder(work) &
        r0.evidence.monitorDirectoryEnumerations.toSeq.filter(underWork) &
        edge.cacheInputPaths(r0.evidence).filter(underWork) &
        edge.cacheEnumeratedDirectories(r0.evidence).filter(underWork)
      checkpoint("paths attributed to the action's cwd: " & $phantoms)
      check phantoms.len == 0

  test "control: a non-git tree shaped like an object store stays observed":
    ## The SHAPE `objects/<2 hex>/<38 hex>` licenses nothing on its own. Here
    ## it lives under a directory that is not a git directory (no `HEAD`, no
    ## `refs`), so nothing makes its name a function of its content, and a
    ## change to the file must re-run the action that read it.
    let repoRoot = findRepoRoot()
    let f = makeFixture("repro-git-objects-lookalike-")
    defer: removeDir(f.root)
    let lookalikeDir = f.root / "data" / "objects" / "ab"
    createDir(lookalikeDir)
    let lookalike = lookalikeDir / repeat('c', 38)
    writeFile(lookalike, "first\n")
    # Shell builtins only: the action's `PATH` is git's own directory, so an
    # external `cat` would not resolve — and a failed lookup reads nothing,
    # which would make this control pass vacuously on an empty key.
    let edge = f.monitoredEdge("git-objects/lookalike",
      "read -r line < " & quoteShell(lookalike) & " && echo \"ran $line\" >> " &
      quoteShell(f.logPath("lookalike")))
    let config = monitoredConfig(repoRoot, f.cacheRoot)
    let r0 = runBuild(graph([edge]), config).byId(edge.id)
    check r0.status == asSucceeded
    # The key half holds everywhere; the record half where one is published.
    check lookalike in edge.cacheInputPaths(r0.evidence)
    if NoTreeLifetimeGuard:
      f.checkFailsClosed(edge, r0)
    else:
      check lookalike in f.recordedInputsUnder(edge, f.root / "data")
    sleep(20)
    writeFile(lookalike, "second\n")
    let r = f.secondRun(config, edge, "lookalike")
    check r.cacheDecision notin ReuseDecisions
    check r.launched
    check f.runLines("lookalike") == @["ran first", "ran second"]

suite "isGitObjectStorePath recognises exactly the by-name entries":

  let hex40 = "0123456789abcdef0123456789abcdef01234567"
  let hex64 = hex40 & "89abcdef0123456789abcdef"
  let loose38 = hex40[2 .. ^1]
  let loose62 = hex64[2 .. ^1]

  proc initRepo(dir: string; bare: bool) =
    createDir(dir)
    let args = if bare: "init -q --bare" else: "init -q"
    let (output, code) = execCmdEx("env -i GIT_CONFIG_NOSYSTEM=1 HOME=" &
      quoteShell(dir) & " " & quoteShell(gitExe()) & " " & args & " " &
      quoteShell(dir))
    if code != 0:
      raise newException(OSError, "git init failed: " & output)

  test "every by-name entry and derived index of a real git directory":
    if gitExe().len == 0:
      skip(NoGitReason)
    else:
      let root = createTempDir("repro-git-objects-predicate-", "")
      defer: removeDir(root)
      initRepo(root / "work", bare = false)
      initRepo(root / "shared.git", bare = true)
      for gitDir in [root / "work" / ".git", root / "shared.git"]:
        let o = gitDir / "objects"
        # NONE of these needs to exist: a probe of an absent loose object is
        # the issue's own case. Only the git directory has to be real.
        for path in [
            o, o & "/", o / "ab", o / "ab" / loose38, o / "ab" / loose62,
            o / "pack", o / "pack" & "/",
            o / "pack" / ("pack-" & hex40 & ".pack"),
            o / "pack" / ("pack-" & hex40 & ".idx"),
            o / "pack" / ("pack-" & hex40 & ".rev"),
            o / "pack" / ("pack-" & hex40 & ".bitmap"),
            o / "pack" / ("pack-" & hex64 & ".idx"),
            o / "pack" / "multi-pack-index",
            o / "pack" / ("multi-pack-index-" & hex40 & ".bitmap"),
            o / "pack" / ("multi-pack-index-" & hex40 & ".rev"),
            o / "pack" / "multi-pack-index.d",
            o / "pack" / "multi-pack-index.d" / "multi-pack-index-chain",
            o / "pack" / "multi-pack-index.d" /
              ("multi-pack-index-" & hex40 & ".midx"),
            o / "info" / "commit-graph",
            o / "info" / "commit-graphs",
            o / "info" / "commit-graphs" / "commit-graph-chain",
            o / "info" / "commit-graphs" / ("graph-" & hex40 & ".graph"),
            o / "info" / "packs"]:
          checkpoint(path)
          check isGitObjectStorePath(path)

  test "what decides WHICH objects are read stays observed":
    if gitExe().len == 0:
      skip(NoGitReason)
    else:
      let root = createTempDir("repro-git-objects-predicate-", "")
      defer: removeDir(root)
      initRepo(root / "work", bare = false)
      let gitDir = root / "work" / ".git"
      let o = gitDir / "objects"
      for path in [
          # Refs, HEAD, the index, config: they choose the names.
          gitDir, gitDir / "HEAD", gitDir / "refs" / "heads" / "main",
          gitDir / "packed-refs", gitDir / "index", gitDir / "config",
          gitDir / "shallow", gitDir / "info" / "grafts",
          # Where names are looked up, not a lookup.
          o / "info", o / "info" / "alternates",
          o / "info" / "http-alternates",
          # Pack side files whose CONTENT is not determined by the name.
          o / "pack" / ("pack-" & hex40 & ".keep"),
          o / "pack" / ("pack-" & hex40 & ".promisor"),
          o / "pack" / ("pack-" & hex40 & ".mtimes"),
          # Temporaries, quarantine and malformed names.
          o / "ab" / "tmp_obj_Xa1b2c", o / "pack" / "tmp_pack_Xa1b2c",
          o / ("incoming-" & "Xa1b2c") / "ab" / loose38,
          o / "AB" / loose38.toUpperAscii, o / "ab" / loose38[1 .. ^1],
          o / "abc" / loose38, o / "ab" / loose38 / "extra",
          o / "ab" / (loose38 & "0"),
          o / "pack" / ("pack-" & hex40[1 .. ^1] & ".idx"),
          o / "pack" / ("pack-" & hex40 & ".idx.tmp"),
          # The work tree is never the object store, whatever it contains.
          root / "work" / "objects" / "ab" / loose38]:
        checkpoint(path)
        check not isGitObjectStorePath(path)

  test "the shape alone, outside a git directory, licenses nothing":
    let root = createTempDir("repro-git-objects-predicate-", "")
    defer: removeDir(root)
    let o = root / "plain" / "objects"
    createDir(o / "ab")
    createDir(o / "pack")
    for path in [o / "ab" / loose38, o / "pack" / ("pack-" & hex40 & ".idx"),
                 o / "pack", o]:
      checkpoint(path)
      check not isGitObjectStorePath(path)
    # A directory that merely has a `HEAD` file is not a git directory either:
    # git's own `is_git_directory` also wants `objects/` and `refs/`.
    writeFile(root / "plain" / "HEAD", "ref: refs/heads/main\n")
    check not isGitObjectStorePath(o / "ab" / loose38)

  test "cacheInputPaths and cacheEnumeratedDirectories elide; declarations win":
    if gitExe().len == 0:
      skip(NoGitReason)
    else:
      let root = createTempDir("repro-git-objects-predicate-", "")
      defer: removeDir(root)
      initRepo(root / "work", bare = false)
      let gitDir = root / "work" / ".git"
      let o = gitDir / "objects"
      let loose = o / "ab" / loose38
      let declaredLoose = o / "cd" / loose38
      let pack = o / "pack"
      let idx = pack / ("pack-" & hex40 & ".idx")
      let refPath = gitDir / "refs" / "heads" / "main"
      let alternates = o / "info" / "alternates"
      let act = action("git-read", ["/bin/sh", "-c", "true"],
        cwd = root,
        inputs = [declaredLoose],
        outputs = [],
        cacheable = true,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      var evidence: PathSetEvidence
      evidence.declaredInputs = act.inputs
      evidence.monitorReads.observeAll(evidence.evidenceProvenance,
        evcMonitorCapture, [loose, idx, refPath, declaredLoose])
      evidence.monitorProbes.observeAll(evidence.evidenceProvenance,
        evcMonitorCapture, [o / "ef" / loose38, pack, alternates])
      evidence.depfileInputs.observeAll(evidence.evidenceProvenance,
        evcToolReportedDepfile, [idx])
      evidence.monitorDirectoryEnumerations.observeAll(
        evidence.evidenceProvenance, evcMonitorCapture, [pack, o / "ab"])
      let inputs = act.cacheInputPaths(evidence)
      let enumerated = act.cacheEnumeratedDirectories(evidence)
      check loose notin inputs
      check idx notin inputs
      check (o / "ef" / loose38) notin inputs
      check pack notin inputs
      check pack notin enumerated
      check (o / "ab") notin enumerated
      # Kept: what chooses the names, and what the author declared.
      check refPath in inputs
      check alternates in inputs
      check declaredLoose in inputs

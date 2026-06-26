## RA-5c — ``--jobs-network`` bounds the sync fetch pool.
##
## Companion to ``t_workspace_sync_fetches_repos_in_parallel``. Where that
## test proves fetches CAN overlap, this one proves the overlap is BOUNDED:
## with ``--jobs-network=2`` at most two per-repo fetches run concurrently
## regardless of how many repos / CPU slots are available, and the shared
## object-cache bare for each unique upstream URL is refreshed exactly once.
##
## Determinism + hermeticity, same as the sibling test:
##
##   * Local ``git init --bare`` upstreams in a tempdir (no network).
##   * Each upstream is advanced one commit so every repo is fetched.
##   * A wrapper ``git`` shim records, per invocation, a start + end
##     nanosecond timestamp for the per-repo ``fetch origin`` calls (one
##     marker pair per call), and separately tallies the shared-bare
##     refresh calls (``fetch --all --prune`` / ``clone --bare``) keyed by
##     the destination cache path. The test computes the PEAK number of
##     overlapping fetch intervals and asserts it is ``<= 2`` even though
##     there are six repos, and that each unique URL's bare was refreshed
##     exactly once.
##
## Falsifiable: an unbounded pool (or the old serial path's missing pool)
## would let peak concurrency exceed 2 (or, serially, never reach 2). Skip
## only when ``git`` is missing.

import std/[os, osproc, strutils, tempfiles, unittest, algorithm, tables]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

# ``repro`` is a build-graph artifact (``reprobuild.apps.repro`` →
# ``build/bin/repro``, built by the apps collection before tests run). The
# generator's ``requiresReproBinary`` detector keys on the literal
# ``build/bin/repro`` so this execute edge declares the CLI as a typed input.
proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA5c Tester\"")
  writeFile(workPath / "README.md", "RA-5c fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedSecondCommit(gitBin, workPath: string; branch = "main"): string =
  writeFile(workPath / "next.txt", "second\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add next.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m \"second commit\"")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA5c Tester\"")

# ---- git wrapper shim ------------------------------------------------------

proc writeGitShim(shimDir, realGit, markersDir, refreshDir: string;
                  sleepMs: int): string =
  ## Wrapper ``git``. For a per-repo ``fetch origin`` it records a
  ## start/end marker pair under ``markersDir`` and sleeps (so the pool
  ## bound is observable). For a shared-bare refresh (``fetch --all
  ## --prune`` or ``clone --bare``) it appends a line to a per-destination
  ## tally file under ``refreshDir`` keyed by the LAST argv element (the
  ## bare path) so the test can assert one-refresh-per-URL. Everything
  ## else passes straight through.
  createDir(shimDir)
  createDir(markersDir)
  createDir(refreshDir)
  let shim = shimDir / "git"
  let sleepS = $(sleepMs.float / 1000.0)
  var lines: seq[string]
  lines.add("#!/usr/bin/env bash")
  lines.add("REAL_GIT=" & q(realGit))
  lines.add("MARKERS=" & q(markersDir))
  lines.add("REFRESH=" & q(refreshDir))
  lines.add("SLEEP_S=" & sleepS)
  lines.add("is_fetch=0")
  lines.add("is_all=0")
  lines.add("is_bareclone=0")
  lines.add("for a in \"$@\"; do")
  lines.add("  case \"$a\" in")
  lines.add("    fetch) is_fetch=1 ;;")
  lines.add("    --all) is_all=1 ;;")
  lines.add("    --bare) is_bareclone=1 ;;")
  lines.add("  esac")
  lines.add("done")
  # Per-repo fetch (``fetch origin``, NOT ``fetch --all``): instrument.
  lines.add("if [ \"$is_fetch\" = \"1\" ] && [ \"$is_all\" = \"0\" ]; then")
  lines.add("  tag=\"$$-$(date +%s%N)\"")
  lines.add("  date +%s%N > \"$MARKERS/$tag.start\"")
  lines.add("  sleep \"$SLEEP_S\"")
  lines.add("  out=\"$(\"$REAL_GIT\" \"$@\" 2>&1)\"")
  lines.add("  rc=$?")
  lines.add("  date +%s%N > \"$MARKERS/$tag.end\"")
  lines.add("  printf '%s' \"$out\"")
  lines.add("  exit $rc")
  lines.add("fi")
  # Shared-bare refresh (clone --bare OR fetch --all --prune): tally by
  # the last argv element (clone dest = bare path; fetch runs with
  # ``-C <bare>`` so the bare path is the arg after ``-C``).
  lines.add("if [ \"$is_bareclone\" = \"1\" ] || " &
    "{ [ \"$is_fetch\" = \"1\" ] && [ \"$is_all\" = \"1\" ]; }; then")
  lines.add("  dest=\"\"")
  lines.add("  prev=\"\"")
  lines.add("  for a in \"$@\"; do")
  lines.add("    if [ \"$prev\" = \"-C\" ]; then dest=\"$a\"; fi")
  lines.add("    prev=\"$a\"")
  lines.add("  done")
  lines.add("  if [ \"$is_bareclone\" = \"1\" ]; then")
  lines.add("    for a in \"$@\"; do dest=\"$a\"; done")  # clone dest = last arg
  lines.add("  fi")
  lines.add("  slug=\"$(printf '%s' \"$dest\" | tr '/' '_')\"")
  lines.add("  echo 1 >> \"$REFRESH/$slug\"")
  lines.add("fi")
  lines.add("exec \"$REAL_GIT\" \"$@\"")
  writeFile(shim, lines.join("\n") & "\n")
  when not defined(windows):
    discard runCmd("chmod +x " & q(shim))
  result = shim

# ---- manifest TOML ---------------------------------------------------------

proc projectTomlWithRepos(remotes: seq[(string, string)]): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n"
  for (name, url) in remotes:
    result.add("[[remote]]\nname = \"" & name & "\"\nfetch = \"" & url & "\"\n\n")
  result.add("includes = [\n")
  for (name, _) in remotes:
    result.add("  \"repos/" & name & ".toml\",\n")
  result.add("]\n")

proc repoFragmentToml(name, remoteName: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remoteName & "\"\n" &
  "revision = \"main\"\n"

# ---- marker interval analysis ----------------------------------------------

proc loadIntervals(markersDir: string): seq[(int64, int64)] =
  for path in walkDir(markersDir):
    if path.path.endsWith(".start"):
      let tag = path.path[0 ..< path.path.len - ".start".len]
      let endPath = tag & ".end"
      if fileExists(endPath):
        let s = parseBiggestInt(readFile(path.path).strip())
        let e = parseBiggestInt(readFile(endPath).strip())
        result.add((int64(s), int64(e)))

proc peakConcurrency(intervals: seq[(int64, int64)]): int =
  ## Sweep-line: emit (+1) at each start, (-1) at each end; the running
  ## sum's maximum is the peak number of simultaneously-open intervals.
  var events: seq[(int64, int)]
  for iv in intervals:
    events.add((iv[0], 1))
    events.add((iv[1], -1))
  # Sort by time; at a tie process ends (-1) before starts (+1) so two
  # back-to-back intervals (one ends exactly as the next starts) are NOT
  # counted as overlapping.
  events.sort(proc (a, b: (int64, int)): int =
    if a[0] != b[0]: cmp(a[0], b[0]) else: cmp(a[1], b[1]))
  var cur = 0
  for (_, delta) in events:
    cur += delta
    if cur > result:
      result = cur

# ---- the suite -------------------------------------------------------------

const RepoCount = 6
const JobsNetwork = 2

suite "RA-5c — --jobs-network bounds the sync fetch pool":

  test "t_workspace_sync_jobs_network_pool_bounds_concurrency":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra5c-bound-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      var remotes: seq[(string, string)]
      var seedWork: seq[string]
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      let manifestsRoot = workspaceRoot / ".repo" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")

      var advancedShas: seq[string]
      for i in 0 ..< RepoCount:
        let name = "lib" & $i
        let origin = scratch / ("origin-" & name & ".git")
        let seedPath = scratch / ("seed-" & name)
        discard seedGitOrigin(gitBin, origin, seedPath)
        remotes.add((name, fileUrl(origin)))
        seedWork.add(seedPath)
        cloneInto(gitBin, origin, workspaceRoot / name)
        writeFile(manifestsRoot / "repos" / (name & ".toml"),
          repoFragmentToml(name, name))

      writeFile(manifestsRoot / "projects" / "myproject.toml",
        projectTomlWithRepos(remotes))

      for i in 0 ..< RepoCount:
        advancedShas.add(seedSecondCommit(gitBin, seedWork[i]))

      let markersDir = scratch / "markers"
      let refreshDir = scratch / "refresh"
      let shimDir = scratch / "shim-bin"
      discard writeGitShim(shimDir, gitBin, markersDir, refreshDir,
        sleepMs = 400)
      # ``REPRO_WORKSPACE_CLONES`` pins the shared object-cache root inside
      # the scratch dir so the test is hermetic and the per-URL bare
      # refresh is observable.
      let clonesRoot = scratch / "clones-cache"
      let newPath = shimDir & ":" & getEnv("PATH")

      let res = runShell(shellCommand(@[
        reproBin, "workspace", "sync", "myproject",
        "--workspace-root=" & workspaceRoot,
        "--jobs-network=" & $JobsNetwork,
      ], @[("PATH", newPath), ("REPRO_WORKSPACE_CLONES", clonesRoot)]))
      if res.code != 0:
        checkpoint("sync output: " & res.output)
      check res.code == 0

      # Determinism: same resolved revisions as a serial run.
      for i in 0 ..< RepoCount:
        let head = requireGit(q(gitBin) & " -C " &
          q(workspaceRoot / ("lib" & $i)) & " rev-parse HEAD").strip()
        check head == advancedShas[i]

      # Bound: peak concurrent per-repo fetches must be <= jobs-network.
      let intervals = loadIntervals(markersDir)
      check intervals.len == RepoCount
      let peak = peakConcurrency(intervals)
      if peak > JobsNetwork:
        checkpoint("peak fetch concurrency " & $peak &
          " exceeded jobs-network=" & $JobsNetwork & ": " & $intervals)
      check peak <= JobsNetwork
      # Sanity: with 6 repos and a pool of 2, at least 2 should have
      # overlapped (otherwise the bound is vacuous / serial).
      check peak >= 2

      # Shared bare refreshed exactly once per unique URL. Each repo has a
      # distinct upstream, so there are RepoCount unique bares, each
      # refreshed (clone --bare on first sight) exactly once.
      var refreshCounts = initTable[string, int]()
      var totalRefreshes = 0
      for path in walkDir(refreshDir):
        let n = readFile(path.path).strip().splitLines().len
        refreshCounts[extractFilename(path.path)] = n
        totalRefreshes += n
      check refreshCounts.len == RepoCount
      for slug, n in refreshCounts:
        if n != 1:
          checkpoint("shared bare " & slug & " refreshed " & $n &
            " times (expected exactly once)")
        check n == 1
      check totalRefreshes == RepoCount

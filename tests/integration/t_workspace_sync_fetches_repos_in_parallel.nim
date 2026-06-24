## RA-5c — ``repro workspace sync`` fetches repos in parallel.
##
## The PRIMARY deliverable of the Workspace/RepoWorkspaces alignment
## campaign: the sync/pull path must fan out the per-repo network fetch
## into the build engine + RunQuota the way Google ``repo`` does, instead
## of the old repo-by-repo serial loop.
##
## This test proves the parallelism **deterministically and hermetically**:
##
##   * A multi-repo workspace is built from local ``git init --bare``
##     upstreams in a tempdir (no network).
##   * Every upstream is advanced by one commit AFTER the workspace clones
##     are taken, so each repo is "clean_fast_forwardable" and sync MUST
##     issue a real ``git fetch`` for each.
##   * A wrapper ``git`` shim is placed first on PATH. On a ``fetch`` it
##     records a start + end nanosecond timestamp (one marker file pair
##     per invocation), sleeps, then delegates to the real git. The test
##     then loads every fetch's [start, end] interval and asserts that at
##     least two of them OVERLAP in wall-clock — impossible under the old
##     serial path where each fetch fully completes before the next begins.
##   * The resolved revisions after sync match the advanced upstream tips,
##     i.e. the parallel path produces the SAME result a serial run would.
##
## Skip rule: only when ``git`` is missing from PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest, algorithm]

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

proc writeGitShim(shimDir, realGit, markersDir: string; sleepMs: int): string =
  ## Write a ``git`` wrapper that, for a ``fetch`` subcommand, records a
  ## start + end nanosecond timestamp into its own marker file pair under
  ## ``markersDir`` (one pair per invocation, so concurrent appends never
  ## corrupt a shared file), sleeps, then delegates to the real git. Every
  ## other subcommand is forwarded straight through. Returns the shim path.
  createDir(shimDir)
  createDir(markersDir)
  let shim = shimDir / "git"
  # ``$$`` is the shell PID — unique per invocation; combine with a
  # nanosecond stamp to be collision-free even for same-PID reuse.
  # Assemble line-by-line (explicit ``\n``) so no interpolation boundary
  # can swallow a newline.
  let sleepS = $(sleepMs.float / 1000.0)
  var lines: seq[string]
  lines.add("#!/usr/bin/env bash")
  lines.add("REAL_GIT=" & q(realGit))
  lines.add("MARKERS=" & q(markersDir))
  lines.add("SLEEP_S=" & sleepS)
  lines.add("is_fetch=0")
  lines.add("for a in \"$@\"; do")
  lines.add("  if [ \"$a\" = \"fetch\" ]; then is_fetch=1; break; fi")
  lines.add("done")
  lines.add("if [ \"$is_fetch\" = \"1\" ]; then")
  lines.add("  tag=\"$$-$(date +%s%N)\"")
  lines.add("  date +%s%N > \"$MARKERS/$tag.start\"")
  lines.add("  sleep \"$SLEEP_S\"")
  lines.add("  out=\"$(\"$REAL_GIT\" \"$@\" 2>&1)\"")
  lines.add("  rc=$?")
  lines.add("  date +%s%N > \"$MARKERS/$tag.end\"")
  lines.add("  printf '%s' \"$out\"")
  lines.add("  exit $rc")
  lines.add("fi")
  lines.add("exec \"$REAL_GIT\" \"$@\"")
  writeFile(shim, lines.join("\n") & "\n")
  when not defined(windows):
    discard runCmd("chmod +x " & q(shim))
  result = shim

# ---- manifest TOML ---------------------------------------------------------

proc projectTomlWithRepos(remotes: seq[(string, string)]): string =
  ## ``remotes`` is a list of (name, url). One include per repo.
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

proc anyOverlap(intervals: seq[(int64, int64)]): bool =
  ## True iff at least two intervals overlap in wall-clock. Sort by start;
  ## an overlap exists when some interval starts before the running max end.
  var sorted = intervals
  sorted.sort(proc (a, b: (int64, int64)): int = cmp(a[0], b[0]))
  var maxEnd = low(int64)
  for i, iv in sorted:
    if i > 0 and iv[0] < maxEnd:
      return true
    if iv[1] > maxEnd:
      maxEnd = iv[1]
  false

# ---- the suite -------------------------------------------------------------

const RepoCount = 4

suite "RA-5c — repro workspace sync fetches repos in parallel":

  test "t_workspace_sync_fetches_repos_in_parallel":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra5c-par-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # Build N independent upstreams + workspace clones.
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
        # Clone the workspace checkout at the ORIGINAL tip.
        cloneInto(gitBin, origin, workspaceRoot / name)
        writeFile(manifestsRoot / "repos" / (name & ".toml"),
          repoFragmentToml(name, name))

      writeFile(manifestsRoot / "projects" / "myproject.toml",
        projectTomlWithRepos(remotes))

      # Advance every upstream by a commit so every repo is
      # fast-forwardable and MUST be fetched.
      for i in 0 ..< RepoCount:
        advancedShas.add(seedSecondCommit(gitBin, seedWork[i]))

      # Install the slow-fetch git shim first on PATH.
      let markersDir = scratch / "markers"
      let shimDir = scratch / "shim-bin"
      discard writeGitShim(shimDir, gitBin, markersDir, sleepMs = 500)
      let newPath = shimDir & ":" & getEnv("PATH")

      let res = runShell(shellCommand(@[
        reproBin, "workspace", "sync", "myproject",
        "--workspace-root=" & workspaceRoot,
        "--jobs-network=" & $RepoCount,
      ], @[("PATH", newPath)]))
      if res.code != 0:
        checkpoint("sync output: " & res.output)
      check res.code == 0

      # Determinism: every repo is now at its advanced upstream tip — the
      # SAME result a serial sync produces.
      for i in 0 ..< RepoCount:
        let head = requireGit(q(gitBin) & " -C " &
          q(workspaceRoot / ("lib" & $i)) & " rev-parse HEAD").strip()
        check head == advancedShas[i]

      # Parallelism: at least two fetch intervals overlapped in wall-clock.
      let intervals = loadIntervals(markersDir)
      check intervals.len >= 2
      if not anyOverlap(intervals):
        checkpoint("fetch intervals did not overlap (serial execution): " &
          $intervals)
      check anyOverlap(intervals)

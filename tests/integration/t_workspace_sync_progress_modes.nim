## RA-27 / Progress reporting for ``repro sync`` / ``repro workspace sync``.
##
## Pins the behavior of the ``--progress`` flag:
##   1. ``--progress=quiet``: suppresses progress lines on stderr (such as
##      "workspace sync: checking N repositories..." and per-repo checks).
##   2. ``--progress=lines``: emits multiline progress lines on stderr, including
##      per-repo checks ("workspace sync: checking [X/N] repo...").
##   3. ``--progress=line`` / ``--progress=bar-line``: accepts single-line updating modes.
##   4. ``--progress=invalid``: exits non-zero with a clear, actionable error.
##   5. ``--json``: suppresses stderr progress lines and keeps stdout a clean JSON doc.
##   6. Parity: ``repro sync`` and ``repro workspace sync`` behave identically.
##   7. Cloning a newly-declared repo whose shared bare exists and has
##      registered borrowers: ``--progress=lines`` announces, in order after
##      "checking 1 repositories...", the shared-cache refresh (naming the URL
##      and the repo), each borrower leaf check as ``[i/N]``, and the clone
##      (``cloning <path> <- <url>``), all before ``[cloned]``;
##      ``--progress=quiet`` and ``--json`` print none of them, and ``--json``
##      keeps stdout one JSON document. CLI/sync.md "Progress and
##      phase ordering (RA-27)" phase 3.
##
## Falsifiability: removing the ``emitProgress`` check causes progress to be emitted
## even under ``--progress=quiet``, failing assertion (1). Removing the flag parser
## makes ``--progress=...`` fail as an unsupported flag. For (7), the build
## without the refresh progress hook prints only "checking 1 repositories...",
## "updating 1 repo(s)" and "[cloned] repo-b", and every ordering check fails.
##
## Hermetic: runs against real git repositories in temporary directories without mocks.
## The shared-clone cache is pointed at a temporary directory with
## ``REPRO_WORKSPACE_CLONES``, and the "other workspaces" borrowing from it are
## real reference clones registered through ``wireAlternates``.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests
import shared_clones

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

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath, branch: string): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Progress Tester\"")
  writeFile(workPath / "README.md", "progress test fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"Progress Tester\"")

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-progress-", "")
  result.reproBin = reproBinary()
  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot)
  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  createDir(result.workspaceRoot / ".repro")

  let origin = result.scratch / "origin.git"
  let seedPath = result.scratch / "seed"
  let tipSha = seedGitOrigin(gitBin, origin, seedPath, "main")

  cloneInto(gitBin, origin, result.workspaceRoot / "repo-a")

  writeFile(result.workspaceRoot / "repos" / "repo-a.toml",
    "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
    "[repo]\n" &
    "name = \"repo-a\"\n" &
    "path = \"repo-a\"\n" &
    "remote = \"origin\"\n" &
    "mainline = \"main\"\n")

  writeFile(result.workspaceRoot / "projects" / "p1.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"p1\"\n\n" &
    "[[remote]]\nname = \"origin\"\nfetch = \"" & origin & "\"\n\n" &
    "includes = [\"repos/repo-a.toml\"]\n")

  writeWorkspaceBranch(result.workspaceRoot, project = "p1", branch = "main")

  # Seed repro.lock so sync runs without requiring lock generation
  writeFile(result.workspaceRoot / "repro.lock",
    "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
    "[[repo]]\n" &
    "name = \"repo-a\"\n" &
    "path = \"repo-a\"\n" &
    "sha = \"" & tipSha & "\"\n")

proc teardown(f: Fixture) =
  try:
    removeDir(f.scratch)
  except CatchableError:
    discard

suite "repro sync --progress modes":
  test "progress modes: quiet, lines, line, json, invalid":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      checkpoint("git missing on PATH; skipping")
    else:
      let f = setupFixture(gitBin)
      defer: teardown(f)

      # 1. --progress=quiet suppresses progress lines on stderr
      block:
        let res = runCmd(q(f.reproBin) & " sync --workspace-root=" & q(f.workspaceRoot) & " --progress=quiet", cwd = f.workspaceRoot)
        if res.code != 0:
          checkpoint("progress=quiet failed: code=" & $res.code & "\n" & res.output)
        check res.code == 0
        check not res.output.contains("workspace sync: checking")
        check not res.output.contains("workspace sync: fetching")

      # 2. --progress=lines emits per-repo checking progress lines
      block:
        let res = runCmd(q(f.reproBin) & " sync --progress=lines", cwd = f.workspaceRoot)
        check res.code == 0
        check res.output.contains("workspace sync: checking")
        check res.output.contains("workspace sync: checking [1/1] repo-a...")

      # 3. --progress=invalid raises clear error
      block:
        let res = runCmd(q(f.reproBin) & " sync --progress=invalid", cwd = f.workspaceRoot)
        check res.code == 1
        check res.output.contains("unsupported --progress=invalid")

      # 4. --json suppresses progress on stderr and yields valid json on stdout
      block:
        let res = runCmd(q(f.reproBin) & " sync --json", cwd = f.workspaceRoot)
        check res.code == 0
        check not res.output.contains("workspace sync: checking")
        let parsed = parseJson(res.output)
        check parsed.hasKey("repos")
        check parsed.hasKey("exitCode")
        check parsed["exitCode"].getInt() == 0

      # 5. Parity with `repro workspace sync`
      block:
        let res = runCmd(q(f.reproBin) & " workspace sync --progress=quiet", cwd = f.workspaceRoot)
        check res.code == 0
        check not res.output.contains("workspace sync: checking")

        let resLines = runCmd(q(f.reproBin) & " workspace sync --progress=lines", cwd = f.workspaceRoot)
        check resLines.code == 0
        check resLines.output.contains("workspace sync: checking [1/1] repo-a...")

# ---- clone of a newly-declared repo: the shared-cache refresh is announced --
#
# CLI/sync.md "Progress and phase ordering (RA-27)", phase 3: cloning a missing
# repository is preceded by a refresh of that URL's shared bare, and the
# refresh runs the leaf detector in every checkout on the host that borrows
# from it (Shared-Clone-Pool-Integrity.md §4.2). The fixture reproduces the
# shape of the reported hang (reprobuild-pm issue 2026-11-22, `repro sync
# --only reprobuild` silent for minutes after `checking 1 repositories...`):
# a declared repo with no checkout, whose shared bare already exists and has
# two borrowers registered from "other workspaces". Before the fix the
# refresh, both leaf checks and the clone ran with nothing on stderr between
# `checking 1 repositories...` and `[cloned]`.

type
  CloneFixture = object
    scratch, reproBin, workspaceRoot, clonesRoot, url: string
    leaves: seq[string]

proc setupCloneFixture(gitBin: string): CloneFixture =
  result.scratch = createTempDir("repro-progress-clone-", "")
  result.reproBin = reproBinary()
  result.workspaceRoot = result.scratch / "workspace"
  result.clonesRoot = result.scratch / "clones"
  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  createDir(result.workspaceRoot / ".repro")

  let origin = result.scratch / "origin-repo-b.git"
  discard seedGitOrigin(gitBin, origin, result.scratch / "seed-repo-b", "main")
  result.url = fileUrl(origin)

  writeFile(result.workspaceRoot / "repos" / "repo-b.toml",
    "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
    "[repo]\n" &
    "name = \"repo-b\"\n" &
    "path = \"repo-b\"\n" &
    "remote = \"b-origin\"\n" &
    "mainline = \"main\"\n")
  writeFile(result.workspaceRoot / "projects" / "p2.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"p2\"\n\n" &
    "[[remote]]\nname = \"b-origin\"\nfetch = \"" & result.url & "\"\n\n" &
    "includes = [\"repos/repo-b.toml\"]\n")
  writeWorkspaceBranch(result.workspaceRoot, project = "p2", branch = "main")

  # The shared bare already exists (an earlier workspace on this host created
  # it), so the refresh takes the fetch arm, which is the arm that runs the
  # leaf detector. Created through the same ``refreshSharedBare`` sync calls,
  # so its path is the one sync derives from the declared URL.
  let created = refreshSharedBare(gitBin, result.clonesRoot, result.url)
  doAssert created.ok, created.diagnostic
  # Two borrowers in two "other workspaces", wired the way a reference clone
  # is: ``wireAlternates`` registers each in ``<bare>/repro/borrowers``.
  for i in 1 .. 2:
    let leaf = result.scratch / ("other-ws-" & $i) / "repo-b"
    createDir(leaf.parentDir)
    discard requireGit(q(gitBin) & " clone -q --reference " &
      q(created.sharedBarePath) & " " & q(result.url) & " " & q(leaf))
    let wired = wireAlternates(leaf, created.sharedBarePath, gitBin)
    doAssert wired.ok, wired.diagnostic
    result.leaves.add(leaf)

proc runCloneSync(f: CloneFixture; verb: openArray[string];
                  progress: string; extra: openArray[string] = []):
    CmdSplitResult =
  # Each run starts from the "declared, not checked out" state.
  if dirExists(f.workspaceRoot / "repo-b"):
    removeDir(f.workspaceRoot / "repo-b")
  var argv = @[f.reproBin]
  argv.add(verb)
  argv.add(["p2", "--only=repo-b", "--jobs=1", "--progress=" & progress,
    "--workspace-root=" & f.workspaceRoot])
  argv.add(extra)
  runShellSplit(shellCommand(argv,
    env = [("REPRO_WORKSPACE_CLONES", f.clonesRoot)]), cwd = f.workspaceRoot)

proc assertAnnouncedInOrder(f: CloneFixture; res: CmdSplitResult) =
  checkpoint("stderr:\n" & res.stderr)
  check res.code == 0
  check dirExists(f.workspaceRoot / "repo-b" / ".git")
  let err = res.stderr
  let checking = err.find("workspace sync: checking 1 repositories...")
  let refresh = err.find("workspace sync: refreshing the shared clone cache for " &
    f.url & " (to clone repo-b)...")
  let first = err.find("workspace sync: checking borrowing checkout [1/2] ")
  let second = err.find("workspace sync: checking borrowing checkout [2/2] ")
  let cloning = err.find("workspace sync: cloning repo-b <- " & f.url & "...")
  let cloned = err.find("workspace sync: [cloned] repo-b")
  check checking >= 0
  check refresh > checking
  check first > refresh
  check second > first
  check cloning > second
  check cloned > cloning
  # Each borrower is named on its own line.
  for leaf in f.leaves:
    var named = false
    for line in err.splitLines():
      if "checking borrowing checkout [" in line and
          line.contains(leaf.parentDir.lastPathPart):
        named = true
    check named

suite "repro sync --progress: cloning a newly-declared repo":
  test "the shared-cache refresh, each borrower check and the clone are announced":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      checkpoint("git missing on PATH; skipping")
    else:
      let f = setupCloneFixture(gitBin)
      defer:
        try: removeDir(f.scratch)
        except CatchableError: discard

      assertAnnouncedInOrder(f, runCloneSync(f, ["sync"], "lines"))
      assertAnnouncedInOrder(f, runCloneSync(f, ["workspace", "sync"], "lines"))

      # Quiet prints none of them, and still clones.
      let quiet = runCloneSync(f, ["sync"], "quiet")
      checkpoint("stderr:\n" & quiet.stderr)
      check quiet.code == 0
      check dirExists(f.workspaceRoot / "repo-b" / ".git")
      check not quiet.stderr.contains("refreshing the shared clone cache")
      check not quiet.stderr.contains("checking borrowing checkout")
      check not quiet.stderr.contains("workspace sync: cloning")

      # ``--json`` prints none of them either, even with a line mode asked
      # for, and stdout stays one JSON document.
      let asJson = runCloneSync(f, ["sync"], "lines", ["--json"])
      checkpoint("stdout:\n" & asJson.stdout & "\nstderr:\n" & asJson.stderr)
      check asJson.code == 0
      check dirExists(f.workspaceRoot / "repo-b" / ".git")
      check not asJson.stderr.contains("refreshing the shared clone cache")
      check not asJson.stderr.contains("checking borrowing checkout")
      check not asJson.stderr.contains("workspace sync: cloning")
      var parsed: JsonNode
      try:
        parsed = parseJson(asJson.stdout)
      except CatchableError:
        checkpoint("stdout is not one JSON document")
      check parsed != nil and parsed.kind == JObject

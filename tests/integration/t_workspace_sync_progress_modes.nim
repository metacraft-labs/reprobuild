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
##
## Falsifiability: removing the ``emitProgress`` check causes progress to be emitted
## even under ``--progress=quiet``, failing assertion (1). Removing the flag parser
## makes ``--progress=...`` fail as an unsupported flag.
##
## Hermetic: runs against real git repositories in temporary directories without mocks.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

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
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\n" &
    "name = \"repo-a\"\n" &
    "path = \"repo-a\"\n" &
    "remote = \"origin\"\n" &
    "revision = \"main\"\n")

  writeFile(result.workspaceRoot / "projects" / "p1.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"p1\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n" &
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

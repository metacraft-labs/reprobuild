## Integration test for multiple named remotes alignment.
## Verifies that:
##   1. Repo TOMLs with multiple remotes resolve correctly.
##   2. `repro workspace init` clones via the primary remote and configures all expected remotes.
##   3. Stale remotes on disk are removed/aligned during sync/init.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code & "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath: string; branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " config user.name \"M9 Tester\"")
  writeFile(workPath / "README.md", "multiple remotes fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

type RemotesFixture = object
  scratch: string
  gitBin: string
  reproBin: string
  workspaceRoot: string
  originUrl: string
  upstreamUrl: string

proc setupFixture(): RemotesFixture =
  let gitBin = findExe("git")
  if gitBin.len == 0:
    echo "test skipped: git missing from PATH"
    quit 0
  result.gitBin = gitBin
  result.reproBin = reproBinary()

  let scratch = createTempDir("repro-remotes-align", "")
  result.scratch = scratch

  let originsDir = scratch / "origins"
  let upstreamsDir = scratch / "upstreams"
  createDir(originsDir)
  createDir(upstreamsDir)

  let originPath = originsDir / "lib-a"
  let upstreamPath = upstreamsDir / "lib-a"
  discard seedGitOrigin(gitBin, originPath, scratch / "seed-origin")
  discard seedGitOrigin(gitBin, upstreamPath, scratch / "seed-upstream")
  result.originUrl = fileUrl(originPath)
  result.upstreamUrl = fileUrl(upstreamPath)

  let workspaceRoot = scratch / "workspace"
  createDir(workspaceRoot)
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  result.workspaceRoot = workspaceRoot

  let projectToml = 
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin-prefix\"\nfetch = \"" & fileUrl(originsDir) & "\"\n\n" &
    "[[remote]]\nname = \"lib-a-upstream-prefix\"\nfetch = \"" & fileUrl(upstreamsDir) & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "]\n"
  writeFile(workspaceRoot / "projects" / "myproject.toml", projectToml)

  let repoToml =
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\n" &
    "name = \"lib-a\"\n" &
    "path = \"libs/lib-a\"\n" &
    "remote = \"origin\"\n" &
    "remotes = [\n" &
    "  { name = \"origin\", remote = \"lib-a-origin-prefix\" },\n" &
    "  { name = \"upstream\", remote = \"lib-a-upstream-prefix\" }\n" &
    "]\n"
  writeFile(workspaceRoot / "repos" / "lib-a.toml", repoToml)

proc cleanupFixture(f: RemotesFixture) =
  removeDir(f.scratch)

suite "Workspace multiple remotes alignment":
  test "workspace init configures standard and upstream remotes, cleaning up stashes":
    let f = setupFixture()
    defer: cleanupFixture(f)

    # 1. Run repro workspace init
    let initRes = runCmd(q(f.reproBin) & " workspace init myproject", f.workspaceRoot)
    check initRes.code == 0

    let repoAbs = f.workspaceRoot / "libs" / "lib-a"
    check dirExists(repoAbs / ".git")

    # 2. Check the configured remotes
    let remotesOutput = requireGit(q(f.gitBin) & " -C " & q(repoAbs) & " remote").strip().splitLines()
    check "origin" in remotesOutput
    check "upstream" in remotesOutput
    check remotesOutput.len == 2

    # Check URLs match
    let originUrl = requireGit(q(f.gitBin) & " -C " & q(repoAbs) & " remote get-url origin").strip()
    check originUrl == f.originUrl

    let upstreamUrl = requireGit(q(f.gitBin) & " -C " & q(repoAbs) & " remote get-url upstream").strip()
    check upstreamUrl == f.upstreamUrl

  test "workspace sync cleans up stale remote configurations and updates URLs":
    let f = setupFixture()
    defer: cleanupFixture(f)

    # Pre-create the repo directory to simulate a checkout with stale remotes
    let repoAbs = f.workspaceRoot / "libs" / "lib-a"
    createDir(repoAbs)
    discard requireGit(q(f.gitBin) & " clone " & q(f.originUrl) & " " & q(repoAbs))

    # Add a stale remote manually
    discard requireGit(q(f.gitBin) & " -C " & q(repoAbs) & " remote add metacraft-labs " & q(f.upstreamUrl))
    # Point origin to a wrong URL
    discard requireGit(q(f.gitBin) & " -C " & q(repoAbs) & " remote set-url origin file:///tmp/nonexistent")

    # Run repro workspace sync
    let syncRes = runCmd(q(f.reproBin) & " workspace sync myproject --force-sync --yes", f.workspaceRoot)
    if syncRes.code != 0:
      checkpoint("sync failed! output:\n" & syncRes.output)
    check syncRes.code == 0

    # Verify remotes align
    let remotesOutput = requireGit(q(f.gitBin) & " -C " & q(repoAbs) & " remote").strip().splitLines()
    check "origin" in remotesOutput
    check "upstream" in remotesOutput
    check "metacraft-labs" notin remotesOutput
    check remotesOutput.len == 2

    # Verify URLs are corrected
    let originUrl = requireGit(q(f.gitBin) & " -C " & q(repoAbs) & " remote get-url origin").strip()
    check originUrl == f.originUrl

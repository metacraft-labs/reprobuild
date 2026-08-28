## `repro workspace repos add` must stage, commit and push into the MANIFEST
## repo it names — including when Git has exported its own repository bindings
## into the environment.
##
## Git exports an absolute `GIT_DIR` (and friends) to every hook it runs, and
## those bindings OVERRIDE a later `git -C <other-repository>`. Every read-side
## git helper in the CLI already scrubs them; `gitOutput` — the one helper that
## runs `add` / `commit` / `push` — did not. The guard immediately above it
## (`discoverGitWorktree`) DOES scrub, so the pre-flight verified that the
## manifest root is a checkout while the commands that followed operated on a
## different repository entirely: the check and the action disagreed about
## which repo they were talking about.
##
## The read-side version of this leak reported every sibling as dirty. The
## write-side version stages the manifest edit into, and commits it to, the
## invoking repository. That is why this is a test and not a comment.
##
## Discrimination against an unfixed binary: with the scrub removed, `victim`
## gains a commit and `manifest` gains none, so assertions 3-6 below fail.
##
## Skip rule: `git` missing on PATH.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc git(gitBin: string; args: openArray[string]; cwd: string): CmdResult =
  var argv = @[gitBin]
  for a in args: argv.add(a)
  runShell(shellCommand(argv), cwd = cwd)

proc requireGit(gitBin: string; args: openArray[string]; cwd: string): string =
  let res = git(gitBin, args, cwd)
  if res.code != 0:
    checkpoint("git " & args.join(" ") & " failed in " & cwd &
      "\nexit=" & $res.code & "\n" & res.output)
    quit 1
  res.output

proc initRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(gitBin, ["init", "-b", "main", "."], path)
  discard requireGit(gitBin,
    ["config", "user.email", "tester@example.invalid"], path)
  discard requireGit(gitBin, ["config", "user.name", "Gate Tester"], path)

proc commitCount(gitBin, path: string): int =
  let res = git(gitBin, ["rev-list", "--count", "HEAD"], path)
  if res.code != 0: return -1
  try: parseInt(res.output.strip()) except ValueError: -1

const projectTomlTemplate = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "demo"
default_revision = "main"
trunk = "main"

[[remote]]
name = "seed-origin"
fetch = "$1"

includes = [
  "repos/seed.toml",
]
"""

const seedFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "seed"
path = "seed"
remote = "seed-origin"
revision = "main"
"""

const workspaceLocalToml = """
schema = "reprobuild.workspace.local.v1"

[workspace]
project = "demo"
branch = "main"
"""

suite "workspace manifest authoring under an inherited GIT_DIR":

  test "t_manifest_commit_targets_the_manifest_repo_under_inherited_git_dir":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-manifest-gitdir-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # The repository whose bindings Git would export — stand-in for the
      # checkout a `pre-push` / `post-commit` hook is running inside.
      let victim = scratch / "victim"
      initRepo(gitBin, victim)
      writeFile(victim / "victim.txt", "victim\n")
      discard requireGit(gitBin, ["add", "victim.txt"], victim)
      discard requireGit(gitBin, ["commit", "-m", "victim seed"], victim)
      let victimGitDir = victim / ".git"
      let victimCommitsBefore = commitCount(gitBin, victim)

      # A remote the new repo's URL can be validated against without network.
      let seedOrigin = scratch / "origin-seed.git"
      discard requireGit(gitBin,
        ["init", "--bare", "-b", "main", seedOrigin], scratch)
      let seedWork = scratch / "seed-work"
      initRepo(gitBin, seedWork)
      writeFile(seedWork / "README.md", "seed\n")
      discard requireGit(gitBin, ["add", "README.md"], seedWork)
      discard requireGit(gitBin, ["commit", "-m", "seed"], seedWork)
      discard requireGit(gitBin,
        ["push", fileUrl(seedOrigin), "main"], seedWork)

      # The membership manifest repo == the workspace root.
      let manifest = scratch / "manifest"
      initRepo(gitBin, manifest)
      createDir(manifest / "projects")
      createDir(manifest / "repos")
      createDir(manifest / ".repro")
      writeFile(manifest / ".repro" / "workspace.toml", workspaceLocalToml)
      writeFile(manifest / "projects" / "demo.toml",
        projectTomlTemplate % [fileUrl(seedOrigin)])
      writeFile(manifest / "repos" / "seed.toml", seedFragmentToml)
      discard requireGit(gitBin, ["add", "-A"], manifest)
      discard requireGit(gitBin, ["commit", "-m", "manifest seed"], manifest)
      let manifestCommitsBefore = commitCount(gitBin, manifest)

      # Author a new repo fragment with Git's repository binding leaked in,
      # exactly as a hook would hand it to us.
      let res = runShell(shellCommand(@[
          reproBin, "workspace", "repos", "add", "demo-lib",
          "--remote=" & fileUrl(seedOrigin),
          "--branch=main", "--project=demo", "-m", "demo lib",
        ], @[("GIT_DIR", victimGitDir)]), cwd = manifest)

      # 1-2: the command succeeded and reported a local commit.
      check res.code == 0
      check res.output.contains("committed locally")

      # 3-4: the manifest repo received the commit and the fragment.
      check commitCount(gitBin, manifest) == manifestCommitsBefore + 1
      check fileExists(manifest / "repos" / "demo-lib.toml")

      # 5-6: the invoking repository was not touched — no commit, and nothing
      # staged into its index either.
      check commitCount(gitBin, victim) == victimCommitsBefore
      check git(gitBin, ["status", "--porcelain"], victim).output.strip() == ""

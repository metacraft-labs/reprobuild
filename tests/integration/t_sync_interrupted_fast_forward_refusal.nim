## Real CLI/Git fixtures model a checkout left behind by an interrupted
## process. No mocks: the retained HEAD/index and target-valued partial
## worktree are inspected through the same Git queries as ordinary sync.
import std/[os, osproc, strutils, tempfiles, unittest]

proc run(args: seq[string]): tuple[code: int, output: string] =
  let res = execCmdEx(args.quoteShellCommand())
  (res.exitCode, res.output)

proc git(repo: string; args: varargs[string]): string =
  let res = run(@["git", "-C", repo] & @args)
  doAssert res.code == 0, res.output
  res.output.strip()

proc fixture(): tuple[root, repo, oldHead, target: string] =
  result.root = createTempDir("repro-interrupted-ff-", "")
  let seed = result.root / "seed.git"
  let ws = result.root / "ws"
  result.repo = ws / "lib"
  createDir(ws / "projects")
  createDir(ws / "repos")
  doAssert run(@["git", "init", "-b", "main", seed]).code == 0
  discard git(seed, "config", "user.email", "tester@example.invalid")
  discard git(seed, "config", "user.name", "Sync test")
  writeFile(seed / "old", "before\n")
  writeFile(seed / "edit", "before\n")
  writeFile(seed / ".gitignore", "ignored*\n")
  discard git(seed, "add", ".")
  discard git(seed, "commit", "-m", "before")
  result.oldHead = git(seed, "rev-parse", "HEAD")
  doAssert run(@["git", "clone", "--no-hardlinks", seed, result.repo]).code == 0
  removeFile(seed / "old")
  writeFile(seed / "edit", "after\n")
  writeFile(seed / "new", "addition\n")
  writeFile(seed / "last", "not yet checked out\n")
  discard git(seed, "add", "-A")
  discard git(seed, "commit", "-m", "after")
  result.target = git(seed, "rev-parse", "HEAD")
  discard git(result.repo, "fetch", "origin")
  removeFile(result.repo / "old")
  writeFile(result.repo / "edit", "after\n")
  writeFile(result.repo / "new", "addition\n")
  writeFile(result.repo / "ignored-local", "preserved\n")
  writeFile(ws / "projects" / "p.toml", """schema = "reprobuild.workspace.project.v1"
[project]
name = "p"
default_revision = "main"
trunk = "main"
[[remote]]
name = "origin"
fetch = """" & seed & "\"\nincludes = [\"repos/lib.toml\"]\n")
  writeFile(ws / "repos" / "lib.toml", """schema = "reprobuild.workspace.repo.v1"
[repo]
name = "lib"
path = "lib"
remote = "origin"
revision = "main"
branch = "main"
""")

suite "sync recognizes compatible interrupted upstream content":
  for role in [false, true]:
    test "refuses untouched with a precise recovery command role=" & $role:
      let fx = fixture()
      defer: removeDir(fx.root)
      let binary = getEnv("REPRO_SYNC_TEST_BINARY",
        currentSourcePath().parentDir.parentDir.parentDir / "build" / "bin" / addFileExt("repro", ExeExt))
      var args = @[binary, "sync", "p", "--jobs=1", "--write-report",
        "--workspace-root=" & fx.root / "ws"]
      if role: args.add("--mainline")
      let oldCache = getEnv("XDG_CACHE_HOME")
      putEnv("XDG_CACHE_HOME", fx.root / "cache")
      defer:
        if oldCache.len > 0: putEnv("XDG_CACHE_HOME", oldCache)
        else: delEnv("XDG_CACHE_HOME")
      let before = git(fx.repo, "status", "--porcelain")
      let result = run(args)
      checkpoint(result.output)
      check result.code == 2
      check "git -C lib reset --hard " & fx.target in result.output
      check "stash" notin result.output
      check git(fx.repo, "rev-parse", "HEAD") == fx.oldHead
      check git(fx.repo, "status", "--porcelain") == before
      check readFile(fx.repo / "ignored-local") == "preserved\n"
      check "interrupted_fast_forward" in readFile(fx.root / "ws" /
        ".repro" / "build" / "reports" / "sync-report.json")

## Real Git and CLI regression for a checkout failure after some paths changed.
## No mocks: deleting a freshly fetched loose blob deterministically exercises
## Git's partial checkout. Fixtures never share objects with the host cache.
import std/[os, osproc, strutils, tempfiles, unittest]

const UnusualAddition =
  when defined(windows): "bbb[magic]-new.txt"
  else: "bbb[*]\r\nnew.txt"

proc run(args: seq[string]): tuple[code: int, output: string] =
  let r = execCmdEx(args.quoteShellCommand())
  (r.exitCode, r.output)

proc git(repo: string; args: varargs[string]): string =
  let r = run(@["git", "-C", repo] & @args)
  doAssert r.code == 0, r.output
  r.output.strip()

proc fixture(unusualName = false): tuple[root, repo, oldHead, newHead: string] =
  result.root = createTempDir("repro-failed-ff-", "")
  let seed = result.root / "seed.git"
  let ws = result.root / "ws"
  result.repo = ws / "lib"
  createDir(ws / "projects")
  createDir(ws / "repos")
  doAssert run(@["git", "init", "-b", "main", seed]).code == 0
  discard git(seed, "config", "user.email", "tester@example.invalid")
  discard git(seed, "config", "user.name", "Sync test")
  writeFile(seed / "aaa-old.txt", "old\n")
  writeFile(seed / "mmm.txt", "before\n")
  writeFile(seed / ".gitignore", "ignored-local\n")
  discard git(seed, "add", ".")
  discard git(seed, "commit", "-m", "before")
  result.oldHead = git(seed, "rev-parse", "HEAD")
  doAssert run(@["git", "clone", "--no-hardlinks", seed, result.repo]).code == 0
  removeFile(seed / "aaa-old.txt")
  let addition = if unusualName: UnusualAddition else: "bbb-new.txt"
  writeFile(seed / addition, "new\n")
  writeFile(seed / "mmm.txt", "after\n")
  writeFile(seed / "zzz-last.bin", "missing blob\n")
  discard git(seed, "add", "-A")
  discard git(seed, "commit", "-m", "after")
  result.newHead = git(seed, "rev-parse", "HEAD")
  discard git(result.repo, "fetch", "origin")
  let blob = git(result.repo, "rev-parse", "origin/main:zzz-last.bin")
  let objectPath = result.repo / ".git" / "objects" / blob[0..1] / blob[2..^1]
  doAssert fileExists(objectPath), "fixture must remove a loose blob"
  when defined(windows):
    setFilePermissions(objectPath, getFilePermissions(objectPath) + {fpUserWrite})
  removeFile(objectPath)
  writeFile(result.repo / "ignored-local", "preserve ignored content\n")
  writeFile(ws / "projects" / "p.toml", """schema = "reprobuild.workspace.project.v1"
[project]
name = "p"
[[remote]]
name = "origin"
fetch = """" & seed & "\"\nincludes = [\"repos/lib.toml\"]\n")
  writeFile(ws / "repos" / "lib.toml", """schema = "reprobuild.workspace.repo.v2"
[repo]
name = "lib"
path = "lib"
remote = "origin"
revision = "main"
mainline = "main"
""")

proc verifyFailedFastForward(role: bool; unusualName = false): int =
  let fx = fixture(unusualName)
  defer: removeDir(fx.root)
  let binary = getEnv("REPRO_SYNC_TEST_BINARY",
    currentSourcePath().parentDir.parentDir.parentDir / "build" / "bin" / addFileExt("repro", ExeExt))
  var args = @[binary, "sync", "p", "--jobs=1", "--write-report", "--tool-provisioning=path",
    "--workspace-root=" & fx.root / "ws"]
  if role: args.add("--mainline")
  let oldCache = getEnv("XDG_CACHE_HOME")
  putEnv("XDG_CACHE_HOME", fx.root / "cache")
  defer:
    if oldCache.len > 0: putEnv("XDG_CACHE_HOME", oldCache)
    else: delEnv("XDG_CACHE_HOME")
  let r = run(args)
  result = r.code
  checkpoint(r.output)
  checkpoint("post-sync status: " & git(fx.repo, "status", "--porcelain"))
  check git(fx.repo, "rev-parse", "HEAD") == fx.oldHead
  check git(fx.repo, "status", "--porcelain").len == 0
  check readFile(fx.repo / "aaa-old.txt") == "old\n"
  check readFile(fx.repo / "mmm.txt") == "before\n"
  check not fileExists(fx.repo / (if unusualName: UnusualAddition else: "bbb-new.txt"))
  check readFile(fx.repo / "ignored-local") == "preserve ignored content\n"
  check "unable to read" in r.output
  check "restored" in r.output

suite "failed fast-forward restores pre-sync checkout":
  test "ordinary missing blob restores worktree and reports cause":
    check verifyFailedFastForward(false) == 1
  test "role missing blob restores worktree and reports cause":
    check verifyFailedFastForward(true) == 1
  test "ordinary rollback preserves exact names and literal Git pathspecs":
    check verifyFailedFastForward(false, unusualName = true) == 1

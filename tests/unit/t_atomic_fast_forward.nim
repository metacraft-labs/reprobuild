## Real Git checkout failures; no mocks. Missing loose objects force Git to
## fail after earlier worktree writes, including file/directory replacements.
## The ref-race runner only schedules a real update-ref between real Git
## commands; it injects concurrency at the boundary without faking Git output.
import std/[os, osproc, streams, strutils, tempfiles, unittest]
import git_fast_forward

proc execute(args: seq[string]; query: bool): FastForwardGitResult {.gcsafe.} =
  # These fixtures emit no benign stderr; production runners use separated
  # stdout for queries. Mutating failures retain Git's complete diagnostic.
  let child = startProcess("git", args = args, options = {poUsePath, poStdErrToStdOut})
  defer: child.close()
  child.inputStream.close()
  let output = child.outputStream.readAll()
  (child.waitForExit(), output, output)

proc git(repo: string; args: varargs[string]): string =
  let r = execute(@["-C", repo] & @args, false)
  doAssert r.code == 0, r.diagnostic
  r.output.strip()

type Fixture = object
  root, oldHead, newHead: string
  emulatedSymlink: bool

proc removeLooseObject(repo, oid: string) =
  let path = repo / ".git" / "objects" / oid[0..1] / oid[2..^1]
  when defined(windows):
    setFilePermissions(path, getFilePermissions(path) + {fpUserWrite})
  removeFile(path)

proc commit(repo, message: string): string =
  discard git(repo, "add", "-A")
  discard git(repo, "commit", "-m", message)
  git(repo, "rev-parse", "HEAD")

proc prepare(shape = "ordinary"; missingBlob = true;
             emulatedSymlink = false): Fixture =
  result.root = createTempDir("repro-atomic-ff-", "")
  doAssert execute(@["init", "-b", "main", result.root], false).code == 0
  discard git(result.root, "config", "user.email", "tester@example.invalid")
  discard git(result.root, "config", "user.name", "Atomic FF test")
  when defined(windows): result.emulatedSymlink = true
  else: result.emulatedSymlink = emulatedSymlink
  writeFile(result.root / "aaa-old", "original\n")
  writeFile(result.root / "mmm", "old\n")
  writeFile(result.root / ".gitignore", "ignored-local\n")
  case shape
  of "file-directory": writeFile(result.root / "node", "original node\n")
  of "symlink-directory":
    createDir(result.root / ".git" / "external")
    writeFile(result.root / ".git" / "external" / "child", "outside precious\n")
    if result.emulatedSymlink:
      # Git's Windows checkout representation preserves index mode 120000
      # without requiring the privilege to create a native symbolic link.
      discard git(result.root, "config", "core.symlinks", "false")
      writeFile(result.root / "node", ".git/external")
      discard git(result.root, "add", "node")
      let oid = git(result.root, "hash-object", "node")
      discard git(result.root, "update-index", "--cacheinfo", "120000," & oid & ",node")
    else:
      createSymlink(".git/external", result.root / "node")
  of "directory-file", "directory-file-local":
    createDir(result.root / "node")
    writeFile(result.root / "node" / "tracked", "original node\n")
  else: discard
  result.oldHead = commit(result.root, "original")
  if shape == "symlink-directory":
    doAssert git(result.root, "ls-tree", result.oldHead, "node").startsWith("120000 blob ")
  removeFile(result.root / "aaa-old")
  writeFile(result.root / "bbb-new", "upstream\n")
  writeFile(result.root / "mmm", "new\n")
  writeFile(result.root / "zzz-last", "missing upstream blob\n")
  case shape
  of "file-directory", "symlink-directory":
    removeFile(result.root / "node")
    createDir(result.root / "node")
    writeFile(result.root / "node" / "child", "new node\n")
  of "directory-file", "directory-file-local":
    removeDir(result.root / "node")
    writeFile(result.root / "node", "new node\n")
  else: discard
  result.newHead = commit(result.root, "upstream")
  discard git(result.root, "reset", "--hard", result.oldHead)
  writeFile(result.root / "ignored-local", "precious\n")
  if shape == "directory-file-local":
    writeFile(result.root / ".git" / "info" / "exclude", "node/local\n")
    writeFile(result.root / "node" / "local", "precious child\n")
  if missingBlob:
    let oid = git(result.root, "rev-parse", result.newHead & ":zzz-last")
    removeLooseObject(result.root, oid)

proc unchanged(fx: Fixture) =
  check git(fx.root, "rev-parse", "HEAD") == fx.oldHead
  check git(fx.root, "status", "--porcelain").len == 0
  check readFile(fx.root / "aaa-old") == "original\n"
  check readFile(fx.root / "mmm") == "old\n"
  check not fileExists(fx.root / "bbb-new")
  check readFile(fx.root / "ignored-local") == "precious\n"

suite "atomic fast-forward rollback":
  test "real partial Git checkout restores deletion modification and addition":
    let fx = prepare()
    defer: removeDir(fx.root)
    let outcome = atomicFastForward(fx.root, fx.newHead, execute)
    check not outcome.ok
    check not outcome.refused
    check "unable to read" in outcome.diagnostic
    check "worktree restored" in outcome.diagnostic
    unchanged(fx)

  test "restoration failure reports half-applied worktree and exact recovery":
    let fx = prepare()
    defer: removeDir(fx.root)
    let oid = git(fx.root, "rev-parse", fx.oldHead & ":aaa-old")
    removeLooseObject(fx.root, oid)
    let outcome = atomicFastForward(fx.root, fx.newHead, execute)
    check not outcome.ok
    check "unable to read" in outcome.diagnostic
    check "restoration FAILED" in outcome.diagnostic
    check "half-applied" in outcome.diagnostic
    check "worktree restored" notin outcome.diagnostic
    check @["git", "-C", fx.root, "reset", "--hard", fx.oldHead].quoteShellCommand() in outcome.diagnostic

  test "ignored upstream-addition collision refuses without overwriting":
    let fx = prepare()
    defer: removeDir(fx.root)
    writeFile(fx.root / ".git" / "info" / "exclude", "bbb-new\n")
    writeFile(fx.root / "bbb-new", "precious addition\n")
    let outcome = atomicFastForward(fx.root, fx.newHead, execute)
    check outcome.refused
    check "ignored path" in outcome.diagnostic
    check git(fx.root, "rev-parse", "HEAD") == fx.oldHead
    check readFile(fx.root / "bbb-new") == "precious addition\n"

  test "untracked local work refuses before mutation and is preserved":
    let fx = prepare()
    defer: removeDir(fx.root)
    writeFile(fx.root / "local-only", "precious local work\n")
    let outcome = atomicFastForward(fx.root, fx.newHead, execute)
    check outcome.refused
    check "dirty" in outcome.diagnostic
    check git(fx.root, "rev-parse", "HEAD") == fx.oldHead
    check readFile(fx.root / "local-only") == "precious local work\n"

  test "file to directory partial checkout restores original file":
    let fx = prepare("file-directory")
    defer: removeDir(fx.root)
    let outcome = atomicFastForward(fx.root, fx.newHead, execute)
    check "worktree restored" in outcome.diagnostic
    unchanged(fx)
    check readFile(fx.root / "node") == "original node\n"

  test "symlink to directory partial checkout restores original symlink":
    let fx = prepare("symlink-directory")
    defer: removeDir(fx.root)
    let outcome = atomicFastForward(fx.root, fx.newHead, execute)
    check "worktree restored" in outcome.diagnostic
    unchanged(fx)
    if fx.emulatedSymlink:
      check readFile(fx.root / "node") == ".git/external"
    else:
      check symlinkExists(fx.root / "node")
      check expandSymlink(fx.root / "node") == ".git/external"
    check readFile(fx.root / ".git" / "external" / "child") == "outside precious\n"

  test "Git emulated symlink representation also restores without privileges":
    let fx = prepare("symlink-directory", emulatedSymlink = true)
    defer: removeDir(fx.root)
    let outcome = atomicFastForward(fx.root, fx.newHead, execute)
    check "worktree restored" in outcome.diagnostic
    unchanged(fx)
    check readFile(fx.root / "node") == ".git/external"
    check git(fx.root, "ls-files", "--stage", "node").startsWith("120000 ")
    check readFile(fx.root / ".git" / "external" / "child") == "outside precious\n"

  test "directory to file partial checkout restores tracked children":
    let fx = prepare("directory-file")
    defer: removeDir(fx.root)
    let outcome = atomicFastForward(fx.root, fx.newHead, execute)
    check "worktree restored" in outcome.diagnostic
    unchanged(fx)
    check readFile(fx.root / "node" / "tracked") == "original node\n"

  test "directory to file refuses ignored child loss":
    let fx = prepare("directory-file-local")
    defer: removeDir(fx.root)
    let outcome = atomicFastForward(fx.root, fx.newHead, execute)
    check outcome.refused
    check "ignored path" in outcome.diagnostic
    unchanged(fx)
    check readFile(fx.root / "node" / "local") == "precious child\n"

  test "a successful fast-forward still advances HEAD and tracked state":
    let fx = prepare("file-directory", missingBlob = false)
    defer: removeDir(fx.root)
    let outcome = atomicFastForward(fx.root, fx.newHead, execute)
    check outcome.ok
    check git(fx.root, "rev-parse", "HEAD") == fx.newHead
    check git(fx.root, "status", "--porcelain").len == 0
    check readFile(fx.root / "node" / "child") == "new node\n"
    check readFile(fx.root / "ignored-local") == "precious\n"

  test "a concurrent fetch cannot change the preflighted checkout target":
    let fx = prepare(missingBlob = false)
    defer: removeDir(fx.root)
    discard git(fx.root, "checkout", "--detach", fx.newHead)
    writeFile(fx.root / "unexpected-addition", "later upstream\n")
    let laterHead = commit(fx.root, "later upstream")
    discard git(fx.root, "reset", "--hard", fx.oldHead)
    let remoteRef = "refs/remotes/origin/main"
    discard git(fx.root, "update-ref", remoteRef, fx.newHead)
    var raced = false
    let outcome = atomicFastForward(fx.root, remoteRef,
      proc(args: seq[string]; query: bool): FastForwardGitResult {.gcsafe.} =
        result = execute(args, query)
        if query and "diff" in args and not raced:
          raced = true
          let changed = execute(@["-C", fx.root, "update-ref", remoteRef, laterHead], false)
          doAssert changed.code == 0, changed.diagnostic)
    check raced
    check outcome.ok
    check git(fx.root, "rev-parse", "HEAD") == fx.newHead
    check not fileExists(fx.root / "unexpected-addition")

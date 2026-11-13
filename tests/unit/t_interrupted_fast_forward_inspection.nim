## Real Git/index/filesystem fixtures: no mocked checkout evidence.
import std/[os, osproc, strutils, tempfiles, unittest]
import git_tool
import interrupted_fast_forward

type Fixture = object
  root, oldTip, target: string
  identity: GitToolIdentity

proc git(f: Fixture; args: varargs[string]): string =
  let res = queryGit(f.identity, @["-C", f.root] & @args)
  if res.code != 0: raise newException(IOError, res.output)
  res.output.strip()

proc fixture(): Fixture =
  result.root = createTempDir("interrupted-ff-", "")
  result.identity.binaryPath = findExe("git")
  discard result.git("init", "-b", "main")
  discard result.git("config", "core.autocrlf", "false")
  discard result.git("config", "user.name", "Test")
  discard result.git("config", "user.email", "test@example.invalid")
  writeFile(result.root / "old", "old\n")
  writeFile(result.root / "edit", "before\n")
  writeFile(result.root / ".gitignore", "ignored*\n")
  discard result.git("add", ".")
  discard result.git("commit", "-m", "base")
  result.oldTip = result.git("rev-parse", "HEAD")
  removeFile(result.root / "old")
  writeFile(result.root / "new", "addition\n")
  writeFile(result.root / "edit", "after\n")
  discard result.git("add", "-A")
  discard result.git("commit", "-m", "advance")
  result.target = result.git("rev-parse", "HEAD")
  discard result.git("reset", "--hard", result.oldTip)

proc compatible(f: Fixture): bool =
  isInterruptedFastForward(f.identity, f.root, f.oldTip, f.target)

suite "interrupted fast-forward inspection":
  test "partial additions deletions and modifications are compatible":
    let f = fixture()
    defer: removeDir(f.root)
    removeFile(f.root / "old")
    writeFile(f.root / "edit", "after\n")
    writeFile(f.root / "new", "addition\n")
    check f.compatible()
    discard f.git("add", "-A")
    check f.compatible()

  test "unrelated worktree and index changes each reject recovery":
    let f = fixture()
    defer: removeDir(f.root)
    writeFile(f.root / "edit", "local\n")
    discard f.git("add", "edit")
    writeFile(f.root / "edit", "after\n")
    check not f.compatible()
    discard f.git("reset", "--hard", f.oldTip)
    writeFile(f.root / "edit", "after\n")
    discard f.git("add", "edit")
    writeFile(f.root / "edit", "local\n")
    check not f.compatible()

  test "unrelated untracked content rejects while unrelated ignored content survives":
    let f = fixture()
    defer: removeDir(f.root)
    writeFile(f.root / "edit", "after\n")
    writeFile(f.root / "ignored-local", "precious\n")
    check f.compatible()
    writeFile(f.root / "unrelated", "local\n")
    check not f.compatible()

  test "ignored target collisions reject even when the rest matches":
    let f = fixture()
    defer: removeDir(f.root)
    discard f.git("reset", "--hard", f.target)
    writeFile(f.root / "ignored-target", "upstream\n")
    discard f.git("add", "-f", "ignored-target")
    discard f.git("commit", "-m", "ignored target")
    let target = f.git("rev-parse", "HEAD")
    discard f.git("reset", "--hard", f.oldTip)
    writeFile(f.root / "edit", "after\n")
    writeFile(f.root / "ignored-target", "precious\n")
    check not isInterruptedFastForward(f.identity, f.root, f.oldTip, target)

  test "type and executable mode mismatches are not upstream content":
    let f = fixture()
    defer: removeDir(f.root)
    removeFile(f.root / "edit")
    when defined(windows):
      # A directory is an observable type mismatch without requiring Windows
      # Developer Mode/admin privilege to create a native symlink.
      createDir(f.root / "edit")
      check not f.compatible()
      removeDir(f.root / "edit")
      writeFile(f.root / "edit", "after\n")
      setFilePermissions(f.root / "edit", getFilePermissions(f.root / "edit") + {fpUserExec})
      check f.compatible() # Windows chmod cannot manufacture an executable bit.
      let blob = f.git("rev-parse", f.target & ":edit")
      discard f.git("update-index", "--cacheinfo", "120000," & blob & ",edit")
      check not f.compatible() # An unrelated index type change still refuses.
    else:
      createSymlink("after\n", f.root / "edit")
      check not f.compatible()
      removeFile(f.root / "edit")
      writeFile(f.root / "edit", "after\n")
      setFilePermissions(f.root / "edit", getFilePermissions(f.root / "edit") + {fpUserExec})
      check not f.compatible()

  test "equal divergent and missing target do not authorize recovery":
    let f = fixture()
    defer: removeDir(f.root)
    writeFile(f.root / "edit", "after\n")
    check not isInterruptedFastForward(f.identity, f.root, f.oldTip, f.oldTip)
    check not isInterruptedFastForward(f.identity, f.root, f.target, f.oldTip)
    check not isInterruptedFastForward(f.identity, f.root, f.oldTip, "missing")

  test "already clean checkout is not an interruption":
    let f = fixture()
    defer: removeDir(f.root)
    check not f.compatible()

  test "unmerged index does not establish a recovery proof":
    let f = fixture()
    defer: removeDir(f.root)
    writeFile(f.root / "edit", "after\n")
    let blob = f.git("rev-parse", f.oldTip & ":edit")
    discard f.git("update-index", "--cacheinfo", "100644," & blob & ",edit")
    let cmd = quoteShell(f.identity.binaryPath) & " -C " & quoteShell(f.root) &
      " update-index --index-info"
    let res = execCmdEx(cmd, input = "100644 " & blob & " 1\tedit\n")
    require res.exitCode == 0
    check not f.compatible()

  test "ignored descendants obstructing a target file reject recovery":
    let f = fixture()
    defer: removeDir(f.root)
    createDir(f.root / "new")
    writeFile(f.root / "new" / "ignored-local", "precious\n")
    writeFile(f.root / "edit", "after\n")
    check not f.compatible()

  test "symlink directory cannot lend external content to a proof":
    let f = fixture()
    defer: removeDir(f.root)
    discard f.git("reset", "--hard", f.target)
    createDir(f.root / "dir")
    writeFile(f.root / "dir" / "child", "upstream\n")
    discard f.git("add", "dir/child")
    discard f.git("commit", "-m", "directory")
    let target = f.git("rev-parse", "HEAD")
    discard f.git("reset", "--hard", f.oldTip)
    let external = createTempDir("interrupted-outside-", "")
    defer: removeDir(external)
    writeFile(external / "child", "upstream\n")
    when defined(windows):
      # A regular parent is also incapable of supplying the target child;
      # native Windows symlink creation requires privileges not needed here.
      writeFile(f.root / "dir", external)
    else:
      createSymlink(external, f.root / "dir")
    writeFile(f.root / "edit", "after\n")
    check not isInterruptedFastForward(f.identity, f.root, f.oldTip, target)

  test "diverged HEAD cannot borrow the target's recovery advice":
    let f = fixture()
    defer: removeDir(f.root)
    writeFile(f.root / "local", "local commit\n")
    discard f.git("add", "local")
    discard f.git("commit", "-m", "local divergence")
    let head = f.git("rev-parse", "HEAD")
    writeFile(f.root / "edit", "after\n")
    check not isInterruptedFastForward(f.identity, f.root, head, f.target)

  test "quoted path bytes and literal pathspec characters remain exact":
    let f = fixture()
    defer: removeDir(f.root)
    discard f.git("reset", "--hard", f.target)
    let path = when defined(windows): "literal spaces & bang!.txt"
               else: ":literal\tname\n*.txt"
    writeFile(f.root / path, "upstream\n")
    discard f.git("--literal-pathspecs", "add", "--", path)
    discard f.git("commit", "-m", "odd filename")
    let target = f.git("rev-parse", "HEAD")
    discard f.git("reset", "--hard", f.oldTip)
    writeFile(f.root / path, "upstream\n")
    check isInterruptedFastForward(f.identity, f.root, f.oldTip, target)

  test "recommended reset preserves unrelated ignored content":
    let f = fixture()
    defer: removeDir(f.root)
    writeFile(f.root / "edit", "after\n")
    writeFile(f.root / "ignored-local", "precious\n")
    require f.compatible()
    discard f.git("reset", "--hard", f.target)
    check readFile(f.root / "ignored-local") == "precious\n"

  test "platform-representable type and executable mode are recognized":
    let f = fixture()
    defer: removeDir(f.root)
    discard f.git("reset", "--hard", f.target)
    when defined(windows):
      # Windows stores executable mode only in the index. A target chmod is
      # safe to complete while its bytes are already in the worktree.
      discard f.git("update-index", "--chmod=+x", "edit")
      discard f.git("commit", "-m", "executable target")
      let target = f.git("rev-parse", "HEAD")
      discard f.git("reset", "--hard", f.oldTip)
      writeFile(f.root / "edit", "after\n")
      check isInterruptedFastForward(f.identity, f.root, f.oldTip, target)
      # With core.symlinks=false, a symlink blob becomes a regular file.
      # Physical type cannot be proved, so refuse that representation.
      discard f.git("reset", "--hard", target)
      discard f.git("config", "core.symlinks", "false")
      writeFile(f.root / "link", "destination")
      discard f.git("add", "link")
      let linkBlob = f.git("rev-parse", ":link")
      discard f.git("update-index", "--cacheinfo", "120000," & linkBlob & ",link")
      discard f.git("commit", "-m", "symlink target")
      let symlinkTarget = f.git("rev-parse", "HEAD")
      discard f.git("reset", "--hard", f.oldTip)
      writeFile(f.root / "edit", "after\n")
      writeFile(f.root / "link", "destination")
      check not isInterruptedFastForward(f.identity, f.root, f.oldTip, symlinkTarget)
    else:
      createSymlink("destination", f.root / "link")
      setFilePermissions(f.root / "edit", getFilePermissions(f.root / "edit") + {fpUserExec})
      discard f.git("add", "link", "edit")
      discard f.git("commit", "-m", "typed changes")
      let target = f.git("rev-parse", "HEAD")
      discard f.git("reset", "--hard", f.oldTip)
      createSymlink("destination", f.root / "link")
      writeFile(f.root / "edit", "after\n")
      setFilePermissions(f.root / "edit", getFilePermissions(f.root / "edit") + {fpUserExec})
      check isInterruptedFastForward(f.identity, f.root, f.oldTip, target)

  test "inspection errors do not turn an inaccessible path into a deletion":
    let f = fixture()
    defer: removeDir(f.root)
    discard f.git("reset", "--hard", f.target)
    createDir(f.root / "private")
    writeFile(f.root / "private" / "child", "before\n")
    discard f.git("add", "private/child")
    discard f.git("commit", "-m", "nested baseline")
    let head = f.git("rev-parse", "HEAD")
    removeFile(f.root / "private" / "child")
    discard f.git("add", "-A")
    discard f.git("commit", "-m", "nested deletion")
    let target = f.git("rev-parse", "HEAD")
    discard f.git("reset", "--hard", head)
    removeFile(f.root / "private" / "child")
    require isInterruptedFastForward(f.identity, f.root, head, target)
    when defined(windows):
      # Windows chmod does not implement POSIX directory access bits. Remove
      # a real required object instead, proving inspection errors fail closed.
      let tree = f.git("rev-parse", target & "^{tree}")
      let objectPath = f.root / ".git" / "objects" / tree[0..1] / tree[2..^1]
      setFilePermissions(objectPath, getFilePermissions(objectPath) + {fpUserWrite})
      removeFile(objectPath)
      check not isInterruptedFastForward(f.identity, f.root, head, target)
    else:
      let permissions = getFilePermissions(f.root / "private")
      setFilePermissions(f.root / "private", {})
      defer: setFilePermissions(f.root / "private", permissions)
      check not isInterruptedFastForward(f.identity, f.root, head, target)

  test "only the observed HEAD and an immutable target can authorize advice":
    let f = fixture()
    defer: removeDir(f.root)
    writeFile(f.root / "edit", "after\n")
    discard f.git("update-ref", "refs/heads/recovery", f.target)
    check not isInterruptedFastForward(f.identity, f.root, f.oldTip, "recovery")
    writeFile(f.root / "local", "new local commit\n")
    discard f.git("add", "local")
    discard f.git("commit", "-m", "advance HEAD after observation")
    check not f.compatible()

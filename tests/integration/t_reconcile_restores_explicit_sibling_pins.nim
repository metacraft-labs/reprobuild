## `scripts/reconcile_locked_siblings.sh` must put a sibling the lock does not
## list back at the explicit pin `.github/sibling-repos` names for it.
##
## The Test job builds two consumers from one sibling tree. CodeTracer's lock
## moves `nim-shm-gset` to an older revision for the `ct` build; reprobuild's
## own lock does not list that sibling, so the second pass left it there and
## the suite's recipe compile failed on `attempting to call undeclared routine:
## 'insertShardIndex'` (agents-based run 45131915341). The sibling-repos pass
## fixes that, and these cases hold it: the explicit pin is restored, the lock
## wins for a name it lists, and without the file the sibling stays where it
## was (the control that shows the test sees the defect).
##
## No mocks: real git repositories in a temp directory and the real script.
import std/[os, osproc, strutils, unittest]

const Script = "scripts/reconcile_locked_siblings.sh"

proc git(dir: string; args: string): string =
  let (output, code) = execCmdEx("git -C " & quoteShell(dir) &
    " -c user.name=t -c user.email=t@example.invalid " & args)
  doAssert code == 0, "git " & args & " failed: " & output
  output.strip()

proc makeSibling(root, name: string): tuple[old, new: string] =
  ## A repository with two commits; returns both revisions.
  let dir = root / name
  createDir(dir)
  discard git(dir, "init -q")
  writeFile(dir / "f", "one")
  discard git(dir, "add f")
  discard git(dir, "commit -q -m one")
  result.old = git(dir, "rev-parse HEAD")
  writeFile(dir / "f", "two")
  discard git(dir, "commit -q -a -m two")
  result.new = git(dir, "rev-parse HEAD")

proc lockWith(entries: seq[(string, string)]): string =
  var groups: seq[string]
  for (name, revision) in entries:
    groups.add("{ name = \"" & name & "\", coord_kind = \"vcs\", revision = \"" &
      revision & "\" }")
  "deps = [" & groups.join(", ") & "]\n"

proc reconcile(lock, root, siblingRepos: string): tuple[output: string, code: int] =
  ## `code` is the script's exit status.
  var cmd = "bash " & quoteShell(getCurrentDir() / Script) & " " &
    quoteShell(lock) & " " & quoteShell(root) & " reprobuild --detach"
  if siblingRepos.len > 0: cmd.add(" " & quoteShell(siblingRepos))
  let (output, code) = execCmdEx(cmd)
  (output: output, code: code)

suite "reconcile_locked_siblings explicit pins":
  setup:
    let root = getTempDir() / ("t_reconcile_explicit_" & $getCurrentProcessId())
    removeDir(root)
    createDir(root)
  teardown:
    removeDir(root)

  test "a sibling the lock omits returns to its explicit pin":
    let gset = makeSibling(root, "nim-shm-gset")
    let other = makeSibling(root, "other")
    discard git(root / "nim-shm-gset", "checkout -q --detach " & gset.old)
    let lock = root / "repro.lock"
    writeFile(lock, lockWith(@[("other", other.old)]))
    let pins = root / "sibling-repos"
    writeFile(pins, "# comment\nnim-shm-gset=" & gset.new & "\nbare-name\n" &
      "branchy=dev\n")
    let (output, code) = reconcile(lock, root, pins)
    check code == 0
    check git(root / "nim-shm-gset", "rev-parse HEAD") == gset.new
    check "nim-shm-gset -> explicit " & gset.new in output
    check git(root / "other", "rev-parse HEAD") == other.old

  test "without the file the sibling stays where it was":
    let gset = makeSibling(root, "nim-shm-gset")
    discard git(root / "nim-shm-gset", "checkout -q --detach " & gset.old)
    let lock = root / "repro.lock"
    writeFile(lock, lockWith(@[("nim-shm-gset-other", gset.old)]))
    let (_, code) = reconcile(lock, root, "")
    check code == 0
    check git(root / "nim-shm-gset", "rev-parse HEAD") == gset.old

  test "a name the lock lists keeps the lock's revision":
    let gset = makeSibling(root, "nim-shm-gset")
    discard git(root / "nim-shm-gset", "checkout -q --detach " & gset.new)
    let lock = root / "repro.lock"
    writeFile(lock, lockWith(@[("nim-shm-gset", gset.old)]))
    let pins = root / "sibling-repos"
    writeFile(pins, "nim-shm-gset=" & gset.new & "\n")
    let (_, code) = reconcile(lock, root, pins)
    check code == 0
    check git(root / "nim-shm-gset", "rev-parse HEAD") == gset.old

  test "a missing sibling-repos file is refused":
    let lock = root / "repro.lock"
    writeFile(lock, lockWith(@[]))
    let (output, code) = reconcile(lock, root, root / "absent")
    check code == 1
    check "no sibling-repos file" in output

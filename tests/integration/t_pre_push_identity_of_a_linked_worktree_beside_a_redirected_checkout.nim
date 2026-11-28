## Pre-push identity of a linked worktree whose declared checkout Git answers
## for another directory.
##
## A workspace declares `member` at `member/`, and linked worktrees of that
## checkout (`git worktree add`) sit beside it. The gate identifies a push
## from such a worktree by its Git common directory: the worktree's common
## directory is the declared checkout's `.git`.
##
## Git reads `core.worktree` from the repository's SHARED config. When that
## setting names another directory (in the reported workspace a linked
## worktree, `agent-harbor-wt-prc3`), `git -C member rev-parse
## --show-toplevel` answers that directory, so the declared path no longer
## validates as a worktree root. The gate then skipped the declared checkout
## for every criterion: not a common-directory match (it was never asked),
## and not remote recovery (the checkout exists). Every push from every
## healthy linked worktree of the repository was refused with "does not match
## a declared repo by path, Git common directory, or configured remote" —
## although it matched by Git common directory and by remote — and the
## refusal's header read `branch=<none>` in a workspace that records a
## branch.
##
## The suite drives the real `repro` binary through `hooks dispatch pre-push`
## (the managed hook's call) against real Git repositories, a real
## `git worktree add` and a real local bare origin, so publication is judged
## offline. Nothing is mocked. Controls keep it from passing vacuously: the
## same push passes without the stray setting, and a separate clone (its own
## object store) beside the redirected checkout is still refused, so the fix
## did not turn a corrupt declared checkout into remote recovery.

from repro_core/process_streams import drainStream
import std/[json, os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

type
  Fixture = object
    scratch, workspace, declared, pushed, other, origin, lockStore: string
    gitBin, reproBin, sha: string

proc q(value: string): string = quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
  (res.exitCode, res.output)

proc require(command: string): string =
  let res = run(command)
  if res.code != 0:
    raise newException(IOError, "command failed: " & command &
      "\nexit=" & $res.code & "\n" & res.output)
  res.output

proc git(fx: Fixture; repo, rest: string): string =
  require(q(fx.gitBin) & " -C " & q(repo) & " " & rest)

proc sourceRoot(): string = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(sourceRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc runProcess(binary: string; args: openArray[string]):
    tuple[code: int; output: string] =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  let process = startProcess(binary, args = @args, env = env,
    options = {poStdErrToStdOut, poUsePath})
  defer: process.close()
  result.output = drainStream(process.outputStream)
  result.code = process.waitForExit()

proc configureUser(fx: Fixture; work: string) =
  discard fx.git(work, "config user.email worktree@example.invalid")
  discard fx.git(work, "config user.name 'Worktree Identity Tester'")

const
  ProjectToml = """
schema = "reprobuild.workspace.project.v1"

# Before the `[project]` header: a bare key after it binds to that table.
includes = ["repos/member.toml"]

[project]
name = "demo"
"""
  MemberToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "member"
path = "member"
url_prefix = "example"
mainline = "main"
"""

proc setup(): Fixture =
  result.gitBin = findExe("git")
  doAssert result.gitBin.len > 0, "git is required"
  result.reproBin = reproBinary()
  result.scratch = createTempDir("repro-pre-push-redirected-checkout-", "")
  var complete = false
  defer:
    if not complete and dirExists(result.scratch):
      removeDir(result.scratch)
  let fx = result
  let origins = fx.scratch / "origins"
  result.origin = origins / "member"
  result.workspace = fx.scratch / "workspace"
  result.declared = result.workspace / "member"
  # Both worktrees sit at the workspace root beside the declared checkout,
  # as `agent-harbor-wt-rel0` and `agent-harbor-wt-prc3` did.
  result.pushed = result.workspace / "member-wt-pushed"
  result.other = result.workspace / "member-wt-other"
  result.lockStore = result.workspace / ".repro" / "manifests"
  createDir(origins)
  createDir(result.workspace)

  discard require(q(fx.gitBin) & " init --bare -b main " & q(result.origin))
  let seed = fx.scratch / "seed"
  discard require(q(fx.gitBin) & " init -b main " & q(seed))
  fx.configureUser(seed)
  writeFile(seed / "README.md", "member\n")
  discard fx.git(seed, "add README.md")
  discard fx.git(seed, "commit -m seed")
  discard fx.git(seed, "remote add origin " & q(fileUrl(result.origin)))
  discard fx.git(seed, "push -u origin main")
  result.sha = fx.git(seed, "rev-parse HEAD").strip()

  # The declared checkout's `origin` is the declared URL (`url_prefix` +
  # name), as in the reported workspace.
  discard require(q(fx.gitBin) & " clone -q " & q(fileUrl(result.origin)) &
    " " & q(result.declared))
  discard fx.git(result.declared, "worktree add -q -b pushed " &
    q(result.pushed) & " origin/main")
  discard fx.git(result.declared, "worktree add -q -b other " &
    q(result.other) & " origin/main")

  createDir(result.workspace / "projects")
  createDir(result.workspace / "repos")
  createDir(result.workspace / "url-prefixes")
  writeFile(result.workspace / "projects" / "demo.toml", ProjectToml)
  writeFile(result.workspace / "repos" / "member.toml", MemberToml)
  writeFile(result.workspace / "url-prefixes" / "example.toml",
    "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n" &
    "[url-prefix]\nname = \"example\"\nurl = \"" & fileUrl(origins) & "\"\n")
  writeWorkspaceProjects(result.workspace, @["demo"])
  writeWorkspaceBranch(result.workspace, "demo", "feature-x")

  createDir(result.lockStore)
  discard require(q(fx.gitBin) & " init -b main " & q(result.lockStore))
  fx.configureUser(result.lockStore)
  writeFile(result.lockStore / ".gitkeep", "")
  discard fx.git(result.lockStore, "add .gitkeep")
  discard fx.git(result.lockStore, "commit -m 'seed lock store'")
  complete = true

proc redirectDeclaredCheckout(fx: Fixture) =
  ## The stray setting: `core.worktree` in the shared config, naming the
  ## OTHER linked worktree. Linked worktrees ignore it; the main one obeys.
  discard fx.git(fx.declared, "config core.worktree " & q(fx.other))
  check expandFilename(fx.git(fx.declared,
    "rev-parse --show-toplevel").strip()) == expandFilename(fx.other)
  check expandFilename(fx.git(fx.pushed,
    "rev-parse --show-toplevel").strip()) == expandFilename(fx.pushed)

proc report(fx: Fixture): JsonNode =
  parseFile(fx.workspace / ".repro" / "build" / "reports" /
    "check-report.json")

proc dispatch(fx: Fixture; root: string): tuple[code: int; output: string] =
  ## The hook invocation Git makes for `git push origin pushed:main`.
  let refs = fx.scratch / "refs.bin"
  writeFile(refs, "refs/heads/pushed " & fx.sha & " refs/heads/main " &
    fx.sha & "\n")
  runProcess(fx.reproBin,
    ["hooks", "dispatch", "pre-push", "--protocol=2",
     "--repo-root", root, "--refs-file", refs, "--",
     "origin", fileUrl(fx.origin)])

proc recordedLock(fx: Fixture): bool =
  if not dirExists(fx.lockStore / "locks"): return false
  for path in walkDirRec(fx.lockStore / "locks"):
    if path.endsWith(fx.sha & ".toml") and
        "path = \"member\"" in readFile(path):
      return true

suite "pre-push identity of a linked worktree beside a redirected checkout":
  test "control: the linked worktree passes while the checkout is healthy":
    let fx = setup()
    defer: removeDir(fx.scratch)
    let dispatched = fx.dispatch(fx.pushed)
    checkpoint(dispatched.output)
    check dispatched.code == 0
    let document = fx.report()
    checkpoint($document["failures"])
    check document["failures"].len == 0
    check "core.worktree" notin $document["notices"]
    check fx.recordedLock()

  test "a stray core.worktree does not unmake the linked worktree's identity":
    let fx = setup()
    defer: removeDir(fx.scratch)
    fx.redirectDeclaredCheckout()
    let dispatched = fx.dispatch(fx.pushed)
    checkpoint(dispatched.output)
    check "does not match a declared repo" notin dispatched.output
    check dispatched.code == 0
    let document = fx.report()
    checkpoint($document["failures"])
    check document["failures"].len == 0
    check expandFilename(document["currentRepo"].getStr()) ==
      expandFilename(fx.pushed)
    # The gate says why the declared checkout looked wrong, and where to look.
    let notices = $document["notices"]
    checkpoint(notices)
    check "recognized 'member' by its Git common directory" in notices
    check "core.worktree" in notices
    check fx.recordedLock()

  test "a separate clone beside the redirected checkout is still refused":
    let fx = setup()
    defer: removeDir(fx.scratch)
    fx.redirectDeclaredCheckout()
    # Its own object store, the declared remote: an independent clone, which
    # the gate refuses while the declared path holds a checkout, however that
    # checkout is configured.
    let clone = fx.workspace / "member-clone"
    discard require(q(fx.gitBin) & " clone -q " & q(fileUrl(fx.origin)) &
      " " & q(clone))
    let dispatched = fx.dispatch(clone)
    checkpoint(dispatched.output)
    check dispatched.code == 2
    let document = fx.report()
    check document["failures"].len == 1
    check document["failures"][0]["property"].getStr() ==
      "current-repo-identity"
    check not fx.recordedLock()
    # The refusal's header carries the workspace's recorded branch.
    check "branch=<none>" notin dispatched.output
    check "branch=feature-x" in dispatched.output

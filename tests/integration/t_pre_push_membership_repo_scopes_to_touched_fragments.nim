## Unified-Locking-And-Hooks.md §8.4 — "Push of the membership
## (`repro-workspace`) repo"; the rule is stated in
## Workspace-And-Develop-Mode.md §"Gate scope when the pushed repo is the
## membership repo".
##
## The membership repo — the one carrying ``projects/``/``repos/`` — is not a
## project repo: it declares no ``depends`` edges, so RA-21's develop-set
## closure is empty, and in the flat native layout it is not a ``[[manifest]]``
## layer either. Both of ``prePushScope``'s narrowing arms therefore missed it
## and it fell through to the whole-workspace fallback, which let an unrelated
## dirty sibling block a one-line manifest edit — exactly the friction the
## "scope the gate like git submodules" rule exists to remove.
##
## The corrected scope is the repos whose manifest fragments the pushed commit
## range actually modifies. This test pins both directions, which is what makes
## it meaningful — a scope that is merely narrower could be vacuous:
##
##   1. a commit touching ``repos/lib-a.toml`` PASSES while lib-b is dirty
##      (lib-b is out of scope and must not block), and
##   2. a commit touching ``repos/lib-b.toml`` FAILS naming lib-b
##      (an in-scope dirty repo still refuses — the gate did not simply stop
##      checking).
##
## Case 2 is the guard against "fixed" meaning "disabled".
##
## No mocks: real git repos on the real filesystem, driven through the real
## ``build/bin/repro`` binary.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

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
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc configureIdentity(gitBin, path: string) =
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"Membership Scope Tester\"")

proc seedOrigin(gitBin, originPath, seedPath: string) =
  ## A bare origin with one published commit, so a clone of it is clean and
  ## published — the state the gate expects of an in-scope sibling.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(seedPath))
  configureIdentity(gitBin, seedPath)
  writeFile(seedPath / "README.md", "membership-scope fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " remote add origin " &
    q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " push origin main")

proc fragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\nname = \"" & name & "\"\npath = \"" & name & "\"\n" &
  "remote = \"" & name & "-origin\"\nrevision = \"main\"\n"

proc projectToml(libAUrl, libBUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\nname = \"ws\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n  \"repos/lib-b.toml\",\n]\n"

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string

proc buildFixture(gitBin, slug: string): Fixture =
  ## A FLAT native-layout workspace: ``projects/`` and ``repos/`` live at the
  ## workspace root, and that root is itself a git checkout with an origin —
  ## i.e. the membership repo. lib-a and lib-b are cloned side by side, both
  ## clean and published.
  result.scratch = createTempDir("repro-membership-scope-" & slug & "-", "")
  result.reproBin = reproBinary()

  let libAOrigin = result.scratch / "origin-lib-a.git"
  let libBOrigin = result.scratch / "origin-lib-b.git"
  seedOrigin(gitBin, libAOrigin, result.scratch / "seed-lib-a")
  seedOrigin(gitBin, libBOrigin, result.scratch / "seed-lib-b")

  let workspaceRoot = result.scratch / "workspace"
  let membershipOrigin = result.scratch / "origin-membership.git"
  discard requireGit(q(gitBin) & " init --bare -b main " & q(membershipOrigin))
  createDir(workspaceRoot)
  discard requireGit(q(gitBin) & " init -b main " & q(workspaceRoot))
  configureIdentity(gitBin, workspaceRoot)
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  writeFile(workspaceRoot / "projects" / "ws.toml",
    projectToml(fileUrl(libAOrigin), fileUrl(libBOrigin)))
  writeFile(workspaceRoot / "repos" / "lib-a.toml", fragmentToml("lib-a"))
  writeFile(workspaceRoot / "repos" / "lib-b.toml", fragmentToml("lib-b"))
  # The sibling checkouts are nested working trees, not content of the
  # membership repo — ignore them so the membership repo stays clean.
  writeFile(workspaceRoot / ".gitignore", "/lib-a/\n/lib-b/\n/.repro/\n")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " commit -m \"seed membership\"")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " remote add origin " & q(membershipOrigin))
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) & " push origin main")

  discard requireGit(q(gitBin) & " clone " & q(fileUrl(libAOrigin)) & " " &
    q(workspaceRoot / "lib-a"))
  configureIdentity(gitBin, workspaceRoot / "lib-a")
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(libBOrigin)) & " " &
    q(workspaceRoot / "lib-b"))
  configureIdentity(gitBin, workspaceRoot / "lib-b")
  writeWorkspaceBranch(workspaceRoot, project = "ws", branch = "main")
  result.workspaceRoot = workspaceRoot

proc dirty(path: string) =
  writeFile(path / "uncommitted.txt", "work in progress\n")

proc commitFragmentEdit(gitBin, workspaceRoot, fragment: string) =
  ## Touch one repo fragment and commit it — the membership change whose scope
  ## the gate must derive from the pushed range.
  let path = workspaceRoot / "repos" / fragment
  writeFile(path, readFile(path) & "\n# touched by the membership commit\n")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " commit -m \"edit " & fragment & "\"")

proc gateResult(fx: Fixture): tuple[code: int; output: string] =
  runCmd(q(fx.reproBin) & " check --mode=pre-push" &
    " --workspace-root=" & q(fx.workspaceRoot) &
    " --current-repo=" & q(fx.workspaceRoot))

suite "pre-push — membership repo scopes to touched fragments":
  let gitBin = findExe("git")

  test "dirty repo OUTSIDE the touched fragments does not block the push":
    if gitBin.len == 0:
      skip()
    else:
      let fx = buildFixture(gitBin, "out-of-scope")
      defer: removeDir(fx.scratch)
      # lib-b is dirty but the commit only touches lib-a's fragment.
      dirty(fx.workspaceRoot / "lib-b")
      commitFragmentEdit(gitBin, fx.workspaceRoot, "lib-a.toml")

      let res = gateResult(fx)
      check res.code == 0
      # The offender must not even be mentioned: it is out of scope, not
      # merely tolerated.
      check "lib-b" notin res.output

  test "dirty repo INSIDE the touched fragments still refuses, naming it":
    if gitBin.len == 0:
      skip()
    else:
      let fx = buildFixture(gitBin, "in-scope")
      defer: removeDir(fx.scratch)
      # Same dirty lib-b, but now the commit touches lib-b's fragment.
      dirty(fx.workspaceRoot / "lib-b")
      commitFragmentEdit(gitBin, fx.workspaceRoot, "lib-b.toml")

      let res = gateResult(fx)
      check res.code == 2
      check "lib-b" in res.output

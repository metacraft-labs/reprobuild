## The committed ``repro.lock`` records the revisions of the develop-set
## siblings a repo is built and tested against
## (Unified-Locking-And-Hooks.md §14, "The default: the committed lock records
## the develop set").
##
## WHY THIS EXISTS. A repo whose siblings reach its build OUTSIDE reprobuild's
## solved graph — a Rust recorder consuming ``../codetracer-trace-format``
## through cargo ``path`` dependencies is the fleet's common case — used to get
## a self-only ``deps`` from ``repro lock refresh``: the root entry and nothing
## else. The workspace manifest DID declare the edge (the pre-push gate scopes
## its clean/published checks to exactly that ``depends`` closure), but the
## lock never recorded where those siblings were, so "which sibling revisions
## was this commit built against" had no committed answer. CI then had to ask a
## separate record store for it, and a commit with no record there could not
## run at all.
##
## Fixture (built ``./build/bin/repro``, black-box; real git, real filesystem):
##
##   <scratch>/workspace/                 a manifest workspace
##     projects/app.toml, repos/*.toml    app depends on lib-b; lib-b depends on
##                                        lib-c; lib-d is unrelated (no edge)
##     .repro/workspace.toml              the workspace metadata marker
##     app/    (git, published)           carries ``repro.solver`` — the lock's
##                                        solver inputs; no recipe needed
##     lib-b/  lib-c/  lib-d/  (git, published)
##
## Asserts:
##   1. ``repro lock refresh app`` records lib-b AND lib-c (the TRANSITIVE
##      closure of the manifest ``depends`` edges) as ``deps`` entries at
##      ``../lib-b`` / ``../lib-c`` with VCS coordinates, the sibling's HEAD as
##      ``revision`` and a ``git-sha1:<HEAD>`` integrity; the root entry
##      ``depends`` on both. lib-d — in the workspace, not in the closure — is
##      NOT recorded.
##   2. After lib-b advances by a published commit, a second refresh re-pins
##      lib-b at its new HEAD (an observation of the checkout, not a copy of the
##      old pin).
##   3. Carry-forward outside a workspace: a fresh standalone clone of app with
##      no workspace and no sibling checkouts still records lib-b and lib-c
##      after a refresh, at the committed pins. A refresh must never silently
##      DROP a sibling pin merely because it cannot see the sibling.
##
## Falsifiability (observed): against the pre-§14 ``lockedDepsForWorkspace``
## the lock carries only ``path = "."``, so (1) fails on the absent
## ``../lib-b`` entry.
##
## NO MOCKS. Every repository is a real local git repository with a real bare
## origin; the manifest is a real on-disk manifest the production resolver
## reads. Nothing touches $HOME or the network.
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
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

proc configureIdentity(gitBin, work: string) =
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.name \"Lock Tester\"")

proc seedPublished(gitBin, scratch, workspace, name: string): string =
  ## A bare origin plus a checkout of it at ``workspace/name`` with one
  ## published commit. Returns the origin path.
  let origin = scratch / ("origin-" & name & ".git")
  let work = workspace / name
  discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " & q(work))
  configureIdentity(gitBin, work)
  writeFile(work / "README.md", name & " fixture\n")
  if name == "app":
    writeFile(work / "repro.solver", solverInputs)
    writeFile(work / ".gitignore", ".repro/\n")
  discard requireGit(q(gitBin) & " -C " & q(work) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(work) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(work) & " push origin main")
  origin

proc fragment(name: string; depends: seq[string]): string =
  result = "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & name & "-origin\"\nrevision = \"main\"\n"
  if depends.len > 0:
    result.add("depends = [")
    for i, d in depends:
      if i > 0: result.add(", ")
      result.add("\"" & d & "\"")
    result.add("]\n")

proc headOf(gitBin, work: string): string =
  requireGit(q(gitBin) & " -C " & q(work) & " rev-parse HEAD").strip()

proc depLineFor(lockBody, path: string): string =
  ## The inline-table text of the ``deps`` entry whose ``path`` is ``path``,
  ## or "" when there is none.
  let key = "path = \"" & path & "\""
  let at = lockBody.find(key)
  if at < 0: return ""
  let open = lockBody.rfind('{', 0, at)
  let close = lockBody.find('}', at)
  if open < 0 or close < 0: return ""
  lockBody[open .. close]

suite "the committed lock records the develop-set siblings":

  test "t_committed_lock_records_develop_set_siblings":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let reproBin = reproBinary()
      let scratch = createTempDir("repro-lock-develop-set-", "")
      defer: removeDir(scratch)
      let workspace = scratch / "workspace"
      createDir(workspace)

      var origins: seq[(string, string)] = @[]
      for name in ["app", "lib-b", "lib-c", "lib-d"]:
        origins.add((name, seedPublished(gitBin, scratch, workspace, name)))

      createDir(workspace / "projects")
      createDir(workspace / "repos")
      var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n"
      for (name, origin) in origins:
        project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
          fileUrl(origin) & "\"\n\n")
      project.add("includes = [\n  \"repos/app.toml\",\n" &
        "  \"repos/lib-b.toml\",\n  \"repos/lib-c.toml\",\n" &
        "  \"repos/lib-d.toml\",\n]\n")
      writeFile(workspace / "projects" / "app.toml", project)
      writeFile(workspace / "repos" / "app.toml", fragment("app", @["lib-b"]))
      writeFile(workspace / "repos" / "lib-b.toml",
        fragment("lib-b", @["lib-c"]))
      writeFile(workspace / "repos" / "lib-c.toml", fragment("lib-c", @[]))
      writeFile(workspace / "repos" / "lib-d.toml", fragment("lib-d", @[]))
      writeWorkspaceBranch(workspace, project = "app", branch = "main")

      let app = workspace / "app"
      let libBHead = headOf(gitBin, workspace / "lib-b")
      let libCHead = headOf(gitBin, workspace / "lib-c")

      # ---- (1) the transitive develop set is recorded, and nothing else. ----
      let refresh = runCmd(q(reproBin) & " lock refresh " & q(app))
      checkpoint(refresh.output)
      check refresh.code == 0
      let body = readFile(app / "repro.lock")
      checkpoint(body)
      let libB = depLineFor(body, "../lib-b")
      let libC = depLineFor(body, "../lib-c")
      check libB.len > 0
      check libC.len > 0
      check "name = \"lib-b\"" in libB
      check "coord_kind = \"vcs\"" in libB
      check ("revision = \"" & libBHead & "\"") in libB
      check ("integrity = \"git-sha1:" & libBHead & "\"") in libB
      check ("revision = \"" & libCHead & "\"") in libC
      check ("integrity = \"git-sha1:" & libCHead & "\"") in libC
      check depLineFor(body, "../lib-d").len == 0
      check "lib-d" notin body
      let root = depLineFor(body, ".")
      check "lib-b" in root
      check "lib-c" in root

      # ---- (2) a sibling that moved is re-pinned from its checkout. ----
      let libBDir = workspace / "lib-b"
      writeFile(libBDir / "change.txt", "advance\n")
      discard requireGit(q(gitBin) & " -C " & q(libBDir) & " add change.txt")
      discard requireGit(q(gitBin) & " -C " & q(libBDir) & " commit -m advance")
      discard requireGit(q(gitBin) & " -C " & q(libBDir) & " push origin main")
      let libBNext = headOf(gitBin, libBDir)
      check libBNext != libBHead
      let again = runCmd(q(reproBin) & " lock refresh " & q(app))
      checkpoint(again.output)
      check again.code == 0
      let body2 = readFile(app / "repro.lock")
      check ("revision = \"" & libBNext & "\"") in depLineFor(body2, "../lib-b")
      check ("revision = \"" & libCHead & "\"") in depLineFor(body2, "../lib-c")

      # Commit + publish the lock so a fresh clone carries it.
      discard requireGit(q(gitBin) & " -C " & q(app) & " add repro.lock")
      discard requireGit(q(gitBin) & " -C " & q(app) & " commit -m lock")
      discard requireGit(q(gitBin) & " -C " & q(app) & " push origin main")

      # ---- (3) outside any workspace, with no sibling checkouts, a refresh
      # carries the committed sibling pins forward rather than dropping them.
      let lone = scratch / "standalone" / "app"
      createDir(scratch / "standalone")
      var appOrigin = ""
      for (name, origin) in origins:
        if name == "app": appOrigin = origin
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(appOrigin)) & " " &
        q(lone))
      configureIdentity(gitBin, lone)
      check not dirExists(scratch / "standalone" / "lib-b")
      let loneRefresh = runCmd(q(reproBin) & " lock refresh " & q(lone))
      checkpoint(loneRefresh.output)
      check loneRefresh.code == 0
      let body3 = readFile(lone / "repro.lock")
      checkpoint(body3)
      check ("revision = \"" & libBNext & "\"") in depLineFor(body3, "../lib-b")
      check ("revision = \"" & libCHead & "\"") in depLineFor(body3, "../lib-c")

## Shared fixture for the committed-lock sibling-pin tests
## (Unified-Locking-And-Hooks.md §13.3 / §13.5 / §14).
##
## A real manifest workspace on disk — `projects/app.toml`, `repos/*.toml`,
## `.repro/workspace.toml` — with four real git repositories, each cloned from
## its own bare origin and published:
##
##   app    repro.nim `uses: "lib-b"`
##   lib-b  repro.nim `uses: "lib-c"` (a library)
##   lib-c  repro.nim (a library)
##   lib-d  repro.nim (a library), in nobody's dependency set until a case
##          adds it to app's `uses:` (``setAppUses``)
##
## The dependencies are declared in the recipes because that is the only place
## reprobuild reads them (owner decision 2026-11-05,
## Unified-Locking-And-Hooks.md §14.9): `repro lock refresh` derives app's
## lock from app's recipe, transitively through lib-b's. The fragments declare
## membership and placement only. This fixture used to put the edges in
## fragment `depends` and give app a `repro.solver` sidecar instead.
##
## Nothing is mocked: the manifest is read by the production resolver, the
## repositories are real, the recipes are compiled by the real provider path,
## and `repro` is the built `./build/bin/repro`.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/recipe_dependencies
import repro_workspace_manifests

proc q*(value: string): string = quoteShell(value)

proc runCmd*(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireCmd*(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc reproBinary*(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

type SiblingFixture* = object
  gitBin*, repro*, scratch*, ws*, app*: string
  origins*: seq[(string, string)]
  appUses*: seq[string]
    ## The workspace siblings app's recipe currently `uses:`.

proc git*(fx: SiblingFixture; repo, args: string): string =
  requireCmd(q(fx.gitBin) & " -C " & q(repo) & " " & args)

proc headOf*(fx: SiblingFixture; repo: string): string =
  fx.git(repo, "rev-parse HEAD").strip()

proc fragment(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & name & "-origin\"\nmainline = \"main\"\n"

const fixtureUses = [("app", @["lib-b"]), ("lib-b", @["lib-c"]),
  ("lib-c", newSeq[string]()), ("lib-d", newSeq[string]())]
  ## Each repo's recipe `uses:` at setup.

proc setAppUses*(fx: var SiblingFixture; uses: seq[string]) =
  ## Change the siblings app's recipe `uses:`, then commit and publish the
  ## recipe (not the lock): the state after a dependency edit pushed without
  ## running `repro lock refresh`. Published so that the pre-push gate's only
  ## question about app's own HEAD is the lock, not its publication.
  fx.appUses = uses
  writeDependencyRecipe(fx.app, uses, library = false)
  discard fx.git(fx.app, "add repro.nim .gitignore")
  discard fx.git(fx.app, "commit -q -m uses")
  discard fx.git(fx.app, "push -q origin main")

proc setupSiblingFixture*(label: string): SiblingFixture =
  result.gitBin = findExe("git")
  result.repro = reproBinary()
  result.scratch = createTempDir("repro-" & label & "-", "")
  result.ws = result.scratch / "workspace"
  createDir(result.ws)
  for name in ["app", "lib-b", "lib-c", "lib-d"]:
    let origin = result.scratch / ("origin-" & name & ".git")
    let work = result.ws / name
    discard requireCmd(q(result.gitBin) & " init --bare -b main " & q(origin))
    discard requireCmd(q(result.gitBin) & " clone " & q(fileUrl(origin)) &
      " " & q(work))
    discard result.git(work, "config user.email tester@example.invalid")
    discard result.git(work, "config user.name \"Lock Tester\"")
    discard result.git(work, "config commit.gpgsign false")
    writeFile(work / "README.md", name & " fixture\n")
    for (repo, uses) in fixtureUses:
      if repo == name:
        writeDependencyRecipe(work, uses, library = name != "app")
    discard result.git(work, "add -A")
    discard result.git(work, "commit -q -m seed")
    discard result.git(work, "push -q origin main")
    result.origins.add((name, origin))
  result.app = result.ws / "app"
  createDir(result.ws / "projects")
  createDir(result.ws / "repos")
  var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\n" &
    "\n"
  for (name, origin) in result.origins:
    project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
      fileUrl(origin) & "\"\n\n")
  project.add("includes = [\n  \"repos/app.toml\",\n" &
    "  \"repos/lib-b.toml\",\n  \"repos/lib-c.toml\",\n" &
    "  \"repos/lib-d.toml\",\n]\n")
  writeFile(result.ws / "projects" / "app.toml", project)
  result.appUses = @["lib-b"]
  for name in ["app", "lib-b", "lib-c", "lib-d"]:
    writeFile(result.ws / "repos" / (name & ".toml"), fragment(name))
  writeWorkspaceBranch(result.ws, project = "app", branch = "main")
  # lib-b depends on lib-c, so lib-b carries the lock that records it (a repo
  # whose recipe derives a dependency the lock does not pin is refused at its
  # own push). app's lock is written by the case (``refreshAndPublishLock``).
  let libB = result.ws / "lib-b"
  let refreshed = refreshCommittedLock(result.repro, libB)
  doAssert refreshed.code == 0, "lib-b lock refresh failed:\n" &
    refreshed.output
  discard result.git(libB, "add repro.lock")
  discard result.git(libB, "commit -q -m lock")
  discard result.git(libB, "push -q origin main")

proc refreshAndPublishLock*(fx: SiblingFixture) =
  ## `repro lock refresh` (the explicit door), then commit + push the lock.
  let r = runCmd(q(fx.repro) & " lock refresh " & q(fx.app))
  checkpoint(r.output)
  check r.code == 0
  discard fx.git(fx.app, "add repro.lock")
  discard fx.git(fx.app, "commit -q -m lock")
  discard fx.git(fx.app, "push -q origin main")

var advanceCounter = 0

proc advance*(fx: SiblingFixture; name: string): string =
  ## A new PUBLISHED commit in sibling `name`; returns its SHA.
  let work = fx.ws / name
  inc advanceCounter
  writeFile(work / "change.txt", "advance " & $advanceCounter & "\n")
  discard fx.git(work, "add change.txt")
  discard fx.git(work, "commit -q -m advance")
  discard fx.git(work, "push -q origin main")
  fx.headOf(work)

proc depEntry*(lockBody, name: string): string =
  ## The inline table of the `deps` entry named `name`, or "". `"."` names
  ## the lock's OWN entry, the one marked `self = "true"` — the spelling a
  ## lock reader holds it at. Entries are found by name because a lock records
  ## no checkout path (Workspace-Manifests.md §"The committed lock carries the
  ## full set (schema v3)").
  let at =
    if name == ".": lockBody.find("self = \"true\"")
    # After `deps = [`: a `packages` entry starts with the same prefix.
    else: lockBody.find("{ name = \"" & name & "\"", max(0, lockBody.find("deps = [")))
  if at < 0: return ""
  let open = lockBody.rfind('{', 0, at)
  let close = lockBody.find('}', at)
  if open < 0 or close < 0: return ""
  lockBody[open .. close]

proc linePrefixed*(body, prefix: string): string =
  for line in body.splitLines():
    if line.startsWith(prefix): return line
  ""

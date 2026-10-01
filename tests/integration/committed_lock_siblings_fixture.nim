## Shared fixture for the committed-lock sibling-pin tests
## (Unified-Locking-And-Hooks.md §13.3 / §13.5 / §14).
##
## A real manifest workspace on disk — `projects/app.toml`, `repos/*.toml`,
## `.repro/workspace.toml` — with four real git repositories, each cloned from
## its own bare origin and published:
##
##   app    carries `repro.solver` (the lock's solver inputs; no recipe needed)
##          and depends on lib-b
##   lib-b  depends on lib-c
##   lib-c
##   lib-d  in the workspace, in nobody's develop set until a case adds it
##
## Nothing is mocked: the manifest is read by the production resolver, the
## repositories are real, and `repro` is the built `./build/bin/repro`.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
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

const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

type SiblingFixture* = object
  gitBin*, repro*, scratch*, ws*, app*: string
  origins*: seq[(string, string)]
  appDepends*: seq[string]

proc git*(fx: SiblingFixture; repo, args: string): string =
  requireCmd(q(fx.gitBin) & " -C " & q(repo) & " " & args)

proc headOf*(fx: SiblingFixture; repo: string): string =
  fx.git(repo, "rev-parse HEAD").strip()

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

proc setAppDepends*(fx: var SiblingFixture; depends: seq[string]) =
  fx.appDepends = depends
  writeFile(fx.ws / "repos" / "app.toml", fragment("app", depends))

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
    if name == "app":
      writeFile(work / "repro.solver", solverInputs)
      writeFile(work / ".gitignore", ".repro/\n")
    discard result.git(work, "add -A")
    discard result.git(work, "commit -q -m seed")
    discard result.git(work, "push -q origin main")
    result.origins.add((name, origin))
  result.app = result.ws / "app"
  createDir(result.ws / "projects")
  createDir(result.ws / "repos")
  var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n"
  for (name, origin) in result.origins:
    project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
      fileUrl(origin) & "\"\n\n")
  project.add("includes = [\n  \"repos/app.toml\",\n" &
    "  \"repos/lib-b.toml\",\n  \"repos/lib-c.toml\",\n" &
    "  \"repos/lib-d.toml\",\n]\n")
  writeFile(result.ws / "projects" / "app.toml", project)
  result.setAppDepends(@["lib-b"])
  writeFile(result.ws / "repos" / "lib-b.toml", fragment("lib-b", @["lib-c"]))
  writeFile(result.ws / "repos" / "lib-c.toml", fragment("lib-c", @[]))
  writeFile(result.ws / "repos" / "lib-d.toml", fragment("lib-d", @[]))
  writeWorkspaceBranch(result.ws, project = "app", branch = "main")

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

proc depEntry*(lockBody, path: string): string =
  ## The inline table of the `deps` entry whose `path` is `path`, or "".
  let key = "path = \"" & path & "\""
  let at = lockBody.find(key)
  if at < 0: return ""
  let open = lockBody.rfind('{', 0, at)
  let close = lockBody.find('}', at)
  if open < 0 or close < 0: return ""
  lockBody[open .. close]

proc linePrefixed*(body, prefix: string): string =
  for line in body.splitLines():
    if line.startsWith(prefix): return line
  ""

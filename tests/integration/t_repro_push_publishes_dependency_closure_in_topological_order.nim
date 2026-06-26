## RA-25 — `repro push` publishes the pushed repo's develop-mode dependency
## closure in TOPOLOGICAL (dependency-first) order, never a dependent before
## its dependency, and publishes the workspace lock for the resulting state.
##
## Topology (a 3-node chain so the toposort is non-trivial):
##
##   app  depends = ["lib"]
##   lib  depends = ["core"]
##   core (no edge)
##
## So app's closure is {app, lib, core}, and the only valid push order that
## never publishes a dependent before its dependency is core → lib → app.
## ``other`` is an UNRELATED repo (not in app's closure) and must NOT be
## pushed.
##
## All four repos start published, then each closure member (app, lib, core)
## gets an UNPUBLISHED local commit. ``repro push`` (from app) must:
##   - push core, then lib, then app (the assertion: core BEFORE lib BEFORE
##     app — a dependent is never published before its dependency);
##   - leave each bare upstream containing the local commit (both bares now
##     have the pushed work);
##   - NOT push ``other`` (out of closure);
##   - publish the workspace lock (the lock subtree lands in the manifest
##     bare).
##
## Falsifiable: break the toposort (e.g. push in declaration / reverse order)
## and the order assertion fails because a dependent would publish before its
## dependency. The order is read from the structured ``push-report.json``
## (the ``order`` array) AND independently corroborated by the per-bare commit
## presence (every closure bare advanced; ``other`` did not).
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos; no network.
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tables, tempfiles, unittest]

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

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA25 Tester\"")
  writeFile(workPath / "README.md", "RA25 topo fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA25 Tester\"")

proc commitLocal(gitBin, repoPath, message: string): string =
  ## Commit WITHOUT pushing — the new HEAD is unpublished.
  writeFile(repoPath / "local.txt", message & "\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add local.txt")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " commit -m " & q(message))
  result = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " rev-parse HEAD").strip()

proc projectToml(appUrl, libUrl, coreUrl, otherUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"app\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"app-origin\"\nfetch = \"" & appUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
    "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
    "[[remote]]\nname = \"other-origin\"\nfetch = \"" & otherUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/app.toml\",\n" &
    "  \"repos/lib.toml\",\n" &
    "  \"repos/core.toml\",\n" &
    "  \"repos/other.toml\",\n" &
    "]\n"

# app → lib → core chain; other is unrelated. Declaration order in the
# manifest is deliberately NOT the topological order (app is declared first),
# so a naive "push in declaration order" would publish app before lib/core
# and fail the order assertion.
const appFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "app"
path = "app"
remote = "app-origin"
revision = "main"
depends = ["lib"]
"""

const libFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib"
path = "lib"
remote = "lib-origin"
revision = "main"
depends = ["core"]
"""

const coreFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "core"
path = "core"
remote = "core-origin"
revision = "main"
"""

const otherFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "other"
path = "other"
remote = "other-origin"
revision = "main"
"""

type
  RepoSeed = object
    origin: string
    sha: string

  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    manifestsRoot: string
    manifestBare: string
    app: RepoSeed
    lib: RepoSeed
    core: RepoSeed
    other: RepoSeed

proc seedManifestGitLayer(gitBin, manifestsRoot, bare: string; branch = "main") =
  ## Make ``.repo/manifests`` a real git checkout tracking a bare upstream so
  ## ``repro push`` genuinely publishes the lock to it.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(bare))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(manifestsRoot))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " config user.name \"RA25 Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add projects repos")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " commit -m \"seed manifest\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " push -u origin " & branch)

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra25-topo-" & slug & "-", "")
  result.reproBin = reproBinary()

  result.app.origin = result.scratch / "origin-app.git"
  result.app.sha = seedGitOrigin(gitBin, result.app.origin,
    result.scratch / "seed-app")
  result.lib.origin = result.scratch / "origin-lib.git"
  result.lib.sha = seedGitOrigin(gitBin, result.lib.origin,
    result.scratch / "seed-lib")
  result.core.origin = result.scratch / "origin-core.git"
  result.core.sha = seedGitOrigin(gitBin, result.core.origin,
    result.scratch / "seed-core")
  result.other.origin = result.scratch / "origin-other.git"
  result.other.sha = seedGitOrigin(gitBin, result.other.origin,
    result.scratch / "seed-other")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "app.toml",
    projectToml(fileUrl(result.app.origin), fileUrl(result.lib.origin),
      fileUrl(result.core.origin), fileUrl(result.other.origin)))
  writeFile(manifestsRoot / "repos" / "app.toml", appFragment)
  writeFile(manifestsRoot / "repos" / "lib.toml", libFragment)
  writeFile(manifestsRoot / "repos" / "core.toml", coreFragment)
  writeFile(manifestsRoot / "repos" / "other.toml", otherFragment)
  result.manifestsRoot = manifestsRoot
  result.manifestBare = result.scratch / "manifest.git"
  seedManifestGitLayer(gitBin, manifestsRoot, result.manifestBare)

  cloneInto(gitBin, result.app.origin, workspaceRoot / "app")
  cloneInto(gitBin, result.lib.origin, workspaceRoot / "lib")
  cloneInto(gitBin, result.core.origin, workspaceRoot / "core")
  cloneInto(gitBin, result.other.origin, workspaceRoot / "other")
  result.workspaceRoot = workspaceRoot
  writeWorkspaceBranch(workspaceRoot, project = "app", branch = "main")

proc invokePush(fx: Fixture; fromProject = false): CmdResult =
  var argv = @[fx.reproBin, "push"]
  if fromProject:
    argv.add("app")
  argv.add("--no-certify")
  argv.add("--workspace-root=" & fx.workspaceRoot)
  argv.add("--current-repo=" & (fx.workspaceRoot / "app"))
  argv.add("--json")
  runShell(shellCommand(argv))

proc readReport(fx: Fixture): JsonNode =
  let p = fx.workspaceRoot / ".repro" / "workspace" / "push-report.json"
  check fileExists(p)
  parseFile(p)

proc bareHasLocal(gitBin, bare: string): bool =
  ## True iff the bare upstream's main branch contains the unpushed
  ## ``local.txt`` file — i.e. the local commit was published.
  let ls = runCmd(q(gitBin) & " -C " & q(bare) &
    " ls-tree -r --name-only refs/heads/main")
  ls.code == 0 and ls.output.contains("local.txt")

proc indexOf(arr: JsonNode; name: string): int =
  result = -1
  for i in 0 ..< arr.len:
    if arr[i].getStr() == name:
      return i

suite "RA-25 — repro push: closure published in topological order":

  test "t_repro_push_publishes_dependency_closure_in_topological_order":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "main")
      defer: removeDir(fx.scratch)

      # Give each CLOSURE member an unpublished local commit; ``other`` stays
      # published (untouched) so we can assert it is NOT pushed.
      discard commitLocal(gitBin, fx.workspaceRoot / "app", "app work")
      discard commitLocal(gitBin, fx.workspaceRoot / "lib", "lib work")
      discard commitLocal(gitBin, fx.workspaceRoot / "core", "core work")

      let res = invokePush(fx)
      checkpoint("push output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0

      # ---- Closure + topological order ----------------------------------
      let closure = report["closure"]
      var closureNames: seq[string]
      for n in closure: closureNames.add(n.getStr())
      check "app" in closureNames
      check "lib" in closureNames
      check "core" in closureNames
      # ``other`` is OUT of the closure.
      check "other" notin closureNames

      let order = report["order"]
      let iCore = indexOf(order, "core")
      let iLib = indexOf(order, "lib")
      let iApp = indexOf(order, "app")
      check iCore >= 0
      check iLib >= 0
      check iApp >= 0
      # THE core property: a dependent is never published before its
      # dependency. core (dep of lib) before lib; lib (dep of app) before app.
      # Falsifiable: a broken toposort (declaration / reverse order) puts app
      # first and fails here.
      check iCore < iLib
      check iLib < iApp
      # ``other`` is never in the push order.
      check indexOf(order, "other") == -1

      # ---- Per-repo outcomes: all three closure members PUSHED -----------
      var outcomeByName: Table[string, string]
      for entry in report["repos"]:
        outcomeByName[entry["name"].getStr()] = entry["outcome"].getStr()
      check outcomeByName["core"] == "pushed"
      check outcomeByName["lib"] == "pushed"
      check outcomeByName["app"] == "pushed"
      check "other" notin outcomeByName

      # ---- Both bares now contain the local commits ----------------------
      check bareHasLocal(gitBin, fx.app.origin)
      check bareHasLocal(gitBin, fx.lib.origin)
      check bareHasLocal(gitBin, fx.core.origin)
      # ``other``'s bare must NOT have advanced (no local commit was made and
      # it was never pushed).
      check not bareHasLocal(gitBin, fx.other.origin)

      # ---- The workspace lock was published to the manifest bare ---------
      check report["lockPublished"].getBool()
      let ls = runCmd(q(gitBin) & " -C " & q(fx.manifestBare) &
        " ls-tree -r --name-only refs/heads/main")
      check ls.code == 0
      check ls.output.contains("locks/app/")

  test "t_repro_push_named_project_publishes_same_closure":
    # ``repro push <project>`` resolves the same closure as the no-arg form.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "named")
      defer: removeDir(fx.scratch)
      discard commitLocal(gitBin, fx.workspaceRoot / "app", "app work")
      discard commitLocal(gitBin, fx.workspaceRoot / "lib", "lib work")
      discard commitLocal(gitBin, fx.workspaceRoot / "core", "core work")

      let res = invokePush(fx, fromProject = true)
      checkpoint("named push output: " & res.output)
      check res.code == 0
      let report = readReport(fx)
      let order = report["order"]
      check indexOf(order, "core") < indexOf(order, "lib")
      check indexOf(order, "lib") < indexOf(order, "app")
      check indexOf(order, "other") == -1
      check bareHasLocal(gitBin, fx.core.origin)
      check not bareHasLocal(gitBin, fx.other.origin)

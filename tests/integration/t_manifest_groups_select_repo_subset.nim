## RA-18 — manifest groups select a repo subset on sync.
##
## Three repos with different group membership:
##   * ``lib-core``  — no ``groups`` declared  → implicit ``default`` group.
##   * ``lib-tools`` — ``groups = ["tools"]``  → ``tools`` only (NOT default).
##   * ``lib-heavy`` — ``groups = ["heavy"]``  → ``heavy`` only.
##
## ``repro workspace sync`` filters the repo set by ``--groups`` (include)
## and ``-<group>`` (exclude). The sync report's ``repos`` array lists
## exactly the SELECTED repos, so it is the observable for subset selection.
##
## Cases (hermetic — local bare upstreams, no network):
##   1. No ``--groups``               → all three repos selected.
##   2. ``--groups=default``          → only the no-groups repo (implicit
##                                      default). Proves a no-groups repo IS
##                                      in ``default`` and a grouped repo is
##                                      NOT.
##   3. ``--groups=tools``            → only ``lib-tools``.
##   4. ``--groups=default,tools``    → ``lib-core`` + ``lib-tools``.
##   5. ``--groups=-heavy``           → all but ``lib-heavy`` (exclude).
##
## Falsifiability: each case asserts the EXACT selected path set, so a
## filter that selected too many (e.g. ignored ``--groups``) or too few
## (e.g. dropped the implicit ``default``) fails the set equality. The
## negative members are checked explicitly (``notin``).
##
## Skip rule: only when ``git`` is missing from PATH.

import std/[json, os, osproc, sets, strutils, tempfiles, unittest]

import repro_test_support

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
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA-18 Tester\"")
  writeFile(workPath / "README.md", "ra18-groups\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

# ---- manifest TOML --------------------------------------------------------

proc projectToml(coreUrl, toolsUrl, heavyUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"myproject\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "[[remote]]\nname = \"tools-origin\"\nfetch = \"" & toolsUrl & "\"\n\n" &
  "[[remote]]\nname = \"heavy-origin\"\nfetch = \"" & heavyUrl & "\"\n\n" &
  "includes = [\n" &
  "  \"repos/lib-core.toml\",\n" &
  "  \"repos/lib-tools.toml\",\n" &
  "  \"repos/lib-heavy.toml\",\n" &
  "]\n"

const coreFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-core"
path = "lib-core"
remote = "core-origin"
revision = "main"
"""

const toolsFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-tools"
path = "lib-tools"
remote = "tools-origin"
revision = "main"
groups = ["tools"]
"""

const heavyFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-heavy"
path = "lib-heavy"
remote = "heavy-origin"
revision = "main"
groups = ["heavy"]
"""

# ---- fixture --------------------------------------------------------------

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-ra18-groups-", "")
  result.reproBin = reproBinary()
  let coreOrigin = result.scratch / "origin-core.git"
  let toolsOrigin = result.scratch / "origin-tools.git"
  let heavyOrigin = result.scratch / "origin-heavy.git"
  discard seedGitOrigin(gitBin, coreOrigin, result.scratch / "seed-core")
  discard seedGitOrigin(gitBin, toolsOrigin, result.scratch / "seed-tools")
  discard seedGitOrigin(gitBin, heavyOrigin, result.scratch / "seed-heavy")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectToml(fileUrl(coreOrigin), fileUrl(toolsOrigin), fileUrl(heavyOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-core.toml", coreFragment)
  writeFile(manifestsRoot / "repos" / "lib-tools.toml", toolsFragment)
  writeFile(manifestsRoot / "repos" / "lib-heavy.toml", heavyFragment)
  result.workspaceRoot = workspaceRoot

proc syncPaths(fx: Fixture; groupsArg: string): HashSet[string] =
  ## Run sync (optionally with a ``--groups=...`` flag) and return the set
  ## of repo paths the report classified — i.e. the selected subset.
  var argv = @[fx.reproBin, "workspace", "sync", "myproject",
    "--workspace-root=" & fx.workspaceRoot]
  if groupsArg.len > 0:
    argv.add("--groups=" & groupsArg)
  let res = runShell(shellCommand(argv))
  if res.code notin {0, 2}:
    checkpoint("sync output: " & res.output)
  let report = parseFile(fx.workspaceRoot / ".repro" / "workspace" /
    "sync-report.json")
  result = initHashSet[string]()
  for entry in report["repos"]:
    result.incl(entry["path"].getStr())

suite "RA-18 — manifest groups subset selection":

  test "groups select the expected repo subset on sync":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)

      # init first so every repo has a working tree (clones are not subject
      # to the group filter; the filter is a sync-time selection).
      let initRes = runShell(shellCommand(@[
        fx.reproBin, "workspace", "init", "myproject",
        "--workspace-root=" & fx.workspaceRoot]))
      if initRes.code != 0:
        checkpoint("init output: " & initRes.output)
      check initRes.code == 0

      # Case 1: no --groups → all three.
      let all = syncPaths(fx, "")
      check all == ["lib-core", "lib-tools", "lib-heavy"].toHashSet

      # Case 2: --groups=default → only the no-groups repo (implicit default).
      let onlyDefault = syncPaths(fx, "default")
      check onlyDefault == ["lib-core"].toHashSet
      check "lib-tools" notin onlyDefault
      check "lib-heavy" notin onlyDefault

      # Case 3: --groups=tools → only lib-tools.
      let onlyTools = syncPaths(fx, "tools")
      check onlyTools == ["lib-tools"].toHashSet
      check "lib-core" notin onlyTools

      # Case 4: --groups=default,tools → lib-core + lib-tools.
      let defaultAndTools = syncPaths(fx, "default,tools")
      check defaultAndTools == ["lib-core", "lib-tools"].toHashSet
      check "lib-heavy" notin defaultAndTools

      # Case 5: --groups=-heavy → exclude lib-heavy, keep the rest.
      let exceptHeavy = syncPaths(fx, "-heavy")
      check exceptHeavy == ["lib-core", "lib-tools"].toHashSet
      check "lib-heavy" notin exceptHeavy

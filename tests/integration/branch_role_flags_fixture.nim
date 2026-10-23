## Shared fixture for the branch-role flag tests of `repro sync --to`,
## `repro switch --to` and `repro branch --from` (Workspace-Branch-Roles.md
## §4.1, §4.2, §4.4 and the required tests of §9).
##
## Deliberately not a ``t_*.nim`` file, so the suite generator never compiles
## it as a test of its own.
##
## A real workspace whose ROOT is a git clone of a bare "origin" (so
## `repro branch` can fork it) and whose two members are real clones of real
## bare remotes, all behind ``file://`` URLs:
##
##   <scratch>/
##     remotes/core     branches main, agents (unless `withAgents = false`),
##                      release
##     remotes/docs     branch latest
##     origin-root.git  the root repository, branch main
##     ws/              a clone of origin-root.git — the workspace
##       repro-workspace.toml   settings.v1: the root's `[workspace] mainline`,
##                              a `product` profile (main / agents / release),
##                              a `spec` profile (latest) and a custom role
##                              `partner` falling back to `staging`
##       projects/demo.toml     member_repos = core, docs
##       repos/core.toml        repo.v2, profile = "product"
##       repos/docs.toml        repo.v2, profile = "spec"
##       core/, docs/           member clones, each on `feature/x` cut from
##                              its mainline's FIRST commit
##
## After the clones, every remote branch moves on by one commit, so a role
## sync has something to fast-forward and the role branches differ from the
## feature branch. The roles each repo resolves to:
##
##   | role       | core                 | docs                       |
##   |------------|----------------------|----------------------------|
##   | mainline   | main                 | latest                     |
##   | unstable   | agents (declared)    | latest (unstable→mainline) |
##   | staging    | main (→ mainline)    | latest (→ mainline)        |
##   | stable     | release (declared)   | latest (→ mainline)        |
##   | production | release (→ stable)   | latest (→ stable→mainline) |
##   | lts        | release (→ stable)   | latest (→ stable→mainline) |
##   | partner    | main (→ staging→ml)  | latest (→ staging→ml)      |
##
## Nothing is mocked: the real `repro` binary runs as a subprocess against
## real repositories and the real filesystem.

import std/[os, osproc, streams, strtabs, strutils, tempfiles]

import repro_test_support

proc q*(value: string): string = quoteShell(value)

proc roleFlagsReproBinary*(): string =
  ## `repro` is a build-graph artifact (`reprobuild.apps.repro`); drive the
  ## built one rather than compiling the CLI at test time.
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

type
  RoleRun* = tuple[code: int; stdout, stderr: string]

  RoleWorkspace* = object
    scratch*: string
    remotes*: string
    rootOrigin*: string
    root*: string
    gitBin*: string
    featureBase*: seq[(string, string)]
      ## (repo, sha) — where each member's `feature/x` was cut, so a test can
      ## put a checkout back exactly where the fixture left it.

proc requireOk*(command: string): string {.discardable.} =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    raise newException(OSError, "command failed: " & command & "\n" &
      res.output)
  res.output

proc gitIn*(ws: RoleWorkspace; repo: string; args: string): string =
  ## `git -C <repo> <args>`, stdout stripped; raises on failure.
  requireOk(q(ws.gitBin) & " -C " & q(repo) & " " & args).strip()

proc gitIdentity(gitBin, path: string) =
  requireOk(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  requireOk(q(gitBin) & " -C " & q(path) & " config user.name Tester")

proc seedBare(gitBin, scratch, barePath: string;
              branches: openArray[string]) =
  ## A bare repository with one commit, published on every name in
  ## `branches` (the first is the initial branch). The seed work tree stays
  ## at `<scratch>/seed-<name>` so `advanceRemote` can move a branch later.
  let work = scratch / ("seed-" & extractFilename(barePath))
  requireOk(q(gitBin) & " init -q -b " & branches[0] & " " & q(work))
  gitIdentity(gitBin, work)
  writeFile(work / "README", extractFilename(barePath) & "\n")
  requireOk(q(gitBin) & " -C " & q(work) & " add -A")
  requireOk(q(gitBin) & " -C " & q(work) & " commit -q -m fixture")
  for b in branches[1 .. ^1]:
    requireOk(q(gitBin) & " -C " & q(work) & " branch " & b)
  requireOk(q(gitBin) & " clone -q --bare " & q(work) & " " & q(barePath))
  for b in branches[1 .. ^1]:
    requireOk(q(gitBin) & " -C " & q(work) & " push -q " & q(barePath) &
      " " & b)

proc advanceRemote*(ws: RoleWorkspace; name, branch: string): string =
  ## Land one commit on `branch` of remote `name` (as a teammate would) and
  ## return the new tip.
  let work = ws.scratch / ("seed-" & name)
  requireOk(q(ws.gitBin) & " -C " & q(work) & " switch -q " & branch)
  writeFile(work / ("moved-" & branch.replace('/', '-')), branch & "\n")
  requireOk(q(ws.gitBin) & " -C " & q(work) & " add -A")
  requireOk(q(ws.gitBin) & " -C " & q(work) & " commit -q -m " &
    q(branch & " moves on"))
  requireOk(q(ws.gitBin) & " -C " & q(work) & " push -q " &
    q(ws.remotes / name) & " " & branch)
  requireOk(q(ws.gitBin) & " -C " & q(work) & " rev-parse HEAD").strip()

const
  settingsToml = "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
    "[workspace]\nmainline = \"main\"\n\n" &
    "[profiles.product]\nmainline = \"main\"\nunstable = \"agents\"\n" &
    "stable = \"release\"\n\n" &
    "[profiles.spec]\nmainline = \"latest\"\n\n" &
    "[branch-roles.partner]\nfallback = \"staging\"\n"

proc fragmentToml(name, keys: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nurl_prefix = \"acme\"\n" & keys & "\n"

proc setupRoleWorkspace*(slug: string; withAgents = true): RoleWorkspace =
  ## The workspace described in the module comment. With `withAgents =
  ## false`, `core`'s remote has NO `agents` branch although its profile
  ## declares `unstable = "agents"` — the case a declared role must refuse
  ## rather than fall back on (§2.2).
  result.gitBin = findExe("git")
  result.scratch = createTempDir("repro-role-flags-" & slug & "-", "")
  result.remotes = result.scratch / "remotes"
  createDir(result.remotes)
  let gitBin = result.gitBin
  if withAgents:
    seedBare(gitBin, result.scratch, result.remotes / "core",
      ["main", "agents", "release"])
  else:
    seedBare(gitBin, result.scratch, result.remotes / "core",
      ["main", "release"])
  seedBare(gitBin, result.scratch, result.remotes / "docs", ["latest"])

  # The root repository: committed manifests and settings, published on
  # `main` of a bare origin, and cloned — the shape `repro workspace init`
  # produces, which is what `repro branch` forks from.
  let rootSeed = result.scratch / "seed-root"
  requireOk(q(gitBin) & " init -q -b main " & q(rootSeed))
  gitIdentity(gitBin, rootSeed)
  for d in ["projects", "repos", "url-prefixes"]:
    createDir(rootSeed / d)
  writeFile(rootSeed / "repro-workspace.toml", settingsToml)
  writeFile(rootSeed / ".gitignore", "/.repro/\n/core/\n/docs/\n")
  writeFile(rootSeed / "projects" / "demo.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "member_repos = [\"core\", \"docs\"]\n\n" &
    "[project]\nname = \"demo\"\n")
  writeFile(rootSeed / "url-prefixes" / "acme.toml",
    "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n[url-prefix]\n" &
    "name = \"acme\"\nurl = \"" & fileUrl(result.remotes) & "\"\n")
  writeFile(rootSeed / "repos" / "core.toml",
    fragmentToml("core", "profile = \"product\""))
  writeFile(rootSeed / "repos" / "docs.toml",
    fragmentToml("docs", "profile = \"spec\""))
  requireOk(q(gitBin) & " -C " & q(rootSeed) & " add -A")
  requireOk(q(gitBin) & " -C " & q(rootSeed) & " commit -q -m workspace")
  result.rootOrigin = result.scratch / "origin-root.git"
  requireOk(q(gitBin) & " clone -q --bare " & q(rootSeed) & " " &
    q(result.rootOrigin))

  result.root = result.scratch / "ws"
  requireOk(q(gitBin) & " clone -q " & q(fileUrl(result.rootOrigin)) & " " &
    q(result.root))
  gitIdentity(gitBin, result.root)
  createDir(result.root / ".repro")
  writeFile(result.root / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"demo\"\nprojects = [\"demo\"]\n")

  for (name, mainline) in [("core", "main"), ("docs", "latest")]:
    let checkout = result.root / name
    requireOk(q(gitBin) & " clone -q --branch " & mainline & " " &
      q(fileUrl(result.remotes / name)) & " " & q(checkout))
    gitIdentity(gitBin, checkout)
    requireOk(q(gitBin) & " -C " & q(checkout) & " switch -q -c feature/x")
    result.featureBase.add((name, requireOk(q(gitBin) & " -C " &
      q(checkout) & " rev-parse HEAD").strip()))

  # Every remote branch moves on, AFTER the clones.
  discard result.advanceRemote("core", "main")
  if withAgents:
    discard result.advanceRemote("core", "agents")
  discard result.advanceRemote("core", "release")
  discard result.advanceRemote("docs", "latest")

proc runRepro*(ws: RoleWorkspace; args: openArray[string];
               cwd = ""): RoleRun =
  ## The real binary's exit code, stdout and stderr, read separately (a report
  ## is compared byte for byte, and progress lines go to stderr). The
  ## fixture's settings file must be found by discovery, not through an
  ## inherited `REPRO_WORKSPACE_CONFIG` pointing elsewhere.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env.del("REPRO_WORKSPACE_CONFIG")
  let p = startProcess(roleFlagsReproBinary(), args = @args, env = env,
    workingDir = (if cwd.len > 0: cwd else: ws.root), options = {})
  # Drain both pipes concurrently enough for these small outputs: stderr is
  # read after stdout, and neither grows past a pipe buffer here.
  let o = p.outputStream.readAll()
  let e = p.errorStream.readAll()
  result = (code: p.waitForExit(), stdout: o, stderr: e)
  p.close()

proc resetFeatureBranches*(ws: RoleWorkspace) =
  ## Put every member back where the fixture left it: on `feature/x` at its
  ## original commit, with no local branch other than `feature/x`. Remote-
  ## tracking refs are left as they are; every run refetches them.
  for (name, sha) in ws.featureBase:
    let checkout = ws.root / name
    discard ws.gitIn(checkout, "switch -q --force feature/x")
    discard ws.gitIn(checkout, "reset -q --hard " & sha)
    for b in ws.gitIn(checkout,
        "for-each-ref " & q("--format=%(refname:short)") &
        " refs/heads").splitLines():
      let branch = b.strip()
      if branch.len > 0 and branch != "feature/x":
        discard ws.gitIn(checkout, "branch -q -D " & q(branch))

proc fetchHeadPresent*(ws: RoleWorkspace; name: string): bool =
  ## Whether any fetch ever ran in member `name` (a fetch leaves FETCH_HEAD).
  fileExists(ws.root / name / ".git" / "FETCH_HEAD")

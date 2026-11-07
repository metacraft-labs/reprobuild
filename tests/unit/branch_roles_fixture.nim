## Shared fixture for the branch-role resolution tests
## (Workspace-Branch-Roles.md §2–§3, §9).
##
## A real workspace root on the real filesystem: `projects/demo.toml`, one
## `repos/<name>.toml` per repo, and — when a test writes one — the shared
## settings file `repro-workspace.toml` beside them. Resolution goes through
## the real reader, the real settings reader and the real resolver, which
## discovers the settings file the same way a command does (the nearest one at
## or above the manifest root). No mocks.
##
## Every repo resolves its URL through a `file://` prefix that points at a
## directory which does NOT exist. Resolution must never consult the remote
## (§2.2, §7 "No remote probing"); a resolver that tried would fail on every
## fixture here, so every passing resolution is also evidence of that.
##
## Not a test itself: the file name does not start with `t_`, so suite
## discovery does not pick it up.

import std/[options, os, strutils, tempfiles]

import repro_workspace_manifests

export options

type
  RolesFixture* = object
    root*: string
    repos*: seq[string]

const unreachableRemotes* = "file:///nonexistent/reprobuild-role-tests/remotes"
  ## Where every fixture repo's URL points. Nothing exists there.

proc newRolesFixture*(prefix: string): RolesFixture =
  ## A fresh workspace root under the system temp dir. The inherited
  ## `REPRO_WORKSPACE_CONFIG` is cleared so the fixture's own settings file
  ## (or its absence) is what discovery finds.
  delEnv("REPRO_WORKSPACE_CONFIG")
  result.root = createTempDir(prefix, "")
  createDir(result.root / "projects")
  createDir(result.root / "repos")
  createDir(result.root / "url-prefixes")
  writeFile(result.root / "url-prefixes" / "acme.toml",
    "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n[url-prefix]\n" &
    "name = \"acme\"\nurl = \"" & unreachableRemotes & "\"\n")

proc dispose*(fx: RolesFixture) =
  removeDir(fx.root)

proc settingsPath*(fx: RolesFixture): string =
  fx.root / "repro-workspace.toml"

proc writeSettings*(fx: RolesFixture; body: string) =
  ## `repro-workspace.toml` (settings.v1) with `body` after the schema line.
  writeFile(fx.settingsPath, "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
    body)

proc fragmentPath*(fx: RolesFixture; name: string): string =
  fx.root / "repos" / (name & ".toml")

proc addRepo*(fx: var RolesFixture; name, repoKeys: string;
              extraTables = "") =
  ## A `repo.v2` fragment for `name`. `repoKeys` are extra `[repo]` lines
  ## (`mainline = "dev"`, `profile = "product"`, `unstable = false` …);
  ## `extraTables` is appended after `[repo]` (a `[repo.branch-roles]`).
  writeFile(fx.fragmentPath(name),
    "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nurl_prefix = \"acme\"\n" & repoKeys &
    (if repoKeys.len > 0 and not repoKeys.endsWith("\n"): "\n" else: "") &
    extraTables)
  if name notin fx.repos:
    fx.repos.add(name)

proc projectFile*(fx: RolesFixture): string =
  ## Writes `projects/demo.toml` naming every repo added so far, and returns
  ## its path.
  result = fx.root / "projects" / "demo.toml"
  var members: seq[string]
  for r in fx.repos:
    members.add("\"" & r & "\"")
  writeFile(result, "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "member_repos = [" & members.join(", ") & "]\n\n[project]\n" &
    "name = \"demo\"\n")

proc resolveDemo*(fx: RolesFixture): ResolvedProject =
  ## Resolve the project exactly as a command does: the real resolver,
  ## discovering the settings file from the manifest root.
  resolveProject(fx.projectFile)

proc repo*(project: ResolvedProject; name: string): ResolvedRepo =
  for r in project.repos:
    if r.name == name:
      return r
  raise newException(KeyError, "no resolved repo named '" & name & "'")

proc role*(repo: ResolvedRepo; name: string): ResolvedRole =
  let found = findRole(repo.roles, name)
  if found.isNone:
    raise newException(KeyError, "repo '" & repo.name & "' resolved no role '" &
      name & "'")
  found.get()

proc refusal*(body: proc ()): ref WorkspaceManifestParseError =
  ## The diagnostic `body` raises, or nil when it raises none.
  try:
    body()
  except WorkspaceManifestParseError as e:
    return e
  nil

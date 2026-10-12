## Every old spelling is still read, means exactly what its new spelling
## means, and is never written.
##
## Workspace-Settings-Files.md §8 step 1 and Workspace-Branch-Roles.md §6 step
## 1: before any workspace renames a file or rewrites a fragment, a `repro`
## must ship that reads BOTH spellings and writes only the new ones, and be
## pinned everywhere. Each fallback below is checked the same way — the old
## spelling and the new spelling of the same content resolve to the same
## value — and then a write after reading the old spelling is checked to
## produce the new name:
##
## * the settings file: `.repro-workspace.toml` (`bootstrap.v1`) vs
##   `repro-workspace.toml` (`settings.v1`), including discovery and the
##   new name winning when both exist;
## * the old file's `.repro-workspace-private.toml` companion, which must
##   still supply `[manifest] private_url`;
## * the state file: `.repro/workspace.toml` (`local.v1`) vs
##   `.repro/workspace-state.toml` (`state.v1`) — a write after reading the
##   old file creates the new file and leaves the old one byte-identical;
## * the fragment: `repo.v1` `branch` vs `repo.v2` `mainline`.
##
## Each fallback is its own test case, so removing one fails the case that
## names it. The settings and state fallbacks are also driven through the
## real `repro` binary (`workspace enable --default` reads the settings
## file's default projects and writes the state file; `projects list
## --enabled` reads the state file), so a CLI site that bypassed the shared
## discovery would fail here too.
##
## No mocks: real files in temporary directories, the real reader, writer
## and binary. The fixtures are hermetic — no network, no clone: `enable` of a
## project with no repos only reads manifests and writes the state file.

import std/[options, os, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const newSettings = """schema = "reprobuild.workspace.settings.v1"

[projects]
default = ["beta"]
default_template = "standard"

[records]
url = "https://git.example.invalid/acme/records.git"
branch = "latest"
publish_locks = true

[develop]
org_urls = ["https://git.example.invalid/acme/"]

[locking]
route = [{ visibility = "team", backend = "git-checkout", path = ".repro/records" }]

[foreign_env]
auto_load_flake = true
"""

const oldSettings = """schema = "reprobuild.workspace.bootstrap.v1"

[manifest]
url = "https://git.example.invalid/acme/records.git"
branch = "latest"
publish_locks = true

[projects]
default = ["beta"]
default_template = "standard"

[develop]
org_urls = ["https://git.example.invalid/acme/"]

[locking]
route = [{ visibility = "team", backend = "git-checkout", path = ".repro/records" }]

[foreign_env]
auto_load_flake = true
"""

const oldPrivateCompanion = """schema = "reprobuild.workspace.bootstrap.v1"

[manifest]
private_url = "git@git.example.invalid:acme/internal-manifests"
"""

const oldState = """schema = "reprobuild.workspace.local.v1"

# Written by an older repro.
[workspace]
project = "alpha"
projects = ["alpha", "gamma"]
branch = "feature/x"
feature_started = true
"""

const newState = """schema = "reprobuild.workspace.state.v1"

[workspace]
project = "alpha"
projects = ["alpha", "gamma"]
branch = "feature/x"
feature_started = true
"""

proc projectStub(name: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n[project]\nname = \"" &
    name & "\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n" &
    "includes = [\n]\n"

proc workspaceWith(scratch, name: string): string =
  ## A workspace root whose own `projects/` declares alpha, beta and gamma.
  result = scratch / name
  createDir(result / "projects")
  for p in ["alpha", "beta", "gamma"]:
    writeFile(result / "projects" / (p & ".toml"), projectStub(p))

proc repro(args: openArray[string]): CmdResult =
  ## The binary with no inherited settings override, so discovery is what is
  ## tested.
  runShell(shellCommand(@[reproBinary()] & @args,
    [("REPRO_WORKSPACE_CONFIG", ""), ("REPRO_DEFAULT_PROJECTS", "")]))

proc enabledSet(root: string): seq[string] =
  let res = repro(["workspace", "projects", "list", "--enabled",
    "--workspace-root=" & root])
  if res.code != 0:
    checkpoint(res.output)
  check res.code == 0
  for line in res.output.splitLines():
    if line.strip().len > 0:
      result.add(line.strip().split('\t')[0])

proc sameSettings(a, b: WorkspaceSettings) =
  check a.projects == b.projects
  check a.records == b.records
  check a.develop == b.develop
  check a.locking == b.locking
  check a.foreign_env == b.foreign_env
  check a.verify == b.verify

suite "old names are read until retired":

  setup:
    putEnv("REPRO_WORKSPACE_CONFIG", "")

  test "fallback: the settings file's old name resolves like the new one":
    let scratch = createTempDir("repro-old-names-settings-", "")
    defer: removeDir(scratch)
    let fresh = workspaceWith(scratch, "fresh")
    let legacy = workspaceWith(scratch, "legacy")
    writeFile(fresh / "repro-workspace.toml", newSettings)
    writeFile(legacy / ".repro-workspace.toml", oldSettings)

    check findWorkspaceSettingsPath(fresh) == fresh / "repro-workspace.toml"
    check findWorkspaceSettingsPath(legacy) == legacy / ".repro-workspace.toml"
    # Discovery walks up from a subdirectory for both names.
    createDir(legacy / "sub" / "dir")
    check findWorkspaceSettingsPath(legacy / "sub" / "dir") ==
      legacy / ".repro-workspace.toml"

    let s = readWorkspaceSettings(findWorkspaceSettingsPath(fresh))
    let o = readWorkspaceSettings(findWorkspaceSettingsPath(legacy))
    check s.schema == schemaWorkspaceSettingsV1
    check o.schema == schemaWorkspaceBootstrapV1
    sameSettings(s, o)
    # The old `[manifest] branch` is also what the root mainline was read from.
    check o.rootMainline == some("latest")

    # Both in one directory: the new name wins.
    writeFile(legacy / "repro-workspace.toml",
      newSettings.replace("\"beta\"", "\"gamma\""))
    check findWorkspaceSettingsPath(legacy) == legacy / "repro-workspace.toml"
    check readWorkspaceSettings(findWorkspaceSettingsPath(legacy)).projects.default ==
      @["gamma"]
    removeFile(legacy / "repro-workspace.toml")

    # Through the binary: `enable --default` takes the default set from
    # either file and records it in the NEW state file.
    for root in [fresh, legacy]:
      let res = repro(["workspace", "enable", "--default",
        "--workspace-root=" & root])
      if res.code != 0:
        checkpoint(root & ": " & res.output)
      check res.code == 0
      check enabledSet(root) == @["beta"]
      check fileExists(root / ".repro" / "workspace-state.toml")
      check not fileExists(root / ".repro" / "workspace.toml")

  test "fallback: the old settings file's private companion still applies":
    let scratch = createTempDir("repro-old-names-private-", "")
    defer: removeDir(scratch)
    let legacy = workspaceWith(scratch, "legacy")
    writeFile(legacy / ".repro-workspace.toml", oldSettings)
    writeFile(legacy / ".repro-workspace-private.toml", oldPrivateCompanion)
    let o = readWorkspaceSettings(findWorkspaceSettingsPath(legacy))
    check o.privateManifestUrl ==
      some("git@git.example.invalid:acme/internal-manifests")
    # The companion belongs to the OLD file only: beside the new file it is
    # not read (`settings.v1` replaces it with named layers).
    let fresh = workspaceWith(scratch, "fresh")
    writeFile(fresh / "repro-workspace.toml", newSettings)
    writeFile(fresh / ".repro-workspace-private.toml", oldPrivateCompanion)
    check readWorkspaceSettings(findWorkspaceSettingsPath(fresh)).privateManifestUrl.isNone

  test "write after a settings fallback read: the new name and schema":
    let scratch = createTempDir("repro-old-names-settings-write-", "")
    defer: removeDir(scratch)
    let legacy = workspaceWith(scratch, "legacy")
    writeFile(legacy / ".repro-workspace.toml", oldSettings)
    let o = readWorkspaceSettings(findWorkspaceSettingsPath(legacy))
    writeWorkspaceManifestFile(legacy / settingsFileName,
      workspaceSettingsText(o))
    check settingsFileName == "repro-workspace.toml"
    check readFile(legacy / settingsFileName).startsWith(
      "schema = \"reprobuild.workspace.settings.v1\"")
    check findWorkspaceSettingsPath(legacy) == legacy / "repro-workspace.toml"
    let n = readWorkspaceSettings(findWorkspaceSettingsPath(legacy))
    check n.schema == schemaWorkspaceSettingsV1
    sameSettings(n, o)
    check readFile(legacy / ".repro-workspace.toml") == oldSettings

  test "fallback: the state file's old name resolves like the new one":
    let scratch = createTempDir("repro-old-names-state-", "")
    defer: removeDir(scratch)
    let fresh = workspaceWith(scratch, "fresh")
    let legacy = workspaceWith(scratch, "legacy")
    createDir(fresh / ".repro")
    createDir(legacy / ".repro")
    writeFile(fresh / ".repro" / "workspace-state.toml", newState)
    writeFile(legacy / ".repro" / "workspace.toml", oldState)

    check workspaceTomlPath(fresh) == fresh / ".repro" / "workspace-state.toml"
    check workspaceTomlPath(legacy) == legacy / ".repro" / "workspace.toml"
    for root in [fresh, legacy]:
      check isInitializedWorkspace(root)
      check readWorkspaceProjects(root) == @["alpha", "gamma"]
      check readWorkspaceBranch(root) == some("feature/x")
      check readWorkspaceFeatureStarted(root)
    check readWorkspaceLocal(workspaceTomlPath(fresh)).workspace ==
      readWorkspaceLocal(workspaceTomlPath(legacy)).workspace
    # Through the binary.
    check enabledSet(fresh) == @["alpha", "gamma"]
    check enabledSet(legacy) == @["alpha", "gamma"]

  test "write after a state fallback read: the new name, the old file untouched":
    let scratch = createTempDir("repro-old-names-state-write-", "")
    defer: removeDir(scratch)
    let legacy = workspaceWith(scratch, "legacy")
    createDir(legacy / ".repro")
    let oldPath = legacy / ".repro" / "workspace.toml"
    let newPath = legacy / ".repro" / "workspace-state.toml"
    writeFile(oldPath, oldState)

    # Library writer.
    writeWorkspaceBranch(legacy, "", "feature/y")
    check fileExists(newPath)
    check readFile(oldPath) == oldState
    let migrated = readFile(newPath)
    check migrated.startsWith("schema = \"reprobuild.workspace.state.v1\"")
    # Carried across from the old file, not re-rendered: the comment survives.
    check "# Written by an older repro." in migrated
    check readWorkspaceBranch(legacy) == some("feature/y")
    check readWorkspaceProjects(legacy) == @["alpha", "gamma"]
    check workspaceTomlPath(legacy) == newPath

    # The binary writes the new file too, and the old one stays inert.
    let res = repro(["workspace", "enable", "beta",
      "--workspace-root=" & legacy])
    if res.code != 0:
      checkpoint(res.output)
    check res.code == 0
    check enabledSet(legacy) == @["alpha", "gamma", "beta"]
    check readFile(oldPath) == oldState
    check readWorkspaceLocal(newPath).workspace.projects ==
      @["alpha", "gamma", "beta"]

  test "fallback: a repo.v1 branch resolves like a repo.v2 mainline":
    let scratch = createTempDir("repro-old-names-fragment-", "")
    defer: removeDir(scratch)
    let v1 = scratch / "v1.toml"
    let v2 = scratch / "v2.toml"
    writeFile(v1, "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
      "name = \"w\"\npath = \"w\"\nbranch = \"dev\"\n")
    writeFile(v2, "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
      "name = \"w\"\npath = \"w\"\nmainline = \"dev\"\n")
    let f1 = readRepoFragment(v1)
    let f2 = readRepoFragment(v2)
    check f1.repo.mainlineBranch == some("dev")
    check f1.repo.mainlineBranch == f2.repo.mainlineBranch
    check f1.repo.roleDecls == f2.repo.roleDecls

    # A write after reading the v1 spelling produces the v2 spelling.
    let rewritten = scratch / "rewritten.toml"
    writeWorkspaceManifestFile(rewritten, repoFragmentText(f1))
    check readFile(rewritten) == readFile(v2)

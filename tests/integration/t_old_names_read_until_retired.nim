## Every retired workspace spelling is refused, not read — and refused with
## the remedy, so an operator still on one is told what to change rather than
## seeing a workspace silently lose its settings or state.
##
## Workspace-Settings-Files.md §8 step 4 and Workspace-Branch-Roles.md §6 step
## 3 retire the old spellings once every workspace has migrated. Each is
## checked here against the same content under the current spelling:
##
## * the settings file under its retired name (`bootstrap.v1`): discovery
##   still stops at the directory that holds it — so the workspace is found
##   and every command refuses THERE, naming the rename and the rewrite —
##   instead of walking past it as if there were no settings at all; beside a
##   current `repro-workspace.toml` it is inert. Its private companion is
##   never read. The retired schema is refused under the current name too.
## * the state file under its retired name (`local.v1`): every verb refuses
##   with the remedy `repro health --fix`, which still migrates it (the one
##   reader of the retired file); the writers refuse rather than start a
##   second state file beside it.
## * the fragment: `repo.v1` (`branch`) is refused at load naming
##   `repo.v2` and `mainline`, and the writer emits only `repo.v2`.
##
## Each retired spelling is its own test case, so removing a refusal fails
## the case that names it. The settings and state cases are also driven
## through the real `repro` binary, so a CLI site that bypassed the shared
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
push_gateway = "off"

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
push_gateway = "off"

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
    name & "\"\n\nincludes = [\n]\n"

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

proc refusalOf(body: proc ()): ref WorkspaceManifestParseError =
  ## The structured refusal `body` raises; fails the test when it raises none.
  try:
    body()
  except WorkspaceManifestParseError as e:
    return e
  checkpoint("expected a WorkspaceManifestParseError")
  fail()

const settingsRemedy = "Rename it to `repro-workspace.toml`"
const stateRemedy = "`repro health --fix`"

suite "old names are refused once retired":

  setup:
    putEnv("REPRO_WORKSPACE_CONFIG", "")

  test "retired: the settings file's old name is refused with the remedy":
    let scratch = createTempDir("repro-old-names-settings-", "")
    defer: removeDir(scratch)
    let fresh = workspaceWith(scratch, "fresh")
    let legacy = workspaceWith(scratch, "legacy")
    writeFile(fresh / "repro-workspace.toml", newSettings)
    writeFile(legacy / ".repro-workspace.toml", oldSettings)

    check findWorkspaceSettingsPath(fresh) == fresh / "repro-workspace.toml"
    # The retired name is not read as settings. It is not walked past either
    # — the walk refuses at the directory holding it, from below it too.
    createDir(legacy / "sub" / "dir")
    for start in [legacy, legacy / "sub" / "dir"]:
      let e = refusalOf(proc () = discard findWorkspaceSettingsPath(start))
      check e.path == legacy / ".repro-workspace.toml"
      check settingsRemedy in e.innerMessage
      check "[records]" in e.innerMessage
    # It still marks the workspace root, so a command finds the workspace and
    # refuses there rather than reporting that there is no workspace.
    check findWorkspaceRoot(legacy / "sub" / "dir") == legacy

    # Beside the current file the retired one is inert: the current file
    # governs.
    writeFile(legacy / "repro-workspace.toml",
      newSettings.replace("\"beta\"", "\"gamma\""))
    check findWorkspaceSettingsPath(legacy) == legacy / "repro-workspace.toml"
    check readWorkspaceSettings(findWorkspaceSettingsPath(legacy)).projects.default ==
      @["gamma"]
    removeFile(legacy / "repro-workspace.toml")

    # Through the binary: `enable --default` reads the default set from the
    # current file, and refuses — naming the remedy, writing nothing — under
    # the retired one.
    let ok = repro(["workspace", "enable", "--default",
      "--workspace-root=" & fresh])
    if ok.code != 0:
      checkpoint(ok.output)
    check ok.code == 0
    check enabledSet(fresh) == @["beta"]
    let refused = repro(["workspace", "enable", "--default",
      "--workspace-root=" & legacy])
    checkpoint(refused.output)
    check refused.code != 0
    check ".repro-workspace.toml" in refused.output
    check settingsRemedy in refused.output
    check not fileExists(legacy / ".repro" / "workspace-state.toml")

  test "retired: the old settings file's private companion is never read":
    let scratch = createTempDir("repro-old-names-private-", "")
    defer: removeDir(scratch)
    let fresh = workspaceWith(scratch, "fresh")
    writeFile(fresh / "repro-workspace.toml", newSettings)
    writeFile(fresh / ".repro-workspace-private.toml", oldPrivateCompanion)
    # A credential-bearing url is a named layer's, supplied by the local
    # settings file; the old companion contributes no layer at all.
    let s = readWorkspaceSettings(findWorkspaceSettingsPath(fresh))
    check s.sharedLayers.len == 0
    check s.localLayers.len == 0
    check composeSettingsLayers(s).layers.len == 0

  test "retired: the old settings schema is refused under the current name":
    let scratch = createTempDir("repro-old-names-settings-schema-", "")
    defer: removeDir(scratch)
    let root = workspaceWith(scratch, "renamed-only")
    writeFile(root / "repro-workspace.toml", oldSettings)
    let e = refusalOf(proc () =
      discard readWorkspaceSettings(root / "repro-workspace.toml"))
    check e.keyPath == "schema"
    check e.observedSchema == "reprobuild.workspace.bootstrap.v1"
    check e.expectedSchema == schemaWorkspaceSettingsV1
    check settingsRemedy in e.innerMessage
    # What the renderer writes for the same policy is the current schema,
    # and reads back.
    var cfg = WorkspaceSettings()
    cfg.records.url = some("https://git.example.invalid/acme/records.git")
    cfg.records.branch = some("latest")
    cfg.records.publish_locks = some(true)
    cfg.projects.default = @["beta"]
    writeWorkspaceManifestFile(root / settingsFileName,
      workspaceSettingsText(cfg))
    check readFile(root / settingsFileName).startsWith(
      "schema = \"reprobuild.workspace.settings.v1\"")
    let n = readWorkspaceSettings(root / settingsFileName)
    check n.records == cfg.records
    check n.projects.default == @["beta"]

  test "retired: the state file's old name is refused, and health --fix migrates it":
    let scratch = createTempDir("repro-old-names-state-", "")
    defer: removeDir(scratch)
    let fresh = workspaceWith(scratch, "fresh")
    let legacy = workspaceWith(scratch, "legacy")
    createDir(fresh / ".repro")
    createDir(legacy / ".repro")
    writeFile(fresh / ".repro" / "workspace-state.toml", newState)
    let oldPath = legacy / ".repro" / "workspace.toml"
    writeFile(oldPath, oldState)

    check workspaceTomlPath(fresh) == fresh / ".repro" / "workspace-state.toml"
    check readWorkspaceProjects(fresh) == @["alpha", "gamma"]
    check enabledSet(fresh) == @["alpha", "gamma"]
    # Under the retired name the state is not read as "no state": every
    # reader refuses, naming the file and the remedy.
    for read in [proc () = discard workspaceTomlPath(legacy),
                 proc () = discard readWorkspaceProjects(legacy),
                 proc () = discard readWorkspaceBranch(legacy),
                 proc () = discard isInitializedWorkspace(legacy)]:
      let e = refusalOf(read)
      check e.path == oldPath
      check stateRemedy in e.innerMessage
    # It still marks the workspace root.
    check findWorkspaceRoot(legacy) == legacy
    let listed = repro(["workspace", "projects", "list", "--enabled",
      "--workspace-root=" & legacy])
    checkpoint(listed.output)
    check listed.code != 0
    check stateRemedy in listed.output
    # The shell prompt is the one reader that must not refuse: it renders on
    # every prompt, so an unreadable state degrades the segment instead.
    let prompt = repro(["prompt", "--workspace-root=" & legacy])
    checkpoint(prompt.output)
    check prompt.code == 0
    check stateRemedy notin prompt.output

    # `repro health --fix` is the one reader of the retired file: it moves the
    # file to the current name, keeping its text, and the workspace reads the
    # same state again.
    let fixed = repro(["health", "--fix", "--offline",
      "--workspace-root=" & legacy])
    checkpoint(fixed.output)
    check not fileExists(oldPath)
    let newPath = legacy / ".repro" / "workspace-state.toml"
    check fileExists(newPath)
    check readFile(newPath).startsWith("schema = \"reprobuild.workspace.state.v1\"")
    check "# Written by an older repro." in readFile(newPath)
    check readWorkspaceLocal(newPath).workspace ==
      readWorkspaceLocal(fresh / ".repro" / "workspace-state.toml").workspace
    check enabledSet(legacy) == @["alpha", "gamma"]

  test "retired: no writer starts a second state file beside the old name":
    let scratch = createTempDir("repro-old-names-state-write-", "")
    defer: removeDir(scratch)
    let legacy = workspaceWith(scratch, "legacy")
    createDir(legacy / ".repro")
    let oldPath = legacy / ".repro" / "workspace.toml"
    let newPath = legacy / ".repro" / "workspace-state.toml"
    writeFile(oldPath, oldState)

    # Library writer: refused, nothing written.
    let e = refusalOf(proc () = writeWorkspaceBranch(legacy, "alpha", "feature/y"))
    check stateRemedy in e.innerMessage
    check not fileExists(newPath)
    check readFile(oldPath) == oldState

    # The binary refuses too, and leaves both files as they were.
    let res = repro(["workspace", "enable", "beta",
      "--workspace-root=" & legacy])
    checkpoint(res.output)
    check res.code != 0
    check stateRemedy in res.output
    check not fileExists(newPath)
    check readFile(oldPath) == oldState

  test "retired: a repo.v1 fragment is refused, and the writer emits repo.v2":
    let scratch = createTempDir("repro-old-names-fragment-", "")
    defer: removeDir(scratch)
    let v1 = scratch / "v1.toml"
    let v2 = scratch / "v2.toml"
    writeFile(v1, "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
      "name = \"w\"\npath = \"w\"\nbranch = \"dev\"\n")
    writeFile(v2, "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
      "name = \"w\"\npath = \"w\"\nmainline = \"dev\"\n")
    let e = refusalOf(proc () = discard readRepoFragment(v1))
    check e.path == v1
    check e.keyPath == "schema"
    check "reprobuild.workspace.repo.v2" in e.innerMessage
    check "`mainline`" in e.innerMessage
    let f2 = readRepoFragment(v2)
    check f2.repo.mainline == some("dev")

    # Writing the record back produces the current spelling, byte for byte.
    let rewritten = scratch / "rewritten.toml"
    writeWorkspaceManifestFile(rewritten, repoFragmentText(f2))
    check readFile(rewritten) == readFile(v2)

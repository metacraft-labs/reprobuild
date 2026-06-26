## RA-6 — `repro workspace projects add --default` auto-layers the project
## set from `REPRO_DEFAULT_PROJECTS` on a fresh workspace.
##
## A fresh workspace with `REPRO_DEFAULT_PROJECTS` set to >= 2 project names
## that exist in a hermetic manifest → the FIRST `projects add --default`
## populates exactly that project set with NO explicit `add <project>`.
## `projects list` then reports exactly the env-specified set.
##
## Without the env var, `add --default` is a deliberate no-op (no host config
## either) — no auto-layer happens and the active set stays empty.
##
## Falsifiability:
##   * If `add --default` ignored `REPRO_DEFAULT_PROJECTS`, the set-match
##     assertion fails (the active set would be empty, not the env set).
##   * If `add --default` auto-layered without the env var, the
##     no-auto-layer assertion fails.
##
## Hermetic: a tempdir workspace with a hand-authored `.repo/manifests`
## (two project files); no network, no git clone — `projects add` /
## `projects list` only read/write `.repo/workspace.toml`.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc projectStub(name: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"" & name & "\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "includes = [\n]\n"

proc setupWorkspace(slug: string; projectNames: openArray[string]): string =
  ## Create a fresh, initialized workspace whose manifest declares the named
  ## projects. Returns the workspace root.
  let scratch = createTempDir("repro-ra6-default-" & slug & "-", "")
  let workspaceRoot = scratch / "workspace"
  let projectsDir = workspaceRoot / ".repo" / "manifests" / "projects"
  createDir(projectsDir)
  for name in projectNames:
    writeFile(projectsDir / (name & ".toml"), projectStub(name))
  result = workspaceRoot

proc projectsList(reproBin, workspaceRoot: string;
                  env: openArray[tuple[name, value: string]] = []): CmdResult =
  runShell(shellCommand(@[reproBin, "workspace", "projects", "list",
    "--workspace-root=" & workspaceRoot], env))

proc projectsAddDefault(reproBin, workspaceRoot: string;
                        env: openArray[tuple[name, value: string]] = []): CmdResult =
  runShell(shellCommand(@[reproBin, "workspace", "projects", "add", "--default",
    "--workspace-root=" & workspaceRoot], env))

proc activeSet(output: string): seq[string] =
  for line in output.splitLines():
    let t = line.strip()
    if t.len > 0:
      result.add(t)

suite "RA-6 — default projects auto-layer on fresh workspace":

  test "test_ra6_default_env_populates_exact_project_set":
    let ws = setupWorkspace("env-set", ["alpha", "beta", "gamma"])
    defer: removeDir(ws.parentDir)
    let reproBin = reproBinary()

    # Fresh workspace: no project set yet.
    let initial = projectsList(reproBin, ws)
    check initial.code == 0
    check activeSet(initial.output).len == 0

    # First `add --default` with REPRO_DEFAULT_PROJECTS set to two projects.
    let addRes = projectsAddDefault(reproBin, ws,
      @[("REPRO_DEFAULT_PROJECTS", "alpha:beta")])
    if addRes.code != 0:
      checkpoint("add output: " & addRes.output)
    check addRes.code == 0

    # The active set is EXACTLY the env-specified set (order preserved).
    let listed = projectsList(reproBin, ws)
    check listed.code == 0
    check activeSet(listed.output) == @["alpha", "beta"]

  test "test_ra6_no_env_no_auto_layer":
    let ws = setupWorkspace("no-env", ["alpha", "beta"])
    defer: removeDir(ws.parentDir)
    let reproBin = reproBinary()

    # WITHOUT REPRO_DEFAULT_PROJECTS (and no host config), `add --default`
    # is a deliberate no-op: no project is layered.
    let addRes = projectsAddDefault(reproBin, ws,
      @[("REPRO_DEFAULT_PROJECTS", "")])
    check addRes.code == 0

    let listed = projectsList(reproBin, ws)
    check listed.code == 0
    check activeSet(listed.output).len == 0

  test "test_ra6_default_layer_is_idempotent":
    let ws = setupWorkspace("idem", ["alpha", "beta"])
    defer: removeDir(ws.parentDir)
    let reproBin = reproBinary()
    let env = @[("REPRO_DEFAULT_PROJECTS", "alpha,beta")]

    check projectsAddDefault(reproBin, ws, env).code == 0
    let first = activeSet(projectsList(reproBin, ws).output)
    check first == @["alpha", "beta"]

    # Re-running does not duplicate the set.
    check projectsAddDefault(reproBin, ws, env).code == 0
    let second = activeSet(projectsList(reproBin, ws).output)
    check second == @["alpha", "beta"]

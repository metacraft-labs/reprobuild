## When an older repro writes the state file under its retired name beside
## the current one, the divergence is reported by `repro health` — not
## silently resolved, and not left for every verb to trip over.
##
## Workspace-Settings-Files.md §8: the retired name `.repro/workspace.toml` is
## not read; the state file is `.repro/workspace-state.toml`. An older build
## (still installed on some host) reads and writes ONLY the retired name, so
## in a checkout used by both the two files can diverge. Every verb reads the
## current file and ignores the retired one; `repro health` is where the
## divergence is reported (`workspaceStateSkew`): its `workspace-state-file`
## row fails naming both files, and `--fix` does NOT choose between the two
## records — it changes nothing.
##
## The sequence, on real files and through the real binary:
##
##   1. a checkout with the current file (`alpha`, `beta`) and the retired
##      file an earlier release migrated from, with its migration snapshot —
##      byte-identical, so nothing has diverged: health reports a plain
##      leftover, not skew (the negative control, so the report cannot pass
##      by always firing);
##   2. an older repro runs `enable gamma` — simulated by writing the retired
##      file exactly the way the 0.2.x serializer did (`serializeWorkspaceLocalToToml`,
##      deleted from this tree by the manifest-editor change): schema line,
##      blank line, `[workspace]`, `project`, `projects` array;
##   3. this repro still reads `alpha`, `beta`, warning about nothing on any
##      verb; `repro health` names both files and says an older repro changed
##      the retired one; `repro health --fix` leaves both files as they are.
##
## A second case covers the other shape: the current file exists first, and an
## older repro CREATES the retired file from scratch (it never saw the new one,
## and no snapshot exists).
##
## No mocks: real files in temporary directories, the real `repro`, stdout and
## stderr read separately so the assertion is about where the report goes.

import std/[json, os, osproc, streams, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc projectStub(name: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n[project]\nname = \"" &
    name & "\"\n\nincludes = [\n]\n"

proc oldBinaryState(projects: openArray[string]): string =
  ## The bytes 0.2.x's `serializeWorkspaceLocalToToml` wrote for a project set.
  result = "schema = \"reprobuild.workspace.local.v1\"\n\n[workspace]\n" &
    "project = \"" & projects[0] & "\"\n"
  if projects.len > 1:
    var quoted: seq[string]
    for p in projects: quoted.add("\"" & p & "\"")
    result.add("projects = [" & quoted.join(", ") & "]\n")

proc workspaceWith(scratch, name: string): string =
  result = scratch / name
  createDir(result / "projects")
  createDir(result / ".repro")
  for p in ["alpha", "beta", "gamma"]:
    writeFile(result / "projects" / (p & ".toml"), projectStub(p))

type Run = tuple[code: int; stdout, stderr: string]

proc repro(args: openArray[string]): Run =
  ## The real binary with stdout and stderr kept apart.
  putEnv("REPRO_WORKSPACE_CONFIG", "")
  let p = startProcess(reproBinary(), args = @args, options = {})
  let o = p.outputStream.readAll()
  let e = p.errorStream.readAll()
  result = (code: p.waitForExit(), stdout: o, stderr: e)
  p.close()

proc enabled(root: string): Run =
  repro(["workspace", "projects", "list", "--enabled",
    "--workspace-root=" & root])

proc names(stdout: string): seq[string] =
  for line in stdout.splitLines():
    if line.strip().len > 0:
      result.add(line.strip().split('\t')[0])

const skewMarker = "two workspace state files exist"

proc stateRow(root: string): JsonNode =
  ## The `workspace-state-file` row of `repro health --json`.
  let health = repro(["health", "--json", "--offline",
    "--workspace-root=" & root])
  checkpoint("health --json exit=" & $health.code & "\nstdout: " &
    health.stdout & "\nstderr: " & health.stderr)
  for row in parseJson(health.stdout)["checks"]:
    if row["name"].getStr() == "workspace-state-file":
      return row
  newJNull()

suite "state-file version skew is reported":

  test "t_state_file_skew_is_reported":
    let scratch = createTempDir("repro-state-skew-", "")
    defer: removeDir(scratch)
    let root = workspaceWith(scratch, "ws")
    let oldPath = root / ".repro" / "workspace.toml"
    let newPath = root / ".repro" / "workspace-state.toml"
    let snapshot = root / ".repro" / "workspace.toml.at-migration"

    # 1. As an earlier release left it after migrating: the retired file and
    #    its snapshot agree, and the current file holds this repro's state.
    check repro(["workspace", "enable", "alpha",
      "--workspace-root=" & root]).code == 0
    check repro(["workspace", "enable", "beta",
      "--workspace-root=" & root]).code == 0
    writeFile(oldPath, oldBinaryState(["alpha"]))
    writeFile(snapshot, oldBinaryState(["alpha"]))
    let before = enabled(root)
    check before.code == 0
    check names(before.stdout) == @["alpha", "beta"]
    check skewMarker notin before.stderr
    check workspaceStateSkew(root) == ""
    let leftover = stateRow(root)
    require leftover.kind == JObject
    check leftover["status"].getStr() == "fail"
    check skewMarker notin leftover["detail"].getStr()
    check "left over" in leftover["detail"].getStr()

    # 2. An older repro enables gamma: it only knows the retired file.
    writeFile(oldPath, oldBinaryState(["alpha", "gamma"]))

    # 3. Every verb still reads the current state, and warns about nothing.
    let after = enabled(root)
    check after.code == 0
    check names(after.stdout) == @["alpha", "beta"]
    check skewMarker notin after.stderr
    # `repro health` reports the divergence, naming both files.
    check workspaceStateSkew(root).len > 0
    let row = stateRow(root)
    require row.kind == JObject
    check row["status"].getStr() == "fail"
    check skewMarker in row["detail"].getStr()
    check newPath in row["detail"].getStr()
    check oldPath in row["detail"].getStr()
    check "older repro" in row["detail"].getStr()
    check not row["fixable"].getBool()
    # `--fix` does not choose between the two records.
    let stateBefore = readFile(newPath)
    discard repro(["health", "--fix", "--offline",
      "--workspace-root=" & root])
    check readFile(oldPath) == oldBinaryState(["alpha", "gamma"])
    check readFile(newPath) == stateBefore

    # Once the stale file is removed there is nothing to report.
    removeFile(oldPath)
    removeFile(snapshot)
    check workspaceStateSkew(root) == ""
    let clean = stateRow(root)
    require clean.kind == JObject
    check clean["status"].getStr() == "ok"

  test "an older repro creating the old file next to the new one is reported":
    let scratch = createTempDir("repro-state-skew-", "")
    defer: removeDir(scratch)
    let root = workspaceWith(scratch, "ws")
    check repro(["workspace", "enable", "alpha",
      "--workspace-root=" & root]).code == 0
    check fileExists(root / ".repro" / "workspace-state.toml")
    check workspaceStateSkew(root) == ""
    # The older repro never saw the new file, so it starts the old one fresh.
    writeFile(root / ".repro" / "workspace.toml", oldBinaryState(["gamma"]))
    let after = enabled(root)
    check names(after.stdout) == @["alpha"]
    check skewMarker notin after.stderr
    let row = stateRow(root)
    require row.kind == JObject
    check skewMarker in row["detail"].getStr()

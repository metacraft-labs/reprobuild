## When an older repro writes the OLD state file after this repro migrated to
## the new one, the divergence is reported — not silently ignored.
##
## Workspace-Settings-Files.md §8 step 1 has this repro write only
## `.repro/workspace-state.toml` and read the old `.repro/workspace.toml` only
## as a fallback. But older builds (0.2.x, still pinned in places during the
## transition) read and write ONLY the old file. In a checkout used by both,
## the two files can then diverge: each binary reports a different active
## project set and neither knows. This repro cannot stop the older one from
## writing, so it must say so on every state read (`workspaceStateSkew`,
## reported by `workspaceTomlPath`).
##
## The sequence, on real files and through the real binary:
##
##   1. a checkout with only the old file (`alpha`), as an older repro left it;
##   2. this repro runs `workspace enable beta` — it migrates to the new file
##      (`alpha`, `beta`) and must NOT warn: nothing has diverged yet (the
##      negative control, so the warning cannot pass by always firing);
##   3. an older repro runs `enable gamma` — simulated by writing the old file
##      exactly the way the 0.2.x serializer did (`serializeWorkspaceLocalToToml`,
##      deleted from this tree by the manifest-editor change): schema line,
##      blank line, `[workspace]`, `project`, `projects` array;
##   4. this repro reads state again: it still reports `alpha`, `beta` on
##      STDOUT, and its STDERR names both files and says an older repro
##      changed state it does not see.
##
## A second case covers the other shape: the new file exists first, and an
## older repro CREATES the old file from scratch (it never saw the new one).
##
## No mocks: real files in temporary directories, the real `repro`, stdout and
## stderr read separately so the assertion is about where the warning goes.

import std/[os, osproc, streams, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc projectStub(name: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n[project]\nname = \"" &
    name & "\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n" &
    "includes = [\n]\n"

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

suite "state-file version skew is reported":

  test "t_state_file_skew_is_reported":
    let scratch = createTempDir("repro-state-skew-", "")
    defer: removeDir(scratch)
    let root = workspaceWith(scratch, "ws")
    let oldPath = root / ".repro" / "workspace.toml"
    let newPath = root / ".repro" / "workspace-state.toml"

    # 1. As an older repro left it.
    writeFile(oldPath, oldBinaryState(["alpha"]))

    # 2. This repro migrates; nothing has diverged, so no warning.
    let enable = repro(["workspace", "enable", "beta",
      "--workspace-root=" & root])
    if enable.code != 0:
      checkpoint(enable.stdout & enable.stderr)
    check enable.code == 0
    check fileExists(newPath)
    let before = enabled(root)
    check before.code == 0
    check names(before.stdout) == @["alpha", "beta"]
    check skewMarker notin before.stderr
    check workspaceStateSkew(root) == ""

    # 3. An older repro enables gamma: it only knows the old file.
    writeFile(oldPath, oldBinaryState(["alpha", "gamma"]))

    # 4. This repro still sees its own state — and says the other changed.
    let after = enabled(root)
    check after.code == 0
    check names(after.stdout) == @["alpha", "beta"]
    check skewMarker in after.stderr
    check newPath in after.stderr
    check oldPath in after.stderr
    check "older repro" in after.stderr
    check "repro health --fix" in after.stderr
    # Reported once per command, not once per state read.
    check after.stderr.count(skewMarker) == 1
    check workspaceStateSkew(root).len > 0

    # Once the stale file is removed there is nothing to report.
    removeFile(oldPath)
    check skewMarker notin enabled(root).stderr

  test "an older repro creating the old file next to the new one is reported":
    let scratch = createTempDir("repro-state-skew-", "")
    defer: removeDir(scratch)
    let root = workspaceWith(scratch, "ws")
    check repro(["workspace", "enable", "alpha",
      "--workspace-root=" & root]).code == 0
    check fileExists(root / ".repro" / "workspace-state.toml")
    check skewMarker notin enabled(root).stderr
    # The older repro never saw the new file, so it starts the old one fresh.
    writeFile(root / ".repro" / "workspace.toml", oldBinaryState(["gamma"]))
    let after = enabled(root)
    check names(after.stdout) == @["alpha"]
    check skewMarker in after.stderr

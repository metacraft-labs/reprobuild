## `repro prompt` never prints workspace notices.
##
## Workspace notices — a settings layer skipped for want of a url
## (Workspace-Settings-Files.md §4) and the state-file version-skew warning
## (§8) — are a property of the checkout that every verb the operator runs
## reports once, on stderr. The prompt is not such a verb: it runs on EVERY
## shell render, and CLI/prompt.md requires it to stay silent when it has
## nothing to show and to do only cheap reads. Printing a notice there would put
## the same line under every prompt, and computing it reads and decodes the
## settings files on every render. So the prompt opts out of notices for its
## whole render (`withoutWorkspaceNotices`).
##
## Two real fixtures, each run through the real `repro` binary:
##
##   1. a root marked only by `repro-workspace.toml` declaring a named layer no
##      file supplies a url for, with NO state file: not an initialized
##      workspace, so the prompt prints nothing at all — stdout AND stderr
##      empty;
##   2. an initialized root (state file) whose `repro-workspace.toml` declares
##      the same url-less layer AND that carries both state files with no
##      migration snapshot (the version-skew condition): the prompt prints its
##      segment on stdout and nothing on stderr.
##
## Positive control: `repro workspace list` at fixture 2 DOES print both
## notices, so the fixture really carries them and the silence is the
## prompt's doing.
##
## Mutation check: making `withoutWorkspaceNotices` leave notices enabled
## fails the empty-stderr assertions for both fixtures.
##
## No mocks; no git is spawned (the prompt never runs git).

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_test_support

proc reproBinary(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc runRepro(args: openArray[string]; cwd: string):
    tuple[code: int; stdout, stderr: string] =
  ## The real binary run from `cwd` with no inherited settings override, its
  ## stdout and stderr read separately.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env.del("REPRO_WORKSPACE_CONFIG")
  let p = startProcess(reproBinary(), workingDir = cwd, args = @args,
    env = env, options = {})
  p.inputStream.close()
  let o = p.outputStream.readAll()
  let e = p.errorStream.readAll()
  result = (code: p.waitForExit(), stdout: o, stderr: e)
  p.close()

const settingsWithUrllessLayer =
  "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
  "[[manifest]]\nname = \"absent\"\nvisibility = \"team\"\n"
const skipMarker = "manifest layer 'absent'"
const skewMarker = "two workspace state files exist"

proc seedProject(root: string) =
  createDir(root / "projects")
  writeFile(root / "projects" / "demo.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\nincludes = []\n\n" &
    "[project]\nname = \"demo\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n")

suite "the prompt prints no workspace notices":

  test "t_prompt_prints_no_workspace_notices":
    let scratch = createTempDir("repro-prompt-notices-", "")
    defer: removeDir(scratch)

    # Fixture 1 — settings-marked root, no state.
    let bare = scratch / "bare"
    seedProject(bare)
    writeFile(bare / "repro-workspace.toml", settingsWithUrllessLayer)
    let quiet = runRepro(["prompt"], bare)
    checkpoint("fixture 1 stderr: " & quiet.stderr)
    check quiet.code == 0
    check quiet.stdout == ""
    check quiet.stderr == ""

    # Fixture 2 — initialized root with a skipped layer and state-file skew.
    let ws = scratch / "ws"
    seedProject(ws)
    writeFile(ws / "repro-workspace.toml", settingsWithUrllessLayer)
    createDir(ws / ".repro")
    writeFile(ws / ".repro" / "workspace-state.toml",
      "schema = \"reprobuild.workspace.state.v1\"\n\n" &
      "[workspace]\nproject = \"demo\"\nbranch = \"feature-x\"\n")
    writeFile(ws / ".repro" / "workspace.toml",
      "schema = \"reprobuild.workspace.local.v1\"\n\n" &
      "[workspace]\nproject = \"demo\"\nbranch = \"other\"\n")
    let rendered = runRepro(["prompt"], ws)
    checkpoint("fixture 2 stdout: " & rendered.stdout)
    checkpoint("fixture 2 stderr: " & rendered.stderr)
    check rendered.code == 0
    check rendered.stdout.strip().len > 0
    check rendered.stderr == ""

    # Positive control: an ordinary verb at the same root reports both.
    let listed = runRepro(["workspace", "list", "--workspace-root=" & ws], ws)
    checkpoint("control stderr: " & listed.stderr)
    check skipMarker in listed.stderr
    check skewMarker in listed.stderr

## Regression — ``repro workspace manifests`` on a single-project
## (metadata-only) workspace must report it ACCURATELY.
##
## A ``.repro/workspace.toml`` written in single-project mode (``[workspace]``
## project + branch, zero ``[[manifest]]`` layers — what ``repro workspace
## projects add`` / ``init`` produce) IS present; it simply declares no manifest
## layers. The renderer nonetheless printed the same line it uses when the file
## is genuinely absent:
##
##   ``workspace manifests: no layered workspace (.repro/workspace.toml not present at …)``
##
## which is factually wrong — the file exists. The fix distinguishes the two
## cases. Asserted: the output names a ``single-project workspace`` and does NOT
## claim the file is ``not present``.
##
## Falsifiability: against a pre-fix build the ``not present`` substring is
## present and the ``single-project workspace`` substring is absent.
##
## Hermetic: fresh tempdir. Skip: ``./build/bin/repro`` absent.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_workspace_manifests

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

suite "regression — manifests reports single-project workspace accurately":

  test "t_manifests_reports_single_project_workspace":
    if not fileExists(reproBinary):
      skip()
    else:
      let scratch = createTempDir("manifests-single-", "")
      defer: removeDir(scratch)

      let ws = scratch / "workspace"
      let manifestsRoot = ws
      createDir(manifestsRoot / "projects")
      writeFile(manifestsRoot / "projects" / "solo.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"solo\"\ndefault_revision = \"main\"\n\n" &
        "includes = []\n")

      # Single-project (metadata-only) workspace.toml — present, but no
      # ``[[manifest]]`` layers.
      writeWorkspaceBranch(ws, project = "solo", branch = "main")
      check fileExists(ws / ".repro" / "workspace.toml")

      let res = run(reproBinary & " workspace manifests --workspace-root=" & q(ws))
      if res.code != 0:
        checkpoint("manifests output: " & res.output)
      check res.code == 0
      check res.output.contains("single-project workspace")
      check res.output.contains("solo")
      check not res.output.contains("not present")

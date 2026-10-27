## A state file that exists but is rejected is reported as such, never as
## "neither was present".
##
## The OLD state file `.repro/workspace.toml` (`local.v1`) records the
## workspace's project and, for a workspace that predates the settings files,
## its `[[manifest]]` layers (the new `.repro/workspace-state.toml` carries no
## layers at all — Workspace-Settings-Files.md §5 — so the fixture uses the
## old file, where a layer is still read until it is migrated). The
## strict reader rejects a key a recorded layer may not carry — `revision`
## (a settings-file layer key) or `from_settings` (internal provenance no file
## may declare) — with a diagnostic that names the file and the key. That
## diagnostic used to be thrown away twice: the routing probe caught it and
## answered "no layers", and the single-project ladder caught it again while
## recovering the recorded project, then reported that the command "requires
## either `.repro/workspace-state.toml` ... or a <project> argument; neither
## was present" — about a file that was present.
##
## The fixture is a real workspace root (`projects/demo.toml` declaring
## `core`, a real `file://` remote) whose state file carries one rejected key
## in its `[[manifest]]` entry. For each rejected key, `repro workspace list`
## and `repro sync --dry-run` (the REAL binary) must exit non-zero with a
## diagnostic naming the state file and `manifest[0].<key>`, and must not say
## "neither was present". A control run with the key removed resolves `core`,
## so the failure is the key and nothing else.
##
## What each assertion guards: the "names the key" and "never 'neither was
## present'" assertions fail when the probe and the ladder swallow the
## reader's error (measured: both verbs then print the "neither was present"
## message and never mention the key).
##
## No mocks. Skip rule: skip only when `git` is missing from PATH.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc reproBinary(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc runRepro(args: openArray[string]):
    tuple[code: int; stdout, stderr: string] =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env.del("REPRO_WORKSPACE_CONFIG")
  let p = startProcess(reproBinary(), args = @args, env = env, options = {})
  let o = p.outputStream.readAll()
  let e = p.errorStream.readAll()
  result = (code: p.waitForExit(), stdout: o, stderr: e)
  p.close()

proc requireSuccess(command: string) =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
    quit 1

proc seedBareRepo(gitBin, scratch, barePath: string) =
  let work = scratch / ("seed-" & extractFilename(barePath))
  requireSuccess(q(gitBin) & " init -q -b main " & q(work))
  requireSuccess(q(gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  requireSuccess(q(gitBin) & " -C " & q(work) & " config user.name Tester")
  writeFile(work / "README", "fixture\n")
  requireSuccess(q(gitBin) & " -C " & q(work) & " add -A")
  requireSuccess(q(gitBin) & " -C " & q(work) & " commit -q -m fixture")
  requireSuccess(q(gitBin) & " clone -q --bare " & q(work) & " " & q(barePath))

proc stateText(extraLayerKey: string): string =
  "schema = \"reprobuild.workspace.local.v1\"\n\n[workspace]\n" &
    "project = \"demo\"\n\n[[manifest]]\nlocal_path = \".\"\n" &
    "visibility = \"public\"\n" & extraLayerKey

suite "a malformed state file is reported accurately":

  test "t_malformed_state_file_is_reported_accurately":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the member repository is a real bare " &
        "repository the verbs resolve")
    else:
      let scratch = createTempDir("repro-malformed-state-", "")
      defer: removeDir(scratch)
      seedBareRepo(gitBin, scratch, scratch / "remotes" / "core")
      let root = scratch / "ws"
      createDir(root / "projects")
      createDir(root / "repos")
      createDir(root / ".repro")
      writeFile(root / "projects" / "demo.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "includes = [\"repos/core.toml\"]\n\n[project]\nname = \"demo\"\n" &
        "default_revision = \"main\"\ntrunk = \"main\"\n\n[[remote]]\n" &
        "name = \"acme\"\nfetch = \"" & fileUrl(scratch / "remotes") & "\"\n")
      writeFile(root / "repos" / "core.toml",
        "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
        "name = \"core\"\npath = \"core\"\nremote = \"acme\"\n" &
        "mainline = \"main\"\n")
      let state = root / ".repro" / "workspace.toml"

      # Control: without a rejected key the recorded project resolves.
      writeFile(state, stateText(""))
      let control = runRepro(["workspace", "list", "--workspace-root=" & root])
      checkpoint("control: " & control.stdout & control.stderr)
      require control.code == 0
      require "core" in control.stdout

      for key in ["revision = \"x\"", "from_settings = true"]:
        let keyName = key.split(" ")[0]
        writeFile(state, stateText(key & "\n"))
        for args in [@["workspace", "list"], @["sync", "--dry-run"]]:
          let res = runRepro(args & @["--workspace-root=" & root])
          checkpoint(args.join(" ") & " with `" & key & "`: exit=" &
            $res.code & "\nstdout: " & res.stdout & "\nstderr: " & res.stderr)
          check res.code != 0
          check "neither was present" notin res.stderr
          check state in res.stderr
          check ("manifest[0]." & keyName) in res.stderr

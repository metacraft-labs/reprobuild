## A workspace's settings layers compose before any state file exists.
##
## Workspace-Settings-Files.md §4 "Layer resolution": layers compose "the root
## repository, then the shared file's `[[manifest]]` entries in order, then
## the local file's unnamed entries in order", and a shared named layer with
## no url from either file is "reported and skipped". Nothing in that rule
## mentions `.repro/workspace-state.toml`: the settings files are committed
## (and the local one sits beside them), so they exist in a fresh clone of the
## workspace repository before `repro workspace init` / `enable` has written
## any state. A workspace-resolving verb run there with a `<project>` must
## therefore see the layers' repos, and must report the skipped layer.
##
## The fixture is a real workspace root with NO `.repro/` at all:
##
##   * its own `projects/demo.toml` + `repos/core.toml` (the base layer);
##   * `repro-workspace.toml` declaring two named layers: `partner`, whose url
##     `repro-workspace.local.toml` supplies (a real `file://` bare git repo
##     carrying `projects/demo.toml` + `repos/partner-lib.toml`), and
##     `absent`, which no file supplies a url for.
##
## Every leg runs the REAL `repro` binary:
##
##   1. `repro workspace list demo --json` lists `core` (base layer) AND
##      `partner-lib` (cloned from the partner layer), and says on stderr,
##      exactly once, that layer `absent` was skipped. It writes no state
##      file — composing is a read.
##   2. `repro workspace manifests --json` enumerates the composed layer stack
##      (the root base layer and `partner`) with no state file.
##   3. Old workspaces are untouched: a root carrying only the OLD
##      `.repro-workspace.toml` (bootstrap.v1, which declares no layers) and
##      no state resolves `workspace list demo` to exactly the output of the
##      same root with no settings file at all, and prints nothing on stderr.
##
## Mutation check: making `isCompositionalWorkspaceToml` / the settings-layer
## seam compose only when a state file exists fails leg 1 on the
## `partner-lib` assertion and on the missing skip report.
##
## No mocks. Skip rule: skip only when `git` is missing from PATH (the partner
## layer is a real repository the real composer clones).

import std/[json, os, osproc, sequtils, streams, strtabs, strutils, tempfiles,
  unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc reproBinary(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc runRepro(args: openArray[string]):
    tuple[code: int; stdout, stderr: string] =
  ## The real binary's exit code, stdout and stderr, read separately so the
  ## skip report is looked for where it belongs and `--json` stays parseable.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  # The fixture's settings files must be found by discovery, not by an
  # inherited override pointing elsewhere.
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

proc seedBareWithFiles(gitBin, scratch, barePath: string;
                       files: openArray[(string, string)]) =
  ## A one-commit bare repository holding `files`, so the layer's url is a
  ## real `file://` remote with `main`.
  let work = scratch / ("seed-" & extractFilename(barePath))
  requireSuccess(q(gitBin) & " init -q -b main " & q(work))
  requireSuccess(q(gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  requireSuccess(q(gitBin) & " -C " & q(work) & " config user.name Tester")
  for (rel, body) in files:
    createDir((work / rel).parentDir)
    writeFile(work / rel, body)
  requireSuccess(q(gitBin) & " -C " & q(work) & " add -A")
  requireSuccess(q(gitBin) & " -C " & q(work) & " commit -q -m fixture")
  requireSuccess(q(gitBin) & " clone -q --bare " & q(work) & " " & q(barePath))

proc projectToml(includes: openArray[string]): string =
  result = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "includes = [\n"
  for inc in includes:
    result.add("  \"" & inc & "\",\n")
  result.add("]\n\n[project]\nname = \"demo\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n[[remote]]\nname = \"acme\"\n" &
    "fetch = \"https://git.example.invalid/acme\"\n")

proc fragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nremote = \"acme\"\nmainline = \"main\"\n"

proc seedRoot(root: string) =
  ## A workspace root's own membership (the base layer), and nothing else.
  createDir(root / "projects")
  createDir(root / "repos")
  writeFile(root / "projects" / "demo.toml", projectToml(["repos/core.toml"]))
  writeFile(root / "repos" / "core.toml", fragmentToml("core"))

proc repoNames(listJson: string): seq[string] =
  for repo in parseJson(listJson)["repos"]:
    result.add(repo["name"].getStr())

const skipMarker = "manifest layer 'absent'"

suite "settings layers apply without a state file":

  test "t_settings_layers_apply_without_state_file":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the partner layer is a real bare repository " &
        "cloned by the real composer, and nothing else proves its repos " &
        "reach a workspace that has no state file")
    else:
      let scratch = createTempDir("repro-layers-no-state-", "")
      defer: removeDir(scratch)

      let partnerBare = scratch / "partner-manifests.git"
      seedBareWithFiles(gitBin, scratch, partnerBare, [
        ("projects/demo.toml", projectToml(["repos/partner-lib.toml"])),
        ("repos/partner-lib.toml", fragmentToml("partner-lib"))])

      let root = scratch / "workspace"
      seedRoot(root)
      writeFile(root / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
        "[[manifest]]\nname = \"partner\"\nvisibility = \"team\"\n\n" &
        "[[manifest]]\nname = \"absent\"\nvisibility = \"team\"\n")
      writeFile(root / "repro-workspace.local.toml",
        "schema = \"reprobuild.workspace.settings-local.v1\"\n\n" &
        "[[manifest]]\nname = \"partner\"\nurl = \"" & fileUrl(partnerBare) &
        "\"\nbranch = \"main\"\n")
      # The precondition the whole test is about.
      require not dirExists(root / ".repro")

      # Leg 1 — the layer's repos are composed, the skipped layer reported.
      let listed = runRepro(["workspace", "list", "demo", "--json",
        "--workspace-root=" & root])
      checkpoint("workspace list stderr: " & listed.stderr)
      checkpoint("workspace list stdout: " & listed.stdout)
      check listed.code == 0
      let names = repoNames(listed.stdout)
      check "core" in names
      check "partner-lib" in names
      check listed.stderr.count(skipMarker) == 1
      check "the layer is skipped" in listed.stderr
      # Composing is a read: no state was written by it.
      check not fileExists(root / ".repro" / "workspace-state.toml")
      check not fileExists(root / ".repro" / "workspace.toml")

      # Leg 2 — the layer stack is enumerated with no state file.
      let manifests = runRepro(["workspace", "manifests", "--json",
        "--workspace-root=" & root])
      checkpoint("workspace manifests stderr: " & manifests.stderr)
      checkpoint("workspace manifests stdout: " & manifests.stdout)
      check manifests.code == 0
      let doc = parseJson(manifests.stdout)
      check doc["hasLayeredWorkspace"].getBool()
      let layerUrls = doc["layers"].getElems().mapIt(it["url"].getStr())
      check fileUrl(partnerBare) in layerUrls
      check doc["layers"].len == 2
      check manifests.stderr.count(skipMarker) == 1

      # Leg 3 — an OLD workspace (bootstrap.v1 only, no layers, no state)
      # resolves exactly as a root with no settings file at all.
      let plain = scratch / "plain"
      seedRoot(plain)
      let legacy = scratch / "legacy"
      seedRoot(legacy)
      writeFile(legacy / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\nurl = \"https://git.example.invalid/acme/records.git\"\n" &
        "branch = \"latest\"\n")
      let plainList = runRepro(["workspace", "list", "demo",
        "--workspace-root=" & plain])
      let legacyList = runRepro(["workspace", "list", "demo",
        "--workspace-root=" & legacy])
      checkpoint("legacy stderr: " & legacyList.stderr)
      check plainList.code == 0
      check legacyList.code == 0
      check legacyList.stdout.replace(legacy, "<root>") ==
        plainList.stdout.replace(plain, "<root>")
      check legacyList.stderr == ""
      check not dirExists(legacy / ".repro")

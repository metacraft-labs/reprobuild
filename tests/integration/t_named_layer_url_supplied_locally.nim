## A shared named manifest layer gets its url from the local settings file —
## and is skipped, with a report, when neither file supplies one.
##
## Workspace-Settings-Files.md §3–§4: `repro-workspace.toml` may declare a
## `[[manifest]]` layer by `name` and `visibility` only, because its url
## carries credentials that must not be committed. Each person's
## `repro-workspace.local.toml` supplies that url (and may set the branch)
## with an entry of the same name. A contributor without access supplies
## nothing, and the layer is then reported and skipped — not an error — so
## their workspace still works.
##
## This exercises the whole path, not just the decoder: a real workspace root
## whose own `projects/` is the base layer (§3: "The root repo is always the
## base layer"), a real bare git repository standing in for the partner's
## manifests, and the real composer (`composeManifestLayersFromFile`, the
## entry point the CLI uses) cloning it through the real VCS executor. The
## composed project must contain the root's repo (public, from the base
## layer) AND the partner's repo (team, from the cloned layer). Then the
## local file is removed and the same composition must skip the layer with a
## report naming it, falling back to the root alone.
##
## Workspace-Settings-Files.md §9 names this test
## `named_layer_url_supplied_locally`.
##
## No mocks. Skip rule: skip only when `git` is missing from PATH (the rule
## every M8 composition test uses).

import std/[options, os, osproc, streams, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_workspace_manifests
import git_actions
import repro_build_engine

proc q(value: string): string = quoteShell(value)

proc reproBinary(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc reproStderr(args: openArray[string]): tuple[code: int; stderr: string] =
  ## The real binary's exit code and STDERR alone (the report is a stderr
  ## notice, so it is looked for where it is supposed to be).
  let p = startProcess(reproBinary(), args = @args, options = {})
  discard p.outputStream.readAll()
  let e = p.errorStream.readAll()
  result = (code: p.waitForExit(), stderr: e)
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

suite "a shared named layer takes its url from the local file":

  test "t_named_layer_url_supplied_locally":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the partner layer is a real bare repository " &
        "cloned by the real composer, and nothing else proves the url the " &
        "local file supplies is the one that gets cloned")
    else:
      let scratch = createTempDir("repro-named-layer-", "")
      defer: removeDir(scratch)
      installGitVcsExecutor()
      defer: clearWorkspaceVcsExecutor()

      let partnerBare = scratch / "partner-manifests.git"
      seedBareWithFiles(gitBin, scratch, partnerBare, [
        ("projects/demo.toml", projectToml(["repos/partner-lib.toml"])),
        ("repos/partner-lib.toml", fragmentToml("partner-lib"))])

      let root = scratch / "workspace"
      createDir(root / "projects")
      createDir(root / "repos")
      writeFile(root / "projects" / "demo.toml",
        projectToml(["repos/core.toml"]))
      writeFile(root / "repos" / "core.toml", fragmentToml("core"))
      createDir(root / ".repro")
      writeFile(root / ".repro" / "workspace-state.toml",
        "schema = \"reprobuild.workspace.state.v1\"\n\n" &
        "[workspace]\nproject = \"demo\"\n")
      writeFile(root / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
        "[[manifest]]\nname = \"partner\"\nvisibility = \"team\"\n")
      let local = root / "repro-workspace.local.toml"
      writeFile(local,
        "schema = \"reprobuild.workspace.settings-local.v1\"\n\n" &
        "[[manifest]]\nname = \"partner\"\nurl = \"" & fileUrl(partnerBare) &
        "\"\nbranch = \"main\"\n")
      putEnv("REPRO_WORKSPACE_CONFIG", "")

      # The decoder's view: one layer, url and branch from the local file,
      # visibility from the shared one.
      let settings = readWorkspaceSettings(root / "repro-workspace.toml")
      let composition = composeSettingsLayers(settings)
      check composition.skipped.len == 0
      check composition.layers.len == 1
      check composition.layers[0].url == some(fileUrl(partnerBare))
      check composition.layers[0].branch == some("main")
      check composition.layers[0].visibility == "team"
      check composition.layers[0].name == some("partner")

      # The composer's view: the root is the base layer, the partner layer
      # is cloned and merged after it.
      check isCompositionalWorkspaceToml(root)
      let resolved = composeManifestLayersFromFile(workspaceTomlPath(root))
      var names: seq[string]
      for repo in resolved.repos:
        names.add(repo.name)
      check names == @["core", "partner-lib"]
      for repo in resolved.repos:
        if repo.name == "core":
          check repo.visibility == wvPublic
        else:
          check repo.visibility == wvTeam
          check repo.manifestLayer == fileUrl(partnerBare)

      # Nobody supplies the url: reported and skipped, not an error.
      removeFile(local)
      let bare = composeSettingsLayers(
        readWorkspaceSettings(root / "repro-workspace.toml"))
      check bare.layers.len == 0
      check bare.skipped.len == 1
      check bare.skipped[0].name == "partner"
      check "partner" in bare.skipped[0].message
      check "without a url" in bare.skipped[0].message
      let eff = effectiveWorkspaceLocalWithNotes(root)
      check eff.skipped.len == 1
      check eff.local.manifest.len == 0
      # With no layer left the workspace resolves from its root alone.
      check not isCompositionalWorkspaceToml(root)

      # Through the real binary: the skip is reported by verbs that resolve
      # the workspace as a SINGLE project — every layer was skipped, so they
      # never reach the composer — not only by the composing ones. A
      # repo-less copy of the root keeps the verbs off the network.
      let cliRoot = scratch / "cli-workspace"
      createDir(cliRoot / "projects")
      createDir(cliRoot / ".repro")
      writeFile(cliRoot / "projects" / "demo.toml", projectToml([]))
      writeFile(cliRoot / ".repro" / "workspace-state.toml",
        "schema = \"reprobuild.workspace.state.v1\"\n\n" &
        "[workspace]\nproject = \"demo\"\n")
      writeFile(cliRoot / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
        "[[manifest]]\nname = \"partner\"\nvisibility = \"team\"\n")
      for verb in [@["sync", "--dry-run"], @["workspace", "list"]]:
        let run = reproStderr(verb & @["--workspace-root=" & cliRoot])
        checkpoint($verb & " stderr: " & run.stderr)
        check run.code == 0
        check "manifest layer 'partner'" in run.stderr
        check "the layer is skipped" in run.stderr
        check run.stderr.count("manifest layer 'partner'") == 1

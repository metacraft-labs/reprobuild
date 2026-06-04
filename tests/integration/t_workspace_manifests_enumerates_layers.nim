## M12 — ``repro workspace manifests``.
##
## Integration test for the read-only manifests subcommand. The CLI
## dispatcher in ``libs/repro_cli_support/src/repro_cli_support.nim``
## routes ``repro workspace manifests`` to
## ``runWorkspaceManifestsCommand``, which:
##
##   1. Reads ``<workspaceRoot>/.repo/workspace.toml`` (M5 surface). A
##      missing workspace.toml is treated as "no layered workspace" —
##      the report's ``hasLayeredWorkspace`` flag is false and the
##      renderer prints a single info line; exit 0.
##   2. For each declared ``[[manifest]]`` layer, computes the layer's
##      provenance string (URL or local_path), visibility tier, and
##      on-disk checkout path that the M8 composer would have
##      materialised at.
##   3. Composes the layers via M8 to learn which composed repos each
##      layer ultimately contributed to (post-shadow-merge).
##   4. Emits ``<workspaceRoot>/.repro/workspace/manifests-report.json``
##      and exits 0 on success, 1 on malformed workspace.toml.
##
## Fixture pattern: hermetic bare-repo "manifest hosts" containing
## TOML files (mirrors the M8 composer test
## ``t_workspace_manifests_private_override_shadows_public``). The
## composer clones from ``file://`` URLs into the workspace's
## ``.repo/manifests-<i>-<sanitized>/`` directories on first
## composition; this test confirms the manifests subcommand reads back
## the same per-layer metadata.
##
## Skip rule: only when ``git`` is missing from PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc compileRepro(tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  let root = repoRoot()
  let args = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--nimcache:" & root / "build" / "nimcache" / "m12-workspace-manifests-repro",
    "--out:" & result,
    root / "apps" / "repro" / "repro.nim",
  ]
  discard requireSuccess(shellCommand(args), root)

# ---- bare-repo seed fixture (mirror M8 composer test) ----------------------

proc seedBareWithFiles(gitBin, scratch, barePath: string;
                       files: openArray[(string, string)]) =
  let workPath = scratch / ("seed-" & extractFilename(barePath))
  removeDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M12 Tester\"")
  for entry in files:
    let absPath = workPath / entry[0]
    createDir(absPath.splitPath.head)
    writeFile(absPath, entry[1])
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  removeDir(barePath)
  discard requireGit(q(gitBin) & " clone --bare " & q(workPath) & " " &
    q(barePath))

# ---- manifest TOML strings (mirror M8 composer test) -----------------------

const publicProjectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "myproject"
default_revision = "main"
default_remote = "origin"
trunk = "main"

[[remote]]
name = "origin"
fetch = "https://example.invalid/public"

includes = [
  "repos/lib-a.toml",
  "repos/lib-b.toml",
]
"""

const publicLibAToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
revision = "main"
"""

const publicLibBToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
revision = "main"
"""

const privateProjectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "myproject"
default_revision = "main"
default_remote = "origin"
trunk = "main"

[[remote]]
name = "origin"
fetch = "https://example.invalid/public"

includes = [
  "repos/lib-b.toml",
  "repos/lib-c.toml",
]
"""

const privateLibBToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
revision = "private-pin"
"""

const privateLibCToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-c"
path = "lib-c"
revision = "main"
"""

# ---- helpers --------------------------------------------------------------

proc writeWorkspaceToml(workspaceRoot, body: string): string =
  let dotRepo = workspaceRoot / ".repo"
  createDir(dotRepo)
  result = dotRepo / "workspace.toml"
  writeFile(result, body)

proc invokeManifests(reproBin, workspaceRoot: string;
                     extra: openArray[string] = []): CmdResult =
  var argv = @[
    reproBin, "workspace", "manifests",
    "--workspace-root=" & workspaceRoot,
  ]
  for x in extra: argv.add(x)
  runShell(shellCommand(argv))

proc readReport(workspaceRoot: string): JsonNode =
  let reportPath = workspaceRoot / ".repro" / "workspace" /
    "manifests-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc findLayerByProvenance(layers: JsonNode; provenance: string): JsonNode =
  for entry in layers:
    if entry["provenance"].getStr() == provenance:
      return entry
  return nil

# ---- the suite -------------------------------------------------------------

suite "M12 — repro workspace manifests (enumerates layers)":

  test "test_m12_manifests_two_layer_workspace_lists_both":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m12-manifests-twolayer-", "")
      defer: removeDir(scratch)
      let reproBin = compileRepro(scratch)

      let publicBare = scratch / "bare-public.git"
      let privateBare = scratch / "bare-private.git"
      seedBareWithFiles(gitBin, scratch, publicBare, [
        ("projects/myproject.toml", publicProjectToml),
        ("repos/lib-a.toml", publicLibAToml),
        ("repos/lib-b.toml", publicLibBToml),
      ])
      seedBareWithFiles(gitBin, scratch, privateBare, [
        ("projects/myproject.toml", privateProjectToml),
        ("repos/lib-b.toml", privateLibBToml),
        ("repos/lib-c.toml", privateLibCToml),
      ])

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      let workspaceTomlBody =
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"myproject\"\nbranch = \"main\"\n\n" &
        "[[manifest]]\n" &
        "url = \"" & fileUrl(publicBare) & "\"\n" &
        "visibility = \"public\"\nbranch = \"main\"\n\n" &
        "[[manifest]]\n" &
        "url = \"" & fileUrl(privateBare) & "\"\n" &
        "visibility = \"private\"\nbranch = \"main\"\n"
      discard writeWorkspaceToml(workspaceRoot, workspaceTomlBody)

      let res = invokeManifests(reproBin, workspaceRoot)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(workspaceRoot)
      check report["hasLayeredWorkspace"].getBool() == true
      check report["project"].getStr() == "myproject"
      check report["layers"].len == 2

      let publicLayer = findLayerByProvenance(report["layers"],
        fileUrl(publicBare))
      let privateLayer = findLayerByProvenance(report["layers"],
        fileUrl(privateBare))
      check not publicLayer.isNil
      check not privateLayer.isNil

      check publicLayer["visibility"].getStr() == "public"
      check publicLayer["url"].getStr() == fileUrl(publicBare)
      check publicLayer["localPath"].getStr() == ""
      check publicLayer["branch"].getStr() == "main"
      check publicLayer["index"].getInt() == 0

      check privateLayer["visibility"].getStr() == "private"
      check privateLayer["url"].getStr() == fileUrl(privateBare)
      check privateLayer["index"].getInt() == 1

      # Contribution map: public contributed lib-a only (lib-b was
      # shadowed by private); private contributed lib-b (the shadow)
      # and lib-c (new).
      var publicContrib: seq[string]
      for entry in publicLayer["contributedRepos"]:
        publicContrib.add(entry.getStr())
      var privateContrib: seq[string]
      for entry in privateLayer["contributedRepos"]:
        privateContrib.add(entry.getStr())
      check "lib-a" in publicContrib
      check "lib-b" notin publicContrib
      check "lib-b" in privateContrib
      check "lib-c" in privateContrib

      # The layer's on-disk checkout path must follow the composer's
      # ``manifests-<i>-<sanitized>`` convention.
      check publicLayer["layerCheckoutPath"].getStr().startsWith(
        workspaceRoot / ".repo" / "manifests-0-")
      check privateLayer["layerCheckoutPath"].getStr().startsWith(
        workspaceRoot / ".repo" / "manifests-1-")

  test "test_m12_manifests_no_workspace_toml_prints_no_layered_line":
    # No workspace.toml in this fixture; the subcommand should not
    # blow up — it should report ``hasLayeredWorkspace = false`` and
    # exit 0 cleanly. We use a fresh scratch directory without any
    # ``.repo/workspace.toml``.
    let scratch = createTempDir("repro-m12-manifests-bare-", "")
    defer: removeDir(scratch)
    let reproBin = compileRepro(scratch)
    let workspaceRoot = scratch / "workspace"
    createDir(workspaceRoot)
    createDir(workspaceRoot / ".repo")  # empty .repo dir

    let res = invokeManifests(reproBin, workspaceRoot)
    if res.code != 0:
      checkpoint("output: " & res.output)
    check res.code == 0
    check res.output.contains("no layered workspace")

    let report = readReport(workspaceRoot)
    check report["hasLayeredWorkspace"].getBool() == false
    check report["layers"].len == 0
    check report["project"].getStr().len == 0

  test "test_m12_manifests_json_mode_includes_per_layer_shape":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m12-manifests-json-", "")
      defer: removeDir(scratch)
      let reproBin = compileRepro(scratch)

      let publicBare = scratch / "bare-public.git"
      seedBareWithFiles(gitBin, scratch, publicBare, [
        ("projects/myproject.toml", publicProjectToml),
        ("repos/lib-a.toml", publicLibAToml),
        ("repos/lib-b.toml", publicLibBToml),
      ])

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)

      # Pre-populate an in-tree local-path manifest layer alongside
      # the URL layer so the JSON shape covers both kinds of entry.
      let localManifestRel = ".repo/manifests-personal"
      let localManifestAbs = workspaceRoot / localManifestRel
      createDir(localManifestAbs / "projects")
      createDir(localManifestAbs / "repos")
      writeFile(localManifestAbs / "projects" / "myproject.toml",
        privateProjectToml)
      writeFile(localManifestAbs / "repos" / "lib-b.toml", privateLibBToml)
      writeFile(localManifestAbs / "repos" / "lib-c.toml", privateLibCToml)

      let workspaceTomlBody =
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"myproject\"\nbranch = \"main\"\n\n" &
        "[[manifest]]\n" &
        "url = \"" & fileUrl(publicBare) & "\"\n" &
        "visibility = \"public\"\nbranch = \"main\"\n\n" &
        "[[manifest]]\n" &
        "local_path = \"" & localManifestRel & "\"\n" &
        "visibility = \"personal\"\n"
      discard writeWorkspaceToml(workspaceRoot, workspaceTomlBody)

      let res = invokeManifests(reproBin, workspaceRoot,
        extra = ["--json"])
      check res.code == 0

      let braceIdx = res.output.find('{')
      check braceIdx >= 0
      let payload = res.output[braceIdx .. ^1]
      let parsed = parseJson(payload)
      check parsed["hasLayeredWorkspace"].getBool() == true
      check parsed["layers"].len == 2

      let urlLayer = findLayerByProvenance(parsed["layers"],
        fileUrl(publicBare))
      let localLayer = findLayerByProvenance(parsed["layers"],
        localManifestRel)
      check not urlLayer.isNil
      check not localLayer.isNil

      check urlLayer["url"].getStr() == fileUrl(publicBare)
      check urlLayer["localPath"].getStr() == ""
      check urlLayer["visibility"].getStr() == "public"

      check localLayer["url"].getStr() == ""
      check localLayer["localPath"].getStr() == localManifestRel
      check localLayer["visibility"].getStr() == "personal"
      # ``local_path`` layers are resolved to absolute paths under
      # workspaceRoot when relative.
      check localLayer["layerCheckoutPath"].getStr() ==
        workspaceRoot / localManifestRel

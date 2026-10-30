## M12 — ``repro workspace manifests``.
##
## Integration test for the read-only manifests subcommand. The CLI
## dispatcher in ``libs/repro_cli_support/src/repro_cli_support.nim``
## routes ``repro workspace manifests`` to
## ``runWorkspaceManifestsCommand``, which:
##
##   1. Reads the workspace's state (``<workspaceRoot>/.repro/
##      workspace-state.toml``: the project) and the layers its settings
##      files declare (``repro-workspace.toml`` for shared layers,
##      ``repro-workspace.local.toml`` for one person's own;
##      Workspace-Settings-Files.md §3–§4). A workspace with neither state
##      nor settings layers is "no layered workspace" — the report's
##      ``hasLayeredWorkspace`` flag is false and the renderer prints a
##      single "no workspace metadata" info line; exit 0.
##   2. For each composed layer — the root repository first, which is
##      always the base layer (§3), then the settings layers in order —
##      computes the layer's provenance string (URL or local_path),
##      visibility tier, and on-disk checkout path that the M8 composer
##      would have materialised at.
##   3. Composes the layers via M8 to learn which composed repos each
##      layer ultimately contributed to (post-shadow-merge).
##   4. Emits ``<workspaceRoot>/.repro/build/reports/manifests-report.json``
##      and exits 0 on success, 1 on a malformed state or settings file.
##
## Fixture pattern: hermetic bare-repo "manifest hosts" containing
## TOML files (mirrors the M8 composer test
## ``t_workspace_manifests_private_override_shadows_public``). The
## composer clones from ``file://`` URLs into the workspace's
## ``.repro/manifests-<i>-<sanitized>/`` directories on first
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

# Test-Fixtures-In-Build-Graph M1: ``repro`` is a build-graph artifact
# (``reprobuild.apps.repro`` → ``build/bin/repro``, built by ``just bootstrap``
# / the apps collection before tests run). Assert it exists and use it instead
# of recompiling ``apps/repro/repro.nim`` at test runtime.
proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

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
default_remote = "origin"

[[remote]]
name = "origin"
fetch = "https://example.invalid/public"

includes = [
  "repos/lib-a.toml",
  "repos/lib-b.toml",
]
"""

const publicLibAToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-a"
path = "lib-a"
mainline = "main"
"""

const publicLibBToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-b"
path = "lib-b"
mainline = "main"
"""

const privateProjectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "myproject"
default_remote = "origin"

[[remote]]
name = "origin"
fetch = "https://example.invalid/public"

includes = [
  "repos/lib-b.toml",
  "repos/lib-c.toml",
]
"""

const privateLibBToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-b"
path = "lib-b"
mainline = "private-pin"
"""

const privateLibCToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-c"
path = "lib-c"
mainline = "main"
"""

# ---- helpers --------------------------------------------------------------

proc writeWorkspaceState(workspaceRoot: string) =
  ## The state file: the active project and branch. Manifest layers are not
  ## state; they are declared in the settings files below.
  let dotRepo = workspaceRoot / ".repro"
  createDir(dotRepo)
  writeFile(dotRepo / "workspace-state.toml",
    "schema = \"reprobuild.workspace.state.v1\"\n\n" &
    "[workspace]\nproject = \"myproject\"\nbranch = \"main\"\n")

proc writeSharedSettings(workspaceRoot, layersBody: string) =
  ## ``repro-workspace.toml``: the shared, committed layers.
  writeFile(workspaceRoot / "repro-workspace.toml",
    "schema = \"reprobuild.workspace.settings.v1\"\n\n" & layersBody)

proc writeLocalSettings(workspaceRoot, layersBody: string) =
  ## ``repro-workspace.local.toml``: one person's own (unnamed) layers.
  writeFile(workspaceRoot / "repro-workspace.local.toml",
    "schema = \"reprobuild.workspace.settings-local.v1\"\n\n" & layersBody)

proc checkRootBaseLayer(layers: JsonNode) =
  ## §3: the root repository is always the base layer, so it is listed
  ## first, as a ``local_path`` layer over the root itself. This fixture's
  ## root carries no ``projects/`` or ``repos/``, so it contributes nothing.
  let root = layers[0]
  check root["index"].getInt() == 0
  check root["url"].getStr() == ""
  check root["localPath"].getStr() == "."
  check root["visibility"].getStr() == "public"
  check root["contributedRepos"].len == 0

proc invokeManifests(reproBin, workspaceRoot: string;
                     extra: openArray[string] = []): CmdResult =
  var argv = @[
    reproBin, "workspace", "manifests", "--write-report",
    "--workspace-root=" & workspaceRoot,
  ]
  for x in extra: argv.add(x)
  runShell(shellCommand(argv))

proc readReport(workspaceRoot: string): JsonNode =
  let reportPath = workspaceRoot / ".repro" / "build" / "reports" /
    "manifests-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc canonical(path: string): string =
  try:
    normalizedPath(expandFilename(path))
  except OSError, CatchableError:
    let parent = path.parentDir
    if parent.len > 0 and parent != path:
      canonical(parent) / path.lastPathPart
    else:
      normalizedPath(absolutePath(path))

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
      let reproBin = reproBinary()

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
      writeWorkspaceState(workspaceRoot)
      writeSharedSettings(workspaceRoot,
        "[[manifest]]\n" &
        "url = \"" & fileUrl(publicBare) & "\"\n" &
        "visibility = \"public\"\nbranch = \"main\"\n\n" &
        "[[manifest]]\n" &
        "url = \"" & fileUrl(privateBare) & "\"\n" &
        "visibility = \"private\"\nbranch = \"main\"\n")

      let res = invokeManifests(reproBin, workspaceRoot)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(workspaceRoot)
      check report["hasLayeredWorkspace"].getBool() == true
      check report["project"].getStr() == "myproject"
      # The root's base layer, then the two declared layers in order.
      check report["layers"].len == 3
      checkRootBaseLayer(report["layers"])

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
      check publicLayer["index"].getInt() == 1

      check privateLayer["visibility"].getStr() == "private"
      check privateLayer["url"].getStr() == fileUrl(privateBare)
      check privateLayer["index"].getInt() == 2

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
      check canonical(publicLayer["layerCheckoutPath"].getStr()).startsWith(
        canonical(workspaceRoot / ".repro" / "manifests-1-"))
      check canonical(privateLayer["layerCheckoutPath"].getStr()).startsWith(
        canonical(workspaceRoot / ".repro" / "manifests-2-"))

  test "test_m12_manifests_no_workspace_toml_reports_missing_metadata":
    # No state file and no settings file in this fixture; the subcommand
    # should not blow up — it should report ``hasLayeredWorkspace = false``
    # and exit 0 cleanly. We use a fresh scratch directory without any
    # ``.repro/workspace-state.toml`` or ``repro-workspace.toml``.
    let scratch = createTempDir("repro-m12-manifests-bare-", "")
    defer: removeDir(scratch)
    let reproBin = reproBinary()
    let workspaceRoot = scratch / "workspace"
    createDir(workspaceRoot)
    createDir(workspaceRoot / ".repro")  # empty .repro dir

    let res = invokeManifests(reproBin, workspaceRoot)
    if res.code != 0:
      checkpoint("output: " & res.output)
    check res.code == 0
    check res.output.contains("no workspace metadata")

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
      let reproBin = reproBinary()

      let publicBare = scratch / "bare-public.git"
      seedBareWithFiles(gitBin, scratch, publicBare, [
        ("projects/myproject.toml", publicProjectToml),
        ("repos/lib-a.toml", publicLibAToml),
        ("repos/lib-b.toml", publicLibBToml),
      ])

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)

      # Pre-populate an in-tree local-path manifest layer alongside
      # the URL layer so the JSON shape covers both kinds of entry. It is
      # one person's own layer, so the local settings file declares it, and
      # it lives outside ``.repro/`` (§4: a ``local_path`` there is refused,
      # since everything under ``.repro/`` is disposable state).
      let localManifestRel = "manifests-personal"
      let localManifestAbs = workspaceRoot / localManifestRel
      createDir(localManifestAbs / "projects")
      createDir(localManifestAbs / "repos")
      writeFile(localManifestAbs / "projects" / "myproject.toml",
        privateProjectToml)
      writeFile(localManifestAbs / "repos" / "lib-b.toml", privateLibBToml)
      writeFile(localManifestAbs / "repos" / "lib-c.toml", privateLibCToml)

      writeWorkspaceState(workspaceRoot)
      writeSharedSettings(workspaceRoot,
        "[[manifest]]\n" &
        "url = \"" & fileUrl(publicBare) & "\"\n" &
        "visibility = \"public\"\nbranch = \"main\"\n")
      writeLocalSettings(workspaceRoot,
        "[[manifest]]\n" &
        "local_path = \"" & localManifestRel & "\"\n" &
        "visibility = \"personal\"\n")

      let res = invokeManifests(reproBin, workspaceRoot,
        extra = ["--json"])
      check res.code == 0

      let braceIdx = res.output.find('{')
      check braceIdx >= 0
      let payload = res.output[braceIdx .. ^1]
      let parsed = parseJson(payload)
      check parsed["hasLayeredWorkspace"].getBool() == true
      # The root's base layer, the shared url layer, the local layer.
      check parsed["layers"].len == 3
      checkRootBaseLayer(parsed["layers"])

      let urlLayer = findLayerByProvenance(parsed["layers"],
        fileUrl(publicBare))
      let localLayer = findLayerByProvenance(parsed["layers"],
        localManifestRel)
      check not urlLayer.isNil
      check not localLayer.isNil

      check urlLayer["url"].getStr() == fileUrl(publicBare)
      check urlLayer["localPath"].getStr() == ""
      check urlLayer["visibility"].getStr() == "public"
      check urlLayer["index"].getInt() == 1

      check localLayer["url"].getStr() == ""
      check localLayer["localPath"].getStr() == localManifestRel
      check localLayer["visibility"].getStr() == "personal"
      check localLayer["index"].getInt() == 2
      # ``local_path`` layers are resolved to absolute paths under
      # workspaceRoot when relative.
      check localLayer["layerCheckoutPath"].getStr() ==
        workspaceRoot / localManifestRel

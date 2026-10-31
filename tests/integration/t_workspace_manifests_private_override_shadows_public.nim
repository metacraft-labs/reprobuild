## M8 — Manifest-layer composition.
##
## The composer reads the workspace's state (`<workspaceRoot>/.repro/
## workspace-state.toml`: the active project) and the manifest layers the
## settings files declare (`repro-workspace.toml` for shared layers,
## `repro-workspace.local.toml` for one person's own;
## Workspace-Settings-Files.md §3–§4), behind the root repository, which is
## always the base layer. This fixture's root carries no `projects/`, so the
## base layer contributes nothing and the declared layers decide the result.
## It acquires each manifest layer (via M2 `bakWorkspaceVcs`
## clone for `url`-backed layers, in-tree for `local_path`-backed
## layers), resolves each layer's `projects/<project>.toml` via M6's
## `resolveProject`, and merges the per-layer `ResolvedProject` values
## into one flat `ResolvedProject`. Later layers shadow earlier ones on
## the `(name, path, projectRemote)` triple; non-matching repos APPEND.
##
## Fixture: hermetic local bare git repos stand in for the public and
## private manifest URLs. Each bare repo is built by committing a real
## working-tree of project + repo-fragment TOMLs, then `git clone
## --bare` into the bare path so the URL the test feeds into
## `repro-workspace.toml` is a valid `file://` remote with one commit on
## `main`.
##
## Skip rule: skip only when `git` is missing from PATH (same rule as
## the M2/M3 VCS tests). All four cases otherwise run.

import std/[options, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests
import git_actions
import repro_build_engine

proc whichGit(): string = findExe("git")

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc seedBareWithFiles(gitBin, scratch, barePath: string;
                       files: openArray[(string, string)]) =
  ## Build a one-commit bare git repo containing the given relative
  ## files. The bare repo is what a remote URL would resolve to; the
  ## composer clones from `file://<barePath>` into the workspace root.
  let workPath = scratch / ("seed-" & extractFilename(barePath))
  removeDir(workPath)
  discard requireSuccess(q(gitBin) & " init -b main " & q(workPath))
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M8 Tester\"")
  for entry in files:
    let relPath = entry[0]
    let body = entry[1]
    let absPath = workPath / relPath
    createDir(absPath.splitPath.head)
    writeFile(absPath, body)
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  removeDir(barePath)
  discard requireSuccess(q(gitBin) & " clone --bare " & q(workPath) & " " &
    q(barePath))

# ---- shared fixture TOML strings ------------------------------------------

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
mainline = "main"
revision = "private-pin"
"""

const privateLibCToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-c"
path = "lib-c"
mainline = "main"
"""

# A copy of the private toml with the same triple as a public repo to
# trigger the post-composition duplicate detector case.
const conflictPublicProjectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "myproject"
default_remote = "origin"

[[remote]]
name = "origin"
fetch = "https://example.invalid/public"

includes = [
  "repos/lib-a.toml",
]
"""

const conflictPrivateProjectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "myproject"
default_remote = "origin"

[[remote]]
name = "origin"
fetch = "https://example.invalid/public"

includes = [
  "repos/lib-a.toml",
  "repos/lib-a-twin.toml",
]
"""

# Twin: SAME (name, path, remote) triple as lib-a. Both fragments
# happen to live in the private layer; M6's per-layer duplicate check
# would already reject this for a single project. But to exercise the
# composer's post-composition guard we keep the twin in a SEPARATE
# fragment file with the same triple — M6's intra-include duplicate
# check catches this and surfaces the structured diagnostic that the
# composer wraps with the layer's provenance.
const conflictTwinToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-a"
path = "lib-a"
remote = "origin"
mainline = "main"
"""

const conflictLibAToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-a"
path = "lib-a"
remote = "origin"
mainline = "main"
"""

# ---- helpers --------------------------------------------------------------

proc writeWorkspaceState(workspaceRoot, workspaceBody: string): string =
  ## The state file (`[workspace]` only); returns its path, which the
  ## composer carries on its diagnostics.
  let dotRepo = workspaceRoot / ".repro"
  createDir(dotRepo)
  result = dotRepo / "workspace-state.toml"
  writeFile(result, "schema = \"reprobuild.workspace.state.v1\"\n\n" &
    "[workspace]\n" & workspaceBody)

proc writeSharedSettings(workspaceRoot, body: string) =
  ## `repro-workspace.toml`: the shared, committed manifest layers.
  writeFile(workspaceRoot / "repro-workspace.toml",
    "schema = \"reprobuild.workspace.settings.v1\"\n\n" & body)

proc writeLocalSettings(workspaceRoot, body: string) =
  ## `repro-workspace.local.toml`: one person's own (unnamed) layers.
  writeFile(workspaceRoot / "repro-workspace.local.toml",
    "schema = \"reprobuild.workspace.settings-local.v1\"\n\n" & body)

suite "M8 — manifest-layer composition":

  test "test_m8_private_layer_shadows_public_for_overlapping_repo":
    let gitBin = whichGit()
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m8-shadows-", "")
      defer: removeDir(scratch)

      installGitVcsExecutor()
      defer: clearWorkspaceVcsExecutor()

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
      let tomlPath = writeWorkspaceState(workspaceRoot,
        "project = \"myproject\"\nbranch = \"main\"\n")
      # The root's mainline is the project-level branch the composed result
      # carries (it replaced the project file's `default_revision` /
      # `trunk`), so declare it and check it survives composition.
      writeSharedSettings(workspaceRoot,
        "[workspace]\nmainline = \"main\"\n\n" &
        "[[manifest]]\n" &
        "url = \"" & fileUrl(publicBare) & "\"\n" &
        "visibility = \"public\"\nbranch = \"main\"\n\n" &
        "[[manifest]]\n" &
        "url = \"" & fileUrl(privateBare) & "\"\n" &
        "visibility = \"private\"\nbranch = \"main\"\n")

      let resolved = composeManifestLayersFromFile(tomlPath)

      check resolved.projectName == "myproject"
      check resolved.workspaceMainline == "main"
      # Three repos total: lib-a (public-only), lib-b (private shadows
      # public), lib-c (private-only).
      check resolved.repos.len == 3

      var libA, libB, libC: ResolvedRepo
      var libAIdx = -1
      var libBIdx = -1
      var libCIdx = -1
      for i, r in resolved.repos:
        case r.name
        of "lib-a":
          libA = r
          libAIdx = i
        of "lib-b":
          libB = r
          libBIdx = i
        of "lib-c":
          libC = r
          libCIdx = i
      check libAIdx >= 0
      check libBIdx >= 0
      check libCIdx >= 0

      # lib-a: public only.
      check libA.manifestLayer == fileUrl(publicBare)
      check libA.visibility == wvPublic
      check libA.revision == "main"

      # lib-b: shadowed by private. The revision MUST be "private-pin",
      # NOT "main" — this is the load-bearing shadowing assertion.
      check libB.manifestLayer == fileUrl(privateBare)
      check libB.visibility == wvPersonal
      check libB.revision == "private-pin"

      # lib-c: private only.
      check libC.manifestLayer == fileUrl(privateBare)
      check libC.visibility == wvPersonal
      check libC.revision == "main"

  test "test_m8_local_path_layer_loads_without_clone":
    let gitBin = whichGit()
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m8-localpath-", "")
      defer: removeDir(scratch)

      installGitVcsExecutor()
      defer: clearWorkspaceVcsExecutor()

      let publicBare = scratch / "bare-public.git"
      seedBareWithFiles(gitBin, scratch, publicBare, [
        ("projects/myproject.toml", publicProjectToml),
        ("repos/lib-a.toml", publicLibAToml),
        ("repos/lib-b.toml", publicLibBToml),
      ])

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)

      # Pre-populate an in-tree local manifest directory containing the
      # private project + repo fragments. It is one person's own layer, so
      # the local settings file declares it, outside `.repro/` (§4 refuses a
      # `local_path` there: everything under `.repro/` is disposable state).
      let localManifestRel = "manifests-personal"
      let localManifestAbs = workspaceRoot / localManifestRel
      createDir(localManifestAbs / "projects")
      createDir(localManifestAbs / "repos")
      writeFile(localManifestAbs / "projects" / "myproject.toml",
                privateProjectToml)
      writeFile(localManifestAbs / "repos" / "lib-b.toml", privateLibBToml)
      writeFile(localManifestAbs / "repos" / "lib-c.toml", privateLibCToml)

      let tomlPath = writeWorkspaceState(workspaceRoot,
        "project = \"myproject\"\nbranch = \"main\"\n")
      writeSharedSettings(workspaceRoot,
        "[[manifest]]\n" &
        "url = \"" & fileUrl(publicBare) & "\"\n" &
        "visibility = \"public\"\nbranch = \"main\"\n")
      writeLocalSettings(workspaceRoot,
        "[[manifest]]\n" &
        "local_path = \"" & localManifestRel & "\"\n" &
        "visibility = \"personal\"\n")

      let resolved = composeManifestLayersFromFile(tomlPath)
      check resolved.projectName == "myproject"

      # Same three-repo shape as the previous case: lib-a public,
      # lib-b shadowed by local, lib-c local-only.
      check resolved.repos.len == 3

      var localRepoCount = 0
      for r in resolved.repos:
        if r.manifestLayer == localManifestRel:
          inc localRepoCount
          check r.visibility == wvPersonal
        elif r.manifestLayer == fileUrl(publicBare):
          check r.visibility == wvPublic
        else:
          checkpoint("unexpected manifestLayer: " & r.manifestLayer)
          fail()
      # Both lib-b (shadow) and lib-c (new) come from the local layer.
      check localRepoCount == 2

  test "test_m8_layer_missing_project_raises":
    let gitBin = whichGit()
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m8-missing-project-", "")
      defer: removeDir(scratch)

      installGitVcsExecutor()
      defer: clearWorkspaceVcsExecutor()

      let publicBare = scratch / "bare-public.git"
      let privateBare = scratch / "bare-private-no-project.git"
      seedBareWithFiles(gitBin, scratch, publicBare, [
        ("projects/myproject.toml", publicProjectToml),
        ("repos/lib-a.toml", publicLibAToml),
        ("repos/lib-b.toml", publicLibBToml),
      ])
      # The private bare deliberately omits projects/myproject.toml; it
      # only declares a DIFFERENT project. Composing for "myproject"
      # must raise.
      const otherProjectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "otherproject"
default_remote = "origin"

[[remote]]
name = "origin"
fetch = "https://example.invalid/other"

includes = []
"""
      seedBareWithFiles(gitBin, scratch, privateBare, [
        ("projects/otherproject.toml", otherProjectToml),
      ])

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      # The layer list is built IN MEMORY and handed to the composer, not
      # written to a settings file. The rule under test belongs to layers
      # that do not come from the settings files (`from_settings` unset):
      # such a layer must declare the project. A settings-file layer instead
      # composes additively per project (Workspace-Settings-Files.md §4) and
      # would contribute nothing here rather than raise — that rule is
      # covered by `t_settings_layers_apply_without_state_file`.
      let tomlPath = writeWorkspaceState(workspaceRoot,
        "project = \"myproject\"\n")
      let local = WorkspaceLocal(schema: schemaWorkspaceStateV1,
        workspace: WorkspaceBody(project: "myproject"),
        manifest: @[
          ManifestLayer(url: some(fileUrl(publicBare)),
            visibility: "public", branch: some("main")),
          ManifestLayer(url: some(fileUrl(privateBare)),
            visibility: "private", branch: some("main"))])

      var raised = false
      try:
        discard composeManifestLayers(local, workspaceRoot, tomlPath)
      except WorkspaceManifestParseError as e:
        raised = true
        check e.path == tomlPath
        # The diagnostic must name BOTH the manifest URL/path AND the
        # missing project name so the user can fix it.
        check fileUrl(privateBare) in e.innerMessage
        check "myproject" in e.innerMessage
      check raised

  test "test_m8_compose_result_passes_m6_duplicate_check":
    let gitBin = whichGit()
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m8-dupcheck-", "")
      defer: removeDir(scratch)

      installGitVcsExecutor()
      defer: clearWorkspaceVcsExecutor()

      # The public layer is well-formed (single repo). The private
      # layer deliberately lists two fragments with the SAME
      # (name, path, projectRemote) triple, which M6's per-layer
      # resolveProject rejects with a duplicate diagnostic. The
      # composer wraps that error with the layer's provenance so the
      # caller knows WHICH layer's project file the rejection
      # originated in.
      let publicBare = scratch / "bare-public.git"
      let privateBare = scratch / "bare-private-dup.git"
      seedBareWithFiles(gitBin, scratch, publicBare, [
        ("projects/myproject.toml", conflictPublicProjectToml),
        ("repos/lib-a.toml", conflictLibAToml),
      ])
      seedBareWithFiles(gitBin, scratch, privateBare, [
        ("projects/myproject.toml", conflictPrivateProjectToml),
        ("repos/lib-a.toml", conflictLibAToml),
        ("repos/lib-a-twin.toml", conflictTwinToml),
      ])

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      let tomlPath = writeWorkspaceState(workspaceRoot,
        "project = \"myproject\"\n")
      writeSharedSettings(workspaceRoot,
        "[[manifest]]\n" &
        "url = \"" & fileUrl(publicBare) & "\"\n" &
        "visibility = \"public\"\nbranch = \"main\"\n\n" &
        "[[manifest]]\n" &
        "url = \"" & fileUrl(privateBare) & "\"\n" &
        "visibility = \"private\"\nbranch = \"main\"\n")

      var raised = false
      try:
        discard composeManifestLayersFromFile(tomlPath)
      except WorkspaceManifestParseError as e:
        raised = true
        # The diagnostic must reference duplication. The inner message
        # (wrapped by the composer) carries the M6 "duplicate repo"
        # phrase and names the offending layer.
        check "duplicate" in e.innerMessage.toLowerAscii()
        check fileUrl(privateBare) in e.innerMessage
      check raised

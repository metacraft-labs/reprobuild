## M6 — `resolveProject` against a fixture that mirrors the post-refactor
## metacraft manifest set (project + three repo fragments).
##
## Each case builds its own scratch manifest-repo-shaped directory under
## `createTempDir`:
##
##   manifest_root/
##     projects/<project>.toml
##     repos/<r1>.toml
##     repos/<r2>.toml
##     repos/<r3>.toml
##
## The project sets `default_remote` and a `[[remote]]` table with two
## remotes (`metacraft-labs` and `github`). Every fragment declares its
## `mainline`, which supplies the checkout revision unless the fragment pins a
## `revision` beside it. At least one fragment relies on the project-default
## remote (omits its `remote` field); at least one fragment pins a revision
## that is not its mainline.

import std/[os, strutils, tempfiles, unittest]

import repro_workspace_manifests

const projectHappyToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "reprobuild"
default_remote = "metacraft-labs"

[[remote]]
name = "metacraft-labs"
fetch = "https://github.com/metacraft-labs"

[[remote]]
name = "github"
fetch = "https://github.com"

includes = [
  "repos/reprobuild.toml",
  "repos/runquota.toml",
  "repos/reprobuild-cmake.toml",
]
"""

# Fragment 1: explicit remote, a `revision` pin that overrides its mainline
# (the pin is NOT `main`), explicit vcs and stability.
const repoReprobuildToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "reprobuild"
path = "reprobuild"
remote = "metacraft-labs"
mainline = "main"
revision = "phase-2"
vcs = "git"
stability = "tracked"
"""

# Fragment 2: its mainline supplies the revision (no `revision` pin), and it
# relies on the project-default remote (omits `remote`). Also omits `vcs` and
# `stability` so the resolver applies the documented defaults.
const repoRunquotaToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
mainline = "main"
name = "runquota"
path = "runquota"
"""

# Fragment 3: explicit non-default remote (`github`); its mainline supplies
# the revision.
const repoReprobuildCmakeToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
mainline = "main"
name = "reprobuild-cmake"
path = "reprobuild-cmake"
remote = "github"
"""

# Variant of fragment 3 that references a remote the project doesn't
# declare. Drives the "unknown remote" diagnostic case.
const repoReprobuildCmakeUnknownRemoteToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
mainline = "main"
name = "reprobuild-cmake"
path = "reprobuild-cmake"
remote = "missing-remote-name"
"""

proc buildManifestRoot(): string =
  ## Build a manifest-repo-shaped directory with `projects/` and `repos/`
  ## subdirs. Returns the absolute path to the root.
  result = createTempDir("reprobuild-m6-resolve-project-", "")
  createDir(result / "projects")
  createDir(result / "repos")

proc writeAll(root: string) =
  ## Write the canonical happy-path fixture into a freshly built root.
  writeFile(root / "projects" / "reprobuild.toml", projectHappyToml)
  writeFile(root / "repos" / "reprobuild.toml", repoReprobuildToml)
  writeFile(root / "repos" / "runquota.toml", repoRunquotaToml)
  writeFile(root / "repos" / "reprobuild-cmake.toml",
            repoReprobuildCmakeToml)

suite "M6 — resolveProject against a metacraft-shaped fixture":

  test "test_m6_resolve_reprobuild_project_happy_path":
    let root = buildManifestRoot()
    writeAll(root)
    let projectFile = root / "projects" / "reprobuild.toml"

    let resolved = resolveProject(projectFile)

    # ---- project-level facts ----
    check resolved.projectName == "reprobuild"
    # The project names no branch: the workspace branch is the root
    # repository's mainline, and this fixture's root declares none.
    check resolved.workspaceMainline == ""
    check resolved.projectFile == projectFile
    check resolved.repos.len == 3

    # ---- source order preservation ----
    check resolved.repos[0].name == "reprobuild"
    check resolved.repos[1].name == "runquota"
    check resolved.repos[2].name == "reprobuild-cmake"

    # ---- fragment 1: explicit everything, including revision override ----
    let r0 = resolved.repos[0]
    check r0.path == "reprobuild"
    check r0.projectRemote == "metacraft-labs"
    check r0.fetchUrl == "https://github.com/metacraft-labs/reprobuild"
    check r0.branch == "main"  # the mainline it follows
    check r0.revision == "phase-2"  # the pin, NOT the mainline
    check r0.vcs == "git"
    check r0.stability == "tracked"
    check r0.fragmentPath == root / "repos" / "reprobuild.toml"

    # ---- fragment 2: relies on every default the project provides ----
    let r1 = resolved.repos[1]
    check r1.path == "runquota"
    check r1.projectRemote == "metacraft-labs"  # project default
    check r1.fetchUrl == "https://github.com/metacraft-labs/runquota"
    check r1.revision == "main"  # from its mainline
    check r1.vcs == "git"  # resolver default
    check r1.stability == "tracked"  # resolver default
    check r1.fragmentPath == root / "repos" / "runquota.toml"

    # ---- fragment 3: explicit remote (not the default), mainline revision ----
    let r2 = resolved.repos[2]
    check r2.path == "reprobuild-cmake"
    check r2.projectRemote == "github"  # explicit, overriding the default
    check r2.fetchUrl == "https://github.com/reprobuild-cmake"
    check r2.revision == "main"  # from its mainline
    check r2.vcs == "git"
    check r2.stability == "tracked"
    check r2.fragmentPath == root / "repos" / "reprobuild-cmake.toml"

  test "test_m6_resolve_reprobuild_project_unknown_remote":
    let root = buildManifestRoot()
    writeAll(root)
    # Swap fragment 3 with the unknown-remote variant.
    writeFile(root / "repos" / "reprobuild-cmake.toml",
              repoReprobuildCmakeUnknownRemoteToml)
    let projectFile = root / "projects" / "reprobuild.toml"

    var raised = false
    try:
      discard resolveProject(projectFile)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.path == projectFile
      check e.keyPath == "includes[2]"
      check e.expectedSchema == "reprobuild.workspace.project.v1"
      # The diagnostic must name BOTH the offending fragment and the
      # unresolvable remote name so a user can fix it without re-reading
      # the project file.
      check "reprobuild-cmake.toml" in e.innerMessage
      check "missing-remote-name" in e.innerMessage
    check raised

  test "test_m6_resolve_reprobuild_project_missing_include":
    let root = buildManifestRoot()
    writeAll(root)
    # Delete fragment 2 so the include resolves to a missing file.
    removeFile(root / "repos" / "runquota.toml")
    let projectFile = root / "projects" / "reprobuild.toml"

    var raised = false
    try:
      discard resolveProject(projectFile)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.path == projectFile
      check e.keyPath == "includes[1]"
      check e.expectedSchema == "reprobuild.workspace.project.v1"
      # Diagnostic must name the missing include path.
      check "repos/runquota.toml" in e.innerMessage
    check raised

  test "test_m6_resolve_reprobuild_project_escapes_root":
    let root = buildManifestRoot()
    # Build a project whose third include escapes the manifest root.
    const projectEscapingToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "reprobuild"
default_remote = "metacraft-labs"

[[remote]]
name = "metacraft-labs"
fetch = "https://github.com/metacraft-labs"

[[remote]]
name = "github"
fetch = "https://github.com"

includes = [
  "repos/reprobuild.toml",
  "repos/runquota.toml",
  "../escape.toml",
]
"""
    writeFile(root / "projects" / "reprobuild.toml", projectEscapingToml)
    writeFile(root / "repos" / "reprobuild.toml", repoReprobuildToml)
    writeFile(root / "repos" / "runquota.toml", repoRunquotaToml)
    let projectFile = root / "projects" / "reprobuild.toml"

    var raised = false
    try:
      discard resolveProject(projectFile)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.path == projectFile
      check e.keyPath == "includes"
      check e.expectedSchema == "reprobuild.workspace.project.v1"
      check "../escape.toml" in e.innerMessage
      check "escapes the manifest root" in e.innerMessage
    check raised

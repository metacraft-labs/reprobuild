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
## The project sets `default_revision = "main"` and a `[[remote]]` table
## with two remotes (`metacraft-labs` and `github`). At least one fragment
## relies on the project-default remote (omits its `remote` field); at
## least one fragment overrides the revision.

import std/[os, strutils, tempfiles, unittest]

import repro_workspace_manifests

const projectHappyToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "reprobuild"
default_revision = "main"
default_remote = "metacraft-labs"
trunk = "main"

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

# Fragment 1: explicit remote, explicit revision override (revision is NOT
# `main`), explicit vcs and stability.
const repoReprobuildToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "reprobuild"
path = "reprobuild"
remote = "metacraft-labs"
revision = "phase-2"
vcs = "git"
stability = "tracked"
"""

# Fragment 2: relies on project-default revision AND project-default
# remote (omits both `remote` and `revision`). Also omits `vcs` and
# `stability` so the resolver applies the documented defaults.
const repoRunquotaToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "runquota"
path = "runquota"
"""

# Fragment 3: explicit non-default remote (`github`), relies on
# project-default revision.
const repoReprobuildCmakeToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "reprobuild-cmake"
path = "reprobuild-cmake"
remote = "github"
"""

# Variant of fragment 3 that references a remote the project doesn't
# declare. Drives the "unknown remote" diagnostic case.
const repoReprobuildCmakeUnknownRemoteToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
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
    check resolved.defaultRevision == "main"
    check resolved.trunk == "main"
    check resolved.projectFile == projectFile
    check resolved.repos.len == 3

    # ---- source order preservation ----
    check resolved.repos[0].name == "reprobuild"
    check resolved.repos[1].name == "runquota"
    check resolved.repos[2].name == "reprobuild-cmake"

    # ---- fragment 1: explicit everything, including revision override ----
    let r0 = resolved.repos[0]
    check r0.path == "reprobuild"
    check r0.remoteName == "metacraft-labs"
    check r0.fetchUrl == "https://github.com/metacraft-labs"
    check r0.revision == "phase-2"  # override, NOT the project default
    check r0.vcs == "git"
    check r0.stability == "tracked"
    check r0.fragmentPath == root / "repos" / "reprobuild.toml"

    # ---- fragment 2: relies on every default the project provides ----
    let r1 = resolved.repos[1]
    check r1.path == "runquota"
    check r1.remoteName == "metacraft-labs"  # project default
    check r1.fetchUrl == "https://github.com/metacraft-labs"
    check r1.revision == "main"  # project default
    check r1.vcs == "git"  # resolver default
    check r1.stability == "tracked"  # resolver default
    check r1.fragmentPath == root / "repos" / "runquota.toml"

    # ---- fragment 3: explicit remote (not the default), default revision ----
    let r2 = resolved.repos[2]
    check r2.path == "reprobuild-cmake"
    check r2.remoteName == "github"  # explicit, overriding the default
    check r2.fetchUrl == "https://github.com"
    check r2.revision == "main"  # project default
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
default_revision = "main"
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

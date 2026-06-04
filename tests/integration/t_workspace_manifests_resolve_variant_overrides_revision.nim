## M7 — `resolveVariant` composes a `variants/<v>.toml` on top of a
## base project: extra `includes` are appended in source order with
## remote / revision defaults resolved against the BASE project's
## tables, and each `[[override]]` mutates the matching `ResolvedRepo`
## by exact `fragmentPath` equality. The return value is a
## `ResolvedProject` indistinguishable downstream from a non-variant
## resolution except for `projectName` (variant's name) and
## `projectFile` (variant's path).
##
## Every case builds its own scratch manifest-repo-shaped tempdir:
##
##   manifest_root/
##     projects/reprobuild.toml
##     variants/reprobuild-with-nim-devel.toml
##     repos/reprobuild.toml
##     repos/runquota.toml
##     repos/nim-everywhere.toml
##     repos/extra-component.toml         (only used by some cases)

import std/[os, strutils, tempfiles, unittest]

import repro_workspace_manifests

const projectBaseToml = """
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
  "repos/nim-everywhere.toml",
]
"""

const repoReprobuildToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "reprobuild"
path = "reprobuild"
remote = "metacraft-labs"
"""

const repoRunquotaToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "runquota"
path = "runquota"
"""

const repoNimEverywhereToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "nim-everywhere"
path = "nim-everywhere"
remote = "metacraft-labs"
"""

const repoExtraComponentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "extra-component"
path = "extra-component"
remote = "github"
"""

# Variant 1: overrides `nim-everywhere`'s revision to `devel`.
const variantRevisionOverrideToml = """
schema = "reprobuild.workspace.variant.v1"

[variant]
name = "reprobuild-with-nim-devel"
base = "projects/reprobuild.toml"

[[override]]
fragment = "repos/nim-everywhere.toml"
revision = "devel"
"""

# Variant 2: adds an extra include but no overrides.
const variantExtraIncludeToml = """
schema = "reprobuild.workspace.variant.v1"

[variant]
name = "reprobuild-with-extra"
base = "projects/reprobuild.toml"

includes = [
  "repos/extra-component.toml",
]
"""

# Variant 3: override targets a fragment the base doesn't include and
# the variant doesn't add.
const variantUnknownFragmentToml = """
schema = "reprobuild.workspace.variant.v1"

[variant]
name = "reprobuild-with-bogus-override"
base = "projects/reprobuild.toml"

[[override]]
fragment = "repos/does-not-exist.toml"
revision = "devel"
"""

# Variant 4: base path escapes the manifest root.
const variantEscapingBaseToml = """
schema = "reprobuild.workspace.variant.v1"

[variant]
name = "reprobuild-escaping"
base = "../escape/projects/foo.toml"
"""

# Variant 5: override sets `remote` to a name the base project does
# not declare.
const variantUnknownRemoteToml = """
schema = "reprobuild.workspace.variant.v1"

[variant]
name = "reprobuild-with-bogus-remote"
base = "projects/reprobuild.toml"

[[override]]
fragment = "repos/nim-everywhere.toml"
remote = "doesnotexist"
"""

# Variant 6: trivial variant — same base, no extras, no overrides.
const variantTrivialToml = """
schema = "reprobuild.workspace.variant.v1"

[variant]
name = "reprobuild-trivial"
base = "projects/reprobuild.toml"
"""

proc buildManifestRoot(): string =
  result = createTempDir("reprobuild-m7-resolve-variant-", "")
  createDir(result / "projects")
  createDir(result / "repos")
  createDir(result / "variants")

proc writeBaseFixture(root: string) =
  ## Write the canonical base project + the three base-referenced
  ## repo fragments. Cases that need the extra-component fragment
  ## write it themselves.
  writeFile(root / "projects" / "reprobuild.toml", projectBaseToml)
  writeFile(root / "repos" / "reprobuild.toml", repoReprobuildToml)
  writeFile(root / "repos" / "runquota.toml", repoRunquotaToml)
  writeFile(root / "repos" / "nim-everywhere.toml", repoNimEverywhereToml)

suite "M7 — resolveVariant against a metacraft-shaped fixture":

  test "test_m7_resolve_variant_happy_path_revision_override":
    let root = buildManifestRoot()
    writeBaseFixture(root)
    let variantFile =
      root / "variants" / "reprobuild-with-nim-devel.toml"
    writeFile(variantFile, variantRevisionOverrideToml)

    let resolved = resolveVariant(variantFile)

    # ---- variant-owned facts ----
    check resolved.projectName == "reprobuild-with-nim-devel"
    check resolved.projectFile == variantFile

    # ---- base-inherited facts ----
    check resolved.defaultRevision == "main"
    check resolved.trunk == "main"
    check resolved.repos.len == 3

    # ---- source order preservation ----
    check resolved.repos[0].name == "reprobuild"
    check resolved.repos[1].name == "runquota"
    check resolved.repos[2].name == "nim-everywhere"

    # ---- fragment 1: untouched by the override ----
    let r0 = resolved.repos[0]
    check r0.path == "reprobuild"
    check r0.remoteName == "metacraft-labs"
    check r0.fetchUrl == "https://github.com/metacraft-labs"
    check r0.revision == "main"  # base's default
    check r0.vcs == "git"
    check r0.stability == "tracked"
    check r0.fragmentPath == root / "repos" / "reprobuild.toml"

    # ---- fragment 2: untouched by the override ----
    let r1 = resolved.repos[1]
    check r1.path == "runquota"
    check r1.remoteName == "metacraft-labs"  # project default
    check r1.fetchUrl == "https://github.com/metacraft-labs"
    check r1.revision == "main"
    check r1.fragmentPath == root / "repos" / "runquota.toml"

    # ---- fragment 3: revision REWRITTEN by the override ----
    let r2 = resolved.repos[2]
    check r2.path == "nim-everywhere"
    check r2.remoteName == "metacraft-labs"  # unchanged
    check r2.fetchUrl == "https://github.com/metacraft-labs"
    check r2.revision == "devel"  # OVERRIDE applied; was "main" pre-variant
    check r2.fragmentPath == root / "repos" / "nim-everywhere.toml"

  test "test_m7_resolve_variant_extra_include_appended":
    let root = buildManifestRoot()
    writeBaseFixture(root)
    writeFile(root / "repos" / "extra-component.toml",
              repoExtraComponentToml)
    let variantFile =
      root / "variants" / "reprobuild-with-extra.toml"
    writeFile(variantFile, variantExtraIncludeToml)

    let resolved = resolveVariant(variantFile)

    # The base supplies three repos in order. The variant's extra
    # include lands at index 3 (the END of the list).
    check resolved.repos.len == 4
    check resolved.repos[0].name == "reprobuild"
    check resolved.repos[1].name == "runquota"
    check resolved.repos[2].name == "nim-everywhere"

    let extra = resolved.repos[3]
    check extra.name == "extra-component"
    check extra.path == "extra-component"
    # The extra include uses `remote = "github"`. That remote name is
    # declared in the BASE project's [[remote]] table, so the fetch URL
    # MUST be resolved from there.
    check extra.remoteName == "github"
    check extra.fetchUrl == "https://github.com"
    check extra.revision == "main"  # base's default
    check extra.vcs == "git"
    check extra.stability == "tracked"
    check extra.fragmentPath == root / "repos" / "extra-component.toml"

  test "test_m7_resolve_variant_override_unknown_fragment":
    let root = buildManifestRoot()
    writeBaseFixture(root)
    let variantFile =
      root / "variants" / "reprobuild-with-bogus-override.toml"
    writeFile(variantFile, variantUnknownFragmentToml)

    var raised = false
    try:
      discard resolveVariant(variantFile)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.path == variantFile
      check e.keyPath == "override[0].fragment"
      check e.expectedSchema == "reprobuild.workspace.variant.v1"
      # Diagnostic must name the unknown fragment path verbatim.
      check "repos/does-not-exist.toml" in e.innerMessage
    check raised

  test "test_m7_resolve_variant_base_path_escapes_root":
    let root = buildManifestRoot()
    writeBaseFixture(root)
    let variantFile =
      root / "variants" / "reprobuild-escaping.toml"
    writeFile(variantFile, variantEscapingBaseToml)

    var raised = false
    try:
      discard resolveVariant(variantFile)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.path == variantFile
      check e.keyPath == "variant.base"
      check e.expectedSchema == "reprobuild.workspace.variant.v1"
      # The diagnostic must reject the path BEFORE any read is
      # attempted, and must name the offending raw string.
      check "../escape/projects/foo.toml" in e.innerMessage
      check "escapes the manifest root" in e.innerMessage
    check raised

  test "test_m7_resolve_variant_override_unknown_remote":
    let root = buildManifestRoot()
    writeBaseFixture(root)
    let variantFile =
      root / "variants" / "reprobuild-with-bogus-remote.toml"
    writeFile(variantFile, variantUnknownRemoteToml)

    var raised = false
    try:
      discard resolveVariant(variantFile)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.path == variantFile
      check e.keyPath == "override[0].remote"
      check e.expectedSchema == "reprobuild.workspace.variant.v1"
      # Diagnostic must name the unresolvable remote name.
      check "doesnotexist" in e.innerMessage
    check raised

  test "test_m7_resolve_variant_indistinguishable_from_resolve_project":
    let root = buildManifestRoot()
    writeBaseFixture(root)
    let projectFile = root / "projects" / "reprobuild.toml"
    let variantFile = root / "variants" / "reprobuild-trivial.toml"
    writeFile(variantFile, variantTrivialToml)

    let asProject = resolveProject(projectFile)
    let asVariant = resolveVariant(variantFile)

    # `projectFile` and `projectName` legitimately differ.
    check asProject.projectFile == projectFile
    check asVariant.projectFile == variantFile
    check asProject.projectName == "reprobuild"
    check asVariant.projectName == "reprobuild-trivial"

    # Everything else MUST be identical: a trivial variant (no extras,
    # no overrides) is by construction the same workspace as its base.
    check asProject.defaultRevision == asVariant.defaultRevision
    check asProject.trunk == asVariant.trunk
    check asProject.repos.len == asVariant.repos.len
    for i in 0 ..< asProject.repos.len:
      check asProject.repos[i].name == asVariant.repos[i].name
      check asProject.repos[i].path == asVariant.repos[i].path
      check asProject.repos[i].remoteName == asVariant.repos[i].remoteName
      check asProject.repos[i].fetchUrl == asVariant.repos[i].fetchUrl
      check asProject.repos[i].revision == asVariant.repos[i].revision
      check asProject.repos[i].vcs == asVariant.repos[i].vcs
      check asProject.repos[i].stability == asVariant.repos[i].stability
      check asProject.repos[i].fragmentPath ==
        asVariant.repos[i].fragmentPath

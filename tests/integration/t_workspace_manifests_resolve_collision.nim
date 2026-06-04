## M6 — `resolveProject` correctly handles the
## `accounting` / `accounting-blocksense` dual-fragment pattern, where two
## different fragments declare the SAME `repo.name` value but distinct
## `path` and `remote` values. The resolver MUST emit both repos as
## separate `ResolvedRepo` entries and MUST NOT deduplicate by name.
##
## Also covers the negative case: when a fixture genuinely repeats the
## same `(name, path, remote)` triple, the resolver rejects it with a
## structured diagnostic.

import std/[os, strutils, tempfiles, unittest]

import repro_workspace_manifests

const projectAccountingToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "accounting"
default_revision = "main"

[[remote]]
name = "metacraft-labs"
fetch = "https://github.com/metacraft-labs"

[[remote]]
name = "blocksense-network"
fetch = "https://github.com/blocksense-network"

includes = [
  "repos/accounting.toml",
  "repos/accounting-blocksense.toml",
]
"""

# Fragment 1: the metacraft "accounting" checkout. `repo.name = "accounting"`,
# checked out at `metacraft/`, remote = `metacraft-labs`.
const repoAccountingToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "accounting"
path = "metacraft"
remote = "metacraft-labs"
"""

# Fragment 2: the blocksense "accounting" checkout. SAME `repo.name`,
# different path AND remote. This is the documented dual-fragment pattern.
const repoAccountingBlocksenseToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "accounting"
path = "blocksense"
remote = "blocksense-network"
"""

# Project variant where the SAME fragment is listed twice. Drives the
# genuine-duplicate diagnostic case.
const projectDuplicateIncludeToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "accounting"
default_revision = "main"

[[remote]]
name = "metacraft-labs"
fetch = "https://github.com/metacraft-labs"

[[remote]]
name = "blocksense-network"
fetch = "https://github.com/blocksense-network"

includes = [
  "repos/accounting.toml",
  "repos/accounting-blocksense.toml",
  "repos/accounting.toml",
]
"""

proc buildManifestRoot(): string =
  result = createTempDir("reprobuild-m6-resolve-collision-", "")
  createDir(result / "projects")
  createDir(result / "repos")

proc writeFixture(root: string) =
  writeFile(root / "projects" / "accounting.toml", projectAccountingToml)
  writeFile(root / "repos" / "accounting.toml", repoAccountingToml)
  writeFile(root / "repos" / "accounting-blocksense.toml",
            repoAccountingBlocksenseToml)

suite "M6 — resolveProject dual-fragment collision handling":

  test "test_m6_resolve_collision_distinct_path_and_remote":
    let root = buildManifestRoot()
    writeFixture(root)
    let projectFile = root / "projects" / "accounting.toml"

    let resolved = resolveProject(projectFile)
    check resolved.projectName == "accounting"
    check resolved.repos.len == 2

    # Both repos share the `repo.name == "accounting"` value but the
    # resolver emits them as DISTINCT `ResolvedRepo` entries because
    # their `path` AND `remoteName` differ.
    check resolved.repos[0].name == "accounting"
    check resolved.repos[1].name == "accounting"

    # ---- metacraft side ----
    check resolved.repos[0].path == "metacraft"
    check resolved.repos[0].remoteName == "metacraft-labs"
    check resolved.repos[0].fetchUrl == "https://github.com/metacraft-labs"
    check resolved.repos[0].revision == "main"  # project default
    check resolved.repos[0].fragmentPath ==
      root / "repos" / "accounting.toml"

    # ---- blocksense side ----
    check resolved.repos[1].path == "blocksense"
    check resolved.repos[1].remoteName == "blocksense-network"
    check resolved.repos[1].fetchUrl ==
      "https://github.com/blocksense-network"
    check resolved.repos[1].revision == "main"
    check resolved.repos[1].fragmentPath ==
      root / "repos" / "accounting-blocksense.toml"

  test "test_m6_resolve_collision_genuine_duplicate_rejected":
    let root = buildManifestRoot()
    writeFixture(root)
    # Swap in the duplicate-include variant.
    writeFile(root / "projects" / "accounting.toml",
              projectDuplicateIncludeToml)
    let projectFile = root / "projects" / "accounting.toml"

    var raised = false
    try:
      discard resolveProject(projectFile)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.path == projectFile
      # The third include (index 2) is the genuine duplicate; the
      # diagnostic points at it and back-references the first
      # appearance at index 0.
      check e.keyPath == "includes[2]"
      check e.expectedSchema == "reprobuild.workspace.project.v1"
      check "duplicate repo" in e.innerMessage
      check "accounting" in e.innerMessage
      check "metacraft" in e.innerMessage
      check "metacraft-labs" in e.innerMessage
      check "includes[0]" in e.innerMessage
    check raised

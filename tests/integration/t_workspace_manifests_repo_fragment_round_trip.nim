## M5 — `repos/<repo>.toml` round-trip through the workspace manifest reader.
##
## Covers the four cases the milestone names:
##
##   1. Happy path — a canonical TOML fixture mirroring the
##      Workspace-Manifests.md §"repos/<repo>.toml" example parses into
##      a `RepoFragment` with every documented field populated as expected.
##   2. Unknown-key rejection — a TOML with one extra top-level key (NOT
##      under `[extensions]`) raises `WorkspaceManifestParseError` whose
##      `keyPath` names the offending key.
##   3. Schema-version mismatch — a TOML whose `schema` value is a
##      different version (`reprobuild.workspace.repo.v2`) raises
##      `WorkspaceManifestParseError` with `keyPath = "schema"`,
##      `expectedSchema = "reprobuild.workspace.repo.v1"`, and
##      `observedSchema = "reprobuild.workspace.repo.v2"`.
##   4. Missing required key — a TOML that omits `repo.path` raises
##      `WorkspaceManifestParseError` whose `keyPath` names the missing key.
##   5. (Bonus) An `[extensions]` table with arbitrary forward-compat keys
##      parses cleanly and the extensions table is reachable on the record.
##
## Fixtures live as `const` strings inside this file and are written via
## `createTempDir` + `writeFile` so the read path traverses the real
## filesystem.

import std/[options, os, tempfiles, unittest]

import repro_workspace_manifests

const happyToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "reprobuild"
path = "reprobuild"
remote = "metacraft-labs"
revision = "main"
vcs = "git"
stability = "tracked"
"""

const unknownKeyToml = """
schema = "reprobuild.workspace.repo.v1"
garbage = "bogus"

[repo]
name = "x"
path = "y"
"""

const wrongSchemaToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "x"
path = "y"
"""

const missingPathToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "x"
"""

const extensionsToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "x"
path = "y"

[extensions]
future_key = "forward-compat"
"""

# RA-18 — copyfile/linkfile (inline-table arrays) + groups.
const ra18Toml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib"
path = "lib"
groups = ["default", "tools"]
copyfile = [{ src = "build/config.default.toml", dest = "config.toml" }]
linkfile = [{ src = "scripts/dev.sh", dest = "dev.sh" }]
"""

proc writeFixture(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

suite "M5 — RepoFragment round-trip":
  let dir = createTempDir("reprobuild-m5-repo-", "")

  test "happy path populates every documented field":
    let path = writeFixture(dir, "repo-happy.toml", happyToml)
    let r = readRepoFragment(path)
    check r.schema == "reprobuild.workspace.repo.v1"
    check r.repo.name == "reprobuild"
    check r.repo.path == "reprobuild"
    check r.repo.remote.isSome
    check r.repo.remote.get() == "metacraft-labs"
    check r.repo.revision.isSome
    check r.repo.revision.get() == "main"
    check r.repo.vcs.isSome
    check r.repo.vcs.get() == "git"
    check r.repo.stability.isSome
    check r.repo.stability.get() == "tracked"

  test "unknown top-level key is rejected with structured diagnostic":
    let path = writeFixture(dir, "repo-unknown.toml", unknownKeyToml)
    var raised = false
    try:
      discard readRepoFragment(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.path == path
      check e.keyPath == "garbage"
      check e.expectedSchema == "reprobuild.workspace.repo.v1"
    check raised

  test "schema-version mismatch surfaces expected/observed pair":
    let path = writeFixture(dir, "repo-wrong-schema.toml", wrongSchemaToml)
    var raised = false
    try:
      discard readRepoFragment(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.path == path
      check e.keyPath == "schema"
      check e.expectedSchema == "reprobuild.workspace.repo.v1"
      check e.observedSchema == "reprobuild.workspace.repo.v2"
    check raised

  test "missing required key is reported":
    let path = writeFixture(dir, "repo-missing-path.toml", missingPathToml)
    var raised = false
    try:
      discard readRepoFragment(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.path == path
      check e.keyPath == "repo.path"
      check e.expectedSchema == "reprobuild.workspace.repo.v1"
    check raised

  test "[extensions] table is allowed through strict mode":
    let path = writeFixture(dir, "repo-extensions.toml", extensionsToml)
    let r = readRepoFragment(path)
    check r.repo.name == "x"
    check r.extensions.isPresent

  test "RA-18 copyfile/linkfile/groups round-trip":
    let path = writeFixture(dir, "repo-ra18.toml", ra18Toml)
    let r = readRepoFragment(path)
    check r.repo.groups == @["default", "tools"]
    check r.repo.copyfile.len == 1
    check r.repo.copyfile[0].src == "build/config.default.toml"
    check r.repo.copyfile[0].dest == "config.toml"
    check r.repo.linkfile.len == 1
    check r.repo.linkfile[0].src == "scripts/dev.sh"
    check r.repo.linkfile[0].dest == "dev.sh"

  test "a fragment WITHOUT RA-18 fields leaves them empty (no regression)":
    let path = writeFixture(dir, "repo-happy2.toml", happyToml)
    let r = readRepoFragment(path)
    check r.repo.copyfile.len == 0
    check r.repo.linkfile.len == 0
    check r.repo.groups.len == 0

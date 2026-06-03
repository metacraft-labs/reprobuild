## M5 — `projects/<project>.toml` round-trip through the workspace manifest
## reader. See `t_workspace_manifests_repo_fragment_round_trip.nim` for the
## five-case template; this file is the project-schema analogue.

import std/[options, os, tempfiles, unittest]

import repro_workspace_manifests

const happyToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "reprobuild"
default_revision = "main"
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
]
"""

const unknownKeyToml = """
schema = "reprobuild.workspace.project.v1"
mystery_field = 42

[project]
name = "x"
"""

const wrongSchemaToml = """
schema = "reprobuild.workspace.project.v2"

[project]
name = "x"
"""

const missingProjectNameToml = """
schema = "reprobuild.workspace.project.v1"

[project]
default_revision = "main"
"""

const extensionsToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "x"

[extensions]
shells = "future"
"""

proc writeFixture(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

suite "M5 — ProjectManifest round-trip":
  let dir = createTempDir("reprobuild-m5-project-", "")

  test "happy path populates remotes and includes":
    let path = writeFixture(dir, "project-happy.toml", happyToml)
    let p = readProjectManifest(path)
    check p.schema == "reprobuild.workspace.project.v1"
    check p.project.name == "reprobuild"
    check p.project.default_revision.isSome
    check p.project.default_revision.get() == "main"
    check p.project.trunk.isSome
    check p.project.trunk.get() == "main"
    check p.remote.len == 2
    check p.remote[0].name == "metacraft-labs"
    check p.remote[0].fetch == "https://github.com/metacraft-labs"
    check p.remote[1].name == "github"
    check p.remote[1].fetch == "https://github.com"
    check p.includes.len == 2
    check p.includes[0] == "repos/reprobuild.toml"
    check p.includes[1] == "repos/runquota.toml"

  test "unknown top-level key is rejected":
    let path = writeFixture(dir, "project-unknown.toml", unknownKeyToml)
    var raised = false
    try:
      discard readProjectManifest(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.path == path
      check e.keyPath == "mystery_field"
      check e.expectedSchema == "reprobuild.workspace.project.v1"
    check raised

  test "schema-version mismatch reports observed v2":
    let path = writeFixture(dir, "project-wrong-schema.toml", wrongSchemaToml)
    var raised = false
    try:
      discard readProjectManifest(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "schema"
      check e.expectedSchema == "reprobuild.workspace.project.v1"
      check e.observedSchema == "reprobuild.workspace.project.v2"
    check raised

  test "missing project.name is reported":
    let path = writeFixture(dir, "project-missing-name.toml",
                            missingProjectNameToml)
    var raised = false
    try:
      discard readProjectManifest(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "project.name"
    check raised

  test "[extensions] passes through strict mode":
    let path = writeFixture(dir, "project-extensions.toml", extensionsToml)
    let p = readProjectManifest(path)
    check p.project.name == "x"
    check p.extensions.isPresent

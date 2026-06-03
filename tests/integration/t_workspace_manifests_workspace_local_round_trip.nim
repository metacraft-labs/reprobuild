## M5 — `<workspace-root>/.repro/workspace.toml` round-trip.

import std/[options, os, tempfiles, unittest]

import repro_workspace_manifests

const happyToml = """
schema = "reprobuild.workspace.local.v1"

[workspace]
project = "reprobuild"
branch = "main"

[[manifest]]
url = "https://github.com/metacraft-labs/metacraft-manifests"
visibility = "public"
branch = "main"

[[manifest]]
url = "git@github.com:metacraft-labs/internal-manifests"
visibility = "org"
branch = "main"

[[manifest]]
local_path = ".repo/manifests-personal"
visibility = "personal"
"""

const unknownKeyToml = """
schema = "reprobuild.workspace.local.v1"
ghost = "field"

[workspace]
project = "x"
"""

const wrongSchemaToml = """
schema = "reprobuild.workspace.local.v2"

[workspace]
project = "x"
"""

const missingWorkspaceProjectToml = """
schema = "reprobuild.workspace.local.v1"

[workspace]
branch = "main"
"""

const extensionsToml = """
schema = "reprobuild.workspace.local.v1"

[workspace]
project = "x"

[extensions]
hint = "future"
"""

proc writeFixture(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

suite "M5 — WorkspaceLocal round-trip":
  let dir = createTempDir("reprobuild-m5-workspace-local-", "")

  test "happy path populates workspace metadata and manifest layers":
    let path = writeFixture(dir, "workspace-happy.toml", happyToml)
    let wl = readWorkspaceLocal(path)
    check wl.schema == "reprobuild.workspace.local.v1"
    check wl.workspace.project == "reprobuild"
    check wl.workspace.branch.isSome
    check wl.workspace.branch.get() == "main"
    check wl.manifest.len == 3
    check wl.manifest[0].url.isSome
    check wl.manifest[0].url.get() ==
      "https://github.com/metacraft-labs/metacraft-manifests"
    check wl.manifest[0].visibility == "public"
    check wl.manifest[0].branch.isSome
    check wl.manifest[0].branch.get() == "main"
    check wl.manifest[2].url.isNone
    check wl.manifest[2].local_path.isSome
    check wl.manifest[2].local_path.get() == ".repo/manifests-personal"
    check wl.manifest[2].visibility == "personal"

  test "unknown top-level key is rejected":
    let path = writeFixture(dir, "workspace-unknown.toml", unknownKeyToml)
    var raised = false
    try:
      discard readWorkspaceLocal(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "ghost"
    check raised

  test "schema-version mismatch reports observed v2":
    let path = writeFixture(dir, "workspace-wrong-schema.toml",
                            wrongSchemaToml)
    var raised = false
    try:
      discard readWorkspaceLocal(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "schema"
      check e.expectedSchema == "reprobuild.workspace.local.v1"
      check e.observedSchema == "reprobuild.workspace.local.v2"
    check raised

  test "missing workspace.project is reported":
    let path = writeFixture(dir, "workspace-missing-project.toml",
                            missingWorkspaceProjectToml)
    var raised = false
    try:
      discard readWorkspaceLocal(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "workspace.project"
    check raised

  test "[extensions] passes through strict mode":
    let path = writeFixture(dir, "workspace-extensions.toml", extensionsToml)
    let wl = readWorkspaceLocal(path)
    check wl.workspace.project == "x"
    check wl.extensions.isPresent

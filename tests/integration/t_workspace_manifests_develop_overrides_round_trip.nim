## M5 — `<workspace-root>/.repro/develop-overrides.toml` round-trip.

import std/[options, os, tempfiles, unittest]

import repro_workspace_manifests

const happyToml = """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "cairo"
local_path = "../cairo"
state = "editable"
created_at = "2026-06-02T10:14:33Z"
provenance = "repro develop cairo"

[[override]]
package = "stint"
local_path = "../stint"
state = "pinned"
created_at = "2026-06-02T11:00:00Z"
"""

const unknownKeyToml = """
schema = "reprobuild.workspace.develop-overrides.v1"
random_top = "bogus"

[[override]]
package = "x"
local_path = "x"
state = "editable"
created_at = "2026-06-02T10:14:33Z"
"""

const wrongSchemaToml = """
schema = "reprobuild.workspace.develop-overrides.v2"

[[override]]
package = "x"
local_path = "x"
state = "editable"
created_at = "2026-06-02T10:14:33Z"
"""

const missingPackageToml = """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
local_path = "x"
state = "editable"
created_at = "2026-06-02T10:14:33Z"
"""

const extensionsToml = """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "x"
local_path = "x"
state = "editable"
created_at = "2026-06-02T10:14:33Z"

[extensions]
note = "future"
"""

proc writeFixture(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

suite "M5 — DevelopOverrides round-trip":
  let dir = createTempDir("reprobuild-m5-develop-overrides-", "")

  test "happy path populates every override entry":
    let path = writeFixture(dir, "develop-overrides-happy.toml", happyToml)
    let d = readDevelopOverrides(path)
    check d.schema == "reprobuild.workspace.develop-overrides.v1"
    check d.`override`.len == 2
    check d.`override`[0].package == "cairo"
    check d.`override`[0].local_path == "../cairo"
    check d.`override`[0].state == "editable"
    check d.`override`[0].created_at == "2026-06-02T10:14:33Z"
    check d.`override`[0].provenance.isSome
    check d.`override`[0].provenance.get() == "repro develop cairo"
    check d.`override`[1].package == "stint"
    check d.`override`[1].state == "pinned"
    check d.`override`[1].provenance.isNone

  test "unknown top-level key is rejected":
    let path = writeFixture(dir, "develop-overrides-unknown.toml",
                            unknownKeyToml)
    var raised = false
    try:
      discard readDevelopOverrides(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "random_top"
    check raised

  test "schema-version mismatch reports observed v2":
    let path = writeFixture(dir, "develop-overrides-wrong-schema.toml",
                            wrongSchemaToml)
    var raised = false
    try:
      discard readDevelopOverrides(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "schema"
      check e.expectedSchema ==
        "reprobuild.workspace.develop-overrides.v1"
      check e.observedSchema ==
        "reprobuild.workspace.develop-overrides.v2"
    check raised

  test "missing override.package is reported":
    let path = writeFixture(dir, "develop-overrides-missing-package.toml",
                            missingPackageToml)
    var raised = false
    try:
      discard readDevelopOverrides(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "override[0].package"
    check raised

  test "[extensions] passes through strict mode":
    let path = writeFixture(dir, "develop-overrides-extensions.toml",
                            extensionsToml)
    let d = readDevelopOverrides(path)
    check d.`override`.len == 1
    check d.extensions.isPresent

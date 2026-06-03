## M5 — `variants/<project>-<variant>.toml` round-trip.

import std/[options, os, tempfiles, unittest]

import repro_workspace_manifests

const happyToml = """
schema = "reprobuild.workspace.variant.v1"

[variant]
name = "reprobuild-with-nim-devel"
base = "projects/reprobuild.toml"

includes = [
  "repos/some-extra.toml",
]

[[override]]
fragment = "repos/nim-everywhere.toml"
revision = "devel"

[[override]]
fragment = "repos/runquota.toml"
remote = "metacraft-labs"
path = "runquota-alt"
"""

const unknownKeyToml = """
schema = "reprobuild.workspace.variant.v1"
stranger = "danger"

[variant]
name = "x"
base = "projects/x.toml"
"""

const wrongSchemaToml = """
schema = "reprobuild.workspace.variant.v2"

[variant]
name = "x"
base = "projects/x.toml"
"""

const missingBaseToml = """
schema = "reprobuild.workspace.variant.v1"

[variant]
name = "x"
"""

const extensionsToml = """
schema = "reprobuild.workspace.variant.v1"

[variant]
name = "x"
base = "projects/x.toml"

[extensions]
note = "future"
"""

proc writeFixture(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

suite "M5 — VariantManifest round-trip":
  let dir = createTempDir("reprobuild-m5-variant-", "")

  test "happy path populates includes and overrides":
    let path = writeFixture(dir, "variant-happy.toml", happyToml)
    let v = readVariantManifest(path)
    check v.schema == "reprobuild.workspace.variant.v1"
    check v.variant.name == "reprobuild-with-nim-devel"
    check v.variant.base == "projects/reprobuild.toml"
    check v.includes.len == 1
    check v.includes[0] == "repos/some-extra.toml"
    check v.`override`.len == 2
    check v.`override`[0].fragment == "repos/nim-everywhere.toml"
    check v.`override`[0].revision.isSome
    check v.`override`[0].revision.get() == "devel"
    check v.`override`[1].fragment == "repos/runquota.toml"
    check v.`override`[1].remote.isSome
    check v.`override`[1].remote.get() == "metacraft-labs"
    check v.`override`[1].path.isSome
    check v.`override`[1].path.get() == "runquota-alt"

  test "unknown top-level key is rejected":
    let path = writeFixture(dir, "variant-unknown.toml", unknownKeyToml)
    var raised = false
    try:
      discard readVariantManifest(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "stranger"
    check raised

  test "schema-version mismatch reports observed v2":
    let path = writeFixture(dir, "variant-wrong-schema.toml", wrongSchemaToml)
    var raised = false
    try:
      discard readVariantManifest(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "schema"
      check e.expectedSchema == "reprobuild.workspace.variant.v1"
      check e.observedSchema == "reprobuild.workspace.variant.v2"
    check raised

  test "missing variant.base is reported":
    let path = writeFixture(dir, "variant-missing-base.toml", missingBaseToml)
    var raised = false
    try:
      discard readVariantManifest(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "variant.base"
    check raised

  test "[extensions] passes through strict mode":
    let path = writeFixture(dir, "variant-extensions.toml", extensionsToml)
    let v = readVariantManifest(path)
    check v.variant.name == "x"
    check v.extensions.isPresent

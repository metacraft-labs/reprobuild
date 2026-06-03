## M5 — `snapshots/<name>.toml` round-trip. Snapshots share the lock shape
## with a `[snapshot]` header (carrying the `name` key) instead of `[lock]`.

import std/[options, os, tempfiles, unittest]

import repro_workspace_manifests

const happyToml = """
schema = "reprobuild.workspace.snapshot.v1"

[snapshot]
name = "release-2026-06"
project = "reprobuild"
created_at = "2026-06-02T10:14:33Z"
created_by = "alice"
workspace_branch = "release/2026-06"

[[repo]]
name = "reprobuild"
path = "reprobuild"
remote = "metacraft-labs"
revision = "a858633c1f1e6b6e6b1f1c5e6a1f1c5e6a1f1c5e"
"""

const unknownKeyToml = """
schema = "reprobuild.workspace.snapshot.v1"
extra_top = "x"

[snapshot]
name = "x"
project = "x"
created_at = "2026-06-02T10:14:33Z"
"""

const wrongSchemaToml = """
schema = "reprobuild.workspace.snapshot.v2"

[snapshot]
name = "x"
project = "x"
created_at = "2026-06-02T10:14:33Z"
"""

const missingSnapshotNameToml = """
schema = "reprobuild.workspace.snapshot.v1"

[snapshot]
project = "x"
created_at = "2026-06-02T10:14:33Z"
"""

const extensionsToml = """
schema = "reprobuild.workspace.snapshot.v1"

[snapshot]
name = "x"
project = "x"
created_at = "2026-06-02T10:14:33Z"

[extensions]
note = "future"
"""

proc writeFixture(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

suite "M5 — Snapshot round-trip":
  let dir = createTempDir("reprobuild-m5-snapshot-", "")

  test "happy path populates snapshot header and pins":
    let path = writeFixture(dir, "snapshot-happy.toml", happyToml)
    let snap = readSnapshot(path)
    check snap.schema == "reprobuild.workspace.snapshot.v1"
    check snap.snapshot.name == "release-2026-06"
    check snap.snapshot.project == "reprobuild"
    check snap.snapshot.created_at == "2026-06-02T10:14:33Z"
    check snap.snapshot.created_by.isSome
    check snap.snapshot.created_by.get() == "alice"
    check snap.snapshot.workspace_branch.isSome
    check snap.snapshot.workspace_branch.get() == "release/2026-06"
    check snap.repo.len == 1
    check snap.repo[0].name == "reprobuild"
    check snap.repo[0].revision ==
      "a858633c1f1e6b6e6b1f1c5e6a1f1c5e6a1f1c5e"

  test "unknown top-level key is rejected":
    let path = writeFixture(dir, "snapshot-unknown.toml", unknownKeyToml)
    var raised = false
    try:
      discard readSnapshot(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "extra_top"
    check raised

  test "schema-version mismatch reports observed v2":
    let path = writeFixture(dir, "snapshot-wrong-schema.toml", wrongSchemaToml)
    var raised = false
    try:
      discard readSnapshot(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "schema"
      check e.expectedSchema == "reprobuild.workspace.snapshot.v1"
      check e.observedSchema == "reprobuild.workspace.snapshot.v2"
    check raised

  test "missing snapshot.name is reported":
    let path = writeFixture(dir, "snapshot-missing-name.toml",
                            missingSnapshotNameToml)
    var raised = false
    try:
      discard readSnapshot(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "snapshot.name"
    check raised

  test "[extensions] passes through strict mode":
    let path = writeFixture(dir, "snapshot-extensions.toml", extensionsToml)
    let snap = readSnapshot(path)
    check snap.snapshot.name == "x"
    check snap.extensions.isPresent

## M5 — `locks/<project>/<sha>.toml` round-trip.

import std/[options, os, tempfiles, unittest]

import repro_workspace_manifests

const happyToml = """
schema = "reprobuild.workspace.lock.v1"

[lock]
project = "reprobuild"
created_at = "2026-06-02T10:14:33Z"
created_by = "repro workspace lock"
workspace_branch = "main"

[[repo]]
name = "reprobuild"
path = "reprobuild"
remote = "metacraft-labs"
revision = "a858633c1f1e6b6e6b1f1c5e6a1f1c5e6a1f1c5e"
branch = "main"

[[repo]]
name = "runquota"
path = "runquota"
remote = "metacraft-labs"
revision = "0a3a0d6b9c1f1e6b6e6b1f1c5e6a1f1c5e6a1f1c"
"""

const unknownKeyToml = """
schema = "reprobuild.workspace.lock.v1"
mystery = "field"

[lock]
project = "x"
created_at = "2026-06-02T10:14:33Z"
"""

const wrongSchemaToml = """
schema = "reprobuild.workspace.lock.v2"

[lock]
project = "x"
created_at = "2026-06-02T10:14:33Z"
"""

const missingProjectToml = """
schema = "reprobuild.workspace.lock.v1"

[lock]
created_at = "2026-06-02T10:14:33Z"
"""

const extensionsToml = """
schema = "reprobuild.workspace.lock.v1"

[lock]
project = "x"
created_at = "2026-06-02T10:14:33Z"

[extensions]
checksum = "deadbeef"
"""

proc writeFixture(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

suite "M5 — Lock round-trip":
  let dir = createTempDir("reprobuild-m5-lock-", "")

  test "happy path populates lock header and per-repo pins":
    let path = writeFixture(dir, "lock-happy.toml", happyToml)
    let lock = readLock(path)
    check lock.schema == "reprobuild.workspace.lock.v1"
    check lock.lock.project == "reprobuild"
    check lock.lock.created_at == "2026-06-02T10:14:33Z"
    check lock.lock.created_by.isSome
    check lock.lock.created_by.get() == "repro workspace lock"
    check lock.lock.workspace_branch.isSome
    check lock.lock.workspace_branch.get() == "main"
    check lock.repo.len == 2
    check lock.repo[0].name == "reprobuild"
    check lock.repo[0].path == "reprobuild"
    check lock.repo[0].remote == "metacraft-labs"
    check lock.repo[0].revision ==
      "a858633c1f1e6b6e6b1f1c5e6a1f1c5e6a1f1c5e"
    check lock.repo[0].branch.isSome
    check lock.repo[0].branch.get() == "main"
    check lock.repo[1].name == "runquota"
    check lock.repo[1].branch.isNone

  test "unknown top-level key is rejected":
    let path = writeFixture(dir, "lock-unknown.toml", unknownKeyToml)
    var raised = false
    try:
      discard readLock(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "mystery"
    check raised

  test "schema-version mismatch reports observed v2":
    let path = writeFixture(dir, "lock-wrong-schema.toml", wrongSchemaToml)
    var raised = false
    try:
      discard readLock(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "schema"
      check e.expectedSchema == "reprobuild.workspace.lock.v1"
      check e.observedSchema == "reprobuild.workspace.lock.v2"
    check raised

  test "missing lock.project is reported":
    let path = writeFixture(dir, "lock-missing-project.toml",
                            missingProjectToml)
    var raised = false
    try:
      discard readLock(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "lock.project"
    check raised

  test "[extensions] passes through strict mode":
    let path = writeFixture(dir, "lock-extensions.toml", extensionsToml)
    let lock = readLock(path)
    check lock.lock.project == "x"
    check lock.extensions.isPresent

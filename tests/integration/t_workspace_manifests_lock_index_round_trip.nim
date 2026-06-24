## Legacy `locks/<project>/index.toml` parser round-trip (back-compat).
##
## RA-1 (pilot `418f109`) DROPPED the shared lock index: the writer no
## longer emits `index.toml` and the "latest lock" lookup uses Git
## history over the per-repo lock subtree instead (see
## `t_workspace_lock_latest_resolves_via_git_history_per_repo`). The
## `readLockIndex` strict parser is intentionally RETAINED so older
## manifest history that still carries an `index.toml` can be read
## without erroring — RA-1 specifies such legacy files are "ignored and
## never updated", not that the parser is deleted. This test pins that
## back-compat parser behavior. The "no new index is written" guarantee
## is asserted in `t_workspace_lock_round_trips_through_resolver`.

import std/[os, tempfiles, unittest]

import repro_workspace_manifests

const happyToml = """
schema = "reprobuild.workspace.lock-index.v1"

[[entry]]
trigger_repo = "reprobuild"
trigger_sha = "a858633c1f1e6b6e6b1f1c5e6a1f1c5e6a1f1c5e"
lock_file = "locks/reprobuild/reprobuild-a858633c.toml"
created_at = "2026-06-02T10:14:33Z"

[[entry]]
trigger_repo = "runquota"
trigger_sha = "0a3a0d6b9c1f1e6b6e6b1f1c5e6a1f1c5e6a1f1c"
lock_file = "locks/reprobuild/runquota-0a3a0d6b.toml"
created_at = "2026-06-02T10:14:34Z"
"""

const unknownKeyToml = """
schema = "reprobuild.workspace.lock-index.v1"
totally_unexpected = 1

[[entry]]
trigger_repo = "x"
trigger_sha = "abc"
lock_file = "locks/x.toml"
created_at = "2026-06-02T10:14:33Z"
"""

const wrongSchemaToml = """
schema = "reprobuild.workspace.lock-index.v2"

[[entry]]
trigger_repo = "x"
trigger_sha = "abc"
lock_file = "locks/x.toml"
created_at = "2026-06-02T10:14:33Z"
"""

const missingLockFileToml = """
schema = "reprobuild.workspace.lock-index.v1"

[[entry]]
trigger_repo = "x"
trigger_sha = "abc"
created_at = "2026-06-02T10:14:33Z"
"""

const extensionsToml = """
schema = "reprobuild.workspace.lock-index.v1"

[[entry]]
trigger_repo = "x"
trigger_sha = "abc"
lock_file = "locks/x.toml"
created_at = "2026-06-02T10:14:33Z"

[extensions]
note = "future"
"""

proc writeFixture(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

suite "Legacy LockIndex parser round-trip (RA-1 back-compat)":
  let dir = createTempDir("reprobuild-m5-lock-index-", "")

  test "happy path populates each entry":
    let path = writeFixture(dir, "lock-index-happy.toml", happyToml)
    let idx = readLockIndex(path)
    check idx.schema == "reprobuild.workspace.lock-index.v1"
    check idx.entry.len == 2
    check idx.entry[0].trigger_repo == "reprobuild"
    check idx.entry[0].trigger_sha ==
      "a858633c1f1e6b6e6b1f1c5e6a1f1c5e6a1f1c5e"
    check idx.entry[0].lock_file ==
      "locks/reprobuild/reprobuild-a858633c.toml"
    check idx.entry[1].trigger_repo == "runquota"

  test "unknown top-level key is rejected":
    let path = writeFixture(dir, "lock-index-unknown.toml", unknownKeyToml)
    var raised = false
    try:
      discard readLockIndex(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "totally_unexpected"
    check raised

  test "schema-version mismatch reports observed v2":
    let path = writeFixture(dir, "lock-index-wrong-schema.toml",
                            wrongSchemaToml)
    var raised = false
    try:
      discard readLockIndex(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "schema"
      check e.expectedSchema == "reprobuild.workspace.lock-index.v1"
      check e.observedSchema == "reprobuild.workspace.lock-index.v2"
    check raised

  test "missing entry.lock_file is reported":
    let path = writeFixture(dir, "lock-index-missing-lock-file.toml",
                            missingLockFileToml)
    var raised = false
    try:
      discard readLockIndex(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "entry[0].lock_file"
    check raised

  test "[extensions] passes through strict mode":
    let path = writeFixture(dir, "lock-index-extensions.toml", extensionsToml)
    let idx = readLockIndex(path)
    check idx.entry.len == 1
    check idx.extensions.isPresent

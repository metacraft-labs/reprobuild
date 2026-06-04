## M20 — Develop-override metadata file round-trip.
##
## Exercises the new ``develop_overrides`` module: the workspace-rooted
## reader / writer that backs ``<workspaceRoot>/.repro/develop-overrides.toml``
## per ``reprobuild-specs/Workspace-Manifests.md`` §"Develop-Mode
## Override File". The cases here mirror the M13 ``workspace_branch``
## round-trip but for the M20 file shape:
##
##   1. Absent file reads as ``none`` (the common case for any
##      workspace that has not activated develop-mode for any package).
##   2. Two-entry write then read recovers exactly what was written.
##   3. Re-writing the same value is byte-identical (idempotency
##      property M22's CLI write path relies on).
##   4. Entries inserted in random order are emitted alphabetically.
##   5. The M5 strict reader rejects unknown top-level keys with the
##      structured ``WorkspaceManifestParseError`` shape.
##   6. ``addOverride`` followed by ``removeOverride`` for the same
##      package round-trips to a value equivalent to the original.
##
## This is a pure-library round-trip; no ``git`` and no compiled
## ``repro`` binary are involved.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests

proc sampleEntry(pkg, path, state, createdAt: string;
                 provenance = ""): DevelopOverrideEntry =
  result.package = pkg
  result.local_path = path
  result.state = state
  result.created_at = createdAt
  if provenance.len > 0:
    result.provenance = some(provenance)
  else:
    result.provenance = none(string)

suite "M20 — develop overrides round-trip through workspace metadata":

  test "test_m20_overrides_file_absent_reads_as_none":
    let workspaceRoot = createTempDir("repro-m20-absent-", "")
    defer: removeDir(workspaceRoot)

    # No ``.repro/develop-overrides.toml`` on disk — the reader returns
    # ``none`` cleanly. This is the steady state for any workspace that
    # has never activated develop-mode for any package, and M21 / M22
    # rely on it to skip the override lookup without a special case.
    check readDevelopOverridesFile(workspaceRoot).isNone
    check not fileExists(developOverridesPath(workspaceRoot))

  test "test_m20_overrides_round_trip_via_writer_and_reader":
    let workspaceRoot = createTempDir("repro-m20-round-trip-", "")
    defer: removeDir(workspaceRoot)

    var file = newDevelopOverrides()
    file = file.addOverride(sampleEntry(
      "cairo", "../cairo", "editable", "2026-06-02T10:14:33Z",
      provenance = "repro develop cairo"))
    file = file.addOverride(sampleEntry(
      "stint", "../stint", "pinned", "2026-06-02T11:00:00Z"))

    writeDevelopOverridesFile(workspaceRoot, file)

    let path = developOverridesPath(workspaceRoot)
    check fileExists(path)

    let reparsed = readDevelopOverridesFile(workspaceRoot)
    check reparsed.isSome
    let entries = listOverrides(reparsed.get())
    check entries.len == 2
    # Alphabetical: cairo before stint.
    check entries[0].package == "cairo"
    check entries[0].local_path == "../cairo"
    check entries[0].state == "editable"
    check entries[0].created_at == "2026-06-02T10:14:33Z"
    check entries[0].provenance.isSome
    check entries[0].provenance.get() == "repro develop cairo"
    check entries[1].package == "stint"
    check entries[1].local_path == "../stint"
    check entries[1].state == "pinned"
    check entries[1].created_at == "2026-06-02T11:00:00Z"
    check entries[1].provenance.isNone

    # findOverride locates the entry M21 will use for shadowing.
    let cairo = findOverride(reparsed.get(), "cairo")
    check cairo.isSome
    check cairo.get().local_path == "../cairo"
    let absent = findOverride(reparsed.get(), "does-not-exist")
    check absent.isNone

  test "test_m20_overrides_writer_is_byte_idempotent":
    let workspaceRoot = createTempDir("repro-m20-idempotent-", "")
    defer: removeDir(workspaceRoot)

    var file = newDevelopOverrides()
    file = file.addOverride(sampleEntry(
      "cairo", "../cairo", "editable", "2026-06-02T10:14:33Z",
      provenance = "repro develop cairo"))
    file = file.addOverride(sampleEntry(
      "stint", "../stint", "pinned", "2026-06-02T11:00:00Z"))

    writeDevelopOverridesFile(workspaceRoot, file)
    let firstBytes = readFile(developOverridesPath(workspaceRoot))

    # Re-running with the same value must produce a byte-identical
    # file (the serializer is deterministic). This is the property
    # the M22 CLI write path relies on so a no-op ``repro develop``
    # never churns the file.
    writeDevelopOverridesFile(workspaceRoot, file)
    let secondBytes = readFile(developOverridesPath(workspaceRoot))
    check firstBytes == secondBytes

    # Round-tripping through the reader then re-writing must ALSO be
    # byte-identical: that is the property that lets M23's
    # ``repro check`` re-emit the file after a structural sweep
    # without disturbing the on-disk shape.
    let reparsed = readDevelopOverridesFile(workspaceRoot).get()
    writeDevelopOverridesFile(workspaceRoot, reparsed)
    let thirdBytes = readFile(developOverridesPath(workspaceRoot))
    check firstBytes == thirdBytes

  test "test_m20_overrides_entries_are_alphabetically_sorted_on_write":
    let workspaceRoot = createTempDir("repro-m20-sorted-", "")
    defer: removeDir(workspaceRoot)

    # Insert in reverse alphabetical order — the writer must still
    # emit them alphabetically so the file shape is independent of
    # insertion order. This is the property that keeps freshly added
    # overrides from reshuffling existing ones unpredictably.
    var file = newDevelopOverrides()
    file = file.addOverride(sampleEntry(
      "zlib", "../zlib", "editable", "2026-06-02T12:00:00Z"))
    file = file.addOverride(sampleEntry(
      "alpha", "../alpha", "editable", "2026-06-02T12:00:01Z"))
    file = file.addOverride(sampleEntry(
      "mango", "../mango", "pinned", "2026-06-02T12:00:02Z"))

    writeDevelopOverridesFile(workspaceRoot, file)
    let reparsed = readDevelopOverridesFile(workspaceRoot).get()
    let entries = listOverrides(reparsed)
    check entries.len == 3
    check entries[0].package == "alpha"
    check entries[1].package == "mango"
    check entries[2].package == "zlib"

    # The raw TOML body must place the alpha block before mango before
    # zlib — verifying the on-disk byte order (not just the in-memory
    # reader output) is what catches a serializer that "sorts on read"
    # but emits insertion-order on write.
    let body = readFile(developOverridesPath(workspaceRoot))
    let alphaIdx = body.find("package = \"alpha\"")
    let mangoIdx = body.find("package = \"mango\"")
    let zlibIdx = body.find("package = \"zlib\"")
    check alphaIdx >= 0
    check mangoIdx > alphaIdx
    check zlibIdx > mangoIdx

  test "test_m20_overrides_strict_reader_rejects_unknown_top_level_keys":
    let workspaceRoot = createTempDir("repro-m20-strict-", "")
    defer: removeDir(workspaceRoot)

    # Hand-roll a develop-overrides.toml that smuggles an unknown
    # top-level key past the writer. The M5 strict reader must reject
    # it with a structured ``WorkspaceManifestParseError`` so a typo
    # surfaces a single actionable diagnostic rather than a downstream
    # failure inside M21's resolver.
    createDir(workspaceRoot / ".repro")
    writeFile(developOverridesPath(workspaceRoot),
      "schema = \"reprobuild.workspace.develop-overrides.v1\"\n" &
      "rogue_top_level_key = \"oops\"\n\n" &
      "[[override]]\n" &
      "package = \"cairo\"\n" &
      "local_path = \"../cairo\"\n" &
      "state = \"editable\"\n" &
      "created_at = \"2026-06-02T10:14:33Z\"\n")

    var raised = false
    try:
      discard readDevelopOverridesFile(workspaceRoot)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "rogue_top_level_key"
      check e.expectedSchema == "reprobuild.workspace.develop-overrides.v1"
    check raised

  test "test_m20_overrides_add_then_remove_is_a_no_op":
    # Pure in-memory round-trip — no filesystem touch. Adding an
    # override then removing it by package name must yield a value
    # whose serialized form matches the original (the structural
    # equivalent of equality for this schema, since the in-memory
    # record carries no ordering information beyond the entry seq).
    let original = newDevelopOverrides()
    let originalBody = serializeDevelopOverridesToToml(original)

    let withEntry = original.addOverride(sampleEntry(
      "cairo", "../cairo", "editable", "2026-06-02T10:14:33Z",
      provenance = "repro develop cairo"))
    check listOverrides(withEntry).len == 1

    let restored = withEntry.removeOverride("cairo")
    check listOverrides(restored).len == 0

    let restoredBody = serializeDevelopOverridesToToml(restored)
    check restoredBody == originalBody

    # Removing a package that is not present is a documented no-op
    # — the helper is idempotent at the in-memory layer so M22's
    # ``repro develop --drop <pkg>`` can be idempotent at the CLI
    # surface.
    let stillEmpty = restored.removeOverride("never-there")
    check serializeDevelopOverridesToToml(stillEmpty) == originalBody

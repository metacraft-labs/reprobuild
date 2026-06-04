## repro_workspace_manifests/develop_overrides.nim
##
## M20 — Develop-mode override metadata file.
##
## Source of truth for per-package source-override entries that point at
## local working copies. Lives under
## ``<workspaceRoot>/.repro/develop-overrides.toml`` per
## ``reprobuild-specs/Workspace-Manifests.md`` §"Develop-Mode Override
## File":
##
##   schema = "reprobuild.workspace.develop-overrides.v1"
##
##   [[override]]
##   package = "cairo"                       # required: solved package id
##   local_path = "../cairo"                 # required: source location
##   state = "editable"                      # required: editable/pinned/detached
##   created_at = "2026-06-02T10:14:33Z"     # required: ISO-8601 timestamp
##   # provenance = "repro develop cairo"    # optional: how it was selected
##
## The file is workspace-local metadata: it lives under ``.repro/`` (NOT
## under ``.repo/``) and is never committed. M21 reads it to shadow
## upstream package bindings in the build graph; M22 (``repro develop``)
## writes new entries; M23 (``repro check``) inspects it during the
## pre-push publication gate. M20 itself ships:
##
##   - the workspace-rooted query layer (``readDevelopOverridesFile``)
##     that returns ``none`` when the file is absent (so callers don't
##     have to special-case the empty state);
##   - the deterministic serializer + writer
##     (``serializeDevelopOverridesToToml`` /
##     ``writeDevelopOverridesFile``);
##   - immutable mutation helpers
##     (``addOverride`` / ``removeOverride`` / ``findOverride`` /
##     ``listOverrides``) that M22 will compose into the CLI write path.
##
## Determinism: ``[[override]]`` blocks are emitted sorted by ``package``
## name so a freshly added entry never reshuffles existing ones. Re-
## writing the same content is a byte-identical no-op. Empty
## ``provenance`` is omitted (rather than emitted as ``provenance = ""``)
## so a record with no provenance round-trips cleanly through the M5
## strict reader, which already accepts the field as ``Option[string]``.

import std/[algorithm, options, os, sequtils]

import types
import diagnostics
import reader

# ---- path helper ----------------------------------------------------------

proc developOverridesPath*(workspaceRoot: string): string =
  ## Canonical absolute path of the develop-overrides metadata file.
  ## ``.repro/`` (workspace-local scratch + metadata, gitignored) is
  ## distinct from ``.repo/`` (repo-tool / workspace.toml metadata).
  workspaceRoot / ".repro" / "develop-overrides.toml"

# ---- TOML escape helper ---------------------------------------------------

proc tomlEscape(value: string): string =
  ## Minimal TOML basic-string escape. Override entries carry package
  ## names, filesystem paths, ISO-8601 timestamps, and short provenance
  ## strings — backslash, double-quote, and control escapes are
  ## sufficient. Mirrors the helper in ``workspace_branch.nim`` so both
  ## writers produce the same quoting shape.
  result = newStringOfCap(value.len + 2)
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    else: result.add(ch)

template emitKv(buf: var string; key, value: string) =
  buf.add(key)
  buf.add(" = \"")
  buf.add(tomlEscape(value))
  buf.add("\"\n")

# ---- query helpers --------------------------------------------------------

proc listOverrides*(file: DevelopOverrides): seq[DevelopOverrideEntry] =
  ## Return the entries in the order they appear inside ``file``. The
  ## serializer always writes them sorted by ``package`` name, so any
  ## file produced by ``writeDevelopOverridesFile`` will return its
  ## entries in alphabetical order. A hand-edited file may carry them
  ## in any order — this proc does NOT re-sort on read so callers can
  ## detect manual edits.
  file.`override`

proc findOverride*(file: DevelopOverrides;
                   packageName: string): Option[DevelopOverrideEntry] =
  ## Look up an override by the solved package name. Returns ``none``
  ## when no entry matches. M21 will call this from the build-graph
  ## resolver to decide whether to shadow the upstream binding.
  for entry in file.`override`:
    if entry.package == packageName:
      return some(entry)
  none(DevelopOverrideEntry)

# ---- immutable mutation helpers -------------------------------------------

proc sortEntries(entries: seq[DevelopOverrideEntry]):
    seq[DevelopOverrideEntry] =
  ## Return ``entries`` sorted by ``package`` name. The serializer is
  ## the single source of truth for write-order, but the mutation
  ## helpers also sort so callers that inspect the in-memory value
  ## after ``addOverride`` see the same order the writer would emit.
  result = entries
  result.sort(proc (a, b: DevelopOverrideEntry): int =
    cmp(a.package, b.package))

proc addOverride*(file: DevelopOverrides;
                  entry: DevelopOverrideEntry): DevelopOverrides =
  ## Return a copy of ``file`` with ``entry`` added (or replacing the
  ## existing entry for the same ``package``). Re-sorts entries by
  ## ``package`` name. The original value is unchanged so callers can
  ## safely keep references to the pre-update record.
  ##
  ## Refuses to add an entry with an empty ``package`` field — that
  ## would silently shadow every read because ``findOverride`` would
  ## still match it but the M5 strict reader would reject the file on
  ## the next round-trip. Surfacing the error here is the lesser of
  ## two evils.
  if entry.package.len == 0:
    raiseManifestError("", "override[].package",
      schemaDevelopOverridesV1, schemaDevelopOverridesV1,
      "addOverride refuses to add an override with empty package name")

  result = file
  if result.schema.len == 0:
    result.schema = schemaDevelopOverridesV1
  var replaced = false
  for i in 0 ..< result.`override`.len:
    if result.`override`[i].package == entry.package:
      result.`override`[i] = entry
      replaced = true
      break
  if not replaced:
    result.`override`.add(entry)
  result.`override` = sortEntries(result.`override`)

proc removeOverride*(file: DevelopOverrides;
                     packageName: string): DevelopOverrides =
  ## Return a copy of ``file`` with the entry for ``packageName``
  ## removed. If no such entry exists the result is structurally equal
  ## to the input (the helpers are deliberately forgiving: M22's
  ## ``repro develop --drop <pkg>`` is idempotent at the CLI surface
  ## and the helper matches that contract).
  result = file
  result.`override` = result.`override`.filterIt(it.package != packageName)
  result.`override` = sortEntries(result.`override`)

# ---- serializer -----------------------------------------------------------

proc serializeDevelopOverridesToToml*(file: DevelopOverrides): string =
  ## Render ``file`` to the canonical TOML form documented in
  ## ``Workspace-Manifests.md`` §"Develop-Mode Override File":
  ##
  ##   ``schema = "reprobuild.workspace.develop-overrides.v1"``
  ##
  ##   ``[[override]]``                  # one block per entry, sorted by ``package``
  ##   ``package = "..."``
  ##   ``local_path = "..."``
  ##   ``state = "..."``
  ##   ``created_at = "..."``
  ##   ``provenance = "..."``            # only when present and non-empty
  ##
  ## Determinism: blocks are emitted in alphabetical order of
  ## ``package`` so a freshly added entry never reshuffles existing
  ## ones. ``provenance`` is omitted when absent or empty (the M5
  ## strict reader treats absent as ``none`` either way).
  ##
  ## The ``[extensions]`` table is intentionally NOT re-emitted: M20
  ## is the only structured writer for this schema and no production
  ## fixture carries extensions today. If a future caller needs to
  ## round-trip extensions, the writer can be extended without
  ## breaking existing consumers (the strict reader already accepts
  ## the table).
  let sorted = sortEntries(file.`override`)

  result = newStringOfCap(96 + sorted.len * 160)
  result.add("schema = \"")
  result.add(schemaDevelopOverridesV1)
  result.add("\"\n")

  for entry in sorted:
    if entry.package.len == 0:
      raiseManifestError("", "override[].package",
        schemaDevelopOverridesV1, schemaDevelopOverridesV1,
        "serializeDevelopOverridesToToml refuses to emit an override " &
          "with empty package name")
    if entry.local_path.len == 0:
      raiseManifestError("", "override[].local_path",
        schemaDevelopOverridesV1, schemaDevelopOverridesV1,
        "serializeDevelopOverridesToToml refuses to emit an override " &
          "with empty local_path")
    if entry.state.len == 0:
      raiseManifestError("", "override[].state",
        schemaDevelopOverridesV1, schemaDevelopOverridesV1,
        "serializeDevelopOverridesToToml refuses to emit an override " &
          "with empty state")
    if entry.created_at.len == 0:
      raiseManifestError("", "override[].created_at",
        schemaDevelopOverridesV1, schemaDevelopOverridesV1,
        "serializeDevelopOverridesToToml refuses to emit an override " &
          "with empty created_at")

    result.add("\n[[override]]\n")
    emitKv(result, "package", entry.package)
    emitKv(result, "local_path", entry.local_path)
    emitKv(result, "state", entry.state)
    emitKv(result, "created_at", entry.created_at)
    if entry.provenance.isSome and entry.provenance.get().len > 0:
      emitKv(result, "provenance", entry.provenance.get())

# ---- reader (workspace-rooted) --------------------------------------------

proc readDevelopOverridesFile*(workspaceRoot: string):
    Option[DevelopOverrides] =
  ## Read ``<workspaceRoot>/.repro/develop-overrides.toml`` through the
  ## M5 strict reader. Returns ``none`` when the file is absent (the
  ## common case for any workspace that has not yet activated
  ## develop-mode for any package); never raises on absence. A
  ## malformed file propagates as ``WorkspaceManifestParseError`` so
  ## the caller sees the same structured diagnostic
  ## ``readDevelopOverrides`` would have raised.
  let path = developOverridesPath(workspaceRoot)
  if not fileExists(path):
    return none(DevelopOverrides)
  some(readDevelopOverrides(path))

# ---- writer ---------------------------------------------------------------

proc writeDevelopOverridesFile*(workspaceRoot: string;
                                file: DevelopOverrides) =
  ## Persist ``file`` to ``<workspaceRoot>/.repro/develop-overrides.toml``
  ## through the deterministic serializer. Creates ``.repro/`` if
  ## missing. Idempotent: re-running with the same value yields a
  ## byte-identical file (the serializer fixes key order and
  ## quoting). ``addOverride`` and ``removeOverride`` are the
  ## intended way to mutate ``file`` before calling this.
  let path = developOverridesPath(workspaceRoot)
  createDir(parentDir(path))
  writeFile(path, serializeDevelopOverridesToToml(file))

# ---- new-file constructor -------------------------------------------------

proc newDevelopOverrides*(): DevelopOverrides =
  ## Construct an empty ``DevelopOverrides`` with the canonical schema
  ## string pre-populated. M22's first write at workspace activation
  ## time starts from this value and folds in the requested entry via
  ## ``addOverride``.
  result.schema = schemaDevelopOverridesV1

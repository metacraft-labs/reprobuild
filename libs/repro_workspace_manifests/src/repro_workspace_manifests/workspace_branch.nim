## repro_workspace_manifests/workspace_branch.nim
##
## M13 — Workspace metadata for the active branch.
##
## The active workspace branch is recorded in
## ``<workspaceRoot>/.repo/workspace.toml`` under ``[workspace].branch``.
## The schema is documented in
## ``reprobuild-specs/Workspace-Manifests.md`` §"Workspace Composition
## Layers" — the same TOML the M8 composer reads. The ``branch`` key was
## already reserved on ``WorkspaceBody`` (see ``types.nim``); M13 wires
## up the writer plus a tiny read-only convenience.
##
## Two operating modes:
##
##   1. **Composer mode** — ``.repo/workspace.toml`` already exists with
##      one or more ``[[manifest]]`` entries. The writer reads the file
##      via the M5 strict reader, updates ``workspace.branch``, and
##      re-emits the canonical TOML preserving the declared manifest
##      layers in source order.
##
##   2. **Single-project mode** — no ``.repo/workspace.toml`` exists.
##      The writer creates a *metadata-only* workspace.toml carrying
##      ``[workspace] project = "<name>"`` and ``branch = "<name>"`` and
##      no ``[[manifest]]`` entries. Dispatch sites that distinguish
##      composer vs single-project mode use
##      ``isCompositionalWorkspaceToml`` (defined below) rather than the
##      bare ``fileExists`` so a metadata-only file still routes to the
##      M6/M7 single-project resolver.
##
## The writer is idempotent: re-running with the same branch value
## overwrites the file with byte-identical bytes (key order and
## quoting are fixed by the serializer).

import std/[options, os]

import types
import diagnostics
import reader

# ---- helpers --------------------------------------------------------------

proc tomlEscape(value: string): string =
  ## Minimal TOML basic-string escape. The workspace metadata only
  ## carries identifier-shaped strings (project names, branch names,
  ## URLs) — backslash / double-quote / control escapes are sufficient.
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

template emitKvBool(buf: var string; key: string; value: bool) =
  buf.add(key)
  buf.add(" = ")
  buf.add(if value: "true" else: "false")
  buf.add("\n")

proc workspaceTomlPath*(workspaceRoot: string): string =
  ## Canonical absolute path of the workspace metadata file.
  workspaceRoot / ".repo" / "workspace.toml"

# ---- serializer -----------------------------------------------------------

proc serializeWorkspaceLocalToToml*(local: WorkspaceLocal): string =
  ## Render a ``WorkspaceLocal`` to the canonical TOML form documented
  ## in ``Workspace-Manifests.md`` §"Workspace Composition Layers". Key
  ## order is fixed:
  ##
  ##   ``schema = "..."``
  ##
  ##   ``[workspace]``
  ##   ``project = "..."``
  ##   ``branch = "..."``     # optional
  ##
  ##   ``[[manifest]]``       # one block per declared layer
  ##   ``url = "..."`` OR ``local_path = "..."``
  ##   ``visibility = "..."``
  ##   ``branch = "..."``     # optional
  ##
  ## The ``[extensions]`` table from the strict reader is NOT
  ## re-emitted: M13's writer is the only structured writer for this
  ## schema, and the workspace.toml does not carry extensions in any
  ## production fixture today. If a future caller needs to round-trip
  ## extensions, the writer can be extended without breaking existing
  ## consumers (the strict reader already accepts the table).
  if local.workspace.project.len == 0:
    raiseManifestError("", "workspace.project",
      schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
      "serializeWorkspaceLocalToToml refuses to emit a workspace with empty project name")

  result = newStringOfCap(192 + local.manifest.len * 128)
  result.add("schema = \"")
  result.add(schemaWorkspaceLocalV1)
  result.add("\"\n\n")
  result.add("[workspace]\n")
  emitKv(result, "project", local.workspace.project)
  if local.workspace.branch.isSome and local.workspace.branch.get().len > 0:
    emitKv(result, "branch", local.workspace.branch.get())
  # M16: emit ``feature_started = true`` only when the flag is
  # explicitly set. The ``none`` and ``some(false)`` cases both
  # omit the key — the reader treats absent and ``false`` as
  # equivalent, so omitting the key keeps the workspace.toml
  # minimal in the steady state.
  if local.workspace.feature_started.isSome and
      local.workspace.feature_started.get() == true:
    emitKvBool(result, "feature_started", true)

  for entry in local.manifest:
    result.add("\n[[manifest]]\n")
    if entry.url.isSome and entry.url.get().len > 0:
      emitKv(result, "url", entry.url.get())
    elif entry.local_path.isSome and entry.local_path.get().len > 0:
      emitKv(result, "local_path", entry.local_path.get())
    emitKv(result, "visibility", entry.visibility)
    if entry.branch.isSome and entry.branch.get().len > 0:
      emitKv(result, "branch", entry.branch.get())

# ---- reader ---------------------------------------------------------------

proc isCompositionalWorkspaceToml*(workspaceRoot: string): bool =
  ## True iff a ``.repo/workspace.toml`` exists at ``workspaceRoot`` AND
  ## declares at least one ``[[manifest]]`` layer. CLI dispatch helpers
  ## use this to decide between the M8 composer path and the M6/M7
  ## single-project path: a metadata-only workspace.toml (zero manifest
  ## layers — written by M9 init to record the active branch) routes to
  ## single-project mode because the composer requires manifest layers.
  let path = workspaceTomlPath(workspaceRoot)
  if not fileExists(path):
    return false
  try:
    let local = readWorkspaceLocal(path)
    return local.manifest.len > 0
  except WorkspaceManifestParseError:
    # A malformed workspace.toml is the user's problem; let the caller
    # surface the structured diagnostic when it next tries to parse the
    # file directly. For dispatch purposes, treat the file as "present
    # but unusable" — return false so the caller falls back to
    # single-project mode (which will then either succeed or emit its
    # own missing-project diagnostic).
    return false

proc readWorkspaceFeatureStarted*(workspaceRoot: string): bool =
  ## M16 — Return ``true`` iff the workspace metadata records that the
  ## current ``[workspace].branch`` value names a feature branch
  ## the operator deliberately started via
  ## ``repro workspace start <branch>``. Returns ``false`` when the
  ## file is missing, the key is absent, or the key is present and
  ## ``false``. A malformed workspace.toml propagates as
  ## ``WorkspaceManifestParseError`` so the caller sees the same
  ## diagnostic the M5 reader would have raised.
  let path = workspaceTomlPath(workspaceRoot)
  if not fileExists(path):
    return false
  let local = readWorkspaceLocal(path)
  if local.workspace.feature_started.isSome:
    return local.workspace.feature_started.get()
  false

proc readWorkspaceBranch*(workspaceRoot: string): Option[string] =
  ## Return the workspace's active branch as recorded in
  ## ``.repo/workspace.toml`` under ``[workspace].branch``. Returns
  ## ``none`` when the file is missing, when the field is absent, or
  ## when the field is present but empty. A malformed workspace.toml
  ## propagates as ``WorkspaceManifestParseError`` so the caller sees
  ## the same diagnostic the M5 reader would have raised — this proc
  ## is a thin convenience over ``readWorkspaceLocal``.
  let path = workspaceTomlPath(workspaceRoot)
  if not fileExists(path):
    return none(string)
  let local = readWorkspaceLocal(path)
  if local.workspace.branch.isSome and local.workspace.branch.get().len > 0:
    return some(local.workspace.branch.get())
  none(string)

# ---- writer ---------------------------------------------------------------

proc writeWorkspaceBranch*(workspaceRoot, project, branch: string) =
  ## Update ``.repo/workspace.toml`` to record ``branch`` as the
  ## workspace's active branch.
  ##
  ## - If ``.repo/workspace.toml`` already exists, the writer reads
  ##   it through the M5 strict reader, replaces
  ##   ``workspace.branch``, and re-emits the canonical TOML.
  ##   ``project`` is IGNORED when the file already exists — the
  ##   existing project name is authoritative (it was set by the
  ##   composer-mode workspace and changing it would orphan the
  ##   manifest layers).
  ## - If the file does NOT exist, a metadata-only workspace.toml is
  ##   created with ``[workspace] project = "<project>"`` and
  ##   ``branch = "<branch>"`` and no ``[[manifest]]`` entries. This
  ##   is the single-project (M9 init) path. Callers MUST pass a
  ##   non-empty ``project`` in this case; an empty ``project`` plus
  ##   a missing file raises ``WorkspaceManifestParseError`` rather
  ##   than emit a file the strict reader would later reject.
  ##
  ## Idempotent: re-running with the same arguments yields a
  ## byte-identical file (the serializer is deterministic). Empty
  ## ``branch`` clears the field rather than emitting ``branch = ""``.
  if branch.len == 0:
    raiseManifestError(workspaceTomlPath(workspaceRoot),
      "workspace.branch", schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
      "writeWorkspaceBranch refuses to record an empty branch name")

  let path = workspaceTomlPath(workspaceRoot)
  createDir(parentDir(path))

  var local: WorkspaceLocal
  if fileExists(path):
    local = readWorkspaceLocal(path)
  else:
    if project.len == 0:
      raiseManifestError(path, "workspace.project",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "writeWorkspaceBranch requires a non-empty project when " &
          "creating workspace.toml from scratch (single-project mode)")
    local.schema = schemaWorkspaceLocalV1
    local.workspace.project = project

  local.workspace.branch = some(branch)
  writeFile(path, serializeWorkspaceLocalToToml(local))

proc writeWorkspaceBranchWithStarted*(workspaceRoot, project, branch: string;
                                     featureStarted: bool) =
  ## M16 variant of ``writeWorkspaceBranch`` that ALSO records the
  ## feature-started mark. ``featureStarted = true`` writes
  ## ``feature_started = true`` under ``[workspace]``; ``false`` clears
  ## the field entirely (by setting the Option to ``none`` so the
  ## serializer omits the key — the steady state for branches that are
  ## NOT feature branches, e.g. ``main``).
  ##
  ## Semantics mirror ``writeWorkspaceBranch``: when the file already
  ## exists in composer mode the existing project and manifest layers
  ## are preserved verbatim; in single-project mode the file is created
  ## from scratch with just the metadata keys. Idempotent: re-running
  ## with the same arguments produces byte-identical output.
  if branch.len == 0:
    raiseManifestError(workspaceTomlPath(workspaceRoot),
      "workspace.branch", schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
      "writeWorkspaceBranchWithStarted refuses to record an empty branch name")

  let path = workspaceTomlPath(workspaceRoot)
  createDir(parentDir(path))

  var local: WorkspaceLocal
  if fileExists(path):
    local = readWorkspaceLocal(path)
  else:
    if project.len == 0:
      raiseManifestError(path, "workspace.project",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "writeWorkspaceBranchWithStarted requires a non-empty project when " &
          "creating workspace.toml from scratch (single-project mode)")
    local.schema = schemaWorkspaceLocalV1
    local.workspace.project = project

  local.workspace.branch = some(branch)
  if featureStarted:
    local.workspace.feature_started = some(true)
  else:
    # Clear the field. The serializer omits absent / false values, so
    # ``none`` keeps the workspace.toml minimal.
    local.workspace.feature_started = none(bool)
  writeFile(path, serializeWorkspaceLocalToToml(local))

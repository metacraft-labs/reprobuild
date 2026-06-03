# repro_workspace_manifests/types.nim
#
# Nim records mirroring the TOML schemas specified in
# `reprobuild-specs/Workspace-Manifests.md`. Each record has a top-level
# `schema` string and an optional `extensions` table that the strict reader
# allows so forward-compatible extension keys do not trip
# unknown-field rejection (Workspace-Manifests.md §"Common Conventions" +
# §"Future Extensions").

import std/[options, tables]
import toml_serialization
import toml_serialization/types as toml_types

export toml_types.TomlValueRef, toml_types.TomlTableRef, toml_types.TomlKind
export tables

type
  Extensions* = object
    ## Forward-compatible `[extensions]` table allow-through.
    ##
    ## The Workspace-Manifests spec reserves `[extensions]` as a place for
    ## future-compatible keys that the strict reader must accept without
    ## rejection. We capture the table body as a `TomlTableRef` so callers
    ## that care can inspect it, while readers that do not care can ignore
    ## the `raw` handle entirely.
    ##
    ## When the input file omits the `[extensions]` table, `raw` stays
    ## `nil`. When present, `raw` is non-nil and populated with the
    ## table's keys and values.
    raw*: TomlTableRef

proc isPresent*(e: Extensions): bool = not e.raw.isNil
  ## True iff the source TOML carried a non-empty `[extensions]` table.

proc readValue*(r: var TomlReader, v: var Extensions) =
  ## Custom strict-mode reader. We must define this explicitly because
  ## status-im/nim-toml-serialization's strict mode otherwise tries to
  ## decode the `[extensions]` table against `Extensions`'s declared
  ## fields, finds none, and would reject every key. Walking the table
  ## via `parseTable` + `readValue(.., var TomlValueRef)` lets every
  ## sub-key pass through irrespective of name.
  parseTable(r, key):
    if v.raw.isNil:
      v.raw = TomlTableRef()
    var inner: TomlValueRef
    r.readValue(inner)
    v.raw[key] = inner

type
  WorkspaceManifestParseError* = object of CatchableError
    ## Structured diagnostic raised by every reader in this library.
    ##
    ## - `path`             — the manifest file path supplied by the caller.
    ## - `keyPath`          — the offending TOML key path (e.g. "schema",
    ##                        "garbage", "extensions.something").
    ##                        Empty when the failure is file-level (missing
    ##                        file, IO error).
    ## - `expectedSchema`   — the schema string this reader expected to find
    ##                        in `schema` (always populated for typed readers).
    ## - `observedSchema`   — the schema string actually observed in the
    ##                        file's `schema` key. Empty when the file is
    ##                        missing, unreadable, or the top-level `schema`
    ##                        key itself could not be parsed.
    ## - `innerMessage`     — the underlying strict-mode parser message (or
    ##                        OS message) without the structured framing.
    path*: string
    keyPath*: string
    expectedSchema*: string
    observedSchema*: string
    innerMessage*: string

const
  schemaRepoFragmentV1*     = "reprobuild.workspace.repo.v1"
  schemaProjectManifestV1*  = "reprobuild.workspace.project.v1"
  schemaVariantManifestV1*  = "reprobuild.workspace.variant.v1"
  schemaLockV1*             = "reprobuild.workspace.lock.v1"
  schemaLockIndexV1*        = "reprobuild.workspace.lock-index.v1"
  schemaSnapshotV1*         = "reprobuild.workspace.snapshot.v1"
  schemaWorkspaceLocalV1*   = "reprobuild.workspace.local.v1"
  schemaDevelopOverridesV1* = "reprobuild.workspace.develop-overrides.v1"

type
  # --- repos/<repo>.toml -----------------------------------------------------

  RepoBody* = object
    name*: string
    path*: string
    remote*: Option[string]
    revision*: Option[string]
    vcs*: Option[string]
    stability*: Option[string]

  RepoFragment* = object
    schema*: string
    repo*: RepoBody
    extensions*: Extensions

  # --- projects/<project>.toml -----------------------------------------------

  ProjectBody* = object
    name*: string
    default_revision*: Option[string]
    default_remote*: Option[string]
    trunk*: Option[string]

  RemoteEntry* = object
    name*: string
    fetch*: string

  ProjectManifest* = object
    schema*: string
    project*: ProjectBody
    remote*: seq[RemoteEntry]
    includes*: seq[string]
    extensions*: Extensions

  # --- variants/<...>.toml ---------------------------------------------------

  VariantBody* = object
    name*: string
    base*: string

  OverrideEntry* = object
    fragment*: string
    revision*: Option[string]
    remote*: Option[string]
    path*: Option[string]

  VariantManifest* = object
    schema*: string
    variant*: VariantBody
    includes*: seq[string]
    `override`*: seq[OverrideEntry]
    extensions*: Extensions

  # --- locks/<project>/<sha>.toml --------------------------------------------

  LockHeader* = object
    project*: string
    created_at*: string
    created_by*: Option[string]
    workspace_branch*: Option[string]

  LockedRepo* = object
    name*: string
    path*: string
    remote*: string
    revision*: string
    branch*: Option[string]

  Lock* = object
    schema*: string
    lock*: LockHeader
    repo*: seq[LockedRepo]
    extensions*: Extensions

  # --- locks/<project>/index.toml --------------------------------------------

  LockIndexEntry* = object
    trigger_repo*: string
    trigger_sha*: string
    lock_file*: string
    created_at*: string

  LockIndex* = object
    schema*: string
    entry*: seq[LockIndexEntry]
    extensions*: Extensions

  # --- snapshots/<name>.toml -------------------------------------------------
  #
  # Per Workspace-Manifests.md §"snapshots/<name>.toml", snapshots share the
  # lock shape with a `[snapshot]` header (carrying the human-meaningful
  # `name` key) instead of `[lock]`.

  SnapshotHeader* = object
    name*: string
    project*: string
    created_at*: string
    created_by*: Option[string]
    workspace_branch*: Option[string]

  Snapshot* = object
    schema*: string
    snapshot*: SnapshotHeader
    repo*: seq[LockedRepo]
    extensions*: Extensions

  # --- <workspace-root>/.repro/workspace.toml --------------------------------

  WorkspaceBody* = object
    project*: string
    branch*: Option[string]

  ManifestLayer* = object
    url*: Option[string]
    local_path*: Option[string]
    visibility*: string
    branch*: Option[string]

  WorkspaceLocal* = object
    schema*: string
    workspace*: WorkspaceBody
    manifest*: seq[ManifestLayer]
    extensions*: Extensions

  # --- <workspace-root>/.repro/develop-overrides.toml ------------------------

  DevelopOverrideEntry* = object
    package*: string
    local_path*: string
    state*: string
    created_at*: string
    provenance*: Option[string]

  DevelopOverrides* = object
    schema*: string
    `override`*: seq[DevelopOverrideEntry]
    extensions*: Extensions

  # NOTE on the schema probe: the reader does NOT define a typed "probe"
  # record. Instead it calls
  #     Toml.decode(content, string, "schema")
  # which uses toml-serialization's `moveToKey` machinery to navigate to
  # just the top-level `schema` value, returning the string and ignoring
  # the rest of the file. That avoids defining a parallel probe record
  # whose shape would have to track every schema variant.

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
  schemaWorkspaceBootstrapV1* = "reprobuild.workspace.bootstrap.v1"

type
  # --- repos/<repo>.toml -----------------------------------------------------

  CopyLinkFileEntry* = object
    ## RA-18 — one copyfile / linkfile directive (the `repo`
    ## `<copyfile>` / `<linkfile>` equivalent). `src` is interpreted
    ## relative to the repo's own working tree; `dest` is interpreted
    ## relative to the workspace root. Both required.
    ##
    ## Authored as an inline-table-array element under `[repo]`:
    ##   copyfile = [{ src = "build/config.default.toml", dest = "config.toml" }]
    ##   linkfile = [{ src = "scripts/dev.sh", dest = "dev.sh" }]
    ## The pinned `nim-toml-serialization` (v0.2.18) does not support a
    ## *nested* array-of-tables (`[[repo.copyfile]]`), so the inline-table
    ## array is the supported surface syntax (Workspace-Manifests.md
    ## §"copyfile / linkfile" "Syntax note").
    src*: string
    dest*: string

  RepoBody* = object
    name*: string
    path*: string
    remote*: Option[string]
    revision*: Option[string]
    vcs*: Option[string]
    stability*: Option[string]
    # RA-14 — optional fetch-acceleration hints (Workspace-Manifests.md
    # §"Optional fetch-acceleration hints"). These never change the
    # resolved tree at the pinned revision; they only change how much is
    # downloaded.
    clone_filter*: Option[string]  ## partial clone: "blob:none" / "tree:0"
    depth*: Option[int]            ## shallow clone depth (deepened on demand)
    single_branch*: Option[bool]   ## fetch only the pinned revision's branch
    # RA-18 — post-sync file materialization + group membership
    # (Workspace-Manifests.md §§"copyfile / linkfile", "Manifest Groups").
    # A missing/empty `groups` means the repo belongs to the implicit
    # `default` group only. `copyfile`/`linkfile` are applied after a
    # successful checkout and re-applied on every sync (idempotent), so the
    # materialized files track the checked-out revision.
    copyfile*: seq[CopyLinkFileEntry]
    linkfile*: seq[CopyLinkFileEntry]
    groups*: seq[string]

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
    feature_started*: Option[bool]
      ## M16 — when ``true``, the current ``branch`` value names a
      ## feature branch the operator deliberately started via
      ## ``repro workspace start <branch>``. The M10 sync planner
      ## reads this flag and no-ops "clean fast-forwardable" repos
      ## that happen to sit on the marked branch even when the lock
      ## pins a different SHA on it. ``none`` means "not marked"
      ## (backward-compatible with workspaces written before M16).

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

  # --- <host-repo>/.repro-workspace.toml (RA-8 host bootstrap config) ---------
  #
  # Committed by the *host* product repo (canonical home `<org>/repro-workspace`)
  # so a new user joins a workspace with a single `repro workspace init` and no
  # `--manifest-url` flag. The `repro` binary ships NO org-specific default URL;
  # this file is the org-config side of the generic-tool-vs-host-config split
  # (Workspace-Manifests.md §"Host Bootstrap Config").

  BootstrapManifestBody* = object
    url*: string
    branch*: Option[string]
    private_url*: Option[string]
      ## Optional private companion manifest URL. May also be supplied from a
      ## sibling `.repro-workspace-private.toml` file (see `readWorkspaceBootstrap`)
      ## that carries credentialed/SSH URLs the public config must not embed.

  BootstrapProjectsBody* = object
    default*: seq[string]
      ## Default project set auto-layered when the user hasn't chosen an
      ## explicit project set (consumed by init / `projects add --default`).

  WorkspaceBootstrap* = object
    schema*: string
    manifest*: BootstrapManifestBody
    projects*: BootstrapProjectsBody
    extensions*: Extensions

  # --- <host-repo>/.repro-workspace-private.toml (RA-8 private companion) -----
  #
  # Sibling of the public bootstrap config. Carries credentialed/SSH manifest
  # URLs so the committed public file never embeds a secret-bearing URL. Read
  # only for its `[manifest] private_url`; intentionally not committed where the
  # URL is credentialed.

  BootstrapPrivateManifestBody* = object
    private_url*: string

  WorkspaceBootstrapPrivate* = object
    schema*: string
    manifest*: BootstrapPrivateManifestBody
    extensions*: Extensions

  # NOTE on the schema probe: the reader does NOT define a typed "probe"
  # record. Instead it calls
  #     Toml.decode(content, string, "schema")
  # which uses toml-serialization's `moveToKey` machinery to navigate to
  # just the top-level `schema` value, returning the string and ignoring
  # the rest of the file. That avoids defining a parallel probe record
  # whose shape would have to track every schema variant.

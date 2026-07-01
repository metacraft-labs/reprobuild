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
  schemaReprobuildConfigV1* = "reprobuild.config.v1"
    ## HL-1 (Unified-Locking-And-Hooks) — the layered configuration file read
    ## by the system-config (layer 2), user-dotfiles (layer 3), and
    ## VCS-private (layer 5) layers, plus every file an `apply_if`
    ## directive references. A `reprobuild.config.v1` file may carry `apply_if`
    ## path-scoped bindings (inline-table array) and/or `[locking]` routes.

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
    # MO-5 — evidence-only private participation marker
    # (Workspace-And-Develop-Mode.md §"Evidence-only participation"). When set
    # to ``"evidence-only"`` the repo participates in the build WITHOUT being
    # shared: only its source-free ``WorkspaceVcsEvidence`` (head-sha / is-clean
    # / is-published) is published to its assigned locking backend, never its
    # source. A teammate who cannot clone it verifies the reproducibility
    # boundary from that evidence + the lock. Any other value (or absent) means
    # a normal SHARED repo whose source IS expected to be present (a missing
    # checkout is then an actionable clone-required error, not evidence-only).
    participation*: Option[string]
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
    # RA-21 — develop-set dependency edges. Names the OTHER repos in the
    # same workspace that THIS repo depends on (a develop-mode sibling is
    # a git-submodule replacement; see Workspace-And-Develop-Mode.md
    # §"VCS Hook Integration"). The pre-push gate scopes its clean/published
    # checks to the pushed repo plus the transitive closure of these edges,
    # not the whole workspace. A missing/empty `depends` means the repo has
    # no develop-set dependencies (it forms a singleton closure).
    depends*: seq[string]

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

  BinaryDependencyEntry* = object
    ## RA-22 — a dependency added in BINARY mode: a pinned, published
    ## artifact rather than a local develop-mode sibling checkout. Recorded
    ## directly in the project manifest (NOT as an `includes` repo fragment)
    ## so a binary dependency is never cloned, synced, or part of the
    ## checkout garbage-collection graph (Workspace-And-Develop-Mode.md
    ## §"Workspace Membership": binary = "no checkout"). Authored as an
    ## inline-table-array element:
    ##   binary_dependency = [{ name = "zlib", remote = "https://…", revision = "v1.3" }]
    name*: string
    remote*: string
    revision*: Option[string]

  CertificatesBody* = object
    ## TC-3 / TC-6 / RA-32 — the project's test-certificate gating policy
    ## (Test-Certificates.md §"Per-project configuration"). Authored as a
    ## top-level `[certificates]` table in `projects/<project>.toml`:
    ##
    ##   [certificates]
    ##   gate_mode = "required"            # off (default) | advisory | required
    ##   required_targets = ["t-unit"]    # targets a cert must cover
    ##   required_platforms = ["linux/amd64", "macos/arm64"]
    ##
    ## Every field is OPTIONAL. A missing `[certificates]` table — or a table
    ## that omits `gate_mode` — resolves to `off`, so a project that never
    ## opts in is never cert-gated (the default-off onboarding guarantee:
    ## RA-32). `gate_mode` ∈ {off, advisory, required}; `advisory` records
    ## coverage without ever blocking the push; `required` refuses the push
    ## unless the submitted certificates cover the pushed commit for the
    ## required targets on each required platform.
    ##
    ## TC-4 — `ci_trust` controls whether CI fast-tracks (skips) targets a
    ## valid certificate already covers, or treats the certificate as purely
    ## informational and re-runs everything. `skip` is the high-trust
    ## fast-track ("trust the certificate, don't re-run"); `advisory` (the
    ## DEFAULT, the SAFER choice) re-runs everything but surfaces the
    ## certificate as a signal. Trust is an EXPLICIT project decision: an
    ## absent / omitted `ci_trust` never silently fast-tracks
    ## (Test-Certificates.md §"CI integration — skipping certified work").
    gate_mode*: Option[string]
    required_targets*: seq[string]
    required_platforms*: seq[string]
    ci_trust*: Option[string]

  ProjectManifest* = object
    schema*: string
    project*: ProjectBody
    remote*: seq[RemoteEntry]
    includes*: seq[string]
    binary_dependency*: seq[BinaryDependencyEntry]
      ## RA-22 — binary-mode dependencies (see `BinaryDependencyEntry`). A
      ## missing/empty array means the project declares no binary
      ## dependencies; backward-compatible with manifests authored before
      ## RA-22.
    certificates*: CertificatesBody
      ## TC-3 / TC-6 / RA-32 — the project's test-certificate gating policy.
      ## A missing `[certificates]` table leaves every field at its zero
      ## value (`gate_mode` = none ⇒ resolved `off`), so enforcement is
      ## strictly opt-in and backward-compatible with manifests authored
      ## before this milestone.
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
    projects*: seq[string]
      ## RA-6 — the active PROJECT SET layered into this workspace. The
      ## pilot's ``repro workspace projects add`` tracks a SET of project
      ## names (not a single project); this array records that set. The
      ## scalar ``project`` field remains the PRIMARY project (the first
      ## entry of the set, kept non-empty for the M6/M8 single-project
      ## resolver and every existing reader). An empty array means
      ## "single-project workspace" — only ``project`` is meaningful.
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
    revision*: Option[string]
      ## RA-17 — optional manifest-revision pin (a commit SHA or tag name). When
      ## set, `init`/refresh verify the manifest source's HEAD resolves to this
      ## exact revision so a moved branch can't silently swap the manifest out.
      ## When signature verification is also required, the SIGNATURE is checked
      ## against this pinned revision (a tag's signature, or the pinned commit's
      ## signature) rather than whatever the branch currently points at.

  BootstrapProjectsBody* = object
    default*: seq[string]
      ## Default project set auto-layered when the user hasn't chosen an
      ## explicit project set (consumed by init / `projects add --default`).

  BootstrapVerifyBody* = object
    ## RA-17 — manifest provenance / trust anchor (Workspace-Manifests.md
    ## §"Manifest Provenance and Verification"). Declared in the host
    ## bootstrap config, NEVER hardcoded. When `require_signature` is true,
    ## `init`/refresh verify that the manifest source's HEAD commit (or the
    ## pinned `manifest_revision` tag) carries a VALID signature from a key in
    ## the configured allowed-signers set, and FAIL CLOSED otherwise. When
    ## `require_signature` is false/absent, no verification is performed and
    ## behavior is unchanged.
    ##
    ## Verification uses git's SSH-signature path (`gpg.format=ssh` +
    ## `gpg.ssh.allowedSignersFile`) so it is testable hermetically with a
    ## generated ed25519 key — no system GPG keyring required, and it works on
    ## every platform git ships SSH signing on.
    require_signature*: bool
      ## When true, an unsigned / wrong-key / tampered manifest source is a
      ## hard error rather than a silent pass-through.
    allowed_signers*: Option[string]
      ## Path to a git `allowed_signers` file (the `gpg.ssh.allowedSignersFile`
      ## format: `<principal> <key-type> <base64-key>` per line). Relative
      ## paths are resolved against the bootstrap config's directory.
    allowed_keys*: seq[string]
      ## Inline allowed signer entries, each one line of the
      ## `allowed_signers` format. Folded into a temporary allowed-signers file
      ## together with `allowed_signers` when verification runs. Lets a config
      ## pin trust keys without a sidecar file.
    signer_identity*: Option[string]
      ## Optional `--check-signatory`-style principal to match against the
      ## allowed-signers `<principal>` column. Defaults to a wildcard
      ## (`reprobuild@manifest`) the inline-key path uses when unset.

  BootstrapDevelopBody* = object
    ## RA-22 — host/workspace policy for `repro add`'s develop-vs-binary
    ## default (Workspace-And-Develop-Mode.md §"`repro add` and develop-mode
    ## policy"). A dependency whose fetch URL begins with one of the
    ## `org_urls` prefixes is added in DEVELOP mode by default (a local
    ## sibling checkout); every other dependency defaults to BINARY. The
    ## policy is data, NEVER a hardcoded org name in the binary — an empty /
    ## absent `org_urls` means "no org defaults to develop" and every `add`
    ## defaults to binary unless `--develop` is passed. Per-`add` `--develop`
    ## / `--binary` flags override the default each time.
    org_urls*: seq[string]
      ## Fetch-URL prefixes (e.g. `https://github.com/our-org/`) whose repos
      ## default to develop mode. Matched as a literal string prefix against
      ## the dependency's remote URL.

  LockingRouteEntry* = object
    ## MO-4 — one per-repo-set → store-backend route in the host bootstrap
    ## config's `[locking]` table (Workspace-Manifests.md §"Routing repo-sets
    ## to stores"; Workspace-And-Develop-Mode.md §"Locking backends per
    ## repo-set"). Each entry maps a VISIBILITY tier (`wvPublic` / `wvOrg` /
    ## `wvTeam` / `wvPersonal`) to the `LockStore` backend that records the
    ## participation of every repo of that tier. Authored as an array of
    ## tables (`[[locking.route]]`) so it mirrors the `[[manifest]]` layer
    ## shape and decodes losslessly under the pinned toml-serialization.
    visibility*: string
      ## The tier this route applies to: `public` | `org` | `team` |
      ## `personal` (the spec uses `personal` and `private` interchangeably;
      ## both resolve to `wvPersonal`).
    backend*: string
      ## The backend kind: `committed-file` | `git-checkout` | `git-notes` |
      ## `separate-branch` | `external-cli` (the five MO-3 backends).
    path*: Option[string]
      ## Backend location, resolved relative to the workspace root when not
      ## absolute. For `git-checkout` it is the manifest-repo root (e.g.
      ## `.repo/manifests-team`); for `committed-file` the records base dir;
      ## for `git-notes` / `separate-branch` the git repo the records attach
      ## to (defaults to each repo's own checkout when omitted).
    program*: Option[string]
      ## The `external-cli` backend program (the documented CLI/JSON
      ## contract), resolved relative to the workspace root when not absolute.
    repos*: seq[string]
      ## HL-1 (Unified-Locking-And-Hooks §4) — the repos this route's TIER
      ## governs, named by `ResolvedRepo.name` or `ResolvedRepo.path`. When a
      ## route NAMES repos, the tier is determined by the DECLARING LAYER
      ## (tier-by-layer): those repos belong to this route's `visibility` tier
      ## regardless of their per-repo `ResolvedRepo.visibility` field, so a
      ## repo named only in a private layer can never appear in the public
      ## committed lock. An EMPTY `repos` list keeps the legacy MO-4
      ## visibility-keyed match (a route applies to every repo whose
      ## `ResolvedRepo.visibility` matches `visibility`), so a single
      ## `[locking]` table resolves byte-identically to before HL-1.

  BootstrapLockingBody* = object
    ## MO-4 — the `[locking]` table: a list of visibility-keyed store routes.
    ## An absent / empty `route` list is the all-public default — every repo
    ## is covered by the committed solved-graph lock (`repro.lock`) and NO
    ## store backend is constructed.
    route*: seq[LockingRouteEntry]

  WorkspaceBootstrap* = object
    schema*: string
    manifest*: BootstrapManifestBody
    projects*: BootstrapProjectsBody
    verify*: BootstrapVerifyBody
    develop*: BootstrapDevelopBody
    locking*: BootstrapLockingBody
    extensions*: Extensions

  # --- reprobuild.config.v1 (HL-1 layered configuration file) -----------------
  #
  # The file the system-config (layer 2), user-dotfiles (layer 3), and
  # VCS-private (layer 5) layers read, and the file every `apply_if`
  # directive references. It carries the two HL-1 directives:
  #   * `apply_if` — a path-scoped binding (modeled on Git's
  #     `includeIf "gitdir:…"`). When a workspace is checked out UNDER `under`,
  #     the referenced `config` file's `[locking]` routes are folded into the
  #     SAME layer that declared the `apply_if`. "Team via IT system config" and
  #     "personal via dotfiles" are the same mechanism at different scopes.
  #   * `[locking] route` — the existing route shape (now able to NAME repos),
  #     declared inline in this layer's file.
  #
  # Q-A resolution (VCS-private config file name/format): layer 5 reads
  # `vcsPrivateMetadataDir(repoRoot)/config.toml` (`<git-common-dir>/repro/config.toml`
  # for git). It is the SAME `reprobuild.config.v1` format as every other layer.
  #
  # Q-B resolution (`under` matching semantics): `under` is matched as a
  # PATH-PREFIX after normalization — both `under` (with `~` expanded) and the
  # workspace path are made absolute and symlink-resolved, then the workspace
  # matches when it equals `under` or is nested under `under/`. Multiple
  # overlapping `apply_if` scopes all contribute; their routes compose within
  # the declaring layer in file order (a later same-tier route refines the
  # backend, a cross-tier collision is a loud error).
  #
  # On-disk form (Q-A/Q-B, DECIDED): to stay within the pinned
  # toml-serialization (no `[[array.of.tables]]` for nested arrays), BOTH
  # `apply_if` and `[locking] route` are authored as INLINE-table arrays — the
  # same convention `.repro-workspace.toml`'s `[locking] route = [{ … }]` uses:
  #
  #   schema = "reprobuild.config.v1"
  #   apply_if = [{ under = "~/work/acme/", config = "team-routes.toml" }]
  #   [locking]
  #   route = [{ visibility = "team", backend = "git-checkout",
  #              path = "manifests-team", repos = ["core"] }]

  ApplyIfEntry* = object
    ## HL-1 — one `[[apply_if]]` path-scoped binding.
    under*: string
      ## The directory under which a workspace checkout activates this
      ## binding. `~` is expanded; the value is normalized to an absolute,
      ## symlink-resolved path before the prefix comparison.
    config*: string
      ## Path to a `reprobuild.config.v1` file whose `[locking]` routes are
      ## contributed when the workspace is under `under`. Relative paths are
      ## resolved against the directory of the file declaring the `apply_if`.

  ReprobuildConfig* = object
    ## HL-1 — a `reprobuild.config.v1` configuration file (system / dotfiles /
    ## VCS-private layer, or an `apply_if`-referenced routes file).
    schema*: string
    apply_if*: seq[ApplyIfEntry]
    locking*: BootstrapLockingBody
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

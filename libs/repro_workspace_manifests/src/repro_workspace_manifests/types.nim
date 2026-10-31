# repro_workspace_manifests/types.nim
#
# Nim records mirroring the TOML schemas specified in
# `reprobuild-specs/Workspace-Manifests.md`. Each record has a top-level
# `schema` string and an optional `extensions` table that the strict reader
# allows so forward-compatible extension keys do not trip
# unknown-field rejection (Workspace-Manifests.md §"Common Conventions" +
# §"Future Extensions").

import std/[options, strutils, tables]
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
  schemaRepoFragmentV2*     = "reprobuild.workspace.repo.v2"
    ## Workspace-Branch-Roles.md §3.1 / §3.6 — the repo fragment: `mainline`,
    ## the five optional built-in role keys, `profile`, and a
    ## `[repo.branch-roles]` sub-table of custom roles. The only fragment
    ## schema read and written; `retired_names.nim` names the one before it,
    ## so its diagnostic can say what to change.
  schemaRepoSetV1*          = "reprobuild.workspace.repo-set.v1"
    ## Workspace-Membership-Model.md — a named membership list. A repo-set that
    ## is enabled in a workspace is what used to be called a project; there is
    ## no second kind. Carries `name`, `member_sets` and `member_repos` and
    ## nothing else, so a shared set cannot drift into a half-project.
  schemaTemplateV1*         = "reprobuild.workspace.template.v1"
    ## Workspace-Membership-Model.md §"Templates" — the starting shape a NEW
    ## repo-set is scaffolded from. A DISTINCT schema rather than a repo-set
    ## with a reserved name, which is what lets the reader forbid the one thing
    ## a template must not carry: a fixed set name. `[template] name` is the
    ## TEMPLATE's identity (what `--template=` selects); the scaffolded set's
    ## name always comes from the `add` argument.
  schemaUrlPrefixV1*        = "reprobuild.workspace.url-prefix.v1"
    ## A URL prefix shared by many repos (`https://github.com/<org>`), declared
    ## ONCE for the workspace. Distinct from a git remote (`origin`,
    ## `upstream`), which is what `RepoRemoteEntry.name` holds.
  schemaProjectManifestV1*  = "reprobuild.workspace.project.v1"
  schemaVariantManifestV1*  = "reprobuild.workspace.variant.v1"
  schemaLockV1*             = "reprobuild.workspace.lock.v1"
  schemaLockIndexV1*        = "reprobuild.workspace.lock-index.v1"
  schemaSnapshotV1*         = "reprobuild.workspace.snapshot.v1"
  schemaWorkspaceLocalV1*   = "reprobuild.workspace.local.v1"
    ## The schema of the per-checkout state file under its retired name
    ## (`retired_names.nim`). Read ONLY by `repro health --fix`, which moves
    ## that file to the current name (Workspace-Settings-Files.md §8 step 2);
    ## no other verb reads it, and nothing writes it.
  schemaWorkspaceStateV1*   = "reprobuild.workspace.state.v1"
    ## Workspace-Settings-Files.md §5 — the per-checkout state file
    ## `.repro/workspace-state.toml`: the `[workspace]` table of the old file
    ## under a name that says what it is.
  schemaDevelopOverridesV1* = "reprobuild.workspace.develop-overrides.v1"
  pushGatewayOptOutValues* = ["off"]
    ## The values the settings files' top-level `push_gateway` key may take:
    ## Push-Gateway-Wiring-And-Policy.md §7.4 defines exactly one, the
    ## per-workspace opt-out `push_gateway = "off"`. Absent means the default.
  schemaWorkspaceSettingsV1* = "reprobuild.workspace.settings.v1"
    ## Workspace-Settings-Files.md §3 — the shared, committed workspace
    ## settings file `repro-workspace.toml`.
  schemaWorkspaceSettingsLocalV1* = "reprobuild.workspace.settings-local.v1"
    ## Workspace-Settings-Files.md §4 — the per-user, never-committed
    ## `repro-workspace.local.toml`. Carries `[[manifest]]` layers only.
  schemaReprobuildConfigV1* = "reprobuild.config.v1"
    ## HL-1 (Unified-Locking-And-Hooks) — the layered configuration file read
    ## by the system-config (layer 2), user-dotfiles (layer 3), and
    ## VCS-private (layer 5) layers, plus every file an `apply_if`
    ## directive references. A `reprobuild.config.v1` file may carry `apply_if`
    ## path-scoped bindings (inline-table array) and/or `[locking]` routes.

type
  # --- branch roles (Workspace-Branch-Roles.md §2–§3) -------------------------

  BranchRoleValueKind* = enum
    ## What one declarer says about one role.
    brvUndeclared  ## the key is absent: this declarer says nothing
    brvBranch      ## the key names a branch
    brvAbsent      ## the key is `false`: the tier is declared ABSENT, so the
                   ## role falls back exactly as if nothing declared it — but
                   ## the absence is written down and reviewable (§3.1)

  BranchRoleValue* = object
    ## The value of one role key — a branch name, or the boolean `false`.
    ##
    ## Decoded by a custom `readValue` (below) because the strict decoder has
    ## no "string or false" type. A value of any other shape (`true`, a number,
    ## a table) is recorded in `rejected` rather than raised from inside the
    ## decoder, where the key path would be lost; the reader then names the
    ## file and key (`rejectBadRoleValues`).
    kind*: BranchRoleValueKind
    branch*: string        ## the branch when `kind == brvBranch`
    rejected*: string      ## non-empty: the value had an illegal shape

  CustomRoleTable* = object
    ## A `branch-roles` sub-table: custom role name -> branch name or `false`
    ## (Workspace-Branch-Roles.md §2.4, §3.1). Kept in declaration order.
    entries*: seq[(string, BranchRoleValue)]

  BranchRoleDecls* = object
    ## The role declarations ONE declarer makes: a repo fragment's `[repo]`,
    ## a `[profiles.<name>]` table, or the settings file's `[workspace]` table
    ## (the root repo, §3.4). Resolving them — fragment, then its profile,
    ## then the default profile, then the fallback chain (§3.3) — is the
    ## resolver's job, not the reader's; the reader only reports what is
    ## written.
    mainline*: Option[string]
      ## Required to RESOLVE (every repo has a mainline) but optional to
      ## DECLARE, because a profile may supply it. Never `false`.
    unstable*: BranchRoleValue
    staging*: BranchRoleValue
    stable*: BranchRoleValue
    production*: BranchRoleValue
    lts*: BranchRoleValue
    custom*: seq[(string, BranchRoleValue)]
      ## The `branch-roles` sub-table, in declaration order.

const
  builtinOptionalRoleNames* = ["unstable", "staging", "stable", "production",
                               "lts"]
    ## The five optional built-in roles (§2.1). `mainline` is the sixth and
    ## the only required one; it is not in this list because it alone may not
    ## be `false`.

proc isDeclared*(v: BranchRoleValue): bool = v.kind != brvUndeclared

proc roleBranch*(v: string): BranchRoleValue =
  BranchRoleValue(kind: brvBranch, branch: v)

proc roleAbsent*(): BranchRoleValue =
  BranchRoleValue(kind: brvAbsent)

proc branchRoleValueFromToml*(node: TomlValueRef): BranchRoleValue =
  ## Classify one TOML value as a role value. Never raises: an illegal shape
  ## lands in `rejected` for the caller to report with its key path.
  if node.isNil:
    return BranchRoleValue(kind: brvUndeclared)
  case node.kind
  of TomlKind.String:
    BranchRoleValue(kind: brvBranch, branch: node.stringVal)
  of TomlKind.Bool:
    if node.boolVal:
      BranchRoleValue(kind: brvUndeclared,
        rejected: "`true` is not a role value; a role is a branch name, or " &
          "`false` to declare the tier absent")
    else:
      BranchRoleValue(kind: brvAbsent)
  else:
    BranchRoleValue(kind: brvUndeclared,
      rejected: "a role is a branch name or `false`, not a " &
        ($node.kind).toLowerAscii())

proc readValue*(r: var TomlReader, v: var BranchRoleValue) =
  ## Strict-decoder hook for one role key; see `BranchRoleValue`.
  var inner: TomlValueRef
  r.readValue(inner)
  v = branchRoleValueFromToml(inner)

proc readValue*(r: var TomlReader, v: var CustomRoleTable) =
  ## Strict-decoder hook for the INLINE spelling of a `branch-roles` table
  ## (`branch-roles = { beta = "beta" }`). The header spelling
  ## (`[repo.branch-roles]`) never reaches this hook — the pinned
  ## toml-serialization silently drops dotted sub-table headers of a typed
  ## record — so the reader re-reads that spelling from the generic TOML tree
  ## (`reader.nim`, `fillRoleSubTables`).
  parseTable(r, key):
    var inner: TomlValueRef
    r.readValue(inner)
    v.entries.add((key, branchRoleValueFromToml(inner)))

type
  # --- repos/<repo>.toml -----------------------------------------------------

  PreviousRepoIdentity* = object
    ## One prior identity of a repo — Declared-Repository-Renames.md §2.
    ##
    ## Authored as an inline-table-array element under `[extensions]`, NOT
    ## under `[repo]`:
    ##
    ##   [extensions]
    ##   previously = [{ name = "reprobuild-specs", path = "reprobuild-specs" }]
    ##
    ## **`[extensions]`, deliberately.** `decodeStrict` decodes every record
    ## with `TomlUnknownFields` unset, so an unknown key under `[repo]` RAISES
    ## on every `repro` that predates the key — the whole repo, and whatever
    ## resolve needed it, then fails. `Extensions.readValue` above passes an
    ## unknown key under `[extensions]` through untouched, so an older binary
    ## parses such a fragment and behaves exactly as it does today (clones
    ## fresh, leaves the orphan). That is the only placement whose
    ## rollout-order failure degrades to the status quo rather than to a
    ## workspace that will not resolve, which matters because the pin cannot
    ## always be moved before the manifest edit lands (on Windows it waits on
    ## a published release). Promotion to `[repo] previously` under a
    ## `reprobuild.workspace.repo.v2` bump happens when a floor can actually
    ## be asserted. Do not "tidy" this into `[repo]`.
    ##
    ## Every field is OPTIONAL and an omitted field means "unchanged from
    ## `[repo]`", so a pure path move names only `path`. An entry must differ
    ## from the present identity in at least one field (`readRepoFragment`
    ## enforces it). Declaration order is "most recent first"; the validator
    ## cannot verify that, so first-match-wins in `sync` is the only
    ## observable consequence of the order.
    ##
    ## The four fields are exactly the four that determine where a checkout
    ## sits and what it talks to. `branch` is deliberately NOT among them: a
    ## mainline rename strands nothing, because the directory stays where it is
    ## and `repro switch --mainline` already moves a checkout between branches.
    ##
    ## ONE TUPLE ARRAY, NOT TWO PARALLEL LISTS. `path` and `name` are
    ## independent but PAIRED at any given moment, and the pairing is
    ## load-bearing twice: the prior URL is DERIVED from the prior `name` (plus
    ## a prefix), and a repo can move twice (`foo` → `vendor/foo` →
    ## `vendor/bar`), which flat lists cannot express. The inline-table array
    ## is also the shape this schema is already obliged to use — see
    ## `CopyLinkFileEntry` for the pinned deserializer's nested
    ## array-of-tables limitation.
    name*: string
      ## The identity the repo was declared under — what `--only`,
      ## `member_repos`, lock record paths and the sidecar file name used.
    path*: string
      ## The working tree it occupied: workspace-root-relative, forward
      ## slashes, no `..` segment. Validated by the SAME check a live
      ## `repo.path` gets (`declaredCheckoutPathRejection`), because a prior
      ## path places a directory MOVE on every machine that syncs.
    url_prefix*: string
      ## The prefix entry its URL was composed from, for a repo that changed
      ## org or host.
    url_suffix*: string
      ## The remainder under that prefix, for a repo that carried its org in
      ## the suffix.

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

  RepoRemoteEntry* = object
    ## One git-remote binding: the local remote name, and where it points.
    name*: string        ## the LOCAL git remote name (`origin`, `upstream`).
    remote*: string      ## deprecated spelling of `url_prefix`.
    url_prefix*: string  ## the workspace URL prefix this binding resolves through.
    url_suffix*: string
      ## The path under that prefix; `url = url_prefix / url_suffix`. Carried
      ## PER BINDING because a fork's upstream has a different path than the
      ## fork: `reprobuild-cmake` forks `Kitware/CMake`, so a shared name would
      ## compose `Kitware/reprobuild-cmake`. Empty means "default to the repo's
      ## `name`", which is the common single-binding case.

  RepoBody* = object
    name*: string
    path*: string
    remote*: Option[string]        ## deprecated spelling of `url_prefix`.
    remotes*: seq[RepoRemoteEntry]
    revision*: Option[string]
      ## An optional pin of the checkout revision, beside the `mainline` it
      ## follows; pins otherwise live in lock files.
    mainline*: Option[string]
      ## Workspace-Branch-Roles.md §3.1: the branch where completed work is
      ## integrated. Only ever a branch name — never a commit id and never a
      ## fully-qualified ref, so it is always a legal argument to
      ## `git clone --branch`. Optional here when the fragment's profile (or
      ## the workspace default profile) supplies it; a repo that resolves no
      ## mainline at all does not load (§3.3).
    unstable*: BranchRoleValue
    staging*: BranchRoleValue
    stable*: BranchRoleValue
    production*: BranchRoleValue
    lts*: BranchRoleValue
      ## `repo.v2`: the five optional built-in roles (§2.1), each a branch
      ## name or `false` (§3.1).
    profile*: Option[string]
      ## `repo.v2`: the `[profiles.<name>]` of the settings file this repo
      ## follows (§3.2).
    `branch-roles`*: CustomRoleTable
      ## `repo.v2`: custom roles (`[repo.branch-roles]`), name -> branch name
      ## or `false` (§3.1). Under a sub-table so a workspace-chosen word can
      ## never collide with a present or future `[repo]` key.
    url_prefix*: Option[string]
    url_suffix*: Option[string]
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
    # RA-18 — post-sync file materialization + subset tagging
    # (Workspace-Manifests.md §"copyfile / linkfile";
    # Workspace-Membership-Model.md §"Reclaiming `groups`").
    # A missing/empty `tags` means the repo belongs to the implicit
    # `default` tag only. `copyfile`/`linkfile` are applied after a
    # successful checkout and re-applied on every sync (idempotent), so the
    # materialized files track the checked-out revision.
    copyfile*: seq[CopyLinkFileEntry]
    linkfile*: seq[CopyLinkFileEntry]
    tags*: seq[string]
      ## Subset-selection labels (`repro sync --tags=…`). This is a FILTER over
      ## a repo set, not a repo set: membership is `member_repos` /
      ## `member_sets` on a repo-set manifest. The field was spelled `groups`
      ## until the membership model reclaimed that word for the membership
      ## concept; the old spelling is retired and fails as an unknown key.
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

proc roleDecls*(body: RepoBody): BranchRoleDecls =
  ## The role declarations this fragment itself makes (§3.3 step 1).
  BranchRoleDecls(mainline: body.mainline,
    unstable: body.unstable, staging: body.staging, stable: body.stable,
    production: body.production, lts: body.lts,
    custom: body.`branch-roles`.entries)

type

  # --- url-prefixes/<name>.toml ----------------------------------------------

  UrlPrefixBody* = object
    name*: string
    url*: string

  UrlPrefixManifest* = object
    schema*: string
    `url-prefix`*: UrlPrefixBody
    extensions*: Extensions

  # --- repo-sets/<set>.toml --------------------------------------------------

  RepoSetBody* = object
    ## Deliberately just a name and a membership list. Identity fields are
    ## absent by construction rather than by convention.
    name*: string

  RepoSetManifest* = object
    ## Membership is declared as TWO keys rather than one, and that is what
    ## makes a name in both namespaces unrepresentable rather than arbitrated.
    ## A single `members` list had to resolve each bare name against both the
    ## repo and the repo-set namespace, and 7 of the 11 projects in the
    ## metacraft manifest repo carry a set and a repo of the same name
    ## (`codetracer`, `garm`, `isonim`, …). Any tie-break would have made those
    ## resolve by rule rather than by declaration; two keys make
    ## `member_repos = ["codetracer"]` inside `repo-sets/codetracer.toml`
    ## simply unambiguous.
    schema*: string
    `repo-set`*: RepoSetBody
    member_sets*: seq[string]
      ## Names of other repo-sets, expanded recursively. Expanded BEFORE
      ## `member_repos` — see `expandMembers`; the order is load-bearing
      ## because dedup keys on first-seen.
    member_repos*: seq[string]
      ## Names of repo fragments. By NAME, not path, consistent with `depends`
      ## and unlike the `includes` this replaces.
    extensions*: Extensions

  # --- templates/<template>.toml ----------------------------------------------

  TemplateBody* = object
    ## A template's own identity, and nothing else. It carries no
    ## `default_remote` for the same reason a
    ## repo-set does not: a collection-level default would make a member
    ## resolve differently depending on which template happened to scaffold the
    ## set that names it.
    name*: string
      ## The TEMPLATE's name — the value `--template=<name>` and
      ## `[projects] default_template` select. NOT the scaffolded set's name,
      ## which always comes from the `add` argument. That separation is the
      ## whole reason this is a distinct schema: a template that could carry a
      ## set name would be a repo-set that scaffolds a copy of itself.

  TemplateManifest* = object
    ## Workspace-Membership-Model.md §"Templates" — a starting membership for a
    ## new repo-set.
    ##
    ## Templates exist because an empty stub makes every new set hand-list
    ## whatever the last one had, and a set added minutes later can silently
    ## lack something every other set has. The two membership keys are the SAME
    ## two a repo-set carries, so what a template seeds is readable as the
    ## thing it produces rather than as a separate dialect.
    schema*: string
    `template`*: TemplateBody
    member_sets*: seq[string]
    member_repos*: seq[string]
    extensions*: Extensions

  # --- projects/<project>.toml -----------------------------------------------

  ProjectBody* = object
    ## `[project]`. It names no branch: each repo's branches are its roles
    ## (Workspace-Branch-Roles.md §3), and the project's default workspace
    ## branch is the ROOT repository's resolved mainline (§3.4). The keys
    ## that once declared either are refused by name (`retired_names.nim`).
    name*: string
    default_remote*: Option[string]

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
    ## A `[certificates]` table in `projects/<project>.toml`, which is NOT
    ## supported (Test-Certificates TC-9d, operator decision D18). It is
    ## decoded only so ``resolveProject`` can recognise it and refuse the
    ## manifest with a remedy (``refuseLegacyCertificatesTable``) instead of
    ## the strict decoder's generic unknown-key error. No field is read.
    gate_mode*: Option[string]
    required_targets*: seq[string]
    required_platforms*: seq[string]
    ci_trust*: Option[string]
    untracked_inputs*: Option[string]

  ProjectManifest* = object
    schema*: string
    project*: ProjectBody
    remote*: seq[RemoteEntry]
    includes*: seq[string]
      ## deprecated; path-based. Superseded by `member_sets` / `member_repos`.
    member_sets*: seq[string]
    member_repos*: seq[string]
      ## Workspace-Membership-Model.md — the same two membership keys a
      ## repo-set carries. A project IS a repo-set that happens to be enabled,
      ## so it declares membership the same way; only the identity fields above
      ## make it look like a different kind, and those are being retired.
    binary_dependency*: seq[BinaryDependencyEntry]
      ## RA-22 — binary-mode dependencies (see `BinaryDependencyEntry`). A
      ## missing/empty array means the project declares no binary
      ## dependencies; backward-compatible with manifests authored before
      ## RA-22.
    certificates*: CertificatesBody
      ## The retired `[certificates]` table (see `CertificatesBody`). A
      ## manifest that carries it does not resolve (TC-9d).
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

  # --- <workspace-root>/.repro/workspace-state.toml --------------------------

  WorkspaceBody* = object
    project*: string
    projects*: seq[string]
      ## RA-6 — the active PROJECT SET layered into this workspace. The
      ## pilot's ``repro workspace enable`` tracks a SET of project
      ## names (not a single project); this array records that set. The
      ## scalar ``project`` field remains the PRIMARY project (the first
      ## entry of the set, kept non-empty for the M6/M8 single-project
      ## resolver and every existing reader). An empty array means
      ## "single-project workspace" — only ``project`` is meaningful.
    branch*: Option[string]
    feature_started*: Option[bool]
      ## M16 — when ``true``, the current ``branch`` value names a
      ## feature branch the operator deliberately started via
      ## ``repro branch <name> --checkout``. The M10 sync planner
      ## reads this flag and no-ops "clean fast-forwardable" repos
      ## that happen to sit on the marked branch even when the lock
      ## pins a different SHA on it. ``none`` means "not marked"
      ## (backward-compatible with workspaces written before M16).

  ManifestLayer* = object
    ## One manifest layer the composer acquires. Decoded from the `[[manifest]]`
    ## entries of a state file (the pre-settings-file location of the layer
    ## list) and BUILT from the settings files' `[[manifest]]` entries
    ## (`composeSettingsLayers`). `name` and `revision` exist only in the
    ## settings files, so the state-file reader rejects them.
    url*: Option[string]
    local_path*: Option[string]
    visibility*: string
    branch*: Option[string]
    name*: Option[string]
      ## The settings-file layer name (Workspace-Settings-Files.md §3–§4).
      ## Also marks the root repo's own base layer (`workspaceRootLayerName`).
    revision*: Option[string]
      ## A settings-file layer pin (§3): the layer is cloned AT this revision
      ## (`git clone --branch`, so a tag or a branch) and its HEAD is verified
      ## to resolve to it — the RA-17 pin check, applied per layer.
    from_settings*: Option[bool]
      ## Set (`some(true)`) on every layer BUILT from the settings files
      ## (`composeSettingsLayers`) and on the implicit root base layer
      ## `withSettingsLayers` adds; never decoded from a state file (the
      ## state-file reader rejects it). It is the layer's ORIGIN, and the
      ## composer reads it per layer: a settings-file layer composes
      ## additively per project — without `projects/<p>.toml` it contributes
      ## nothing to <p> (Workspace-Settings-Files.md §4 "Layers are additive
      ## per project") — while a layer listed in the legacy state file keeps
      ## the M8 rule that it must declare the project. Per layer rather than
      ## per composition so a workspace mixing both kinds gets each rule.

  WorkspaceLocal* = object
    ## The per-checkout state file `.repro/workspace-state.toml` (`state.v1`).
    ## `manifest` is set only when `repro health --fix` reads a file it is
    ## migrating (`readStateFileForMigration`); every other reader refuses a
    ## state file carrying layers.
    schema*: string
    workspace*: WorkspaceBody
    manifest*: seq[ManifestLayer]
      ## Layers a state file being MIGRATED still records (the retired
      ## `local.v1` kept them there): `repro health --fix` moves them to
      ## `repro-workspace.local.toml` (Workspace-Settings-Files.md §8 step 2).
      ## Always empty from every other reader, which refuses the key (§5). No
      ## writer adds one.
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

  # --- shared tables of the settings file (repro-workspace.toml) ------------
  #
  # The `Bootstrap*` record names are historical: these are the tables of the
  # shared settings file (Workspace-Settings-Files.md §3), kept under their
  # names because every consumer and the HL-1 configuration file share them.

  BootstrapProjectsBody* = object
    default*: seq[string]
      ## Default project set auto-layered when the user hasn't chosen an
      ## explicit project set (consumed by init / `enable --default`).
    default_template*: Option[string]
      ## Workspace-Membership-Model.md §"Templates" — the template
      ## `repro ws sets add` / `projects add` scaffolds from when the operator
      ## names none. Declared in ORG CONFIG, never hardcoded in the binary: an
      ## absent key means "no default", and the stub is the empty one.
      ##
      ## Applying it is REPORTED, never silent. The mechanism exists because
      ## membership was being invisibly hand-copied, so a default that applied
      ## invisibly would reproduce the defect it was introduced to fix;
      ## `--no-template` opts out for the one set that should not have it.

  BootstrapVerifyBody* = object
    ## RA-17 — manifest provenance / trust anchor (Workspace-Manifests.md
    ## §"Manifest Provenance and Verification"). Declared in the host
    ## settings file, NEVER hardcoded. When `require_signature` is true,
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
      ## paths are resolved against the settings file's directory.
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
    ## MO-4 — one per-repo-set → store-backend route in the settings
    ## file's `[locking]` table (Workspace-Manifests.md §"Routing repo-sets
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

  BootstrapForeignEnvBody* = object
    ## NF-4 (Nix-Flake-Coexistence.md §2b) — the `[foreign_env]` table: whether
    ## a directory with NO `repro.nim` may still get a dev environment by
    ## activating a foreign one.
    ##
    ## TWO flags, not one tri-state. They govern different trust decisions: an
    ## `.envrc` is arbitrary shell that Reprobuild would be causing to run,
    ## while a `flake.nix` is evaluated by `nix` under its own sandboxing
    ## rules. A site may reasonably want the second without the first, and one
    ## knob cannot express that.
    ##
    ## `Option` rather than plain `bool` so an unset key means "this layer has
    ## no opinion" and a lower-precedence layer's answer survives. A plain
    ## `bool` would decode a silent `false` in every layer, and the
    ## highest-precedence file present would then always win by saying nothing.
    ##
    ## Both default to absent, i.e. OFF: activating a foreign environment
    ## because a directory happens to contain a file is a decision an operator
    ## makes, not one Reprobuild makes for them.
    auto_load_envrc*: Option[bool]
    auto_load_flake*: Option[bool]

  # --- repro-workspace.toml / repro-workspace.local.toml ----------------------
  #
  # Workspace-Settings-Files.md §3–§4. Both files are decoded from the generic
  # TOML tree by `settings.nim` rather than by the typed strict decoder: the
  # pinned toml-serialization drops dotted sub-table headers
  # (`[profiles.product]`, `[profiles.product.branch-roles]`) of a typed record
  # without an error, and fails with an empty message on several shapes this
  # file uses. The records below are the decoded result, not decode targets.

  WorkspaceRootSettings* = object
    ## `[workspace]` — the ROOT repo's own branch roles (Branch-Roles §3.4)
    ## plus the workspace default profile (§3.2).
    profile*: Option[string]
    default_profile*: Option[string]
    roles*: BranchRoleDecls

  WorkspaceRecordsSettings* = object
    ## `[records]` — the record store (generated lock records). Absent means
    ## committed-lock-only.
    url*: Option[string]
    branch*: Option[string]
    publish_locks*: Option[bool]
      ## MO-14 — OPT-IN to central workspace-lock PUBLICATION. When true, a
      ## passing pre-push gate commits + pushes the `locks/` subtree to the
      ## record store (the RA-7/RA-21 publication boundary). When absent or
      ## false, the workspace operates COMMITTED-LOCK-ONLY: the pre-push gate
      ## still writes/refreshes the lock locally and passes, but never
      ## publishes to the central store (Workspace-Manifests.md §"Lock
      ## publication"). This gates PUBLICATION ONLY — manifest layer fetch and
      ## refresh are independent and unaffected.

  SettingsManifestLayer* = object
    ## One `[[manifest]]` entry as a settings file declares it. Composed into
    ## `ManifestLayer`s by `composeSettingsLayers` (§4 "Layer resolution").
    name*: Option[string]
    url*: Option[string]
    branch*: Option[string]
    visibility*: Option[string]
    revision*: Option[string]
    local_path*: Option[string]

  CustomRoleDecl* = object
    ## `[branch-roles.<name>]` (Branch-Roles §2.4).
    name*: string
    fallback*: string

  WorkspaceSettings* = object
    ## The workspace settings (Workspace-Settings-Files.md §3–§4): the shared
    ## `repro-workspace.toml` (`settings.v1`) and the per-user
    ## `repro-workspace.local.toml` beside it, decoded by `settings.nim`.
    path*: string
      ## The settings file that was read.
    schema*: string
      ## `settings.v1`; `settings-local.v1` for a lone local file
      ## (`readLoneLocalSettings`).
    localPath*: string
      ## The `repro-workspace.local.toml` read beside `path`, or "".
    workspace*: WorkspaceRootSettings
    projects*: BootstrapProjectsBody
    records*: WorkspaceRecordsSettings
    sharedLayers*: seq[SettingsManifestLayer]
      ## `[[manifest]]` of the shared file, in file order.
    localLayers*: seq[SettingsManifestLayer]
      ## `[[manifest]]` of the local file, in file order.
    push_gateway*: Option[string]
      ## Push-Gateway-Wiring-And-Policy.md §7.4's per-WORKSPACE opt-out: the
      ## top-level `push_gateway = "off"` (the one value §7.4 defines; any
      ## other is refused naming the file and key). Shared policy, so the local
      ## file may not set it (§4).
    profiles*: seq[(string, BranchRoleDecls)]
      ## `[profiles.<name>]`, sorted by name (TOML tables are unordered).
    customRoles*: seq[CustomRoleDecl]
      ## `[branch-roles.<name>]`, sorted by name.
    verify*: BootstrapVerifyBody
    develop*: BootstrapDevelopBody
    locking*: BootstrapLockingBody
    foreign_env*: BootstrapForeignEnvBody
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
  # same convention `repro-workspace.toml`'s `[locking] route = [{ … }]` uses:
  #
  #   schema = "reprobuild.config.v1"
  #   apply_if = [{ under = "~/work/acme/", config = "team-routes.toml" }]
  #   [locking]
  #   route = [{ visibility = "team", backend = "git-checkout",
  #              path = "manifests-team", repos = ["core"] }]

  ApplyIfEntry* = object
    ## HL-1 — one `apply_if` path-scoped binding. Authored as an INLINE-table
    ## array element (`apply_if = [{ under = "…", config = "…" }]`), not the
    ## `[[apply_if]]` double-bracket form (the pinned `toml-serialization`
    ## rejects the nested double-bracket array-of-tables — §4.2).
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
    foreign_env*: BootstrapForeignEnvBody
    extensions*: Extensions

  # NOTE on the schema probe: the reader does NOT define a typed "probe"
  # record. Instead it calls
  #     Toml.decode(content, string, "schema")
  # which uses toml-serialization's `moveToKey` machinery to navigate to
  # just the top-level `schema` value, returning the string and ignoring
  # the rest of the file. That avoids defining a parallel probe record
  # whose shape would have to track every schema variant.

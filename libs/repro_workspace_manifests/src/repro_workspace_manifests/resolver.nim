## repro_workspace_manifests/resolver.nim
##
## M6 — Manifest resolver. Reads a `projects/<p>.toml` (M5 surface), walks
## its `includes` list, reads every referenced `repos/<r>.toml` fragment
## (also M5 surface), applies project-level defaults to fragments that omit
## them, and resolves `remote` names against the project's `[[remote]]`
## table.
##
## The output is a `ResolvedProject` value carrying one `ResolvedRepo`
## per fragment, in source order. The engine and CLI consume this typed
## record directly; they never re-walk the includes themselves.
##
## M7 — Variant composer. `resolveVariant(variantFile)` reads a
## `variants/<v>.toml`, resolves its `[variant].base` against the
## manifest-repo root using the SAME path-safety rules M6 applies to
## include paths, calls `resolveProject` on the base, then layers the
## variant's extra `includes` and `[[override]]` entries on top. The
## return type is the SAME `ResolvedProject` M6 emits, so downstream
## consumers (engine, CLI) cannot tell variant from non-variant
## resolutions apart — except for the two fields where they LEGITIMATELY
## differ:
##   - `projectName` carries the variant's `[variant].name`, because the
##     active workspace is referred to by the variant name when one is
##     active.
##   - `projectFile` carries the absolute path of the variant file, so
##     `repro workspace status` can say "active variant: …".
## Everything else — `defaultRevision`, `trunk`, the per-fragment
## `ResolvedRepo` records — is inherited from the base unchanged, then
## mutated only where an override explicitly targets it.
##
## Error policy
## ------------
##
## The resolver reuses M5's `WorkspaceManifestParseError`. The rationale:
##
## - Every resolution failure either originates inside an M5 reader (the
##   included fragment is missing, or has a schema violation), or it is a
##   shape rule on top of the M5 surface (unknown remote, escaping include
##   path, duplicate `(name, path, remote)` triple). In both cases the
##   diagnostic shape M5 already produces — file path, key path,
##   expected/observed schema, inner message — is the right one. Callers
##   that already `except WorkspaceManifestParseError` keep working.
##
## - The alternative (a parallel `ManifestResolutionError`) would force
##   callers to catch two exception types for what is fundamentally one
##   class of failure: "the manifest set is malformed". M6 stays inside
##   M5's diagnostic envelope.
##
## For resolver-specific failures the convention is:
##
## - `keyPath` names the offending structural location
##   (e.g. `includes[2]`, `remote[i].name`).
## - `path` is the project file we were resolving when the failure
##   happened, so the caller always knows which project to look at.
## - `innerMessage` carries the human-readable reason.

## Workspace-Membership-Model.md
## -----------------------------
##
## The resolver additionally accepts the membership-model spellings, ALONGSIDE
## the ones above rather than instead of them, because the manifest repo is
## converted in a separate step and must resolve byte-identically until it is:
##
##   - `member_sets` / `member_repos` (NAMES) as well as `includes` (paths).
##     The two keys are two NAMESPACES: a bare name is resolved against
##     `repo-sets/` or `repos/` according to the key it sits under, never both,
##     so a set and a repo may share a name and each key still has exactly one
##     answer.
##   - repo-sets expand depth-first to any depth, `member_sets` before
##     `member_repos`, with cycle detection that names the full path
##     (`a -> b -> a`) rather than overflowing the stack.
##   - `url-prefixes/<name>.toml` resolves `url_prefix`, with `url =
##     url_prefix / url_suffix` and `url_suffix` defaulting to the repo's
##     `name`. The old `remote` spelling still resolves through the project's
##     `[[remote]]` table, and only THAT path keeps `getFetchUrl`'s
##     "a base ending in .git is used verbatim" special case.
##   - per-binding `url_prefix` / `url_suffix` on `remotes = [{ … }]`, so a
##     fork's `upstream` lands on a different path than its `origin`.
##   - `branch` takes precedence over `revision` when both are present.

import std/[options, os, strutils, tables]
import types
import diagnostics
import reader
import manifest_source

export manifest_source

type
  WorkspaceVisibility* = enum
    ## The four documented visibility tiers a manifest layer may declare
    ## in `.repro/workspace.toml` (see Workspace-And-Develop-Mode.md
    ## §"Workspace Composition and Manifest Layers"). The enum is shared
    ## between M6's single-project resolver (which uses the default
    ## `wvPublic` because no layer information is attached) and M8's
    ## manifest-layer composer (which overwrites the field with the
    ## actual layer's declared value). The "private" tier from the spec
    ## maps to `wvPersonal` here — the workspace TOML uses the strings
    ## "private" and "personal" interchangeably for the per-developer
    ## tier; the enum carries one canonical name.
    wvPublic
    wvOrg
    wvTeam
    wvPersonal

  ResolvedRemote* = object
    ## One git remote of a checkout, after the project manifest's
    ## `[[remote]]` table has been applied to the fragment's declaration.
    ##
    ## The two name fields are DIFFERENT namespaces and must not be
    ## confused: `localName` lives in the checkout's `.git/config`,
    ## `projectRemote` lives in the project manifest.
    localName*: string     ## Git remote name inside the checkout (e.g. "origin", "upstream")
    projectRemote*: string ## Key into the project manifest's `[[remote]]` table (e.g. "metacraft-labs", "github")
    fetchUrl*: string      ## Full constructed fetch URL

  ResolvedPreviousIdentity* = object
    ## One prior identity of a repo, with every field RESOLVED to the
    ## effective value an omitted field inherits from `[repo]`
    ## (Declared-Repository-Renames.md §2).
    ##
    ## `fetchUrl` is the point of resolving these here rather than carrying
    ## the raw `PreviousRepoIdentity` through: a fragment's fetch URL is
    ## COMPOSED from a prefix plus `name`/`url_suffix`, so declaring the prior
    ## NAME is what lets the tool reconstruct the prior URL — and the prior URL
    ## is the primary evidence the relocation identity check reads (§3.3a).
    ## Composition needs the `url-prefixes/` table, which only exists inside
    ## resolution.
    name*: string     ## effective prior repo name
    path*: string     ## effective prior checkout path, workspace-relative
    fetchUrl*: string ## effective prior fetch URL, derived not declared

  ResolvedRepo* = object
    ## Post-resolution facts for a single repo.
    ##
    ## The five load-bearing fields (`name`, `path`, `projectRemote`,
    ## `fetchUrl`, `revision`) are exactly the tuple the milestone names
    ## ("(name, path, fetch-url, revision)"); the `vcs` and `stability`
    ## fields carry the fragment's optional values with the documented
    ## defaults applied; `fragmentPath` is the include path the fragment
    ## was loaded from (useful for diagnostics and provenance reporting).
    ##
    ## The trailing `manifestLayer` and `visibility` fields are populated
    ## by M8's `composeManifestLayers` with the URL / local path of the
    ## manifest layer that declared the repo and that layer's declared
    ## visibility tier. M6 + M7 leave them at the documented defaults
    ## (empty string and `wvPublic`) because no layer information is
    ## attached at the single-project resolution boundary.
    name*: string
    path*: string
    ## Which entry of the project manifest's `[[remote]]` table this repo
    ## resolves through (e.g. "metacraft-labs"). NOT the git remote name
    ## in the checkout — that is `ResolvedRemote.localName`, and
    ## `gitRemoteNameFor` is the mapping between the two.
    ##
    ## One documented exception, preserved from the pre-rename behaviour:
    ## when a fragment declares a `remotes` list but omits the scalar
    ## `repo.remote`, this field holds the FIRST resolved remote's
    ## `localName` instead of a `[[remote]]` key. Note this is NOT because
    ## no key is available — the project's `default_remote` has already
    ## been assigned here, and `remotes[0].remote` is a key too; the
    ## `remotes`-list branch simply overwrites it with the local name.
    ## Both `gitRemoteNameFor` and `cloneUrlFor` handle that case
    ## explicitly; nothing else may assume this field is always a
    ## `[[remote]]` key. Applies to `resolveProject` and `resolveVariant`
    ## alike (the two branches are textually identical).
    projectRemote*: string
    fetchUrl*: string
    remotes*: seq[ResolvedRemote]
    revision*: string
    branch*: string
      ## The branch this repo TRACKS, when the fragment declared one. Only ever
      ## a branch NAME, so it is always a legal `git clone --branch` argument;
      ## `revision` conflated that with "an exact commit to sit at" and the
      ## conflation cost two defects. Empty for a fragment that declares only
      ## `revision`.
      ##
      ## Independent of `revision`, which is where the checkout SITS. A
      ## fragment declaring only `branch` gets that branch name copied into
      ## `revision` so every existing consumer keeps reading one field; a
      ## fragment declaring BOTH keeps its own `revision`, because the pin is
      ## the whole reason it was written.
    vcs*: string
    stability*: string
    # MO-5 — evidence-only private participation marker carried verbatim from
    # the fragment's ``participation`` field. ``"evidence-only"`` means the repo
    # participates via published source-free evidence and is never cloned; any
    # other value (default "") means a normal SHARED repo. See
    # ``RepoBody.participation`` in ``types.nim``.
    participation*: string
    fragmentPath*: string
    manifestLayer*: string
    visibility*: WorkspaceVisibility
    # RA-14 — fetch-acceleration hints carried from the fragment. Empty /
    # zero / false means "no acceleration" (full clone of every head).
    # These never change the resolved tree at the pinned revision.
    cloneFilter*: string
    depth*: int
    singleBranch*: bool
    # RA-18 — post-sync file materialization + subset tags, carried
    # verbatim from the fragment. An empty `tags` means the repo belongs
    # to the implicit `default` tag only (see `effectiveTags`).
    copyfile*: seq[CopyLinkFileEntry]
    linkfile*: seq[CopyLinkFileEntry]
    tags*: seq[string]
    # RA-21 — develop-set dependency edges carried verbatim from the
    # fragment. Names the other repos this repo depends on; the pre-push
    # gate uses these to compute the pushed repo's transitive dependency
    # closure (Workspace-And-Develop-Mode.md §"VCS Hook Integration").
    depends*: seq[string]
    previously*: seq[ResolvedPreviousIdentity]
      ## Declared-Repository-Renames.md §2 — the identities this repo was
      ## previously declared under, most recent first, resolved from
      ## `[extensions] previously`. Empty for the overwhelming majority of
      ## fragments, and INERT whenever a checkout already sits at `path`, so
      ## the key is safe to leave in a fragment forever.

  CertificateGateMode* = enum
    ## A gate's mode, as a certificate policy rule's `gate_mode` /
    ## `commit_gate` resolves for it (TC-9c). `cgmOff` is the DEFAULT (and
    ## the value where no policy rule applies): the pre-push gate runs
    ## exactly as it did before test certificates existed. `cgmAdvisory`
    ## records the coverage result in the gate report (a warning when
    ## uncovered) but NEVER blocks the push.
    ## `cgmRequired` refuses the push unless the submitted certificates cover
    ## the pushed commit for the required targets on each required platform.
    cgmOff = "off"
    cgmAdvisory = "advisory"
    cgmRequired = "required"

  CertificateCiTrust* = enum
    ## TC-4 — the policy's `ci_trust`, the EXPLICIT
    ## decision about whether CI fast-tracks certified work. `cctAdvisory` is
    ## the DEFAULT (and the value for a project that declares no `ci_trust`):
    ## CI re-runs every required target authoritatively but surfaces a valid
    ## certificate as an informational signal — nothing is skipped on trust.
    ## `cctSkip` is the high-trust fast-track: a target covered by a VALID
    ## (registered-signed, unrevoked, commit+lock+platform-matching)
    ## certificate is SKIPPED and the PR fast-tracked. The default is the
    ## SAFER `cctAdvisory` so trust is never granted by omission
    ## (Test-Certificates.md §"CI integration — skipping certified work").
    cctAdvisory = "advisory"
    cctSkip = "skip"

  CertificateUntrackedInputs* = enum
    ## The policy's `untracked_inputs`: what issuance does
    ## about untracked, non-ignored files in the tested repository. They are
    ## not part of the content a certificate names, so a test that read one
    ## ran against something the certificate does not identify
    ## (test-certificates Standard §3.2).
    cuiReadSet = "read-set"
      ## The DEFAULT. Withhold only when a read set captured from the run
      ## shows that it read an untracked file. Without a read set, issue and
      ## report `untracked = true`.
    cuiStrict = "strict"
      ## Withhold whenever any untracked, non-ignored file exists.

  ResolvedProject* = object
    ## A flat view of one `projects/<project>.toml` after include
    ## expansion and default application.
    projectName*: string
    defaultRevision*: string
    trunk*: string
    repos*: seq[ResolvedRepo]
    projectFile*: string
    # Test-Certificates TC-9d: no certificate policy is resolved here any
    # more. The policy is the `[certificate_policy]` snapshot in the
    # `repro.lock` of the content a gate judges, and a project manifest that
    # still carries the old `[certificates]` table does not resolve
    # (`refuseLegacyCertificatesTable`).

const
  defaultRepoVcs* = "git"
  defaultRepoStability* = "tracked"
  defaultManifestTag* = "default"
    ## RA-18 — a repo with no declared `tags` belongs to this implicit
    ## tag (the `repo`-tool convention). A repo's effective tag set is
    ## therefore `tags` when non-empty, else `["default"]`.
  urlPrefixesDirName* = "url-prefixes"
    ## Workspace-Membership-Model.md — where the workspace's URL prefixes are
    ## declared, ONCE each, rather than re-declared per project.
  repoSetsDirName* = "repo-sets"
  reposDirName* = "repos"

# ---- the dedup-by-path conflict rule --------------------------------------
#
# Declared here rather than in `project_set.nim` because there are now TWO
# places a repo can be reached by more than one route — across the projects of
# an active set, and across the members of a repo-set — and they must refuse
# for the same reason with the same evidence. `project_set.nim` re-exports
# both, so its callers are unaffected.

type
  WorkspaceProjectSetConflictError* = object of WorkspaceManifestParseError
    ## PS-4 — raised ONLY when two sources declare one checkout path with
    ## different facts. Callers distinguish this from every other resolution
    ## failure: a conflict is a decision the operator has to make (the set
    ## cannot be resolved at all), whereas an unresolvable or
    ## not-yet-materialized manifest may simply be a workspace whose manifest
    ## checkout has not landed yet.
    ##
    ## The structured fields below carry the same evidence the message
    ## spells out, so a caller that reports the refusal AS DATA
    ## (`repro workspace sets resolve --json`) does not have to parse prose.
    ## Both raise sites populate them; the message text is unchanged.
    checkoutPath*: string
      ## The workspace-relative checkout path the two sources disagree about.
    sources*: seq[string]
      ## The two sources, in order: the one whose declaration was kept
      ## (first-seen) and the one that contradicted it. Project / repo-set
      ## names, as the message names them.
    fields*: seq[string]
      ## The identifiers of the differing facts — the stable keys of
      ## `conflictingFieldIds`, in comparison order.

proc conflictingFieldIds*(existing, candidate: ResolvedRepo): seq[string] =
  ## The load-bearing facts of a checkout: what would be cloned, from where,
  ## at which revision, with which VCS. Two sources may reach these through
  ## differently-NAMED remotes (`origin` vs `metacraft-labs` pointing at the
  ## same fetch base) without disagreeing about anything real, so the remote
  ## KEY is deliberately not compared — the resolved fetch URL is.
  ##
  ## Returns the short, stable identifier of each differing fact (`name`,
  ## `fetchUrl`, `revision`, `vcs` — the `ResolvedRepo` field names, which
  ## are also the keys a resolve report uses). `conflictingFields` renders
  ## the same comparison for a human, so the two can never disagree about
  ## WHICH facts differ.
  if existing.name != candidate.name:
    result.add("name")
  if existing.fetchUrl != candidate.fetchUrl:
    result.add("fetchUrl")
  if existing.revision != candidate.revision:
    result.add("revision")
  if existing.vcs != candidate.vcs:
    result.add("vcs")

proc conflictingFields*(existing, candidate: ResolvedRepo): seq[string] =
  ## `conflictingFieldIds`, rendered for a diagnostic: each differing fact
  ## with both values ("revision (main vs v2)").
  for id in conflictingFieldIds(existing, candidate):
    case id
    of "name":
      result.add("name (" & existing.name & " vs " & candidate.name & ")")
    of "fetchUrl":
      result.add("fetch url (" & existing.fetchUrl & " vs " &
        candidate.fetchUrl & ")")
    of "revision":
      result.add("revision (" & existing.revision & " vs " &
        candidate.revision & ")")
    of "vcs":
      result.add("vcs (" & existing.vcs & " vs " & candidate.vcs & ")")
    else:
      discard

proc validatePreviousIdentities*(repos: openArray[ResolvedRepo];
                                 ownerFile, ownerSchema: string) =
  ## Declared-Repository-Renames.md §2.3, rules 2-4 — the three validator
  ## rules that need the WHOLE resolved set and so cannot be answered by
  ## `readRepoFragment` from one file.
  ##
  ## Rule 2 is the dangerous one and the reason this is an error rather than a
  ## notice. A forge FREES the old name when a repository is renamed and lets
  ## anyone create a new repository there; if a fragment then legitimately
  ## declares that path, a stale prior claim from another fragment would
  ## authorise `sync` to MOVE a directory that belongs to someone else. A live
  ## claim always wins and the prior claim is an error, not a silent loss.
  ##
  ## Rule 3 is the same reasoning for the half of identity that keys lock
  ## records and `--only` selectors. Rule 4 refuses two fragments claiming one
  ## ancestor, because whichever `sync` reached first would win by accident.
  ##
  ## The per-repo `previous_path_claimed_by_live_repo` refusal in `sync` is the
  ## belt to this proc's braces: a manifest can reach a checkout through a
  ## layer composition or an older writer that never passed through here, and
  ## the consequence of getting it wrong is a moved directory.
  if repos.len == 0:
    return
  var liveByPath = initTable[string, string]()
  var liveByName = initTable[string, string]()
  for repo in repos:
    if repo.path notin liveByPath:
      liveByPath[repo.path] = repo.name
    if repo.name notin liveByName:
      liveByName[repo.name] = repo.path
  var claimedPrior = initTable[string, string]()
  for repo in repos:
    for index, prior in repo.previously:
      let keyPath = "extensions.previously[" & $index & "]"
      if prior.path in liveByPath and prior.path != repo.path:
        raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
          "repo '" & repo.name & "' declares previous checkout path '" &
            prior.path & "', but repo '" & liveByPath[prior.path] &
            "' declares that path RIGHT NOW. A live claim wins: drop the " &
            "prior claim, or the next sync would move a directory that " &
            "belongs to another repo")
      if prior.name in liveByName and prior.name != repo.name:
        raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
          "repo '" & repo.name & "' declares previous name '" & prior.name &
            "', but a live repo is declared under that name right now (at '" &
            liveByName[prior.name] & "'). A live claim wins: drop the prior " &
            "claim")
      let priorKey = prior.name & "\t" & prior.path
      if priorKey in claimedPrior and claimedPrior[priorKey] != repo.name:
        raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
          "repos '" & claimedPrior[priorKey] & "' and '" & repo.name &
            "' both declare the previous identity (name='" & prior.name &
            "', path='" & prior.path &
            "'); two repos cannot share one ancestor, and whichever sync " &
            "reached first would win by accident")
      claimedPrior[priorKey] = repo.name

# ---- the retired `[certificates]` table ------------------------------------
#
# Test-Certificates TC-9d (operator decision D18): a test-certificate
# requirement is a certificate policy — declared with `certificatePolicy`
# (`repro_certificates`), enacted by a repository's `repro.nim` with
# `enactCertificatePolicy`, and recorded by `repro lock refresh` as the
# `[certificate_policy]` snapshot in that repository's `repro.lock`, which is
# what every gate reads. The per-project `[certificates]` table of
# `projects/<project>.toml` is not read anywhere. A manifest that still
# carries one is refused, never ignored: ignoring it would silently turn a
# `required` into `off`.

const LegacyCertificatesKeyPath* = "certificates"
  ## The ``keyPath`` of the error a manifest carrying ``[certificates]``
  ## raises, so a caller that must not fail on it (the pre-commit gate) can
  ## still recognise it and say so out loud.

const LegacyCertificatesRemedy* =
  "remove the [certificates] table; declare the requirement as a " &
  "certificate policy (`certificatePolicy` from the repro_certificates " &
  "module), enact it in each repository's repro.nim with " &
  "`enactCertificatePolicy`, and run `repro lock refresh` to record it in " &
  "that repository's repro.lock (see the repro_certificates module " &
  "documentation)"
  ## What to do instead, in the terms of the policy design.

proc carriesLegacyCertificatesTableIn*(project: ProjectManifest;
                                       content: string): bool =
  ## Whether the manifest whose text is ``content`` (already decoded as
  ## ``project``) carries a ``[certificates]`` table. A set field is enough;
  ## an EMPTY table is found by its header, so even a table that sets nothing
  ## is reported rather than tolerated. Content-level, so a manifest read from
  ## a git revision is checked exactly like one read from disk.
  let c = project.certificates
  if c.gate_mode.isSome or c.ci_trust.isSome or c.untracked_inputs.isSome or
      c.required_targets.len > 0 or c.required_platforms.len > 0:
    return true
  for raw in content.splitLines():
    let line = raw.strip()
    if line.startsWith("[") and not line.startsWith("[["):
      # The header ends at its first `]`: a trailing comment
      # (`[certificates] # ...`) and a quoted key (`["certificates"]`)
      # name the same table.
      let close = line.find(']')
      if close < 0: continue
      let header = line[1 ..< close].strip().replace("\"", "")
      if header == "certificates" or header.startsWith("certificates."):
        return true
  false

proc carriesLegacyCertificatesTable*(project: ProjectManifest;
                                     projectFile: string): bool =
  ## ``carriesLegacyCertificatesTableIn`` over the text of ``projectFile``.
  ## An unreadable file contributes no header (the decoded fields still
  ## count), as before.
  var content = ""
  try:
    content = readFile(projectFile)
  except IOError:
    discard
  carriesLegacyCertificatesTableIn(project, content)

proc legacyCertificatesTableMessage*(projectFile: string): string =
  ## The diagnostic for a manifest that carries ``[certificates]``.
  "the [certificates] table in " & projectFile & " is not supported: " &
    "test-certificate requirements come from a certificate policy that each " &
    "repository enacts and records in its repro.lock, which is what every " &
    "gate reads. It is refused rather than ignored, because ignoring it " &
    "would silently turn its gate_mode into off. Remedy: " &
    LegacyCertificatesRemedy

proc refuseLegacyCertificatesTable*(project: ProjectManifest;
                                    projectFile: string) =
  ## Raise ``WorkspaceManifestParseError`` (key path
  ## ``LegacyCertificatesKeyPath``) when the project manifest carries a
  ## ``[certificates]`` table.
  if carriesLegacyCertificatesTable(project, projectFile):
    raiseManifestError(projectFile, LegacyCertificatesKeyPath,
      schemaProjectManifestV1, schemaProjectManifestV1,
      legacyCertificatesTableMessage(projectFile))

proc refuseLegacyCertificatesTableIn(project: ProjectManifest;
                                     content, displayPath: string) =
  ## ``refuseLegacyCertificatesTable`` for a manifest already read as
  ## ``content``; ``displayPath`` is what the diagnostic names.
  if carriesLegacyCertificatesTableIn(project, content):
    raiseManifestError(displayPath, LegacyCertificatesKeyPath,
      schemaProjectManifestV1, schemaProjectManifestV1,
      legacyCertificatesTableMessage(displayPath))

# ---- RA-18 subset tags -----------------------------------------------------
#
# A tag is a FILTER over a repo set, not a repo set. The distinction is why the
# field is no longer spelled `groups`: membership — which repos belong together
# — is `member_repos` / `member_sets` on a repo-set manifest, and the word
# "group" was holding a filter that only ever narrowed an already-resolved set
# (Workspace-Membership-Model.md §"Reclaiming `groups`").

proc effectiveTags*(repo: ResolvedRepo): seq[string] =
  ## The repo's effective tag set: its declared `tags` when it has any,
  ## otherwise the implicit `["default"]`. A repo that explicitly lists tags
  ## WITHOUT naming `default` is NOT in `default` (mirroring `repo`, where
  ## listing a group opts out of the implicit membership).
  if repo.tags.len > 0: repo.tags
  else: @[defaultManifestTag]

proc repoSelectedByTags*(repo: ResolvedRepo;
                         includeTags, excludeTags: seq[string]): bool =
  ## RA-18 subset selection. `includeTags` is the requested `--tags`
  ## set (empty means "no `--tags` filter": every repo is selected unless
  ## excluded). `excludeTags` is the `-<tag>` set. A repo is selected
  ## when (a) `includeTags` is empty OR the repo carries at least one
  ## included tag, AND (b) the repo carries NONE of the excluded tags.
  ## Exclusion wins over inclusion, matching `repo`'s `groups=foo,-bar`.
  let tags = effectiveTags(repo)
  for t in excludeTags:
    if t in tags:
      return false
  if includeTags.len == 0:
    return true
  for t in includeTags:
    if t in tags:
      return true
  false

# ---- helpers --------------------------------------------------------------

proc normalizeIncludePath(projectFile, raw: string): string =
  ## Validate an include path string and return it as a path relative to the
  ## manifest-repo root (`normalizeRelPath`), for the `ManifestSource` the
  ## project is resolved from to read. `projectFile` is the project's display
  ## path; it only frames diagnostics. The checks are purely lexical: whether
  ## the target exists is the source's question, asked by the caller.
  ##
  ## Include paths in the TOML are written with forward slashes and are
  ## interpreted relative to the manifest-repo root — i.e. the directory
  ## that holds `projects/` (and therefore the parent of the project
  ## file's directory). They must NOT be absolute and must NOT escape
  ## the manifest root via `..`.
  if raw.len == 0:
    raiseManifestError(projectFile, "includes",
      schemaProjectManifestV1, schemaProjectManifestV1,
      "include path is empty")
  if isAbsolute(raw):
    raiseManifestError(projectFile, "includes",
      schemaProjectManifestV1, schemaProjectManifestV1,
      "include path is absolute (must be relative to the manifest root): '" &
        raw & "'")
  # Workspace-Manifests.md §"Common Conventions" — paths use forward
  # slashes regardless of host OS. Reject backslashes outright so a
  # Windows-authored manifest can't accidentally smuggle host-specific
  # separators in.
  if '\\' in raw:
    raiseManifestError(projectFile, "includes",
      schemaProjectManifestV1, schemaProjectManifestV1,
      "include path uses backslash separators (must be forward slashes): '" &
        raw & "'")
  # Walk the path components manually so we reject any `..` segment
  # before the OS resolves it. Even if `..` would land back inside the
  # manifest root (e.g. `projects/../repos/foo.toml`), we reject it as
  # a matter of policy: include paths should be the canonical form.
  for component in raw.split('/'):
    if component == "..":
      raiseManifestError(projectFile, "includes",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "include path escapes the manifest root via '..': '" & raw & "'")
  result = normalizeRelPath(raw)

# ---- fetch-URL construction -----------------------------------------------

proc isVerbatimFetchBase*(fetch: string): bool =
  ## `true` when `getFetchUrl` uses this `fetch` VERBATIM instead of appending
  ## a repo name — i.e. it already points at one repository rather than at a
  ## base other repos hang off. Manifest AUTHORING has to make the same
  ## distinction (such a `fetch` can serve exactly one URL and can never be
  ## reused), so the predicate lives here and both sides call it.
  ##
  ## Takes the RAW `fetch` string: `canonicalGitUrl` strips the `.git` from
  ## network URLs, and a canonicalized base can no longer be told apart from a
  ## composable one.
  fetch.endsWith(".git") or fetch.endsWith(".git/")

proc getFetchUrl*(fetchBase, repoName: string): string =
  ## Build a repo's clone URL from its remote's `fetch` base and the repo's
  ## server-side `name`, following Android-`repo` manifest semantics: the
  ## clone URL is `<remote fetch>/<project name>` (the `name` attribute, NOT
  ## the local checkout `path`). A `fetch` base that already points at a full
  ## repo (ends in `.git`) is used verbatim; otherwise the `name` is appended.
  ##
  ## Exported because manifest AUTHORING (`repro workspace repos add`)
  ## has to invert this function: given a requested clone URL it must find the
  ## declared remote that already composes to it. Authoring and resolution
  ## must never drift apart, so both sides call this one proc.
  if fetchBase.len == 0:
    ""
  elif isVerbatimFetchBase(fetchBase):
    fetchBase
  else:
    fetchBase & "/" & repoName

# ---- remote planning (manifest authoring) ---------------------------------
#
# `repro workspace repos add <repo> --project=<p> --remote=URL` has to turn
# a clone URL into a `repos/<repo>.toml` fragment plus, at most, one new
# `[[remote]]` entry in `projects/<project>.toml`. The rules below are the
# inverse of `getFetchUrl`:
#
#   1. REUSE THE MOST SPECIFIC DECLARED BASE — of every declared `fetch` base
#      that can serve the URL, take the LONGEST, and put whatever path remains
#      into the fragment's `name` (Android-`repo` semantics: `name` is the
#      server-side path, `path` is the local checkout dir). Nothing is added
#      to the project's remote table. This single rule reproduces both
#      hand-written families in the pilot manifests, which declare `github` →
#      `https://github.com` AND `metacraft-labs` → `https://github.com/metacraft-labs`:
#
#        https://github.com/metacraft-labs/nim-shm-queue
#          → remote = "metacraft-labs", name = "nim-shm-queue"
#            (the longer base wins; the name stays bare, as in
#             `repos/nim-shm-queue.toml`)
#        https://github.com/llvm/llvm-project
#          → remote = "github", name = "llvm/llvm-project"
#            (no `llvm` base is declared, so the generic host base serves it
#             and the org travels in `name`, as in `repos/llvm-project.toml`)
#
#      A `fetch` that already points at ONE repo (ends in `.git`) is used
#      verbatim by `getFetchUrl`, so it is not a base anything can be appended
#      to: it serves a URL only by BEING it, and then the requested name is
#      kept as-is.
#   2. MINT — no declared base prefixes the URL: add exactly ONE entry, named
#      after the org (or the host when the URL has no org segment) and carrying
#      the org base as `fetch`, so the NEXT repo from the same org hits rule 1
#      and adds nothing.
#
# A per-repo remote (`<repo>-origin` with the full URL as `fetch`) is never
# PLANNED here: it grows the project's shared remote table by one entry per
# repo and can never be reused, because a `fetch` ending in `.git` is used
# verbatim. A caller may still fall back to one when it cannot use the plan it
# got — see `preserveRepoName` below.
#
# `preserveRepoName` is for callers that cannot accept a server-side name:
# `repro add` records develop-set `depends` edges that key off `[repo].name`,
# so a fragment whose `name` is not the added repo's own name would leave those
# edges dangling. Such a caller asks for a plan that keeps the name, which
# restricts rule 1 to bases that compose to the URL with the requested name
# unchanged. (`repro workspace repos add` writes no `depends` edges and
# so takes the unrestricted, convention-matching plan.)

type
  RepoRemotePlan* = object
    ## The outcome of planning a repo fragment's remote against a project's
    ## existing `[[remote]]` table.
    remoteName*: string
      ## The `[repo].remote` value the fragment should carry.
    repoName*: string
      ## The `[repo].name` value the fragment should carry. Equal to the
      ## requested repo name except when the URL's server-side path differs
      ## from the local checkout dir (`llvm/llvm-project` checked out as
      ## `llvm-project`, or a bare-repo URL whose last segment keeps its
      ## `.git`).
    mintedFetch*: string
      ## When non-empty, the `fetch` base of a NEW `[[remote]]` entry that the
      ## caller must append to the project manifest under `remoteName`. Empty
      ## means an existing declared remote was reused — add nothing.
    error*: string
      ## Non-empty when the URL cannot be turned into a manifest entry at all
      ## (e.g. it carries no path segment to use as a repo name).

proc isLocalGitUrl(url: string): bool =
  ## `true` for URLs that name a directory on a filesystem (`file://…`, an
  ## absolute path, a Windows drive path). For those the trailing `.git` is
  ## part of the DIRECTORY NAME and must never be stripped — `file:///srv/x`
  ## and `file:///srv/x.git` are two different places. Every network git host
  ## in practice serves `…/repo` and `…/repo.git` as the same repository, so
  ## the suffix is optional there and safe to normalize away.
  url.startsWith("file://") or url.startsWith("/") or url.startsWith("\\\\") or
    (url.len >= 3 and url[1] == ':' and (url[2] == '/' or url[2] == '\\'))

proc canonicalGitUrl*(url: string): string =
  ## Normalize a clone URL for comparison: drop a trailing `/`, then drop a
  ## trailing `.git` (network URLs only — see `isLocalGitUrl`).
  result = url
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)
  if not isLocalGitUrl(result) and result.endsWith(".git"):
    result.setLen(result.len - ".git".len)
    while result.len > 1 and result.endsWith("/"):
      result.setLen(result.len - 1)

proc splitLastSegment(url: string): tuple[base, leaf: string] =
  ## Split a canonical URL into everything before the final `/` and the final
  ## segment itself. Returns an empty `base` when there is no separator.
  let idx = url.rfind('/')
  if idx <= 0:
    ("", url)
  else:
    (url[0 ..< idx], url[idx + 1 .. ^1])

proc orgLabelFor(base: string): string =
  ## The name to give a newly minted remote: the org segment of the base
  ## (`https://github.com/metacraft-labs` → `metacraft-labs`), or — when the
  ## base is just a host — the host's first label (`https://github.com` →
  ## `github`, matching the hand-written `github` remote in the pilot
  ## manifests).
  var rest = base
  let scheme = rest.find("://")
  var hostOnly = false
  if scheme >= 0:
    rest = rest[scheme + 3 .. ^1]
    hostOnly = '/' notin rest
  elif ':' in rest:
    # scp-style `git@host:org/repo`.
    rest = rest[rest.find(':') + 1 .. ^1]
    hostOnly = rest.len == 0
  if hostOnly or rest.len == 0:
    # Host (possibly `user@host:port`) — take its first DNS label.
    var host = if scheme >= 0: rest else: base
    let at = host.rfind('@')
    if at >= 0: host = host[at + 1 .. ^1]
    let colon = host.find(':')
    if colon >= 0: host = host[0 ..< colon]
    let dot = host.find('.')
    result = if dot > 0: host[0 ..< dot] else: host
  else:
    let idx = rest.rfind('/')
    result = if idx >= 0: rest[idx + 1 .. ^1] else: rest
  # A remote name is a TOML key-ish identifier in practice; keep it tame.
  if result.endsWith(".git"):
    result.setLen(result.len - ".git".len)

proc hostLabelFor(base: string): string =
  ## The host's first DNS label, used to disambiguate a minted remote name
  ## that collides with an existing, differently-pointed remote.
  var rest = base
  let scheme = rest.find("://")
  if scheme >= 0:
    rest = rest[scheme + 3 .. ^1]
  let at = rest.rfind('@')
  if at >= 0 and (rest.find('/') < 0 or at < rest.find('/')):
    rest = rest[at + 1 .. ^1]
  var host = rest
  for sep in ['/', ':']:
    let idx = host.find(sep)
    if idx >= 0: host = host[0 ..< idx]
  let dot = host.find('.')
  result = if dot > 0: host[0 ..< dot] else: host

proc planRepoRemote*(remotes: openArray[RemoteEntry];
                     defaultRemote: string;
                     repoName, requestedUrl: string;
                     preserveRepoName = false): RepoRemotePlan =
  ## Plan the `[repo].remote` / `[repo].name` of a fragment for `repoName`
  ## cloned from `requestedUrl`, against a project's declared `remotes`.
  ## See the rules documented above this type.
  result.repoName = repoName
  if requestedUrl.len == 0:
    result.error = "remote URL is empty"
    return
  let wanted = canonicalGitUrl(requestedUrl)

  # Rule 1 — reuse the MOST SPECIFIC declared base that can serve the URL.
  # Primary key: the length of the matched base, so `metacraft-labs` beats the
  # generic `github` for a repo under that org and the fragment's `name` stays
  # bare. Tie-break when several bases are equally specific (a project may
  # declare two names for one org): the project's `default_remote` first, then
  # a remote named after the org segment of its own base (`metacraft-labs`
  # beats a generic `origin` alias), then declaration order.
  var bestLen = -1
  var bestRank = high(int)
  var bestRepoName = ""
  for idx, r in remotes.pairs:
    if r.fetch.len == 0: continue
    let rBase = canonicalGitUrl(r.fetch)
    if rBase.len == 0: continue
    var candidateName = ""
    if isVerbatimFetchBase(r.fetch):
      # Not a base: `getFetchUrl` ignores the name, so this remote serves the
      # URL only by being it, and the requested name is kept.
      if rBase != wanted: continue
      candidateName = repoName
    elif wanted.startsWith(rBase & "/"):
      candidateName = wanted[rBase.len + 1 .. ^1]
    else:
      continue
    if candidateName.len == 0: continue
    if preserveRepoName and candidateName != repoName: continue
    var rank = idx
    if r.name == orgLabelFor(rBase): rank -= 1_000
    if defaultRemote.len > 0 and r.name == defaultRemote: rank -= 1_000_000
    if rBase.len > bestLen or (rBase.len == bestLen and rank < bestRank):
      bestLen = rBase.len
      bestRank = rank
      result.remoteName = r.name
      bestRepoName = candidateName
  if result.remoteName.len > 0:
    result.repoName = bestRepoName
    return

  let (base, leaf) = splitLastSegment(wanted)
  if base.len == 0 or leaf.len == 0:
    result.error = "remote URL '" & requestedUrl &
      "' has no repository path segment to compose a manifest entry from"
    return

  # Rule 2 — mint ONE org-named remote carrying the org base, so the next
  # repo from the same org reuses it via rule 1.
  result.repoName = leaf
  var candidate = orgLabelFor(base)
  if candidate.len == 0: candidate = hostLabelFor(base)
  if candidate.len == 0: candidate = "origin"
  var taken = initTable[string, string]()
  for r in remotes:
    taken[r.name] = canonicalGitUrl(r.fetch)
  var name = candidate
  var attempt = 0
  while taken.hasKey(name):
    if taken[name] == base:
      # Same base under a different name — reuse it rather than duplicating.
      result.remoteName = name
      result.mintedFetch = ""
      return
    inc attempt
    name =
      if attempt == 1 and hostLabelFor(base).len > 0 and
          hostLabelFor(base) != candidate:
        hostLabelFor(base) & "-" & candidate
      else:
        candidate & "-" & $(attempt + 1)
  result.remoteName = name
  result.mintedFetch = base

type
  RepoUrlPrefixPlan* = object
    ## The membership-model counterpart of `RepoRemotePlan`: how a requested
    ## clone URL is split into a declared `url_prefix` plus the `url_suffix`
    ## under it. Same reuse-the-most-specific-then-mint rules, minus the
    ## verbatim case, which does not exist on this path.
    prefixName*: string
    urlSuffix*: string
      ## Written into the fragment only when it differs from the repo's `name`
      ## — the whole point of splitting the two fields is that `name` stops
      ## carrying URL structure.
    mintedUrl*: string
      ## When non-empty, the `url` of a NEW `url-prefixes/<prefixName>.toml`
      ## the caller must create. Empty means an existing prefix was reused.
    error*: string

proc planRepoUrlPrefix*(prefixes: Table[string, string];
                        repoName, requestedUrl: string): RepoUrlPrefixPlan =
  ## Plan the `url_prefix` / `url_suffix` of a fragment for `repoName` cloned
  ## from `requestedUrl`, against the workspace's declared url prefixes.
  ##
  ## Rule 1, REUSE THE MOST SPECIFIC: of every declared prefix that the URL
  ## sits under, take the longest, and put the remainder in `url_suffix`. So a
  ## workspace declaring both `github` → `https://github.com` and
  ## `metacraft-labs` → `https://github.com/metacraft-labs` gets a bare suffix
  ## for the org's own repos and `llvm/llvm-project` for the generic one.
  ##
  ## Rule 2, MINT ONE: no declared prefix serves the URL, so add exactly one,
  ## named after the org, carrying the org base — and the NEXT repo from that
  ## org hits rule 1 and adds nothing. Growing one prefix per repo is what this
  ## avoids, and is why the minted prefix is the org base rather than the full
  ## repo URL.
  if requestedUrl.len == 0:
    result.error = "remote URL is empty"
    return
  let wanted = canonicalGitUrl(requestedUrl)

  var bestLen = -1
  for name, url in prefixes:
    let base = canonicalGitUrl(url)
    if base.len == 0: continue
    if not wanted.startsWith(base & "/"): continue
    let suffix = wanted[base.len + 1 .. ^1]
    if suffix.len == 0: continue
    # Ties broken by name so the plan is deterministic across table orders —
    # a `Table` iteration order is not one an operator can predict, and a
    # scaffolding decision that varies run to run is not reviewable.
    if base.len > bestLen or (base.len == bestLen and name < result.prefixName):
      bestLen = base.len
      result.prefixName = name
      result.urlSuffix = suffix
  if result.prefixName.len > 0:
    return

  let (base, leaf) = splitLastSegment(wanted)
  if base.len == 0 or leaf.len == 0:
    result.error = "remote URL '" & requestedUrl &
      "' has no repository path segment to compose a manifest entry from"
    return
  result.urlSuffix = leaf
  var candidate = orgLabelFor(base)
  if candidate.len == 0: candidate = hostLabelFor(base)
  if candidate.len == 0: candidate = "origin"
  var name = candidate
  var attempt = 0
  while name in prefixes:
    if canonicalGitUrl(prefixes[name]) == base:
      # The same base under a different name — reuse rather than duplicate.
      result.prefixName = name
      result.mintedUrl = ""
      return
    inc attempt
    name =
      if attempt == 1 and hostLabelFor(base).len > 0 and
          hostLabelFor(base) != candidate:
        hostLabelFor(base) & "-" & candidate
      else:
        candidate & "-" & $(attempt + 1)
  result.prefixName = name
  result.mintedUrl = base

# ---- Workspace-Membership-Model.md: url prefixes ---------------------------

proc loadUrlPrefixesAt*(source: ManifestSource): Table[string, string] =
  ## Every `url-prefixes/<name>.toml` of `source`, as name -> url, read in
  ## sorted file-name order.
  ##
  ## Declared ONCE for the workspace rather than per project: a label like
  ## `metacraft-labs` is a fact about where an org's repos live, not a fact
  ## about any one project, and re-declaring it per project is what made a
  ## fragment unshareable without every consumer also learning the remote names
  ## it happens to reference.
  ##
  ## A missing directory is not an error — an unconverted manifest repo has
  ## none, and every fragment in it resolves through the project's
  ## `[[remote]]` table instead.
  result = initTable[string, string]()
  for rel in source.listTomlFiles(urlPrefixesDirName):
    let file = source.displayPath(rel)
    let manifest = readUrlPrefixFromContent(
      source.readManifestText(rel, schemaUrlPrefixV1), file)
    let name = manifest.`url-prefix`.name
    let url = manifest.`url-prefix`.url
    if name in result and result[name] != url:
      raiseManifestError(file, "url-prefix.name",
        schemaUrlPrefixV1, schemaUrlPrefixV1,
        "url prefix '" & name & "' is declared twice with different urls ('" &
          result[name] & "' vs '" & url &
          "'); a prefix is workspace-wide, so the name has to mean one place")
    result[name] = url

proc loadUrlPrefixes*(manifestRoot: string): Table[string, string] =
  ## `loadUrlPrefixesAt` over the directory `manifestRoot`.
  loadUrlPrefixesAt(newDirectorySource(manifestRoot))

# ---- shared per-fragment resolution ---------------------------------------
#
# One proc serves `includes`, `members`, and the variant composer's extra
# includes. They differ only in what they blame in a diagnostic, never in how a
# fragment resolves — and keeping that single is what lets the membership model
# land without the unconverted manifests moving.

type
  FragmentContext = object
    ## Everything OUTSIDE a repo fragment that its resolution consults.
    remotes: Table[string, string]
      ## The project's `[[remote]]` table: name -> `fetch` base. Empty when the
      ## owner is a repo-set, which has no such table by construction.
    urlPrefixes: Table[string, string]
      ## `url-prefixes/<name>.toml`: name -> url.
    defaultRemote: string
    defaultRevision: string
    ownerLabel: string
      ## How a diagnostic refers to the manifest carrying the remote table —
      ## "the project" for M6, "the base project" for M7's variant composer.
    source: ManifestSource
      ## Where every fragment and repo-set is read from — the one route by
      ## which resolution reaches the metadata (`manifest_source.nim`).

proc resolveUrlPrefix(ctx: FragmentContext; ownerFile, ownerSchema, keyPath,
                      reference, prefixName: string): string =
  ## The url a `url_prefix` name resolves to. An undeclared name is refused
  ## rather than composed into a broken URL that only fails at clone time on
  ## somebody else's machine.
  if prefixName in ctx.urlPrefixes:
    return ctx.urlPrefixes[prefixName]
  raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
    "fragment '" & reference & "' references unknown url prefix '" &
      prefixName & "' (no `" & urlPrefixesDirName / (prefixName & ".toml") &
      "` declares it)")

proc composePrefixedUrl(prefixUrl, suffix: string): string =
  ## `url = url_prefix + "/" + url_suffix`. Unconditionally — there is
  ## deliberately no "a prefix that already ends in .git is used verbatim"
  ## branch here, because a field whose meaning depends on the shape of its own
  ## value is a defect waiting for the first input of the other shape. That
  ## special case survives only on the old `remote` path, in `getFetchUrl`.
  var base = prefixUrl
  while base.len > 1 and base.endsWith("/"):
    base.setLen(base.len - 1)
  base & "/" & suffix

proc resolveFragment(ctx: FragmentContext; fragmentRel: string;
                     ownerFile, ownerSchema, keyPath, reference: string):
    ResolvedRepo =
  ## Read one `repos/<r>.toml` (`fragmentRel`, relative to the source root)
  ## from `ctx.source` and resolve it against `ctx`. `fragmentPath` is the
  ## source's display path for it: the absolute file for a directory source.
  ##
  ## `reference` is how the owning manifest named this fragment — an include
  ## PATH (`repos/foo.toml`) or a member NAME (`foo`) — and appears verbatim in
  ## every diagnostic, so the operator is pointed at what they actually wrote.
  let fragmentAbs = ctx.source.displayPath(fragmentRel)
  let fragment = readRepoFragmentFromContent(
    ctx.source.readManifestText(fragmentRel, schemaRepoFragmentV2), fragmentAbs)

  result.name = fragment.repo.name
  result.path =
    if fragment.repo.path.len > 0: fragment.repo.path
    else: fragment.repo.name
  result.fragmentPath = fragmentAbs

  let repoUrlPrefix =
    if fragment.repo.url_prefix.isSome: fragment.repo.url_prefix.get()
    else: ""
  let repoUrlSuffix =
    if fragment.repo.url_suffix.isSome: fragment.repo.url_suffix.get()
    else: ""
  # `url_suffix` defaults to `name`, which is the common single-binding case.
  # The two are separate fields precisely so `name` can go back to being
  # identity in the workspace rather than doubling as the path under the
  # prefix (`name = "microsoft/BuildXL"`).
  let defaultSuffix =
    if repoUrlSuffix.len > 0: repoUrlSuffix else: fragment.repo.name

  # Resolve one `remotes = [{ … }]` binding. A binding that names a
  # `url_prefix` takes the new path (its OWN suffix, so a fork's upstream can
  # sit at a different path); one that names only the old `remote` keeps
  # composing through the project's `[[remote]]` table exactly as before.
  proc resolveBinding(entry: RepoRemoteEntry): ResolvedRemote =
    if entry.url_prefix.len > 0:
      let suffix =
        if entry.url_suffix.len > 0: entry.url_suffix else: fragment.repo.name
      let prefix = resolveUrlPrefix(ctx, ownerFile, ownerSchema, keyPath,
        reference, entry.url_prefix)
      return ResolvedRemote(localName: entry.name,
                            projectRemote: entry.url_prefix,
                            fetchUrl: composePrefixedUrl(prefix, suffix))
    # `remote` resolves against the project's `[[remote]]` table and NOWHERE
    # else. Falling back to `url-prefixes/` when the table has no such entry
    # was tried and removed: it only ever fires where resolution would have
    # failed, which is exactly where a typo lives, and turning a typo into a
    # silent success is a worse failure mode than the transitional convenience
    # is worth. The conversion is one scripted commit and never lands in the
    # half-state the fallback was protecting.
    if entry.remote in ctx.remotes:
      return ResolvedRemote(localName: entry.name, projectRemote: entry.remote,
        fetchUrl: getFetchUrl(ctx.remotes[entry.remote], fragment.repo.name))
    raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
      "fragment '" & reference & "' references unknown remote '" &
        entry.remote & "' (not declared in " & ctx.ownerLabel &
        "'s [[remote]] table)")

  if repoUrlPrefix.len > 0:
    # Membership-model path. The primary binding is ALWAYS the local remote
    # `origin`, so a checkout's remotes look like an ordinary clone's; the
    # predecessor tool named the primary after the MANIFEST remote, which is
    # why its checkouts did not.
    let prefix = resolveUrlPrefix(ctx, ownerFile, ownerSchema, keyPath,
      reference, repoUrlPrefix)
    let originUrl = composePrefixedUrl(prefix, defaultSuffix)
    var resolvedRemotes = @[ResolvedRemote(localName: "origin",
      projectRemote: repoUrlPrefix, fetchUrl: originUrl)]
    for entry in fragment.repo.remotes:
      let binding = resolveBinding(entry)
      # A binding that names `origin` itself is the operator being explicit
      # about the primary, not a second remote with the same name.
      var replaced = false
      for i in 0 ..< resolvedRemotes.len:
        if resolvedRemotes[i].localName == binding.localName:
          resolvedRemotes[i] = binding
          replaced = true
          break
      if not replaced:
        resolvedRemotes.add(binding)
    result.remotes = resolvedRemotes
    result.projectRemote = resolvedRemotes[0].projectRemote
    result.fetchUrl = resolvedRemotes[0].fetchUrl
  else:
    # Pre-membership-model path, unchanged. `projectRemote` keeps its
    # documented irregularity (see `ResolvedRepo.projectRemote`): a fragment
    # that lists `remotes` but omits the scalar `repo.remote` puts the FIRST
    # binding's LOCAL name there rather than a `[[remote]]` key.
    let fragmentRemote =
      if fragment.repo.remote.isSome: fragment.repo.remote.get()
      else: ""
    if fragmentRemote.len > 0:
      result.projectRemote = fragmentRemote
    elif ctx.defaultRemote.len > 0:
      result.projectRemote = ctx.defaultRemote
    else:
      raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
        "fragment '" & reference &
          "' omits `repo.remote` and " & ctx.ownerLabel &
          " has no `default_remote`")

    var resolvedRemotes = newSeq[ResolvedRemote]()
    if fragment.repo.remotes.len > 0:
      for entry in fragment.repo.remotes:
        resolvedRemotes.add(resolveBinding(entry))
      let primaryName =
        if fragmentRemote.len > 0: fragmentRemote
        else: resolvedRemotes[0].localName
      result.projectRemote = primaryName
      var primary = resolvedRemotes[0]
      for r in resolvedRemotes:
        if r.localName == primaryName:
          primary = r
          break
      result.fetchUrl = primary.fetchUrl
    else:
      if result.projectRemote in ctx.remotes:
        result.fetchUrl =
          getFetchUrl(ctx.remotes[result.projectRemote], fragment.repo.name)
      else:
        raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
          "fragment '" & reference & "' references unknown remote '" &
            result.projectRemote & "' (not declared in " & ctx.ownerLabel &
            "'s [[remote]] table)")
      resolvedRemotes.add(ResolvedRemote(localName: "origin",
        projectRemote: result.projectRemote, fetchUrl: result.fetchUrl))
    result.remotes = resolvedRemotes

  # Resolve branch and revision. They answer DIFFERENT questions and a fragment
  # may legitimately answer both: `branch` is what the repo TRACKS, `revision`
  # is where it SITS. For most repos only the first is declared and the second
  # is supplied by the lock. A read-only third-party source tree is the case
  # where both belong in the fragment — it appears in no dependency graph, so
  # no lock covers it, and without a pin the checkout floats on whatever the
  # upstream branch tip happens to be.
  #
  # So `branch` does not overwrite `revision`. It only SUPPLIES it when the
  # fragment pinned nothing, which keeps a branch-only fragment resolving to a
  # legal `git clone --branch` argument. Overwriting instead meant a fragment
  # carrying both silently discarded its SHA: the pin was recorded in the
  # manifest but bound nothing, which reads as protected while floating.
  # The mainline, whichever schema declared it (`mainline` in repo.v2,
  # `branch` in repo.v1 — `readRepoFragment` maps one onto the other).
  let fragmentBranch = fragment.repo.mainlineBranch.get("")
  let fragmentRevision =
    if fragment.repo.revision.isSome: fragment.repo.revision.get() else: ""
  result.branch = fragmentBranch
  if fragmentBranch.len > 0 or fragmentRevision.len > 0:
    result.revision =
      if fragmentRevision.len > 0: fragmentRevision else: fragmentBranch
  else:
    result.revision = ctx.defaultRevision

  result.vcs =
    if fragment.repo.vcs.isSome and fragment.repo.vcs.get().len > 0:
      fragment.repo.vcs.get()
    else:
      defaultRepoVcs
  result.stability =
    if fragment.repo.stability.isSome and fragment.repo.stability.get().len > 0:
      fragment.repo.stability.get()
    else:
      defaultRepoStability
  # MO-5 — carry the evidence-only participation marker verbatim (default "").
  if fragment.repo.participation.isSome:
    result.participation = fragment.repo.participation.get()

  # RA-14 — carry the fetch-acceleration hints through unchanged. They are pure
  # download knobs; the resolved revision above is the single source of truth
  # for what the checkout resolves to.
  if fragment.repo.clone_filter.isSome:
    result.cloneFilter = fragment.repo.clone_filter.get()
  if fragment.repo.depth.isSome:
    result.depth = fragment.repo.depth.get()
  if fragment.repo.single_branch.isSome:
    result.singleBranch = fragment.repo.single_branch.get()

  # RA-18 — carry the copyfile/linkfile directives and group membership
  # through verbatim. These are workspace-layout facts, not download knobs;
  # the materialization step runs post-checkout in the CLI driver.
  result.copyfile = fragment.repo.copyfile
  result.linkfile = fragment.repo.linkfile
  result.tags = fragment.repo.tags

  # RA-21 — carry the develop-set dependency edges through verbatim.
  result.depends = fragment.repo.depends

  # Declared-Repository-Renames.md §2 — resolve each declared prior identity
  # to its EFFECTIVE (name, path, fetchUrl) triple. An omitted field inherits
  # from `[repo]`, so a pure path move resolves to today's name and URL with
  # yesterday's directory.
  #
  # The URL is composed through the SAME two paths the live URL above takes,
  # because a prior identity is a declaration of what the live one used to be
  # and must compose the same way or the reconstruction is a guess:
  #
  #   * a prior identity that names `url_prefix` resolves it against
  #     `url-prefixes/` and composes its own suffix — the org/host-change
  #     case, which is the only reason that field exists;
  #   * otherwise the repo's own prefix (membership-model path) or the
  #     project's `[[remote]]` entry (legacy `remote` path) composes the
  #     prior NAME / `url_suffix`.
  for prior in previousIdentities(fragmentAbs, fragment.extensions):
    var resolvedPrior = ResolvedPreviousIdentity(
      name: if prior.name.len > 0: prior.name else: result.name,
      path: if prior.path.len > 0: prior.path else: result.path)
    let priorSuffix =
      if prior.url_suffix.len > 0: prior.url_suffix
      elif prior.name.len > 0: prior.name
      else: defaultSuffix
    if prior.url_prefix.len > 0:
      let priorPrefix = resolveUrlPrefix(ctx, ownerFile, ownerSchema, keyPath,
        reference, prior.url_prefix)
      resolvedPrior.fetchUrl = composePrefixedUrl(priorPrefix, priorSuffix)
    elif repoUrlPrefix.len > 0:
      let livePrefix = resolveUrlPrefix(ctx, ownerFile, ownerSchema, keyPath,
        reference, repoUrlPrefix)
      resolvedPrior.fetchUrl = composePrefixedUrl(livePrefix, priorSuffix)
    elif result.projectRemote in ctx.remotes:
      resolvedPrior.fetchUrl =
        getFetchUrl(ctx.remotes[result.projectRemote], resolvedPrior.name)
    else:
      # No way to compose a prior URL. Not an error: the relocation identity
      # check accepts a candidate on the CURRENT URL too (and on content
      # identity), so an unreconstructible prior URL narrows the evidence it
      # can read rather than invalidating the declaration.
      resolvedPrior.fetchUrl = ""
    result.previously.add(resolvedPrior)

# ---- Workspace-Membership-Model.md: membership expansion -------------------

type
  MemberAccumulator = object
    ## Expansion state threaded through the depth-first walk. Dedup identity is
    ## the checkout PATH: a repo reachable by two routes is ONE checkout.
    repos: seq[ResolvedRepo]
    byPath: Table[string, int]
    declaredBy: Table[string, string]

proc raiseMemberConflict(ownerFile, ownerSchema, keyPath, checkoutPath,
                         owningSource, otherSource: string;
                         differences, fieldIds: seq[string]) {.noreturn.} =
  ## The dedup refusal. Nothing shadows anything here: identical declarations
  ## merge silently (the common case — two sets both pulling in
  ## `metacraft-dev-guidelines`), and a genuine disagreement is a decision the
  ## operator has to make, so it names the path, both sources, and the fields.
  let inner = "'" & owningSource & "' and '" & otherSource &
    "' declare checkout path '" & checkoutPath & "' with different " &
    differences.join(", ") &
    "; a path is ONE working tree, so the membership cannot be resolved. " &
    "Align the two declarations (normally by having both sets name the same " &
    "repo) or drop one of them"
  var e = newException(WorkspaceProjectSetConflictError, "")
  e.path = ownerFile
  e.keyPath = keyPath
  e.expectedSchema = ownerSchema
  e.observedSchema = ownerSchema
  e.innerMessage = inner
  e.checkoutPath = checkoutPath
  e.sources = @[owningSource, otherSource]
  e.fields = fieldIds
  e.msg = "[" & e.path & "] at key '" & keyPath & "': " & inner
  raise e

proc chainSuffix(chain: openArray[string]): string =
  ## " (reached via a -> b)" — so a diagnostic deep inside a nested repo-set
  ## says how resolution got there, not just where it stopped.
  if chain.len == 0: "" else: " (reached via " & chain.join(" -> ") & ")"

proc expandMembers(ctx: FragmentContext;
                   ownerFile, ownerSchema: string;
                   memberSets, memberRepos: openArray[string];
                   chain: seq[string]; acc: var MemberAccumulator) =
  ## Depth-first expansion of one manifest's membership.
  ##
  ## The two keys are separate NAMESPACES, not a stylistic split: a bare name
  ## is resolved against exactly one of `repo-sets/` or `repos/`, decided by
  ## the key it was written under. That is what makes
  ## `member_repos = ["codetracer"]` inside `repo-sets/codetracer.toml` legal
  ## and unambiguous, where a single `members` list had to consult both and
  ## then arbitrate — and 7 of the 11 projects in the metacraft manifest repo
  ## carry a set and a repo of the same name, so the arbitration would have
  ## been the common case rather than the corner one.
  ##
  ## `member_sets` expands BEFORE `member_repos`, declaration order preserved
  ## within each. That ordering is load-bearing, not incidental: dedup keys on
  ## FIRST-SEEN, so it decides which declaration of a shared path is the one
  ## kept and which is merely checked against it, and it decides the order of
  ## `ResolvedProject.repos`. Leaving it to the order the code happens to walk
  ## in would make the resolved repo order an implementation accident.
  for idx, member in memberSets.pairs:
    let keyPath = "member_sets[" & $idx & "]"
    let setRel = repoSetsDirName & "/" & member & ".toml"
    let setAbs = ctx.source.displayPath(setRel)
    if not ctx.source.hasFile(setRel):
      raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
        "member set '" & member & "' does not exist (looked for '" &
          repoSetsDirName / (member & ".toml") & "' under '" &
          ctx.source.displayRoot & "')" & chainSuffix(chain))
    if member in chain:
      raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
        "repo-set cycle: " & (chain & @[member]).join(" -> ") &
          "; a set that contains itself has no expansion")
    let setManifest = readRepoSetFromContent(
      ctx.source.readManifestText(setRel, schemaRepoSetV1), setAbs)
    expandMembers(ctx, setAbs, schemaRepoSetV1,
      setManifest.member_sets, setManifest.member_repos,
      chain & @[member], acc)

  for idx, member in memberRepos.pairs:
    let keyPath = "member_repos[" & $idx & "]"
    let fragmentRel = reposDirName & "/" & member & ".toml"
    if not ctx.source.hasFile(fragmentRel):
      raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
        "member repo '" & member & "' does not exist (looked for '" &
          reposDirName / (member & ".toml") & "' under '" &
          ctx.source.displayRoot & "')" & chainSuffix(chain))
    let resolved = resolveFragment(ctx, fragmentRel, ownerFile, ownerSchema,
      keyPath, member)
    let owner =
      if chain.len > 0: chain[^1] else: ownerFile.splitFile.name
    if resolved.path in acc.byPath:
      let existing = acc.repos[acc.byPath[resolved.path]]
      let differences = conflictingFields(existing, resolved)
      if differences.len > 0:
        raiseMemberConflict(ownerFile, ownerSchema, keyPath, resolved.path,
          acc.declaredBy.getOrDefault(resolved.path, owner), owner, differences,
          conflictingFieldIds(existing, resolved))
      # Identical declaration — one checkout, one entry.
      continue
    acc.byPath[resolved.path] = acc.repos.len
    acc.declaredBy[resolved.path] = owner
    acc.repos.add(resolved)

# ---- entry points -----------------------------------------------------------
#
# Each resolver has a SOURCE entry point (`…At(source, relPath)`) that does the
# work, and the historical PATH entry point, which is the source entry point
# over a directory source rooted at the file's grandparent (the manifest-repo
# root, since manifests live one directory below it). A directory source's
# display paths are the absolute paths the path entry points always reported,
# so `projectFile`, `fragmentPath` and every diagnostic are unchanged for
# them; a git-revision source reports `<git dir>@<commit>:<path>` instead.

proc manifestRootOf(manifestFile: string): string =
  ## The manifest-repo root a path entry point resolves against: the parent of
  ## the directory holding `manifestFile` (`projects/`, `variants/`, …).
  parentDir(parentDir(absolutePath(manifestFile)))

proc resolveProjectAt*(source: ManifestSource;
                       projectRel: string): ResolvedProject =
  ## Resolve the project manifest at `projectRel` (relative to the root of
  ## `source`, normally `projects/<project>.toml`) into a `ResolvedProject`,
  ## reading it and everything it references from `source` only. Raises
  ## `WorkspaceManifestParseError` on any malformed input — see the
  ## module-level "Error policy" comment.
  let absProject = source.displayPath(projectRel)
  let projectContent = source.readManifestText(projectRel,
    schemaProjectManifestV1)
  let project = readProjectManifestFromContent(projectContent, absProject)

  result.projectFile = absProject
  result.projectName = project.project.name
  if project.project.default_revision.isSome:
    result.defaultRevision = project.project.default_revision.get()
  if project.project.trunk.isSome:
    result.trunk = project.project.trunk.get()
  # Test-Certificates TC-9d — the `[certificates]` table is no longer read.
  # Ignoring it would turn a `required` into `off` without a word, so a
  # manifest that still carries it does not load.
  refuseLegacyCertificatesTableIn(project, projectContent, absProject)

  # Build remote name -> fetch URL lookup. The M5 reader already enforces
  # non-empty `name` and `fetch` on each remote entry, so we can index
  # by name directly. A duplicate remote name is a structural error: we
  # reject it here rather than silently letting the second entry shadow
  # the first.
  var remotes = initTable[string, string]()
  for i, r in project.remote:
    if r.name in remotes:
      raiseManifestError(absProject, "remote[" & $i & "].name",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "duplicate remote name '" & r.name & "' in project")
    remotes[r.name] = r.fetch

  let defaultRemoteName =
    if project.project.default_remote.isSome:
      project.project.default_remote.get()
    else:
      ""

  let ctx = FragmentContext(
    remotes: remotes,
    urlPrefixes: loadUrlPrefixesAt(source),
    defaultRemote: defaultRemoteName,
    defaultRevision: result.defaultRevision,
    ownerLabel: "the project",
    source: source)

  # Track `(name, path, projectRemote)` triples to detect genuine duplicates.
  # Two distinct fragments with the same `repo.name` but different `path`
  # and/or `remote` (the accounting / accounting-blocksense pattern) MUST
  # be allowed through; only an identical triple is a duplicate.
  var seen = initTable[string, int]()

  for incIdx, rawInclude in project.includes:
    let fragmentRel = normalizeIncludePath(absProject, rawInclude)
    if not source.hasFile(fragmentRel):
      raiseManifestError(absProject,
        "includes[" & $incIdx & "]",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "include target does not exist: '" & rawInclude &
          "' (resolved to '" & source.displayPath(fragmentRel) & "')")
    let resolved = resolveFragment(ctx, fragmentRel, absProject,
      schemaProjectManifestV1, "includes[" & $incIdx & "]", rawInclude)

    # Duplicate check on the `(name, path, projectRemote)` triple. We use
    # a tab-joined key because none of the three components legally
    # contains a tab character (repo names are file-system-safe; paths
    # use forward slashes; remote names are TOML identifiers).
    #
    # This is the `includes` rule and it stays exactly as it was: a repeated
    # include is an authoring mistake in a hand-written list. `member_repos`
    # dedups by checkout PATH instead, because reaching one repo through two
    # sets is the normal case there rather than a mistake.
    let triple = resolved.name & "\t" & resolved.path & "\t" & resolved.projectRemote
    if triple in seen:
      raiseManifestError(absProject,
        "includes[" & $incIdx & "]",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "duplicate repo (name='" & resolved.name & "', path='" & resolved.path &
          "', remote='" & resolved.projectRemote & "') first declared at includes[" &
          $seen[triple] & "]")
    seen[triple] = incIdx

    result.repos.add(resolved)

  # Workspace-Membership-Model.md — `members`, expanded after `includes` so a
  # half-converted project keeps its include order and merely appends. A
  # project that declares neither membership key (every project in an
  # unconverted manifest repo) does not enter this at all.
  if project.member_sets.len > 0 or project.member_repos.len > 0:
    var acc = MemberAccumulator(
      byPath: initTable[string, int](),
      declaredBy: initTable[string, string]())
    for i, repo in result.repos:
      if repo.path notin acc.byPath:
        acc.byPath[repo.path] = i
        acc.declaredBy[repo.path] = project.project.name
    acc.repos = result.repos
    expandMembers(ctx, absProject, schemaProjectManifestV1,
      project.member_sets, project.member_repos, @[], acc)
    result.repos = acc.repos

  validatePreviousIdentities(result.repos, absProject,
    schemaProjectManifestV1)

proc resolveProject*(projectFile: string): ResolvedProject =
  ## Resolve `projectFile` (a `projects/<project>.toml` on disk) into a
  ## `ResolvedProject`: `resolveProjectAt` over a directory source rooted at
  ## the manifest-repo root. Raises `WorkspaceManifestParseError` on any
  ## malformed input — see the module-level "Error policy" comment.
  let root = manifestRootOf(projectFile)
  resolveProjectAt(newDirectorySource(root),
    relPathFor(root, absolutePath(projectFile)))

proc resolveRepoSetAt*(source: ManifestSource;
                       setRel: string): ResolvedProject =
  ## Resolve a `repo-sets/<set>.toml` into the SAME `ResolvedProject` a project
  ## resolves to.
  ##
  ## That the return type is the same is the point of the model: a repo-set
  ## that is enabled in a workspace is what used to be called a project, so
  ## every downstream consumer — sync, lock, status, the project-set union —
  ## cannot tell one from the other and does not have to.
  ##
  ## A repo-set carries NO remote table and NO defaults by construction, so
  ## every member fragment resolves through `url-prefixes/` and declares its
  ## own branch. That is the invariant the model rests on: a repo fragment
  ## fully determines its own checkout, and nothing about which set referenced
  ## it can change where it lands.
  ##
  ## `setRel` is relative to the root of `source`, which every member is read
  ## from.
  let absSet = source.displayPath(setRel)
  let manifest = readRepoSetFromContent(
    source.readManifestText(setRel, schemaRepoSetV1), absSet)

  result.projectFile = absSet
  result.projectName = manifest.`repo-set`.name

  let ctx = FragmentContext(
    remotes: initTable[string, string](),
    urlPrefixes: loadUrlPrefixesAt(source),
    defaultRemote: "",
    defaultRevision: "",
    ownerLabel: "the repo-set",
    source: source)
  var acc = MemberAccumulator(
    byPath: initTable[string, int](),
    declaredBy: initTable[string, string]())
  expandMembers(ctx, absSet, schemaRepoSetV1,
    manifest.member_sets, manifest.member_repos,
    @[manifest.`repo-set`.name], acc)
  result.repos = acc.repos

  validatePreviousIdentities(result.repos, absSet, schemaRepoSetV1)

proc resolveRepoSet*(setFile: string): ResolvedProject =
  ## `resolveRepoSetAt` over a directory source rooted at the manifest-repo
  ## root that holds `setFile` (a `repo-sets/<set>.toml` on disk).
  let root = manifestRootOf(setFile)
  resolveRepoSetAt(newDirectorySource(root),
    relPathFor(root, absolutePath(setFile)))

# ---- string-based entry point --------------------------------------------

proc stringOverlay(content, basePath, schema: string):
    tuple[source: ManifestSource; rel: string] =
  ## The source a `…FromString` entry point resolves against: the directory
  ## holding `basePath`'s manifest-repo root, with `basePath` reading as
  ## `content` IN MEMORY. Nothing is written — not `basePath`, not its
  ## directory — so resolving a string body never touches the tree, and a
  ## file already at `basePath` is neither consulted nor replaced.
  if not isAbsolute(basePath):
    raiseManifestError(basePath, "", schema, schema,
      "basePath must be an absolute path")
  let root = manifestRootOf(basePath)
  let rel = relPathFor(root, basePath)
  (source: newOverlaySource(newDirectorySource(root), rel, content), rel: rel)

proc resolveProjectFromString*(content: string;
                               basePath: string): ResolvedProject =
  ## Resolve a project manifest whose body is supplied as a TOML string.
  ##
  ## `basePath` plays the role the on-disk project file would: include
  ## paths are resolved relative to `parentDir(parentDir(basePath))`,
  ## `projectFile` and every diagnostic carry `basePath`, and the referenced
  ## fragments are read from disk under that root. The body itself is NOT
  ## written to `basePath`: it is served from memory by an overlay source
  ## (`newOverlaySource`), so the call leaves the tree untouched and a file
  ## already at `basePath` is neither read nor overwritten. The body still
  ## passes the same reader (`readProjectManifestFromContent`) as a file.
  ##
  ## This is the seam tests use to build inline-TOML project fixtures
  ## without rewriting `resolveProject` itself. Production code uses
  ## `resolveProject(projectFile)` directly.
  let overlay = stringOverlay(content, basePath, schemaProjectManifestV1)
  result = resolveProjectAt(overlay.source, overlay.rel)

# ---- M7: variant composer -------------------------------------------------

proc normalizeVariantPath(variantFile, raw, keyPath, label: string): string =
  ## Validate a path string that appears inside a variant manifest
  ## (`[variant].base`, `includes[]`, or `[[override]].fragment`) and
  ## return it relative to the manifest-repo root (`normalizeRelPath`), for
  ## the variant's `ManifestSource` to read or display. `variantFile` is the
  ## variant's display path and only frames diagnostics; the checks are
  ## lexical, and existence is the caller's question to the source.
  ##
  ## Mirrors M6's `normalizeIncludePath` rejection rules: empty,
  ## absolute, backslash-bearing, and any `..`-bearing path is rejected
  ## with a structured `WorkspaceManifestParseError` carrying the
  ## variant schema string and the supplied `keyPath`. `label` is a
  ## short noun ("variant base path", "include path", …) used in the
  ## human-readable message.
  ##
  ## The manifest root is the source's root, the directory holding
  ## `projects/`, `repos/`, and `variants/` — variants live in a sibling
  ## directory at the same depth as projects.
  if raw.len == 0:
    raiseManifestError(variantFile, keyPath,
      schemaVariantManifestV1, schemaVariantManifestV1,
      label & " is empty")
  if isAbsolute(raw):
    raiseManifestError(variantFile, keyPath,
      schemaVariantManifestV1, schemaVariantManifestV1,
      label & " is absolute (must be relative to the manifest root): '" &
        raw & "'")
  if '\\' in raw:
    raiseManifestError(variantFile, keyPath,
      schemaVariantManifestV1, schemaVariantManifestV1,
      label & " uses backslash separators (must be forward slashes): '" &
        raw & "'")
  for component in raw.split('/'):
    if component == "..":
      raiseManifestError(variantFile, keyPath,
        schemaVariantManifestV1, schemaVariantManifestV1,
        label & " escapes the manifest root via '..': '" & raw & "'")
  result = normalizeRelPath(raw)

proc resolveVariantAt*(source: ManifestSource;
                       variantRel: string): ResolvedProject =
  ## Resolve a `variants/<v>.toml` into a `ResolvedProject` by composing:
  ##
  ## 1. The base project (read via M5's `readProjectManifest` and
  ##    resolved via M6's `resolveProject`).
  ## 2. Any extra `includes` the variant declares — appended to
  ##    `result.repos` in source order, with remote-name / fetch-URL /
  ##    revision resolved against the BASE project's `[[remote]]` table
  ##    and defaults. Variants do NOT carry their own `[[remote]]`
  ##    declarations.
  ## 3. Each `[[override]]` in source order. An override targets a
  ##    fragment by its `fragment` field (the path string from the
  ##    variant TOML); the resolver matches that against the
  ##    `fragmentPath` of existing `ResolvedRepo` entries after the
  ##    same path-normalization the loader applies. A `revision`,
  ##    `remote`, and/or `path` field on the override mutates the
  ##    matching record in place. If multiple fields are present they
  ##    are all applied.
  ##
  ## The returned `ResolvedProject` is indistinguishable downstream
  ## from a non-variant resolution except for two fields where it
  ## legitimately differs:
  ##   - `projectName` carries the variant's `[variant].name`.
  ##   - `projectFile` carries the display path of the variant file (its
  ##     absolute path for a directory source).
  ## All other fields (`defaultRevision`, `trunk`, `repos[*]`) are
  ## inherited from the base, mutated only where an override or extra
  ## include explicitly touches them.
  ##
  ## `variantRel` is relative to the root of `source`; the base project and
  ## every fragment are read from `source` too.
  ##
  ## Raises `WorkspaceManifestParseError` on any malformed input —
  ## same diagnostic policy as M6. See the module-level "Error policy"
  ## comment.
  let absVariant = source.displayPath(variantRel)
  let variant = readVariantManifestFromContent(
    source.readManifestText(variantRel, schemaVariantManifestV1), absVariant)

  # ---- step 1: resolve the base project ---------------------------------
  let baseRel = normalizeVariantPath(
    absVariant, variant.variant.base, "variant.base", "variant base path")
  let baseAbs = source.displayPath(baseRel)
  if not source.hasFile(baseRel):
    raiseManifestError(absVariant, "variant.base",
      schemaVariantManifestV1, schemaVariantManifestV1,
      "variant base project does not exist: '" & variant.variant.base &
        "' (resolved to '" & baseAbs & "')")
  result = resolveProjectAt(source, baseRel)

  # Override the two fields the variant legitimately owns. Everything
  # else flows through from the base resolver unchanged.
  result.projectName = variant.variant.name
  result.projectFile = absVariant

  # ---- rebuild the remote lookup table (for extra includes) -------------
  #
  # The base resolver already validated the project's [[remote]] table
  # so duplicate-name rejection has happened upstream. Re-read the
  # project here only to map remote name -> fetch URL for the variant's
  # extra includes and for `[[override]].remote` lookups. We do NOT
  # honour any [[remote]] table the variant might carry — the M5
  # schema doesn't declare one, and the spec explicitly says variants
  # don't declare their own remotes.
  let baseProject = readProjectManifestFromContent(
    source.readManifestText(baseRel, schemaProjectManifestV1), baseAbs)
  var remotes = initTable[string, string]()
  for r in baseProject.remote:
    remotes[r.name] = r.fetch
  let defaultRemoteName =
    if baseProject.project.default_remote.isSome:
      baseProject.project.default_remote.get()
    else:
      ""
  let variantCtx = FragmentContext(
    remotes: remotes,
    urlPrefixes: loadUrlPrefixesAt(source),
    defaultRemote: defaultRemoteName,
    defaultRevision: result.defaultRevision,
    ownerLabel: "the base project",
    source: source)

  # ---- step 2: apply the variant's extra includes ------------------------
  #
  # Build the duplicate-detection set seeded from the base's resolved
  # repos so any extra include that collides with a base repo is
  # rejected with the same `(name, path, projectRemote)` rule M6 uses.
  var seen = initTable[string, int]()
  for i, r in result.repos:
    let triple = r.name & "\t" & r.path & "\t" & r.projectRemote
    seen[triple] = i

  for incIdx, rawInclude in variant.includes:
    let fragmentRel = normalizeVariantPath(
      absVariant, rawInclude,
      "includes[" & $incIdx & "]", "include path")
    if not source.hasFile(fragmentRel):
      raiseManifestError(absVariant,
        "includes[" & $incIdx & "]",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "include target does not exist: '" & rawInclude &
          "' (resolved to '" & source.displayPath(fragmentRel) & "')")
    let resolved = resolveFragment(variantCtx, fragmentRel, absVariant,
      schemaVariantManifestV1, "includes[" & $incIdx & "]", rawInclude)

    let triple = resolved.name & "\t" & resolved.path & "\t" & resolved.projectRemote
    if triple in seen:
      raiseManifestError(absVariant,
        "includes[" & $incIdx & "]",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "duplicate repo (name='" & resolved.name & "', path='" & resolved.path &
          "', remote='" & resolved.projectRemote &
          "') already present from earlier resolution at index " &
          $seen[triple])
    seen[triple] = result.repos.len
    result.repos.add(resolved)

  # ---- step 3: apply each [[override]] in source order ------------------
  #
  # The override targets a fragment by its `fragment` path string,
  # matched against the `fragmentPath` field of existing `ResolvedRepo`
  # entries AFTER the same path-normalization the loader applied.
  for ovIdx, ov in variant.`override`:
    # Both sides of the comparison are display paths of the same source, so
    # the match is the same for a directory and a revision.
    let targetAbs = source.displayPath(normalizeVariantPath(
      absVariant, ov.fragment,
      "override[" & $ovIdx & "].fragment", "override fragment path"))
    var matchedIdx = -1
    for i in 0 ..< result.repos.len:
      if result.repos[i].fragmentPath == targetAbs:
        matchedIdx = i
        break
    if matchedIdx < 0:
      raiseManifestError(absVariant,
        "override[" & $ovIdx & "].fragment",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "override targets fragment '" & ov.fragment &
          "' which is not part of the resolved variant (neither the base " &
          "project nor the variant's extra `includes` declare it)")

    if ov.revision.isSome:
      result.repos[matchedIdx].revision = ov.revision.get()
    if ov.remote.isSome:
      let newRemote = ov.remote.get()
      if newRemote notin remotes:
        raiseManifestError(absVariant,
          "override[" & $ovIdx & "].remote",
          schemaVariantManifestV1, schemaVariantManifestV1,
          "override sets remote '" & newRemote &
            "' which is not declared in the base project's [[remote]] table")
      let fullUrl = getFetchUrl(remotes[newRemote], result.repos[matchedIdx].name)
      result.repos[matchedIdx].projectRemote = newRemote
      result.repos[matchedIdx].fetchUrl = fullUrl

      # Sync the remotes list
      if result.repos[matchedIdx].remotes.len > 0:
        var found = false
        for idx, r in result.repos[matchedIdx].remotes:
          if r.localName == newRemote or r.localName == "origin":
            result.repos[matchedIdx].remotes[idx].projectRemote = newRemote
            result.repos[matchedIdx].remotes[idx].fetchUrl = fullUrl
            found = true
            break
        if not found:
          result.repos[matchedIdx].remotes.add(ResolvedRemote(localName: "origin", projectRemote: newRemote, fetchUrl: fullUrl))
      else:
        result.repos[matchedIdx].remotes = @[ResolvedRemote(localName: "origin", projectRemote: newRemote, fetchUrl: fullUrl)]
    if ov.path.isSome:
      result.repos[matchedIdx].path = ov.path.get()

  # ---- step 4: post-override duplicate-detection re-run -----------------
  #
  # An override could mutate a repo into a duplicate of another entry
  # (e.g. change its `path` to match a sibling with the same name and
  # remote). Re-scan the final repos list to catch that.
  var finalSeen = initTable[string, int]()
  for i in 0 ..< result.repos.len:
    let r = result.repos[i]
    let triple = r.name & "\t" & r.path & "\t" & r.projectRemote
    if triple in finalSeen:
      raiseManifestError(absVariant,
        "override",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "after applying overrides, repos at indices " & $finalSeen[triple] &
          " and " & $i & " share the same (name='" & r.name &
          "', path='" & r.path & "', remote='" & r.projectRemote &
          "') triple")
    finalSeen[triple] = i

  validatePreviousIdentities(result.repos, absVariant,
    schemaVariantManifestV1)

proc resolveVariant*(variantFile: string): ResolvedProject =
  ## `resolveVariantAt` over a directory source rooted at the manifest-repo
  ## root that holds `variantFile` (a `variants/<v>.toml` on disk).
  let root = manifestRootOf(variantFile)
  resolveVariantAt(newDirectorySource(root),
    relPathFor(root, absolutePath(variantFile)))

proc resolveVariantFromString*(content: string;
                               basePath: string): ResolvedProject =
  ## Resolve a variant manifest whose body is supplied as a TOML string.
  ## The string-body analogue of `resolveVariant`, mirroring M6's
  ## `resolveProjectFromString`.
  ##
  ## `basePath` plays the role the on-disk variant file would: the
  ## variant's `[variant].base` and `includes[]` are resolved relative
  ## to `parentDir(parentDir(basePath))`, and any diagnostic carries
  ## `basePath` as the `path` field. The base project and fragments are
  ## read from disk under that root; the variant body is served from
  ## memory and never written to `basePath` (see `resolveProjectFromString`).
  let overlay = stringOverlay(content, basePath, schemaVariantManifestV1)
  result = resolveVariantAt(overlay.source, overlay.rel)

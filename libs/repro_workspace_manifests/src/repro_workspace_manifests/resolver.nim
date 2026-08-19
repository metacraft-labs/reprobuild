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
##   - `members` (NAMES) as well as `includes` (paths). A name resolves against
##     two namespaces — `repos/<name>.toml` and `repo-sets/<name>.toml` — and a
##     name carried by both is refused, because the two are resolved together
##     and one name cannot mean two things.
##   - repo-sets expand depth-first to any depth, with cycle detection that
##     names the full path (`a -> b -> a`) rather than overflowing the stack.
##   - `url-prefixes/<name>.toml` resolves `url_prefix`, with `url =
##     url_prefix / url_suffix` and `url_suffix` defaulting to the repo's
##     `name`. The old `remote` spelling still resolves through the project's
##     `[[remote]]` table, and only THAT path keeps `getFetchUrl`'s
##     "a base ending in .git is used verbatim" special case.
##   - per-binding `url_prefix` / `url_suffix` on `remotes = [{ … }]`, so a
##     fork's `upstream` lands on a different path than its `origin`.
##   - `branch` takes precedence over `revision` when both are present.

import std/[algorithm, options, os, strutils, tables]
import types
import diagnostics
import reader

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
      ## Workspace-Membership-Model.md — the fragment's `branch`, when it
      ## declared one. Only ever a branch NAME, so it is always a legal
      ## `git clone --branch` argument; `revision` conflated that with "an
      ## exact commit to sit at" and the conflation cost two defects. Empty for
      ## an unconverted fragment (which declares `revision` instead), and when
      ## non-empty it is also mirrored into `revision`, so every existing
      ## consumer keeps reading one field and nothing has to be taught the new
      ## one before the manifest repo is converted.
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
    # RA-18 — post-sync file materialization + group membership, carried
    # verbatim from the fragment. An empty `groups` means the repo belongs
    # to the implicit `default` group only (see `repoInGroups`).
    copyfile*: seq[CopyLinkFileEntry]
    linkfile*: seq[CopyLinkFileEntry]
    groups*: seq[string]
    # RA-21 — develop-set dependency edges carried verbatim from the
    # fragment. Names the other repos this repo depends on; the pre-push
    # gate uses these to compute the pushed repo's transitive dependency
    # closure (Workspace-And-Develop-Mode.md §"VCS Hook Integration").
    depends*: seq[string]

  CertificateGateMode* = enum
    ## TC-3 / TC-6 / RA-32 — the resolved `[certificates] gate_mode`.
    ## `cgmOff` is the DEFAULT (and the value for a project that declares no
    ## `[certificates]` table at all): the pre-push gate runs exactly as it
    ## did before test certificates existed, so a newcomer's first push is
    ## never cert-walled. `cgmAdvisory` records the coverage result in the
    ## gate report (a warning when uncovered) but NEVER blocks the push.
    ## `cgmRequired` refuses the push unless the submitted certificates cover
    ## the pushed commit for the required targets on each required platform.
    cgmOff = "off"
    cgmAdvisory = "advisory"
    cgmRequired = "required"

  CertificateCiTrust* = enum
    ## TC-4 — the resolved `[certificates] ci_trust`, the project's EXPLICIT
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

  CertificatePolicy* = object
    ## The resolved test-certificate gating policy for a project. The DEFAULT
    ## (every field zero / `cgmOff`) is what a project with no `[certificates]`
    ## table resolves to, so the policy is a strict no-op until a project opts
    ## in. `requiredTargets` are the targets a certificate set must cover;
    ## `requiredPlatforms` are the platforms each of which must be covered
    ## (the union of submitted certificates is checked per platform).
    gateMode*: CertificateGateMode
    requiredTargets*: seq[string]
    requiredPlatforms*: seq[string]
    ciTrust*: CertificateCiTrust
      ## TC-4 — whether CI skips certified targets (`cctSkip`) or re-runs them
      ## while surfacing the certificate as advisory (`cctAdvisory`, the
      ## default). Independent of `gateMode`: a project can require coverage on
      ## push yet still re-run in CI (advisory), or run advisory pushes yet
      ## fast-track CI (skip). Defaults to `cctAdvisory` (no trust by omission).

  ResolvedProject* = object
    ## A flat view of one `projects/<project>.toml` after include
    ## expansion and default application.
    projectName*: string
    defaultRevision*: string
    trunk*: string
    repos*: seq[ResolvedRepo]
    projectFile*: string
    certificatePolicy*: CertificatePolicy
      ## TC-3 / TC-6 / RA-32 — resolved from the project manifest's
      ## `[certificates]` table; defaults to `cgmOff` (no enforcement) when
      ## the table is absent or omits `gate_mode`.

const
  defaultRepoVcs* = "git"
  defaultRepoStability* = "tracked"
  defaultManifestGroup* = "default"
    ## RA-18 — a repo with no declared `groups` belongs to this implicit
    ## group (the `repo`-tool convention). A repo's effective group set is
    ## therefore `groups` when non-empty, else `["default"]`.
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

proc conflictingFields*(existing, candidate: ResolvedRepo): seq[string] =
  ## The load-bearing facts of a checkout: what would be cloned, from where,
  ## at which revision, with which VCS. Two sources may reach these through
  ## differently-NAMED remotes (`origin` vs `metacraft-labs` pointing at the
  ## same fetch base) without disagreeing about anything real, so the remote
  ## KEY is deliberately not compared — the resolved fetch URL is.
  if existing.name != candidate.name:
    result.add("name (" & existing.name & " vs " & candidate.name & ")")
  if existing.fetchUrl != candidate.fetchUrl:
    result.add("fetch url (" & existing.fetchUrl & " vs " &
      candidate.fetchUrl & ")")
  if existing.revision != candidate.revision:
    result.add("revision (" & existing.revision & " vs " &
      candidate.revision & ")")
  if existing.vcs != candidate.vcs:
    result.add("vcs (" & existing.vcs & " vs " & candidate.vcs & ")")

# ---- TC-3 / TC-6 / RA-32 certificate policy resolution --------------------

proc resolveCertificatePolicy*(body: CertificatesBody;
                               projectFile: string): CertificatePolicy =
  ## Resolve a manifest `[certificates]` table into a `CertificatePolicy`.
  ## The DEFAULT — an absent table, or one that omits `gate_mode` — is
  ## `cgmOff`: a project that never opts in is never cert-gated (the RA-32
  ## default-off / advisory-first onboarding guarantee). A `gate_mode` value
  ## outside {off, advisory, required} is a structural error: a typo must
  ## fail LOUD rather than silently fall back to `off` (which would mask an
  ## intended `required`).
  result.gateMode = cgmOff
  if body.gate_mode.isSome:
    let raw = body.gate_mode.get().strip()
    case raw
    of "", "off": result.gateMode = cgmOff
    of "advisory": result.gateMode = cgmAdvisory
    of "required": result.gateMode = cgmRequired
    else:
      raiseManifestError(projectFile, "certificates.gate_mode",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "invalid `certificates.gate_mode` value '" & raw &
          "' (expected: off | advisory | required)")
  result.requiredTargets = body.required_targets
  result.requiredPlatforms = body.required_platforms
  # TC-4 — resolve the CI-trust decision. The DEFAULT — an absent / omitted
  # `ci_trust` — is `cctAdvisory`: CI never fast-tracks on trust unless the
  # project explicitly opts in, so a forged certificate can never cause a skip
  # in a project that did not ask for it. As with `gate_mode`, an out-of-range
  # value is a structural error (a typo must fail LOUD, never silently grant
  # the higher-trust `skip`).
  result.ciTrust = cctAdvisory
  if body.ci_trust.isSome:
    let raw = body.ci_trust.get().strip()
    case raw
    of "", "advisory": result.ciTrust = cctAdvisory
    of "skip": result.ciTrust = cctSkip
    else:
      raiseManifestError(projectFile, "certificates.ci_trust",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "invalid `certificates.ci_trust` value '" & raw &
          "' (expected: advisory | skip)")

# ---- RA-18 group membership -----------------------------------------------

proc effectiveGroups*(repo: ResolvedRepo): seq[string] =
  ## The repo's effective group membership: its declared `groups` when it
  ## has any, otherwise the implicit `["default"]`. A repo that explicitly
  ## lists groups WITHOUT naming `default` is NOT in `default` (mirroring
  ## `repo`, where listing a group opts out of the implicit membership).
  if repo.groups.len > 0: repo.groups
  else: @[defaultManifestGroup]

proc repoSelectedByGroups*(repo: ResolvedRepo;
                           includeGroups, excludeGroups: seq[string]): bool =
  ## RA-18 subset selection. `includeGroups` is the requested `--groups`
  ## set (empty means "no `--groups` filter": every repo is selected unless
  ## excluded). `excludeGroups` is the `-<group>` set. A repo is selected
  ## when (a) `includeGroups` is empty OR the repo is in at least one
  ## included group, AND (b) the repo is in NONE of the excluded groups.
  ## Exclusion wins over inclusion, matching `repo`'s `groups=foo,-bar`.
  let groups = effectiveGroups(repo)
  for g in excludeGroups:
    if g in groups:
      return false
  if includeGroups.len == 0:
    return true
  for g in includeGroups:
    if g in groups:
      return true
  false

# ---- helpers --------------------------------------------------------------

proc normalizeIncludePath(projectFile, raw: string): string =
  ## Validate an include path string and return the absolute filesystem
  ## path of the referenced fragment.
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
  let manifestRoot = parentDir(parentDir(absolutePath(projectFile)))
  # Walk the path components manually so we reject any `..` segment
  # before the OS resolves it. Even if `..` would land back inside the
  # manifest root (e.g. `projects/../repos/foo.toml`), we reject it as
  # a matter of policy: include paths should be the canonical form.
  for component in raw.split('/'):
    if component == "..":
      raiseManifestError(projectFile, "includes",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "include path escapes the manifest root via '..': '" & raw & "'")
  result = manifestRoot / raw.replace('/', DirSep)

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

# ---- Workspace-Membership-Model.md: url prefixes ---------------------------

proc loadUrlPrefixes*(manifestRoot: string): Table[string, string] =
  ## Every `url-prefixes/<name>.toml` under `manifestRoot`, as name -> url.
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
  let dir = manifestRoot / urlPrefixesDirName
  if not dirExists(dir):
    return
  var files: seq[string]
  for kind, path in walkDir(dir):
    if kind in {pcFile, pcLinkToFile} and path.splitFile.ext == ".toml":
      files.add(path)
  sort(files)
  for file in files:
    let manifest = readUrlPrefix(file)
    let name = manifest.`url-prefix`.name
    let url = manifest.`url-prefix`.url
    if name in result and result[name] != url:
      raiseManifestError(file, "url-prefix.name",
        schemaUrlPrefixV1, schemaUrlPrefixV1,
        "url prefix '" & name & "' is declared twice with different urls ('" &
          result[name] & "' vs '" & url &
          "'); a prefix is workspace-wide, so the name has to mean one place")
    result[name] = url

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

proc resolveFragment(ctx: FragmentContext; fragmentAbs: string;
                     ownerFile, ownerSchema, keyPath, reference: string):
    ResolvedRepo =
  ## Read one `repos/<r>.toml` and resolve it against `ctx`.
  ##
  ## `reference` is how the owning manifest named this fragment — an include
  ## PATH (`repos/foo.toml`) or a member NAME (`foo`) — and appears verbatim in
  ## every diagnostic, so the operator is pointed at what they actually wrote.
  let fragment = readRepoFragment(fragmentAbs)

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
    if entry.remote in ctx.remotes:
      return ResolvedRemote(localName: entry.name, projectRemote: entry.remote,
        fetchUrl: getFetchUrl(ctx.remotes[entry.remote], fragment.repo.name))
    # A `remote` name the project's table does not carry may still be a url
    # prefix: that is the state a manifest repo is in while its remotes have
    # been hoisted into `url-prefixes/` but its fragments still say `remote`.
    # Only reachable where resolution used to FAIL, so it cannot move a
    # manifest that resolves today.
    if entry.remote in ctx.urlPrefixes:
      let suffix =
        if entry.url_suffix.len > 0: entry.url_suffix else: fragment.repo.name
      return ResolvedRemote(localName: entry.name, projectRemote: entry.remote,
        fetchUrl: composePrefixedUrl(ctx.urlPrefixes[entry.remote], suffix))
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
      elif result.projectRemote in ctx.urlPrefixes:
        # Same hoisted-remotes intermediate state as in `resolveBinding`.
        result.fetchUrl = composePrefixedUrl(
          ctx.urlPrefixes[result.projectRemote], defaultSuffix)
      else:
        raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
          "fragment '" & reference & "' references unknown remote '" &
            result.projectRemote & "' (not declared in " & ctx.ownerLabel &
            "'s [[remote]] table)")
      resolvedRemotes.add(ResolvedRemote(localName: "origin",
        projectRemote: result.projectRemote, fetchUrl: result.fetchUrl))
    result.remotes = resolvedRemotes

  # Resolve revision. `branch` WINS over `revision` when both are present:
  # `branch` carries only branch names, so it is the one that is always a legal
  # `git clone --branch` argument, and a pin belongs in the lock rather than in
  # a manifest. `revision` still resolves alone, for every unconverted
  # fragment. With neither set we fall back to the project's
  # `default_revision`, then leave the field empty — downstream policy decides
  # what an empty revision means; we do NOT inject a hardcoded branch name.
  let fragmentBranch =
    if fragment.repo.branch.isSome: fragment.repo.branch.get() else: ""
  let fragmentRevision =
    if fragment.repo.revision.isSome: fragment.repo.revision.get() else: ""
  if fragmentBranch.len > 0:
    result.branch = fragmentBranch
    result.revision = fragmentBranch
  elif fragmentRevision.len > 0:
    result.revision = fragmentRevision
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
  result.groups = fragment.repo.groups

  # RA-21 — carry the develop-set dependency edges through verbatim.
  result.depends = fragment.repo.depends

# ---- Workspace-Membership-Model.md: `members` expansion --------------------

type
  MemberAccumulator = object
    ## Expansion state threaded through the depth-first walk. Dedup identity is
    ## the checkout PATH: a repo reachable by two routes is ONE checkout.
    repos: seq[ResolvedRepo]
    byPath: Table[string, int]
    declaredBy: Table[string, string]

proc raiseMemberConflict(ownerFile, ownerSchema, keyPath, checkoutPath,
                         owningSource, otherSource: string;
                         differences: seq[string]) {.noreturn.} =
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
  e.msg = "[" & e.path & "] at key '" & keyPath & "': " & inner
  raise e

proc chainSuffix(chain: openArray[string]): string =
  ## " (reached via a -> b)" — so a diagnostic deep inside a nested repo-set
  ## says how resolution got there, not just where it stopped.
  if chain.len == 0: "" else: " (reached via " & chain.join(" -> ") & ")"

proc expandMembers(ctx: FragmentContext; manifestRoot: string;
                   ownerFile, ownerSchema: string;
                   members: openArray[string]; chain: seq[string];
                   acc: var MemberAccumulator) =
  ## Depth-first expansion of one `members` list.
  ##
  ## An entry names a repo or a repo-set, resolved against those two
  ## namespaces rather than against the filesystem — which is the whole point
  ## of `members` over `includes`, whose entries were paths while every other
  ## reference in the schema (`depends`, `remote`) was a name.
  for idx, member in members.pairs:
    let keyPath = "members[" & $idx & "]"
    let fragmentAbs = manifestRoot / reposDirName / (member & ".toml")
    let setAbs = manifestRoot / repoSetsDirName / (member & ".toml")
    let isRepo = fileExists(fragmentAbs)
    let isSet = fileExists(setAbs)

    if isRepo and isSet:
      # The two namespaces are resolved TOGETHER, so a name carried by both has
      # no answer. Refusing is the only option that does not silently pick one.
      raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
        "member '" & member & "' is BOTH a repo fragment (" &
          reposDirName / (member & ".toml") & ") and a repo-set (" &
          repoSetsDirName / (member & ".toml") &
          "); members resolve against both namespaces, so one name cannot " &
          "mean two things — rename one of them" & chainSuffix(chain))

    if isSet:
      if member in chain:
        raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
          "repo-set cycle: " & (chain & @[member]).join(" -> ") &
            "; a set that contains itself has no expansion")
      let setManifest = readRepoSet(setAbs)
      expandMembers(ctx, manifestRoot, setAbs, schemaRepoSetV1,
        setManifest.members, chain & @[member], acc)
      continue

    if not isRepo:
      raiseManifestError(ownerFile, keyPath, ownerSchema, ownerSchema,
        "member '" & member & "' names neither a repo nor a repo-set " &
          "(looked for '" & reposDirName / (member & ".toml") & "' and '" &
          repoSetsDirName / (member & ".toml") & "' under '" & manifestRoot &
          "')" & chainSuffix(chain))

    let resolved = resolveFragment(ctx, fragmentAbs, ownerFile, ownerSchema,
      keyPath, member)
    let owner =
      if chain.len > 0: chain[^1] else: ownerFile.splitFile.name
    if resolved.path in acc.byPath:
      let differences =
        conflictingFields(acc.repos[acc.byPath[resolved.path]], resolved)
      if differences.len > 0:
        raiseMemberConflict(ownerFile, ownerSchema, keyPath, resolved.path,
          acc.declaredBy.getOrDefault(resolved.path, owner), owner, differences)
      # Identical declaration — one checkout, one entry.
      continue
    acc.byPath[resolved.path] = acc.repos.len
    acc.declaredBy[resolved.path] = owner
    acc.repos.add(resolved)

# ---- on-disk entry point --------------------------------------------------

proc resolveProject*(projectFile: string): ResolvedProject =
  ## Resolve `projectFile` (a `projects/<project>.toml`) into a
  ## `ResolvedProject`. Raises `WorkspaceManifestParseError` on any
  ## malformed input — see the module-level "Error policy" comment.
  let absProject = absolutePath(projectFile)
  let project = readProjectManifest(absProject)

  result.projectFile = absProject
  result.projectName = project.project.name
  if project.project.default_revision.isSome:
    result.defaultRevision = project.project.default_revision.get()
  if project.project.trunk.isSome:
    result.trunk = project.project.trunk.get()
  # TC-3 / TC-6 / RA-32 — resolve the certificate gating policy (default off).
  result.certificatePolicy =
    resolveCertificatePolicy(project.certificates, absProject)

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

  let manifestRoot = parentDir(parentDir(absProject))
  let ctx = FragmentContext(
    remotes: remotes,
    urlPrefixes: loadUrlPrefixes(manifestRoot),
    defaultRemote: defaultRemoteName,
    defaultRevision: result.defaultRevision,
    ownerLabel: "the project")

  # Track `(name, path, projectRemote)` triples to detect genuine duplicates.
  # Two distinct fragments with the same `repo.name` but different `path`
  # and/or `remote` (the accounting / accounting-blocksense pattern) MUST
  # be allowed through; only an identical triple is a duplicate.
  var seen = initTable[string, int]()

  for incIdx, rawInclude in project.includes:
    let fragmentAbs = normalizeIncludePath(absProject, rawInclude)
    if not fileExists(fragmentAbs):
      raiseManifestError(absProject,
        "includes[" & $incIdx & "]",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "include target does not exist: '" & rawInclude &
          "' (resolved to '" & fragmentAbs & "')")
    let resolved = resolveFragment(ctx, fragmentAbs, absProject,
      schemaProjectManifestV1, "includes[" & $incIdx & "]", rawInclude)

    # Duplicate check on the `(name, path, projectRemote)` triple. We use
    # a tab-joined key because none of the three components legally
    # contains a tab character (repo names are file-system-safe; paths
    # use forward slashes; remote names are TOML identifiers).
    #
    # This is the `includes` rule and it stays exactly as it was: a repeated
    # include is an authoring mistake in a hand-written list. `members` dedups
    # by checkout PATH instead, because reaching one repo through two sets is
    # the normal case there rather than a mistake.
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
  # project that declares no `members` (every project in an unconverted
  # manifest repo) does not enter this at all.
  if project.members.len > 0:
    var acc = MemberAccumulator(
      byPath: initTable[string, int](),
      declaredBy: initTable[string, string]())
    for i, repo in result.repos:
      if repo.path notin acc.byPath:
        acc.byPath[repo.path] = i
        acc.declaredBy[repo.path] = project.project.name
    acc.repos = result.repos
    expandMembers(ctx, manifestRoot, absProject, schemaProjectManifestV1,
      project.members, @[], acc)
    result.repos = acc.repos

proc resolveRepoSet*(setFile: string): ResolvedProject =
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
  let absSet = absolutePath(setFile)
  let manifest = readRepoSet(absSet)
  let manifestRoot = parentDir(parentDir(absSet))

  result.projectFile = absSet
  result.projectName = manifest.`repo-set`.name

  let ctx = FragmentContext(
    remotes: initTable[string, string](),
    urlPrefixes: loadUrlPrefixes(manifestRoot),
    defaultRemote: "",
    defaultRevision: "",
    ownerLabel: "the repo-set")
  var acc = MemberAccumulator(
    byPath: initTable[string, int](),
    declaredBy: initTable[string, string]())
  expandMembers(ctx, manifestRoot, absSet, schemaRepoSetV1,
    manifest.members, @[manifest.`repo-set`.name], acc)
  result.repos = acc.repos

# ---- string-based entry point --------------------------------------------

proc resolveProjectFromString*(content: string;
                               basePath: string): ResolvedProject =
  ## Resolve a project manifest whose body is supplied as a TOML string.
  ##
  ## `basePath` plays the role the on-disk project file would: include
  ## paths are resolved relative to `parentDir(parentDir(basePath))`,
  ## and any diagnostic carries `basePath` as the `path` field. The
  ## referenced fragment files MUST exist on disk under that root
  ## (this proc does not provide a virtual filesystem for fragments —
  ## fragments are always read by `readRepoFragment`).
  ##
  ## This is the seam tests use to build inline-TOML project fixtures
  ## without rewriting `resolveProject` itself. Production code uses
  ## `resolveProject(projectFile)` directly.
  if not isAbsolute(basePath):
    raiseManifestError(basePath, "",
      schemaProjectManifestV1, schemaProjectManifestV1,
      "basePath must be an absolute path")

  # Round-trip through a temp project file so we exercise the same M5
  # reader the on-disk path uses. This keeps the validation contract
  # uniform across the two entry points.
  writeFile(basePath, content)
  result = resolveProject(basePath)

# ---- M7: variant composer -------------------------------------------------

proc normalizeVariantPath(variantFile, raw, keyPath, label: string): string =
  ## Validate a path string that appears inside a variant manifest
  ## (`[variant].base`, `includes[]`, or `[[override]].fragment`) and
  ## return its absolute on-disk form under the manifest-repo root.
  ##
  ## Mirrors M6's `normalizeIncludePath` rejection rules: empty,
  ## absolute, backslash-bearing, and any `..`-bearing path is rejected
  ## with a structured `WorkspaceManifestParseError` carrying the
  ## variant schema string and the supplied `keyPath`. `label` is a
  ## short noun ("variant base path", "include path", …) used in the
  ## human-readable message.
  ##
  ## The manifest root is computed the same way as for projects:
  ## `parentDir(parentDir(absolutePath(variantFile)))`. That is the
  ## directory holding `projects/`, `repos/`, and `variants/`, because
  ## variants live in a sibling directory at the same depth as projects.
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
  let manifestRoot = parentDir(parentDir(absolutePath(variantFile)))
  result = manifestRoot / raw.replace('/', DirSep)

proc resolveVariant*(variantFile: string): ResolvedProject =
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
  ##   - `projectFile` carries the absolute path of the variant file.
  ## All other fields (`defaultRevision`, `trunk`, `repos[*]`) are
  ## inherited from the base, mutated only where an override or extra
  ## include explicitly touches them.
  ##
  ## Raises `WorkspaceManifestParseError` on any malformed input —
  ## same diagnostic policy as M6. See the module-level "Error policy"
  ## comment.
  let absVariant = absolutePath(variantFile)
  let variant = readVariantManifest(absVariant)

  # ---- step 1: resolve the base project ---------------------------------
  let baseAbs = normalizeVariantPath(
    absVariant, variant.variant.base, "variant.base", "variant base path")
  if not fileExists(baseAbs):
    raiseManifestError(absVariant, "variant.base",
      schemaVariantManifestV1, schemaVariantManifestV1,
      "variant base project does not exist: '" & variant.variant.base &
        "' (resolved to '" & baseAbs & "')")
  result = resolveProject(baseAbs)

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
  let baseProject = readProjectManifest(baseAbs)
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
    urlPrefixes: loadUrlPrefixes(parentDir(parentDir(absVariant))),
    defaultRemote: defaultRemoteName,
    defaultRevision: result.defaultRevision,
    ownerLabel: "the base project")

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
    let fragmentAbs = normalizeVariantPath(
      absVariant, rawInclude,
      "includes[" & $incIdx & "]", "include path")
    if not fileExists(fragmentAbs):
      raiseManifestError(absVariant,
        "includes[" & $incIdx & "]",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "include target does not exist: '" & rawInclude &
          "' (resolved to '" & fragmentAbs & "')")
    let resolved = resolveFragment(variantCtx, fragmentAbs, absVariant,
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
    let targetAbs = normalizeVariantPath(
      absVariant, ov.fragment,
      "override[" & $ovIdx & "].fragment", "override fragment path")
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

proc resolveVariantFromString*(content: string;
                               basePath: string): ResolvedProject =
  ## Resolve a variant manifest whose body is supplied as a TOML string.
  ## The string-body analogue of `resolveVariant`, mirroring M6's
  ## `resolveProjectFromString`.
  ##
  ## `basePath` plays the role the on-disk variant file would: the
  ## variant's `[variant].base` and `includes[]` are resolved relative
  ## to `parentDir(parentDir(basePath))`, and any diagnostic carries
  ## `basePath` as the `path` field. The referenced base project and
  ## fragment files MUST exist on disk under that root (this proc does
  ## not provide a virtual filesystem — the M5 readers always read from
  ## the real filesystem).
  if not isAbsolute(basePath):
    raiseManifestError(basePath, "",
      schemaVariantManifestV1, schemaVariantManifestV1,
      "basePath must be an absolute path")
  writeFile(basePath, content)
  result = resolveVariant(basePath)

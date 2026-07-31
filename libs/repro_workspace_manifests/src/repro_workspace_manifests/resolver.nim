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

import std/[options, os, strutils, tables]
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

proc getFetchUrl*(fetchBase, repoName: string): string =
  ## Build a repo's clone URL from its remote's `fetch` base and the repo's
  ## server-side `name`, following Android-`repo` manifest semantics: the
  ## clone URL is `<remote fetch>/<project name>` (the `name` attribute, NOT
  ## the local checkout `path`). A `fetch` base that already points at a full
  ## repo (ends in `.git`) is used verbatim; otherwise the `name` is appended.
  ##
  ## Exported because manifest AUTHORING (`repro workspace project repo add`)
  ## has to invert this function: given a requested clone URL it must find the
  ## declared remote that already composes to it. Authoring and resolution
  ## must never drift apart, so both sides call this one proc.
  if fetchBase.len == 0:
    ""
  elif fetchBase.endsWith(".git") or fetchBase.endsWith(".git/"):
    fetchBase
  else:
    fetchBase & "/" & repoName

# ---- remote planning (manifest authoring) ---------------------------------
#
# `repro workspace project repo add <project> <repo> --remote=URL` has to turn
# a clone URL into a `repos/<repo>.toml` fragment plus, at most, one new
# `[[remote]]` entry in `projects/<project>.toml`. The rules below are the
# inverse of `getFetchUrl`:
#
#   1. REUSE — a declared remote whose `fetch` base, composed with the repo's
#      name, already reproduces the requested URL. Nothing is added to the
#      project's remote table.
#   2. REUSE WITH A SERVER-SIDE NAME — only when the URL's last segment is not
#      the repo name (e.g. `…/llvm/llvm-project` added as `llvm-project`): a
#      declared base is a prefix of the URL, so the fragment carries the
#      remaining path as its `name` (Android-`repo` semantics: `name` is the
#      server-side path, `path` is the local checkout dir). This is how the
#      hand-written `repos/llvm-project.toml` is shaped.
#   3. MINT — no declared remote can produce the URL: add exactly ONE entry,
#      named after the org (or the host when the URL has no org segment) and
#      carrying the org base as `fetch`, so the NEXT repo from the same org
#      hits rule 1 and adds nothing.
#
# A per-repo remote (`<repo>-origin` with the full URL as `fetch`) is never
# minted: it grows the project's shared remote table by one entry per repo and
# can never be reused, because a `fetch` ending in `.git` is used verbatim.

type
  RepoRemotePlan* = object
    ## The outcome of planning a repo fragment's remote against a project's
    ## existing `[[remote]]` table.
    remoteName*: string
      ## The `[repo].remote` value the fragment should carry.
    repoName*: string
      ## The `[repo].name` value the fragment should carry. Equal to the
      ## requested repo name except when the URL's server-side path differs
      ## from the local checkout dir (rule 2 / a bare-repo URL whose last
      ## segment keeps its `.git`).
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
                     repoName, requestedUrl: string): RepoRemotePlan =
  ## Plan the `[repo].remote` / `[repo].name` of a fragment for `repoName`
  ## cloned from `requestedUrl`, against a project's declared `remotes`.
  ## See the rules documented above this type.
  result.repoName = repoName
  if requestedUrl.len == 0:
    result.error = "remote URL is empty"
    return
  let wanted = canonicalGitUrl(requestedUrl)

  # Rule 1 — a declared remote already composes to the requested URL for this
  # repo name. Deterministic pick when several do (a project may declare two
  # names for one org): the project's `default_remote` first, then a remote
  # named after the org segment of its own base (`metacraft-labs` beats a
  # generic `origin` alias), then declaration order.
  var bestRank = high(int)
  for idx, r in remotes.pairs:
    if r.fetch.len == 0: continue
    if canonicalGitUrl(getFetchUrl(r.fetch, repoName)) != wanted: continue
    var rank = idx
    if r.name == orgLabelFor(canonicalGitUrl(r.fetch)): rank -= 1_000
    if defaultRemote.len > 0 and r.name == defaultRemote: rank -= 1_000_000
    if rank < bestRank:
      bestRank = rank
      result.remoteName = r.name
  if result.remoteName.len > 0:
    return

  let (base, leaf) = splitLastSegment(wanted)
  if base.len == 0 or leaf.len == 0:
    result.error = "remote URL '" & requestedUrl &
      "' has no repository path segment to compose a manifest entry from"
    return

  # Rule 2 — the URL's server-side name differs from the local checkout name
  # (`llvm/llvm-project` checked out as `llvm-project`, or a bare `…/x.git`
  # directory). A declared base that PREFIXES the URL can still serve it; the
  # fragment carries the remaining path as its `name`.
  if leaf != repoName:
    var bestBaseLen = -1
    for r in remotes:
      if r.fetch.len == 0: continue
      let rBase = canonicalGitUrl(r.fetch)
      if rBase.endsWith(".git"): continue   # verbatim, single-repo base
      if not wanted.startsWith(rBase & "/"): continue
      if rBase.len > bestBaseLen:
        bestBaseLen = rBase.len
        result.remoteName = r.name
        result.repoName = wanted[rBase.len + 1 .. ^1]
    if result.remoteName.len > 0:
      return

  # Rule 3 — mint ONE org-named remote carrying the org base, so the next
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
    let fragment = readRepoFragment(fragmentAbs)

    var resolved: ResolvedRepo
    resolved.name = fragment.repo.name
    resolved.path =
      if fragment.repo.path.len > 0: fragment.repo.path
      else: fragment.repo.name
    resolved.fragmentPath = fragmentAbs

    # Resolve remote name: fragment's explicit value wins; otherwise the
    # project's `default_remote`. If the fragment omits `remote` and the
    # project declares no `default_remote`, that's a structural error.
    let fragmentRemote =
      if fragment.repo.remote.isSome: fragment.repo.remote.get()
      else: ""
    if fragmentRemote.len > 0:
      resolved.projectRemote = fragmentRemote
    elif defaultRemoteName.len > 0:
      resolved.projectRemote = defaultRemoteName
    else:
      raiseManifestError(absProject,
        "includes[" & $incIdx & "]",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "fragment '" & rawInclude &
          "' omits `repo.remote` and the project has no `default_remote`")

    var resolvedRemotes = newSeq[ResolvedRemote]()
    if fragment.repo.remotes.len > 0:
      for r in fragment.repo.remotes:
        if r.remote notin remotes:
          raiseManifestError(absProject,
            "includes[" & $incIdx & "]",
            schemaProjectManifestV1, schemaProjectManifestV1,
            "fragment '" & rawInclude & "' references unknown remote '" &
              r.remote & "' (not declared in the project's [[remote]] table)")
        let fullUrl = getFetchUrl(remotes[r.remote], fragment.repo.name)
        resolvedRemotes.add(ResolvedRemote(localName: r.name, projectRemote: r.remote, fetchUrl: fullUrl))

      let primaryName = if fragmentRemote.len > 0: fragmentRemote else: resolvedRemotes[0].localName
      resolved.projectRemote = primaryName
      var primaryProjectRemote = ""
      for r in resolvedRemotes:
        if r.localName == primaryName:
          primaryProjectRemote = r.projectRemote
          break
      if primaryProjectRemote.len == 0:
        primaryProjectRemote = resolvedRemotes[0].projectRemote
      resolved.fetchUrl = getFetchUrl(remotes[primaryProjectRemote], fragment.repo.name)
    else:
      if resolved.projectRemote notin remotes:
        raiseManifestError(absProject,
          "includes[" & $incIdx & "]",
          schemaProjectManifestV1, schemaProjectManifestV1,
          "fragment '" & rawInclude & "' references unknown remote '" &
            resolved.projectRemote & "' (not declared in the project's [[remote]] table)")
      let fullUrl = getFetchUrl(remotes[resolved.projectRemote], fragment.repo.name)
      resolved.fetchUrl = fullUrl
      resolvedRemotes.add(ResolvedRemote(localName: "origin", projectRemote: resolved.projectRemote, fetchUrl: fullUrl))

    resolved.remotes = resolvedRemotes

    # Resolve revision: fragment's explicit value wins; otherwise the
    # project's `default_revision`. If neither is set we leave the field
    # empty — the caller's downstream policy (e.g. M9's `workspace init`)
    # decides what an empty revision means. We do NOT inject a hardcoded
    # branch name here.
    let fragmentRevision =
      if fragment.repo.revision.isSome: fragment.repo.revision.get()
      else: ""
    if fragmentRevision.len > 0:
      resolved.revision = fragmentRevision
    else:
      resolved.revision = result.defaultRevision

    resolved.vcs =
      if fragment.repo.vcs.isSome and fragment.repo.vcs.get().len > 0:
        fragment.repo.vcs.get()
      else:
        defaultRepoVcs
    resolved.stability =
      if fragment.repo.stability.isSome and fragment.repo.stability.get().len > 0:
        fragment.repo.stability.get()
      else:
        defaultRepoStability
    # MO-5 — carry the evidence-only participation marker verbatim (default "").
    if fragment.repo.participation.isSome:
      resolved.participation = fragment.repo.participation.get()

    # RA-14 — carry the fetch-acceleration hints through unchanged. They
    # are pure download knobs; the resolved revision above is the single
    # source of truth for what the checkout resolves to.
    if fragment.repo.clone_filter.isSome:
      resolved.cloneFilter = fragment.repo.clone_filter.get()
    if fragment.repo.depth.isSome:
      resolved.depth = fragment.repo.depth.get()
    if fragment.repo.single_branch.isSome:
      resolved.singleBranch = fragment.repo.single_branch.get()

    # RA-18 — carry the copyfile/linkfile directives and group membership
    # through verbatim. These are workspace-layout facts, not download
    # knobs; the materialization step runs post-checkout in the CLI driver.
    resolved.copyfile = fragment.repo.copyfile
    resolved.linkfile = fragment.repo.linkfile
    resolved.groups = fragment.repo.groups

    # RA-21 — carry the develop-set dependency edges through verbatim.
    resolved.depends = fragment.repo.depends

    # Duplicate check on the `(name, path, projectRemote)` triple. We use
    # a tab-joined key because none of the three components legally
    # contains a tab character (repo names are file-system-safe; paths
    # use forward slashes; remote names are TOML identifiers).
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
    let fragment = readRepoFragment(fragmentAbs)

    var resolved: ResolvedRepo
    resolved.name = fragment.repo.name
    resolved.path =
      if fragment.repo.path.len > 0: fragment.repo.path
      else: fragment.repo.name
    resolved.fragmentPath = fragmentAbs

    let fragmentRemote =
      if fragment.repo.remote.isSome: fragment.repo.remote.get()
      else: ""
    if fragmentRemote.len > 0:
      resolved.projectRemote = fragmentRemote
    elif defaultRemoteName.len > 0:
      resolved.projectRemote = defaultRemoteName
    else:
      raiseManifestError(absVariant,
        "includes[" & $incIdx & "]",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "fragment '" & rawInclude &
          "' omits `repo.remote` and the base project has no `default_remote`")

    var resolvedRemotes = newSeq[ResolvedRemote]()
    if fragment.repo.remotes.len > 0:
      for r in fragment.repo.remotes:
        if r.remote notin remotes:
          raiseManifestError(absVariant,
            "includes[" & $incIdx & "]",
            schemaVariantManifestV1, schemaVariantManifestV1,
            "fragment '" & rawInclude & "' references unknown remote '" &
              r.remote & "' (not declared in the base project's [[remote]] table)")
        let fullUrl = getFetchUrl(remotes[r.remote], fragment.repo.name)
        resolvedRemotes.add(ResolvedRemote(localName: r.name, projectRemote: r.remote, fetchUrl: fullUrl))
      
      let primaryName = if fragmentRemote.len > 0: fragmentRemote else: resolvedRemotes[0].localName
      resolved.projectRemote = primaryName
      var primaryProjectRemote = ""
      for r in resolvedRemotes:
        if r.localName == primaryName:
          primaryProjectRemote = r.projectRemote
          break
      if primaryProjectRemote.len == 0:
        primaryProjectRemote = resolvedRemotes[0].projectRemote
      resolved.fetchUrl = getFetchUrl(remotes[primaryProjectRemote], fragment.repo.name)
    else:
      if resolved.projectRemote notin remotes:
        raiseManifestError(absVariant,
          "includes[" & $incIdx & "]",
          schemaVariantManifestV1, schemaVariantManifestV1,
          "fragment '" & rawInclude & "' references unknown remote '" &
            resolved.projectRemote & "' (not declared in the base project's [[remote]] table)")
      let fullUrl = getFetchUrl(remotes[resolved.projectRemote], fragment.repo.name)
      resolved.fetchUrl = fullUrl
      resolvedRemotes.add(ResolvedRemote(localName: "origin", projectRemote: resolved.projectRemote, fetchUrl: fullUrl))

    resolved.remotes = resolvedRemotes

    let fragmentRevision =
      if fragment.repo.revision.isSome: fragment.repo.revision.get()
      else: ""
    if fragmentRevision.len > 0:
      resolved.revision = fragmentRevision
    else:
      resolved.revision = result.defaultRevision

    resolved.vcs =
      if fragment.repo.vcs.isSome and fragment.repo.vcs.get().len > 0:
        fragment.repo.vcs.get()
      else:
        defaultRepoVcs
    resolved.stability =
      if fragment.repo.stability.isSome and fragment.repo.stability.get().len > 0:
        fragment.repo.stability.get()
      else:
        defaultRepoStability
    # MO-5 — carry the evidence-only participation marker verbatim (default "").
    if fragment.repo.participation.isSome:
      resolved.participation = fragment.repo.participation.get()

    # RA-14 — carry the fetch-acceleration hints through unchanged. They
    # are pure download knobs; the resolved revision above is the single
    # source of truth for what the checkout resolves to.
    if fragment.repo.clone_filter.isSome:
      resolved.cloneFilter = fragment.repo.clone_filter.get()
    if fragment.repo.depth.isSome:
      resolved.depth = fragment.repo.depth.get()
    if fragment.repo.single_branch.isSome:
      resolved.singleBranch = fragment.repo.single_branch.get()

    # RA-18 — carry the copyfile/linkfile directives and group membership
    # through verbatim (same as the project path above).
    resolved.copyfile = fragment.repo.copyfile
    resolved.linkfile = fragment.repo.linkfile
    resolved.groups = fragment.repo.groups

    # RA-21 — carry the develop-set dependency edges through verbatim.
    resolved.depends = fragment.repo.depends

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

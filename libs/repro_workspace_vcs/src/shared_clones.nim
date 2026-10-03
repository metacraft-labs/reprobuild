## Workspace VCS — shared bare-clone cache + alternates wiring (RA-5).
##
## A *source-acquisition accelerator* that is strictly separate from the
## action-output CAS. It speeds how source arrives; it never changes what
## is built. The clone receipt (remote + revision + resolved SHA) remains
## the determinism unit, and a cold cache MUST produce a byte-identical
## resolved tree (transparency).
##
## The design (see ``reprobuild-specs/Workspace-And-Develop-Mode.md`` §
## "Clone acceleration: shared object cache"):
##
##   - Each unique upstream fetch URL → a stable filesystem slug → ONE
##     bare clone under a per-user cache root. The shared bare is
##     refreshed clone-if-missing / fetch-if-present
##     (``git fetch --all --prune``), never rewrites its commit-graph
##     (``SharedBareSafetyConfig``), and expires only objects no registered
##     borrower names (``poolIntegrityConfig``, see
##     ``reprobuild-specs/spec/Shared-Clone-Pool-Integrity.md``): other
##     checkouts borrow from it.
##   - Each per-workspace repo writes ``objects/info/alternates`` pointing
##     at the shared bare's ``objects/`` dir, so a sync transfers only the
##     objects not already in the shared pool. Git natively honors
##     alternates.
##   - Wiring is best-effort: on any failure the caller falls back to a
##     normal standalone clone (init is never broken by the accelerator).
##   - ``pushCacheRef`` pushes a repo's current branch to
##     ``refs/cache/<workspace>/<branch>`` in the shared bare
##     (``--force --no-verify``, workspace-namespaced) so siblings
##     alternated to the same bare see the objects with no network fetch.
##     RA-4 wires this into the post-commit hook; RA-5 ships the mechanism.
##
## The module shells out to a caller-provided ``git`` binary path (the
## same identity-bound binary ``git_actions`` uses) via ``execCmdEx`` —
## no new third-party dependency, matching the M2 subprocess shape.

import std/[os, osproc, strtabs, strutils, times]

import git_tool

const
  AlternatesRelPath* = "objects/info/alternates"
    ## Path, relative to a git object-store root, of the alternates file
    ## git reads to discover additional read-only object pools.

type
  ManifestCacheEntryStatus* = enum
    ## What a directory sitting at a manifest-cache path turned out to BE,
    ## once asked. W8-R3: the whole defect was that this question had exactly
    ## two answers — ``looksLikeGitDir`` true or false — and "a git dir that
    ## belongs to someone else", "a git dir that cannot say who it belongs
    ## to" and "a git dir that is mine" were all the same answer. Each is now
    ## its own value, and in particular ABSENCE (``mceAbsent``, recoverable by
    ## cloning) and FAILURE TO READ (``mceUnreadable`` / ``mceNoOrigin``,
    ## which must refuse) are never folded together — that collapse is the
    ## root defect this campaign keeps finding.
    mceUnknown        ## not asked; the zero value for results from other procs
    mceAbsent         ## nothing that looks like a git dir is there
    mceMatches        ## a git dir whose ``origin`` IS the requested repository
    mceForeign        ## a git dir whose ``origin`` is a DIFFERENT repository
    mceNoOrigin       ## a git dir with no ``origin`` remote configured at all
    mceUnreadable     ## the local config could not be read (not a repo, …)

  LeafCheckMode* = enum
    lcmReport   ## report what is wrong; change no ref
    lcmRepair   ## also remove stale remote-tracking refs (message A)

  LeafFindingKind* = enum
    lfkRefilled            ## was missing, came back through the chain: silent
    lfkStaleRemoteRef      ## refs/remotes/* whose commit exists nowhere (A)
    lfkLocalTipMissing     ## a local ref's own commit exists nowhere (B)
    lfkLocalHistoryMissing ## a local branch's commits are intact, a parent is gone (B)
    lfkOldGit              ## git < 2.42: the pool keeps every object (§3.6)

  LeafFinding* = object
    kind*: LeafFindingKind
    refName*: string
      ## Full ref name, ``HEAD``, or ``worktree:<path>`` for a linked
      ## worktree's detached HEAD.
    objectId*: string
      ## The missing object: the ref's tip, or the missing parent.
    childId*: string
      ## For ``lfkLocalHistoryMissing``: the oldest present commit of the
      ## branch, whose parent is ``objectId``.
    removed*: bool
      ## ``lfkStaleRemoteRef`` only: the ref was deleted and logged.
    message*: string
      ## The rendered user-facing message ("" for ``lfkRefilled``).

  LeafCheckReport* = object
    leaf*: string
    pool*: string
    registered*: bool
    configured*: bool
    findings*: seq[LeafFinding]
    diagnostic*: string

  SharedCloneResult* = object
    ## Outcome of a best-effort shared-clone / alternates operation. The
    ## caller inspects ``ok`` to decide whether to fall back to a plain
    ## standalone clone. ``diagnostic`` carries the human-facing reason on
    ## failure (empty on success).
    ok*: bool
    sharedBarePath*: string
    diagnostic*: string
    manifestEntry*: ManifestCacheEntryStatus
      ## W8-R3 — set only by ``ensureManifestCache``: which of the states
      ## above the cache entry it settled on was in. Carried as a VALUE and
      ## not merely spelled into ``diagnostic`` so a caller can tell a refusal
      ## caused by an unreadable entry from one caused by a foreign entry
      ## without parsing prose. ``mceUnknown`` on every other proc's result.
    leafReports*: seq[LeafCheckReport]
      ## Set by ``refreshSharedBare``: the detector's report for every leaf
      ## registered with the refreshed pool (Shared-Clone-Pool-Integrity
      ## §4.2). The caller prints their messages.

# ---- cache-root resolution -------------------------------------------------

proc windowsDrive(path: string): string =
  ## Return the ``X:`` drive prefix of an absolute Windows path, or "" if
  ## the path has no drive letter. Pure string logic so it is testable on
  ## any host (the resolution order below only *consults* it on Windows).
  if path.len >= 2 and path[1] == ':' and path[0].isAlphaAscii:
    path[0 .. 1]
  else:
    ""

proc resolveCacheRoot*(env: proc(key: string): string {.closure.};
                       workspaceRoot = ""; isWindows = false): string =
  ## Resolve the cache root following the RA-5 order:
  ##
  ##   ``REPRO_WORKSPACE_CLONES`` (explicit override)
  ##   → on Windows, when the workspace lives on a different drive than the
  ##     user profile, ``<drive>\.cache\reprobuild\clones``
  ##   → ``XDG_CACHE_HOME``
  ##   → ``%LOCALAPPDATA%`` (Windows fallback)
  ##   → ``~/.cache``
  ##
  ## The returned path is the ``…/reprobuild/clones`` directory; per-URL
  ## bares live beneath it under their slug. ``env`` is injected (rather
  ## than calling ``os.getEnv`` directly) so the resolver is hermetically
  ## testable. The explicit-override branch returns the override verbatim
  ## (the operator pointed at a clones dir directly); every other branch
  ## appends ``reprobuild/clones``.
  let override = env("REPRO_WORKSPACE_CLONES")
  if override.len > 0:
    return override

  if isWindows and workspaceRoot.len > 0:
    let wsDrive = windowsDrive(workspaceRoot)
    let profile = env("USERPROFILE")
    let profileDrive = windowsDrive(profile)
    if wsDrive.len > 0 and profileDrive.len > 0 and
        cmpIgnoreCase(wsDrive, profileDrive) != 0:
      return wsDrive & "\\.cache" / "reprobuild" / "clones"

  let xdg = env("XDG_CACHE_HOME")
  if xdg.len > 0:
    return xdg / "reprobuild" / "clones"

  if isWindows:
    let localAppData = env("LOCALAPPDATA")
    if localAppData.len > 0:
      return localAppData / "reprobuild" / "clones"

  let home = env("HOME")
  let base =
    if home.len > 0: home / ".cache"
    elif isWindows:
      let up = env("USERPROFILE")
      if up.len > 0: up / ".cache" else: ".cache"
    else: ".cache"
  base / "reprobuild" / "clones"

proc defaultCacheRoot*(workspaceRoot = ""): string =
  ## Convenience wrapper that resolves the cache root against the live
  ## process environment and host OS. Production call sites use this; the
  ## hermetic tests use ``resolveCacheRoot`` with an injected ``env``.
  proc liveEnv(key: string): string = getEnv(key)
  resolveCacheRoot(liveEnv, workspaceRoot, defined(windows))

# ---- bootstrap manifest cache root (RA-11) ---------------------------------

proc resolveManifestCacheRoot*(env: proc(key: string): string {.closure.};
                               private = false; isWindows = false): string =
  ## Resolve the **bootstrap manifest cache** root (RA-11). This is the
  ## tool-managed location ``repro workspace init`` clones the manifest
  ## repo into so that ``init`` works *outside* an existing workspace
  ## (no sibling manifest checkout yet). It is independent of the RA-5
  ## *clones* cache above: the manifest cache holds manifest REPOS, the
  ## clones cache holds participating-repo object pools.
  ##
  ## Resolution order, per
  ## ``Workspace-And-Develop-Mode.md`` §"Manifest cache and
  ## partial-failure policy":
  ##
  ##   ``REPRO_MANIFEST_CACHE`` (explicit override)
  ##   → ``XDG_CACHE_HOME``/reprobuild/manifests
  ##   → ``%LOCALAPPDATA%``/reprobuild/manifests   (Windows fallback)
  ##   → ``~/.cache``/reprobuild/manifests
  ##
  ## ``private = true`` selects the **private companion** cache: a
  ## parallel ``…/manifests-private`` tree so a private companion
  ## manifest never shares a directory (or a slug namespace) with the
  ## public manifest. The override branch honors the same split by
  ## appending ``-private`` to the operator's explicit path.
  ##
  ## ``env`` is injected (rather than calling ``os.getEnv`` directly) so
  ## the resolver is hermetically testable.
  let leaf = if private: "manifests-private" else: "manifests"
  let override = env("REPRO_MANIFEST_CACHE")
  if override.len > 0:
    return if private: override & "-private" else: override

  let xdg = env("XDG_CACHE_HOME")
  if xdg.len > 0:
    return xdg / "reprobuild" / leaf

  if isWindows:
    let localAppData = env("LOCALAPPDATA")
    if localAppData.len > 0:
      return localAppData / "reprobuild" / leaf

  let home = env("HOME")
  let base =
    if home.len > 0: home / ".cache"
    elif isWindows:
      let up = env("USERPROFILE")
      if up.len > 0: up / ".cache" else: ".cache"
    else: ".cache"
  base / "reprobuild" / leaf

proc defaultManifestCacheRoot*(private = false): string =
  ## Convenience wrapper that resolves the manifest cache root against the
  ## live process environment and host OS. Production call sites use this;
  ## hermetic tests use ``resolveManifestCacheRoot`` with an injected
  ## ``env``.
  proc liveEnv(key: string): string = getEnv(key)
  resolveManifestCacheRoot(liveEnv, private, defined(windows))

# ---- URL → slug ------------------------------------------------------------

proc sanitizeSlugSegment(segment: string): string =
  ## Keep a path segment to a portable character set: ASCII alnum plus
  ## ``-._``; everything else (``:``, ``@``, spaces, …) becomes ``_``. This is
  ## deterministic; it is NOT injective and NOT meant to round-trip back to
  ## the URL.
  ##
  ## SAYING THAT PLAINLY, because this doc used to call the set
  ## "collision-resistant" and it is not. The mapping is many-to-one by
  ## construction: ``a:b``, ``a_b`` and ``a@b`` are three distinct segments
  ## that all slug to ``a_b``, and that predates any of this. The W5 rule
  ## below adds more of the same — ``..`` and ``__`` both become ``__``, ``.``
  ## and ``_`` both become ``_`` — so ``https://h/../victim.git`` and
  ## ``https://h/__/victim.git`` share one cache directory (measured). What
  ## the slug has to be is STABLE (the same URL always maps to the same
  ## directory, so a cache hit is a cache hit) and CONTAINED (it never points
  ## outside the cache root). Injectivity is not a property it has ever had,
  ## and what a collision costs differs by consumer:
  ##
  ##   * ``sharedBarePath`` — harmless. The shared bare is an OBJECT POOL,
  ##     wired in through ``objects/info/alternates``; the real clone still
  ##     fetches from its own remote and simply finds fewer of its objects
  ##     already present. A collision costs a redundant fetch.
  ##   * ``manifestCachePath`` — a shared CHECKOUT that is read directly, so
  ##     two colliding manifest URLs would share one working tree. That is a
  ##     wrong-content outcome rather than a slow one, and it is pre-existing
  ##     (``a:b``/``a_b`` collided before W5); see the note there.
  ##
  ## Neither is a CONTAINMENT question, which is what this proc is being
  ## changed for, and widening the character set to reduce collisions is a
  ## separate decision with a cache-invalidation cost — every slug that moves
  ## orphans the bare clone already on disk under the old name.
  ##
  ## W5 — AND NO SEGMENT MAY BE A TRAVERSAL. The ``-._`` set kept ``..``
  ## verbatim, so a URL path segment of ``..`` survived into the slug and
  ## steered every path built from it out of the cache root. Measured through
  ## the real ``urlSlug`` + ``sharedBarePath``, against a cache root of
  ## ``C:\Users\<u>\AppData\Local\Temp\w5cache`` — and note the escape is
  ## complete before any ``extendedPath`` is involved, because ``os./``
  ## already folds the ``..`` away:
  ##
  ##   https://h/../../../victim.git -> C:\Users\<u>\AppData\Local\victim.git
  ##   git@h:../../victim.git        -> C:\Users\<u>\AppData\Local\Temp\victim.git
  ##
  ## Three cleanup paths ``removeDir`` that computed directory when the clone
  ## into it FAILS — ``refreshSharedBare`` and ``ensureManifestCache`` below,
  ## and ``git_actions.nim``'s ``refresh-bare`` executor — which is the "the
  ## recovery step becomes the incident" shape again: the delete happens on
  ## the failure branch, so a URL that cannot be cloned at all is not a URL
  ## that is harmless. Measured end to end on ``d0c6ad8f``, and asserted by
  ## ``t_a_hostile_fetch_url_deletes_a_real_directory_before_this_rule``: an
  ## existing victim directory at the computed path is what MAKES the clone
  ## fail ("destination path already exists and is not an empty directory"),
  ## and the cleanup then deletes it.
  ##
  ## WHY THE RULE IS HERE and not at the lock boundary that validates the
  ## other delete-steering lock fields. Two reasons, and they are the same
  ## two:
  ##
  ##   * The URL is not a path, and ``..`` in a REMOTE path is legal — it
  ##     names something on the server and need never become a local
  ##     directory. Refusing it upstream would refuse a legitimate remote to
  ##     protect a local join that is this proc's job to make safe.
  ##   * The URL arrives from TWO independent producers — a lock's
  ##     ``dep.coordinates.url`` and a manifest's ``repo.remote`` (via
  ##     ``cloneUrlFor``) — and only the first passes through
  ##     ``validateLockedDeps``. A rule there would cover one and leave the
  ##     other open. This proc is the single funnel both producers cross, and
  ##     it is total: it returns a segment for every input rather than
  ##     rejecting some, so there is no route around it and no caller left to
  ##     remember a check.
  ##
  ## The rule: after sanitization, a segment made of NOTHING BUT ``.`` is not
  ## a name, it is navigation — ``.`` (self), ``..`` (parent), and ``...``
  ## and beyond, which Win32 strips trailing dots from and can therefore
  ## collapse INTO ``..``. Each such dot becomes ``_``, so ``..`` slugs to
  ## ``__`` and stays one inert segment. Any segment containing a single
  ## alphanumeric, ``-`` or ``_`` is already inert (``a..b``, ``..z`` and
  ## ``_..`` are ordinary directory names) and is left exactly as it was, so
  ## no slug for a real remote moves.
  ##
  ## Rewriting to ``_`` rather than to a reserved spelling is what MAKES this
  ## many-to-one: ``..`` now shares a slug with a literal ``__`` segment, and
  ## ``.`` with ``_``. That is a deliberate choice of the collision (which
  ## costs at worst a shared cache directory, see above) over a wider
  ## character set (which would move existing slugs and orphan every bare
  ## clone on disk). It is a widening of a pre-existing many-to-one mapping,
  ## not a new property.
  result = newStringOfCap(segment.len)
  var dotsOnly = segment.len > 0
  for ch in segment:
    if ch.isAlphaNumeric or ch in {'-', '.', '_'}:
      result.add(ch)
      if ch != '.': dotsOnly = false
    else:
      result.add('_')
      dotsOnly = false
  if dotsOnly:
    for i in 0 ..< result.len:
      result[i] = '_'

proc normalizeFetchUrl(url: string): string =
  ## Normalize an upstream fetch URL so trivially-different spellings of
  ## the same remote map to the same slug:
  ##   - strip a trailing ``/``
  ##   - strip a trailing ``.git`` (added back as the bare suffix)
  ##   - lowercase the scheme + host portion is left as-is (paths can be
  ##     case-sensitive on the server) — we only trim, not case-fold, to
  ##     stay safe.
  result = url.strip()
  while result.len > 0 and result[^1] == '/':
    result.setLen(result.len - 1)
  if result.toLowerAscii.endsWith(".git"):
    result.setLen(result.len - 4)

type
  RemoteUrlParts = object
    ## The decomposition of a fetch URL that BOTH ``urlSlug`` and
    ## ``canonicalRemoteIdentity`` are built from. Factored out so the two
    ## cannot disagree about *what* the host and the path are: the slug folds
    ## these fields through ``sanitizeSlugSegment``, the identity does not, and
    ## that single difference is the whole of W8-R3's fix.
    scheme: string
      ## Lowercased URL scheme, or "" for scp-like / bare-local spellings.
    host: string
      ## Authority with userinfo and port removed; ``_local_`` for a path.
    port: string
      ## Explicit port as spelled, or "" when the URL carries none.
    path: string
      ## Everything after the authority, with the trailing ``/`` and ``.git``
      ## already trimmed by ``normalizeFetchUrl``.

proc decomposeRemoteUrl(url: string): RemoteUrlParts =
  ## Split a fetch URL into scheme / host / port / path. This is exactly the
  ## parse ``urlSlug`` has always done, lifted out verbatim so a second
  ## consumer can reuse it; the only addition is that the port is RETAINED
  ## rather than dropped on the floor.
  ##
  ## Known limitation, pre-existing and deliberately not changed here: a
  ## bracketed IPv6 authority (``[::1]:22``) is split at its FIRST colon, so
  ## ``host`` is ``[`` and ``port`` is the remainder. That is wrong as a parse
  ## but it is DETERMINISTIC, so every spelling of one IPv6 URL still
  ## decomposes identically and both consumers stay self-consistent.
  let normalized = normalizeFetchUrl(url)
  if normalized.contains("://"):
    # scheme://[user@]host[:port]/path
    let sep = normalized.find("://")
    result.scheme = normalized[0 ..< sep].toLowerAscii
    let afterScheme = normalized[sep + 3 .. ^1]
    let firstSlash = afterScheme.find('/')
    var authority = ""
    if firstSlash < 0:
      authority = afterScheme
      result.path = ""
    else:
      authority = afterScheme[0 ..< firstSlash]
      result.path = afterScheme[firstSlash + 1 .. ^1]
    # strip user@ and :port from the authority
    let at = authority.find('@')
    if at >= 0: authority = authority[at + 1 .. ^1]
    let colon = authority.find(':')
    if colon >= 0:
      result.port = authority[colon + 1 .. ^1]
      authority = authority[0 ..< colon]
    result.host = authority
    if result.host.len == 0:
      # file:///abs/path → empty authority; treat as a local path.
      result.host = "_local_"
  elif normalized.contains('@') and normalized.contains(':') and
      not normalized.startsWith('/'):
    # scp-like syntax: [user@]host:path — the text after the colon is a
    # PATH, never a port, so ``port`` stays empty.
    let at = normalized.find('@')
    let rest = if at >= 0: normalized[at + 1 .. ^1] else: normalized
    let colon = rest.find(':')
    result.host = rest[0 ..< colon]
    result.path = rest[colon + 1 .. ^1]
  else:
    # bare local path
    result.host = "_local_"
    result.path = normalized

proc urlSlug*(url: string): string =
  ## Map a fetch URL to a stable, filesystem-safe relative slug of the
  ## form ``<host>/<path-segments>.git``. Works for ``https://``,
  ## ``ssh://``, ``git://``, ``file://`` and bare local paths.
  ##
  ## Examples:
  ##   ``https://github.com/org/repo.git`` → ``github.com/org/repo.git``
  ##   ``git@github.com:org/repo.git``     → ``github.com/org/repo.git``
  ##   ``file:///tmp/origin-lib-a.git``    → ``_local_/tmp/origin-lib-a.git``
  ##   ``/tmp/origin-lib-a.git``           → ``_local_/tmp/origin-lib-a.git``
  let parts = decomposeRemoteUrl(url)
  var segments: seq[string]
  if parts.host.len > 0:
    segments.add(sanitizeSlugSegment(parts.host))
  for raw in parts.path.split('/'):
    if raw.len == 0: continue
    segments.add(sanitizeSlugSegment(raw))
  if segments.len == 0:
    segments.add("_empty_")
  result = segments.join("/") & ".git"

proc defaultPortForScheme(scheme: string): string =
  ## The port a scheme implies when the URL does not spell one. Used only to
  ## decide whether an EXPLICIT port is redundant; an unknown scheme has no
  ## default, so its explicit port is always significant.
  case scheme
  of "https": "443"
  of "http": "80"
  of "ssh": "22"
  of "git": "9418"
  else: ""

proc canonicalRemoteIdentity*(url: string): string =
  ## The identity of the REPOSITORY a fetch URL names, as a comparable
  ## string. Two URLs denote the same repository iff their identities are
  ## equal.
  ##
  ## This is ``urlSlug``'s decomposition WITHOUT ``sanitizeSlugSegment``. That
  ## is the whole point: the slug is a filesystem NAME and is many-to-one by
  ## construction (``a:b``, ``a_b`` and ``a@b`` share one directory, and since
  ## W5 so do ``..`` and ``__``); the identity is an ANSWER TO "is this entry
  ## mine", and folding characters there is what let the first URL to reach a
  ## slug own it. Nothing here is lossy, so the collisions the slug has do not
  ## reach the check that guards the slug's contents.
  ##
  ## WHAT IT DELIBERATELY TREATS AS EQUAL, and why each is safe:
  ##
  ##   * **The scheme.** ``https://h/o/r``, ``ssh://h/o/r`` and
  ##     ``git@h:o/r`` all have identity ``h/o/r``. It is the equivalence the
  ##     cache key was BUILT on: ``urlSlug`` never reads the scheme at all, so
  ##     its own documented examples map the https and scp spellings of one
  ##     GitHub repo to one slug. An identity that required scheme equality
  ##     would be FINER than the key it guards in that dimension, so a
  ##     workspace that bootstrapped over https and later over ssh would
  ##     re-key and clone a second, permanent copy of the same repository.
  ##     Stated exactly, because it is the one fold that is a judgement and
  ##     not a derivation: scheme equality is not free of risk, it is
  ##     PRE-EXISTING risk. Two different servers really could answer
  ##     ``https://h/o/r`` and ``git://h/o/r``, and this rule would call them
  ##     one repository — but so does the slug, so they already shared one
  ##     directory before this fix and separating them here would not stop
  ##     them sharing a slug. Every OTHER equivalence below is one the slug
  ##     also makes, or one where the identity is COARSER than the slug (host
  ##     case), which costs a second entry and can never mis-serve. So the
  ##     identity is a strict refinement of the key everywhere it can be one:
  ##     it adds no co-tenancy the key did not already have.
  ##   * **A trailing ``.git`` and a trailing ``/``** — already folded by
  ##     ``normalizeFetchUrl``, so ``…/r``, ``…/r.git`` and ``…/r.git/`` are
  ##     one repository.
  ##   * **Userinfo.** ``https://alice@h/o/r`` and ``https://h/o/r`` are the
  ##     same repository fetched with different credentials. Whose credentials
  ##     they are is not a property of the repository.
  ##   * **Host case.** DNS is case-insensitive, so ``H/o/r`` == ``h/o/r``.
  ##   * **A redundant default port.** ``https://h:443/o/r`` == ``https://h/o/r``.
  ##   * **Empty path segments.** ``h//o///r`` == ``h/o/r``, matching the slug.
  ##
  ## WHAT IT DELIBERATELY DOES **NOT** TREAT AS EQUAL:
  ##
  ##   * **Punctuation in the path.** ``h/a:b/r``, ``h/a_b/r`` and ``h/a@b/r``
  ##     are three repositories that share one slug. Separating them is the
  ##     defect being fixed; anything looser reopens it.
  ##   * **``..`` versus ``__``.** Same reason.
  ##   * **Path case.** ``h/O/r`` != ``h/o/r``. Some forges fold path case and
  ##     some servers do not, and we cannot tell which from the URL. Folding
  ##     would be a guess in the unsafe direction; not folding costs at worst
  ##     one extra cache entry. (For a ``_local_`` path on a case-insensitive
  ##     filesystem this means two spellings of ONE local repo get two cache
  ##     entries — churn, never wrong content. That is W8-R2's question and it
  ##     is not answered here.)
  ##   * **A non-default port.** ``h:8443`` is a different endpoint than ``h``.
  ##   * **Anything about the on-disk tree.** Identity is about the URL only.
  let parts = decomposeRemoteUrl(url)
  var authority = parts.host.toLowerAscii
  if parts.port.len > 0 and parts.port != defaultPortForScheme(parts.scheme):
    authority.add(":")
    authority.add(parts.port)
  var segments: seq[string]
  for raw in parts.path.split('/'):
    if raw.len == 0: continue
    segments.add(raw)
  authority & "/" & segments.join("/")

proc identityDigestHex(identity: string): string =
  ## FNV-1a 64 over a canonical identity, as 16 lowercase hex digits. Used
  ## ONLY to name a disambiguated cache directory.
  ##
  ## A non-cryptographic hash is adequate *here* and the reason is structural,
  ## not an appeal to unlikelihood: the directory it names is still subjected
  ## to the same identity check as every other. A forged digest collision
  ## therefore buys an attacker a REFUSAL, not a hit — the failure mode of a
  ## bad digest is churn, and wrong content is unreachable through it. Chosen
  ## over ``std/sha1`` so this module gains no dependency and no deprecation
  ## warning for a value that never leaves the filesystem.
  var h = 0xcbf29ce484222325'u64
  for ch in identity:
    h = h xor uint64(ord(ch))
    h = h * 0x100000001b3'u64
  toHex(h, 16).toLowerAscii

proc sharedBarePath*(cacheRoot, fetchUrl: string): string =
  ## Absolute path of the shared bare clone for ``fetchUrl`` under
  ## ``cacheRoot``.
  cacheRoot / urlSlug(fetchUrl)

proc manifestCachePath*(cacheRoot, manifestUrl: string): string =
  ## Absolute path of the cached manifest-repo checkout for
  ## ``manifestUrl`` under the bootstrap manifest cache ``cacheRoot``
  ## (RA-11). Keyed by source URL (its slug) so workspaces bootstrapped
  ## from different manifest URLs are kept apart.
  ##
  ## "Never collide" is what this said, and it is too strong: ``urlSlug`` is
  ## not injective (see ``sanitizeSlugSegment``), so two manifest URLs
  ## differing only in punctuation — ``a:b`` / ``a_b`` / ``a@b``, and since W5
  ## also ``..`` / ``__`` — share one cached checkout, and the second caller
  ## gets a tree fetched from the first caller's origin. Pre-existing and not
  ## changed here; recorded so the guarantee is not read as stronger than it
  ## is.
  ##
  ## AND THAT IS A TRACKED ITEM, not just a caveat, because of what the branch
  ## above it does. ``ensureManifestCache`` takes ``looksLikeGitDir(target)``
  ## as "this cache entry is mine": it fetches from the checkout's OWN
  ## ``origin`` and returns ``ok = true``. So the first URL to reach a slug
  ## OWNS it, and every colliding URL afterwards is served that origin's tree
  ## without a single check that the remote matches what was asked for. The
  ## consumer is the composer/resolver reading ``projects/*.toml``, i.e. the
  ## document that decides which repos a workspace clones and from where — so
  ## the outcome is wrong content at the point where content becomes trust,
  ## and it PERSISTS: one bootstrap from a hostile spelling poisons every
  ## later bootstrap of the legitimate URL on that host. Contrast
  ## ``sharedBarePath``, where a collision costs a redundant fetch and nothing
  ## else. The remedy is not a wider character set (which moves every existing
  ## slug); it is for this cache to record the URL it was cloned for and
  ## refuse — or re-key — when the recorded URL is not the one being asked
  ## for.
  ##
  ## W8-R3 — THAT IS NOW DONE, and this proc is deliberately UNCHANGED by it.
  ## The slug stays many-to-one (making it injective would move every entry on
  ## disk and orphan every clone already cached); what changed is that
  ## ``ensureManifestCache`` no longer takes arrival at this path as proof of
  ## ownership. It reads the entry's own ``origin`` and compares
  ## ``canonicalRemoteIdentity`` before serving it, so a colliding URL is
  ## detected here rather than served the incumbent's tree, and is re-keyed to
  ## ``disambiguatedManifestCachePath``. See ``inspectManifestCacheEntry``.
  cacheRoot / urlSlug(manifestUrl)

proc disambiguatedManifestCachePath*(cacheRoot, manifestUrl: string): string =
  ## The SECOND path ``ensureManifestCache`` tries when the primary
  ## ``manifestCachePath`` is already owned by a different repository: the
  ## same slug with the URL's canonical identity digest appended.
  ##
  ## Why re-key rather than refuse or evict. A mismatch has two possible
  ## causes and they want opposite things — a benign slug collision wants a
  ## working outcome, an attack wants a refusal — and it is not decidable from
  ## the mismatch alone which one it is. Re-keying satisfies both without
  ## choosing: the legitimate URL gets its own directory and bootstraps
  ## normally, and the hostile entry is never served to it, because the harm
  ## was always "served content from the wrong remote" and never "the wrong
  ## remote has a directory". Eviction (re-clone in place) would satisfy
  ## correctness too but at the price of DELETING a cache entry we have just
  ## proven belongs to someone else, and of two alternating URLs re-cloning
  ## each other forever. Refusal alone would leave the legitimate URL with no
  ## way to bootstrap at all, permanently, since nothing evicts the incumbent.
  ##
  ## The digest is over the identity, not the URL, so every spelling this
  ## module calls equal lands on ONE re-keyed directory. The result stays
  ## inside ``cacheRoot`` (a hex suffix introduces no separator and no
  ## traversal). A re-keyed path that itself collides with some third URL's
  ## entry is caught by the same identity check and REFUSED, so the walk is
  ## two entries deep and terminates.
  cacheRoot / (urlSlug(manifestUrl) & "-" &
    identityDigestHex(canonicalRemoteIdentity(manifestUrl)))

# ---- git plumbing ----------------------------------------------------------

proc runGit(gitBin: string; args: openArray[string];
            workingDir = ""): tuple[code: int; output: string] =
  var cmd = quoteShell(gitBin)
  for arg in args:
    cmd.add(" ")
    cmd.add(quoteShell(arg))
  let res = execCmdEx(cmd, workingDir = workingDir,
    env = scrubbedGitRepositoryEnv())
  (code: res.exitCode, output: res.output)

proc looksLikeGitDir(path: string): bool =
  ## A bare repo has ``HEAD`` + ``objects`` directly; a normal repo has a
  ## ``.git``. Accept either as "already a git object store".
  dirExists(path / "objects") or dirExists(path / ".git")

# ---- shared bare refresh ---------------------------------------------------

const SharedBareFetchRefspec* = "+refs/heads/*:refs/heads/*"
  ## The refspec every shared bare in the cache MUST carry on its
  ## ``origin`` remote.
  ##
  ## ``git clone --bare`` deliberately configures NO ``remote.origin.fetch``
  ## (git-clone(1): ``--bare`` creates no remote-tracking branches and no
  ## refspec). A bare with no refspec still ACCEPTS ``git fetch --all
  ## --prune``, and that fetch still exits 0 -- but it writes nothing except
  ## ``FETCH_HEAD``. ``refs/heads/*`` never moves. Measured on this host's
  ## cache: every bare in it had an EMPTY ``remote.origin.fetch``, and
  ## ``refs/heads/dev`` sat at its clone-time SHA no matter how many times
  ## the cache had been "refreshed".
  ##
  ## Three consequences, all silent. (1) The cache serves clone-time
  ## objects forever, so nothing pushed after the bare was created is ever
  ## accelerated. (2) The entire pre-rewrite history stays reachable from
  ## the frozen ``refs/heads/*``, so ``maintainSharedBare``'s
  ## ``git gc --prune=now`` can never drop it -- a history purge upstream
  ## reclaims nothing locally. (3) The only objects gc CAN collect are the
  ## freshly-fetched ones, because no ref was updated to name them: the
  ## cache prunes exactly the half it should have kept.
  ##
  ## Why heads-only and NOT ``--mirror`` / ``+refs/*:refs/*``: the shared
  ## bare is not a pure mirror. ``pushCacheRef`` publishes sibling-workspace
  ## objects into it under ``refs/cache/<workspace>/*``, and those refs
  ## exist on NO remote. A mirror refspec puts them inside the fetch's
  ## destination namespace, so the very next ``--prune`` DELETES them and
  ## RA-5's cross-workspace object sharing stops without a word. Verified
  ## on a fixture: under ``+refs/*:refs/*`` the cache ref was gone after one
  ## prune; under this refspec it survived and ``refs/heads/*`` still
  ## advanced. Heads-only is the refspec that makes the bare current
  ## without eating the half of it git does not know about.

proc ensureSharedBareRefspec*(gitBin, barePath: string): bool =
  ## Idempotently install ``SharedBareFetchRefspec`` (and
  ## ``remote.origin.prune``) on ``barePath``'s ``origin``. This is ALSO the
  ## in-place migration for every bare already in a user's cache: such a
  ## directory needs no re-clone and no deletion, only these config writes,
  ## after which its next refresh advances and prunes refs normally.
  ## Returns ``false`` when the config could not be read/written.
  # The early return checks BOTH keys. Checking only the refspec would make
  # a bare that was migrated before ``remote.origin.prune`` joined this set
  # permanently un-migratable: it would answer "already done" and never
  # acquire the second half.
  let current = runGit(gitBin,
    ["-C", barePath, "config", "--get-all", "remote.origin.fetch"])
  # A missing key exits 1 with empty output. That is the un-migrated bare,
  # which is the case this proc exists to repair -- not an error.
  var refspecPresent = false
  if current.code == 0:
    for line in current.output.splitLines():
      if line.strip() == SharedBareFetchRefspec:
        refspecPresent = true
        break
  if refspecPresent:
    let prune = runGit(gitBin,
      ["-C", barePath, "config", "--get", "remote.origin.prune"])
    if prune.code == 0 and prune.output.strip().toLowerAscii() == "true":
      return true
  # ``--replace-all``, not ``--add``: a bare carrying some other refspec is
  # being CORRECTED, and appending would leave the wrong one in force
  # alongside the right one.
  let applied = runGit(gitBin, ["-C", barePath, "config", "--replace-all",
    "remote.origin.fetch", SharedBareFetchRefspec])
  if applied.code != 0:
    return false
  # ``remote.origin.prune`` belongs with the refspec, not with the call
  # site. The refresh already passes ``--prune``, but this cache is also
  # read and refreshed by other code paths and by operators poking at it by
  # hand, and a branch deleted upstream that lingers in the bare keeps its
  # whole history reachable -- the same way the missing refspec did. Pinning
  # the behaviour in the bare's own config makes "deleted upstream means
  # gone here" a property of the cache rather than of who fetched it.
  # Measured on the real cache: ``refs/heads/main`` was still present in
  # bares whose remote had deleted that branch months earlier.
  runGit(gitBin, ["-C", barePath, "config", "--replace-all",
    "remote.origin.prune", "true"]).code == 0

proc poolIntegrityConfig*(gitBin, pool: string): seq[(string, string)] {.gcsafe.}
proc checkRegisteredLeaves*(gitBin, pool: string;
                            mode = lcmRepair): seq[LeafCheckReport] {.gcsafe.}
proc registerLeafWithPool*(gitBin, leaf, pool: string): string {.gcsafe.}
proc pruneBorrowers*(pool: string): seq[string] {.gcsafe.}
proc registerBorrower*(pool, leaf: string): bool {.gcsafe.}
proc borrowersPath*(pool: string): string {.gcsafe.}
proc ensureLeafPoolConfig*(gitBin, leaf, pool: string): string {.gcsafe.}

const SharedBareSafetyConfig* = [
  ("gc.auto", "0"),
  ("maintenance.auto", "false"),
  ("maintenance.strategy", "none"),
  ("gc.writeCommitGraph", "false"),
  ("fetch.writeCommitGraph", "false")]
  ## Configuration every shared bare MUST carry because other checkouts
  ## BORROW from it.
  ##
  ## A checkout wired to the bare through ``objects/info/alternates`` can hold
  ## branches, remote-tracking refs, reflogs and stashes naming objects that
  ## exist ONLY in the bare. The bare cannot see those references, and its
  ## borrowers live in any number of sibling workspaces, so "unreachable here"
  ## never means "unused". Two things git does on its own therefore destroy
  ## sibling workspaces:
  ##
  ##   1. Automatic maintenance. ``git fetch`` (and ``receive-pack``, i.e. the
  ##      post-commit cache-ref push) ends with ``git maintenance run --auto``.
  ##      Right after an upstream history rewrite, ``fetch --prune`` has just
  ##      made the pre-rewrite commits unreachable in the bare, and the gc task
  ##      expires them. Measured on 12 recorder bares borrowed by 8 workspaces
  ##      each: borrowers then failed ``fsck`` with ``invalid sha1 pointer`` and
  ##      every later ``git fetch`` with ``did not send all necessary
  ##      objects``. ``gc.auto`` / ``maintenance.auto`` /
  ##      ``maintenance.strategy`` turn the automatic pass off (each alone was
  ##      enough to stop the loss in the fixture). What a gc that DOES run
  ##      may expire is decided per pool, not here: ``poolIntegrityConfig``
  ##      sets ``gc.pruneExpire`` and the retention hook that tells gc what
  ##      the registered borrowers still name
  ##      (``reprobuild-specs/spec/Shared-Clone-Pool-Integrity.md`` §3).
  ##   2. Commit-graph rewrites. A borrower that writes a split commit-graph
  ##      chains its layer onto the bare's layers. ``fetch.writeCommitGraph``
  ##      MERGES the bare's split chain on every fetch, and gc replaces it; each
  ##      leaves every chained borrower printing ``unable to find all
  ##      commit-graph files`` on every command. Measured on git 2.54 under both
  ##      the ``gc`` and ``geometric`` maintenance strategies: disabling
  ##      automatic maintenance alone does NOT prevent this -- the fetch-time
  ##      write does it by itself -- so ``fetch.writeCommitGraph=false`` is
  ##      required in addition, and ``gc.writeCommitGraph=false`` covers gc.
  ##
  ## Persisted in the bare's own config (not only passed per command) so the
  ## property holds for whoever touches the cache: an operator's hand-run
  ## ``git fetch``, and the ``receive-pack`` a cache-ref push runs there.

proc sharedBareSafetyArgs*(): seq[string] =
  ## ``-c key=value`` pairs for ``SharedBareSafetyConfig``, to prefix every git
  ## command reprobuild itself runs against a shared bare. Belt and braces for
  ## a bare whose config could not be written (read-only cache, a concurrent
  ## writer holding the config lock).
  for (key, value) in SharedBareSafetyConfig:
    result.add("-c")
    result.add(key & "=" & value)

proc ensureSharedBareSafety*(gitBin, barePath: string): bool =
  ## Idempotently install ``SharedBareSafetyConfig`` and the pool's
  ## integrity config (``poolIntegrityConfig``: the retention hook, the
  ## partial-clone keys of the refetch chain, and ``gc.pruneExpire``) into
  ## ``barePath``'s config. Like ``ensureSharedBareRefspec`` this is also the
  ## in-place migration for every bare already in a user's cache. Returns
  ## ``false`` when a key could not be written.
  ##
  ## ``gc.pruneExpire`` is written LAST, so a run that fails part-way never
  ## leaves a pool expiring objects without the hook that protects them.
  result = true
  for (key, value) in @SharedBareSafetyConfig & poolIntegrityConfig(gitBin,
      barePath):
    let current = runGit(gitBin, ["-C", barePath, "config", "--get", key])
    if current.code == 0 and current.output.strip() == value:
      continue
    if runGit(gitBin, ["-C", barePath, "config", "--replace-all", key,
        value]).code != 0:
      result = false

proc prepareSharedBare*(gitBin, barePath: string): string =
  ## Install everything an existing shared bare must carry before anything
  ## writes to it: the fetch refspec (``ensureSharedBareRefspec``) and the
  ## borrower-safety config (``ensureSharedBareSafety``). Returns "" on
  ## success, otherwise the diagnostic. Every refresh path calls this -- the
  ## ``refresh-bare`` engine action ``repro sync`` schedules as well as
  ## ``refreshSharedBare`` -- so no path can refresh an unprotected bare.
  if not ensureSharedBareSafety(gitBin, barePath):
    return "could not install the shared-bare safety config on " & barePath &
      " (automatic maintenance there could delete objects that checkouts in " &
      "other workspaces still borrow)"
  if not ensureSharedBareRefspec(gitBin, barePath):
    return "could not install the shared-bare fetch refspec (" &
      SharedBareFetchRefspec & ") on " & barePath &
      "; a fetch there would silently advance no refs"
  ""

proc sharedBareFetchArgs*(barePath: string): seq[string] =
  ## The argv (after the git binary) of the one refresh fetch every path runs
  ## against an existing shared bare.
  result = sharedBareSafetyArgs()
  result.add(["-C", barePath, "fetch", "--all", "--prune", "--quiet"])

proc refreshSharedBare*(gitBin, cacheRoot, fetchUrl: string): SharedCloneResult =
  ## Clone-if-missing / fetch-if-present the shared bare for ``fetchUrl``.
  ## Returns ``ok = true`` with the bare path populated, or ``ok = false``
  ## with a diagnostic on any failure (the caller then falls back to a
  ## standalone clone). This is the single shared-state write per unique
  ## URL; per RA-5c it is done once up front before per-repo clones fan
  ## out, so concurrent clones read a consistent pool without racing.
  let bare = sharedBarePath(cacheRoot, fetchUrl)
  if looksLikeGitDir(bare):
    # Migrate-then-fetch. Without the refspec the fetch below is a no-op
    # that reports success (see ``SharedBareFetchRefspec``), so installing
    # it is not an optimization -- it is what makes the refresh a refresh.
    # The safety config goes in FIRST: a ``--prune`` that finally advances
    # refs is exactly what makes a rewritten upstream's old history
    # unreachable here while borrowers still use it (``SharedBareSafetyConfig``).
    let prepared = prepareSharedBare(gitBin, bare)
    if prepared.len > 0:
      return SharedCloneResult(ok: false, sharedBarePath: bare,
        diagnostic: prepared)
    # fetch-if-present: refresh all refs, prune deleted ones.
    let res = runGit(gitBin, sharedBareFetchArgs(bare))
    if res.code != 0:
      return SharedCloneResult(ok: false, sharedBarePath: bare,
        diagnostic: "git fetch in shared bare failed (" & $res.code & "): " &
          res.output.strip())
    # A refresh is what makes a rewritten upstream's old commits unreachable
    # here, so it is also the moment to look at every leaf that borrows them
    # (Shared-Clone-Pool-Integrity §4.2).
    return SharedCloneResult(ok: true, sharedBarePath: bare,
      leafReports: checkRegisteredLeaves(gitBin, bare))

  # clone-if-missing: create the parent and a bare mirror clone.
  let parent = bare.splitPath.head
  if parent.len > 0:
    try:
      createDir(parent)
    except OSError as e:
      return SharedCloneResult(ok: false, sharedBarePath: bare,
        diagnostic: "could not create cache parent " & parent & ": " & e.msg)
  let res = runGit(gitBin,
    ["clone", "--bare", "--quiet", fetchUrl, bare])
  if res.code != 0:
    # Leave no half-populated bare behind so the next attempt re-clones
    # cleanly rather than mistaking a broken dir for a present cache.
    if dirExists(bare):
      try: removeDir(bare)
      except OSError: discard
    return SharedCloneResult(ok: false, sharedBarePath: bare,
      diagnostic: "git clone --bare into shared cache failed (" & $res.code &
        "): " & res.output.strip())
  # A freshly-cloned bare is current, but it is born WITHOUT a fetch
  # refspec, so its NEXT refresh would be the silent no-op described on
  # ``SharedBareFetchRefspec``. Install it at birth, so no bare in the cache
  # ever spends a single refresh cycle frozen.
  let prepared = prepareSharedBare(gitBin, bare)
  if prepared.len > 0:
    return SharedCloneResult(ok: false, sharedBarePath: bare,
      diagnostic: "cloned the shared bare but " & prepared)
  SharedCloneResult(ok: true, sharedBarePath: bare)

# ---- bootstrap manifest cache population (RA-11) ---------------------------

type
  ManifestCacheEntry* = object
    ## What ``inspectManifestCacheEntry`` found at one cache path.
    status*: ManifestCacheEntryStatus
    path*: string
    observedUrl*: string
      ## The ``origin`` URL the entry actually carries — populated for
      ## ``mceMatches`` and ``mceForeign``, "" otherwise.
    detail*: string
      ## Git's own message, populated for ``mceUnreadable``.

proc inspectManifestCacheEntry*(gitBin, entryPath, manifestUrl: string):
    ManifestCacheEntry =
  ## Ask a manifest-cache directory whether it is the checkout of
  ## ``manifestUrl``, and never guess.
  ##
  ## W8-R3. The predicate this replaces was ``looksLikeGitDir(entryPath)``,
  ## which answers "is there a git object store here" and was being read as
  ## "is this entry mine". Those are different questions and ``urlSlug`` is
  ## many-to-one, so the first URL to reach a slug owned it and every
  ## colliding URL afterwards was served the incumbent's tree — a
  ## wrong-content outcome at the point content becomes trust (the
  ## composer/resolver reads ``projects/*.toml`` straight out of this
  ## directory) that PERSISTS across every later bootstrap.
  ##
  ## WHAT IT COMPARES AGAINST, and why that and not a stamp file. The entry's
  ## own ``origin`` remote is the record ``git clone`` already keeps, so this
  ## works on the entries ALREADY ON DISK; a new stamp file would make every
  ## pre-existing entry unverifiable and force a mass re-clone. It is also no
  ## weaker: forging either one requires write access to the cache directory,
  ## and an attacker with that can write the content directly and skip the
  ## metadata entirely.
  ##
  ## ``config --local`` rather than plain ``config``, for two reasons. It
  ## makes "not a repository" (exit 128) DISTINGUISHABLE from "no origin
  ## configured" (exit 1, empty output) — plain ``config --get`` returns exit
  ## 1 for both because it happily searches global/system scope outside a
  ## repository (measured). And it confines the answer to the repository
  ## itself, so an ambient ``remote.origin.url`` in the user's global config
  ## can never supply an identity for a directory that does not have one.
  ##
  ## A directory that is not a git dir at all is ``mceAbsent``, NOT a
  ## failure. That is the pre-existing clone-and-recover path — the clone
  ## fails on a non-empty destination and the failure branch removes it —
  ## and ``t_a_hostile_fetch_url_deletes_a_real_directory_before_this_rule``
  ## asserts exactly that behaviour. Identity is only answerable of something
  ## that claims to be a repository, so only those are asked.
  result.path = entryPath
  if not looksLikeGitDir(entryPath):
    result.status = mceAbsent
    return
  let res = runGit(gitBin,
    ["-C", entryPath, "config", "--local", "--get", "remote.origin.url"])
  # ``runGit`` merges stderr into stdout, so a git advisory (``warning:`` /
  # ``hint:`` on a host with an odd global config) would otherwise be read AS
  # the URL and turn every entry foreign. Take the first line that is a value
  # rather than a diagnostic; git prints exactly one value line for
  # ``--get``.
  var observed = ""
  for line in res.output.splitLines:
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    if trimmed.startsWith("warning:") or trimmed.startsWith("hint:") or
        trimmed.startsWith("fatal:") or trimmed.startsWith("error:"):
      continue
    observed = trimmed
    break
  if res.code != 0:
    # Exit 1 with no value line is git's "key not present"; anything else is
    # a genuine read failure (not a repository, corrupt config, …).
    result.status = if res.code == 1 and observed.len == 0: mceNoOrigin
                    else: mceUnreadable
    result.detail = res.output.strip()
    return
  if observed.len == 0:
    result.status = mceNoOrigin
    return
  result.observedUrl = observed
  result.status =
    if canonicalRemoteIdentity(observed) == canonicalRemoteIdentity(manifestUrl):
      mceMatches
    else:
      mceForeign

proc refreshManifestCacheEntry(gitBin, target: string): SharedCloneResult =
  ## Fetch-if-present, then fast-forward the checked-out branch so the cached
  ## manifest reflects upstream. Best-effort: a fetch failure leaves the
  ## existing checkout usable — which is sound precisely BECAUSE the caller
  ## has already established the entry is the requested repository. Serving a
  ## stale tree from the right remote is a freshness question; serving a tree
  ## from the wrong remote is not.
  let fetched = runGit(gitBin, ["-C", target, "fetch", "--quiet",
    "--prune", "origin"])
  if fetched.code != 0:
    return SharedCloneResult(ok: true, sharedBarePath: target,
      manifestEntry: mceMatches,
      diagnostic: "manifest cache fetch failed (using existing checkout): " &
        fetched.output.strip())
  let curRes = runGit(gitBin,
    ["-C", target, "rev-parse", "--abbrev-ref", "HEAD"])
  let cur = if curRes.code == 0: curRes.output.strip() else: ""
  if cur.len > 0 and cur != "HEAD":
    discard runGit(gitBin, ["-C", target, "merge", "--ff-only", "--quiet",
      "refs/remotes/origin/" & cur])
  SharedCloneResult(ok: true, sharedBarePath: target,
    manifestEntry: mceMatches)

proc cloneManifestCacheEntry(gitBin, target, manifestUrl, branch: string):
    SharedCloneResult =
  ## Clone-if-missing into ``target``.
  let parent = target.splitPath.head
  if parent.len > 0:
    try:
      createDir(parent)
    except OSError as e:
      return SharedCloneResult(ok: false, sharedBarePath: target,
        manifestEntry: mceAbsent,
        diagnostic: "could not create manifest cache parent " & parent &
          ": " & e.msg)
  var cloneArgs = @["clone", "--quiet"]
  if branch.len > 0:
    cloneArgs.add(["--single-branch", "--branch", branch])
  cloneArgs.add([manifestUrl, target])
  let res = runGit(gitBin, cloneArgs)
  if res.code != 0:
    if dirExists(target):
      try: removeDir(target)
      except OSError: discard
    return SharedCloneResult(ok: false, sharedBarePath: target,
      manifestEntry: mceAbsent,
      diagnostic: "git clone of manifest repo into cache failed (" &
        $res.code & "): " & res.output.strip())
  SharedCloneResult(ok: true, sharedBarePath: target, manifestEntry: mceAbsent)

proc unverifiableManifestCacheRefusal(entry: ManifestCacheEntry;
                                      manifestUrl: string): SharedCloneResult =
  ## Refuse an entry whose identity could not be ESTABLISHED (as opposed to
  ## established and found foreign, which re-keys). Fail closed: the entry is
  ## neither served nor deleted, and the reason names which of the two
  ## unreadable states it was.
  ##
  ## Not deleting matters as much as not serving. The clone path's recovery
  ## step is a ``removeDir`` of the destination, so falling THROUGH to it —
  ## rather than returning here — would turn "I cannot verify this directory"
  ## into "I deleted this directory", the recovery-becomes-the-incident shape
  ## this cache has already produced once.
  let why =
    case entry.status
    of mceNoOrigin:
      "it is a git repository with NO `origin` remote, so there is nothing " &
        "to check the requested URL against"
    else:
      "its local git config could not be read" &
        (if entry.detail.len > 0: " (" & entry.detail & ")" else: "")
  SharedCloneResult(ok: false, sharedBarePath: entry.path,
    manifestEntry: entry.status,
    diagnostic: "refusing to use the manifest cache entry at '" & entry.path &
      "' for '" & manifestUrl & "': " & why & ". A cache entry that cannot " &
      "prove which repository it holds is not usable as one; remove the " &
      "directory to let it be re-cloned.")

proc ensureManifestCache*(gitBin, cacheRoot, manifestUrl: string;
                          branch = ""): SharedCloneResult =
  ## Clone-if-missing / fetch-and-fast-forward-if-present the manifest
  ## repo for ``manifestUrl`` into the bootstrap manifest cache. Returns
  ## ``ok = true`` with ``sharedBarePath`` set to the on-disk manifest
  ## checkout (a NORMAL working tree, not a bare — the composer/resolver
  ## reads ``projects/*.toml`` files from it), or ``ok = false`` with a
  ## diagnostic on any failure.
  ##
  ## Unlike ``refreshSharedBare`` (which manages a *bare* object pool),
  ## this materialises a checked-out manifest tree because the manifest
  ## reader walks real files. The clone uses ``--single-branch`` on the
  ## requested ``branch`` when one is given.
  ##
  ## W8-R3 — AN ENTRY IS USED ONLY IF IT PROVES IT IS THE REQUESTED ONE.
  ## Presence at ``manifestCachePath`` is not ownership: the slug is
  ## many-to-one, so this walks at most two candidate paths and asks each
  ## ``inspectManifestCacheEntry``:
  ##
  ##   primary ``manifestCachePath``
  ##     mceMatches   → fetch + fast-forward it (the ordinary cache hit)
  ##     mceAbsent    → clone into it (the ordinary cold cache)
  ##     mceForeign   → a slug collision; try the re-keyed path below
  ##     mceNoOrigin
  ##     mceUnreadable→ REFUSE, without deleting anything
  ##
  ##   ``disambiguatedManifestCachePath``
  ##     mceMatches   → fetch + fast-forward it
  ##     mceAbsent    → clone into it
  ##     anything else→ REFUSE
  ##
  ## The walk cannot recurse further, so a pathological third collision ends
  ## in a refusal rather than a search.
  let primary = manifestCachePath(cacheRoot, manifestUrl)
  let entry = inspectManifestCacheEntry(gitBin, primary, manifestUrl)
  case entry.status
  of mceMatches:
    return refreshManifestCacheEntry(gitBin, primary)
  of mceAbsent:
    return cloneManifestCacheEntry(gitBin, primary, manifestUrl, branch)
  of mceNoOrigin, mceUnreadable, mceUnknown:
    return unverifiableManifestCacheRefusal(entry, manifestUrl)
  of mceForeign:
    discard

  # The primary slug is owned by a DIFFERENT repository. Re-key onto the
  # identity-digest path and ask the same question there; the incumbent is
  # left untouched, because it is a legitimate cache entry for its own URL.
  let rekeyed = disambiguatedManifestCachePath(cacheRoot, manifestUrl)
  let alt = inspectManifestCacheEntry(gitBin, rekeyed, manifestUrl)
  case alt.status
  of mceMatches:
    refreshManifestCacheEntry(gitBin, rekeyed)
  of mceAbsent:
    cloneManifestCacheEntry(gitBin, rekeyed, manifestUrl, branch)
  of mceForeign:
    SharedCloneResult(ok: false, sharedBarePath: rekeyed,
      manifestEntry: mceForeign,
      diagnostic: "refusing to use the manifest cache for '" & manifestUrl &
        "': the slug path '" & primary & "' holds '" & entry.observedUrl &
        "' and the re-keyed path '" & rekeyed & "' holds '" &
        alt.observedUrl & "', so neither is this URL's entry.")
  else:
    unverifiableManifestCacheRefusal(alt, manifestUrl)

# ---- alternates wiring -----------------------------------------------------

proc gitObjectDir(repoPath: string): string =
  ## Return the object-store dir for ``repoPath`` whether it is a normal
  ## working tree (``<repo>/.git/objects``) or a bare repo
  ## (``<repo>/objects``).
  if dirExists(repoPath / ".git"):
    repoPath / ".git" / "objects"
  else:
    repoPath / "objects"

proc alternatesFilePath*(repoPath: string): string =
  ## Path of the alternates file for ``repoPath`` (normal or bare).
  gitObjectDir(repoPath) / "info" / "alternates"

proc readAlternates*(repoPath: string): seq[string] =
  ## Return the alternates currently wired for ``repoPath`` (empty if the
  ## file is absent). Blank lines are skipped.
  let p = alternatesFilePath(repoPath)
  if not fileExists(p):
    return @[]
  for line in readFile(p).splitLines:
    let trimmed = line.strip()
    if trimmed.len > 0:
      result.add(trimmed)

proc wireAlternates*(repoPath, sharedBarePath: string;
                     gitBin = "git"): SharedCloneResult =
  ## Idempotently wire ``repoPath`` to read objects from the shared bare's
  ## ``objects/`` dir via ``objects/info/alternates``. Safe to call on an
  ## already-wired repo (the entry is added only if absent). Best-effort:
  ## returns ``ok = false`` with a diagnostic on any IO failure so the
  ## caller can fall back.
  ##
  ## A borrower the pool does not know about is a borrower a gc there can
  ## break, so the repo is entered in the pool's borrower registry BEFORE
  ## the alternates entry is written, and is not wired at all when that
  ## fails (Shared-Clone-Pool-Integrity §3.2). It also gets the refetch
  ## chain and ``fetch.hideRefs`` (§3.4, §3.5); a failure there is reported
  ## but does not unwire it, because it costs recovery, not safety.
  let sharedObjects = sharedBarePath / "objects"
  if not dirExists(sharedObjects):
    return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
      diagnostic: "shared bare has no objects dir: " & sharedObjects)
  if not registerBorrower(sharedBarePath, repoPath):
    return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
      diagnostic: "could not register " & repoPath & " as a borrower in " &
        borrowersPath(sharedBarePath))
  let altPath = alternatesFilePath(repoPath)
  let infoDir = altPath.splitPath.head
  try:
    createDir(infoDir)
  except OSError as e:
    return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
      diagnostic: "could not create " & infoDir & ": " & e.msg)
  var entries = readAlternates(repoPath)
  if sharedObjects notin entries:
    entries.add(sharedObjects)
    try:
      writeFile(altPath, entries.join("\n") & "\n")
    except IOError as e:
      return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
        diagnostic: "could not write alternates " & altPath & ": " & e.msg)
  let configured = ensureLeafPoolConfig(gitBin, repoPath, sharedBarePath)
  SharedCloneResult(ok: true, sharedBarePath: sharedBarePath,
    diagnostic: configured)

proc samePathOnDisk*(a, b: string): bool =
  ## Path equality for two spellings of what may be ONE location.
  ##
  ## The alternates file has two authors with two conventions, and they
  ## must still compare equal: ``wireAlternates`` writes Nim's ``/`` join,
  ## which on Windows emits a backslash; ``git clone --reference`` writes
  ## git's own spelling, which is a forward slash on every platform. An
  ## exact string compare therefore answers "not wired" for every repo git
  ## itself wired -- measured on this workspace, 162 of 162 repos reported
  ## ``wired=false`` while their alternates files named exactly the right
  ## shared bare.
  ##
  ## So normalise before comparing: unify separators, collapse ``.``/``..``,
  ## drop a trailing separator, and fold case on the platforms whose
  ## filesystems do. This compares two path STRINGS; it is deliberately not
  ## a containment or filesystem-identity question (no stat, no symlink
  ## resolution), so it stays correct for a path that does not exist yet.
  proc canon(value: string): string =
    if value.len == 0:
      return ""
    result = value
    if DirSep != '/':
      result = result.replace('/', DirSep)
    if AltSep != DirSep:
      result = result.replace(AltSep, DirSep)
    try:
      result = normalizedPath(result)
    except CatchableError:
      discard
    while result.len > 1 and result[^1] == DirSep:
      result.setLen(result.len - 1)
    when defined(windows) or defined(macosx):
      result = result.toLowerAscii()
  canon(a) == canon(b)

proc isWiredTo*(repoPath, sharedBarePath: string): bool =
  ## True when ``repoPath`` already reads the shared bare via alternates.
  ## Compares NORMALISED paths (``samePathOnDisk``) rather than raw
  ## strings: the entry may have been written by git (forward slashes) or
  ## by ``wireAlternates`` (the platform separator), and both name the very
  ## same object pool.
  let wanted = sharedBarePath / "objects"
  for entry in readAlternates(repoPath):
    if samePathOnDisk(entry, wanted):
      return true
  false

# ---- pool integrity: borrowed objects, recovery and messages ---------------
#
# ``reprobuild-specs/spec/Shared-Clone-Pool-Integrity.md``. A shared bare (the
# POOL) is borrowed by any number of checkouts (LEAVES) through
# ``objects/info/alternates``, and git's gc in the pool sees only the pool's
# own refs. Everything below exists so that a gc in the pool keeps what the
# leaves still name, so a leaf can fetch back what upstream still serves, and
# so a leaf that does lose something says what happened in words that point
# at the cause:
#
#   * the BORROWER REGISTRY (``<pool>/repro/borrowers``, §3.2) lists every leaf;
#   * the RETENTION HOOK (``<pool>/repro/retain-borrowed.sh``, §3.3) is the
#     pool's ``gc.recentObjectsHook`` and prints what the registered leaves
#     name, so gc keeps it;
#   * the REFETCH CHAIN (§3.4) makes each leaf a partial clone of its pool and
#     the pool a partial clone of upstream, so a missing object is fetched on
#     demand through both;
#   * ``fetch.hideRefs=refs/remotes/`` in each leaf (§3.5) keeps a plain
#     ``git fetch`` working over a dangling remote-tracking ref;
#   * the DETECTOR (``checkLeaf``, §4) finds what is still missing, removes
#     stale copies of upstream, and explains everything else without
#     touching it.

const
  PoolReproDirName* = "repro"
    ## Directory inside a pool (and inside a leaf's git dir) that holds the
    ## files reprobuild owns there.
  BorrowersFileName* = "borrowers"
    ## ``<pool>/repro/borrowers``: one absolute leaf path per line.
  RetentionHookFileName* = "retain-borrowed.sh"
    ## ``<pool>/repro/retain-borrowed.sh``: the pool's ``gc.recentObjectsHook``.
  OldGitReportedFileName* = "old-git-reported"
    ## Marker so the below-2.42 condition is reported once per pool (§3.6).
  DroppedRefsLogFileName* = "dropped-refs.log"
    ## ``<leaf git dir>/repro/dropped-refs.log``: one line per removed ref.
  PoolPruneExpire* = "2.weeks.ago"
    ## ``gc.pruneExpire`` of a pool whose retention hook can protect its
    ## registered leaves (§3.1). Git's own default.
  PoolNeverExpire* = "never"
    ## ``gc.pruneExpire`` of every other pool: an old git, an empty registry,
    ## or a hook that could not be written (§3.6, §5).
  RetentionHookMinGit* = (major: 2, minor: 42)
    ## First git release that runs ``gc.recentObjectsHook``.
  LeafPoolRemoteName* = "repro-pool"
    ## The remote every leaf carries for its pool (§3.4).
  LeafPoolUploadPack* = "env GIT_NO_LAZY_FETCH=0 git-upload-pack"
    ## ``remote.repro-pool.uploadpack``. ``upload-pack`` refuses to lazily
    ## fetch on behalf of a client by default (it exports
    ## ``GIT_NO_LAZY_FETCH=1``, because a lazy fetch runs the SERVED
    ## repository's configuration). This opts this one remote in, so a
    ## leaf's request for an object the pool lacks is passed on to upstream.
    ## It is a deliberate widening of trust: the pool's configuration now
    ## runs inside the leaf's git commands. The pool is the user's own cache,
    ## written only by reprobuild.
  LeafHiddenFetchRefs* = "refs/remotes/"
    ## ``fetch.hideRefs`` in every leaf (§3.5).

proc poolReproDir*(pool: string): string = pool / PoolReproDirName
proc borrowersPath*(pool: string): string =
  poolReproDir(pool) / BorrowersFileName
proc retentionHookPath*(pool: string): string =
  poolReproDir(pool) / RetentionHookFileName

proc runGitEnv(gitBin: string; args: openArray[string];
               lazyFetch: bool; input = "";
               workingDir = ""): tuple[code: int; output: string] =
  ## ``runGit`` with lazy fetching pinned on or off, and optional stdin.
  ## Lazy fetching is decided explicitly in BOTH directions so an ambient
  ## ``GIT_NO_LAZY_FETCH`` cannot decide whether a probe touches the network:
  ## a presence probe that lazily fetches would heal what it is measuring and
  ## report nothing, and a refill that cannot fetch would report a loss that
  ## upstream could still have repaired.
  var cmd = quoteShell(gitBin)
  for arg in args:
    cmd.add(" ")
    cmd.add(quoteShell(arg))
  let env = scrubbedGitRepositoryEnv()
  # Lazy fetching ON is the variable ABSENT, exactly as a user's shell has
  # it, not ``=0``: upload-pack only sets ``GIT_NO_LAZY_FETCH=1`` when it is
  # unset, so an inherited ``0`` would let the pool fetch on our behalf even
  # without ``remote.repro-pool.uploadpack``, and the refill would not be
  # exercising the path a user's own git takes.
  if lazyFetch:
    env.del("GIT_NO_LAZY_FETCH")
  else:
    env["GIT_NO_LAZY_FETCH"] = "1"
  let res = execCmdEx(cmd, workingDir = workingDir, env = env, input = input)
  (code: res.exitCode, output: res.output)

proc isObjectId(text: string): bool =
  (text.len == 40 or text.len == 64) and
    text.allCharsInSet({'0'..'9', 'a'..'f'})

proc isNullObjectId(text: string): bool =
  text.len > 0 and text.allCharsInSet({'0'})

# -- git version (§3.6) ------------------------------------------------------

proc parseGitVersion*(banner: string): tuple[ok: bool; major, minor: int] =
  ## Parse ``git version 2.54.0`` (and vendor spellings such as
  ## ``git version 2.42.0.windows.1`` or ``git version 2.39.3 (Apple
  ## Git-146)``) into its major and minor numbers.
  for raw in banner.splitLines():
    let line = raw.strip()
    const prefix = "git version "
    if not line.startsWith(prefix):
      continue
    let parts = line[prefix.len .. ^1].split({'.', ' '})
    if parts.len < 2:
      return (ok: false, major: 0, minor: 0)
    try:
      return (ok: true, major: parseInt(parts[0]), minor: parseInt(parts[1]))
    except ValueError:
      return (ok: false, major: 0, minor: 0)
  (ok: false, major: 0, minor: 0)

proc gitSupportsRetentionHook*(gitBin: string): bool =
  ## Whether ``gitBin`` honours ``gc.recentObjectsHook`` (git >= 2.42). An
  ## unparseable answer is "no": the cost of a wrong "no" is disk (the pool
  ## keeps everything), the cost of a wrong "yes" is a pool that expires
  ## objects its leaves still use.
  let res = runGit(gitBin, ["version"])
  if res.code != 0:
    return false
  let v = parseGitVersion(res.output)
  v.ok and (v.major > RetentionHookMinGit.major or
    (v.major == RetentionHookMinGit.major and
     v.minor >= RetentionHookMinGit.minor))

# -- borrower registry (§3.2) -------------------------------------------------

proc canonicalLeafPath(leaf: string): string =
  result = absolutePath(leaf)
  try:
    result = normalizedPath(result)
  except CatchableError:
    discard
  while result.len > 1 and result[^1] in {DirSep, AltSep}:
    result.setLen(result.len - 1)

proc readBorrowers*(pool: string): seq[string] =
  ## The leaves registered with ``pool``, deduplicated, in file order.
  let path = borrowersPath(pool)
  if not fileExists(path):
    return @[]
  var text = ""
  try:
    text = readFile(path)
  except IOError, OSError:
    return @[]
  for line in text.splitLines():
    let entry = line.strip()
    if entry.len == 0:
      continue
    var seen = false
    for existing in result:
      if samePathOnDisk(existing, entry):
        seen = true
        break
    if not seen:
      result.add(entry)

proc registerBorrower*(pool, leaf: string): bool =
  ## Add ``leaf`` to ``pool``'s registry unless it is already there. The
  ## write is a single short append, so two workspaces registering at once
  ## both land (``readBorrowers`` folds a duplicate); nothing here rewrites
  ## the file, so a registration can never erase another.
  let entry = canonicalLeafPath(leaf)
  for existing in readBorrowers(pool):
    if samePathOnDisk(existing, entry):
      return true
  try:
    createDir(poolReproDir(pool))
    let f = open(borrowersPath(pool), fmAppend)
    defer: f.close()
    f.write(entry & "\n")
    true
  except IOError, OSError:
    false

proc pruneBorrowers*(pool: string): seq[string] =
  ## Remove every registry entry whose path no longer exists or no longer
  ## borrows from ``pool``, and return the removed entries. Those are the
  ## only two reasons an entry ever leaves (§3.2): a leaf that exists and
  ## still borrows stays registered no matter what else is wrong with it.
  let entries = readBorrowers(pool)
  var keep: seq[string]
  for entry in entries:
    if dirExists(entry) and isWiredTo(entry, pool):
      keep.add(entry)
    else:
      result.add(entry)
  if result.len == 0:
    return
  let path = borrowersPath(pool)
  let tmp = path & ".tmp-" & $getCurrentProcessId()
  try:
    writeFile(tmp, (if keep.len > 0: keep.join("\n") & "\n" else: ""))
    moveFile(tmp, path)
  except IOError, OSError:
    try: removeFile(tmp)
    except OSError: discard
    result.setLen(0)

# -- retention hook (§3.3) ----------------------------------------------------

const RetentionHookScript* = """#!/bin/sh
# retain-borrowed.sh -- written by reprobuild, and rewritten whenever this
# shared clone is refreshed, so local edits do not survive.
#
# `git gc` runs this as gc.recentObjectsHook. Every object id printed here is
# kept, together with everything it reaches in this pool, as if it were
# recent. It prints what each checkout listed in repro/borrowers still names
# -- its refs, its HEADs and its reflog entries -- and, for any of those this
# pool does not hold itself (a commit made in the checkout), the history
# behind it, so the parents of a checkout's own commits are kept too. If this
# script fails, git skips pruning: a failure keeps objects, it never deletes
# them.

# gc exports this pool's GIT_DIR (and friends) to the hook, and they override
# `git -C <checkout>`. Clear them before reading any checkout.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_NAMESPACE \
  GIT_PREFIX GIT_IMPLICIT_WORK_TREE GIT_SHALLOW_FILE GIT_GRAFT_FILE \
  GIT_REPLACE_REF_BASE GIT_NO_REPLACE_OBJECTS GIT_INTERNAL_SUPER_PREFIX
# Checkouts are partial clones of this pool: reading one must never fetch.
GIT_NO_LAZY_FETCH=1
export GIT_NO_LAZY_FETCH

pool=$(cd "$(dirname "$0")/.." && pwd) || exit 1
registry="$pool/repro/borrowers"
# Expiry is only switched on once the registry names a checkout, so a missing
# registry here means something removed it. Refuse: git then prunes nothing.
[ -f "$registry" ] || exit 1
work="$pool/repro/retain.$$"
rm -rf "$work" && mkdir "$work" || exit 1
trap 'rm -rf "$work"' EXIT
git --git-dir="$pool" for-each-ref --format='^%(objectname)' > "$work/pooltips" || exit 1

status=0
while IFS= read -r leaf || [ -n "$leaf" ]; do
  [ -n "$leaf" ] || continue
  [ -d "$leaf" ] || continue
  # A path that is no longer a repository borrows nothing. A repository git
  # cannot open (ownership checks, a broken config) still borrows: refuse
  # rather than let its objects expire.
  [ -e "$leaf/.git" ] || continue
  common=$(git -C "$leaf" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { status=1; continue; }
  : > "$work/names"
  # Refs, read from the ref store: this format never opens the objects.
  git -C "$leaf" for-each-ref --format='%(objectname)' >> "$work/names" || { status=1; continue; }
  # Detached HEADs, of the checkout and of each linked worktree.
  for head in "$common/HEAD" "$common"/worktrees/*/HEAD; do
    [ -f "$head" ] || continue
    line=
    IFS= read -r line < "$head" || true
    case $line in ref:*) ;; *) printf '%s\n' "$line" >> "$work/names" ;; esac
  done
  # Reflogs, read from the files: `git reflog` walks commits and stops at a
  # missing one.
  for logs in "$common/logs" "$common"/worktrees/*/logs; do
    [ -d "$logs" ] || continue
    find "$logs" -type f -exec cat {} + | cut -d' ' -f1,2 | tr ' ' '\n' >> "$work/names"
  done
  grep -E '^[0-9a-f]{40}([0-9a-f]{24})?$' "$work/names" | grep -v -E '^0+$' | sort -u > "$work/ids"
  cat "$work/ids"
  # Ids this pool does not hold were made in the checkout. Print the history
  # behind them, up to what this pool's own refs already keep.
  git --git-dir="$pool" cat-file --batch-check='%(objectname)' < "$work/ids" > "$work/check" || { status=1; continue; }
  sed -n 's/ missing$//p' "$work/check" > "$work/foreign"
  if [ -s "$work/foreign" ]; then
    cat "$work/foreign" "$work/pooltips" |
      git -C "$leaf" rev-list --objects --no-object-names --missing=allow-any --ignore-missing --stdin || status=1
  fi
done < "$registry"
exit $status
"""
  ## The script ``ensureRetentionHook`` writes. POSIX ``sh`` plus ``git``
  ## and the coreutils every git installation ships with.

proc ensureRetentionHook*(pool: string): bool =
  ## Write (or rewrite) the retention hook into ``pool``. Returns ``false``
  ## when it could not be written, in which case the pool keeps
  ## ``gc.pruneExpire=never``.
  let path = retentionHookPath(pool)
  try:
    createDir(poolReproDir(pool))
    if not fileExists(path) or readFile(path) != RetentionHookScript:
      let tmp = path & ".tmp-" & $getCurrentProcessId()
      writeFile(tmp, RetentionHookScript)
      moveFile(tmp, path)
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
    true
  except IOError, OSError:
    false

proc retentionHookConfigValue*(pool: string): string =
  ## The ``gc.recentObjectsHook`` value: the script's path, quoted for the
  ## shell git runs it through. Forward slashes on every platform, because
  ## that shell is ``sh`` even on Windows.
  quoteShellPosix(retentionHookPath(pool).replace('\\', '/'))

proc poolRetentionReady*(gitBin, pool: string): bool =
  ## True when expiring unreachable objects in ``pool`` is safe for its
  ## registered leaves: git runs the hook, the hook is in place, and the
  ## registry names at least one leaf. Anything else keeps ``never`` (§3.6,
  ## §5): a pool must never expire objects on the strength of an empty
  ## registry or a hook git will not run.
  gitSupportsRetentionHook(gitBin) and
    fileExists(retentionHookPath(pool)) and readBorrowers(pool).len > 0

proc poolIntegrityConfig*(gitBin, pool: string): seq[(string, string)] =
  ## The pool-specific rows of §3.1, beyond the static
  ## ``SharedBareSafetyConfig``. ``gc.pruneExpire`` is computed: see
  ## ``poolRetentionReady``.
  let hookWritten = ensureRetentionHook(pool)
  result = @[
    ("core.repositoryFormatVersion", "1"),
    ("extensions.partialClone", "origin"),
    ("remote.origin.promisor", "true")]
  if hookWritten:
    result.add(("gc.recentObjectsHook", retentionHookConfigValue(pool)))
  result.add(("gc.pruneExpire",
    if hookWritten and poolRetentionReady(gitBin, pool): PoolPruneExpire
    else: PoolNeverExpire))

# -- the leaf: refetch chain and fetch.hideRefs (§3.4, §3.5) -------------------

proc poolFileUrl*(pool: string): string =
  ## ``file://`` URL of ``pool``. A ``file://`` URL rather than a plain path:
  ## for a plain path git would hardlink instead of fetch, and the partial
  ## clone machinery needs a transport.
  var p = absolutePath(pool).replace('\\', '/')
  if not p.startsWith("/"):
    p = "/" & p          # file:///C:/...
  "file://" & p

proc gitDirOf(gitBin, leaf: string): tuple[gitDir, commonDir: string] =
  ## Absolute git dir and common dir of ``leaf``. ``--path-format`` needs
  ## git 2.31; an older git answers relative to ``leaf``.
  var res = runGit(gitBin, ["-C", leaf, "rev-parse", "--path-format=absolute",
    "--git-dir", "--git-common-dir"])
  if res.code != 0:
    res = runGit(gitBin, ["-C", leaf, "rev-parse", "--git-dir",
      "--git-common-dir"])
    if res.code != 0:
      return ("", "")
  var lines: seq[string]
  for line in res.output.splitLines():
    let t = line.strip()
    if t.len > 0 and not t.startsWith("warning:"):
      lines.add(if t.isAbsolute: t else: absolutePath(t, absolutePath(leaf)))
  if lines.len < 2:
    return ("", "")
  (lines[0], lines[1])

proc ensureLeafPoolConfig*(gitBin, leaf, pool: string): string =
  ## Install §3.4 and §3.5 into ``leaf``'s config. Returns "" on success,
  ## otherwise the diagnostic. Idempotent.
  ##
  ## DEVIATION FROM §3.4, measured 2026-10-02: the leaf does NOT get
  ## ``extensions.partialClone`` or ``core.repositoryFormatVersion=1``. Nix's
  ## ``builtins.fetchGit`` opens a working-tree checkout with libgit2, and
  ## libgit2 refuses to open a repository carrying that extension
  ## ("unsupported extension name extensions.partialclone", libgit2 error
  ## 6) — measured with Nix 2.32.8, 2.34.7 and Determinate Nix 2.34.8. Every
  ## ``git+file://`` sibling override in a workspace dev shell reads a leaf
  ## that way, so the extension would break SPI-GOAL-6 and every dev shell
  ## with it. ``remote.repro-pool.promisor=true`` on its own is enough for
  ## git 2.54 to fetch a missing object on demand through the pool (the read
  ## healed leaf and pool), and leaves the repository format alone.
  let rows = [
    ("remote." & LeafPoolRemoteName & ".url", poolFileUrl(pool)),
    ("remote." & LeafPoolRemoteName & ".promisor", "true"),
    ("remote." & LeafPoolRemoteName & ".uploadpack", LeafPoolUploadPack),
    ("remote." & LeafPoolRemoteName & ".skipFetchAll", "true")]
  var failedKeys: seq[string]
  for (key, value) in rows:
    let current = runGit(gitBin, ["-C", leaf, "config", "--local", "--get", key])
    if current.code == 0 and current.output.strip() == value:
      continue
    if runGit(gitBin, ["-C", leaf, "config", "--local", "--replace-all", key,
        value]).code != 0:
      failedKeys.add(key)
  # The pool remote is never fetched by refspec (§3.4): it exists only to
  # serve missing objects.
  let fetchKey = "remote." & LeafPoolRemoteName & ".fetch"
  if runGit(gitBin, ["-C", leaf, "config", "--local", "--get-all",
      fetchKey]).code == 0:
    discard runGit(gitBin, ["-C", leaf, "config", "--local", "--unset-all",
      fetchKey])
  var hidden = false
  let hide = runGit(gitBin, ["-C", leaf, "config", "--local", "--get-all",
    "fetch.hideRefs"])
  if hide.code == 0:
    for line in hide.output.splitLines():
      if line.strip() == LeafHiddenFetchRefs:
        hidden = true
  if not hidden and runGit(gitBin, ["-C", leaf, "config", "--local", "--add",
      "fetch.hideRefs", LeafHiddenFetchRefs]).code != 0:
    failedKeys.add("fetch.hideRefs")
  # Undo the one write the deviation above retracts, wherever an earlier
  # build made it, so such a leaf is readable by Nix again.
  let ext = runGit(gitBin, ["-C", leaf, "config", "--local", "--get",
    "extensions.partialClone"])
  if ext.code == 0 and ext.output.strip() == LeafPoolRemoteName:
    discard runGit(gitBin, ["-C", leaf, "config", "--local", "--unset",
      "extensions.partialClone"])
  if failedKeys.len > 0:
    return "could not write " & failedKeys.join(", ") & " in " & leaf
  ""

proc poolsOfLeaf*(leaf: string; cacheRoot = ""): seq[string] =
  ## The pools ``leaf`` borrows from: every alternates entry whose parent is
  ## a bare repository, restricted to ``cacheRoot`` when one is given (the
  ## detector only ever writes into pools reprobuild owns).
  for entry in readAlternates(leaf):
    var objects = entry
    if not objects.isAbsolute:
      objects = alternatesFilePath(leaf).parentDir.parentDir / objects
    let pool = objects.parentDir
    if not (dirExists(pool / "objects") and fileExists(pool / "HEAD")) or
        dirExists(pool / ".git"):
      continue
    if cacheRoot.len > 0:
      let root = canonicalLeafPath(cacheRoot)
      let canon = canonicalLeafPath(pool)
      if not (canon == root or canon.startsWith(root & DirSep) or
          canon.replace('\\', '/').startsWith(root.replace('\\', '/') & "/")):
        continue
    result.add(pool)

# -- detector (§4) ------------------------------------------------------------

proc hasMessages*(report: LeafCheckReport): bool =
  for f in report.findings:
    if f.message.len > 0:
      return true
  false

proc messages*(reports: openArray[LeafCheckReport]): seq[string] =
  for r in reports:
    for f in r.findings:
      if f.message.len > 0:
        result.add(f.message)

proc displayPath*(path: string): string =
  ## A path as the user should read it in a message and paste it into a
  ## command: relative to the current directory when it is inside it, else
  ## absolute; shell-quoted when it needs to be.
  var shown = path
  try:
    let cwd = getCurrentDir()
    let rel = relativePath(path, cwd)
    if rel.len > 0 and not rel.startsWith("..") and not rel.isAbsolute:
      shown = rel
  except CatchableError:
    discard
  quoteShell(shown)

proc displayPoolPath(pool: string): string =
  ## The pool path for prose (never pasted): ``~`` for the home directory.
  let home = getHomeDir()
  var h = home
  while h.len > 1 and h[^1] in {DirSep, AltSep}:
    h.setLen(h.len - 1)
  if h.len > 1 and pool.startsWith(h & DirSep):
    "~" & pool[h.len .. ^1]
  else:
    pool

proc abbrev(id: string): string =
  if id.len > 7: id[0 ..< 7] else: id

proc batchPresence(gitBin, leaf: string; ids: seq[string]): seq[string] =
  ## The subset of ``ids`` missing from ``leaf`` (own store plus alternates),
  ## probed with lazy fetching OFF. Batched so neither pipe can fill while
  ## the other is still being written.
  const BatchLines = when defined(windows): 48 else: 900
  var i = 0
  while i < ids.len:
    let chunk = ids[i ..< min(ids.len, i + BatchLines)]
    let res = runGitEnv(gitBin, ["-C", leaf, "cat-file",
      "--batch-check=%(objectname)"], lazyFetch = false,
      input = chunk.join("\n") & "\n")
    for line in res.output.splitLines():
      let t = line.strip()
      if t.endsWith(" missing"):
        let id = t[0 ..< t.len - len(" missing")]
        if isObjectId(id):
          result.add(id)
    i += BatchLines

proc objectPresent(gitBin, leaf, id: string): bool =
  runGitEnv(gitBin, ["-C", leaf, "cat-file", "-e", id],
    lazyFetch = false).code == 0

proc refill(gitBin, leaf, id: string): bool =
  ## §4.1 step 1: read ``id`` once WITH lazy fetching, which goes leaf →
  ## pool → upstream (§3.4), then report whether it is now present.
  discard runGitEnv(gitBin, ["-C", leaf, "cat-file", "-t", id],
    lazyFetch = true)
  objectPresent(gitBin, leaf, id)

type LeafTarget = object
  refName: string
  id: string

proc listLeafTargets(gitBin, leaf, commonDir: string): seq[LeafTarget] =
  ## Every ref (from the ref store, never the objects), plus the detached
  ## HEADs of the checkout and its linked worktrees. A HEAD that is a
  ## symbolic ref is covered by the branch it names; ``refs/stash`` is a
  ## ref like any other.
  let res = runGit(gitBin, ["-C", leaf, "for-each-ref",
    "--format=%(objectname) %(refname) %(symref)"])
  if res.code == 0:
    for line in res.output.splitLines():
      let parts = line.strip().split(' ')
      if parts.len < 2 or not isObjectId(parts[0]):
        continue
      if parts.len >= 3 and parts[2].len > 0:
        continue                       # a symbolic ref (origin/HEAD)
      result.add(LeafTarget(refName: parts[1], id: parts[0]))
  proc headOf(path: string): string =
    try:
      readFile(path).strip()
    except IOError, OSError:
      ""
  let mainHead = headOf(commonDir / "HEAD")
  if isObjectId(mainHead):
    result.add(LeafTarget(refName: "HEAD", id: mainHead))
  if dirExists(commonDir / "worktrees"):
    for kind, wt in walkDir(commonDir / "worktrees"):
      if kind != pcDir:
        continue
      let h = headOf(wt / "HEAD")
      if isObjectId(h):
        var where = wt.lastPathPart
        let gitdirFile = headOf(wt / "gitdir")
        if gitdirFile.len > 0:
          where = gitdirFile.parentDir
        result.add(LeafTarget(refName: "worktree:" & where, id: h))

proc describeRef(refName: string): string =
  if refName.startsWith("refs/heads/"):
    "your branch '" & refName["refs/heads/".len .. ^1] & "'"
  elif refName.startsWith("refs/tags/"):
    "your tag '" & refName["refs/tags/".len .. ^1] & "'"
  elif refName == "refs/stash":
    "your latest stash (refs/stash)"
  elif refName == "HEAD":
    "your detached HEAD"
  elif refName.startsWith("worktree:"):
    "the detached HEAD of worktree " & displayPath(refName["worktree:".len .. ^1])
  else:
    "your ref '" & refName & "'"

proc upstreamTipInPool(gitBin, leaf, pool, refName: string):
    tuple[branch, id: string] =
  ## For a local branch: the branch it tracks (``branch.<b>.merge``, else
  ## the same name) and that branch's CURRENT tip in the pool. The pool was
  ## just refreshed and the leaf borrows from it, so that commit is readable
  ## in the leaf without any fetch.
  if not refName.startsWith("refs/heads/"):
    return ("", "")
  let local = refName["refs/heads/".len .. ^1]
  var upstream = local
  let merge = runGit(gitBin, ["-C", leaf, "config", "--get",
    "branch." & local & ".merge"])
  if merge.code == 0:
    let m = merge.output.strip()
    if m.startsWith("refs/heads/"):
      upstream = m["refs/heads/".len .. ^1]
  let tip = runGit(gitBin, ["--git-dir=" & pool, "rev-parse", "--verify",
    "-q", "refs/heads/" & upstream])
  if tip.code == 0 and isObjectId(tip.output.strip()):
    (upstream, tip.output.strip())
  else:
    (upstream, "")

proc messageStaleRemoteRef(leaf, pool, refName, id, logPath: string;
                           removed: bool): string =
  ## Message A (§4.4, SPI-AREQ-3).
  let l = displayPath(leaf)
  let cache = "the shared cache (" & displayPoolPath(pool) & ")"
  if removed:
    "repro: " & l & ": removed " & refName & " (" & abbrev(id) & ")\n" &
    "  Upstream rewrote or deleted that branch, and the old commit no longer exists\n" &
    "  upstream or in " & cache & ". The ref was only a copy of upstream; none of\n" &
    "  your branches depend on it. The next fetch recreates it if the branch still exists.\n" &
    "  Logged in " & displayPath(logPath)
  else:
    "repro: " & l & ": " & refName & " (" & abbrev(id) & ") is a stale copy of upstream\n" &
    "  Upstream rewrote or deleted that branch, and the old commit no longer exists\n" &
    "  upstream or in " & cache & ". The ref is only a copy of upstream; none of\n" &
    "  your branches depend on it. Remove it with:\n" &
    "      git -C " & l & " update-ref -d " & refName & " " & id

proc messageLocalTipMissing(gitBin, leaf, pool, refName, id: string): string =
  ## Message B (§4.4, SPI-AREQ-1/4) for a local ref whose own commit is gone.
  let l = displayPath(leaf)
  let (upstream, newTip) = upstreamTipInPool(gitBin, leaf, pool, refName)
  result = "repro: " & l & ": " & describeRef(refName) & " points at " &
    abbrev(id) & ", which no longer\n" &
    "exists here, in the shared cache (" & displayPoolPath(pool) & "), or upstream.\n" &
    "  Why:  upstream rewrote its history and the old commits were removed everywhere this\n" &
    "        machine can reach. Commits that existed only on this ref and were never\n" &
    "        pushed are gone from this checkout too.\n" &
    "  Fix:  - if another machine or checkout still has " & abbrev(id) & ", fetch it from there:\n" &
    "            git -C " & l & " fetch <that-checkout> " & id & "\n"
  if refName.startsWith("refs/heads/"):
    let target = if newTip.len > 0: newTip else: "<new-base>"
    result.add("        - otherwise point it at the rewritten history (your working tree and\n" &
      "          index are left as they are):\n" &
      "            git -C " & l & " update-ref " & refName & " " & target & "\n")
    # The checked-out branch: its index still describes the old tree, so
    # git would call every difference an uncommitted change (and refuse a
    # rebase). A mixed reset re-reads the index from the new tip and leaves
    # every file in the working tree as it is.
    let head = runGit(gitBin, ["-C", leaf, "symbolic-ref", "-q", "HEAD"])
    if head.code == 0 and head.output.strip() == refName:
      result.add("          then, because it is checked out, re-read the index from it\n" &
        "          (files in the working tree are not touched):\n" &
        "            git -C " & l & " reset -q\n")
    if newTip.len > 0:
      result.add("          (" & abbrev(newTip) & " is upstream's current '" & upstream &
        "', already in the shared cache)\n")
    else:
      result.add("          (<new-base> is the rewritten counterpart of " & abbrev(id) &
        ", usually origin/<branch>)\n")
  elif refName == "HEAD" or refName.startsWith("worktree:"):
    let where =
      if refName == "HEAD": l
      else: displayPath(refName["worktree:".len .. ^1])
    result.add("        - otherwise move HEAD onto the rewritten history (your working tree and\n" &
      "          index are left as they are):\n" &
      "            git -C " & where & " update-ref --no-deref HEAD <new-base>\n" &
      "          (<new-base> is the rewritten counterpart of " & abbrev(id) &
        ", usually origin/<branch>)\n")
  else:
    result.add("        - otherwise remove it:\n" &
      "            git -C " & l & " update-ref -d " & refName & " " & id & "\n")
  result.add("  Nothing was changed.")

proc messageLocalHistoryMissing(leaf, pool, refName, missing,
                                child: string; contentLost: bool): string =
  ## Message B (§4.4) for a branch whose own commits are intact but whose
  ## parents are gone. The spec's ``rebase --onto <new-base> <missing>``
  ## cannot run while the commit it names is missing (git: "invalid
  ## upstream"), so the recovery grafts the oldest own commit onto the new
  ## base first, which needs only commits that exist.
  let l = displayPath(leaf)
  let branch =
    if refName.startsWith("refs/heads/"): refName["refs/heads/".len .. ^1]
    else: refName
  if contentLost:
    # The own commits exist, but files in them existed only in the old
    # history: nothing can replay them until the old commit is back.
    return "repro: " & l & ": " & describeRef(refName) & " is built on " &
        abbrev(missing) & ", which no\n" &
      "longer exists here, in the shared cache (" & displayPoolPath(pool) &
        "), or upstream.\n" &
      "  Why:  upstream rewrote its history and the old commits were removed everywhere this\n" &
      "        machine can reach. Your own commits on '" & branch & "' are still here, but some of\n" &
      "        the files in them existed only in that old history and are gone as well, so\n" &
      "        they cannot be replayed onto the rewritten history from this machine alone.\n" &
      "  Fix:  - fetch " & abbrev(missing) & " from another machine or checkout that still has it:\n" &
      "            git -C " & l & " fetch <that-checkout> " & missing & "\n" &
      "          and then move your commits onto the rewritten history:\n" &
      "            git -C " & l & " rebase --onto <new-base> " & missing & " " & branch & "\n" &
      "          (<new-base> is the rewritten counterpart of " & abbrev(missing) &
        ", usually origin/<branch>)\n" &
      "  Nothing was changed."
  "repro: " & l & ": " & describeRef(refName) & " is built on " & abbrev(missing) &
    ", which no\n" &
  "longer exists here, in the shared cache (" & displayPoolPath(pool) & "), or upstream.\n" &
  "  Why:  upstream rewrote its history and the old commits were removed everywhere this\n" &
  "        machine can reach. Your own commits on '" & branch & "' are intact; their parents are gone.\n" &
  "  Fix:  - if another machine or checkout still has " & abbrev(missing) & ", fetch it from there:\n" &
  "            git -C " & l & " fetch <that-checkout> " & missing & "\n" &
  "        - otherwise move your commits onto the rewritten history:\n" &
  "            git -C " & l & " replace --graft " & child & " <new-base>\n" &
  "            git -C " & l & " rebase --force-rebase <new-base> " & branch & "\n" &
  "            git -C " & l & " replace -d " & child & "\n" &
  "          (<new-base> is the rewritten counterpart of " & abbrev(missing) &
    ", usually origin/<branch>)\n" &
  "  Nothing was changed."

proc messageOldGit(gitBin, pool: string): string =
  let v = runGit(gitBin, ["version"]).output.strip()
  "repro: shared cache " & displayPoolPath(pool) & ": " & v & " is older than 2.42,\n" &
  "  so it cannot be told which objects the checkouts borrowing from this cache still\n" &
  "  use. The cache therefore keeps every object it has ever held (gc.pruneExpire=never).\n" &
  "  Nothing is at risk; upgrading git lets it reclaim the space."

proc missingAncestry(gitBin, leaf: string; tips: seq[string];
                     stopAt: seq[string]):
    tuple[missing: seq[string]; childOf: seq[(string, string)]] =
  ## Walk the commits of ``tips`` that ``stopAt`` does not already reach,
  ## with lazy fetching off, and return the missing commits plus, for each,
  ## the present commit whose parent it is.
  var input = ""
  for t in tips: input.add(t & "\n")
  for s in stopAt: input.add("^" & s & "\n")
  let res = runGitEnv(gitBin, ["-C", leaf, "rev-list", "--parents",
    "--missing=print", "--ignore-missing", "--stdin"], lazyFetch = false,
    input = input)
  var missingSet: seq[string]
  var edges: seq[(string, string)]   # (child, parent)
  for line in res.output.splitLines():
    let t = line.strip()
    if t.startsWith("?"):
      let id = t[1 .. ^1]
      if isObjectId(id) and id notin missingSet:
        missingSet.add(id)
      continue
    let parts = t.split(' ')
    if parts.len >= 2 and isObjectId(parts[0]):
      for p in parts[1 .. ^1]:
        if isObjectId(p):
          edges.add((parts[0], p))
  result.missing = missingSet
  for m in missingSet:
    for (child, parent) in edges:
      if parent == m and child notin missingSet:
        result.childOf.add((m, child))
        break

proc appendDroppedRefLog(logPath, refName, id, pool: string): bool =
  try:
    createDir(logPath.parentDir)
    let f = open(logPath, fmAppend)
    defer: f.close()
    f.write(now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'") & "\t" & refName &
      "\t" & id & "\t" & pool & "\n")
    true
  except IOError, OSError, ValueError:
    false

proc checkLeaf*(gitBin, leaf: string; mode: LeafCheckMode;
                cacheRoot = ""; pool = ""): LeafCheckReport =
  ## The detector (§4.1) for one leaf, with self-registration (§4.3).
  ##
  ## Registration and the §3.4/§3.5 config are written in EVERY mode: they
  ## only ever make the pool keep more and the leaf fetch more, and a leaf
  ## that the detector has seen but not registered would be exactly the
  ## unprotected borrower §3.2 exists to prevent. ``mode`` governs the one
  ## destructive step, removing a stale remote-tracking ref.
  result.leaf = leaf
  var thePool = pool
  if thePool.len == 0:
    let pools = poolsOfLeaf(leaf, cacheRoot)
    if pools.len == 0:
      return                           # not a leaf of any pool: nothing to do
    thePool = pools[0]
  result.pool = thePool
  let (gitDir, commonDir) = gitDirOf(gitBin, leaf)
  if gitDir.len == 0:
    result.diagnostic = "not a git checkout: " & leaf
    return

  # §4.3 self-registration.
  result.registered = registerBorrower(thePool, leaf)
  let configured = ensureLeafPoolConfig(gitBin, leaf, thePool)
  result.configured = configured.len == 0
  if configured.len > 0:
    result.diagnostic = configured

  # §3.6: report an old git once per pool.
  if not gitSupportsRetentionHook(gitBin):
    let marker = poolReproDir(thePool) / OldGitReportedFileName
    if not fileExists(marker):
      result.findings.add(LeafFinding(kind: lfkOldGit,
        message: messageOldGit(gitBin, thePool)))
      try:
        createDir(poolReproDir(thePool))
        writeFile(marker, "")
      except IOError, OSError:
        discard

  let targets = listLeafTargets(gitBin, leaf, commonDir)
  var ids: seq[string]
  for t in targets:
    if t.id notin ids: ids.add(t.id)
  let missing = batchPresence(gitBin, leaf, ids)
  var stillMissing: seq[string]
  for id in missing:
    if refill(gitBin, leaf, id):
      result.findings.add(LeafFinding(kind: lfkRefilled, objectId: id))
    else:
      stillMissing.add(id)

  # Local work first (SPI-AREQ-4): a local ref whose own commit is gone, and
  # a local branch or detached HEAD whose commits are intact but sit on
  # parents that are gone. Nothing is changed for either; and a
  # remote-tracking ref whose commit one of them needs is left alone too, so
  # message A's "none of your branches depend on it" is only ever said when
  # it is true.
  var neededByLocal: seq[string]
  for t in targets:
    if t.id notin stillMissing or t.refName.startsWith("refs/remotes/"):
      continue
    result.findings.add(LeafFinding(kind: lfkLocalTipMissing,
      refName: t.refName, objectId: t.id,
      message: messageLocalTipMissing(gitBin, leaf, thePool, t.refName,
        t.id)))
    neededByLocal.add(t.id)

  # Walk only what upstream's present refs do not already reach: in the
  # common case that is the handful of unpushed commits, and one process for
  # all of them.
  var localTips: seq[LeafTarget]
  var stopAt: seq[string]
  for t in targets:
    if t.id in stillMissing:
      continue
    if t.refName.startsWith("refs/heads/") or t.refName == "HEAD" or
        t.refName.startsWith("worktree:"):
      localTips.add(t)
    elif t.refName.startsWith("refs/remotes/"):
      if t.id notin stopAt: stopAt.add(t.id)
  var allTips: seq[string]
  for t in localTips:
    if t.id notin allTips: allTips.add(t.id)
  if allTips.len > 0:
    let combined = missingAncestry(gitBin, leaf, allTips, stopAt)
    var settled = combined.missing.len == 0
    if not settled:
      var refilled = 0
      for m in combined.missing:
        if refill(gitBin, leaf, m):
          inc refilled
          result.findings.add(LeafFinding(kind: lfkRefilled, objectId: m))
      # Refilling a parent can expose the next missing one; one more walk
      # settles it (each refill brings the history behind the commit too).
      if refilled == combined.missing.len:
        settled = missingAncestry(gitBin, leaf, allTips,
          stopAt).missing.len == 0
    if not settled:
      for t in localTips:
        let own = missingAncestry(gitBin, leaf, @[t.id], stopAt)
        if own.missing.len == 0:
          continue
        let m = own.missing[0]
        var child = ""
        for (parent, c) in own.childOf:
          if parent == m:
            child = c
            break
        # "Your own commits are intact" must be true before it is said: walk
        # the trees of the commits that are here, and look for files that
        # went with the old history.
        var input = t.id & "\n"
        for st in stopAt: input.add("^" & st & "\n")
        let objs = runGitEnv(gitBin, ["-C", leaf, "rev-list", "--objects",
          "--no-object-names", "--missing=print", "--ignore-missing",
          "--stdin"], lazyFetch = false, input = input)
        var contentLost = false
        for line in objs.output.splitLines():
          let x = line.strip()
          if x.startsWith("?") and x[1 .. ^1] notin own.missing:
            contentLost = true
            break
        result.findings.add(LeafFinding(kind: lfkLocalHistoryMissing,
          refName: t.refName, objectId: m, childId: child,
          message: messageLocalHistoryMissing(leaf, thePool, t.refName, m,
            child, contentLost)))
        for id in own.missing:
          if id notin neededByLocal: neededByLocal.add(id)

  # Stale copies of upstream (SPI-AREQ-3).
  let logPath = gitDir / PoolReproDirName / DroppedRefsLogFileName
  for t in targets:
    if t.id notin stillMissing or not t.refName.startsWith("refs/remotes/"):
      continue
    if t.id in neededByLocal:
      continue                         # message B covers it; nothing changes
    var removed = false
    if mode == lcmRepair:
      # ``update-ref -d <ref> <old>`` checks the ref store, not the object,
      # and refuses if someone moved the ref since we read it.
      if runGit(gitBin, ["-C", leaf, "update-ref", "-d", t.refName,
          t.id]).code == 0:
        removed = true
        discard appendDroppedRefLog(logPath, t.refName, t.id, thePool)
    result.findings.add(LeafFinding(kind: lfkStaleRemoteRef,
      refName: t.refName, objectId: t.id, removed: removed,
      message: messageStaleRemoteRef(leaf, thePool, t.refName, t.id,
        logPath, removed)))

proc checkRegisteredLeaves*(gitBin, pool: string;
                            mode = lcmRepair): seq[LeafCheckReport] {.gcsafe.} =
  ## §4.2: after a refresh of ``pool``, run the detector in every leaf
  ## registered with it that still borrows from it.
  for leaf in readBorrowers(pool):
    if not dirExists(leaf) or not isWiredTo(leaf, pool):
      continue
    result.add(checkLeaf(gitBin, leaf, mode, pool = pool))

proc registerLeafWithPool*(gitBin, leaf, pool: string): string =
  ## What wiring a leaf to a pool must also do (§3.2, §3.4, §3.5): register it
  ## and configure it. Returns "" on success, otherwise the diagnostic. Used by
  ## ``wireAlternates`` and by the ``git clone --reference`` path.
  if not registerBorrower(pool, leaf):
    return "could not register " & leaf & " in " & borrowersPath(pool)
  ensureLeafPoolConfig(gitBin, leaf, pool)

# -- migration (§5) -----------------------------------------------------------

type
  SharedClonesMigration* = object
    ## Outcome of ``migrateSharedClones``.
    pools*: seq[string]
      ## Every pool found under the cache root.
    poolExpiry*: seq[(string, string)]
      ## ``(pool, gc.pruneExpire)`` after the pass.
    leaves*: seq[LeafCheckReport]
      ## The detector's report for every leaf that was migrated.
    diagnostics*: seq[string]

proc listPools*(cacheRoot: string): seq[string] =
  ## Every shared bare under ``cacheRoot``: a ``*.git`` directory holding
  ## ``objects/`` and ``HEAD``. The walk does not descend into a pool.
  if not dirExists(cacheRoot):
    return
  var stack = @[cacheRoot]
  while stack.len > 0:
    let dir = stack.pop()
    for kind, entry in walkDir(dir):
      if kind != pcDir:
        continue
      if entry.endsWith(".git") and dirExists(entry / "objects") and
          fileExists(entry / "HEAD"):
        result.add(entry)
      else:
        stack.add(entry)

proc findCheckoutsUnder*(roots: openArray[string]; maxDepth = 4): seq[string] =
  ## Git checkouts (directories with a ``.git``) under each of ``roots``, at
  ## most ``maxDepth`` levels down, descending into checkouts too (a
  ## workspace nests some repos inside others). Hidden directories and the
  ## usual build-output trees are skipped; this only has to find workspace
  ## repos, which never live there.
  const Skip = ["node_modules", "target", "build", "dist", "result"]
  for root in roots:
    if not dirExists(root):
      continue
    var stack = @[(root, 0)]
    while stack.len > 0:
      let (dir, depth) = stack.pop()
      if dirExists(dir / ".git") and dir notin result:
        result.add(dir)
      if depth >= maxDepth:
        continue
      for kind, entry in walkDir(dir):
        if kind != pcDir:
          continue
        let name = entry.lastPathPart
        if name.startsWith(".") or name in Skip:
          continue
        stack.add((entry, depth + 1))

proc migrateSharedClones*(gitBin, cacheRoot: string;
                          leafCandidates: openArray[string]):
    SharedClonesMigration =
  ## §5 in one pass over the whole pool root, so a machine converges without
  ## waiting for each repo to be synced:
  ##
  ##   1. every pool gets §3.1–§3.3 (``prepareSharedBare``) — while its
  ##      registry is still empty this keeps ``gc.pruneExpire=never``;
  ##   2. every leaf among ``leafCandidates`` and every leaf already
  ##      registered gets the detector in repair mode, which registers it and
  ##      writes §3.4–§3.5 (self-registration, §4.3);
  ##   3. every pool's config is asserted again, which is the step that
  ##      moves a pool to the expiry window — only now that its registry
  ##      holds the leaves found in step 2.
  result.pools = listPools(cacheRoot)
  for pool in result.pools:
    let prepared = prepareSharedBare(gitBin, pool)
    if prepared.len > 0:
      result.diagnostics.add(prepared)
  var leaves: seq[string]
  for c in leafCandidates:
    if dirExists(c) and c notin leaves:
      leaves.add(c)
  for pool in result.pools:
    for leaf in readBorrowers(pool):
      if dirExists(leaf) and leaf notin leaves:
        leaves.add(leaf)
  for leaf in leaves:
    if poolsOfLeaf(leaf, cacheRoot).len == 0:
      continue
    let report = checkLeaf(gitBin, leaf, lcmRepair, cacheRoot)
    if report.diagnostic.len > 0:
      result.diagnostics.add(report.diagnostic)
    result.leaves.add(report)
  for pool in result.pools:
    if not ensureSharedBareSafety(gitBin, pool):
      result.diagnostics.add("could not install the shared-bare safety " &
        "config on " & pool)
    let expiry = runGit(gitBin, ["--git-dir=" & pool, "config", "--get",
      "gc.pruneExpire"]).output.strip()
    result.poolExpiry.add((pool, expiry))

# ---- cache-ref push (RA-5 mechanism; RA-4 wires the hook) ------------------

proc currentBranch*(gitBin, repoPath: string): string =
  ## Return the short name of the branch ``repoPath`` currently has
  ## checked out, or "" when detached / on error.
  let res = runGit(gitBin,
    ["-C", repoPath, "rev-parse", "--abbrev-ref", "HEAD"])
  if res.code != 0:
    return ""
  let name = res.output.strip()
  if name == "HEAD": "" else: name

# ---- the cache push may only ever write the cache namespace ---------------
#
# The eager post-commit push exists to move OBJECTS between sibling checkouts
# that share one bare. It is not a publication: nothing it writes is meant to
# be visible to anyone but this machine, and it deliberately runs
# ``--force --no-verify`` so no gate can slow it down. Those two properties
# are safe together only for as long as its destination cannot be an ordinary
# branch on an ordinary remote. If it ever could, an unattended background
# process would be force-pushing unreviewed work to a shared remote with every
# safety check switched off — and, being detached and fire-and-forget, it
# would do so silently.
#
# Nothing about the refspec construction below announces that it is
# load-bearing, and a reader who changes it will not be warned by the type
# system, by git, or by the caller (which discards the result). So the
# constraint is stated once, as data, and enforced on the ARGUMENT VECTOR
# immediately before the process starts. An edit that retargets the push —
# whether by changing the ref, the destination, or by hand-building a
# different command — has to get past a check that reads what is actually
# about to be executed, not what the author intended.

const
  cacheRefNamespace* = "refs/cache/"
    ## The ONE ref namespace the eager cache push may write
    ## (Unified-Locking-And-Hooks.md §7.2). Anything else — and
    ## ``refs/heads/`` above all — is out of bounds by construction.

type
  CacheRefPushPlan* = object
    ## The fully-resolved git invocation for one cache-ref push, kept
    ## separate from the act of running it so it can be asserted on
    ## without a repository, a network, or a subprocess.
    ok*: bool
    destination*: string   ## the shared bare's own path; never a remote name
    cacheRef*: string      ## ``refs/cache/<workspace>/<branch>``
    diagnostic*: string    ## why not, when ``ok`` is false

proc refComponentFault(value: string): string =
  ## "" when ``value`` is usable as ONE path component of a ref name.
  ## Non-empty describes why it is not — the components are what decide
  ## whether the assembled ref can leave its namespace.
  if value.len == 0: return "is empty"
  if value == "." or value == "..": return "is '" & value & "'"
  if value.startsWith("-"): return "starts with '-'"
  if value.endsWith(".lock"): return "ends with '.lock'"
  for ch in value:
    if ch in {'/', '\\', ':', '?', '[', '*', '~', '^', ' ', '\t'} or
        ch < ' ' or ch == '\x7F':
      return "contains '" & $ch & "'"
  ""

proc cacheRefPushPlan*(sharedBarePath, workspaceName, branch: string):
    CacheRefPushPlan =
  ## PURE: build (and validate) the cache-ref push for one repo. Refuses,
  ## rather than pushing something else, whenever the destination would not
  ## be a shared bare on this filesystem or the ref would not land inside
  ## ``refs/cache/``.
  ##
  ## The destination must be an ABSOLUTE path to a git directory. That single
  ## rule is what makes a remote impossible to reach from here: a remote alias
  ## (``origin``), an ``https://`` or ``ssh://`` URL, and git's scp-like
  ## ``git@host:org/repo`` form are none of them absolute paths, so each is
  ## refused before any process starts.
  ##
  ## ``workspaceName`` is ONE component — it is a directory basename, and a
  ## name carrying a separator could otherwise reposition the ref (``..`` most
  ## obviously). ``branch`` may contain '/' (``fix/some-thing``), so it is
  ## checked component by component and may not itself be a full ref name.
  result.destination = sharedBarePath
  if branch.len == 0:
    result.diagnostic = "no branch to cache-push (detached HEAD?)"
    return
  if sharedBarePath.len == 0 or not sharedBarePath.isAbsolute:
    result.diagnostic = "cache-push destination must be an absolute path to " &
      "a shared bare, not a remote or URL: '" & sharedBarePath & "'"
    return
  if not looksLikeGitDir(sharedBarePath):
    result.diagnostic = "shared bare missing for cache-push: " & sharedBarePath
    return
  let wsFault = refComponentFault(workspaceName)
  if wsFault.len > 0:
    result.diagnostic = "workspace name " & wsFault &
      ", so it cannot name a cache ref: '" & workspaceName & "'"
    return
  if branch.startsWith("refs/"):
    result.diagnostic = "cache-push branch must be a branch name, not a full " &
      "ref: '" & branch & "'"
    return
  for component in branch.split('/'):
    let fault = refComponentFault(component)
    if fault.len > 0:
      result.diagnostic = "branch component '" & component & "' " & fault &
        ", so it cannot name a cache ref: '" & branch & "'"
      return
  # A git ref name is NOT a filesystem path: its separator is '/' on every
  # platform, including Windows. Nim's ``/`` is ``DirSep``-aware, so building
  # this with it produced ``refs\cache\<ws>\<branch>`` on Windows — ``joinPath``
  # rewrites the ``/`` already inside the left operand too, so the WHOLE ref
  # name came back backslashed — and git rejected the push with
  # ``fatal: invalid refspec``. The push is best-effort
  # and the caller discards its result, so the whole RA-5 cache-ref mechanism
  # was a silent no-op on Windows — found while proving W4's detached child
  # actually runs. The readers below (``cacheRefWorkspaces``,
  # ``pruneDeadCacheRefs``) already split on '/', so this is the one site that
  # disagreed with the rest of the file.
  result.cacheRef = cacheRefNamespace & workspaceName & "/" & branch
  result.ok = true

proc cacheRefPushArgvFault*(argv: openArray[string];
                            expectedDestination: string): string =
  ## "" when ``argv`` is a git push that writes ONLY inside
  ## ``refs/cache/`` on ``expectedDestination``. Non-empty names what is
  ## wrong with it.
  ##
  ## This reads the vector that is about to be handed to the process, so it
  ## holds for a command assembled anywhere, by anyone, however it was built.
  ## It is the reason a future retargeting of this push cannot ship quietly.
  var sawPush = false
  var destination = ""
  var refspecs: seq[string]
  var i = 0
  while i < argv.len:
    let arg = argv[i]
    if not sawPush:
      if arg == "push": sawPush = true
      elif arg == "-C": inc i          # its value is a path, not an operand
      inc i
      continue
    if arg.startsWith("-"):
      inc i
      continue
    if destination.len == 0: destination = arg
    else: refspecs.add(arg)
    inc i
  if not sawPush:
    return "not a 'git push'"
  if destination.len == 0:
    return "no push destination; git would fall back to a configured remote"
  if destination != expectedDestination:
    return "pushes to '" & destination & "' instead of the shared bare '" &
      expectedDestination & "'"
  if refspecs.len == 0:
    return "no refspec; git would push whatever the branch's upstream is"
  for spec in refspecs:
    let colon = spec.rfind(':')
    if colon < 0:
      return "refspec '" & spec &
        "' names no destination ref, so git chooses one"
    let dest = spec[(colon + 1) .. ^1]
    if not dest.startsWith(cacheRefNamespace) or
        dest.len == cacheRefNamespace.len or ".." in dest or "//" in dest:
      return "refspec '" & spec & "' writes '" & dest & "', which is outside " &
        cacheRefNamespace
  ""

proc cacheRefPushArgv*(repoPath: string; plan: CacheRefPushPlan): seq[string] =
  ## The argv for a validated plan. ``--force --no-verify`` is correct only
  ## because the destination is this machine's own object cache: the
  ## publication gate has nothing to say about an internal object write, and
  ## the ref is workspace-namespaced so it cannot collide with a sibling's
  ## same-named branch. Both of those justifications depend on the plan
  ## having been validated, which is why the argv is built from it and not
  ## from raw arguments.
  if not plan.ok: return @[]
  @["-C", repoPath, "push", "--force", "--no-verify", plan.destination,
    "HEAD:" & plan.cacheRef]

proc pushCacheRef*(gitBin, repoPath, sharedBarePath, workspaceName: string;
                   branch = ""): SharedCloneResult =
  ## Push ``repoPath``'s current branch (or the explicit ``branch``) into
  ## the shared bare under ``refs/cache/<workspaceName>/<branch>``, using
  ## ``--force --no-verify`` (the publication gate does not apply to an
  ## internal object/ref write). Workspace-namespacing the ref means
  ## same-named branches from different workspaces never collide.
  ##
  ## Effect: a commit in workspace W1 becomes visible — as raw objects
  ## reachable from the cache ref — to any sibling workspace alternated to
  ## the same bare, with no network round-trip and no manual fetch.
  ##
  ## This is the RA-5 mechanism. RA-4 calls it from the post-commit hook
  ## (detached, fire-and-forget, never blocking the commit); RA-5 exposes
  ## it and tests it directly.
  ##
  ## It writes the cache namespace or it writes nothing: a destination or a
  ## ref it cannot vouch for is refused here rather than pushed somewhere
  ## else. See ``cacheRefPushPlan`` for why that has to be a rule and not a
  ## convention.
  let useBranch =
    if branch.len > 0: branch else: currentBranch(gitBin, repoPath)
  if useBranch.len == 0:
    return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
      diagnostic: "cannot determine branch to cache-push in " & repoPath &
        " (detached HEAD?)")
  let plan = cacheRefPushPlan(sharedBarePath, workspaceName, useBranch)
  if not plan.ok:
    return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
      diagnostic: plan.diagnostic)
  let argv = cacheRefPushArgv(repoPath, plan)
  let fault = cacheRefPushArgvFault(argv, plan.destination)
  if fault.len > 0:
    return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
      diagnostic: "refusing to run the cache-ref push: it " & fault)
  # ``HEAD:<cacheRef>`` pushes whatever the working tree currently has
  # checked out; the cache ref is the destination in the bare.
  let res = runGit(gitBin, argv)
  if res.code != 0:
    return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
      diagnostic: "cache-ref push failed (" & $res.code & "): " &
        res.output.strip())
  SharedCloneResult(ok: true, sharedBarePath: sharedBarePath)

# ---- cache maintenance: gc / repack / dead-ref prune (RA-15) ---------------
#
# The RA-5 cache accumulates loose objects from every ``refs/cache/<ws>/*``
# push without bound (each cache-ref push lands a new commit's objects loose).
# RA-15 adds an *opportunistic*, *best-effort* maintenance pass per shared
# bare that:
#
#   1. prunes ``refs/cache/<workspace>/*`` for workspaces that are no longer
#      live (so unreachable objects become collectable), and
#   2. runs ``git gc``/``git repack`` to fold loose objects into packs
#      (expiring only what no registered borrower names, after the pool's
#      ``gc.pruneExpire``), bounded by a loose-object-count / cache-size /
#      age budget so we do NOT
#      gc on every operation.
#
# It is designed to never block a clone or commit: callers run it on a
# threshold (or detached in the background). Every step is wrapped so a
# failure is reported via ``MaintenanceResult.diagnostic`` rather than raised
# — a maintenance failure must never break init/sync/commit.

type
  MaintenanceBudget* = object
    ## Threshold that gates whether a gc/repack pass runs. Maintenance is
    ## skipped (a cheap no-op) until at least one bound is exceeded, so the
    ## common path stays fast. ``looseObjectLimit`` is the primary trigger
    ## (it tracks exactly the cache-ref-push growth); ``ageSeconds`` forces a
    ## periodic pass even when growth is slow; ``sizeBytesLimit`` caps total
    ## on-disk footprint. A value of 0 disables that particular bound.
    looseObjectLimit*: int
    sizeBytesLimit*: int64
    ageSeconds*: int

  MaintenanceResult* = object
    ## Outcome of a best-effort maintenance pass over one shared bare.
    ## ``ok`` is false only on a genuine error (a git command failed); a
    ## *skipped* pass (budget not exceeded) is ``ok = true`` with
    ## ``ran = false``. ``prunedRefs`` lists the dead cache refs removed.
    ok*: bool
    ran*: bool
    sharedBarePath*: string
    looseBefore*: int
    looseAfter*: int
    prunedRefs*: seq[string]
    diagnostic*: string

const
  DefaultLooseObjectLimit* = 500
    ## Default loose-object trigger. Each cache-ref push of a fresh commit
    ## adds a handful of loose objects; a few hundred is a sensible "enough
    ## churn to bother packing" threshold that stays well below git's own
    ## ``gc.auto`` default (6700) so the cache never balloons.
  DefaultMaintenanceAgeSeconds* = 7 * 24 * 60 * 60
    ## Default age bound: force a pass at least weekly even on a quiet cache.
  MaintenanceStampRelPath* = "reprobuild-last-gc"
    ## File (relative to the bare root) whose mtime records the last pass, so
    ## the age bound and the "dead workspace" age fallback have a clock.

proc defaultMaintenanceBudget*(): MaintenanceBudget =
  ## Sensible defaults (overridable by callers / the CLI later).
  MaintenanceBudget(
    looseObjectLimit: DefaultLooseObjectLimit,
    sizeBytesLimit: 0,
    ageSeconds: DefaultMaintenanceAgeSeconds)

proc looseObjectCount*(gitBin, barePath: string): int =
  ## Number of loose (unpacked) objects in ``barePath``, via
  ## ``git count-objects -v`` (the ``count:`` field). Returns 0 on error so
  ## a failed probe never *triggers* maintenance spuriously.
  let res = runGit(gitBin, ["-C", barePath, "count-objects", "-v"])
  if res.code != 0:
    return 0
  for line in res.output.splitLines:
    let trimmed = line.strip()
    if trimmed.startsWith("count:"):
      try:
        return parseInt(trimmed[len("count:") .. ^1].strip())
      except ValueError:
        return 0
  0

proc directorySizeBytes(path: string): int64 =
  ## Total size of all regular files under ``path`` (best-effort; unreadable
  ## entries are skipped). Used only when a ``sizeBytesLimit`` is configured.
  if not dirExists(path):
    return 0
  for f in walkDirRec(path, yieldFilter = {pcFile}):
    try:
      result += getFileSize(f)
    except OSError, IOError:
      discard

proc maintenanceStampPath(barePath: string): string =
  barePath / MaintenanceStampRelPath

proc maintenanceAgeSeconds(barePath: string): int =
  ## Seconds since the last recorded maintenance pass, or a very large number
  ## when no stamp exists yet (so the age bound fires on a never-maintained
  ## bare).
  let stamp = maintenanceStampPath(barePath)
  if not fileExists(stamp):
    return high(int)
  try:
    let last = getLastModificationTime(stamp).toUnix()
    let now = getTime().toUnix()
    int(max(0'i64, now - last))
  except OSError:
    high(int)

proc touchMaintenanceStamp(barePath: string) =
  try:
    writeFile(maintenanceStampPath(barePath), "")
  except IOError, OSError:
    discard

proc maintenanceDue*(gitBin, barePath: string;
                     budget: MaintenanceBudget): bool =
  ## True when at least one configured budget bound is exceeded. This is the
  ## cheap gate callers consult before paying for a gc — it never runs git gc
  ## itself.
  if not looksLikeGitDir(barePath):
    return false
  if budget.looseObjectLimit > 0 and
      looseObjectCount(gitBin, barePath) >= budget.looseObjectLimit:
    return true
  if budget.ageSeconds > 0 and
      maintenanceAgeSeconds(barePath) >= budget.ageSeconds:
    return true
  if budget.sizeBytesLimit > 0 and
      directorySizeBytes(barePath) >= budget.sizeBytesLimit:
    return true
  false

proc cacheRefWorkspaces*(gitBin, barePath: string): seq[string] =
  ## The distinct workspace names that currently own a ``refs/cache/<ws>/*``
  ## ref in ``barePath``. Used to find dead-workspace refs to prune.
  let res = runGit(gitBin,
    ["-C", barePath, "for-each-ref", "--format=%(refname)", "refs/cache/"])
  if res.code != 0:
    return @[]
  var seen: seq[string]
  for line in res.output.splitLines:
    let refName = line.strip()
    # refs/cache/<ws>/<branch...>
    if not refName.startsWith("refs/cache/"):
      continue
    let rest = refName[len("refs/cache/") .. ^1]
    let slash = rest.find('/')
    if slash <= 0:
      continue
    let ws = rest[0 ..< slash]
    if ws notin seen:
      seen.add(ws)
  seen

proc pruneDeadCacheRefs*(gitBin, barePath: string;
                         liveWorkspaces: openArray[string]): seq[string] =
  ## Delete every ``refs/cache/<ws>/*`` ref whose ``<ws>`` is not in
  ## ``liveWorkspaces``. Returns the list of deleted ref names. A LIVE
  ## workspace's refs are always preserved — this is the safety-critical
  ## invariant (dropping a live workspace's cache refs would silently lose
  ## not-yet-published objects on the next gc).
  let res = runGit(gitBin,
    ["-C", barePath, "for-each-ref", "--format=%(refname)", "refs/cache/"])
  if res.code != 0:
    return @[]
  for line in res.output.splitLines:
    let refName = line.strip()
    if not refName.startsWith("refs/cache/"):
      continue
    let rest = refName[len("refs/cache/") .. ^1]
    let slash = rest.find('/')
    if slash <= 0:
      continue
    let ws = rest[0 ..< slash]
    if ws in liveWorkspaces:
      continue
    let del = runGit(gitBin, ["-C", barePath, "update-ref", "-d", refName])
    if del.code == 0:
      result.add(refName)

proc discoverLiveWorkspaceNames*(workspaceRoots: openArray[string]): seq[string] =
  ## Map a set of live workspace ROOT directories to the workspace names used
  ## in the cache-ref namespace. The name is the directory basename (the same
  ## value RA-4/RA-5 namespace cache pushes under). Only directories that
  ## still exist on disk are treated as live — that is the liveness predicate.
  for root in workspaceRoots:
    if root.len == 0:
      continue
    if dirExists(root):
      let name = root.lastPathPart
      if name.len > 0 and name notin result:
        result.add(name)

proc maintainSharedBare*(gitBin, barePath: string;
                         liveWorkspaces: openArray[string];
                         budget = defaultMaintenanceBudget();
                         force = false): MaintenanceResult =
  ## Run an opportunistic, best-effort maintenance pass over one shared bare:
  ##
  ##   1. prune dead-workspace ``refs/cache/*`` (workspaces not in
  ##      ``liveWorkspaces``), then
  ##   2. when the budget is exceeded (or ``force``), run ``git gc`` to fold
  ##      loose objects into packs. What it may expire is the pool's own
  ##      config: unreachable objects that no registered borrower names, after
  ##      ``gc.pruneExpire`` (``poolIntegrityConfig``).
  ##
  ## Never raises: a git failure is returned as ``ok = false`` with a
  ## diagnostic so a caller on the init/commit path can ignore it. ``force``
  ## bypasses the budget gate (used by the manual ``shared-clones gc``
  ## trigger). When ``liveWorkspaces`` is empty the prune step is skipped (we
  ## refuse to delete every cache ref just because no live set was supplied —
  ## that would be the unsafe interpretation).
  result.sharedBarePath = barePath
  if not looksLikeGitDir(barePath):
    result.ok = false
    result.diagnostic = "shared bare missing for maintenance: " & barePath
    return
  result.ok = true
  result.looseBefore = looseObjectCount(gitBin, barePath)

  # (1) Dead-workspace ref prune. Only when we were actually given a live
  # set; an empty set means "unknown", and pruning everything would be
  # destructive, so we skip it.
  if liveWorkspaces.len > 0:
    result.prunedRefs = pruneDeadCacheRefs(gitBin, barePath, liveWorkspaces)

  # (2) Budget-gated gc/repack.
  let due = force or maintenanceDue(gitBin, barePath, budget)
  if not due:
    result.ran = false
    result.looseAfter = result.looseBefore
    return

  # The expiry is the POOL's: ``gc.pruneExpire`` and ``gc.recentObjectsHook``
  # from its config (Shared-Clone-Pool-Integrity §3.1, §3.3), so no prune
  # flag is passed. ``--prune=now`` in particular must never appear here:
  # git does not run the retention hook in that mode, so it would delete
  # every object the pool's own refs no longer reach -- including the ones
  # checkouts in sibling workspaces still borrow through alternates.
  #
  # Registry entries for leaves that are gone, or that no longer borrow from
  # this pool, are dropped first; then the config is re-asserted, which is
  # what moves a pool between ``never`` and the expiry window as its
  # registry fills or empties. If that cannot be written the gc does not
  # run: a pool whose config we could not establish is a pool we do not
  # prune (SPI-GOAL-5).
  discard pruneBorrowers(barePath)
  if not ensureSharedBareSafety(gitBin, barePath):
    result.ok = false
    result.ran = false
    result.looseAfter = result.looseBefore
    result.diagnostic = "could not install the shared-bare safety config on " &
      barePath & "; gc skipped so nothing a borrower uses can be expired"
    return
  var gcArgs = sharedBareSafetyArgs()
  gcArgs.add(["-C", barePath, "gc", "--quiet"])
  let gc = runGit(gitBin, gcArgs)
  if gc.code != 0:
    result.ok = false
    result.ran = false
    result.looseAfter = result.looseBefore
    result.diagnostic = "git gc failed (" & $gc.code & "): " &
      gc.output.strip()
    return
  result.ran = true
  result.looseAfter = looseObjectCount(gitBin, barePath)
  touchMaintenanceStamp(barePath)

# ---- inspection (the `shared-clones list` surface) -------------------------

type
  SharedCloneRepoInfo* = object
    ## Per-repo wiring view used by ``repro workspace shared-clones list``.
    path*: string
    fetchUrl*: string
    sharedBarePath*: string
    barePresent*: bool
    wired*: bool

proc inspectRepoWiring*(workspaceRoot, cacheRoot, repoRelPath,
                        fetchUrl: string): SharedCloneRepoInfo =
  ## Build the wiring view for a single repo without touching the network.
  let bare = sharedBarePath(cacheRoot, fetchUrl)
  let repoAbs = workspaceRoot / repoRelPath
  SharedCloneRepoInfo(
    path: repoRelPath,
    fetchUrl: fetchUrl,
    sharedBarePath: bare,
    barePresent: looksLikeGitDir(bare),
    wired: isWiredTo(repoAbs, bare))

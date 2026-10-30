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
##     (``git fetch --all --prune``), rewrites non-split commit-graphs only
##     after migrating borrowers, and expires only objects no registered
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

import std/[locks, os, osproc, sets, strtabs, strutils, tables, tempfiles, times]
when defined(windows):
  import std/winlean
else:
  import std/posix as posix

import git_tool
# ``execCmdExCloseOnce``: ``execCmdEx`` without ``osproc.close``'s double close
# of the merged stdout/stderr descriptor. These helpers run inside the build
# engine's workspace-VCS executor, on the scheduler thread, while the engine's
# worker pool may be live; see ``repro_core/process_close``.
from repro_core/process_exec import execCmdExCloseOnce
from repro_core/ambient_execution import uncontrolledFindExe, uncontrolledStartProcess

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
    lfkRefetchChainMissing ## partial-pool leaf lacked its lazy-refetch chain
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

# ---- cross-process and cross-thread VCS serialization ----------------------

const
  VcsLockDefaultTimeoutMs* {.intdefine.} = 120_000
    ## Maximum wait time (2 minutes) when acquiring a per-cache-entry or
    ## per-checkout lock before giving up.
  VcsLockPollIntervalMs = 25

when defined(windows):
  const
    FILE_ATTRIBUTE_NORMAL_W = int32(0x80)
else:
  proc cFlock(fd: cint; operation: cint): cint {.importc: "flock", header: "<sys/file.h>".}

  const
    LOCK_EX_C = cint(2)
    LOCK_NB_C = cint(4)
    LOCK_UN_C = cint(8)

type
  VcsLockEntry = object
    ownerThread: int
    depth: int
    when defined(windows):
      handle: Handle
    else:
      fd: cint

  VcsFileLock* = object
    key*: string
    lockFile*: string
    acquired*: bool

var
  vcsLockTableGuard: Lock
  vcsLockEntries {.guard: vcsLockTableGuard.}: Table[string, VcsLockEntry]

initLock(vcsLockTableGuard)

proc canonicalLockKey(path: string): string {.gcsafe.} =
  if path.len == 0:
    return ""
  result = absolutePath(path)
  if DirSep != '/':
    result = result.replace('/', DirSep)
  if AltSep != DirSep:
    result = result.replace(AltSep, DirSep)
  try:
    result = normalizedPath(result)
  except CatchableError:
    discard
  while result.len > 1 and result[^1] in {DirSep, AltSep}:
    result.setLen(result.len - 1)
  when defined(windows) or defined(macosx):
    result = result.toLowerAscii()

proc cacheEntryLockPath*(entryPath: string): string {.gcsafe.} =
  ## Sibling lock file for a shared bare cache entry or manifest cache entry.
  ## Lives alongside ``entryPath`` (never inside it) so locking an entry
  ## before its initial clone neither creates the target directory early nor
  ## turns a non-git directory at ``entryPath`` into a non-empty one.
  var clean = entryPath
  while clean.len > 1 and clean[^1] in {DirSep, AltSep}:
    clean.setLen(clean.len - 1)
  if clean.len == 0: "" else: clean & ".repro-lock"

proc checkoutLockPath*(repoPath: string): string {.gcsafe.} =
  ## Per-checkout lock file inside ``<repoPath>/.git/repro-vcs-lock`` (or
  ## ``<repoPath>/repro-vcs-lock`` for a bare repository) used to serialize
  ## reprobuild-managed mutating fetches against a working tree or bare repo
  ## without creating untracked files in the working tree.
  if repoPath.len == 0:
    return ""
  if dirExists(repoPath / ".git"):
    return repoPath / ".git" / "repro-vcs-lock"
  if fileExists(repoPath / ".git"):
    try:
      let firstLine = readFile(repoPath / ".git").strip()
      if firstLine.startsWith("gitdir:"):
        let gd = firstLine["gitdir:".len .. ^1].strip()
        let absGd = if gd.isAbsolute: gd else: absolutePath(gd, absolutePath(repoPath))
        if dirExists(absGd):
          var commonDir = absGd
          if fileExists(absGd / "commondir"):
            let common = readFile(absGd / "commondir").strip()
            commonDir = if common.isAbsolute: common
              else: absolutePath(common, absGd)
          return commonDir / "repro-vcs-lock"
    except CatchableError:
      discard
  if dirExists(repoPath / "objects") and fileExists(repoPath / "HEAD"):
    return repoPath / "repro-vcs-lock"
  ""

proc acquireVcsFileLock*(lockFile: string;
                         timeoutMs = VcsLockDefaultTimeoutMs): VcsFileLock {.gcsafe.} =
  ## Acquire a cross-process and cross-thread re-entrant exclusive lock on
  ## ``lockFile``. When ``lockFile`` is empty, returns an unacquired no-op
  ## handle so callers can wrap optional paths unconditionally. A negative
  ## timeout waits indefinitely for contention, but refuses permanent I/O
  ## errors; lazy pool refills must not fail just because another refill or
  ## maintenance pass takes longer than the ordinary command deadline.
  if lockFile.len == 0:
    return VcsFileLock(acquired: false)
  let key = canonicalLockKey(lockFile)
  if key.len == 0:
    return VcsFileLock(acquired: false)
  let parent = lockFile.parentDir
  if parent.len > 0:
    try:
      createDir(parent)
    except IOError, OSError:
      return VcsFileLock(acquired: false)

  let tid = getThreadId()
  let deadline = epochTime() + (float(max(0, timeoutMs)) / 1000.0)
  while true:
    var inUseByOtherThread = false
    var reentered = false
    {.cast(gcsafe).}:
      withLock(vcsLockTableGuard):
        if key in vcsLockEntries:
          if vcsLockEntries[key].ownerThread == tid and
              vcsLockEntries[key].depth > 0:
            inc vcsLockEntries[key].depth
            reentered = true
          else:
            inUseByOtherThread = true
        else:
          vcsLockEntries[key] = VcsLockEntry(ownerThread: tid, depth: 0)
    if reentered:
      return VcsFileLock(key: key, lockFile: lockFile, acquired: true)
    if inUseByOtherThread:
      if timeoutMs >= 0 and epochTime() >= deadline:
        return VcsFileLock(acquired: false)
      sleep(VcsLockPollIntervalMs)
      continue

    var osAcquired = false
    var permanentFault = false
    when defined(windows):
      let h = createFileW(
        newWideCString(lockFile),
        GENERIC_READ or GENERIC_WRITE,
        0,
        nil,
        OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL_W,
        0)
      if h != INVALID_HANDLE_VALUE:
        osAcquired = true
        {.cast(gcsafe).}:
          withLock(vcsLockTableGuard):
            vcsLockEntries[key] = VcsLockEntry(
              ownerThread: tid, depth: 1, handle: h)
      elif timeoutMs < 0:
        # Only sharing/locking violations mean another live holder can
        # release this resource. Access or filesystem errors cannot heal by
        # waiting indefinitely.
        permanentFault = int(osLastError()) notin [32, ERROR_LOCK_VIOLATION]
    else:
      # This new mode has no contention deadline. An exec'd credential or
      # transport helper must not retain its lock if the owner is interrupted.
      let descriptorFlags = if timeoutMs < 0: posix.O_CLOEXEC else: cint(0)
      let fd = posix.open(cstring(lockFile),
        posix.O_CREAT or posix.O_RDWR or descriptorFlags, posix.Mode(0o600))
      if fd >= 0:
        if cFlock(fd, LOCK_EX_C or LOCK_NB_C) == 0:
          osAcquired = true
          {.cast(gcsafe).}:
            withLock(vcsLockTableGuard):
              vcsLockEntries[key] = VcsLockEntry(
                ownerThread: tid, depth: 1, fd: fd)
        else:
          let failure = osLastError()
          discard posix.close(fd)
          if timeoutMs < 0:
            permanentFault = int(failure) notin
              [int(posix.EAGAIN), int(posix.EWOULDBLOCK), int(posix.EINTR)]
      elif timeoutMs < 0:
        permanentFault = int(osLastError()) != int(posix.EINTR)

    if osAcquired:
      return VcsFileLock(key: key, lockFile: lockFile, acquired: true)

    {.cast(gcsafe).}:
      withLock(vcsLockTableGuard):
        if key in vcsLockEntries and vcsLockEntries[key].ownerThread == tid and
            vcsLockEntries[key].depth == 0:
          vcsLockEntries.del(key)

    if permanentFault or (timeoutMs >= 0 and epochTime() >= deadline):
      return VcsFileLock(acquired: false)
    sleep(VcsLockPollIntervalMs)

proc releaseVcsFileLock*(lock: var VcsFileLock) {.gcsafe.} =
  if not lock.acquired:
    return
  var toClose: VcsLockEntry
  var shouldClose = false
  {.cast(gcsafe).}:
    withLock(vcsLockTableGuard):
      if lock.key in vcsLockEntries:
        dec vcsLockEntries[lock.key].depth
        if vcsLockEntries[lock.key].depth <= 0:
          toClose = vcsLockEntries[lock.key]
          vcsLockEntries.del(lock.key)
          shouldClose = true
  if shouldClose:
    when defined(windows):
      if toClose.handle != 0 and toClose.handle != INVALID_HANDLE_VALUE:
        discard closeHandle(toClose.handle)
    else:
      if toClose.fd >= 0:
        discard cFlock(toClose.fd, LOCK_UN_C)
        discard posix.close(toClose.fd)
  lock.acquired = false

template withVcsFileLock*(lockFile: string; onFailure, body: untyped) =
  ## A nonempty path requires ownership before running the protected body.
  ## Failure is a separate branch so callers retain their structured refusal
  ## or safe fallback. An empty optional path still executes unconditionally.
  block:
    let requiredLockFile = lockFile
    var vcsLock = acquireVcsFileLock(requiredLockFile)
    defer: releaseVcsFileLock(vcsLock)
    if requiredLockFile.len > 0 and not vcsLock.acquired:
      onFailure
    else:
      body

template withVcsFileLock*(lockFile: string; body: untyped) =
  ## Raise IOError when a required lock cannot be acquired. Result-returning
  ## callers use the explicit failure-branch overload to preserve their API.
  block:
    let requiredLockFile = lockFile
    withVcsFileLock(requiredLockFile,
        (block: raise newException(IOError, "could not acquire VCS lock: " & requiredLockFile))):
      body

template withCacheEntryVcsLock*(entryPath: string; onFailure, body: untyped) =
  withVcsFileLock(cacheEntryLockPath(entryPath), onFailure):
    body

template withCacheEntryVcsLock*(entryPath: string; body: untyped) =
  withVcsFileLock(cacheEntryLockPath(entryPath)):
    body

template withCheckoutVcsLock*(repoPath: string; onFailure, body: untyped) =
  withVcsFileLock(checkoutLockPath(repoPath), onFailure):
    body

template withCheckoutVcsLock*(repoPath: string; body: untyped) =
  withVcsFileLock(checkoutLockPath(repoPath)):
    body

proc isTransientGitLockContention*(output: string): bool {.gcsafe.} =
  ## True when ``git`` failed because another process concurrently updated or
  ## locked a ref or config file in the same repository.
  output.contains("cannot lock ref ") or
    output.contains("incorrect old value provided") or
    output.contains("reference_transaction") or
    output.contains("could not lock config file") or
    (output.contains("Unable to create '") and output.contains(".lock'"))

# ---- git plumbing ----------------------------------------------------------

proc runGit(gitBin: string; args: openArray[string];
            workingDir = ""): tuple[code: int; output: string] =
  var cmd = quoteShell(gitBin)
  for arg in args:
    cmd.add(" ")
    cmd.add(quoteShell(arg))
  const MaxLockRetries = 5
  for attempt in 0 .. MaxLockRetries:
    let res = execCmdExCloseOnce(cmd, workingDir = workingDir,
      env = scrubbedGitRepositoryEnv())
    result = (code: res.exitCode, output: res.output)
    if result.code == 0 or attempt == MaxLockRetries or
        not isTransientGitLockContention(result.output):
      return
    sleep(25 * (attempt + 1))

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
  ##   2. Automatic split commit-graph rewrites can remove layers still used
  ##      by a borrower. Keep those writers off. ``maintainSharedBare`` first
  ##      converts registered borrowers to independent non-split graphs, then
  ##      rebuilds the pool graph after gc so expired commits leave it too.
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
  ## out, and is serialized across concurrent processes via
  ## ``withCacheEntryVcsLock(bare)`` so concurrent workspace initializations
  ## or forks never race on the same shared bare entry.
  let bare = sharedBarePath(cacheRoot, fetchUrl)
  var checkLeaves = false
  withCacheEntryVcsLock(bare,
      (block: return SharedCloneResult(ok: false, sharedBarePath: bare,
        diagnostic: "could not lock shared bare: " & bare))):
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
      checkLeaves = true
    else:
      # clone-if-missing: create the parent and a bare mirror clone.
      let parent = bare.splitPath.head
      if parent.len > 0:
        try:
          createDir(parent)
        except OSError as e:
          return SharedCloneResult(ok: false, sharedBarePath: bare,
            diagnostic: "could not create cache parent " & parent & ": " & e.msg)
      let res = runGit(gitBin,
        ["clone", "--bare", "--no-local", "--quiet", fetchUrl, bare])
      if res.code != 0:
        if looksLikeGitDir(bare):
          let prepared = prepareSharedBare(gitBin, bare)
          if prepared.len > 0:
            return SharedCloneResult(ok: false, sharedBarePath: bare,
              diagnostic: prepared)
          let fetched = runGit(gitBin, sharedBareFetchArgs(bare))
          if fetched.code != 0:
            return SharedCloneResult(ok: false, sharedBarePath: bare,
              diagnostic: "git fetch in shared bare failed (" &
                $fetched.code & "): " & fetched.output.strip())
          checkLeaves = true
        else:
          # Leave no half-populated bare behind so the next attempt re-clones
          # cleanly rather than mistaking a broken dir for a present cache.
          if dirExists(bare):
            try: removeDir(bare)
            except OSError: discard
          return SharedCloneResult(ok: false, sharedBarePath: bare,
            diagnostic: "git clone --bare into shared cache failed (" &
              $res.code & "): " & res.output.strip())
      else:
        # A freshly-cloned bare is current, but it is born WITHOUT a fetch
        # refspec, so its NEXT refresh would be the silent no-op described on
        # ``SharedBareFetchRefspec``. Install it at birth, so no bare in the
        # cache ever spends a single refresh cycle frozen.
        let prepared = prepareSharedBare(gitBin, bare)
        if prepared.len > 0:
          return SharedCloneResult(ok: false, sharedBarePath: bare,
            diagnostic: "cloned the shared bare but " & prepared)
  if checkLeaves:
    # A refresh is what makes a rewritten upstream's old commits unreachable
    # here, so it is also the moment to look at every leaf that borrows them
    # (Shared-Clone-Pool-Integrity §4.2). Run outside the bare lock so lock
    # acquisition stays strictly checkout -> pool.
    return SharedCloneResult(ok: true, sharedBarePath: bare,
      leafReports: checkRegisteredLeaves(gitBin, bare))
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
  # Cache entries must own their objects even when a local manifest source
  # borrows from a pool outside the selected cache root.
  var cloneArgs = @["clone", "--no-local", "--quiet"]
  if branch.len > 0:
    cloneArgs.add(["--single-branch", "--branch", branch])
  cloneArgs.add([manifestUrl, target])
  let res = runGit(gitBin, cloneArgs)
  if res.code != 0:
    if looksLikeGitDir(target):
      let post = inspectManifestCacheEntry(gitBin, target, manifestUrl)
      if post.status == mceMatches:
        return refreshManifestCacheEntry(gitBin, target)
    else:
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
  var entry: ManifestCacheEntry
  withCacheEntryVcsLock(primary,
      (block: return SharedCloneResult(ok: false, sharedBarePath: primary,
        diagnostic: "could not lock manifest cache: " & primary))):
    entry = inspectManifestCacheEntry(gitBin, primary, manifestUrl)
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
  withCacheEntryVcsLock(rekeyed,
      (block: return SharedCloneResult(ok: false, sharedBarePath: rekeyed,
        diagnostic: "could not lock manifest cache: " & rekeyed))):
    let alt = inspectManifestCacheEntry(gitBin, rekeyed, manifestUrl)
    case alt.status
    of mceMatches:
      return refreshManifestCacheEntry(gitBin, rekeyed)
    of mceAbsent:
      return cloneManifestCacheEntry(gitBin, rekeyed, manifestUrl, branch)
    of mceForeign:
      return SharedCloneResult(ok: false, sharedBarePath: rekeyed,
        manifestEntry: mceForeign,
        diagnostic: "refusing to use the manifest cache for '" & manifestUrl &
          "': the slug path '" & primary & "' holds '" & entry.observedUrl &
          "' and the re-keyed path '" & rekeyed & "' holds '" &
          alt.observedUrl & "', so neither is this URL's entry.")
    else:
      return unverifiableManifestCacheRefusal(alt, manifestUrl)

# ---- alternates wiring -----------------------------------------------------

proc gitObjectDir(repoPath: string): string =
  ## Return the object-store dir for ``repoPath`` whether it is a normal
  ## working tree (``<repo>/.git/objects``) or a bare repo
  ## (``<repo>/objects``).
  var gitDir = repoPath / ".git"
  if fileExists(gitDir):
    let text = readFile(gitDir).strip()
    if not text.startsWith("gitdir:"):
      raise newException(IOError, "invalid gitdir file: " & gitDir)
    let target = text["gitdir:".len .. ^1].strip()
    gitDir = if target.isAbsolute: target else: absolutePath(target, absolutePath(repoPath))
  elif not dirExists(gitDir):
    gitDir = repoPath
  if fileExists(gitDir / "commondir"):
    let common = readFile(gitDir / "commondir").strip()
    gitDir = if common.isAbsolute: common else: absolutePath(common, absolutePath(gitDir))
  gitDir / "objects"

proc alternatesFilePath*(repoPath: string): string =
  ## Path of the alternates file for ``repoPath`` (normal or bare).
  gitObjectDir(repoPath) / "info" / "alternates"

proc readAlternatesFile(path: string): seq[string] =
  ## The entries of the alternates file at ``path``, verbatim (empty if the
  ## file is absent). Blank lines are skipped and nothing else is
  ## interpreted, so a caller that rewrites the file keeps every line it did
  ## not change. Raises ``IOError`` when the file exists but cannot be read.
  if not fileExists(path):
    return @[]
  for line in readFile(path).splitLines:
    let trimmed = line.strip()
    if trimmed.len > 0:
      result.add(trimmed)

proc readAlternates*(repoPath: string): seq[string] =
  ## Return the alternates currently wired for ``repoPath`` (empty if the
  ## file is absent). Blank lines are skipped.
  readAlternatesFile(alternatesFilePath(repoPath))

proc resolveAlternateEntry(entry, objectDir: string): string =
  ## The object directory that an entry in ``objectDir``'s alternates file
  ## names. Git resolves a relative entry against the object directory whose
  ## ``info/alternates`` lists it, not against the repository or the working
  ## directory (``parse_alternates`` in git's ``odb.c``).
  if entry.isAbsolute: entry
  else: absolutePath(entry, absolutePath(objectDir))

proc alternateObjectDirs*(leaf: string): seq[string] =
  ## Resolve relative alternates against the object directory, including a
  ## linked worktree's common store. Keep missing targets visible to health.
  let objectDir = gitObjectDir(leaf)
  for entry in readAlternates(leaf):
    result.add(resolveAlternateEntry(entry, objectDir))

const GitMaxAlternateDepth = 5
  ## How deep git follows nested alternates. In git 2.54.0's ``odb.c``,
  ## ``odb_prepare_alternates`` links the primary store's entries at depth 0,
  ## and ``odb_add_alternate_recursively`` follows the ``info/alternates`` of
  ## a store at depth ``d`` only while ``d + 1 <= 5``; past that it reports
  ## "ignoring alternate object stores, nesting too deep". So stores up to
  ## six hops away are part of a repository's object database, and a seventh
  ## is not. Older gits apply the same limit in ``link_alt_odb_entries``
  ## (``if (depth > 5)``, in ``sha1_file.c`` and later ``object-file.c``).
  ## https://github.com/git/git/blob/v2.54.0/odb.c

proc objectStoreIdentity(objectDir: string): string =
  ## The spelling git keys an object store by: its real path, since
  ## ``parse_alternates`` normalises each entry with ``strbuf_realpath``. A
  ## store whose path cannot be resolved keeps its absolute lexical spelling.
  try:
    result = expandFilename(objectDir)
  except OSError:
    result = absolutePath(objectDir)
  while result.len > 1 and result[^1] in {DirSep, AltSep}:
    result.setLen(result.len - 1)

proc linkAlternateStores(objectDir: string; childDepth: int;
                         seen, stores: var seq[string]) =
  ## Append to ``stores`` every store that ``objectDir``'s alternates file
  ## names, each followed by the stores IT borrows from, the way git builds
  ## an object database: depth first, in file order, each store once.
  ##
  ## Mirrors git's rules, so the result is the set of stores git itself
  ## reads. An absent or unreadable ``info/alternates`` contributes nothing
  ## (git warns and carries on, ``odb_source_files_read_alternates``). A
  ## ``#`` line is a comment. An entry naming a missing directory is skipped
  ## (git: "object directory ... does not exist"). A store already linked,
  ## or the primary one, is skipped (``odb_is_source_usable``), and that is
  ## also what makes a cycle terminate. Nesting stops at
  ## ``GitMaxAlternateDepth``. A C-quoted entry is not unquoted, so it is
  ## skipped as a missing directory; git never writes one itself.
  var entries: seq[string]
  try:
    entries = readAlternatesFile(objectDir / "info" / "alternates")
  except IOError, OSError:
    return
  if entries.len > 0 and childDepth > GitMaxAlternateDepth:
    return
  for entry in entries:
    if entry.startsWith("#"):
      continue
    let resolved = resolveAlternateEntry(entry, objectDir)
    if not dirExists(resolved):
      continue
    let store = objectStoreIdentity(resolved)
    if store in seen:
      continue
    seen.add(store)
    stores.add(store)
    linkAlternateStores(store, childDepth + 1, seen, stores)

proc borrowedObjectStores*(repoPath: string): seq[string] =
  ## Every object store ``repoPath`` reads objects from through alternates,
  ## TRANSITIVELY: the stores its own ``objects/info/alternates`` names, the
  ## stores their alternates name, and so on, as git follows them (see
  ## ``linkAlternateStores``). Each is given by its real path, and the
  ## repository's own store is not included. Raises ``IOError`` for an
  ## invalid ``.git`` file, like ``gitObjectDir``.
  let primary = objectStoreIdentity(gitObjectDir(repoPath))
  var seen = @[primary]
  linkAlternateStores(primary, 0, seen, result)

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
  withCheckoutVcsLock(repoPath,
      (block: return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
        diagnostic: "could not lock checkout: " & repoPath))):
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
    return SharedCloneResult(ok: true, sharedBarePath: sharedBarePath,
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
  LeafPoolUploadPack* = "internal shared-pool-upload-pack"
    ## Internal transport role. ``leafPoolUploadPackCommand`` binds this to
    ## the selected repro executable; the old unrestricted lazy upload-pack
    ## command could refill the same history concurrently without negotiation.
  LeafHiddenFetchRefs* = "refs/remotes/"
    ## ``fetch.hideRefs`` in every leaf (§3.5).

proc quotePoolShell(value: string): string =
  ## Git's bundled Windows shell takes POSIX paths and quoting, rather than
  ## cmd.exe's command syntax or the native process argument quoting.
  when defined(windows): quoteShellPosix(value.replace('\\', '/'))
  else: quoteShellPosix(value)

proc leafPoolUploadPackCommand*(): string =
  ## Use the same explicit executable override as managed Git hooks. Library
  ## callers are not necessarily running in the CLI, so getAppFilename() is
  ## not a valid way to select the transport service.
  let override = getEnv("REPROBUILD_REPRO")
  let hint = getEnv("REPRO_SHARED_POOL_CLI")
  let executable = if override.len > 0: override
    elif hint.len > 0: hint
    else: uncontrolledFindExe("repro")
  let resolved = if executable.len == 0: "repro"
    else:
      let found = uncontrolledFindExe(executable)
      if found.len > 0: found else: absolutePath(executable)
  # Git evaluates this configuration through its POSIX shell on Windows too.
  quotePoolShell(resolved) & " " & LeafPoolUploadPack

proc poolReproDir*(pool: string): string = pool / PoolReproDirName
proc borrowersPath*(pool: string): string =
  poolReproDir(pool) / BorrowersFileName
proc retentionHookPath*(pool: string): string =
  poolReproDir(pool) / RetentionHookFileName

proc poolTransportShell(gitBin: string): string =
  ## Use an explicit shell for file redirection. poEvalCommand does not
  ## invoke a shell on Windows, and cmd.exe cannot safely quote arbitrary
  ## paths containing percent signs. Git itself already requires this shell.
  when defined(windows):
    let declared = runGit(gitBin, ["var", "GIT_SHELL_PATH"])
    if declared.code == 0 and fileExists(declared.output.strip()):
      return declared.output.strip()
    # Older Git versions do not expose GIT_SHELL_PATH. Cover the cmd/, bin/
    # and mingw64/libexec/git-core/ executable locations in Git for Windows.
    var directory = absolutePath(gitBin).parentDir
    for depth in 0 .. 3:
      for candidate in [directory / "sh.exe", directory / "bin/sh.exe",
          directory / "usr/bin/sh.exe"]:
        if fileExists(candidate): return candidate
      directory = directory.parentDir
    raise newException(IOError, "could not locate Git's POSIX shell")
  else:
    "/bin/sh"

proc runGitEnv(gitBin: string; args: openArray[string];
               lazyFetch: bool; input = "";
               workingDir = ""; inputFile = "";
               objectDirectory = ""; alternateObjectDirectory = ""):
               tuple[code: int; output: string] =
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
  if inputFile.len > 0:
    var script = quotePoolShell(gitBin)
    for arg in args: script.add(" " & quotePoolShell(arg))
    script.add(" < " & quotePoolShell(inputFile))
    cmd = quoteShellCommand(@[poolTransportShell(gitBin), "-c", script])
  let env = scrubbedGitRepositoryEnv()
  if objectDirectory.len > 0:
    # These are our explicit ingestion store and read-only pool, never the
    # invoking leaf's inherited object-store bindings. Git accepts C-quoted
    # alternate paths, so separators and quotes inside a path stay literal.
    env["GIT_OBJECT_DIRECTORY"] = absolutePath(objectDirectory)
    if alternateObjectDirectory.len > 0:
      var quoted = "\""
      for ch in absolutePath(alternateObjectDirectory):
        case ch
        of '\\', '"': quoted.add('\\'); quoted.add(ch)
        else:
          if ord(ch) < 32 or ord(ch) == 127:
            quoted.add('\\'); quoted.add(toOct(ord(ch), 3))
          else: quoted.add(ch)
      quoted.add('"')
      env["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = quoted
  # Lazy fetching ON is the variable ABSENT, exactly as a user's shell has
  # it, not ``=0``. This exercises the same path as a user's own Git; the
  # pool transport separately disables lazy fetching throughout its service.
  if lazyFetch:
    env.del("GIT_NO_LAZY_FETCH")
  else:
    env["GIT_NO_LAZY_FETCH"] = "1"
  let res = execCmdExCloseOnce(cmd, workingDir = workingDir, env = env,
    input = input)
  (code: res.exitCode, output: res.output)

proc isObjectId(text: string): bool =
  (text.len == 40 or text.len == 64) and
    text.allCharsInSet({'0'..'9', 'a'..'f'})

proc poolObjectKinds(gitBin, pool: string; ids: seq[string]): seq[string] =
  if ids.len == 0: return
  # Use a file for stdin: a batch response can fill the output pipe while
  # its parent is still writing a large checkout's list of wanted IDs.
  let temporary = createTempFile("pool-presence-", ".ids")
  defer: removeFile(temporary.path)
  try:
    temporary.cfile.write(ids.join("\n") & "\n")
  finally:
    temporary.cfile.close()
  let presence = runGitEnv(gitBin, ["--no-replace-objects", "-C", pool,
    "-c", "core.commitGraph=false", "cat-file",
    "--batch-check=%(objectname) %(objecttype)"],
    lazyFetch = false, inputFile = temporary.path)
  if presence.code != 0:
    raise newException(IOError, "could not inspect wanted objects")
  let rows = presence.output.strip().splitLines()
  if rows.len != ids.len:
    raise newException(IOError, "incomplete wanted-object presence response")
  for i, row in rows:
    if row == ids[i] & " missing":
      result.add("missing")
    elif row notin [ids[i] & " commit", ids[i] & " tree",
        ids[i] & " blob", ids[i] & " tag"]:
      raise newException(IOError, "invalid wanted-object presence response")
    else:
      result.add(row.splitWhitespace()[1])

proc absentPoolObjects(gitBin, pool: string; ids: seq[string]): seq[string] =
  for i, kind in poolObjectKinds(gitBin, pool, ids):
    if kind == "missing": result.add(ids[i])

proc presentPoolCommits(gitBin, pool: string; ids: seq[string]): seq[string] =
  var seen = initHashSet[string]()
  for i, kind in poolObjectKinds(gitBin, pool, ids):
    if kind == "commit" and ids[i] notin seen:
      seen.incl(ids[i])
      result.add(ids[i])

proc suppliedCommitTips(gitBin, pool: string; ids: seq[string]): seq[string] =
  result = presentPoolCommits(gitBin, pool, ids)
  let kinds = poolObjectKinds(gitBin, pool, ids)
  for i, kind in kinds:
    if kind == "tag":
      let peeled = runGitEnv(gitBin, ["--no-replace-objects", "-C", pool,
        "-c", "core.commitGraph=false", "rev-parse", "--verify",
        ids[i] & "^{commit}"], lazyFetch = false)
      let id = peeled.output.strip()
      if peeled.code == 0 and isObjectId(id) and id notin result:
        result.add(id)

proc refillTipsPath(pool: string): string = poolReproDir(pool) / "refill-tips"

proc readRefillTips(pool: string): seq[string] =
  let path = refillTipsPath(pool)
  if not fileExists(path) and not dirExists(path): return
  try:
    for line in readFile(path).splitLines():
      if line.len == 0: continue
      if not isObjectId(line):
        raise newException(IOError, "invalid object id in " & path)
      result.add(line)
  except IOError, OSError:
    raise newException(IOError, "could not read refill negotiation tips " &
      path & ": " & getCurrentExceptionMsg())

proc writeRefillTips(pool: string; tips: seq[string]) =
  ## Hints are deliberately outside refs: they neither retain objects for GC
  ## nor change the upstream/ref mirror. The caller holds the pool VCS lock.
  let path = refillTipsPath(pool)
  let temporary = path & ".tmp-" & $getCurrentProcessId()
  try:
    createDir(poolReproDir(pool))
    writeFile(temporary, if tips.len > 0: tips.join("\n") & "\n" else: "")
    moveFile(temporary, path)
  except IOError, OSError:
    if fileExists(temporary): removeFile(temporary)
    raise newException(IOError, "could not write refill negotiation tips " &
      path & ": " & getCurrentExceptionMsg())

proc incompletePoolHistory(gitBin, pool: string; hiddenRefs: HashSet[string];
                           hints: seq[string]; includeRefs = true): HashSet[string] =
  var args = @["--no-replace-objects", "-C", pool, "-c",
    "core.commitGraph=false", "rev-list", "--parents", "--topo-order",
    "--missing=print"]
  if includeRefs:
    args.add("--exclude=HEAD")
    for name in hiddenRefs: args.add("--exclude=" & name)
    args.add("--all")
  args.add(hints)
  let walk = runGitEnv(gitBin, args, lazyFetch = false)
  if walk.code != 0:
    raise newException(IOError, "could not inspect physical negotiation history: " &
      walk.output.strip())
  let rows = walk.output.splitLines()
  result = initHashSet[string]()
  for row in rows:
    if row.startsWith("?") and isObjectId(row[1 .. ^1]):
      result.incl(row[1 .. ^1])
  # Children precede parents in topological order. Reverse it to mark every
  # ref or raw hint which depends on a physically missing ancestor.
  for i in countdown(rows.high, 0):
    let fields = rows[i].splitWhitespace()
    if fields.len == 0 or not isObjectId(fields[0]): continue
    for parent in fields[1 .. ^1]:
      if parent in result:
        result.incl(fields[0])
        break

proc missingWantedAncestors(gitBin, pool: string; incomplete: HashSet[string];
                            tips: seq[string]): seq[string] =
  var required: seq[string]
  for tip in tips:
    if tip in incomplete: required.add(tip)
  if required.len == 0: return
  # Advisory haves must not make an unrelated, otherwise complete read depend
  # on repairing their history. Only wanted commits' ancestors are required.
  let broken = incompletePoolHistory(gitBin, pool, initHashSet[string](),
    required, includeRefs = false)
  var candidates: seq[string]
  for id in broken: candidates.add(id)
  absentPoolObjects(gitBin, pool, candidates)

proc independentRefillTips(gitBin, pool: string; oldTips, newTips: seq[string]):
    seq[string] =
  result = oldTips
  for candidate in newTips:
    if candidate in result: continue
    var kept: seq[string]
    var redundant = false
    var offset = 0
    # The old frontier is already independent. Comparing each new tip with
    # bounded chunks preserves that invariant without unbounded merge-base
    # argv or an ancestry walk on ordinary missing-blob requests.
    while offset < result.len:
      let stop = min(result.len, offset + 128)
      let chunk = result[offset ..< stop]
      let merged = runGitEnv(gitBin, @["--no-replace-objects", "-C", pool,
        "-c", "core.commitGraph=false", "merge-base", "--independent"] &
        chunk & @[candidate], lazyFetch = false)
      if merged.code != 0:
        raise newException(IOError, "could not compact refill negotiation tips: " &
          merged.output.strip())
      let survivors = merged.output.splitWhitespace().toHashSet()
      if candidate notin survivors:
        redundant = true
        break
      for tip in chunk:
        if tip in survivors: kept.add(tip)
      offset = stop
    if not redundant:
      kept.add(candidate)
      result = kept

const
  RefillStageMarkerName = ".repro-refill-stage"
  RefillStageMarker = "reprobuild.pool-refill.v1\n"

proc removeOwnedRefillStage(stage: string) =
  ## Keep the ownership marker until every potentially large payload is gone.
  ## A kill during cleanup must not strand unmarked incoming packs either.
  for kind, child in walkDir(stage):
    if child.lastPathPart == RefillStageMarkerName: continue
    if kind == pcDir: removeDir(child)
    else: removeFile(child)
  let marker = stage / RefillStageMarkerName
  if fileExists(marker): removeFile(marker)
  removeDir(stage)

proc cleanupAbandonedRefillStages(pool: string) =
  ## The caller owns the same pool lock as every active refill, so a marked
  ## direct child here can only belong to a process which has already exited.
  ## Unknown directories and symlinks stay intact, including unreadable magic.
  for kind, stage in walkDir(poolReproDir(pool)):
    if kind != pcDir or not stage.lastPathPart.startsWith("refill-"): continue
    let marker = stage / RefillStageMarkerName
    if not fileExists(marker) or symlinkExists(marker): continue
    var magic: string
    try: magic = readFile(marker)
    except IOError, OSError: continue
    if magic != RefillStageMarker: continue
    try:
      removeOwnedRefillStage(stage)
    except IOError, OSError:
      raise newException(IOError, "could not remove abandoned pool refill stage " &
        stage & ": " & getCurrentExceptionMsg())

proc refillPoolObjects(gitBin, pool: string; args: seq[string];
                       ids: seq[string]): tuple[code: int; output: string] =
  ## Negotiate into a private object store, then publish only genuinely new
  ## objects. Git's negotiation can repeat trees even with correct commit
  ## haves; directly installing its promisor pack would retain those copies.
  ## The caller owns the pool lock throughout. Readers see the original pool
  ## until a complete, self-contained promisor pack becomes visible.
  let originalObjects = absolutePath(gitObjectDir(pool))
  createDir(poolReproDir(pool))
  cleanupAbandonedRefillStages(pool)
  let scratch = createTempDir("refill-", "", poolReproDir(pool))
  defer: removeOwnedRefillStage(scratch)
  writeFile(scratch / RefillStageMarkerName, RefillStageMarker)
  let incomingObjects = absolutePath(scratch / "objects")
  createDir(incomingObjects / "pack")
  # The alternate exists for object lookup, not another source of haves.
  # Discovering its refs would reintroduce this same pool's damaged tips
  # after the caller has deliberately excluded them from negotiation.
  # A trailing space makes Git invoke its shell for the ':' builtin rather
  # than try to execute a file named ':'.
  let fetchArgs = @["-c", "core.alternateRefsCommand=: "] & args
  result = runGitEnv(gitBin, fetchArgs, lazyFetch = false,
    input = ids.join("\n") & "\n", objectDirectory = incomingObjects,
    alternateObjectDirectory = originalObjects)

  # A failed fetch can still have received a valid pack before its
  # connectivity check found damaged old history. Ingest complete objects
  # too, and preserve the fetch status for the caller's recovery decision.
  let format = runGitEnv(gitBin, ["-C", pool, "rev-parse",
    "--show-object-format"], lazyFetch = false)
  if format.code != 0 or format.output.strip() notin ["sha1", "sha256"]:
    raise newException(IOError, "could not identify shared pool object format")
  var incoming: seq[string]
  var seen = initHashSet[string]()
  for index in walkFiles(incomingObjects / "pack/*.idx"):
    let contents = runGitEnv(gitBin, ["-C", pool, "show-index",
      "--object-format=" & format.output.strip()], lazyFetch = false,
      inputFile = index)
    if contents.code != 0:
      raise newException(IOError, "could not enumerate received pool objects: " &
        contents.output.strip())
    for line in contents.output.splitLines():
      if line.len == 0: continue
      let fields = line.splitWhitespace()
      if fields.len < 2 or not isObjectId(fields[1]):
        raise newException(IOError, "invalid received pack index")
      if fields[1] notin seen:
        seen.incl(fields[1])
        incoming.add(fields[1])
  # Current Git keeps filtered transfers in promisor packs. Accept loose
  # arrivals as well without depending on that implementation choice.
  for kind, directory in walkDir(incomingObjects):
    let prefix = directory.lastPathPart
    if kind != pcDir or prefix.len != 2 or
        not prefix.allCharsInSet({'0'..'9', 'a'..'f'}): continue
    for fileKind, path in walkDir(directory):
      let id = prefix & path.lastPathPart
      if fileKind == pcFile and isObjectId(id) and id notin seen:
        seen.incl(id)
        incoming.add(id)
  let missing = absentPoolObjects(gitBin, pool, incoming)
  if missing.len == 0: return
  let idFile = scratch / "missing-objects"
  writeFile(idFile, missing.join("\n") & "\n")
  let prefix = absolutePath(scratch / "compact/pack")
  createDir(prefix.parentDir)
  let packed = runGitEnv(gitBin, ["--no-replace-objects", "-C", pool,
    "pack-objects", "-q", "--no-reuse-delta", "--index-version=2", prefix],
    lazyFetch = false, inputFile = idFile, objectDirectory = incomingObjects,
    alternateObjectDirectory = originalObjects)
  let hash = packed.output.strip()
  if packed.code != 0 or not isObjectId(hash):
    raise newException(IOError, "could not pack new shared pool objects: " &
      packed.output.strip())
  let source = prefix & "-" & hash
  if not fileExists(source & ".pack") or not fileExists(source & ".idx"):
    raise newException(IOError, "new shared pool pack was not produced")
  writeFile(source & ".promisor", "")
  let packDir = originalObjects / "pack"
  createDir(packDir)
  let destination = packDir / ("pack-" & hash)
  for extension in [".pack", ".promisor", ".idx"]:
    if fileExists(destination & extension):
      raise newException(IOError, "refusing to replace an existing shared pool pack")
  var installed: seq[string]
  try:
    # Git discovers packs through their indexes. Publish the promise marker
    # before the index, so no reader sees unmarked partial-clone objects.
    for extension in [".pack", ".promisor", ".idx"]:
      moveFile(source & extension, destination & extension)
      installed.add(destination & extension)
  except CatchableError:
    # Before the index is visible these files cannot have readers. Once it
    # is visible, preserve the pack even if a later check reports failure.
    if not fileExists(destination & ".idx"):
      for path in installed: removeFile(path)
    raise
  if absentPoolObjects(gitBin, pool, missing).len > 0:
    raise newException(IOError, "new shared pool pack did not supply its objects")

proc serveSharedPoolUploadPack*(gitBin, pool: string): int =
  ## Serve the private promisor remote using Git's v0 stateless transport.
  ## Git specifies pkt-line framing and the v0 request grammar in:
  ## https://git-scm.com/docs/gitprotocol-common
  ## https://git-scm.com/docs/gitprotocol-pack
  ## A lazy-fetch client sends no haves: letting upload-pack itself refill a
  ## missing want consequently downloads its entire history with noop
  ## negotiation. Refill explicitly, under the same lock as refresh/gc, before
  ## stock upload-pack sees the request. A second client rechecks presence
  ## after acquiring the lock and cannot write another copy of that history.
  ##
  ## This remote is only for lazy fetches, never a normal refspec fetch. Refuse
  ## interactive have/ACK negotiation immediately rather than waiting for a
  ## client which is itself waiting for our ACK. Git clients which request v2
  ## transparently fall back when the advertisement is v0.
  if gitBin.len == 0:
    stderr.writeLine("repro pool transport: cannot find git")
    return 1
  let env = scrubbedGitRepositoryEnv()
  env.del("GIT_PROTOCOL")
  env["GIT_NO_LAZY_FETCH"] = "1"
  let serviceArgs = @["-c", "uploadpack.allowFilter=true", "-c",
    "uploadpack.allowAnySHA1InWant=true", "upload-pack"]
  try:
    # --advertise-refs never reads stdin. Inherit the client's stdout and
    # stderr directly, avoiding buffering the advertisement or deadlocking on
    # a pool whose warnings fill stderr before stdout reaches EOF.
    var advertised = uncontrolledStartProcess(gitBin, args = serviceArgs &
      @["--advertise-refs", pool], env = env,
      options = {poUsePath, poParentStreams})
    let advertisedCode = advertised.waitForExit()
    advertised.close()
    if advertisedCode != 0: return advertisedCode
    stdout.flushFile()
    var request = ""
    var wants: seq[string]
    var seenWants = initHashSet[string]()
    var flushed = false
    # Git pkt-lines are at most 65520 bytes. Bound the aggregate too so an
    # invalid local client cannot retain arbitrary input in this process.
    const MaxRequestBytes = 256 * 1024 * 1024
    while true:
      var header = newString(4)
      if stdin.readBuffer(addr header[0], 4) != 4:
        raise newException(IOError, "incomplete packet header")
      if not header.allCharsInSet({'0'..'9', 'a'..'f', 'A'..'F'}):
        raise newException(IOError, "invalid packet length")
      let length = parseHexInt(header)
      if length != 0 and (length < 4 or length > 65520):
        raise newException(IOError, "invalid packet length")
      if request.len + max(length, 4) > MaxRequestBytes:
        raise newException(IOError, "request exceeds transport limit")
      request.add(header)
      if length == 0:
        # A client can discover that another borrower has just supplied all
        # its wants after reading the advertisement. Stock upload-pack treats
        # an empty want list as a successful no-op too.
        if wants.len == 0: return 0
        flushed = true
        continue
      var payload = newString(length - 4)
      if payload.len > 0 and
          stdin.readBuffer(addr payload[0], payload.len) != payload.len:
        raise newException(IOError, "incomplete packet payload")
      request.add(payload)
      if payload.strip() == "done" and flushed and wants.len > 0:
        break
      if payload.startsWith("want ") and not flushed:
        let fields = payload.splitWhitespace()
        if fields.len < 2 or not isObjectId(fields[1]):
          raise newException(IOError, "invalid wanted object id")
        if fields[1] notin seenWants:
          seenWants.incl(fields[1])
          wants.add(fields[1])
      elif payload.startsWith("shallow ") and not flushed:
        let fields = payload.splitWhitespace()
        if fields.len != 2 or not isObjectId(fields[1]):
          raise newException(IOError, "invalid shallow boundary object id")
      elif payload.strip() == "filter blob:none" and not flushed:
        discard
      else:
        raise newException(IOError,
          "the pool remote supports only non-negotiating lazy fetches")
    block:
      # A legitimate LLVM refill can outlast the ordinary two-minute VCS
      # deadline. Wait for its owner rather than failing a concurrent read.
      var refillLock = acquireVcsFileLock(cacheEntryLockPath(pool), timeoutMs = -1)
      if not refillLock.acquired:
        raise newException(IOError, "could not lock shared pool")
      defer: releaseVcsFileLock(refillLock)
      let absent = absentPoolObjects(gitBin, pool, wants)
      if absent.len > 0:
        let recordedTips = readRefillTips(pool)
        var hints = presentPoolCommits(gitBin, pool, recordedTips)
        if hints != recordedTips: writeRefillTips(pool, hints)
        var refillArgs = @["-C", pool, "-c",
          "fetch.negotiationAlgorithm=consecutive"]
        let refs = runGitEnv(gitBin, ["-C", pool, "for-each-ref",
          "--format=%(objectname) %(refname)"], lazyFetch = false)
        if refs.code != 0:
          raise newException(IOError, "could not inspect pool negotiation refs")
        var refIds: seq[string]
        var refNames: seq[string]
        for line in refs.output.splitLines():
          let fields = line.splitWhitespace()
          if fields.len == 2 and isObjectId(fields[0]):
            refIds.add(fields[0])
            refNames.add(fields[1])
        let missingRefs = absentPoolObjects(gitBin, pool, refIds).toHashSet()
        var hiddenRefs = initHashSet[string]()
        for i, id in refIds:
          if id in missingRefs:
            hiddenRefs.incl(refNames[i])
            refillArgs.add(["-c", "fetch.hideRefs=" & refNames[i]])
        var fetchArgs = @["fetch", "origin", "--filter=blob:none", "--no-tags",
          "--no-write-fetch-head", "--no-auto-maintenance",
          "--recurse-submodules=no", "--stdin"]
        if hints.len > 0:
          # --negotiation-tip restricts Git's defaults; include ordinary refs
          # as well as raw refilled tips whose objects have no retaining ref.
          fetchArgs.add("--negotiation-tip=*")
          for tip in hints: fetchArgs.add("--negotiation-tip=" & tip)
        proc recoverKnownHistory(incomplete: HashSet[string];
                                 targets: seq[string]): bool =
          var recoveryArgs = @["--no-replace-objects"] & refillArgs &
            @["-c", "core.commitGraph=false"]
          var removedBrokenHave = false
          var safeTips = initHashSet[string]()
          var safeHints: seq[string]
          for tip in hints:
            if tip in incomplete:
              removedBrokenHave = true
            else:
              safeHints.add(tip)
              safeTips.incl(tip)
          if safeHints != hints:
            hints = safeHints
            writeRefillTips(pool, hints)
          for i, id in refIds:
            if refNames[i] in hiddenRefs: continue
            # An annotated (including nested) tag names a tag object, while
            # the ancestry walk reports its peeled commit. Resolve that same
            # commit before deciding whether this ref is a safe have.
            let peeled = runGitEnv(gitBin, ["--no-replace-objects", "-C", pool,
              "-c", "core.commitGraph=false", "rev-parse", "--verify",
              refNames[i] & "^{commit}"], lazyFetch = false)
            if peeled.code != 0 or not isObjectId(peeled.output.strip()):
              continue
            let commit = peeled.output.strip()
            if id in incomplete or commit in incomplete:
              recoveryArgs.add(["-c", "fetch.hideRefs=" & refNames[i]])
              removedBrokenHave = true
            else:
              safeTips.incl(commit)
          if not removedBrokenHave: return false
          if targets.len == 0: return true
          if safeTips.len == 0:
            recoveryArgs.add(["-c", "fetch.negotiationAlgorithm=noop"])
          var recoveryFetchArgs: seq[string]
          for arg in fetchArgs:
            if not arg.startsWith("--negotiation-tip="):
              recoveryFetchArgs.add(arg)
          for tip in safeTips:
            recoveryFetchArgs.add("--negotiation-tip=" & tip)
          let recovered = refillPoolObjects(gitBin, pool,
            recoveryArgs & recoveryFetchArgs, targets)
          if absentPoolObjects(gitBin, pool, targets).len > 0:
            raise newException(IOError, "could not refill shared pool: " &
              recovered.output.strip())
          true
        let refill = refillPoolObjects(gitBin, pool, refillArgs & fetchArgs, absent)
        let remaining = absentPoolObjects(gitBin, pool, absent)
        var newTips = suppliedCommitTips(gitBin, pool, absent)
        if remaining.len > 0 or refill.code != 0:
          # A failed connectivity check may have supplied the requested tip
          # while an older hint still has a hole. Include newly supplied tips
          # in the physical proof and repair the actual missing ancestors too.
          let incomplete = incompletePoolHistory(gitBin, pool, hiddenRefs,
            hints & newTips)
          var targets = missingWantedAncestors(gitBin, pool, incomplete, newTips)
          for id in remaining:
            if id notin targets: targets.add(id)
          let recovered = recoverKnownHistory(incomplete, targets)
          if remaining.len > 0 and not recovered:
            raise newException(IOError, "could not refill shared pool: " &
              refill.output.strip())
        newTips = suppliedCommitTips(gitBin, pool, absent)
        if newTips.len > 0:
          var compacted: seq[string]
          try:
            compacted = independentRefillTips(gitBin, pool, hints, newTips)
          except IOError:
            let incomplete = incompletePoolHistory(gitBin, pool, hiddenRefs,
              hints & newTips)
            let targets = missingWantedAncestors(gitBin, pool, incomplete, newTips)
            if not recoverKnownHistory(incomplete, targets): raise
            compacted = independentRefillTips(gitBin, pool, hints, newTips)
          if compacted != hints or compacted != recordedTips:
            writeRefillTips(pool, compacted)
    # Redirect only stdin while inheriting stdout/stderr. In particular packs
    # stream directly to the client; they are never buffered in Nim memory.
    let temporary = createTempFile("pool-request-", ".pkt")
    let requestFile = temporary.path
    defer: removeFile(requestFile)
    try:
      temporary.cfile.write(request)
    finally:
      temporary.cfile.close()
    var command = quotePoolShell(gitBin)
    for arg in serviceArgs & @["--stateless-rpc", pool]:
      command.add(" " & quotePoolShell(arg))
    command.add(" < " & quotePoolShell(requestFile))
    var served = uncontrolledStartProcess(poolTransportShell(gitBin),
      args = @["-c", command], env = env,
      options = {poUsePath, poParentStreams})
    result = served.waitForExit()
    served.close()
  except CatchableError:
    stderr.writeLine("repro pool transport: " & getCurrentExceptionMsg())
    result = 1

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
  withCacheEntryVcsLock(pool, (block: return false)):
    let entry = canonicalLeafPath(leaf)
    for existing in readBorrowers(pool):
      if samePathOnDisk(existing, entry):
        return true
    try:
      createDir(poolReproDir(pool))
      let f = open(borrowersPath(pool), fmAppend)
      defer: f.close()
      f.write(entry & "\n")
      return true
    except IOError, OSError:
      return false

proc pruneBorrowers*(pool: string): seq[string] =
  ## Remove every registry entry whose path no longer exists or no longer
  ## borrows from ``pool``, and return the removed entries. Those are the
  ## only two reasons an entry ever leaves (§3.2): a leaf that exists and
  ## still borrows stays registered no matter what else is wrong with it.
  withCacheEntryVcsLock(pool, (block: return @[])):
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

# Snapshot the registry for this invocation. Discovery is repeated on every gc.
# Git for Windows accepts forward-slash drive paths; dirname and shell globs
# also need that spelling when Nim wrote native separators to the registry.
tr '\\' '/' < "$registry" > "$work/leaves" || exit 1
[ -s "$work/leaves" ] || exit 1
while IFS= read -r leaf || [ -n "$leaf" ]; do
  [ -n "$leaf" ] || continue
  # A registered leaf may be the workspace checkout itself, or a nested repo.
  # Prefer the workspace's marker; plain-git trees retain the sibling fallback.
  # The settings and state files' RETIRED names mark a workspace here too:
  # repro refuses to work in such a root until it is migrated, but its
  # checkouts still borrow from this pool, and a missed parent means objects
  # they need are not retained.
  workspace=$leaf
  marked=0
  while [ "$workspace" != / ] && [ "$workspace" != . ]; do
    if [ -f "$workspace/repro-workspace.toml" ] ||
       [ -f "$workspace/.repro/workspace-state.toml" ] ||
       [ -f "$workspace/.repro-workspace.toml" ] ||
       [ -f "$workspace/.repro/workspace.toml" ]; then
      dirname "$workspace"
      marked=1
      break
    fi
    ancestor=$(dirname "$workspace")
    [ "$ancestor" != "$workspace" ] || break
    workspace=$ancestor
  done
  [ "$marked" = 1 ] || dirname "$(dirname "$leaf")"
done < "$work/leaves" | sort -u > "$work/parents" || exit 1

# Bound the walk to the sibling-workspace layout, including nested repos and
# .git files (linked worktrees). Do not inspect objects or trigger lazy fetches.
discover_leaf() {
  candidate=$1
  [ -e "$candidate/.git" ] || return 0
  common=$(git -C "$candidate" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  objects="$common/objects"
  # An inaccessible parent makes test -e report absence too. Establish access
  # before interpreting a missing alternates file as a standalone checkout.
  [ -r "$objects" ] && [ -x "$objects" ] || return 1
  if [ -d "$objects/info" ]; then
    [ -r "$objects/info" ] && [ -x "$objects/info" ] || return 1
  fi
  alternates="$objects/info/alternates"
  [ -e "$alternates" ] || return 0
  [ -r "$alternates" ] || return 1
  while IFS= read -r alternate || [ -n "$alternate" ]; do
    [ -n "$alternate" ] || continue
    alternate=$(printf '%s' "$alternate" | tr '\\' '/') || return 1
    case $alternate in /* | [A-Za-z]:/*) ;; *) alternate="$objects/$alternate" ;; esac
    resolved=$(cd "$alternate" && pwd -P) || return 1
    if [ "$resolved" = "$poolobjects" ]; then
      printf '%s\n' "$candidate" >> "$work/found" || return 1
      break
    fi
  done < "$alternates"
}
scan_dir() {
  directory=$1
  depth=$2
  [ -r "$directory" ] && [ -x "$directory" ] || return 1
  discover_leaf "$directory" || return 1
  [ "$depth" -gt 0 ] || return 0
  for child in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
    [ -d "$child" ] || continue
    # A subshell keeps recursive calls from changing this call's variables.
    (scan_dir "$child" "$((depth - 1))") || return 1
  done
}
poolobjects=$(cd "$pool/objects" && pwd -P) || exit 1
: > "$work/found"
while IFS= read -r parent || [ -n "$parent" ]; do
  [ -d "$parent" ] || continue
  [ -r "$parent" ] && [ -x "$parent" ] || exit 1
  for workspace in "$parent"/* "$parent"/.[!.]* "$parent"/..?*; do
    [ -d "$workspace" ] || continue
    (scan_dir "$workspace" 2) || exit 1
  done
done < "$work/parents"
sort -u "$work/found" > "$work/discovered" || exit 1
incomplete=0
while IFS= read -r leaf || [ -n "$leaf" ]; do
  if ! grep -F -x -e "$leaf" "$work/leaves" >/dev/null; then
    # One append per record, matching registerBorrower's append-only protocol.
    printf '%s\n' "$leaf" >> "$registry" || exit 1
    printf '%s\n' "$leaf" >> "$work/leaves" || exit 1
    incomplete=1
  fi
done < "$work/discovered"
if [ "${1-}" = --discover ]; then
  [ "$incomplete" = 0 ] || exit 2
  exit 0
fi

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
done < "$work/leaves"
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
  ## The hook and readiness share one discovery implementation. A newly
  ## found borrower is registered, but this pass still keeps ``never``; only
  ## a later complete pass can enable expiry. Discovery errors fail closed.
  if not gitSupportsRetentionHook(gitBin) or
      not fileExists(retentionHookPath(pool)) or readBorrowers(pool).len == 0:
    return false
  let env = scrubbedGitRepositoryEnv()
  env["PATH"] = gitBin.parentDir & $PathSep & getEnv("PATH")
  let discovered = execCmdExCloseOnce("sh " &
    quoteShell(retentionHookPath(pool)) & " --discover", env = env)
  discovered.exitCode == 0

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

proc commitGraphWriteRefusal(gitBin, repo: string): string =
  ## Git silently skips commit-graph writes for shallow or grafted histories.
  ## Refuse those repositories before expiry rather than trust a successful
  ## exit that can leave a borrower's old split base or a stale pool graph.
  let shallow = runGitEnv(gitBin, ["-C", repo, "rev-parse",
    "--is-shallow-repository"], lazyFetch = false)
  if shallow.code != 0 or shallow.output.strip() != "false":
    return "cannot rebuild the commit-graph in shallow or unreadable repository " &
      repo & ": " & shallow.output.strip()
  let dirs = gitDirOf(gitBin, repo)
  if dirs.commonDir.len == 0:
    return "could not locate the commit-graph directory in " & repo
  if fileExists(dirs.commonDir / "info/grafts"):
    return "cannot rebuild the commit-graph with legacy grafts in " & repo
  ""

proc writeNonSplitCommitGraph(gitBin, repo: string): string =
  ## A non-split write walks reachable objects afresh, including when the old
  ## graph is stale or its split base is missing. ``core.commitGraph=false``
  ## cannot be used here: Git then returns success without writing anything.
  ## Force it on for this explicit write, even if global config disables it.
  let refusal = commitGraphWriteRefusal(gitBin, repo)
  if refusal.len > 0:
    return refusal
  # Git leaves an old graph untouched when there are no reachable commits.
  # That graph may name exactly the objects gc has just expired. A repository
  # without commits reachable from refs needs no commit-graph. Like Git's
  # --reachable writer, exclude a detached HEAD from that set. Disable graph
  # reads for the probe so broken-chain warnings cannot impersonate a commit.
  # Remove both legacy representations when the set is empty.
  let refs = runGitEnv(gitBin, ["--no-replace-objects", "-C", repo,
    "-c", "core.commitGraph=false",
    "rev-list", "--exclude=HEAD", "--all", "--max-count=1"], lazyFetch = false)
  if refs.code != 0:
    return "could not enumerate commits before rebuilding the commit-graph in " &
      repo & ": " & refs.output.strip()
  if refs.output.strip().len == 0:
    let dirs = gitDirOf(gitBin, repo)
    if dirs.commonDir.len == 0:
      return "could not locate the commit-graph directory in " & repo
    let info = dirs.commonDir / "objects/info"
    if fileExists(info / "commit-graph.lock") or
        fileExists(info / "commit-graphs/commit-graph-chain.lock"):
      return "could not remove the empty commit-graph in " & repo &
        ": commit-graph is locked"
    try:
      removeFile(info / "commit-graph")
      if dirExists(info / "commit-graphs"):
        removeDir(info / "commit-graphs")
    except IOError, OSError:
      return "could not remove the empty commit-graph in " & repo & ": " &
        getCurrentExceptionMsg()
    return ""
  let graph = runGitEnv(gitBin, ["--no-replace-objects", "-C", repo,
    "-c", "core.commitGraph=true",
    "commit-graph", "write", "--reachable"], lazyFetch = false)
  if graph.code != 0:
    return "could not rebuild the non-split commit-graph in " & repo &
      " (" & $graph.code & "): " & graph.output.strip()
  let dirs = gitDirOf(gitBin, repo)
  if dirs.commonDir.len == 0 or
      not fileExists(dirs.commonDir / "objects/info/commit-graph") or
      fileExists(dirs.commonDir / "objects/info/commit-graphs/commit-graph-chain"):
    return "git did not create an independent non-split commit-graph in " & repo
  ""

proc migrateLeafCommitGraph(gitBin, leaf: string): string =
  let dirs = gitDirOf(gitBin, leaf)
  if dirs.commonDir.len == 0:
    return "could not locate the shared object directory in " & leaf
  # Do not create a graph on every on-touch configuration. Only a split chain
  # can depend on the pool; an existing monolithic graph is already independent.
  if fileExists(dirs.commonDir / "objects/info/commit-graphs/commit-graph-chain"):
    return writeNonSplitCommitGraph(gitBin, leaf)
  ""

proc leafPoolConfigRows(pool: string): seq[(string, string)] =
  @[("remote." & LeafPoolRemoteName & ".url", poolFileUrl(pool)),
    ("remote." & LeafPoolRemoteName & ".promisor", "true"),
    # Git otherwise records this during the first lazy fetch, so concurrent
    # readers of a newly wired leaf would race for its config.lock.
    ("remote." & LeafPoolRemoteName & ".partialclonefilter", "blob:none"),
    ("remote." & LeafPoolRemoteName & ".uploadpack", leafPoolUploadPackCommand()),
    ("maintenance.auto", "false"),
    ("gc.auto", "0"),
    ("remote." & LeafPoolRemoteName & ".skipFetchAll", "true")]

proc hasPromisorRemoteConfig(gitBin, repo: string): bool =
  ## Whether ``repo``'s effective config names a promisor remote: either
  ## ``extensions.partialClone`` (which makes the remote it names one) or any
  ## ``remote.<name>.promisor=true``. These are the settings under which git
  ## fetches a missing object on demand instead of failing on it.
  let extension = runGit(gitBin, ["-C", repo, "config", "--get",
    "extensions.partialClone"])
  if extension.code == 0 and extension.output.strip().len > 0:
    return true
  let promisors = runGit(gitBin, ["-C", repo, "config", "--bool",
    "--get-regexp", "^remote\\..*\\.promisor$"])
  if promisors.code == 0:
    for line in promisors.output.splitLines():
      if line.strip().endsWith(" true"): return true
  false

proc hasPromisorPacks(objectDir: string): bool =
  ## Whether ``objectDir`` holds a pack received from a promisor remote: a
  ## ``*.promisor`` file beside it marks every object it does not contain
  ## but references as promised rather than missing.
  let packDir = objectDir / "pack"
  if dirExists(packDir):
    for _ in walkFiles(packDir / "*.promisor"):
      return true
  false

proc repoIsPartialClone*(gitBin, repo: string): bool =
  ## Whether ``repo`` may advertise objects it only promises, so that a
  ## repository borrowing from it can "have" a commit whose blobs are absent.
  ##
  ## Config is the usual signal, but not the only one: a ``*.promisor`` file
  ## beside a pack marks that pack as received from a promisor remote, and it
  ## stays there after the config that made the remote a promisor is edited
  ## away. A foreign cache (one another tool made, outside reprobuild's cache
  ## root) may show only that file, so it counts too.
  if hasPromisorRemoteConfig(gitBin, repo):
    return true
  var objectDir = ""
  try:
    objectDir = gitObjectDir(repo)
  except IOError:
    return false
  hasPromisorPacks(objectDir)

proc objectStoreIsPartial*(gitBin, objectDir: string): bool =
  ## ``repoIsPartialClone`` for an object store reached through alternates,
  ## which may belong to a bare repository (``<pool>.git/objects``) or to a
  ## non-bare one's ``.git`` directory (``<checkout>/.git/objects``).
  ##
  ## The ``*.promisor`` packs are the store's own signal. The config signal
  ## is read from the repository that owns the store, its parent directory,
  ## and only when that directory is a git directory (it has ``HEAD``):
  ## ``git -C`` on any other directory would discover and answer for some
  ## unrelated enclosing repository.
  if hasPromisorPacks(objectDir):
    return true
  let owner = objectDir.parentDir
  objectDir.lastPathPart == "objects" and fileExists(owner / "HEAD") and
    hasPromisorRemoteConfig(gitBin, owner)

proc needsLeafRefetchChain(gitBin, leaf, pool: string): bool =
  ## Ref-tip presence cannot detect missing blobs below present commits.
  ## Inspect the actual chain before on-touch configuration repairs it.
  if not repoIsPartialClone(gitBin, pool): return false
  for (key, value) in leafPoolConfigRows(pool):
    let current = runGit(gitBin, ["-C", leaf, "config", "--local",
      "--get-all", key])
    if current.code != 0 or current.output.strip() != value: return true
  runGit(gitBin, ["-C", leaf, "config", "--local", "--get-all",
    "remote." & LeafPoolRemoteName & ".fetch"]).code == 0

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
  let selectedOverride = getEnv("REPROBUILD_REPRO")
  if selectedOverride.len > 0 and uncontrolledFindExe(selectedOverride).len == 0:
    return "cannot install refetch chain: REPROBUILD_REPRO is not executable: " &
      selectedOverride
  var failedKeys: seq[string]
  for (key, value) in leafPoolConfigRows(pool):
    let current = runGit(gitBin, ["-C", leaf, "config", "--local", "--get-all", key])
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
    if runGit(gitBin, ["-C", leaf, "config", "--local", "--unset-all",
        fetchKey]).code != 0:
      failedKeys.add(fetchKey)
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
  migrateLeafCommitGraph(gitBin, leaf)

proc poolsOfLeaf*(leaf: string; cacheRoot = ""): seq[string] =
  ## The pools ``leaf`` borrows from: every alternates entry whose parent is
  ## a bare repository, restricted to ``cacheRoot`` when one is given (the
  ## detector only ever writes into pools reprobuild owns).
  for objects in alternateObjectDirs(leaf):
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

proc leafFetchNeedsPromisor*(gitBin, leaf: string): bool =
  ## Whether a ``git fetch`` in ``leaf`` needs a promisor remote it does not
  ## have, from which to fetch a thin pack's missing delta bases.
  ##
  ## A server answers a fetch with a THIN pack: it may send an object as a
  ## delta against a base the client said it has. A leaf says it has every
  ## commit its alternates reach, but when the repository behind an
  ## alternate is a partial clone, the blobs of those commits may only be
  ## promised. ``index-pack`` then cannot resolve the delta ("unresolved
  ## deltas left after unpacking") unless the leaf has a promisor remote to
  ## fetch the base from.
  ##
  ## True when ANY object store in the leaf's object database is a partial
  ## clone's (``objectStoreIsPartial``) and the leaf's own config names no
  ## promisor remote. The stores are those git itself reads, so the walk is
  ## transitive (``borrowedObjectStores``): a leaf whose alternate is a full
  ## repository that in turn borrows from a ``blob:none`` one advertises that
  ## one's commits too, and is in the same position as a direct leaf of it.
  ## Owned or foreign, bare or a non-bare ``.git`` directory, all count. A
  ## leaf carrying the §3.4 refetch chain (``remote.repro-pool.promisor=
  ## true``) answers false: the chain already supplies a missing base
  ## through the pool.
  ##
  ## Failing safe means answering false, i.e. running the fetch exactly as
  ## before this check existed: for an unreadable ``.git`` file (the fetch
  ## itself reports it), and for an alternates file anywhere in the chain
  ## that cannot be read. The latter contributes no stores, which is not a
  ## guess: git skips such a file too, so the stores beyond it are not in
  ## the leaf's object database and their commits are not advertised. Every
  ## other branch of the chain is still evaluated.
  var stores: seq[string]
  try:
    stores = borrowedObjectStores(leaf)
  except IOError, OSError:
    return false
  for store in stores:
    if objectStoreIsPartial(gitBin, store):
      return not hasPromisorRemoteConfig(gitBin, leaf)
  false

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

proc displayPoolPath*(pool: string): string =
  ## The pool path for prose (never pasted): ``~`` for the home directory.
  ## Exported so tests that pin a message build it with the same rule.
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
  withCheckoutVcsLock(leaf,
      (block: return LeafCheckReport(leaf: leaf, pool: pool,
        diagnostic: "could not lock checkout: " & leaf))):
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

    let missingChain = needsLeafRefetchChain(gitBin, leaf, thePool)
    # §4.3 self-registration precedes presence probes even when every ref
    # tip exists: missing blobs are healed on subsequent reads, not by an
    # expensive eager walk of every tree.
    result.registered = registerBorrower(thePool, leaf)
    let configured = ensureLeafPoolConfig(gitBin, leaf, thePool)
    result.configured = configured.len == 0
    if configured.len > 0:
      result.diagnostic = configured
    if missingChain:
      result.findings.add(LeafFinding(kind: lfkRefetchChainMissing,
        message: "repro: " & displayPath(leaf) &
          ": missing or incorrect refetch chain to partial shared clone " &
          displayPath(thePool) & ". " &
          (if result.configured: "Installed on touch; missing blobs can now be fetched on read."
           else: configured & ". Repair with: repro health --fix")))

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
  withCheckoutVcsLock(leaf, (block: return "could not lock checkout: " & leaf)):
    if not registerBorrower(pool, leaf):
      return "could not register " & leaf & " in " & borrowersPath(pool)
    return ensureLeafPoolConfig(gitBin, leaf, pool)

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
  @["-C", repoPath, "push", "--no-thin", "--force", "--no-verify", plan.destination,
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
  withCacheEntryVcsLock(sharedBarePath,
      (block: return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
        diagnostic: "could not lock shared bare: " & sharedBarePath))):
    # Thin-pack delta selection can read a promised old blob in the sender,
    # recursively entering this pool's transport while we hold its lock.
    # Send a self-contained pack and disable all lazy fetches in this locked
    # best-effort operation. Unexpected missing history then refuses the cache
    # push rather than waiting on the lock its own parent holds.
    let res = runGitEnv(gitBin, argv, lazyFetch = false)
    if res.code != 0:
      return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
        diagnostic: "cache-ref push failed (" & $res.code & "): " &
          res.output.strip())
    return SharedCloneResult(ok: true, sharedBarePath: sharedBarePath)

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
  withCacheEntryVcsLock(barePath,
      (block: return MaintenanceResult(ok: false, sharedBarePath: barePath,
        diagnostic: "could not lock shared bare: " & barePath))):
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
    # Old leaves may have chained onto the pool's split layers. Convert all
    # registered leaves before gc can expire anything or the pool's graph write
    # removes those layers. A failed migration must leave object retention intact.
    let borrowers = readBorrowers(barePath)
    for leaf in borrowers:
      let migrated = ensureLeafPoolConfig(gitBin, leaf, barePath)
      if migrated.len > 0:
        result.ok = false
        result.diagnostic = migrated & "; gc skipped before borrower graph migration"
        result.looseAfter = result.looseBefore
        return
    let preserveLegacyChain = borrowers.len == 0 and fileExists(
      barePath / "objects/info/commit-graphs/commit-graph-chain")
    if not preserveLegacyChain:
      let refusal = commitGraphWriteRefusal(gitBin, barePath)
      if refusal.len > 0:
        result.ok = false
        result.looseAfter = result.looseBefore
        result.diagnostic = refusal & "; gc skipped before pool graph rebuild"
        return
    let packDir = barePath / "objects/pack"
    let hadMultiPackIndex = fileExists(packDir / "multi-pack-index") or
      dirExists(packDir / "multi-pack-index.d")
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
    # gc deliberately leaves graph writes disabled. Rebuild explicitly, after
    # expiry, so no cached graph can still name a commit gc just removed.
    # With no registered borrowers expiry is disabled. Preserve a legacy split
    # graph: unknown borrowers may still chain onto it and cannot be migrated.
    let graphFault = if preserveLegacyChain: "" else:
      writeNonSplitCommitGraph(gitBin, barePath)
    if graphFault.len > 0:
      result.ok = false
      result.ran = true
      result.looseAfter = looseObjectCount(gitBin, barePath)
      result.diagnostic = graphFault
      return
    if hadMultiPackIndex:
      let midx = runGitEnv(gitBin, ["-C", barePath, "multi-pack-index", "write"],
        lazyFetch = false)
      if midx.code != 0:
        result.ok = false
        result.ran = true
        result.looseAfter = looseObjectCount(gitBin, barePath)
        result.diagnostic = "could not rebuild the multi-pack-index in " &
          barePath & " (" & $midx.code & "): " & midx.output.strip()
        return
    result.ran = true
    result.looseAfter = looseObjectCount(gitBin, barePath)
    touchMaintenanceStamp(barePath)

# ---- inspection (the `shared-clones list` surface) -------------------------

proc inspectSharedBareVerdict*(barePath: string): string =
  ## Directly inspect the bare repository's git config at ``barePath / "config"``
  ## without spawning git subprocesses.
  ##
  ## Verdicts:
  ##   - "no-bare" when not looksLikeGitDir(barePath) or config does not exist
  ##   - "ok" when both the fetch refspec and all safety keys are present
  ##   - "refspec-without-safety" when refspec is present but safety keys are not
  ##   - "safety-without-refspec" when safety keys are present but refspec is not
  ##   - "unconfigured" when neither is present
  if not looksLikeGitDir(barePath):
    return "no-bare"
  let configPath = barePath / "config"
  if not fileExists(configPath):
    return "no-bare"

  var content: string
  try:
    content = readFile(configPath)
  except CatchableError:
    return "no-bare"

  var currentSection = ""
  var fetchValues: seq[string] = @[]
  var gcAuto = ""
  var maintAuto = ""
  var maintStrategy = ""
  var gcWriteCommitGraph = ""
  var fetchWriteCommitGraph = ""
  var gcPruneExpire = ""

  for rawLine in content.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#") or line.startsWith(";"):
      continue
    if line.startsWith("[") and line.endsWith("]"):
      let inside = line[1 .. ^2].strip()
      let quoteStart = inside.find('"')
      if quoteStart >= 0:
        let quoteEnd = inside.rfind('"')
        let sec = inside[0 ..< quoteStart].strip().toLowerAscii
        let subsec = if quoteEnd > quoteStart:
                       inside[quoteStart + 1 ..< quoteEnd]
                     else:
                       inside[quoteStart + 1 .. ^1]
        currentSection = sec & "." & subsec.toLowerAscii
      else:
        currentSection = inside.toLowerAscii
    else:
      let eqIdx = line.find('=')
      if eqIdx >= 0:
        let k = line[0 ..< eqIdx].strip().toLowerAscii
        var v = line[eqIdx + 1 .. ^1].strip()
        var commentIdx = -1
        for i in 0 ..< v.len:
          if (v[i] == '#' or v[i] == ';') and i > 0 and v[i - 1] in Whitespace:
            commentIdx = i
            break
        if commentIdx >= 0:
          v = v[0 ..< commentIdx].strip()
        if v.len >= 2 and v.startsWith("\"") and v.endsWith("\""):
          v = v[1 .. ^2]
        let fullKey = if currentSection.len > 0: currentSection & "." & k else: k
        case fullKey
        of "remote.origin.fetch":
          fetchValues.add(v)
        of "gc.auto":
          gcAuto = v
        of "maintenance.auto":
          maintAuto = v
        of "maintenance.strategy":
          maintStrategy = v
        of "gc.writecommitgraph":
          gcWriteCommitGraph = v
        of "fetch.writecommitgraph":
          fetchWriteCommitGraph = v
        of "gc.pruneexpire":
          gcPruneExpire = v
        else:
          discard

  var hasRefspec = false
  for f in fetchValues:
    if f == SharedBareFetchRefspec or f.contains(SharedBareFetchRefspec):
      hasRefspec = true
      break

  let hasSafety = gcAuto == "0" and
    maintAuto.toLowerAscii == "false" and
    maintStrategy.toLowerAscii == "none" and
    gcWriteCommitGraph.toLowerAscii == "false" and
    fetchWriteCommitGraph.toLowerAscii == "false" and
    gcPruneExpire.len > 0 and gcPruneExpire.toLowerAscii != "now"

  if hasRefspec and hasSafety:
    "ok"
  elif hasRefspec and not hasSafety:
    "refspec-without-safety"
  elif not hasRefspec and hasSafety:
    "safety-without-refspec"
  else:
    "unconfigured"

# ---- whole-cache sweep (``shared-clones gc`` / ``rewire``) -----------------

type
  SharedBareSweepEntry* = object
    path*: string
    before*: string
      ## ``inspectSharedBareVerdict`` as found, recorded before anything was
      ## written, so a repair never erases the evidence of what it repaired.
    after*: string
    repaired*: bool
    diagnostic*: string

proc sharedBareLastFetch*(barePath: string): string =
  ## UTC time of the bare's last fetch (``FETCH_HEAD``'s mtime), or "" when
  ## nothing has ever fetched into it. Next to the config verdict it makes a
  ## pool frozen at its clone-time tips visible rather than inferred.
  let fetchHead = barePath / "FETCH_HEAD"
  if fileExists(fetchHead):
    try:
      return getLastModificationTime(fetchHead).utc.format(
        "yyyy-MM-dd'T'HH:mm:ss'Z'")
    except OSError:
      discard
  ""

proc findSharedBares*(cacheRoot: string): seq[string] =
  ## Every bare repository under ``cacheRoot``, declared by an enabled project
  ## or not. Descends until it meets a git directory and never below one; a
  ## non-bare checkout found in the cache is not a pool and is skipped.
  if cacheRoot.len == 0 or not dirExists(cacheRoot):
    return
  var stack = @[cacheRoot]
  while stack.len > 0:
    let dir = stack.pop()
    for kind, entry in walkDir(dir):
      if kind != pcDir:
        continue
      if dirExists(entry / "objects") and dirExists(entry / "refs") and
          fileExists(entry / "HEAD"):
        result.add(entry)
      elif dirExists(entry / ".git"):
        continue
      else:
        stack.add(entry)

proc sweepSharedBares*(gitBin, cacheRoot: string): seq[SharedBareSweepEntry] =
  ## The EAGER half of the pool migration. ``prepareSharedBare`` runs only on
  ## the bares a refresh touches, so a property installed that way converges
  ## "as repos happen to be synced" and is never checkably true of the cache:
  ## a bare no enabled project declares is never visited at all. This visits
  ## every bare under ``cacheRoot``, records its verdict, and installs the
  ## refspec and the borrower-safety config where either is missing --
  ## through ``prepareSharedBare``, so the safety-before-refspec order holds
  ## here too. Each entry carries the verdict found BEFORE the repair.
  for bare in findSharedBares(cacheRoot):
    let before = inspectSharedBareVerdict(bare)
    var entry = SharedBareSweepEntry(path: bare, before: before, after: before)
    if before == "no-bare":
      entry.diagnostic = "could not read the config of " & bare
    elif before != "ok":
      let prepared = prepareSharedBare(gitBin, bare)
      entry.after = inspectSharedBareVerdict(bare)
      entry.repaired = prepared.len == 0 and entry.after == "ok"
      if prepared.len > 0:
        entry.diagnostic = prepared
    result.add(entry)

type
  SharedCloneRepoInfo* = object
    ## Per-repo wiring view used by ``repro workspace shared-clones list``.
    path*: string
    fetchUrl*: string
    sharedBarePath*: string
    barePresent*: bool
    wired*: bool
    verdict*: string


proc sameObjectDirectory(a, b: string): bool =
  ## Existing stores have filesystem identity: a symlink spelling is not a
  ## foreign pool. Missing stores still need the lexical comparison so health
  ## can name them instead of silently omitting their borrowers.
  if dirExists(a) and dirExists(b):
    try:
      return sameFile(a, b)
    except OSError:
      discard
  samePathOnDisk(a, b)

proc borrowsFromPool*(leaf, canonicalPool: string): bool =
  ## Whether any resolved alternate names this object store, including relative
  ## entries and symlink aliases. Share the classifier with foreign detection:
  ## otherwise health can skip a canonical leaf while reporting it as healthy.
  for objects in alternateObjectDirs(leaf):
    if sameObjectDirectory(objects, canonicalPool / "objects"):
      return true
  false

proc foreignAlternates*(leaf, canonicalPool: string): seq[string] =
  ## A former URL key in our own cache is foreign just like another tool's
  ## cache. Only this manifest URL's canonical objects directory is retained.
  for objects in alternateObjectDirs(leaf):
    if not sameObjectDirectory(objects, canonicalPool / "objects"):
      result.add(objects)

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
    wired: borrowsFromPool(repoAbs, bare),
    verdict: inspectSharedBareVerdict(bare))

proc leafConnectivityDiagnostic*(gitBin, leaf: string; full = false): string =
  ## Observation only: no registration, configuration, lazy fetch or repair.
  ## fsck includes dangling symbolic refs, which for-each-ref silently omits.
  let checked = runGitEnv(gitBin, ["-C", leaf, "fsck",
    (if full: "--full" else: "--connectivity-only")], lazyFetch = false)
  if checked.code != 0 or "warning:" in checked.output or
      "error:" in checked.output:
    return checked.output.strip()
  ""

proc leafMissingObjects(gitBin, leaf, commonDir: string): tuple[missing: seq[string], diagnostic: string] =
  # Promisor fsck deliberately tolerates missing objects. Traverse explicitly
  # instead: retiring a promisor remote must not silently lose readable data.
  var args = @["-C", leaf, "rev-list", "--objects", "--all", "--reflog",
    "--indexed-objects", "--no-object-names", "--missing=print"]
  for target in listLeafTargets(gitBin, leaf, commonDir):
    args.add(target.id)
  let walked = runGitEnv(gitBin, args, lazyFetch = false)
  if walked.code != 0:
    result.diagnostic = walked.output.strip()
    return
  for line in walked.output.splitLines():
    if line.startsWith("?"):
      result.missing.add(line[1 .. ^1].strip())

proc consolidateLeafPool*(gitBin, leaf, canonicalPool: string): SharedCloneResult =
  ## Materialize the leaf before retiring any of its alternate stores. This
  ## never prunes a shared pool or deletes a ref. A replacement graph is built
  ## as a non-split file with NO alternates, so it is entirely local. Until final
  ## verification succeeds the original wiring/config/graphs are rollback state.
  result.sharedBarePath = canonicalPool
  let (_, commonDir) = gitDirOf(gitBin, leaf)
  if commonDir.len == 0:
    result.diagnostic = "not a git checkout: " & leaf
    return
  var lock = acquireVcsFileLock(checkoutLockPath(leaf))
  if not lock.acquired:
    result.diagnostic = "could not lock checkout: " & leaf
    return
  defer: releaseVcsFileLock(lock)
  let altPath = alternatesFilePath(leaf)
  let hadAlt = fileExists(altPath)
  let configPath = commonDir / "config"
  let graphDir = commonDir / "objects/info/commit-graphs"
  let graphFile = commonDir / "objects/info/commit-graph"
  let backupSuffix = ".repro-consolidate-backup"
  let savedDir = graphDir & backupSuffix
  let savedFile = graphFile & backupSuffix
  var oldAlt, oldConfig: string
  var changedAlt, changedConfig, movedDir, movedFile, replacedGraph: bool
  try:
    oldAlt = if hadAlt: readFile(altPath) else: ""
    oldConfig = readFile(configPath)
    if dirExists(savedDir) or fileExists(savedFile):
      result.diagnostic = "previous consolidation graph backup exists; inspect " & savedDir
      return
    # Refuse existing corruption before modifying the leaf's metadata. In
    # particular no repair is permitted to erase a dangling symbolic ref.
    let before = leafConnectivityDiagnostic(gitBin, leaf, full = true)
    if before.len > 0:
      result.diagnostic = "consolidation refused: " & before
      return
    if not dirExists(canonicalPool / "objects") or
        not registerBorrower(canonicalPool, leaf):
      result.diagnostic = "cannot register checkout with canonical pool " & canonicalPool
      return
    var recoveryUrls: seq[string]
    # rewire may already have repointed repro-pool. Read the former pools'
    # upstream URLs, then fetch directly INTO THE LEAF, never into a foreign
    # bare whose gc/retention policy this process does not own.
    for objects in alternateObjectDirs(leaf):
      let origin = runGit(gitBin,
        ["-C", objects.parentDir, "config", "--get", "remote.origin.url"])
      let url = origin.output.strip()
      if origin.code == 0 and url.len > 0 and url notin recoveryUrls:
        recoveryUrls.add(url)
    # Hydrate promised objects while the old refetch chain is still usable.
    # Each pass can reveal deeper missing trees; stop when a pass cannot heal
    # an object, rather than trusting fsck's intentional promisor omissions.
    while true:
      let walked = leafMissingObjects(gitBin, leaf, commonDir)
      if walked.diagnostic.len > 0:
        result.diagnostic = "consolidation object traversal failed: " & walked.diagnostic
        return
      if walked.missing.len == 0: break
      for id in walked.missing:
        if refill(gitBin, leaf, id): continue
        var recovered = false
        for url in recoveryUrls:
          discard runGitEnv(gitBin,
            ["-C", leaf, "-c", "gc.auto=0", "-c", "maintenance.auto=false",
            "-c", "fetch.writeCommitGraph=false", "fetch", "--no-tags",
            "--no-write-fetch-head", "--no-auto-maintenance",
            "--no-recurse-submodules", url, id], lazyFetch = false)
          if objectPresent(gitBin, leaf, id):
            recovered = true
            break
        if not recovered:
          result.diagnostic = "consolidation cannot materialize promised object " & id
          return
    # No --local: objects borrowed from every old pool must be copied. Normal
    # repack retains reflog and linked-worktree roots as well as all refs.
    let packed = runGitEnv(gitBin,
      ["-C", leaf, "-c", "gc.auto=0", "repack", "-a", "-d"], lazyFetch = false)
    if packed.code != 0:
      result.diagnostic = "consolidation repack failed: " & packed.output.strip()
      return
    changedAlt = true
    writeFile(altPath, "")
    # Checking without ANY alternate also prevents a promised foreign-only
    # object being mistaken for one supplied by the canonical pool.
    let targets = listLeafTargets(gitBin, leaf, commonDir)
    for target in targets:
      if not objectPresent(gitBin, leaf, target.id):
        result.diagnostic = "consolidation did not materialize " & target.refName & " " & target.id
        return
    let materialized = leafMissingObjects(gitBin, leaf, commonDir)
    if materialized.diagnostic.len > 0 or materialized.missing.len > 0:
      result.diagnostic = "consolidation left missing local objects: " &
        materialized.diagnostic & " " & materialized.missing.join(", ")
      return
    if dirExists(graphDir):
      moveDir(graphDir, savedDir)
      movedDir = true
    if fileExists(graphFile):
      moveFile(graphFile, savedFile)
      movedFile = true
    replacedGraph = true
    let graphFault = writeNonSplitCommitGraph(gitBin, leaf)
    if graphFault.len > 0:
      result.diagnostic = "consolidation graph rebuild failed: " & graphFault
      return
    let disconnected = leafConnectivityDiagnostic(gitBin, leaf, full = true)
    if disconnected.len > 0:
      result.diagnostic = "consolidation verification failed: " & disconnected
      return
    writeFile(altPath, canonicalPool / "objects" & "\n")
    changedConfig = true
    let configured = ensureLeafPoolConfig(gitBin, leaf, canonicalPool)
    if configured.len > 0:
      result.diagnostic = configured
      return
    let verified = leafConnectivityDiagnostic(gitBin, leaf, full = true)
    if verified.len > 0:
      result.diagnostic = "consolidation verification failed: " & verified
      return
    result.ok = true
  except CatchableError as error:
    result.diagnostic = "consolidation failed: " & error.msg
  finally:
    if not result.ok:
      try:
        if changedAlt:
          if hadAlt: writeFile(altPath, oldAlt)
          elif fileExists(altPath): removeFile(altPath)
        if changedConfig: writeFile(configPath, oldConfig)
        if replacedGraph:
          if dirExists(graphDir): removeDir(graphDir)
          if fileExists(graphFile): removeFile(graphFile)
        if movedDir: moveDir(savedDir, graphDir)
        if movedFile: moveFile(savedFile, graphFile)
      except CatchableError as error:
        result.diagnostic.add("; rollback failed: " & error.msg)
    else:
      if movedDir: removeDir(savedDir)
      if movedFile: removeFile(savedFile)

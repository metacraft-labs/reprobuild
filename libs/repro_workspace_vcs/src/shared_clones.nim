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
##     (``git fetch --all --prune``).
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

import std/[os, osproc, strutils, times]

import git_tool

const
  AlternatesRelPath* = "objects/info/alternates"
    ## Path, relative to a git object-store root, of the alternates file
    ## git reads to discover additional read-only object pools.

type
  SharedCloneResult* = object
    ## Outcome of a best-effort shared-clone / alternates operation. The
    ## caller inspects ``ok`` to decide whether to fall back to a plain
    ## standalone clone. ``diagnostic`` carries the human-facing reason on
    ## failure (empty on success).
    ok*: bool
    sharedBarePath*: string
    diagnostic*: string

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
  let normalized = normalizeFetchUrl(url)
  var host = ""
  var path = ""

  if normalized.contains("://"):
    # scheme://[user@]host[:port]/path
    let afterScheme = normalized[normalized.find("://") + 3 .. ^1]
    let firstSlash = afterScheme.find('/')
    if firstSlash < 0:
      host = afterScheme
      path = ""
    else:
      host = afterScheme[0 ..< firstSlash]
      path = afterScheme[firstSlash + 1 .. ^1]
    # strip user@ and :port from the authority
    let at = host.find('@')
    if at >= 0: host = host[at + 1 .. ^1]
    let colon = host.find(':')
    if colon >= 0: host = host[0 ..< colon]
    if host.len == 0:
      # file:///abs/path → empty authority; treat as a local path.
      host = "_local_"
  elif normalized.contains('@') and normalized.contains(':') and
      not normalized.startsWith('/'):
    # scp-like syntax: [user@]host:path
    let at = normalized.find('@')
    let rest = if at >= 0: normalized[at + 1 .. ^1] else: normalized
    let colon = rest.find(':')
    host = rest[0 ..< colon]
    path = rest[colon + 1 .. ^1]
  else:
    # bare local path
    host = "_local_"
    path = normalized

  var segments: seq[string]
  if host.len > 0:
    segments.add(sanitizeSlugSegment(host))
  for raw in path.split('/'):
    if raw.len == 0: continue
    segments.add(sanitizeSlugSegment(raw))
  if segments.len == 0:
    segments.add("_empty_")
  result = segments.join("/") & ".git"

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
  ## for. Tracked as W8-R3 in
  ## ``Windows-Cacheable-Builds-Session-Residuals.milestones.org``.
  cacheRoot / urlSlug(manifestUrl)

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

proc refreshSharedBare*(gitBin, cacheRoot, fetchUrl: string): SharedCloneResult =
  ## Clone-if-missing / fetch-if-present the shared bare for ``fetchUrl``.
  ## Returns ``ok = true`` with the bare path populated, or ``ok = false``
  ## with a diagnostic on any failure (the caller then falls back to a
  ## standalone clone). This is the single shared-state write per unique
  ## URL; per RA-5c it is done once up front before per-repo clones fan
  ## out, so concurrent clones read a consistent pool without racing.
  let bare = sharedBarePath(cacheRoot, fetchUrl)
  if looksLikeGitDir(bare):
    # fetch-if-present: refresh all refs, prune deleted ones.
    let res = runGit(gitBin,
      ["-C", bare, "fetch", "--all", "--prune", "--quiet"])
    if res.code != 0:
      return SharedCloneResult(ok: false, sharedBarePath: bare,
        diagnostic: "git fetch in shared bare failed (" & $res.code & "): " &
          res.output.strip())
    return SharedCloneResult(ok: true, sharedBarePath: bare)

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
  SharedCloneResult(ok: true, sharedBarePath: bare)

# ---- bootstrap manifest cache population (RA-11) ---------------------------

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
  let target = manifestCachePath(cacheRoot, manifestUrl)
  if looksLikeGitDir(target):
    # fetch-if-present, then fast-forward the checked-out branch so the
    # cached manifest reflects upstream. Best-effort: a fetch failure
    # leaves the existing (possibly stale) checkout usable.
    let fetched = runGit(gitBin, ["-C", target, "fetch", "--quiet",
      "--prune", "origin"])
    if fetched.code != 0:
      return SharedCloneResult(ok: true, sharedBarePath: target,
        diagnostic: "manifest cache fetch failed (using existing checkout): " &
          fetched.output.strip())
    let curRes = runGit(gitBin,
      ["-C", target, "rev-parse", "--abbrev-ref", "HEAD"])
    let cur = if curRes.code == 0: curRes.output.strip() else: ""
    if cur.len > 0 and cur != "HEAD":
      discard runGit(gitBin, ["-C", target, "merge", "--ff-only", "--quiet",
        "refs/remotes/origin/" & cur])
    return SharedCloneResult(ok: true, sharedBarePath: target)

  let parent = target.splitPath.head
  if parent.len > 0:
    try:
      createDir(parent)
    except OSError as e:
      return SharedCloneResult(ok: false, sharedBarePath: target,
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
      diagnostic: "git clone of manifest repo into cache failed (" &
        $res.code & "): " & res.output.strip())
  SharedCloneResult(ok: true, sharedBarePath: target)

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

proc wireAlternates*(repoPath, sharedBarePath: string): SharedCloneResult =
  ## Idempotently wire ``repoPath`` to read objects from the shared bare's
  ## ``objects/`` dir via ``objects/info/alternates``. Safe to call on an
  ## already-wired repo (the entry is added only if absent). Best-effort:
  ## returns ``ok = false`` with a diagnostic on any IO failure so the
  ## caller can fall back.
  let sharedObjects = sharedBarePath / "objects"
  if not dirExists(sharedObjects):
    return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
      diagnostic: "shared bare has no objects dir: " & sharedObjects)
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
  SharedCloneResult(ok: true, sharedBarePath: sharedBarePath)

proc isWiredTo*(repoPath, sharedBarePath: string): bool =
  ## True when ``repoPath`` already reads the shared bare via alternates.
  (sharedBarePath / "objects") in readAlternates(repoPath)

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
  let useBranch =
    if branch.len > 0: branch else: currentBranch(gitBin, repoPath)
  if useBranch.len == 0:
    return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
      diagnostic: "cannot determine branch to cache-push in " & repoPath &
        " (detached HEAD?)")
  if not looksLikeGitDir(sharedBarePath):
    return SharedCloneResult(ok: false, sharedBarePath: sharedBarePath,
      diagnostic: "shared bare missing for cache-push: " & sharedBarePath)
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
  let cacheRef = "refs/cache/" & workspaceName & "/" & useBranch
  # ``HEAD:<cacheRef>`` pushes whatever the working tree currently has
  # checked out; the cache ref is the destination in the bare.
  let res = runGit(gitBin,
    ["-C", repoPath, "push", "--force", "--no-verify", sharedBarePath,
     "HEAD:" & cacheRef])
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
#   2. runs ``git gc``/``git repack`` to fold loose objects into packs,
#      bounded by a loose-object-count / cache-size / age budget so we do NOT
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
  ##      loose objects into packs and drop now-unreachable objects.
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

  # ``git gc --prune=now`` packs loose objects and expires unreachable ones
  # (the dead-ref objects pruned above become collectable). ``--quiet`` keeps
  # it silent on the fire-and-forget path.
  let gc = runGit(gitBin, ["-C", barePath, "gc", "--quiet", "--prune=now"])
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

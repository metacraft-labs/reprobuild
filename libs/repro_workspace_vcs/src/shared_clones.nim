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

import std/[os, osproc, strutils]

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

# ---- URL → slug ------------------------------------------------------------

proc sanitizeSlugSegment(segment: string): string =
  ## Keep a path segment to a portable, collision-resistant character set:
  ## ASCII alnum plus ``-._``; everything else (``:``, ``@``, spaces, …)
  ## becomes ``_``. This is deterministic and reversible-enough for a
  ## cache slug; it is NOT meant to round-trip back to the URL.
  result = newStringOfCap(segment.len)
  for ch in segment:
    if ch.isAlphaNumeric or ch in {'-', '.', '_'}:
      result.add(ch)
    else:
      result.add('_')

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

# ---- git plumbing ----------------------------------------------------------

proc runGit(gitBin: string; args: openArray[string];
            workingDir = ""): tuple[code: int; output: string] =
  var cmd = quoteShell(gitBin)
  for arg in args:
    cmd.add(" ")
    cmd.add(quoteShell(arg))
  let res = execCmdEx(cmd, workingDir = workingDir)
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
  let cacheRef = "refs/cache" / workspaceName / useBranch
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

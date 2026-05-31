## Bucket-clone helper for the M66 catalog harvester.
##
## A *bucket* is a git repository carrying a ``bucket/`` subdirectory
## (Scoop's convention) of ``<app>.json`` manifest files. The
## harvester needs the bucket on local disk in two cases:
##
##   1. The operator passed ``--bucket scoopinstaller/main`` (a
##      ``<org>/<repo>`` shortname) or an https URL. We clone or
##      refresh under the cache root.
##   2. The operator passed ``--bucket /path/to/local/bucket`` — a
##      local directory. We use it in place (no clone, no pull).
##
## Honest scope: we shell out to ``git`` rather than vendor a git
## client. The harvester is a maintainer tool; needing ``git`` on
## PATH is acceptable. Authentication is out of scope — public
## buckets only.

import std/[algorithm, os, osproc, streams, strutils]

type
  BucketKind* = enum
    bkLocalDirectory
    bkGitRepository

  BucketRef* = object
    ## A resolved bucket reference. ``localRoot`` is the on-disk
    ## directory carrying the ``bucket/*.json`` manifests (the parent
    ## of ``bucket/``); ``bucketSubdir`` is the path component to
    ## append to reach the manifests (almost always ``"bucket"``, but
    ## a few smaller buckets ship manifests at the repo root — we
    ## auto-detect both shapes in ``locateManifestsDir``).
    kind*: BucketKind
    spec*: string         ## what the operator wrote on the CLI
    localRoot*: string    ## absolute path to the on-disk root
    bucketSubdir*: string ## "bucket" or "" depending on shape

  BucketError* = object of CatchableError

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc isGitUrl*(spec: string): bool =
  spec.startsWith("https://") or spec.startsWith("http://") or
    spec.startsWith("git@") or spec.startsWith("ssh://") or
    spec.startsWith("git://")

proc isShortname*(spec: string): bool =
  ## ``scoopinstaller/main`` -- a github shortname.
  not isGitUrl(spec) and not dirExists(spec) and
    not fileExists(spec) and spec.count('/') == 1 and
    not spec.startsWith(".") and not spec.startsWith("/") and
    not (spec.len >= 2 and spec[1] == ':')

proc shortnameToHttps*(spec: string): string =
  ## ``scoopinstaller/main`` -> ``https://github.com/scoopinstaller/main``
  "https://github.com/" & spec

proc cacheRoot*(): string =
  ## Cache root mirrors the spec: ``$XDG_CACHE_HOME/repro-catalog-harvester/buckets/``,
  ## falling back to the platform default. On Windows ``XDG_CACHE_HOME``
  ## is almost never set; we honor ``LOCALAPPDATA`` next.
  let xdg = getEnv("XDG_CACHE_HOME")
  if xdg.len > 0:
    return xdg / "repro-catalog-harvester" / "buckets"
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0:
      return local / "repro-catalog-harvester" / "buckets"
  getHomeDir() / ".cache" / "repro-catalog-harvester" / "buckets"

proc slugFor(spec: string): string =
  ## Make a filesystem-safe directory name from a bucket spec.
  result = newStringOfCap(spec.len)
  for ch in spec:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')

proc runGit*(args: openArray[string]; cwd = ""):
    tuple[exitCode: int; output: string] =
  ## Run ``git`` and capture combined stdout+stderr. The harvester
  ## never needs git's stdout/stderr split — it's all advisory.
  ##
  ## M2 fix: previously this read from the child's stdout via
  ## ``startProcess(...).outputStream.readAll()`` *before* calling
  ## ``waitForExit``. On Windows that pattern truncates the captured
  ## output to roughly the first pipe-buffer flush — for ``git log``
  ## of a multi-year manifest (e.g. ``bucket/gradle.json`` with ~87
  ## commits) only the head commit's hash made it back, so
  ## ``commitVersionsFor`` returned a single entry and
  ## ``--version-history N>1`` silently no-op'd. The fix is to drain
  ## the stream in a chunked-read loop while the child is still
  ## producing, then call ``waitForExit`` once the stream signals
  ## EOF. See the M2 hand-off note for the reproduction (it
  ## reproduces deterministically under PowerShell + the cached
  ## ScoopInstaller/Main bucket post-``--fetch --unshallow``).
  let cmdArgs = @args
  let opts = {poUsePath, poStdErrToStdOut}
  var p = startProcess("git", workingDir = cwd, args = cmdArgs,
    options = opts)
  var outp = newStringOfCap(4096)
  var buf = newString(4096)
  let stream = p.outputStream
  while true:
    let n = stream.readData(addr buf[0], buf.len)
    if n <= 0: break
    let prevLen = outp.len
    outp.setLen(prevLen + n)
    copyMem(addr outp[prevLen], addr buf[0], n)
  let rc = p.waitForExit()
  p.close()
  (rc, outp)

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc locateManifestsDir*(root: string): string =
  ## Pick the directory inside a clone that actually carries
  ## ``<app>.json`` manifests. Standard Scoop layout: ``bucket/``;
  ## some smaller buckets ship at the repo root.
  if dirExists(root / "bucket"):
    return root / "bucket"
  root

proc resolveBucket*(spec: string; refresh = true): BucketRef =
  ## Resolve a CLI ``--bucket`` argument to a local path. Clones a
  ## remote repo on first use (and ``git pull``s on subsequent use
  ## unless ``refresh = false``). Local paths are returned in-place.
  if dirExists(spec):
    # Treat as a local checkout. The user may point at either the
    # repo root or the ``bucket/`` subdir directly.
    let absRoot = absolutePath(spec)
    let manifestsDir = locateManifestsDir(absRoot)
    result = BucketRef(
      kind: bkLocalDirectory, spec: spec,
      localRoot: absRoot,
      bucketSubdir:
        if manifestsDir == absRoot: "" else: relativePath(manifestsDir, absRoot))
    return

  let url = if isGitUrl(spec): spec
            elif isShortname(spec): shortnameToHttps(spec)
            else:
              raise newException(BucketError,
                "bucket spec '" & spec &
                  "' is neither an existing directory, a git URL, " &
                  "nor an <org>/<repo> shortname")

  let cacheDir = cacheRoot() / slugFor(spec)
  createDir(cacheDir.parentDir)

  if dirExists(cacheDir / ".git"):
    if refresh:
      let (rc, output) = runGit(@["pull", "--ff-only", "--quiet"],
        cwd = cacheDir)
      if rc != 0:
        raise newException(BucketError,
          "git pull failed for bucket '" & spec & "': " & output.strip())
  else:
    # Clone with --depth=1 for fast first-pass harvests. The
    # ``--with-history`` operator path is responsible for unshallowing
    # later if it needs ``git log`` reach.
    if dirExists(cacheDir):
      removeDir(cacheDir)
    let (rc, output) = runGit(@["clone", "--depth=1", "--quiet",
      url, cacheDir])
    if rc != 0:
      raise newException(BucketError,
        "git clone failed for bucket '" & spec & "' (url=" & url &
          "): " & output.strip())

  let manifestsDir = locateManifestsDir(cacheDir)
  result = BucketRef(
    kind: bkGitRepository, spec: spec,
    localRoot: cacheDir,
    bucketSubdir:
      if manifestsDir == cacheDir: "" else: relativePath(manifestsDir, cacheDir))

proc unshallow*(bucket: BucketRef) =
  ## Promote a ``--depth=1`` clone to a full clone so subsequent
  ## ``git log`` can walk historical versions. No-op for local
  ## directories.
  if bucket.kind != bkGitRepository: return
  if not fileExists(bucket.localRoot / ".git" / "shallow"): return
  let (rc, output) = runGit(@["fetch", "--unshallow", "--quiet"],
    cwd = bucket.localRoot)
  if rc != 0:
    raise newException(BucketError,
      "git fetch --unshallow failed: " & output.strip())

proc manifestsDirOf*(bucket: BucketRef): string =
  if bucket.bucketSubdir.len > 0:
    bucket.localRoot / bucket.bucketSubdir
  else:
    bucket.localRoot

iterator manifestFiles*(bucket: BucketRef): tuple[app: string; path: string] =
  ## Yield ``(app_name, absolute_path)`` for every ``<app>.json``
  ## sibling of the manifests directory, alphabetically sorted for
  ## determinism.
  let dir = manifestsDirOf(bucket)
  if not dirExists(dir):
    raise newException(BucketError,
      "bucket '" & bucket.spec & "' has no manifests directory at " & dir)
  var hits: seq[string] = @[]
  for kind, path in walkDir(dir, relative = false):
    if kind == pcFile and path.endsWith(".json"):
      hits.add(path)
  hits.sort(cmp[string])
  for path in hits:
    let app = path.splitFile().name
    yield (app, path)

proc commitVersionsFor*(bucket: BucketRef; app: string):
    seq[tuple[sha: string; version: string]] =
  ## For a git-backed bucket, return the chronological-newest-first
  ## sequence of ``(commit-sha, version)`` pairs where ``version`` is
  ## the manifest's ``"version"`` field at that commit. Versions are
  ## de-duplicated — only the most recent commit per version is kept.
  ## Returns an empty seq for local-directory buckets.
  if bucket.kind != bkGitRepository: return @[]
  let dir = manifestsDirOf(bucket)
  # M2 fix: ``git show <sha>:<path>`` insists on forward slashes for
  # the rev-spec path component even on Windows. Without this
  # normalization the call returned rc=128 ("invalid object name") for
  # every historical commit, so ``commitVersionsFor`` accumulated zero
  # versions and ``--version-history N>1`` silently no-op'd. The
  # earlier ``git log -- <path>`` tolerates either separator, so the
  # bug surfaced only inside the loop body — and the head-version
  # emit happened *before* the loop in ``harvestApp``, masking it
  # entirely on the dry-run summary.
  let relPath = relativePath(dir / (app & ".json"), bucket.localRoot)
    .replace('\\', '/')
  # ``--first-parent`` keeps the log linear across merges; we want
  # one entry per shipped version, not per merge fan-out.
  let (rc, output) = runGit(@["log", "--first-parent",
    "--pretty=format:%H", "--", relPath], cwd = bucket.localRoot)
  if rc != 0: return @[]
  var seenVersions: seq[string] = @[]
  for line in output.splitLines:
    let sha = line.strip()
    if sha.len == 0: continue
    let (rcShow, body) = runGit(@["show", sha & ":" & relPath],
      cwd = bucket.localRoot)
    if rcShow != 0: continue
    # Cheap version-field extraction (avoids re-parsing the whole
    # JSON for every commit). We tolerate any whitespace + the
    # standard scoop "version": "1.2.3" shape.
    let needle = "\"version\""
    let idx = body.find(needle)
    if idx < 0: continue
    var i = idx + needle.len
    while i < body.len and body[i] in {' ', '\t', ':'}: inc i
    if i >= body.len or body[i] != '"': continue
    inc i
    let start = i
    while i < body.len and body[i] != '"': inc i
    if i >= body.len: continue
    let version = body[start ..< i]
    if version in seenVersions: continue
    seenVersions.add(version)
    result.add((sha: sha, version: version))

proc manifestAtCommit*(bucket: BucketRef; app: string; sha: string): string =
  ## Read the historical manifest body at a specific commit. Returns
  ## an empty string if git can't find the path at that commit.
  if bucket.kind != bkGitRepository: return ""
  let dir = manifestsDirOf(bucket)
  # M2 fix: forward-slash the rev-spec path; ``git show <sha>:<path>``
  # rejects Windows-style backslashes (see the matching note in
  # ``commitVersionsFor``).
  let relPath = relativePath(dir / (app & ".json"), bucket.localRoot)
    .replace('\\', '/')
  let (rc, body) = runGit(@["show", sha & ":" & relPath],
    cwd = bucket.localRoot)
  if rc != 0: return ""
  body

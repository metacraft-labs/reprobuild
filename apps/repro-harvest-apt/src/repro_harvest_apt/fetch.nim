## C2 P1: HTTP fetch + on-disk index cache for the apt harvester.
##
## Responsibilities split out of the main entry point so they can be
## unit-tested independently and reused by the dnf/pacman harvesters
## once those land.
##
## ## What is fetched
##
## For one harvest run targeting ``apt:<pkg>@<distro>/<suite>:<snapshot>``
## the harvester needs four URLs:
##
##   1. ``<snapshot-base>/dists/<suite>/InRelease``        — clearsigned
##                                                          suite meta
##   2. ``<snapshot-base>/dists/<suite>/Release.gpg``      — detached
##                                                          signature
##                                                          (optional;
##                                                          InRelease's
##                                                          clearsign
##                                                          already covers
##                                                          this)
##   3. ``<snapshot-base>/dists/<suite>/main/binary-amd64/Packages.xz``
##                                                       — the package
##                                                          index
##   4. ``<snapshot-base>/<pool-path>/<pkg>_<ver>_<arch>.deb`` per pkg
##                                                       — the actual
##                                                          archives
##                                                          (downloaded
##                                                          ONLY when the
##                                                          operator asks
##                                                          for them via
##                                                          ``--fetch-debs``;
##                                                          C2 default is
##                                                          metadata only,
##                                                          since the
##                                                          .deb URLs +
##                                                          sha256s are
##                                                          recorded in
##                                                          the catalog
##                                                          and fetched on
##                                                          first realize)
##
## ## Cache layout
##
## The cache mirrors snapshot.debian.org's URL hierarchy verbatim under
## ``<cache-dir>/<host>/<path>``. This keeps the cache content-addressed
## by URL (any URL the operator visits creates exactly one cache entry)
## and lets a future ``repro-cache`` tier subsume the same directory.
##
## ## Rate limiting
##
## snapshot.debian.org rate-limits aggressive scrapers. The fetcher
## enforces a configurable minimum delay between requests against the
## same host (default 1 second). The clock is per-host so a multi-host
## harvest (mirror + snapshot) isn't gated unnecessarily.

import std/[httpclient, monotimes, net, os, osproc, strutils, tables,
            times, uri]

import blake3
import nimcrypto/sha2 as nc_sha2_local

import repro_harvest_apt/signature

type
  FetchClient* = ref object
    ## Stateful HTTP client + per-host rate-limit clock.
    cacheDir*: string
    minIntervalMs*: int       ## min delay between requests to one host
    lastFetchAt*: Table[string, MonoTime]
    userAgent*: string
    offline*: bool            ## when true, only consult the cache; raise
                              ## on miss

  FetchError* = object of CatchableError
    url*: string
    httpCode*: int

  CachedFetch* = object
    ## Result of a fetch (cache hit or live HTTP).
    bytes*: string
    fromCache*: bool
    cachePath*: string

# ---------------------------------------------------------------------------
# Cache-path computation
# ---------------------------------------------------------------------------

proc cachePathFor*(cacheDir: string; url: string): string =
  ## Map a URL into a cache file path.
  let u = parseUri(url)
  var p = cacheDir / u.hostname
  # Replace path separators with the OS native one and strip leading
  # slashes so the cache nests under the host directory.
  var rel = u.path
  if rel.startsWith("/"):
    rel = rel[1 .. ^1]
  if rel.len > 0:
    p.add(DirSep)
  for ch in rel:
    if ch == '/': p.add(DirSep)
    else: p.add(ch)
  result = p

# ---------------------------------------------------------------------------
# Rate limiter
# ---------------------------------------------------------------------------

proc waitForRate(c: FetchClient; host: string) =
  if c.minIntervalMs <= 0: return
  let now = getMonoTime()
  if host in c.lastFetchAt:
    let last = c.lastFetchAt[host]
    let elapsed = inMilliseconds(now - last)
    if elapsed < c.minIntervalMs:
      sleep(c.minIntervalMs - int(elapsed))
  c.lastFetchAt[host] = getMonoTime()

# ---------------------------------------------------------------------------
# Fetch entry points
# ---------------------------------------------------------------------------

proc newFetchClient*(cacheDir: string;
                    minIntervalMs = 1000;
                    userAgent = "repro-harvest-apt/0.1";
                    offline = false): FetchClient =
  result = FetchClient(
    cacheDir: cacheDir,
    minIntervalMs: minIntervalMs,
    lastFetchAt: initTable[string, MonoTime](),
    userAgent: userAgent,
    offline: offline)
  createDir(cacheDir)

proc fetchUrl*(c: FetchClient; url: string;
              forceRefetch = false): CachedFetch =
  ## Fetch ``url`` from cache when possible, fall through to live HTTP
  ## otherwise. The cache is updated atomically on a live fetch.
  let cachePath = cachePathFor(c.cacheDir, url)
  if (not forceRefetch) and fileExists(cachePath):
    return CachedFetch(bytes: readFile(cachePath),
      fromCache: true, cachePath: cachePath)
  if c.offline:
    var e = newException(FetchError,
      "offline mode + cache miss for " & url & " at " & cachePath)
    e.url = url
    raise e
  let host = parseUri(url).hostname
  waitForRate(c, host)
  let client = newHttpClient(timeout = 30_000,
    userAgent = c.userAgent,
    sslContext = newContext(verifyMode = CVerifyPeer))
  defer: client.close()
  var bytes = ""
  try:
    bytes = client.getContent(url)
  except HttpRequestError as ex:
    var e = newException(FetchError,
      "HTTP fetch failed for " & url & ": " & ex.msg)
    e.url = url
    e.httpCode = -1
    raise e
  except CatchableError as ex:
    var e = newException(FetchError,
      "fetch failed for " & url & ": " & ex.msg)
    e.url = url
    e.httpCode = -1
    raise e
  # Atomic write: tmp file in same dir, then rename.
  createDir(parentDir(cachePath))
  let tmp = cachePath & ".part"
  writeFile(tmp, bytes)
  moveFile(tmp, cachePath)
  result = CachedFetch(bytes: bytes, fromCache: false,
    cachePath: cachePath)

# ---------------------------------------------------------------------------
# Decompression helpers
# ---------------------------------------------------------------------------

proc maybeDecompress*(bytes: string; url: string): string =
  ## Run an external decompressor on ``bytes`` when ``url`` ends in
  ## ``.xz`` or ``.gz``. Shells out to ``xz`` / ``gzip`` (or
  ## ``REPRO_XZ_BIN`` / ``REPRO_GZIP_BIN`` env override). If no
  ## decompressor is available and the bytes are compressed, raises a
  ## FetchError.
  if url.endsWith(".xz"):
    let xz = getEnv("REPRO_XZ_BIN")
    let bin = if xz.len > 0: xz else: findExe("xz")
    if bin.len == 0:
      var e = newException(FetchError,
        "fetched " & url & " but no xz decompressor on PATH; " &
        "set REPRO_XZ_BIN or install xz")
      e.url = url
      raise e
    let tmpIn = getTempDir() / ("rharvxz-" & $getCurrentProcessId() &
      ".xz")
    let tmpOut = tmpIn[0 .. ^4]
    defer:
      try: removeFile(tmpIn)
      except: discard
      try: removeFile(tmpOut)
      except: discard
    writeFile(tmpIn, bytes)
    let (_, code) = execCmdEx(bin & " -d -k " & quoteShell(tmpIn))
    if code != 0:
      var e = newException(FetchError,
        "xz decompression failed for " & url)
      e.url = url
      raise e
    return readFile(tmpOut)
  elif url.endsWith(".gz"):
    let gz = getEnv("REPRO_GZIP_BIN")
    let bin = if gz.len > 0: gz else: findExe("gzip")
    if bin.len == 0:
      var e = newException(FetchError,
        "fetched " & url & " but no gzip decompressor on PATH; " &
        "set REPRO_GZIP_BIN or install gzip")
      e.url = url
      raise e
    let tmpIn = getTempDir() / ("rharvgz-" & $getCurrentProcessId() &
      ".gz")
    let tmpOut = tmpIn[0 .. ^4]
    defer:
      try: removeFile(tmpIn)
      except: discard
      try: removeFile(tmpOut)
      except: discard
    writeFile(tmpIn, bytes)
    let (_, code) = execCmdEx(bin & " -d -k " & quoteShell(tmpIn))
    if code != 0:
      var e = newException(FetchError,
        "gzip decompression failed for " & url)
      e.url = url
      raise e
    return readFile(tmpOut)
  else:
    bytes

# ---------------------------------------------------------------------------
# Sha256 verification (independent of the GPG signature path)
# ---------------------------------------------------------------------------

proc sha256HexStr*(bytes: string): string =
  ## SHA-256 hex of ``bytes`` (lowercase, 64 chars). Uses nimcrypto's
  ## constant-time SHA-256 — already vendored under
  ## ``../codetracer/libs/nimcrypto`` and exposed via the
  ## NIMCRYPTO_SRC path in config.nims.
  var ctx: nc_sha2_local.sha256
  ctx.init()
  ctx.update(bytes)
  let digest = ctx.finish()
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = digest.data[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

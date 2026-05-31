## MSYS2 pacman repository harvester source (M6 of the
## Realize-Closure-And-Catalog-Expansion spec).
##
## Reads ``https://repo.msys2.org/mingw/<env>/`` (env = ``mingw64``,
## ``ucrt64``, ``clang64``, …) and emits a
## ``VersionedProvisioning`` entry for a single requested package. The
## entry's ``install_method`` is ``imMsys2Pacman``, its
## ``archive_format`` is ``afTarZst``, and its ``platforms`` slice
## points at the canonical ``.pkg.tar.zst`` URL with the SHA-256
## carried verbatim from the upstream repo's signed metadata (when
## fetched as part of a ``--with-db`` mode; the default mode computes
## the digest from the downloaded artifact itself, which is hermetic
## but requires a one-time download).
##
## Honest scope (M6):
##
##   * **No automatic dependency resolution.** MSYS2 packages declare
##     ``depend`` arrays in their PKGINFO; we extract them into the
##     emitter's diagnostics for the operator to read but do NOT
##     auto-harvest the transitive closure. Operators must list every
##     needed MSYS2 package explicitly in home.nim.
##   * **mingw64 only in the M6 milestone.** ucrt64 / clang64 / mingw32
##     / msys envs are reachable via ``--env <name>`` and the URL +
##     prefix-flatten code paths handle them generically, but
##     end-to-end live smoke testing is mingw64-only for M6.
##   * **Hashes computed from the artifact itself.** The MSYS2 db file
##     (``mingw64.db.tar.zst``) carries per-package SHA-256s, but the
##     M6 implementation downloads the .pkg.tar.zst and computes the
##     hash from the bytes. This is hermetic (we never trust the
##     unverified index for the hash) and keeps the harvester's
##     dependency footprint to ``std/httpclient`` + a sha256 hasher.
##     Re-running the harvester on the same upstream artifact produces
##     byte-identical output (the catalog's ``serializeAsCode`` is
##     deterministic; the upstream artifact's SHA-256 is by definition
##     stable per artifact).
##
## Output flatten (M6 realize hook in cakBuiltin / builtin_adapter):
## MSYS2 packages ship a top-level prefix subdir matching the env
## (``mingw64/``, ``ucrt64/``, …) carrying ``bin/``, ``lib/``,
## ``share/`` underneath. The harvester emits ``extract_path: "mingw64"``
## so the realize hook's ``flattenExtractPath`` materializes
## ``bin/ocaml.exe`` at the prefix root.

import std/[algorithm, httpclient, os, osproc, strutils]
import repro_dsl_stdlib/packages_schema

# SHA-256 is computed by shelling out to the host hasher (sha256sum on
# POSIX, certutil on Windows). This mirrors the existing
# ``builtin_adapter.fileShaHex`` strategy and keeps the harvester free
# of an external Nim sha2 dependency. Nim 2.2's stdlib does not ship
# std/sha2; the system tools are universally available.

type
  Msys2Env* = enum
    ## Supported MSYS2 environments. The M6 harvester end-to-end
    ## verifies only ``meMingw64``; the others compile but are
    ## documented as untested.
    meMingw64 = "mingw64"
    meUcrt64 = "ucrt64"
    meClang64 = "clang64"
    meMingw32 = "mingw32"
    meMsys = "msys"

  Msys2PackageRef* = object
    ## A resolved (env, package, version, rel) tuple ready for emit.
    env*: Msys2Env
    fullName*: string    ## e.g. ``mingw-w64-x86_64-ocaml``
    version*: string     ## e.g. ``5.4.1``
    rel*: string         ## pacman package revision, e.g. ``2``
    arch*: string        ## ``any`` for noarch packages (the common case)
    filename*: string    ## e.g. ``mingw-w64-x86_64-ocaml-5.4.1-2-any.pkg.tar.zst``
    url*: string         ## canonical https URL of the .pkg.tar.zst
    sha256*: string      ## hex-encoded SHA-256 of the downloaded bytes
    depends*: seq[string] ## ``depend = X`` lines from the package's
                         ## .PKGINFO (informational; not auto-resolved)
    binRelpaths*: seq[string]
                         ## ``bin/<tool>.exe`` paths discovered inside the
                         ## .pkg.tar.zst (used to populate
                         ## ``VersionedProvisioning.bin_relpath``)

  Msys2HarvestError* = object of CatchableError

# ---------------------------------------------------------------------------
# Env <-> URL helpers
# ---------------------------------------------------------------------------

proc envBaseUrl*(env: Msys2Env): string =
  "https://repo.msys2.org/mingw/" & $env & "/"

proc envPackagePrefix*(env: Msys2Env): string =
  ## The mingw-w64 package-name prefix the env uses. Operators can pass
  ## a shorthand (``ocaml``) and the harvester auto-prefixes to e.g.
  ## ``mingw-w64-x86_64-ocaml`` for mingw64.
  case env
  of meMingw64: "mingw-w64-x86_64-"
  of meUcrt64: "mingw-w64-ucrt-x86_64-"
  of meClang64: "mingw-w64-clang-x86_64-"
  of meMingw32: "mingw-w64-i686-"
  of meMsys: ""  # base env uses bare package names

proc envExtractRoot*(env: Msys2Env): string =
  ## The top-level subdir the package's payload ships under (the value
  ## the harvester writes to ``extract_path``; the realize hook flattens
  ## this to the prefix root).
  case env
  of meMingw64: "mingw64"
  of meUcrt64: "ucrt64"
  of meClang64: "clang64"
  of meMingw32: "mingw32"
  of meMsys: ""  # base env files land at the root already

# ---------------------------------------------------------------------------
# SHA-256 of a downloaded file
# ---------------------------------------------------------------------------

proc fileSha256Hex*(path: string): string =
  ## Compute SHA-256 over the file at ``path`` by shelling out to the
  ## host hasher (``sha256sum`` on POSIX; ``certutil -hashfile``
  ## ``SHA256`` on Windows). Returns the hex digest in lowercase.
  ##
  ## Mirrors ``builtin_adapter.fileShaHex`` — kept inline here so the
  ## harvester binary does not pull repro_home_apply into its link.
  let sumExe = findExe("sha256sum")
  let shasum = findExe("shasum")
  let certutil = when defined(windows): findExe("certutil") else: ""
  let openssl = findExe("openssl")
  let command =
    if sumExe.len > 0:
      quoteShell(sumExe) & " " & quoteShell(path)
    elif shasum.len > 0:
      quoteShell(shasum) & " -a 256 " & quoteShell(path)
    elif certutil.len > 0:
      quoteShell(certutil) & " -hashfile " & quoteShell(path) & " SHA256"
    elif openssl.len > 0:
      quoteShell(openssl) & " dgst -sha256 -r " & quoteShell(path)
    else:
      raise newException(Msys2HarvestError,
        "no SHA-256 implementation available (tried sha256sum, " &
        "shasum, certutil, openssl)")
  let res = execCmdEx(command)
  if res.exitCode != 0:
    raise newException(Msys2HarvestError,
      "sha256 helper exited " & $res.exitCode & " for " & path &
      "\n" & res.output)
  # Parse the output: take the first 64-char hex run on any non-empty
  # line. Handles ``<hex>  <path>`` (sha256sum), ``<hex> *<path>``
  # (sha256sum binary mode), certutil's multi-line ``SHA256 hash of
  # <path>: <hex>``, and openssl's ``SHA256(<path>)= <hex>`` shape.
  for raw in res.output.splitLines:
    let line = raw.strip()
    if line.len == 0: continue
    # Skip purely descriptive lines (certutil's "CertUtil: -hashfile
    # completed successfully.").
    var i = 0
    # Find the longest hex run at start-of-line OR after the first
    # whitespace / colon / equals.
    while i < line.len:
      var j = i
      while j < line.len and line[j] in {'0'..'9', 'a'..'f', 'A'..'F'}:
        inc j
      if j - i == 64:
        return line[i ..< j].toLowerAscii()
      if j == i: inc i
      else: i = j
  raise newException(Msys2HarvestError,
    "sha256 helper produced no 64-char hex digest in:\n" & res.output)

# ---------------------------------------------------------------------------
# Mock-friendly index fetcher
# ---------------------------------------------------------------------------
#
# The hermetic test harness sets ``REPRO_M6_INDEX_FIXTURE_DIR`` to a
# local directory whose layout mirrors ``https://repo.msys2.org/mingw/``;
# the harvester then reads index files + .pkg.tar.zst payloads from
# disk instead of issuing real HTTPS requests. Production runs hit the
# upstream HTTPS endpoint directly.

const FixtureDirEnv* = "REPRO_M6_INDEX_FIXTURE_DIR"

proc fetchUrlToString*(url: string): string =
  let fixtureDir = getEnv(FixtureDirEnv)
  if fixtureDir.len > 0:
    # Map ``https://repo.msys2.org/mingw/<env>/<rest>`` -> ``<fixtureDir>/<env>/<rest>``.
    # A bare ``<env>/`` trailing-slash URL maps to ``<fixtureDir>/<env>/index.html``
    # so the harvester's HTML directory-listing parser sees a fixture
    # equivalent of the upstream Apache index.
    const prefix = "https://repo.msys2.org/mingw/"
    if not url.startsWith(prefix):
      raise newException(Msys2HarvestError,
        "fixture mode: URL '" & url & "' is not under " & prefix)
    var rel = url[prefix.len .. ^1]
    if rel.endsWith("/"):
      rel.add("index.html")
    let local = fixtureDir / rel
    if not fileExists(local):
      raise newException(Msys2HarvestError,
        "fixture mode: no file at " & local)
    return readFile(local)
  var client = newHttpClient(timeout = 30_000)
  defer: client.close()
  try:
    return client.getContent(url)
  except HttpRequestError as err:
    raise newException(Msys2HarvestError,
      "MSYS2 index fetch failed for " & url & ": " & err.msg)
  except OSError as err:
    raise newException(Msys2HarvestError,
      "MSYS2 index fetch failed for " & url & ": " & err.msg)

proc fetchUrlToFile*(url, dest: string) =
  let fixtureDir = getEnv(FixtureDirEnv)
  if fixtureDir.len > 0:
    const prefix = "https://repo.msys2.org/mingw/"
    if not url.startsWith(prefix):
      raise newException(Msys2HarvestError,
        "fixture mode: URL '" & url & "' is not under " & prefix)
    let rel = url[prefix.len .. ^1]
    let local = fixtureDir / rel
    if not fileExists(local):
      raise newException(Msys2HarvestError,
        "fixture mode: no file at " & local)
    copyFile(local, dest)
    return
  var client = newHttpClient(timeout = 120_000)
  defer: client.close()
  try:
    client.downloadFile(url, dest)
  except HttpRequestError as err:
    raise newException(Msys2HarvestError,
      "MSYS2 download failed for " & url & ": " & err.msg)
  except OSError as err:
    raise newException(Msys2HarvestError,
      "MSYS2 download failed for " & url & ": " & err.msg)

# ---------------------------------------------------------------------------
# Index parsing
# ---------------------------------------------------------------------------

proc listIndexFilenames*(env: Msys2Env): seq[string] =
  ## Parse the Apache-style directory listing at ``envBaseUrl(env)`` and
  ## return every linked filename. We use the listing rather than the
  ## ``<env>.db.tar.zst`` index because M6's hermetic test fixtures are
  ## easier to assemble as a flat directory than as a pacman db file.
  ## The listing parser is deliberately tolerant — it extracts
  ## ``href="..."`` tokens and filters to .pkg.tar.zst leafs.
  let body = fetchUrlToString(envBaseUrl(env))
  for chunk in body.split('"'):
    if chunk.startsWith("http"): continue
    if chunk.endsWith(".pkg.tar.zst"):
      let leaf =
        if chunk.contains('/'):
          chunk[chunk.rfind('/') + 1 .. ^1]
        else:
          chunk
      if leaf.len > 0 and leaf notin result:
        result.add(leaf)

# ---------------------------------------------------------------------------
# Version comparison
# ---------------------------------------------------------------------------
#
# MSYS2 versions follow the pacman semver-ish convention: <upstream>-<rel>
# where <upstream> is dot-separated decimal segments plus optional pre-
# release suffixes. M6 picks the LATEST entry by lexicographic comparison
# of the version + rel tuple after a numeric pre-parse pass. Edge cases
# (alpha/beta/rc suffixes, +build metadata) fall back to lex order — the
# MSYS2 packages we currently target don't exercise those.

proc compareVersionPair(a, b: Msys2PackageRef): int =
  ## Newest-first: returns NEGATIVE when ``a`` is NEWER (so the sort
  ## ascending puts the newest at index 0).
  proc splitVer(v: string): seq[int] =
    var i = 0
    while i < v.len:
      var j = i
      while j < v.len and v[j] in {'0'..'9'}: inc j
      if j == i: break
      try: result.add(parseInt(v[i ..< j]))
      except ValueError: break
      i = j
      if i < v.len and v[i] == '.': inc i else: break
  let av = splitVer(a.version)
  let bv = splitVer(b.version)
  let n = min(av.len, bv.len)
  for k in 0 ..< n:
    if av[k] != bv[k]: return cmp(bv[k], av[k])
  if av.len != bv.len: return cmp(bv.len, av.len)
  # Same upstream version: tie-break on rel (numeric).
  try:
    let ar = parseInt(a.rel)
    let br = parseInt(b.rel)
    if ar != br: return cmp(br, ar)
  except ValueError: discard
  cmp(b.filename, a.filename)

# ---------------------------------------------------------------------------
# Filename parsing
# ---------------------------------------------------------------------------

proc parsePkgFilename*(env: Msys2Env; filename: string):
    tuple[ok: bool; fullName, version, rel, arch: string] =
  ## Decompose an MSYS2 package filename into its constituent fields.
  ## The shape is:
  ##   ``<fullName>-<version>-<rel>-<arch>.pkg.tar.zst``
  ## where ``<arch>`` is typically ``any`` (noarch) or the env's CPU.
  ## ``<fullName>`` includes the ``mingw-w64-x86_64-`` prefix and the
  ## bare package name (e.g. ``mingw-w64-x86_64-ocaml``).
  result.ok = false
  let suffix = ".pkg.tar.zst"
  if not filename.endsWith(suffix): return
  let stem = filename[0 ..< filename.len - suffix.len]
  # Last four hyphen-separated tokens are: arch, rel, version, then the
  # package name's tail. arch is the LAST hyphen-separated token; rel
  # the second-to-last; version the third. The package-name span is
  # everything before. The pacman ``<rel>`` may itself contain a dot
  # (``-1.2``) but not a hyphen.
  var dashIdxs: seq[int] = @[]
  for i, ch in stem:
    if ch == '-': dashIdxs.add(i)
  if dashIdxs.len < 3: return
  let archStart = dashIdxs[^1] + 1
  let relStart = dashIdxs[^2] + 1
  let verStart = dashIdxs[^3] + 1
  let arch = stem[archStart .. ^1]
  let rel = stem[relStart .. dashIdxs[^1] - 1]
  let version = stem[verStart .. dashIdxs[^2] - 1]
  let fullName = stem[0 ..< dashIdxs[^3]]
  # Sanity: the package's full-name prefix must match the env's
  # convention (e.g. ``mingw-w64-x86_64-`` for mingw64). Otherwise this
  # filename belongs to a sibling env's index leaking into the listing —
  # discard.
  let envPrefix = envPackagePrefix(env)
  if envPrefix.len > 0 and not fullName.startsWith(envPrefix): return
  result.ok = true
  result.fullName = fullName
  result.version = version
  result.rel = rel
  result.arch = arch

# ---------------------------------------------------------------------------
# Resolution: pick the latest version of a requested package
# ---------------------------------------------------------------------------

proc resolveLatestPackage*(env: Msys2Env; packageHint: string;
                           versionPin = ""): Msys2PackageRef =
  ## Probe the env's index and return the ``Msys2PackageRef`` for the
  ## latest (or version-pinned) build of the requested package.
  ## ``packageHint`` may be a bare name (``ocaml``) which is auto-
  ## prefixed with the env's ``mingw-w64-<arch>-`` convention, or a
  ## full pacman package name (``mingw-w64-x86_64-ocaml``).
  let fullName =
    if packageHint.startsWith("mingw-w64-") or env == meMsys:
      packageHint
    else:
      envPackagePrefix(env) & packageHint
  let leafs = listIndexFilenames(env)
  var candidates: seq[Msys2PackageRef] = @[]
  for leaf in leafs:
    let p = parsePkgFilename(env, leaf)
    if not p.ok: continue
    if p.fullName != fullName: continue
    if versionPin.len > 0 and p.version != versionPin: continue
    candidates.add(Msys2PackageRef(
      env: env,
      fullName: p.fullName,
      version: p.version,
      rel: p.rel,
      arch: p.arch,
      filename: leaf,
      url: envBaseUrl(env) & leaf))
  if candidates.len == 0:
    raise newException(Msys2HarvestError,
      "no MSYS2 package '" & fullName & "' in env '" & $env &
      "'" & (if versionPin.len > 0:
              " (with version pin '" & versionPin & "')"
            else: ""))
  candidates.sort(compareVersionPair)
  candidates[0]

# ---------------------------------------------------------------------------
# .pkg.tar.zst introspection
# ---------------------------------------------------------------------------
#
# After download we need:
#   (a) the SHA-256 (computed via fileSha256Hex);
#   (b) the .PKGINFO ``depend =`` lines (informational);
#   (c) the list of ``<env>/bin/*`` entries to populate bin_relpath.
#
# .pkg.tar.zst is a zstd-compressed tar. We shell out to ``tar --zstd``
# (Git for Windows ships this) OR to a host ``zstd | tar`` pipe — both
# are exclusively used at HARVEST time so the runtime ``afTarZst``
# discovery (which probes for a catalog 7z) is independent. The
# harvester is a maintainer tool; needing host tar+zstd is acceptable.

proc tarListEntries*(archivePath: string): seq[string] =
  ## Return every entry path in the .tar.zst archive (file + directory).
  ## Used by the harvester to enumerate the ``<env>/bin/`` files for
  ## ``bin_relpath`` synthesis.
  let tar = findExe("tar")
  if tar.len == 0:
    raise newException(Msys2HarvestError,
      "harvester needs 'tar' on PATH to introspect MSYS2 packages " &
      "(Git for Windows ships tar with --zstd; alternatively install " &
      "the upstream GNU tar 1.31+)")
  # Try the --zstd filter first (GNU tar).
  let cmd1 = quoteShell(tar) & " --zstd -tf " & quoteShell(archivePath)
  let res1 = execCmdEx(cmd1)
  if res1.exitCode == 0:
    for line in res1.output.splitLines:
      let s = line.strip(chars = {'\n', '\r', ' '})
      if s.len > 0: result.add(s)
    return
  # Fallback A: bsdtar auto-detect via bare ``-tf``.
  let cmdAuto = quoteShell(tar) & " -tf " & quoteShell(archivePath)
  let resAuto = execCmdEx(cmdAuto)
  if resAuto.exitCode == 0:
    for line in resAuto.output.splitLines:
      let s = line.strip(chars = {'\n', '\r', ' '})
      if s.len > 0: result.add(s)
    return
  # Fallback B: zstd | tar pipeline.
  let zstd = findExe("zstd")
  if zstd.len == 0:
    raise newException(Msys2HarvestError,
      "tar --zstd failed and no 'zstd' on PATH for fallback (tar " &
      "output: " & res1.output & ")")
  let cmd2 = quoteShell(zstd) & " -dc " & quoteShell(archivePath) &
    " | " & quoteShell(tar) & " -tf -"
  let res2 = execCmdEx(cmd2)
  if res2.exitCode != 0:
    raise newException(Msys2HarvestError,
      "zstd | tar -tf pipeline failed (exit " & $res2.exitCode &
      "): " & res2.output)
  for line in res2.output.splitLines:
    let s = line.strip(chars = {'\n', '\r', ' '})
    if s.len > 0: result.add(s)

proc tarExtractMember*(archivePath, member, destFile: string): bool =
  ## Extract a single member from the .tar.zst archive to ``destFile``.
  ## Returns ``true`` on success, ``false`` if the member is absent.
  let tar = findExe("tar")
  if tar.len == 0:
    raise newException(Msys2HarvestError,
      "harvester needs 'tar' on PATH to extract MSYS2 package members")
  let workDir = parentDir(destFile)
  createDir(workDir)
  # We extract relatively into a scratch subdir and then rename to
  # ``destFile`` — this avoids polluting ``workDir`` with the original
  # member path.
  let scratch = workDir / ".m6-extract-scratch"
  if dirExists(scratch): removeDir(scratch)
  createDir(scratch)
  defer:
    try: removeDir(scratch)
    except OSError: discard
  let cmd1 = quoteShell(tar) & " --zstd -xf " & quoteShell(archivePath) &
    " -C " & quoteShell(scratch) & " " & quoteShell(member)
  let res1 = execCmdEx(cmd1)
  if res1.exitCode != 0:
    # Fallback A: bsdtar auto-detect.
    let cmdAuto = quoteShell(tar) & " -xf " & quoteShell(archivePath) &
      " -C " & quoteShell(scratch) & " " & quoteShell(member)
    let resAuto = execCmdEx(cmdAuto)
    if resAuto.exitCode != 0:
      # Fallback B: zstd | tar
      let zstd = findExe("zstd")
      if zstd.len == 0:
        return false
      let cmd2 = quoteShell(zstd) & " -dc " & quoteShell(archivePath) &
        " | " & quoteShell(tar) & " -xf - -C " & quoteShell(scratch) &
        " " & quoteShell(member)
      let res2 = execCmdEx(cmd2)
      if res2.exitCode != 0:
        return false
  let extracted = scratch / member
  if not fileExists(extracted):
    return false
  if fileExists(destFile): removeFile(destFile)
  moveFile(extracted, destFile)
  true

proc parsePkgInfoDepends*(pkgInfoBody: string): seq[string] =
  ## Parse ``depend = X`` lines out of a .PKGINFO body. Returns the
  ## list of package-name strings (the version-constraint tail is kept
  ## as-is for operator review).
  for raw in pkgInfoBody.splitLines:
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"): continue
    let eq = line.find('=')
    if eq <= 0: continue
    let key = line[0 ..< eq].strip()
    if key != "depend": continue
    let value = line[eq + 1 .. ^1].strip()
    if value.len > 0: result.add(value)

# ---------------------------------------------------------------------------
# Public entry point: harvest one MSYS2 package -> VersionedProvisioning
# ---------------------------------------------------------------------------

proc harvestMsys2Package*(env: Msys2Env; packageHint: string;
                           toolName: string;
                           versionPin = "";
                           cacheDir = ""):
    VersionedProvisioning =
  ## End-to-end harvest of one MSYS2 package. Returns the
  ## ``VersionedProvisioning`` ready to feed to ``emitCatalogFile`` /
  ## a hand-merged ``packages/<tool>.nim``.
  ##
  ## ``toolName`` is the operator-facing catalog identifier (e.g.
  ## ``ocaml``) and is used to filter the package's bin_relpath
  ## candidates — we synthesize ``bin_relpath`` as ``bin/<tool>.exe``
  ## (and ``bin/<tool>`` for non-.exe environments) if either entry
  ## exists inside the archive. The full list of ``bin/`` files inside
  ## the package is captured in ``Msys2PackageRef.binRelpaths`` for the
  ## operator's review; the catalog records only the canonical tool
  ## binary so the post-extract sanity check is tight.
  ##
  ## ``cacheDir`` is the directory the .pkg.tar.zst is downloaded into;
  ## defaults to ``$XDG_CACHE_HOME / repro-catalog-harvester / msys2``
  ## (or the platform equivalent). The cache is INTENTIONALLY
  ## per-package — re-running the harvester for a different package
  ## does not re-download earlier ones.
  var pkgRef = resolveLatestPackage(env, packageHint, versionPin)
  let cache =
    if cacheDir.len > 0: cacheDir
    else:
      let xdg = getEnv("XDG_CACHE_HOME")
      let base =
        if xdg.len > 0: xdg
        else:
          when defined(windows):
            let local = getEnv("LOCALAPPDATA")
            if local.len > 0: local
            else: getHomeDir() / ".cache"
          else: getHomeDir() / ".cache"
      base / "repro-catalog-harvester" / "msys2"
  createDir(cache)
  let downloadPath = cache / pkgRef.filename
  if not fileExists(downloadPath):
    fetchUrlToFile(pkgRef.url, downloadPath)
  pkgRef.sha256 = fileSha256Hex(downloadPath).toLowerAscii()
  # Introspect the archive for the package's deps + bin/ contents.
  let entries = tarListEntries(downloadPath)
  let extractRoot = envExtractRoot(env)
  let binPrefix = if extractRoot.len > 0: extractRoot & "/bin/" else: "bin/"
  for entry in entries:
    if entry.startsWith(binPrefix) and entry.len > binPrefix.len and
       not entry.endsWith("/"):
      pkgRef.binRelpaths.add(entry[binPrefix.len .. ^1])
  # PKGINFO depends — best-effort; non-fatal if extraction misses.
  let pkgInfoPath = cache / (pkgRef.filename & ".PKGINFO")
  if tarExtractMember(downloadPath, ".PKGINFO", pkgInfoPath):
    pkgRef.depends = parsePkgInfoDepends(readFile(pkgInfoPath))
  # Compose the bin_relpath. Prefer the operator-named tool first
  # (``bin/<tool>.exe``); fall back to ALL discovered bin entries if
  # the canonical name is absent (rare; usually means the package's
  # primary binary differs from the catalog identifier).
  var binRelpath: seq[string] = @[]
  let canonical = "bin/" & toolName & ".exe"
  let canonicalBare = "bin/" & toolName
  for b in pkgRef.binRelpaths:
    if b == toolName & ".exe":
      binRelpath.add(canonical)
    elif b == toolName:
      binRelpath.add(canonicalBare)
  if binRelpath.len == 0:
    # Last-resort fallback: emit every binary the package ships.
    # Catalog reviewers can prune to the relevant tool subset.
    for b in pkgRef.binRelpaths:
      binRelpath.add("bin/" & b)
  if binRelpath.len == 0:
    raise newException(Msys2HarvestError,
      "package '" & pkgRef.fullName & "' has no bin/ entries inside " &
      "the archive; cannot synthesize bin_relpath. Inspect the archive " &
      "manually and hand-edit the catalog entry.")
  # Compose the VersionedProvisioning. Per the M6 spec the version
  # string is ``<upstream>-<rel>`` (e.g. ``5.4.1-2``); we match that
  # convention so re-harvests against the same upstream + rel produce
  # byte-identical catalogs.
  result = initVersionedProvisioning(
    version = pkgRef.version & "-" & pkgRef.rel,
    archive_format = afTarZst,
    install_method = imMsys2Pacman,
    bin_relpath = binRelpath,
    platforms = @[
      initPlatformBinary(
        cpu = pcX86_64, os = poWindows,
        url = pkgRef.url,
        sha256 = pkgRef.sha256,
        extract_path = envExtractRoot(env))
    ],
    pacman_packages = @[pkgRef.fullName])

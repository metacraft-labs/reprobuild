## GitHub Releases API harvester source (M7 of the
## Realize-Closure-And-Catalog-Expansion spec).
##
## Reads ``https://api.github.com/repos/<org>/<repo>/releases`` and
## emits a ``VersionedProvisioning`` entry per harvested asset. Each
## release in the API response carries a ``tag_name`` (e.g. ``v2.1.1``),
## an ``assets`` array (each asset has ``name``,
## ``browser_download_url``, ``size``, ``digest`` — when present, the
## sha256 shows up as ``"sha256:<hex>"``), plus ``prerelease`` and
## ``draft`` boolean flags.
##
## Honest scope (M7):
##
##   * **One asset per harvest invocation.** The operator runs the
##     harvester once per (platform, tool) combination, supplying a
##     regex via ``--asset-pattern`` to pick the right binary out of
##     the release's asset list. Multi-platform fold-in (one
##     invocation -> one catalog file with Linux + Windows + macOS
##     slices) is a future concern documented in the M7 spec section's
##     Outstanding Tasks.
##   * **No transitive dependencies.** GitHub Releases binaries are
##     generally self-contained (alire ships ``bin/alr.exe`` standalone;
##     winlibs gcc ships its full toolchain in one zip). The operator
##     remains responsible for listing any runtime prerequisites.
##   * **Hashes prefer the asset's ``digest`` field.** GitHub started
##     shipping per-asset sha256 in the ``digest`` field (formatted as
##     ``sha256:<hex>``) for releases uploaded after mid-2024. When
##     present we take it verbatim; otherwise we download the asset
##     once and compute the sha256 ourselves via ``fileSha256Hex``
##     (same shell-out pattern M6 uses). The harvester does NOT trust
##     unverified third-party sources; the GitHub API itself is the
##     trust anchor here.
##   * **Pre-releases excluded by default.** The harvester walks the
##     paginated ``/releases`` endpoint and picks the FIRST release
##     whose ``prerelease`` flag is false (the latest non-prerelease).
##     ``--prerelease`` includes prereleases in the candidate pool.
##
## Authentication: when ``GITHUB_TOKEN`` is set in the environment the
## harvester forwards it as ``Authorization: Bearer <token>`` so the
## host hits the 5000-req/hour authenticated rate limit instead of the
## 60-req/hour unauthenticated one. Operators refreshing more than a
## handful of catalogs at once should set the token.

import std/[httpclient, json, os, osproc, streams, strutils]
import repro_dsl_stdlib/packages_schema

# ---------------------------------------------------------------------------
# Minimal regex matcher
# ---------------------------------------------------------------------------
#
# M7 uses a small in-process regex matcher rather than ``std/re`` to keep
# the harvester binary free of a runtime PCRE DLL dependency (Nim's
# ``re`` module dynamically loads ``pcre64.dll`` on Windows x64, which
# the reprobuild distribution does not ship). The matcher supports the
# minimal subset operators specify when picking GitHub release assets:
#
#   * literal characters (everything except the metacharacters below);
#   * ``.``    — any single character;
#   * ``*``    — zero or more of the preceding atom (literal/``.``/class);
#   * ``+``    — one or more of the preceding atom;
#   * ``?``    — zero or one of the preceding atom;
#   * ``^`` / ``$`` — anchors. (Match is always anchored implicitly when
#                     called via ``matchFull``.)
#   * ``\.`` / ``\\`` / ``\(`` / ``\)`` / ``\d`` / ``\w`` / ``\s`` /
#     ``\D`` / ``\W`` / ``\S`` — backslash escapes;
#   * ``[abc]`` / ``[a-z]`` / ``[^abc]`` — character classes;
#   * ``(...)`` — capture groups (one or more; ``--version-extract``
#     extracts group 1).
#
# Alternation ``a|b``, non-greedy ``*?`` / ``+?``, backreferences,
# lookahead/behind, named groups are out of scope — operators pick
# upstream tags whose patterns are straightforward.

type
  RegexParseError* = object of CatchableError
  RegexAtomKind = enum
    raLiteral, raAnyChar, raCharClass, raGroupStart, raGroupEnd,
    raAnchorStart, raAnchorEnd

  RegexAtom = object
    kind: RegexAtomKind
    ch: char
    classChars: set[char]
    classNegated: bool
    quantStar: bool        ## 0..N
    quantPlus: bool        ## 1..N
    quantQuestion: bool    ## 0..1

  CompiledRegex* = object
    atoms*: seq[RegexAtom]
    numGroups*: int

const RegexDigit = {'0'..'9'}
const RegexWord = {'A'..'Z', 'a'..'z', '0'..'9', '_'}
const RegexSpace = {' ', '\t', '\n', '\r', '\f', '\v'}

proc parseCharClass(pattern: string; i: var int):
    tuple[chars: set[char]; negated: bool] =
  ## Parse a ``[...]`` character class starting at ``pattern[i] == '['``.
  ## Advances ``i`` to the position AFTER the closing ``]``.
  doAssert pattern[i] == '['
  inc i
  if i < pattern.len and pattern[i] == '^':
    result.negated = true
    inc i
  while i < pattern.len and pattern[i] != ']':
    var lo = pattern[i]
    if lo == '\\' and i + 1 < pattern.len:
      inc i
      case pattern[i]
      of 'd': result.chars = result.chars + RegexDigit; inc i; continue
      of 'D': result.chars = result.chars + ({'\x00'..'\xFF'} - RegexDigit); inc i; continue
      of 'w': result.chars = result.chars + RegexWord; inc i; continue
      of 'W': result.chars = result.chars + ({'\x00'..'\xFF'} - RegexWord); inc i; continue
      of 's': result.chars = result.chars + RegexSpace; inc i; continue
      of 'S': result.chars = result.chars + ({'\x00'..'\xFF'} - RegexSpace); inc i; continue
      else: lo = pattern[i]; inc i
    else:
      inc i
    if i + 1 < pattern.len and pattern[i] == '-' and pattern[i + 1] != ']':
      var hi = pattern[i + 1]
      if hi == '\\' and i + 2 < pattern.len:
        hi = pattern[i + 2]
        i += 3
      else:
        i += 2
      let l = min(lo, hi)
      let h = max(lo, hi)
      for c in l..h: result.chars.incl(c)
    else:
      result.chars.incl(lo)
  if i >= pattern.len or pattern[i] != ']':
    raise newException(RegexParseError,
      "unterminated character class starting at offset " &
      $(i - result.chars.len))
  inc i  # past the closing ']'

proc compileRegex*(pattern: string): CompiledRegex =
  ## Compile a regex pattern into a flat atom sequence. The compiled
  ## form is consumed by ``matchFull`` via a backtracking interpreter.
  var i = 0
  while i < pattern.len:
    let c = pattern[i]
    var atom: RegexAtom
    case c
    of '^':
      atom = RegexAtom(kind: raAnchorStart)
      inc i
    of '$':
      atom = RegexAtom(kind: raAnchorEnd)
      inc i
    of '.':
      atom = RegexAtom(kind: raAnyChar)
      inc i
    of '(':
      atom = RegexAtom(kind: raGroupStart)
      inc result.numGroups
      inc i
    of ')':
      atom = RegexAtom(kind: raGroupEnd)
      inc i
    of '[':
      let (chars, negated) = parseCharClass(pattern, i)
      atom = RegexAtom(kind: raCharClass, classChars: chars,
                       classNegated: negated)
    of '\\':
      if i + 1 >= pattern.len:
        raise newException(RegexParseError,
          "trailing backslash in pattern")
      inc i
      case pattern[i]
      of 'd':
        atom = RegexAtom(kind: raCharClass, classChars: RegexDigit,
                         classNegated: false)
      of 'D':
        atom = RegexAtom(kind: raCharClass, classChars: RegexDigit,
                         classNegated: true)
      of 'w':
        atom = RegexAtom(kind: raCharClass, classChars: RegexWord,
                         classNegated: false)
      of 'W':
        atom = RegexAtom(kind: raCharClass, classChars: RegexWord,
                         classNegated: true)
      of 's':
        atom = RegexAtom(kind: raCharClass, classChars: RegexSpace,
                         classNegated: false)
      of 'S':
        atom = RegexAtom(kind: raCharClass, classChars: RegexSpace,
                         classNegated: true)
      else:
        atom = RegexAtom(kind: raLiteral, ch: pattern[i])
      inc i
    of '*', '+', '?', '|', '{':
      raise newException(RegexParseError,
        "regex quantifier '" & $c & "' has no preceding atom at offset " &
        $i)
    else:
      atom = RegexAtom(kind: raLiteral, ch: c)
      inc i
    # Optional quantifier on this atom.
    if i < pattern.len and atom.kind in {raLiteral, raAnyChar, raCharClass}:
      case pattern[i]
      of '*':
        atom.quantStar = true
        inc i
      of '+':
        atom.quantPlus = true
        inc i
      of '?':
        atom.quantQuestion = true
        inc i
      else: discard
    result.atoms.add(atom)

proc atomMatchesChar(atom: RegexAtom; c: char): bool =
  case atom.kind
  of raLiteral: c == atom.ch
  of raAnyChar: c != '\n'
  of raCharClass:
    if atom.classNegated: c notin atom.classChars
    else: c in atom.classChars
  else: false

proc tryMatch(atoms: seq[RegexAtom]; atomIdx: int;
              text: string; pos: int;
              captures: var seq[tuple[lo, hi: int]];
              openGroups: var seq[int]): bool =
  ## Backtracking matcher. ``captures`` is the live capture-array
  ## (group N -> (lo, hi) into ``text``); ``openGroups`` is a stack of
  ## group indices currently being captured.
  if atomIdx >= atoms.len:
    # Pattern consumed; we always require full-text match.
    return pos == text.len
  let atom = atoms[atomIdx]
  case atom.kind
  of raAnchorStart:
    if pos != 0: return false
    return tryMatch(atoms, atomIdx + 1, text, pos, captures, openGroups)
  of raAnchorEnd:
    if pos != text.len: return false
    return tryMatch(atoms, atomIdx + 1, text, pos, captures, openGroups)
  of raGroupStart:
    captures.add((pos, -1))
    openGroups.add(captures.len - 1)
    if tryMatch(atoms, atomIdx + 1, text, pos, captures, openGroups):
      return true
    discard openGroups.pop()
    discard captures.pop()
    return false
  of raGroupEnd:
    if openGroups.len == 0:
      return false  # unbalanced ); compileRegex doesn't currently catch this
    let g = openGroups.pop()
    let savedHi = captures[g].hi
    captures[g].hi = pos
    if tryMatch(atoms, atomIdx + 1, text, pos, captures, openGroups):
      return true
    captures[g].hi = savedHi
    openGroups.add(g)
    return false
  of raLiteral, raAnyChar, raCharClass:
    if atom.quantStar or atom.quantPlus:
      # Greedy match: consume as many as we can, then backtrack.
      var maxCount = 0
      var p = pos
      while p < text.len and atomMatchesChar(atom, text[p]):
        inc maxCount
        inc p
      let minCount = if atom.quantPlus: 1 else: 0
      var n = maxCount
      while n >= minCount:
        if tryMatch(atoms, atomIdx + 1, text, pos + n,
                    captures, openGroups):
          return true
        dec n
      return false
    elif atom.quantQuestion:
      # Try with one consumed first, then zero.
      if pos < text.len and atomMatchesChar(atom, text[pos]):
        if tryMatch(atoms, atomIdx + 1, text, pos + 1,
                    captures, openGroups):
          return true
      return tryMatch(atoms, atomIdx + 1, text, pos, captures, openGroups)
    else:
      if pos >= text.len: return false
      if not atomMatchesChar(atom, text[pos]): return false
      return tryMatch(atoms, atomIdx + 1, text, pos + 1,
                      captures, openGroups)

proc matchFull*(compiled: CompiledRegex; text: string):
    tuple[ok: bool; captures: seq[string]] =
  ## Match ``text`` against ``compiled`` as a whole (anchored both
  ## sides). Returns captures keyed by group order (group 1 at index
  ## 0). ``ok`` is false on no match.
  var captures: seq[tuple[lo, hi: int]] = @[]
  var openGroups: seq[int] = @[]
  let ok = tryMatch(compiled.atoms, 0, text, 0, captures, openGroups)
  if not ok:
    return (false, @[])
  var capStrs: seq[string] = @[]
  for cap in captures:
    if cap.lo >= 0 and cap.hi >= cap.lo:
      capStrs.add(text[cap.lo ..< cap.hi])
    else:
      capStrs.add("")
  (true, capStrs)

proc matchesPattern*(pattern, text: string): bool =
  ## Convenience wrapper for asset-name matching: compiles the pattern
  ## and returns ``true`` iff ``text`` matches as a whole.
  let compiled = compileRegex(pattern)
  matchFull(compiled, text).ok

# ---------------------------------------------------------------------------
# Error types + asset/release shapes
# ---------------------------------------------------------------------------

type
  GhAsset* = object
    name*: string
    contentType*: string
    size*: int64
    digest*: string            ## "sha256:<hex>" when present; "" otherwise
    browserDownloadUrl*: string

  GhRelease* = object
    tagName*: string
    name*: string
    body*: string
    prerelease*: bool
    draft*: bool
    assets*: seq[GhAsset]

  GhReleasesHarvestError* = object of CatchableError

  GhRateLimitError* = object of GhReleasesHarvestError
    ## Distinct subtype so the CLI can name ``GITHUB_TOKEN`` in the
    ## remediation message. Mirrors the M6 ``Msys2HarvestError`` shape.

# ---------------------------------------------------------------------------
# SHA-256 of a downloaded file (shells out to host hashers).
# ---------------------------------------------------------------------------

proc fileSha256Hex*(path: string): string =
  ## Compute SHA-256 over the file at ``path`` by shelling out to the
  ## host hasher (``sha256sum`` / ``shasum`` / ``certutil`` /
  ## ``openssl``). Returns the hex digest in lowercase. Mirrors
  ## ``msys2_source.fileSha256Hex`` byte-for-byte — kept inline to
  ## avoid the harvester binary pulling cross-module surface for a
  ## tiny utility.
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
      raise newException(GhReleasesHarvestError,
        "no SHA-256 implementation available (tried sha256sum, " &
        "shasum, certutil, openssl)")
  let res = execCmdEx(command)
  if res.exitCode != 0:
    raise newException(GhReleasesHarvestError,
      "sha256 helper exited " & $res.exitCode & " for " & path &
      "\n" & res.output)
  for raw in res.output.splitLines:
    let line = raw.strip()
    if line.len == 0: continue
    var i = 0
    while i < line.len:
      var j = i
      while j < line.len and line[j] in {'0'..'9', 'a'..'f', 'A'..'F'}:
        inc j
      if j - i == 64:
        return line[i ..< j].toLowerAscii()
      if j == i: inc i
      else: i = j
  raise newException(GhReleasesHarvestError,
    "sha256 helper produced no 64-char hex digest in:\n" & res.output)

# ---------------------------------------------------------------------------
# Mock-friendly API fetcher
# ---------------------------------------------------------------------------
#
# The hermetic test harness sets ``REPRO_M7_API_FIXTURE_DIR`` to a local
# directory whose layout mirrors the GitHub REST API: under that root,
# ``<org>/<repo>/releases.json`` is the recorded response, and
# ``<org>/<repo>/assets/<filename>`` is the binary fixture for any asset
# whose ``browser_download_url`` points at
# ``https://github.com/<org>/<repo>/releases/download/<tag>/<filename>``.
# Production runs hit the live GitHub API; tests route through the
# fixture root for full determinism without a network call.

const FixtureDirEnv* = "REPRO_M7_API_FIXTURE_DIR"
const TokenEnvVar* = "GITHUB_TOKEN"

const UserAgentValue =
  "reprobuild-catalog-harvester/m7 (+https://github.com/metacraft-labs/reprobuild)"

proc authHeader*(): tuple[present: bool; header: string] =
  ## Returns the Authorization header value to forward, or ``("", false)``
  ## when ``GITHUB_TOKEN`` is unset. Exposed for the unit test that
  ## asserts auth-header forwarding without touching the network.
  let tok = getEnv(TokenEnvVar)
  if tok.len > 0:
    return (true, "Bearer " & tok)
  (false, "")

proc newGhClient(): HttpClient =
  result = newHttpClient(timeout = 30_000, userAgent = UserAgentValue)
  result.headers["Accept"] = "application/vnd.github+json"
  result.headers["X-GitHub-Api-Version"] = "2022-11-28"
  let (present, header) = authHeader()
  if present:
    result.headers["Authorization"] = header

proc fetchReleasesJsonRaw*(org, repo: string): string =
  ## Returns the raw JSON body of
  ## ``https://api.github.com/repos/<org>/<repo>/releases``. Honors the
  ## ``REPRO_M7_API_FIXTURE_DIR`` fixture mode for hermetic tests.
  ## Raises ``GhRateLimitError`` on a 403 with ``X-RateLimit-Remaining: 0``,
  ## naming the ``GITHUB_TOKEN`` env var in the diagnostic.
  let fixtureDir = getEnv(FixtureDirEnv)
  if fixtureDir.len > 0:
    let local = fixtureDir / org / repo / "releases.json"
    if not fileExists(local):
      raise newException(GhReleasesHarvestError,
        "fixture mode: no GitHub releases fixture at " & local)
    return readFile(local)
  let url = "https://api.github.com/repos/" & org & "/" & repo & "/releases"
  let client = newGhClient()
  defer: client.close()
  try:
    let resp = client.request(url, httpMethod = HttpGet)
    let body = resp.bodyStream.readAll()
    if resp.code.int == 403:
      let remaining = resp.headers.getOrDefault("x-ratelimit-remaining")
      if $remaining == "0":
        raise newException(GhRateLimitError,
          "GitHub API rate-limit hit (X-RateLimit-Remaining: 0). " &
          "Set the GITHUB_TOKEN environment variable to raise the " &
          "per-hour quota from 60 (unauthenticated) to 5000 " &
          "(authenticated). The token only needs ``public_repo`` " &
          "scope for harvesting public catalogs.")
      raise newException(GhReleasesHarvestError,
        "GitHub API returned 403 for " & url & ": " & body)
    if resp.code.int < 200 or resp.code.int >= 300:
      raise newException(GhReleasesHarvestError,
        "GitHub API returned " & $resp.code & " for " & url & ": " & body)
    return body
  except HttpRequestError as err:
    raise newException(GhReleasesHarvestError,
      "GitHub Releases fetch failed for " & url & ": " & err.msg)
  except OSError as err:
    raise newException(GhReleasesHarvestError,
      "GitHub Releases fetch failed for " & url & ": " & err.msg)

proc fetchAssetToFile*(asset: GhAsset; dest: string) =
  ## Download the asset's ``browser_download_url`` to ``dest``. Honors
  ## the fixture mode by mapping
  ## ``https://github.com/<org>/<repo>/releases/download/<tag>/<file>``
  ## to ``<fixtureDir>/<org>/<repo>/assets/<file>``.
  let fixtureDir = getEnv(FixtureDirEnv)
  if fixtureDir.len > 0:
    const prefix = "https://github.com/"
    if not asset.browserDownloadUrl.startsWith(prefix):
      raise newException(GhReleasesHarvestError,
        "fixture mode: asset URL '" & asset.browserDownloadUrl &
        "' is not under " & prefix)
    let rest = asset.browserDownloadUrl[prefix.len .. ^1]
    let parts = rest.split('/')
    # Shape: <org>/<repo>/releases/download/<tag>/<file>
    if parts.len < 6 or parts[2] != "releases" or parts[3] != "download":
      raise newException(GhReleasesHarvestError,
        "fixture mode: unrecognized asset URL shape '" &
        asset.browserDownloadUrl & "'")
    let org = parts[0]
    let repo = parts[1]
    let leaf = parts[^1]
    let local = fixtureDir / org / repo / "assets" / leaf
    if not fileExists(local):
      raise newException(GhReleasesHarvestError,
        "fixture mode: no asset fixture at " & local)
    copyFile(local, dest)
    return
  let client = newGhClient()
  defer: client.close()
  # downloadFile follows 30x redirects (GitHub's release downloads
  # 302 from api.github.com to the codeload mirror).
  try:
    client.downloadFile(asset.browserDownloadUrl, dest)
  except HttpRequestError as err:
    raise newException(GhReleasesHarvestError,
      "GitHub asset download failed for " & asset.browserDownloadUrl &
      ": " & err.msg)
  except OSError as err:
    raise newException(GhReleasesHarvestError,
      "GitHub asset download failed for " & asset.browserDownloadUrl &
      ": " & err.msg)

# ---------------------------------------------------------------------------
# JSON -> typed releases
# ---------------------------------------------------------------------------

proc parseAsset(node: JsonNode): GhAsset =
  if node.kind != JObject:
    raise newException(GhReleasesHarvestError,
      "expected asset to be an object; got " & $node.kind)
  result.name = node{"name"}.getStr()
  result.contentType = node{"content_type"}.getStr()
  result.size =
    if node.hasKey("size"): node["size"].getBiggestInt()
    else: 0
  result.digest = node{"digest"}.getStr()
  result.browserDownloadUrl = node{"browser_download_url"}.getStr()

proc parseRelease(node: JsonNode): GhRelease =
  if node.kind != JObject:
    raise newException(GhReleasesHarvestError,
      "expected release to be an object; got " & $node.kind)
  result.tagName = node{"tag_name"}.getStr()
  result.name = node{"name"}.getStr()
  result.body = node{"body"}.getStr()
  result.prerelease = node{"prerelease"}.getBool(false)
  result.draft = node{"draft"}.getBool(false)
  if node.hasKey("assets") and node["assets"].kind == JArray:
    for a in node["assets"]:
      result.assets.add(parseAsset(a))

proc parseReleases*(jsonBody: string): seq[GhRelease] =
  ## Parse the GitHub Releases API response body into typed releases.
  ## Used by both production fetches and the hermetic test fixture
  ## reader.
  var parsed: JsonNode
  try:
    parsed = parseJson(jsonBody)
  except JsonParsingError as err:
    raise newException(GhReleasesHarvestError,
      "GitHub Releases response is not valid JSON: " & err.msg)
  if parsed.kind != JArray:
    raise newException(GhReleasesHarvestError,
      "GitHub Releases response expected to be a JSON array; got " &
      $parsed.kind)
  for node in parsed:
    result.add(parseRelease(node))

proc fetchReleases*(org, repo: string;
                    includePrereleases: bool = false): seq[GhRelease] =
  ## Fetch + parse the releases for ``<org>/<repo>``. Skips draft
  ## releases unconditionally (drafts are not publicly downloadable);
  ## skips prereleases unless ``includePrereleases`` is true.
  let raw = fetchReleasesJsonRaw(org, repo)
  let all = parseReleases(raw)
  for r in all:
    if r.draft: continue
    if r.prerelease and not includePrereleases: continue
    result.add(r)

# ---------------------------------------------------------------------------
# Asset selection
# ---------------------------------------------------------------------------

proc selectAsset*(release: GhRelease; pattern: string): GhAsset =
  ## Pick the single asset whose name matches ``pattern``. Raises
  ## ``GhReleasesHarvestError`` with the available asset list when zero
  ## or multiple assets match — the operator MUST narrow the pattern;
  ## the harvester does not silently pick the first.
  if release.assets.len == 0:
    raise newException(GhReleasesHarvestError,
      "release '" & release.tagName & "' has no assets")
  var compiled: CompiledRegex
  try:
    compiled = compileRegex(pattern)
  except RegexParseError as err:
    raise newException(GhReleasesHarvestError,
      "invalid --asset-pattern '" & pattern & "': " & err.msg)
  var matches: seq[GhAsset] = @[]
  for a in release.assets:
    if matchFull(compiled, a.name).ok:
      matches.add(a)
  if matches.len == 0:
    var available: seq[string] = @[]
    for a in release.assets: available.add(a.name)
    raise newException(GhReleasesHarvestError,
      "no asset in release '" & release.tagName &
      "' matches pattern '" & pattern & "'. Available assets:\n  " &
      available.join("\n  "))
  if matches.len > 1:
    var matched: seq[string] = @[]
    for m in matches: matched.add(m.name)
    raise newException(GhReleasesHarvestError,
      "pattern '" & pattern & "' matched MULTIPLE assets in release '" &
      release.tagName & "'; refine the pattern. Matched:\n  " &
      matched.join("\n  "))
  matches[0]

# ---------------------------------------------------------------------------
# Tag-to-version extraction
# ---------------------------------------------------------------------------

proc extractVersion*(tag: string; extractRegex: string = ""): string =
  ## Apply ``extractRegex`` to the tag and return capture group 1; if
  ## no regex is supplied, return the tag verbatim. The most common
  ## use case is stripping a leading ``v`` (``^v(.+)$``). Raises if
  ## the regex fails to match (the operator's pattern should always
  ## match the latest tag — a mismatch implies an upstream tag-shape
  ## change worth surfacing rather than silently absorbing).
  if extractRegex.len == 0:
    return tag
  var compiled: CompiledRegex
  try:
    compiled = compileRegex(extractRegex)
  except RegexParseError as err:
    raise newException(GhReleasesHarvestError,
      "invalid --version-extract regex '" & extractRegex & "': " & err.msg)
  if compiled.numGroups != 1:
    raise newException(GhReleasesHarvestError,
      "--version-extract regex '" & extractRegex & "' must contain " &
      "exactly one capture group; got " & $compiled.numGroups)
  let (ok, captures) = matchFull(compiled, tag)
  if not ok:
    raise newException(GhReleasesHarvestError,
      "tag '" & tag & "' did not match --version-extract regex '" &
      extractRegex & "'. The regex must contain exactly one capture " &
      "group whose match becomes the catalog version.")
  if captures.len == 0 or captures[0].len == 0:
    raise newException(GhReleasesHarvestError,
      "--version-extract regex '" & extractRegex & "' matched tag '" &
      tag & "' but the capture group was empty")
  captures[0]

# ---------------------------------------------------------------------------
# Archive-format inference (asset name -> ArchiveFormat)
# ---------------------------------------------------------------------------

proc inferArchiveFormatFromName*(name: string):
    tuple[fmt: ArchiveFormat; known: bool] =
  ## Match in longest-suffix-first order; mirrors the manifest_parser
  ## ``inferArchiveFormat`` shape but operates on a plain asset name
  ## (no URL query / fragment cleanup needed — GitHub asset names are
  ## literal). The ``known`` flag lets the caller surface a diagnostic
  ## when the asset's extension is unrecognized (the catalog still
  ## emits with ``afRaw`` but realize-time extraction will fail).
  let lower = name.toLowerAscii()
  if lower.endsWith(".tar.gz") or lower.endsWith(".tgz"):
    return (afTarGz, true)
  if lower.endsWith(".tar.xz") or lower.endsWith(".txz"):
    return (afTarXz, true)
  if lower.endsWith(".tar.bz2") or lower.endsWith(".tbz2"):
    return (afTarBz2, true)
  if lower.endsWith(".tar.zst") or lower.endsWith(".tzst") or
     lower.endsWith(".pkg.tar.zst"):
    return (afTarZst, true)
  if lower.endsWith(".7z.exe"):
    return (afSevenZipSfx, true)
  if lower.endsWith(".7z"):
    return (afSevenZip, true)
  if lower.endsWith(".zip"):
    return (afZip, true)
  if lower.endsWith(".msi"):
    return (afInstallerMsi, true)
  if lower.endsWith(".exe"):
    # A bare ``.exe`` on GitHub Releases is almost always a single-binary
    # download (alire's ``alr-...-installer-...exe`` notwithstanding —
    # those use ``--asset-pattern`` to exclude). Realize as ``afRaw``.
    return (afRaw, true)
  (afRaw, false)

# ---------------------------------------------------------------------------
# OS / CPU inference (best-effort, optional)
# ---------------------------------------------------------------------------
#
# M7's primary target is the operator-driven case: ``--asset-pattern``
# narrows to one platform per harvest invocation, so the OS/CPU are
# implied by the pattern itself (e.g. ``...windows.zip`` -> Windows).
# The harvester nevertheless tries to infer (OS, CPU) from the asset
# name so the emitted ``PlatformBinary`` carries the correct tags.
# When inference fails the operator can override via ``--platform-os``
# / ``--platform-cpu``.

proc inferPlatformOs*(name: string): PlatformOs =
  let lower = name.toLowerAscii()
  if "windows" in lower or "win32" in lower or "win64" in lower or
     lower.endsWith(".exe") or lower.endsWith(".msi"):
    return poWindows
  if "macos" in lower or "darwin" in lower or "osx" in lower or
     "apple" in lower:
    return poMacos
  if "linux" in lower or "ubuntu" in lower or "debian" in lower or
     "alpine" in lower:
    return poLinux
  poAny

proc inferPlatformCpu*(name: string): PlatformCpu =
  let lower = name.toLowerAscii()
  if "x86_64" in lower or "x64" in lower or "amd64" in lower:
    return pcX86_64
  if "aarch64" in lower or "arm64" in lower:
    return pcAArch64
  if "x86" in lower or "i686" in lower or "i386" in lower:
    return pcX86
  pcAny

# ---------------------------------------------------------------------------
# Digest extraction (prefer asset.digest; else compute from bytes)
# ---------------------------------------------------------------------------

proc computeOrTakeSha256*(asset: GhAsset; downloadedFile: string): string =
  ## Prefer the asset's ``digest`` field when it begins with
  ## ``sha256:`` and carries a 64-char hex tail; otherwise compute the
  ## hash from the downloaded bytes via ``fileSha256Hex``. Returns the
  ## hex digest in lowercase (matches the schema's ``sha256`` shape).
  if asset.digest.startsWith("sha256:"):
    let hex = asset.digest[7 .. ^1]
    if hex.len == 64:
      var allHex = true
      for ch in hex:
        if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
          allHex = false
          break
      if allHex:
        return hex.toLowerAscii()
  if not fileExists(downloadedFile):
    raise newException(GhReleasesHarvestError,
      "asset.digest is missing/non-sha256 and the downloaded file is " &
      "absent at " & downloadedFile & "; cannot compute sha256")
  fileSha256Hex(downloadedFile).toLowerAscii()

# ---------------------------------------------------------------------------
# Resolution: pick a release by latest / version pin
# ---------------------------------------------------------------------------

proc selectRelease*(releases: seq[GhRelease];
                    versionPin: string = "";
                    extractRegex: string = ""): GhRelease =
  ## Pick the release matching ``versionPin`` (post-extraction) when
  ## set, else the FIRST non-draft non-prerelease entry (GitHub returns
  ## releases newest-first by published_at). Raises when no candidate
  ## matches.
  if releases.len == 0:
    raise newException(GhReleasesHarvestError,
      "no releases available (after draft/prerelease filtering)")
  if versionPin.len == 0:
    return releases[0]
  for r in releases:
    let extracted = extractVersion(r.tagName, extractRegex)
    if extracted == versionPin or r.tagName == versionPin:
      return r
  var availableTags: seq[string] = @[]
  for r in releases: availableTags.add(r.tagName)
  raise newException(GhReleasesHarvestError,
    "no release matches version pin '" & versionPin & "'. " &
    "Available tags:\n  " & availableTags.join("\n  "))

# ---------------------------------------------------------------------------
# Public entry point: harvest one (release, asset) -> VersionedProvisioning
# ---------------------------------------------------------------------------

type
  GhHarvestOpts* = object
    org*: string
    repo*: string
    assetPattern*: string         ## REQUIRED regex over asset.name
    versionExtract*: string       ## OPTIONAL regex; default: tag verbatim
    versionPin*: string           ## OPTIONAL exact version match
    includePrereleases*: bool
    cacheDir*: string             ## download cache; default platform-derived
    overrideOs*: PlatformOs       ## poAny = infer from asset name
    overrideCpu*: PlatformCpu     ## pcAny = infer from asset name
    binRelpath*: seq[string]      ## REQUIRED non-empty bin_relpath
                                  ## (operator-supplied; the harvester
                                  ## does NOT introspect the archive in
                                  ## M7 — too many archive formats to
                                  ## cover cleanly)
    extractPath*: string          ## OPTIONAL inner-dir flatten path

proc defaultCacheDir(): string =
  let xdg = getEnv("XDG_CACHE_HOME")
  let base =
    if xdg.len > 0: xdg
    else:
      when defined(windows):
        let local = getEnv("LOCALAPPDATA")
        if local.len > 0: local
        else: getHomeDir() / ".cache"
      else: getHomeDir() / ".cache"
  base / "repro-catalog-harvester" / "gh-releases"

proc harvestGhRelease*(opts: GhHarvestOpts): VersionedProvisioning =
  ## End-to-end harvest of one (release, asset) tuple. Returns a
  ## ``VersionedProvisioning`` ready for ``emitCatalogFile``.
  ##
  ## Steps:
  ##   1. Fetch the releases list (or read the fixture);
  ##   2. Pick the release matching ``versionPin`` or the latest non-
  ##      prerelease;
  ##   3. Select the asset matching ``assetPattern``;
  ##   4. Download to the cache;
  ##   5. Compute or take sha256;
  ##   6. Infer archive format + OS + CPU (with operator override);
  ##   7. Compose the VersionedProvisioning.
  if opts.assetPattern.len == 0:
    raise newException(GhReleasesHarvestError,
      "GhHarvestOpts.assetPattern is required (operator must specify " &
      "--asset-pattern; auto-discovery is out of M7 scope)")
  if opts.binRelpath.len == 0:
    raise newException(GhReleasesHarvestError,
      "GhHarvestOpts.binRelpath is required (operator must specify " &
      "--bin-relpath at least once; the M7 harvester does not " &
      "introspect downloaded archives)")
  let releases = fetchReleases(opts.org, opts.repo, opts.includePrereleases)
  let release = selectRelease(releases, opts.versionPin, opts.versionExtract)
  let asset = selectAsset(release, opts.assetPattern)

  let cache =
    if opts.cacheDir.len > 0: opts.cacheDir
    else: defaultCacheDir()
  createDir(cache)
  let downloadPath = cache / asset.name
  if not fileExists(downloadPath):
    fetchAssetToFile(asset, downloadPath)
  let sha = computeOrTakeSha256(asset, downloadPath)

  let (archiveFmt, _) = inferArchiveFormatFromName(asset.name)
  let osChoice =
    if opts.overrideOs != poAny: opts.overrideOs
    else: inferPlatformOs(asset.name)
  let cpuChoice =
    if opts.overrideCpu != pcAny: opts.overrideCpu
    else: inferPlatformCpu(asset.name)

  let version = extractVersion(release.tagName, opts.versionExtract)

  # Default install method: imExtract for archives, imExtract w/ afRaw
  # for single binaries (the realize hook treats afRaw as "place the
  # downloaded file at bin_relpath[0]"). M7 does not emit installer
  # methods — operators publishing MSI-only on GitHub Releases would
  # need a follow-up flag.
  result = initVersionedProvisioning(
    version = version,
    archive_format = archiveFmt,
    install_method = imExtract,
    bin_relpath = opts.binRelpath,
    platforms = @[
      initPlatformBinary(
        cpu = cpuChoice, os = osChoice,
        url = asset.browserDownloadUrl,
        sha256 = sha,
        extract_path = opts.extractPath)
    ])

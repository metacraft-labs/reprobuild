## Reprobuild-Binary-Cache-Fleet R1 — binary-cache CLIENT config.
##
## The A2/A2.5 client had NO runtime config: it read a single
## ``REPRO_BINARY_CACHE_URL`` env var and trusted whatever that URL
## served. R1 introduces a durable config MECHANISM plus the
## default-untrusted trust model: a cache is used for substitution
## ONLY when the config carries an explicit entry that lists the
## producer public key(s) we accept for it. A manifest signed by any
## other key (or unsigned) is a cache MISS, never a silent trust.
##
## ## File format (INI-style, parsed by ``std/parsecfg``)
##
## Chosen over TOML because reprobuild vendors no TOML parser and
## ``std/parsecfg`` ships with Nim (already on the recipe-import
## allowlist). One section per cache:
##
##   [fleet]
##   url = "https://repro-cache.example:7878"
##   trusted-public-keys = "04ab…, 04cd…"
##   priority = 20
##
##   [local]
##   url = "http://localhost:7878"
##   trusted-public-keys = "04ef…"
##   priority = 10
##
## The section header is the cache NAME. ``std/parsecfg`` section
## headers do not accept quotes inside the brackets, so an optional
## ``cache`` prefix word is allowed as sugar (``[cache fleet]`` ==
## ``[fleet]``). Keys:
##
##   * ``url``                 — HTTP(S) base URL of the cache.
##   * ``trusted-public-keys`` — comma- and/or whitespace-separated
##                               list of 65-byte (130-hex-char)
##                               uncompressed ECDSA-P256 public keys.
##                               An entry with NONE is never
##                               substituted from (default-untrusted).
##   * ``priority``            — integer; LOWER wins (Nix convention).
##                               Defaults to ``DefaultCachePriority``.
##
## ## Paths + precedence
##
##   1. If ``REPRO_CACHES_CONFIG`` is set, ONLY that file is read (it
##      fully replaces the system + user files). Missing => no caches.
##   2. Otherwise the SYSTEM file (``/etc/repro/caches.conf`` on
##      POSIX) is read first, then the per-USER file
##      (``$XDG_CONFIG_HOME/repro/caches.conf`` ~
##      ``~/.config/repro/caches.conf``). The user file OVERRIDES /
##      EXTENDS the system file: a cache whose name repeats replaces
##      the system definition; new names are appended.
##   3. Back-compat: ``REPRO_BINARY_CACHE_URL`` (if set) is folded in
##      as an implicit cache named ``env`` at ``EnvCachePriority``
##      (lowest). Its trusted key comes from the producer cert at
##      ``REPRO_BINARY_CACHE_CERT_PATH`` when that file is present
##      (the single-producer legacy setup trusts its own producer key
##      — explicit, not "trust anything"). With no cert configured the
##      env cache carries NO trusted key and, under default-untrusted,
##      is never substituted from (a MISS).
##
## The loader returns endpoints sorted by ascending priority so
## ``substituteInProcess`` tries the most-preferred cache first and
## falls through to the next on a miss / trust-rejection.

import std/[os, parsecfg, streams, strutils, algorithm, tables]

import ./types
import ../../../repro_peer_cache/src/repro_peer_cache/key_types as peerKeys

const
  DefaultCachePriority* = 30'i32
    ## Priority used for a config cache that omits ``priority``.
    ## Matches the server's ``DefaultPriority`` so an unqualified
    ## client + server agree by default.
  EnvCachePriority* = 1000'i32
    ## Implicit ``REPRO_BINARY_CACHE_URL`` cache sits below every
    ## explicitly-configured cache (higher number = lower preference).

  SystemConfigPathPosix* = "/etc/repro/caches.conf"
  UserConfigRelPath* = "repro/caches.conf"
  ConfigPathEnvVar* = "REPRO_CACHES_CONFIG"
  EnvUrlVar* = "REPRO_BINARY_CACHE_URL"
  EnvCertVar* = "REPRO_BINARY_CACHE_CERT_PATH"

type
  CacheConfigError* = object of CatchableError
    ## Raised on a malformed config file (bad hex key, unparsable
    ## priority, …). A MISSING file is not an error — it yields no
    ## caches.

  CacheEntry* = object
    ## One parsed ``[cache "name"]`` section.
    name*: string
    url*: string
    trustedKeys*: seq[peerKeys.PublicKeyBytes]
    priority*: int32

# ---------------------------------------------------------------------------
# Path resolution.
# ---------------------------------------------------------------------------

proc systemConfigPath*(): string =
  when defined(windows):
    let base = getEnv("PROGRAMDATA", "C:\\ProgramData")
    result = base / "repro" / "caches.conf"
  else:
    result = SystemConfigPathPosix

proc userConfigPath*(): string =
  let xdg = getEnv("XDG_CONFIG_HOME", "")
  if xdg.len > 0:
    result = xdg / UserConfigRelPath
  else:
    result = getHomeDir() / ".config" / UserConfigRelPath

# ---------------------------------------------------------------------------
# Hex → PublicKeyBytes (65-byte uncompressed ECDSA-P256).
# ---------------------------------------------------------------------------

proc parsePubKeyHex(hex: string): peerKeys.PublicKeyBytes =
  ## Parses a 130-char (65-byte) uncompressed ECDSA-P256 pubkey hex.
  ## Raises ``CacheConfigError`` on a wrong length / non-hex digit.
  let h = hex.strip()
  if h.len != peerKeys.P256PubLen * 2:
    raise newException(CacheConfigError,
      "trusted-public-keys entry must be " & $(peerKeys.P256PubLen * 2) &
      " hex chars (" & $peerKeys.P256PubLen & " bytes); got " & $h.len &
      ": '" & h & "'")
  for i in 0 ..< peerKeys.P256PubLen:
    let hi = h[2 * i]
    let lo = h[2 * i + 1]
    if hi notin HexDigits or lo notin HexDigits:
      raise newException(CacheConfigError,
        "trusted-public-keys entry has non-hex digit at position " &
        $(2 * i) & ": '" & h & "'")
    result[i] = byte((parseHexInt($hi) shl 4) or parseHexInt($lo))

proc splitKeyList(raw: string): seq[string] =
  ## Splits a trusted-public-keys value on commas and/or whitespace,
  ## dropping empties. Lets a config write either
  ## ``"04ab…, 04cd…"`` or ``"04ab… 04cd…"``.
  result = @[]
  for tok in raw.multiReplace((",", " ")).splitWhitespace():
    if tok.len > 0:
      result.add(tok)

# ---------------------------------------------------------------------------
# Parser.
# ---------------------------------------------------------------------------

proc sectionCacheName(section: string): string =
  ## Normalises a section header into a cache name. ``std/parsecfg``
  ## already stripped the brackets; a leading ``cache`` word is
  ## optional sugar (``[cache fleet]`` == ``[fleet]``). A quoted name
  ## (``["fleet"]`` / ``[cache "fleet"]``) is tolerated too in case a
  ## future parser preserves the quotes.
  var s = section.strip()
  if s.len > 6 and (s.startsWith("cache ") or s.startsWith("cache\t")):
    s = s[len("cache") .. ^1].strip()
  # Strip surrounding quotes if present.
  if s.len >= 2 and s[0] == '"' and s[^1] == '"':
    s = s[1 ..< ^1]
  result = s

proc parseCachesText*(text, sourceLabel: string): seq[CacheEntry] =
  ## Parses config TEXT into cache entries (order preserved). Raises
  ## ``CacheConfigError`` on a malformed key / value. ``sourceLabel``
  ## is only used in error messages.
  result = @[]
  var stream = newStringStream(text)
  var p: CfgParser
  open(p, stream, sourceLabel)
  defer: close(p)
  var cur = CacheEntry(priority: DefaultCachePriority)
  var inSection = false
  while true:
    let e = next(p)
    case e.kind
    of cfgEof:
      if inSection:
        result.add(cur)
      break
    of cfgSectionStart:
      if inSection:
        result.add(cur)
      cur = CacheEntry(name: sectionCacheName(e.section),
                       priority: DefaultCachePriority)
      inSection = true
    of cfgKeyValuePair, cfgOption:
      if not inSection:
        raise newException(CacheConfigError,
          sourceLabel & ": key '" & e.key & "' appears before any " &
          "[cache \"…\"] section")
      case e.key.toLowerAscii()
      of "url":
        cur.url = e.value.strip()
      of "trusted-public-keys", "trusted_public_keys":
        for keyHex in splitKeyList(e.value):
          cur.trustedKeys.add(parsePubKeyHex(keyHex))
      of "priority":
        try:
          cur.priority = int32(parseInt(e.value.strip()))
        except ValueError:
          raise newException(CacheConfigError,
            sourceLabel & ": cache '" & cur.name &
            "' priority is not an integer: '" & e.value & "'")
      else:
        # Unknown keys are ignored (forward-compat for future fields).
        discard
    of cfgError:
      raise newException(CacheConfigError,
        sourceLabel & ": " & e.msg)

proc parseCachesFile*(path: string): seq[CacheEntry] =
  ## Reads + parses one config file. A MISSING file yields ``@[]``
  ## (not an error). Propagates ``CacheConfigError`` on malformed
  ## content.
  if not fileExists(path):
    return @[]
  result = parseCachesText(readFile(path), path)

# ---------------------------------------------------------------------------
# Merge + env fold-in.
# ---------------------------------------------------------------------------

proc mergeByName(base, overlay: seq[CacheEntry]): seq[CacheEntry] =
  ## User file overrides / extends the system file: an overlay cache
  ## whose name repeats a base cache REPLACES it (keeping the base's
  ## slot position for determinism); a new name is appended.
  result = base
  var indexByName = initTable[string, int]()
  for i, c in result:
    indexByName[c.name] = i
  for c in overlay:
    if indexByName.hasKey(c.name):
      result[indexByName[c.name]] = c
    else:
      indexByName[c.name] = result.len
      result.add(c)

proc envCertPubKey(): seq[peerKeys.PublicKeyBytes] =
  ## Reads the producer public key from ``REPRO_BINARY_CACHE_CERT_PATH``
  ## (a bare 130-hex-char ECDSA-P256 pubkey line) if that env var is
  ## set and the file exists. This is the SINGLE-PRODUCER back-compat
  ## trust anchor: a legacy setup that configures its producer cert
  ## trusts THAT producer key for the env cache — explicit, not
  ## "trust anything". Returns ``@[]`` when unavailable (=> the env
  ## cache stays untrusted => a MISS, honouring default-untrusted).
  result = @[]
  let certPath = getEnv(EnvCertVar, "").strip()
  if certPath.len == 0 or not fileExists(certPath):
    return
  for line in readFile(certPath).splitLines():
    let h = line.strip()
    if h.len == 0 or h.startsWith("#"):
      continue
    try:
      result.add(parsePubKeyHex(h))
    except CacheConfigError:
      discard   # not a pubkey line (e.g. a private-key marker); skip.
    break

proc foldEnvUrl(entries: seq[CacheEntry]): seq[CacheEntry] =
  ## Back-compat: if ``REPRO_BINARY_CACHE_URL`` is set AND no
  ## configured cache already names that URL, append an implicit
  ## ``env`` cache. Its trusted key is taken from the producer cert at
  ## ``REPRO_BINARY_CACHE_CERT_PATH`` when present (single-producer
  ## back-compat); otherwise it carries NO trusted keys and — under
  ## default-untrusted — is therefore never substituted from. Kept so
  ## a legacy env-only setup keeps working when a producer cert is
  ## configured, while an env-URL with no producer key is a MISS.
  result = entries
  let envUrl = getEnv(EnvUrlVar, "").strip()
  if envUrl.len == 0:
    return
  for c in entries:
    if c.url == envUrl:
      return   # a configured cache already covers this URL.
  result.add(CacheEntry(
    name: "env",
    url: envUrl,
    trustedKeys: envCertPubKey(),
    priority: EnvCachePriority))

# ---------------------------------------------------------------------------
# Public entry points.
# ---------------------------------------------------------------------------

proc loadCacheEntries*(): seq[CacheEntry] =
  ## Resolves the effective cache list per the documented precedence
  ## (``REPRO_CACHES_CONFIG`` override, else system+user merge), folds
  ## in the ``REPRO_BINARY_CACHE_URL`` back-compat cache, and returns
  ## the entries. NOT sorted (see ``loadEndpoints``).
  let overridePath = getEnv(ConfigPathEnvVar, "")
  var merged: seq[CacheEntry]
  if overridePath.len > 0:
    merged = parseCachesFile(overridePath)
  else:
    let sys = parseCachesFile(systemConfigPath())
    let usr = parseCachesFile(userConfigPath())
    merged = mergeByName(sys, usr)
  result = foldEnvUrl(merged)

proc toEndpoint*(c: CacheEntry): SubstituteEndpoint =
  ## Converts a parsed cache entry into a substitute endpoint with
  ## trust enforcement ENABLED — an endpoint with no trusted keys is
  ## therefore rejected at substitute time (default-untrusted).
  SubstituteEndpoint(
    baseUrl: c.url,
    trustedSigners: c.trustedKeys,
    priority: c.priority,
    enforceTrust: true)

proc loadEndpoints*(): seq[SubstituteEndpoint] =
  ## The CLI/substitute entry point: the effective cache list turned
  ## into trust-enforcing endpoints, sorted by ascending priority
  ## (lower wins). Caches with an empty URL are dropped.
  var entries = loadCacheEntries()
  entries.sort(proc (a, b: CacheEntry): int = cmp(a.priority, b.priority))
  result = @[]
  for c in entries:
    if c.url.len == 0:
      continue
    result.add(toEndpoint(c))

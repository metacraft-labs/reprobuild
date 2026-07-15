## `repro cache <subcommand>` dispatch — the shared client machinery.
##
## This is the single implementation behind the `repro cache` subcommand
## group (see reprobuild-specs Binary-Caches.md §"Client CLI Surface
## (`repro cache`)"). It was folded out of the historical standalone
## ``repro-binary-cache-client`` binary — that executable was the
## identical toolset under a different ``pname`` — so both the shipping
## ``repro cache …`` entry point and the binary-cache integration-test
## helper drive ONE copy of the handlers.
##
## The dispatcher adds no behaviour beyond argv parsing + process exit
## codes; it routes each subcommand to the same ``substituteInProcess`` +
## HTTP-publish machinery the build engine uses during ``repro build``.
##
## ## Subcommands
##
##   lookup     <entry-key-hex>
##     GET /manifests/<hex>; exit 0 on 200, 1 on 404. Quiet on success;
##     prints "miss" on miss.
##
##   substitute <entry-key-hex> <out-prefix-dir>
##     Walks the closure; on success extracts the realised prefix into
##     ``<out-prefix-dir>``. Exit 0 on hit, 1 on miss / error.
##
##   publish    <entry-key-hex> <prefix-dir>
##     Packages ``<prefix-dir>`` into a deterministic archive (see
##     "Archive format" below), signs a binary-cache manifest with the
##     supplied ECDSA-P256 key, POSTs the manifest + payload to the
##     server. The cache-entry key supplied on the command line is
##     used to LABEL the manifest; for v1 the build script computes
##     it via ``deriveCacheEntryKey`` and threads the hex through.
##
## ## Cache config + trust (Reprobuild-Binary-Cache-Fleet R1)
##
## ``substitute`` no longer trusts whatever ``REPRO_BINARY_CACHE_URL``
## serves. It reads a config file listing caches with their trusted
## producer public keys and only substitutes from a cache when the
## fetched manifest is signed by one of THAT cache's trusted keys.
##
##   * Precedence: ``REPRO_CACHES_CONFIG`` (single file, overrides
##     everything) else ``/etc/repro/caches.conf`` (system) merged
##     with ``~/.config/repro/caches.conf`` (user overrides/extends).
##   * Format (INI-style, one section per cache):
##
##       [cache "fleet"]
##       url = "https://repro-cache:7878"
##       trusted-public-keys = "04ab…"   # 130-hex ECDSA-P256, comma/space list
##       priority = 20                    # lower wins
##
##   * DEFAULT-UNTRUSTED: a cache with no ``trusted-public-keys`` is
##     never substituted from — a MISS, never a silent trust. An
##     untrusted / unsigned / tampered manifest is likewise a MISS.
##   * Multi-cache: caches are tried in ascending priority order; a
##     miss (or trust rejection) on one falls through to the next.
##   * Back-compat: ``REPRO_BINARY_CACHE_URL`` is folded in as an
##     implicit lowest-priority cache. Its trusted key is read from
##     the producer cert at ``REPRO_BINARY_CACHE_CERT_PATH`` when that
##     file is present (single-producer legacy setup); with no cert
##     configured it stays untrusted and is a MISS.
##
## ## Environment variables
##
##   REPRO_CACHES_CONFIG             Override cache config path (single
##                                   file; replaces system + user).
##   REPRO_BINARY_CACHE_URL          Default ``http://localhost:7878``.
##   REPRO_BINARY_CACHE_KEY_PATH     ECDSA-P256 private key (the
##                                   ``ecdsa-p256:<hex>`` format used by
##                                   ``repro_peer_cache``). Required for
##                                   ``publish``. ``substitute`` /
##                                   ``lookup`` do not need it.
##   REPRO_BINARY_CACHE_CERT_PATH    Matching pub key file (65-byte
##                                   uncompressed hex). Required for
##                                   ``publish``.
##   REPRO_LOCAL_STORE               Local store root for the substitute
##                                   sink. Defaults to ``$HOME/.local/
##                                   share/repro/local-store``.
##
## ## Archive format (``rbcarc-v2``)
##
## A flat, deterministic archive used in place of ``tar``:
##
##   magic        "RBCA"
##   version      u32-le == 2
##   entryCount   u32-le
##   for each entry:
##     pathLen   u32-le
##     path      utf-8 bytes (forward-slash separators, repeating "../"
##               forbidden so extract cannot escape the prefix root)
##     kind      u8 (0 regular file, 1 directory, 2 symbolic link)
##     mode      u32-le (POSIX permission bits; preserved exactly on POSIX.
##               Windows uses 0o755 for executable-looking extensions and
##               0o644 for other files because it has no equivalent mode).
##     size      u64-le
##     bytes     raw file bytes, or the symlink target for kind 2
##
## v2 records empty directories and symlinks without dereferencing them.
## The reader continues to accept v1 archives, whose entries are regular
## files, so existing cache content remains substitutable.

import std/[httpclient, httpcore, net, os, parseopt, strutils]

when defined(ssl):
  import wrappers/openssl

import ../repro_binary_cache_client
import ./in_process as inProcessArchive
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

const
  DefaultUrl = "http://localhost:7878"
  Usage = """
repro cache — binary-cache client (single-entry publish/substitute wiring).

Usage:
  repro cache lookup     <entry-key-hex>
  repro cache substitute <entry-key-hex> <out-prefix-dir>
  repro cache publish    <entry-key-hex> <prefix-dir>   [identity-flags]
  repro cache derive-key                                 [identity-flags]
  repro cache gen-key                                    [identity-flags]

Identity flags (for publish + derive-key):
  --package-name=NAME       --package-version=VER
  --platform-cpu=CPU        --platform-os=OS
  --platform-abi=ABI        --platform-libc=LIBC
  --toolchain-name=N        --toolchain-version=V
  --toolchain-host-ldso=LDSO  --toolchain-extra=FP
  --provider-revision=HEX
  --dep=<hex>               (repeatable)
  --option=<name>=<value>   (repeatable)

Cache config (substitute, R1 default-untrusted):
  REPRO_CACHES_CONFIG             override config path (system+user else
                                  /etc/repro/caches.conf + ~/.config/repro/caches.conf)
  A cache is substituted from ONLY when the config lists its trusted
  producer public key(s) and the manifest is signed by one of them.

Environment:
  REPRO_BINARY_CACHE_URL          default http://localhost:7878
  REPRO_BINARY_CACHE_KEY_PATH     ECDSA-P256 private key (required for publish)
  REPRO_BINARY_CACHE_CERT_PATH    matching pubkey file       (required for publish)
  REPRO_LOCAL_STORE               local store root for substitute
"""

type
  PublishArgs = object
    entryKeyHex: string
    prefixDir: string
    packageName: string
    packageVersion: string
    platformCpu: string
    platformOs: string
    platformAbi: string
    platformLibc: string
    toolchainName: string
    toolchainVersion: string
    toolchainHostLdSo: string
    toolchainExtra: string
    providerRevision: string
    depHex: seq[string]
    options: seq[(string, string)]

# ---------------------------------------------------------------------------
# Archive extraction
# ---------------------------------------------------------------------------

proc extractPrefix(archive: openArray[byte]; outDir: string) =
  inProcessArchive.extractPrefix(archive, outDir)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc defaultCacheUrl(): string =
  result = getEnv("REPRO_BINARY_CACHE_URL", DefaultUrl)

proc newCacheHttpClient(url: string; timeoutMs: int): HttpClient =
  ## Windows-Runner-Binary-Cache-Deploy M6 — HTTP client that speaks
  ## HTTPS to an https:// endpoint. Under -d:ssl an https URL gets an SSL
  ## context honoring REPRO_BINARY_CACHE_CA_FILE / _TLS_INSECURE; plain
  ## http (and non-ssl builds) keep the default client.
  when defined(ssl):
    if url.toLowerAscii().startsWith("https://"):
      var openSslInitialized {.global.} = false
      if not openSslInitialized:
        discard SSL_library_init()
        openSslInitialized = true
      let caFile = getEnv("REPRO_BINARY_CACHE_CA_FILE", "")
      let insecure = getEnv("REPRO_BINARY_CACHE_TLS_INSECURE", "") in
        ["1", "true", "yes"]
      let ctx =
        if insecure: newContext(verifyMode = CVerifyNone)
        elif caFile.len > 0: newContext(verifyMode = CVerifyPeer, caFile = caFile)
        else: newContext(verifyMode = CVerifyPeer)
      return newHttpClient(timeout = timeoutMs, sslContext = ctx)
    return newHttpClient(timeout = timeoutMs, sslContext = nil)
  else:
    return newHttpClient(timeout = timeoutMs)

proc defaultStoreRoot(): string =
  let envRoot = getEnv("REPRO_LOCAL_STORE", "")
  if envRoot.len > 0:
    return envRoot
  when defined(windows):
    return getHomeDir() / "AppData" / "Local" / "repro" / "local-store"
  else:
    return getHomeDir() / ".local" / "share" / "repro" / "local-store"

proc parseEntryKeyHex(hex: string): string =
  ## Normalises + validates the entry-key hex CLI argument.
  if hex.len != 64:
    raise newException(ValueError,
      "entry-key hex must be 64 chars; got " & $hex.len)
  for ch in hex:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      raise newException(ValueError,
        "entry-key hex carries non-hex char: " & hex)
  result = hex.toLowerAscii()

proc loadProducerKeypair(): peerAuth.PeerKeypair =
  let keyPath = getEnv("REPRO_BINARY_CACHE_KEY_PATH", "")
  let certPath = getEnv("REPRO_BINARY_CACHE_CERT_PATH", "")
  if keyPath.len == 0 or certPath.len == 0:
    raise newException(ValueError,
      "publish requires REPRO_BINARY_CACHE_KEY_PATH + " &
      "REPRO_BINARY_CACHE_CERT_PATH to be set")
  result = peerAuth.loadOrGenerateKeypair(certPath, keyPath)

# ---------------------------------------------------------------------------
# lookup / substitute
# ---------------------------------------------------------------------------

proc cmdLookup(args: seq[string]): int =
  if args.len != 1:
    stderr.writeLine(Usage)
    return 2
  let hex = parseEntryKeyHex(args[0])
  let baseUrl = defaultCacheUrl()
  let url = baseUrl & "/manifests/" & hex
  let client = newCacheHttpClient(baseUrl, 15_000)
  defer: client.close()
  # Use GET (the A2 server only implements GET / POST routes; HEAD
  # returns 405 from Nim's asynchttpserver).
  try:
    let resp = client.get(url)
    case int(resp.code)
    of 200:
      echo "hit ", hex
      return 0
    of 404:
      echo "miss ", hex
      return 1
    else:
      stderr.writeLine("lookup failed: HTTP " & $resp.code)
      return 3
  except CatchableError as e:
    stderr.writeLine("lookup failed: " & e.msg)
    return 3

proc cmdSubstitute(args: seq[string]): int =
  if args.len != 2:
    stderr.writeLine(Usage)
    return 2
  let hex = parseEntryKeyHex(args[0])
  let outDir = args[1]

  let storeRoot = defaultStoreRoot()
  createDir(storeRoot)
  # Reprobuild-Binary-Cache-Fleet R1 — build the endpoint list from the
  # config file(s) (system + user, or REPRO_CACHES_CONFIG override),
  # folding in the REPRO_BINARY_CACHE_URL back-compat cache. Every
  # endpoint enforces the default-untrusted model: a manifest signed
  # by a producer key that is not in that cache's trusted-public-keys
  # is rejected (a MISS), and a cache with NO trusted keys is never
  # substituted from. The caches are tried in ascending priority order.
  let endpoints =
    try: loadEndpoints()
    except CacheConfigError as e:
      stderr.writeLine("substitute: cache config error: " & e.msg)
      return 2
  if endpoints.len == 0:
    stderr.writeLine("substitute: no caches configured (see " &
      "/etc/repro/caches.conf, ~/.config/repro/caches.conf, or " &
      "$REPRO_CACHES_CONFIG); miss")
    return 1
  let res = substituteInProcess(hex, storeRoot, endpoints)
  if not res.ok:
    stderr.writeLine("substitute failed: " & res.reason)
    return 1
  if res.outcomes.len == 0:
    stderr.writeLine("substitute returned no outcomes for " & hex)
    return 1
  let rootOutcome = res.outcomes[^1]
  if rootOutcome.casPath.len == 0 or not fileExists(rootOutcome.casPath):
    stderr.writeLine("substitute root CAS path missing: " & rootOutcome.casPath)
    return 1
  # The root's CAS blob is the packed prefix archive (per the publish
  # path). Extract it into outDir.
  let archiveBytes = readFile(rootOutcome.casPath)
  var asBytes = newSeq[byte](archiveBytes.len)
  for i, ch in archiveBytes:
    asBytes[i] = byte(ch)
  createDir(outDir)
  try:
    extractPrefix(asBytes, outDir)
  except IOError as e:
    # Not an archive: fall back to single-file extraction (the build
    # script's prefix was a single file like hex0).
    stderr.writeLine("substitute: archive parse failed (" & e.msg &
                     "); writing CAS blob verbatim to " & outDir)
    writeFile(outDir / "blob", archiveBytes)
  echo "hit ", hex, " -> ", outDir
  return 0

# ---------------------------------------------------------------------------
# publish
# ---------------------------------------------------------------------------

proc parseIdentityFlags(flagArgs: seq[string]): PublishArgs =
  # ``allowWhitespaceAfterColon = false`` keeps ``--platform-libc=`` from
  # consuming the next argv slot as its value (the build-script prelude
  # routinely passes empty values to opt out of a field).
  var p = initOptParser(flagArgs, allowWhitespaceAfterColon = false)
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "package-name": result.packageName = p.val
      of "package-version": result.packageVersion = p.val
      of "platform-cpu": result.platformCpu = p.val
      of "platform-os": result.platformOs = p.val
      of "platform-abi": result.platformAbi = p.val
      of "platform-libc": result.platformLibc = p.val
      of "toolchain-name": result.toolchainName = p.val
      of "toolchain-version": result.toolchainVersion = p.val
      of "toolchain-host-ldso": result.toolchainHostLdSo = p.val
      of "toolchain-extra": result.toolchainExtra = p.val
      of "provider-revision": result.providerRevision = p.val
      of "dep":
        if p.val.len > 0:
          result.depHex.add(parseEntryKeyHex(p.val))
      of "option":
        let eq = p.val.find('=')
        if eq <= 0:
          stderr.writeLine("--option requires name=value form")
          quit(2)
        result.options.add((p.val[0 ..< eq], p.val[eq + 1 .. ^1]))
      else: discard
    of cmdArgument: discard

proc parsePublishArgs(args: seq[string]): PublishArgs =
  if args.len < 2:
    stderr.writeLine(Usage)
    quit(2)
  result = parseIdentityFlags(args[2 .. ^1])
  result.entryKeyHex = parseEntryKeyHex(args[0])
  result.prefixDir = args[1]

proc identityFromArgs(a: PublishArgs): CacheEntryIdentity =
  result = newCacheEntryIdentity(
    packageName = a.packageName,
    packageVersion = a.packageVersion,
    platform = PlatformTriple(
      cpu: a.platformCpu, os: a.platformOs,
      abi: a.platformAbi, libcVariant: a.platformLibc),
    toolchain = ToolchainIdentity(
      name: a.toolchainName, version: a.toolchainVersion,
      hostLdSoAbi: a.toolchainHostLdSo,
      extraFingerprint: a.toolchainExtra),
    providerRevision = a.providerRevision)
  for (k, v) in a.options:
    result.addOption(k, v)
  for depHex in a.depHex:
    result.addDep(depHex)

proc cmdDeriveKey(args: seq[string]): int =
  let parsed = parseIdentityFlags(args)
  let idy = identityFromArgs(parsed)
  echo deriveCacheEntryKeyHex(idy)
  return 0

proc cmdGenKey(args: seq[string]): int =
  ## Generates an ECDSA-P256 keypair and writes the matching key + cert
  ## files at the env-configured paths if missing. Returns 0 on success,
  ## or 0 too if the files already exist (idempotent). Useful for
  ## bootstrap from CI / shell scripts.
  let keyPath = getEnv("REPRO_BINARY_CACHE_KEY_PATH", "")
  let certPath = getEnv("REPRO_BINARY_CACHE_CERT_PATH", "")
  if keyPath.len == 0 or certPath.len == 0:
    stderr.writeLine("gen-key: REPRO_BINARY_CACHE_KEY_PATH + " &
                     "REPRO_BINARY_CACHE_CERT_PATH must be set")
    return 2
  let kp = peerAuth.loadOrGenerateKeypair(certPath, keyPath)
  const HexChars = "0123456789abcdef"
  var pubHex = newStringOfCap(130)
  for b in kp.publicKey:
    pubHex.add(HexChars[(int(b) shr 4) and 0xf])
    pubHex.add(HexChars[int(b) and 0xf])
  echo pubHex
  return 0

proc cmdPublish(rawArgs: seq[string]): int =
  ## M9.L.4-refactor Step A: thin wrapper that translates CLI flags +
  ## env vars into a ``PublishInProcessRequest`` and forwards to the
  ## library implementation. The pre-existing drift-guard +
  ## packaging + sign + POST live in ``publishInProcess``
  ## (libs/repro_binary_cache_client/src/repro_binary_cache_client/
  ## in_process.nim). Keeping CLI behaviour byte-identical:
  ##
  ##   * exit 2 — identity hex mismatch + missing prefix dir + missing
  ##     key/cert env vars (these are all caller-input errors, the
  ##     pre-refactor CLI also exited 2 on them).
  ##   * exit 1 — HTTP failure / network error.
  ##   * exit 0 — server accepted the publish.
  ##   * stdout — ``published <entryKeyHex>`` on success.
  ##   * stderr — diagnostic text on failure (unchanged).
  let args = parsePublishArgs(rawArgs)
  let idy = identityFromArgs(args)
  let kp =
    try: loadProducerKeypair()
    except ValueError as e:
      stderr.writeLine(e.msg)
      return 2
  let req = PublishInProcessRequest(
    entryKeyHex: args.entryKeyHex,
    prefixDir: args.prefixDir,
    identity: idy,
    endpoint: defaultCacheUrl(),
    keypair: kp)
  let res = publishInProcess(req)
  if not res.ok:
    stderr.writeLine(res.error)
    # Drift-guard + missing-prefix errors are caller-input failures
    # (exit 2); everything else is a runtime / network failure (exit 1).
    # The pre-refactor CLI used the same partitioning.
    if res.statusCode == 0 and
       (res.error.contains("identity-derived key does not match") or
        res.error.contains("prefix path does not exist")):
      return 2
    return 1
  echo "published ", res.responseBody.strip()
  return 0

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

proc runCacheSubcommand*(args: seq[string]): int =
  ## Routes ``repro cache <subcommand> …`` (``args`` is everything AFTER
  ## the ``cache`` verb) to the shared handlers. Adds no behaviour beyond
  ## argv parsing + exit codes — the substitution / publish semantics
  ## (including R1 trust) come from the shared library. This is the SAME
  ## dispatch the historical standalone ``repro-binary-cache-client``
  ## exposed under its own ``main``.
  if args.len == 0:
    echo Usage
    return 0
  case args[0]
  of "lookup":
    return cmdLookup(args[1 .. ^1])
  of "substitute":
    return cmdSubstitute(args[1 .. ^1])
  of "publish":
    return cmdPublish(args[1 .. ^1])
  of "derive-key":
    return cmdDeriveKey(args[1 .. ^1])
  of "gen-key":
    return cmdGenKey(args[1 .. ^1])
  of "-h", "--help", "help":
    echo Usage
    return 0
  else:
    echo Usage
    return 2

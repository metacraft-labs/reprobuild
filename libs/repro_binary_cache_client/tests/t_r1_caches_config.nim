## Reprobuild-Binary-Cache-Fleet R1 — caches config parser + precedence.
##
## Pure unit tests (no server) for ``caches_config``:
##
##   * INI parse: sections, url / trusted-public-keys / priority.
##   * Multiple + comma/space-separated trusted keys.
##   * ``toEndpoint`` sets ``enforceTrust`` (default-untrusted).
##   * ``loadEndpoints`` precedence: REPRO_CACHES_CONFIG override,
##     system+user merge (user overrides by name), priority sort,
##     REPRO_BINARY_CACHE_URL back-compat fold-in (no trust).
##   * Malformed key / priority raises CacheConfigError.

import std/[os, strutils, unittest]

import ../src/repro_binary_cache_client/caches_config

# A valid 65-byte (130-hex) uncompressed ECDSA-P256 pubkey shape:
# 0x04 || 64 bytes. The bytes need not be a real point for parse tests.
const
  KeyA = "04" & repeat("ab", 64)
  KeyB = "04" & repeat("cd", 64)
  KeyC = "04" & repeat("ef", 64)

proc withEnv(name, val: string; body: proc()) =
  let had = existsEnv(name)
  let prev = getEnv(name)
  putEnv(name, val)
  defer:
    if had: putEnv(name, prev) else: delEnv(name)
  body()

suite "R1 — caches config parser":

  test "parses a two-cache file with keys + priority":
    let text = """
[fleet]
url = "https://repro-cache:7878"
trusted-public-keys = "$1, $2"
priority = 20

[local]
url = "http://localhost:7878"
trusted-public-keys = "$3"
priority = 10
""" % [KeyA, KeyB, KeyC]
    let entries = parseCachesText(text, "test")
    check entries.len == 2
    check entries[0].name == "fleet"
    check entries[0].url == "https://repro-cache:7878"
    check entries[0].trustedKeys.len == 2
    check entries[0].priority == 20
    check entries[1].name == "local"
    check entries[1].trustedKeys.len == 1
    check entries[1].priority == 10

  test "trusted-public-keys accepts whitespace-only separators":
    let text = "[c]\nurl = \"u\"\ntrusted-public-keys = \"$1 $2\"\n" %
      [KeyA, KeyB]
    let entries = parseCachesText(text, "test")
    check entries.len == 1
    check entries[0].trustedKeys.len == 2

  test "bare [name] section header works (cache prefix optional)":
    let text = "[fleet]\nurl = \"u\"\ntrusted-public-keys = \"$1\"\n" % [KeyA]
    let entries = parseCachesText(text, "test")
    check entries.len == 1
    check entries[0].name == "fleet"

  test "missing priority defaults; cache with no keys parses (0 trusted)":
    let text = "[c]\nurl = \"u\"\n"
    let entries = parseCachesText(text, "test")
    check entries.len == 1
    check entries[0].priority == DefaultCachePriority
    check entries[0].trustedKeys.len == 0

  test "toEndpoint enables enforceTrust (default-untrusted)":
    let e = CacheEntry(name: "c", url: "u", trustedKeys: @[], priority: 5)
    let ep = toEndpoint(e)
    check ep.enforceTrust
    check ep.trustedSigners.len == 0
    check ep.baseUrl == "u"

  test "malformed pubkey hex raises":
    expect CacheConfigError:
      discard parseCachesText(
        "[c]\nurl=\"u\"\ntrusted-public-keys=\"deadbeef\"\n", "t")

  test "non-integer priority raises":
    expect CacheConfigError:
      discard parseCachesText(
        "[c]\nurl=\"u\"\npriority=\"soon\"\n", "t")

suite "R1 — caches config precedence + env fold-in":

  test "REPRO_CACHES_CONFIG override + priority sort + enforceTrust":
    let tmp = getTempDir() / "r1cfg_override"
    createDir(tmp)
    let cfgPath = tmp / "caches.conf"
    writeFile(cfgPath, """
[hi]
url = "http://hi"
trusted-public-keys = "$1"
priority = 5

[lo]
url = "http://lo"
trusted-public-keys = "$2"
priority = 50
""" % [KeyA, KeyB])
    withEnv(ConfigPathEnvVar, cfgPath, proc() =
      withEnv(EnvUrlVar, "", proc() =
        delEnv(EnvUrlVar)
        let eps = loadEndpoints()
        check eps.len == 2
        # Sorted ascending: priority 5 first.
        check eps[0].baseUrl == "http://hi"
        check eps[0].priority == 5
        check eps[0].enforceTrust
        check eps[1].baseUrl == "http://lo"))
    removeDir(tmp)

  test "REPRO_BINARY_CACHE_URL folds in as lowest-priority, no-trust cache":
    let tmp = getTempDir() / "r1cfg_env"
    createDir(tmp)
    let cfgPath = tmp / "caches.conf"
    writeFile(cfgPath, """
[fleet]
url = "http://fleet"
trusted-public-keys = "$1"
priority = 10
""" % [KeyA])
    withEnv(ConfigPathEnvVar, cfgPath, proc() =
      # The test suite itself may publish through a temporary producer cert.
      # This case specifically proves the no-cert fallback, so isolate that
      # input instead of inheriting suite-level cache credentials.
      withEnv(EnvCertVar, "", proc() =
        withEnv(EnvUrlVar, "http://env-only", proc() =
          let eps = loadEndpoints()
          check eps.len == 2
          # fleet (priority 10) before env (EnvCachePriority, lowest).
          check eps[0].baseUrl == "http://fleet"
          check eps[1].baseUrl == "http://env-only"
          # The env cache carries NO trust => default-untrusted => a MISS.
          check eps[1].trustedSigners.len == 0
          check eps[1].enforceTrust)))
    removeDir(tmp)

  test "env URL already covered by a config cache is NOT duplicated":
    let tmp = getTempDir() / "r1cfg_dup"
    createDir(tmp)
    let cfgPath = tmp / "caches.conf"
    writeFile(cfgPath, """
[fleet]
url = "http://same"
trusted-public-keys = "$1"
priority = 10
""" % [KeyA])
    withEnv(ConfigPathEnvVar, cfgPath, proc() =
      withEnv(EnvUrlVar, "http://same", proc() =
        let eps = loadEndpoints()
        check eps.len == 1
        check eps[0].baseUrl == "http://same"
        check eps[0].trustedSigners.len == 1))
    removeDir(tmp)

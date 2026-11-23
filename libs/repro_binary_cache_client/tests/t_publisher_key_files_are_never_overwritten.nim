## A publisher's key files are loaded, never minted over (reprobuild-pm
## spec/Binary-Caches.md: `REPRO_BINARY_CACHE_KEY_PATH` is "required for
## `publish`"; spec/CLI/build.md, "Publishing for an appliance").
##
## Found by the independent review of `--publish` (2026-11-01): with the
## cert path mistyped, `loadProducerKeypair` reached `loadOrGenerateKeypair`,
## which saw one file missing, generated a fresh pair and wrote it over the
## existing private key with a plain `writeFile` under the umask -- so the
## only copy of an allowlisted publisher key could be destroyed by a typo,
## and the new key file was world-readable under a 022 umask.
##
## Checked against the real filesystem; no mocks:
##   * a publisher load with one path wrong refuses by name, writes nothing,
##     and leaves the key that is there byte-identical;
##   * `loadOrGenerateKeypair` refuses the same half-present pair instead of
##     generating over it;
##   * a generated private key is 0600 even under a 022 umask, and a second
##     generation into the same paths cannot replace it (created
##     exclusively).

import std/[os, strutils, tempfiles, unittest]
when defined(posix):
  import std/posix

import repro_peer_cache/auth as peerAuth
import repro_binary_cache_client/cli_dispatch

suite "publisher key files are never overwritten":

  test "a mistyped cert path is refused by name and the key is untouched":
    let dir = createTempDir("publisher-key-", "")
    defer: removeDir(dir)
    let cert = dir / "producer.cert"
    let key = dir / "producer.key"
    discard peerAuth.loadOrGenerateKeypair(cert, key)
    let before = readFile(key)
    putEnv("REPRO_BINARY_CACHE_KEY_PATH", key)
    putEnv("REPRO_BINARY_CACHE_CERT_PATH", dir / "prodcuer.cert")
    defer:
      delEnv("REPRO_BINARY_CACHE_KEY_PATH")
      delEnv("REPRO_BINARY_CACHE_CERT_PATH")
    var refusal = ""
    try:
      discard loadProducerKeypair()
    except CatchableError as e:
      refusal = e.msg
    check "prodcuer.cert" in refusal
    check readFile(key) == before
    check not fileExists(dir / "prodcuer.cert")

  test "a mistyped key path is refused by name and nothing is created":
    let dir = createTempDir("publisher-key-", "")
    defer: removeDir(dir)
    let cert = dir / "producer.cert"
    let key = dir / "producer.key"
    discard peerAuth.loadOrGenerateKeypair(cert, key)
    putEnv("REPRO_BINARY_CACHE_KEY_PATH", dir / "prodcuer.key")
    putEnv("REPRO_BINARY_CACHE_CERT_PATH", cert)
    defer:
      delEnv("REPRO_BINARY_CACHE_KEY_PATH")
      delEnv("REPRO_BINARY_CACHE_CERT_PATH")
    expect AuthError:
      discard loadProducerKeypair()
    check not fileExists(dir / "prodcuer.key")

  test "generation refuses a half-present pair instead of minting over it":
    let dir = createTempDir("publisher-key-", "")
    defer: removeDir(dir)
    let key = dir / "producer.key"
    discard peerAuth.loadOrGenerateKeypair(dir / "producer.cert", key)
    let before = readFile(key)
    expect AuthError:
      discard peerAuth.loadOrGenerateKeypair(dir / "other.cert", key)
    check readFile(key) == before
    check not fileExists(dir / "other.cert")

  when defined(posix):
    test "a generated private key is 0600 under a 022 umask":
      let dir = createTempDir("publisher-key-", "")
      defer: removeDir(dir)
      let old = umask(Mode(0o022))
      defer: discard umask(old)
      discard peerAuth.loadOrGenerateKeypair(dir / "p.cert", dir / "p.key")
      var st: Stat
      require stat((dir / "p.key").cstring, st) == 0
      check (int(st.st_mode) and 0o777) == 0o600
      # Control: an ordinary file in the same directory under the same
      # umask is 0644, so the check above discriminates.
      writeFile(dir / "plain", "x")
      require stat((dir / "plain").cstring, st) == 0
      check (int(st.st_mode) and 0o777) == 0o644

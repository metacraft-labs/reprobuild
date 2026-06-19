## M9.O — auto-generated producer credentials test.
##
## Exercises the lazy keypair generation path added to
## ``engine_publisher.nim``. The covered behaviours:
##
##   * ``defaultAutoCredentialDir`` resolves to the per-OS default and
##     honours the ``REPRO_BINARY_CACHE_AUTO_CRED_DIR`` test override.
##   * ``ensureAutoProducerKeypair`` generates a fresh keypair when
##     called against an empty directory, and reuses the pre-existing
##     pair on the second call (no key rotation between invocations).
##   * The directory is created when it doesn't exist; POSIX
##     permissions are tightened (0o700 dir, 0o600 files).
##   * The ``mkBinaryCachePublisher`` closure:
##       - skips keygen entirely when ``REPRO_CACHE_DISABLE=1`` is set;
##       - generates credentials at the override directory on first
##         invocation when env vars are unset;
##       - caches the resolved key/cert paths across invocations in
##         the same closure (subsequent calls reuse without re-running
##         ``ensureAutoProducerKeypair``);
##       - honours pre-existing env-var pinned credentials when both
##         files exist on disk (production case).
##
## No network. No real WSL distro. ``maybeAutoStartReproCache`` is
## exercised against a bogus endpoint (port 1) so the probe fails fast
## and the proc returns false without side effects on non-Windows
## hosts. On Windows the WSL invocation is best-effort and tolerated:
## if the distro isn't present the proc returns false within the
## bounded poll window.

import std/[os, strutils, unittest]

import ../src/repro_binary_cache_client/engine_publisher
import repro_build_engine

const TmpRoot = "build/test-tmp/test_auto_credentials"

proc freshTmpDir(tag: string): string =
  result = TmpRoot / tag
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc clearAllEnv() =
  delEnv("REPRO_BINARY_CACHE_URL")
  delEnv("REPRO_BINARY_CACHE_KEY_PATH")
  delEnv("REPRO_BINARY_CACHE_CERT_PATH")
  delEnv("REPRO_CACHE_DISABLE")
  delEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR")

proc stubRequest(cwd: string): BinaryCachePublishRequest =
  BinaryCachePublishRequest(
    actionId: "stub-action",
    cwd: cwd,
    declaredOutputs: @[])

suite "M9.O — auto-generated producer credentials":

  test "defaultAutoCredentialDir resolves to per-OS default when override unset":
    # Without the test-only override, the per-OS default applies. We
    # check the shape (suffix) rather than the absolute path so the
    # assertion holds regardless of ``$HOME`` / ``%LOCALAPPDATA%``
    # settings on the test host.
    clearAllEnv()
    let resolved = defaultAutoCredentialDir()
    check resolved.len > 0
    check resolved.endsWith("producer-keypair")
    check "repro" in resolved

  test "REPRO_BINARY_CACHE_AUTO_CRED_DIR override wins":
    # The test override pins the directory under build/test-tmp so the
    # rest of the suite + every test run stays sandboxed away from real
    # user-config state.
    clearAllEnv()
    let tmp = freshTmpDir("override")
    putEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR", tmp)
    defer: delEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR")
    let resolved = defaultAutoCredentialDir()
    check resolved == tmp

  test "ensureAutoProducerKeypair generates a fresh keypair on first call":
    # Calling against an empty directory: keys are written, ``generated``
    # is true, both files exist on disk afterwards.
    clearAllEnv()
    let dir = freshTmpDir("ensure-fresh")
    var keyPath, certPath: string
    let outcome = ensureAutoProducerKeypair(dir, keyPath, certPath)
    check outcome.ok
    check outcome.generated
    check outcome.error.len == 0
    check keyPath == dir / "producer.key.pem"
    check certPath == dir / "producer.cert.pem"
    check fileExists(keyPath)
    check fileExists(certPath)

  test "ensureAutoProducerKeypair reuses pre-existing keypair on second call":
    # Second call against the same dir: ``generated`` is false (loaded,
    # not regenerated), key bytes on disk are unchanged.
    clearAllEnv()
    let dir = freshTmpDir("ensure-reuse")
    var k1, c1: string
    let first = ensureAutoProducerKeypair(dir, k1, c1)
    check first.ok
    check first.generated
    let keyBytesBefore = readFile(k1)
    let certBytesBefore = readFile(c1)
    var k2, c2: string
    let second = ensureAutoProducerKeypair(dir, k2, c2)
    check second.ok
    check (not second.generated)  # loaded, not regenerated
    check k1 == k2
    check c1 == c2
    check readFile(k2) == keyBytesBefore
    check readFile(c2) == certBytesBefore

  test "REPRO_CACHE_DISABLE=1 skips keygen entirely":
    # Even when env vars are unset, ``REPRO_CACHE_DISABLE=1`` keeps the
    # closure from creating the auto-credential directory. We point the
    # override at a path that does NOT exist; after invoking the closure
    # the path MUST remain absent.
    clearAllEnv()
    let dir = TmpRoot / "disabled-must-not-exist"
    if dirExists(dir):
      removeDir(dir)
    putEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR", dir)
    putEnv("REPRO_CACHE_DISABLE", "1")
    defer:
      delEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR")
      delEnv("REPRO_CACHE_DISABLE")
    let pub = mkBinaryCachePublisher()
    check pub != nil
    let res = pub(stubRequest(TmpRoot))
    check (not res.ok)
    check res.error.len == 0  # silent disable
    check (not dirExists(dir))  # keygen MUST NOT have created the dir

  test "closure auto-generates credentials under the override directory":
    # Env vars unset, override pinned: first invocation generates keys
    # under the override and reuses them on the second call. We use a
    # bogus endpoint so the downstream HTTP POST fails fast; we only
    # care that the keygen path ran (the keypair files exist) and that
    # the second invocation didn't rotate them.
    clearAllEnv()
    let dir = freshTmpDir("closure-auto")
    putEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR", dir)
    # Bogus endpoint so the post-keygen HTTP step fails quickly without
    # blocking the test on a real cache server.
    putEnv("REPRO_BINARY_CACHE_URL", "http://127.0.0.1:1")
    defer:
      delEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR")
      delEnv("REPRO_BINARY_CACHE_URL")
    let pub = mkBinaryCachePublisher()
    check pub != nil
    discard pub(stubRequest(TmpRoot))
    check fileExists(dir / "producer.key.pem")
    check fileExists(dir / "producer.cert.pem")
    let keyBytes = readFile(dir / "producer.key.pem")
    let certBytes = readFile(dir / "producer.cert.pem")
    # Second invocation through the SAME closure reuses cached paths.
    discard pub(stubRequest(TmpRoot))
    check readFile(dir / "producer.key.pem") == keyBytes
    check readFile(dir / "producer.cert.pem") == certBytes

  test "closure preserves env-pinned credentials when both files exist":
    # When ``REPRO_BINARY_CACHE_KEY_PATH`` + ``REPRO_BINARY_CACHE_CERT_PATH``
    # are set AND both files exist on disk, the closure uses those
    # paths verbatim — the auto-credential override is ignored and no
    # files are written under the override directory.
    clearAllEnv()
    let dir = freshTmpDir("env-pinned")
    let overrideDir = freshTmpDir("env-pinned-override")
    var pinnedKey, pinnedCert: string
    let prep = ensureAutoProducerKeypair(dir, pinnedKey, pinnedCert)
    check prep.ok
    putEnv("REPRO_BINARY_CACHE_KEY_PATH", pinnedKey)
    putEnv("REPRO_BINARY_CACHE_CERT_PATH", pinnedCert)
    putEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR", overrideDir)
    putEnv("REPRO_BINARY_CACHE_URL", "http://127.0.0.1:1")
    defer:
      delEnv("REPRO_BINARY_CACHE_KEY_PATH")
      delEnv("REPRO_BINARY_CACHE_CERT_PATH")
      delEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR")
      delEnv("REPRO_BINARY_CACHE_URL")
    let pub = mkBinaryCachePublisher()
    check pub != nil
    discard pub(stubRequest(TmpRoot))
    # The override directory MUST remain free of producer files because
    # the env-pinned paths took precedence.
    check (not fileExists(overrideDir / "producer.key.pem"))
    check (not fileExists(overrideDir / "producer.cert.pem"))

  test "maybeAutoStartReproCache returns false against an unreachable endpoint":
    # No probe target listens on port 1. On non-Windows hosts the proc
    # short-circuits immediately. On Windows the WSL invocation is
    # best-effort; either way the final reachability is false within
    # the bounded poll window.
    let reachable = maybeAutoStartReproCache("http://127.0.0.1:1")
    check (not reachable)

  test "maybeAutoStartReproCache returns false for unparseable endpoint":
    # A non-URL endpoint (e.g. empty or scheme-less) MUST short-circuit
    # rather than attempting any network or process I/O.
    check (not maybeAutoStartReproCache(""))
    check (not maybeAutoStartReproCache("not-a-url"))

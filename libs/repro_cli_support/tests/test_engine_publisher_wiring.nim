## M9.L.4-refactor Step C — production publisher-wiring smoke test.
##
## Step C wires ``mkBinaryCachePublisher()`` into the
## ``BuildEngineConfig`` assembled inside
## ``libs/repro_cli_support/src/repro_cli_support.nim``'s
## ``executeBuildTarget`` (the ``repro build`` driver path). Two
## production assembly sites are touched:
##
##   1. The ``runLoweredGraphBuild`` helper's ``engineConfig`` (around
##      line ~4564). Used by the multi-target / lowered-graph fast
##      path.
##   2. The main inline ``engineConfig`` (around line ~5288). Used by
##      every other ``repro build`` invocation.
##
## Both call ``mkBinaryCachePublisher()`` and assign the closure to
## ``engineConfig.binaryCachePublisher`` immediately after the config
## value is constructed. The engine only fires the closure for actions
## that carry ``publishToBinaryCache = true`` AND a populated
## ``cacheEntryIdentity`` — the four from-source conventions tag
## install + stage-copy actions accordingly.
##
## ## Scope
##
## ``executeBuildTarget`` is a private proc that needs a fully realised
## build target (project DSL workspace + provider compile + lowered
## graph) before its ``BuildEngineConfig`` is reachable. Building one
## here just to read the field off a config value would dwarf the
## actual wiring under test. Instead this smoke test:
##
##   * Exercises the ``mkBinaryCachePublisher`` factory the production
##     wiring calls (closure returns non-nil + behaves per the env-var
##     contract). The factory's behaviour is also validated upstream
##     by ``libs/repro_binary_cache_client/tests/test_publish_in_process``
##     and ``libs/repro_build_engine/tests/test_binary_cache_publisher_hook``.
##
##   * Sanity-checks that ``defaultBuildEngineConfig`` (the factory the
##     test fixtures + workspace-vcs / manifest-refresh use) leaves
##     ``binaryCachePublisher`` ``nil`` so deterministic test fixtures
##     are unaffected by the production wiring.
##
## Test fixtures that assemble their own ``BuildEngineConfig`` via
## ``defaultBuildEngineConfig`` stay deterministic; they NEVER call
## ``mkBinaryCachePublisher()`` so they cannot accidentally reach a
## real cache server.

import std/[options, os, strutils, unittest]

import repro_build_engine
import repro_binary_cache_client/engine_publisher

const TmpCacheRoot = "build/test-tmp/test_engine_publisher_wiring"

proc resetTmp() =
  if dirExists(TmpCacheRoot):
    removeDir(TmpCacheRoot)
  createDir(TmpCacheRoot)

proc clearEnv() =
  ## The factory snapshots env vars on first call and caches them for
  ## the closure's lifetime. Each test constructs a FRESH closure so
  ## the cache is bounded to that closure — clearing the env here
  ## guarantees the test sees the configuration we intend.
  delEnv("REPRO_BINARY_CACHE_URL")
  delEnv("REPRO_BINARY_CACHE_KEY_PATH")
  delEnv("REPRO_BINARY_CACHE_CERT_PATH")
  delEnv("REPRO_CACHE_DISABLE")

proc stubRequest(): BinaryCachePublishRequest =
  ## Minimal request shape — the gating tests below all short-circuit
  ## before the closure consults ``identity`` / ``declaredOutputs`` /
  ## ``cwd``, so the field values do not matter; only the closure's
  ## env-driven branch decisions matter.
  BinaryCachePublishRequest(
    actionId: "stub-action",
    cwd: TmpCacheRoot,
    declaredOutputs: @[])

suite "M9.L.4-refactor Step C — production publisher wiring":

  test "mkBinaryCachePublisher returns a non-nil closure":
    # The production driver code in ``repro_cli_support.nim`` assigns
    # this closure to ``engineConfig.binaryCachePublisher``. The
    # engine's hook only fires when this field is non-nil; verifying
    # the factory's return value is non-nil is the load-bearing
    # invariant Step C depends on.
    resetTmp()
    clearEnv()
    let pub = mkBinaryCachePublisher()
    check pub != nil

  test "closure honours REPRO_CACHE_DISABLE=1 silently (ok=false, empty error)":
    # When ``REPRO_CACHE_DISABLE=1`` is set, the closure must NOT
    # attempt any HTTP I/O and must NOT log a warning. The engine
    # treats this as a no-op cache miss equivalent — same gate the
    # in-process substitution path uses.
    resetTmp()
    clearEnv()
    putEnv("REPRO_CACHE_DISABLE", "1")
    defer: delEnv("REPRO_CACHE_DISABLE")
    let pub = mkBinaryCachePublisher()
    check pub != nil
    let res = pub(stubRequest())
    check res.ok == false
    check res.error.len == 0
    check res.bytesUploaded == 0

  test "closure soft-fails with structured error when key/cert env vars are unset":
    # When no key/cert env vars are configured, the closure returns
    # ``ok = false`` with a warning naming both env vars. The engine
    # logs the warning into stats but does NOT abort the build (soft
    # fail by design). This is what every developer machine without
    # the binary-cache credentials hits — the build still succeeds
    # locally.
    resetTmp()
    clearEnv()
    let pub = mkBinaryCachePublisher()
    check pub != nil
    let res = pub(stubRequest())
    check res.ok == false
    check res.error.len > 0
    check "REPRO_BINARY_CACHE_KEY_PATH" in res.error
    check "REPRO_BINARY_CACHE_CERT_PATH" in res.error
    check res.bytesUploaded == 0

  test "defaultBuildEngineConfig leaves binaryCachePublisher nil " &
       "(test fixtures are unaffected)":
    # The test fixtures + workspace-vcs / manifest-refresh callers
    # build their engine configs via ``defaultBuildEngineConfig``; the
    # production wiring lives elsewhere (inside
    # ``executeBuildTarget``). This check guards against an accidental
    # leak of the publisher into test fixtures, which would cause
    # cross-test interference + real HTTP I/O attempts on machines
    # that happen to have the env vars set.
    resetTmp()
    clearEnv()
    let cfg = defaultBuildEngineConfig(TmpCacheRoot)
    check cfg.binaryCachePublisher == nil

  test "readPublisherEnv snapshot reflects env state at call time":
    # The closure's env-var snapshot is consulted on first invocation
    # and cached. ``readPublisherEnv`` is the public surface the
    # factory uses internally; exercising it here pins the env-var
    # name contract (any rename of ``REPRO_BINARY_CACHE_*`` would
    # break this check + the four convention regressions
    # simultaneously).
    resetTmp()
    clearEnv()
    putEnv("REPRO_BINARY_CACHE_URL", "http://example.invalid:1234")
    putEnv("REPRO_BINARY_CACHE_KEY_PATH", "/no/such/key")
    putEnv("REPRO_BINARY_CACHE_CERT_PATH", "/no/such/cert")
    defer:
      delEnv("REPRO_BINARY_CACHE_URL")
      delEnv("REPRO_BINARY_CACHE_KEY_PATH")
      delEnv("REPRO_BINARY_CACHE_CERT_PATH")
    let snap = readPublisherEnv()
    check snap.endpoint == "http://example.invalid:1234"
    check snap.keyPath == "/no/such/key"
    check snap.certPath == "/no/such/cert"
    check snap.disabled == false

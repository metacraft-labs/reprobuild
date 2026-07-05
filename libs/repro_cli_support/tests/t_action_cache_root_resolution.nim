import std/[os, unittest]

import repro_cli_support

suite "action cache root resolution":
  test "explicit flag beats env and store roots":
    putEnv("REPROBUILD_ACTION_CACHE_ROOT", "/tmp/repro-env-cache")
    putEnv("REPROBUILD_STORE_ROOT", "/tmp/repro-store")
    putEnv("REPRO_STORE_ROOT", "/tmp/repro-compat-store")
    check resolveActionCacheRoot("/tmp/repro-explicit-cache") ==
      "/tmp/repro-explicit-cache"
    delEnv("REPROBUILD_ACTION_CACHE_ROOT")
    delEnv("REPROBUILD_STORE_ROOT")
    delEnv("REPRO_STORE_ROOT")

  test "direct env override beats store roots":
    putEnv("REPROBUILD_ACTION_CACHE_ROOT", "/tmp/repro-env-cache")
    putEnv("REPROBUILD_STORE_ROOT", "/tmp/repro-store")
    putEnv("REPRO_STORE_ROOT", "/tmp/repro-compat-store")
    check resolveActionCacheRoot() == "/tmp/repro-env-cache"
    delEnv("REPROBUILD_ACTION_CACHE_ROOT")
    delEnv("REPROBUILD_STORE_ROOT")
    delEnv("REPRO_STORE_ROOT")

  test "store root fallback keeps legacy action-cache suffix":
    delEnv("REPROBUILD_ACTION_CACHE_ROOT")
    putEnv("REPROBUILD_STORE_ROOT", "/tmp/repro-store")
    putEnv("REPRO_STORE_ROOT", "/tmp/repro-compat-store")
    check resolveActionCacheRoot() == "/tmp/repro-store" / "action-cache"
    delEnv("REPROBUILD_STORE_ROOT")
    delEnv("REPRO_STORE_ROOT")

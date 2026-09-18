## The activation cache key must move when the STORE ROOT moves.
##
## ``repro dev-env export`` short-circuits when its cache key matches the
## marker the last activation set, and the key is what decides whether the
## PATH a shell already has is still the right one. So every input that
## changes that PATH has to be in the key.
##
## ``REPRO_STORE_ROOT`` was not, and the consequence was silent rather than
## wrong-looking. Pointing it at an empty directory — the obvious way to
## rehearse a clean install without a clean machine — appeared to do
## nothing: ``resolveStoreRoot`` honoured the variable, but the activation
## never re-ran, so the previous run's entries were replayed and every tool
## still resolved out of the default store. Nothing reported a conflict,
## because from the key's point of view nothing had changed.
##
## The neighbouring variable was already keyed, which is what makes the
## omission a slip rather than a decision: ``REPRO_TOOL_PROVISIONING``
## selects WHICH provisioning mode realizes a tool, and
## ``REPRO_STORE_ROOT`` selects WHERE the result lives. Both end up in the
## PATH the activation emits.

import std/[os, unittest]

import repro_dev_env_engine/cache_key

suite "the dev-env cache key covers the store root":

  setup:
    delEnv("REPRO_STORE_ROOT")
    delEnv("REPRO_TOOL_PROVISIONING")

  teardown:
    delEnv("REPRO_STORE_ROOT")
    delEnv("REPRO_TOOL_PROVISIONING")

  test "two store roots do not share an activation":
    let root = getCurrentDir()
    putEnv("REPRO_STORE_ROOT", "/tmp/store-a")
    let a = computeDevEnvEdgeCacheKey(root, "default", "", "")
    putEnv("REPRO_STORE_ROOT", "/tmp/store-b")
    let b = computeDevEnvEdgeCacheKey(root, "default", "", "")
    check a != b

  test "setting it at all differs from leaving it unset":
    # The case that actually bit: going from "no override" to an override
    # is the first thing anyone does, and it has to invalidate.
    let root = getCurrentDir()
    let unset = computeDevEnvEdgeCacheKey(root, "default", "", "")
    putEnv("REPRO_STORE_ROOT", "/tmp/store-a")
    let overridden = computeDevEnvEdgeCacheKey(root, "default", "", "")
    check unset != overridden

  test "the same store root still short-circuits":
    # The key must not become unstable: an activation that recomputes on
    # every prompt would trade a correctness bug for a latency one, and the
    # fast path exists precisely to avoid touching the build engine.
    let root = getCurrentDir()
    putEnv("REPRO_STORE_ROOT", "/tmp/store-a")
    let first = computeDevEnvEdgeCacheKey(root, "default", "", "")
    let second = computeDevEnvEdgeCacheKey(root, "default", "", "")
    check first == second

  test "the neighbouring provisioning variable is still keyed":
    # Guards the fix against a regression that would look like a cleanup:
    # both variables belong in the key for the same reason.
    let root = getCurrentDir()
    putEnv("REPRO_TOOL_PROVISIONING", "tarball")
    let tarball = computeDevEnvEdgeCacheKey(root, "default", "", "")
    putEnv("REPRO_TOOL_PROVISIONING", "nix")
    let nix = computeDevEnvEdgeCacheKey(root, "default", "", "")
    check tarball != nix

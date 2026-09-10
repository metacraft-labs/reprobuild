import std/[os, tempfiles, unittest]

import repro_binary_cache_client/cache_key
import repro_project_dsl/source_cache_identity

suite "source package cache identity completeness":
  test "entry recipe bytes cannot authorize a package substitute":
    let root = createTempDir("source-cache-identity-", "")
    defer: removeDir(root)
    writeFile(root / "repro.nim", "import recipe\n")
    writeFile(root / "recipe.nim", "const implementation = 1\n")
    let before = sourceCacheEntryIdentity(root, "probe", "1", "cmake")
    expect CacheKeyError:
      discard deriveCacheEntryKeyHex(before)

    writeFile(root / "recipe.nim", "const implementation = 2\n")
    let after = sourceCacheEntryIdentity(root, "probe", "1", "cmake")
    # Until the complete identity is bound, neither imported implementation
    # may look up or publish the entry-only key shared by both recipes.
    expect CacheKeyError:
      discard deriveCacheEntryKeyHex(after)

  test "a missing recipe cannot authorize a package substitute":
    let root = createTempDir("source-cache-missing-", "")
    defer: removeDir(root)
    expect CacheKeyError:
      discard deriveCacheEntryKeyHex(
        sourceCacheEntryIdentity(root, "missing", "1", "cmake"))

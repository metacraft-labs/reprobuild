## Canonical binary-cache identity composition for source-built packages.
##
## This module deliberately accepts the selected package version as an
## argument. Provider/runtime layers own version selection; keeping that
## registry dependency out of this module lets both the standard provider
## and the Layer-1 package constructors share the exact same key logic.

import std/[os, strutils]

import blake3
import repro_binary_cache_client/cache_key
import repro_core

proc cacheIdentityExtendedPath(path: string): string =
  when defined(windows):
    if path.len == 0 or path.startsWith("\\\\"):
      path
    else:
      "\\\\?\\" & normalizedPath(absolutePath(path)).replace('/', '\\')
  else:
    path

proc sourceProviderRevisionHex*(projectRoot: string): string =
  ## BLAKE3 of the active recipe bytes, truncated to 32 lowercase hex chars.
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  let body =
    try: readFile(cacheIdentityExtendedPath(match.path))
    except CatchableError: ""
  if body.len == 0:
    return ""
  let full = blake3.toHex(blake3.digest(body))
  if full.len >= 32: full[0 ..< 32] else: full

proc sourceCacheEntryIdentity*(projectRoot, packageName, packageVersion,
                               conventionTag: string): CacheEntryIdentity =
  ## Compose the public-interface identity shared by every source-package
  ## construction path. Dependency and user-option channels intentionally
  ## remain empty until those identities are resolved canonically.
  newCacheEntryIdentity(
    packageName = packageName,
    packageVersion = packageVersion,
    platform = publicInterfaceTriple(),
    toolchain = publicInterfaceToolchain(conventionTag),
    providerRevision = sourceProviderRevisionHex(projectRoot))

## Pending binary-cache identity composition for source-built packages.
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
      "\\\\?\\" & os.normalizedPath(absolutePath(path)).replace('/', '\\')
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
  ## This entry-file digest is diagnostic, not the source closure: imported
  ## recipes, SDK generators, selected dependencies/options and the actual
  ## toolchain are not yet bound here. Refuse package-cache reuse until the
  ## complete solved instance is available. Ordinary action caching is separate.
  ##
  ## An identity whose provider-revision component would come out EMPTY is
  ## refused rather than returned. Two things produce one:
  ##
  ##   * an empty ``projectRoot``, which makes ``resolveProjectFile`` resolve
  ##     relative to the current working directory. With the cwd already at
  ##     the recipe's own directory that silently yields the RIGHT digest, and
  ##     from anywhere else it yields no digest at all — so the same call
  ##     produces two different identities depending on where the process
  ##     happens to be standing, and neither outcome is announced;
  ##   * a root that carries no recipe file, or a recipe file that is empty.
  ##
  ## The component is not optional decoration. It is what distinguishes one
  ## recipe's entry from another's in a CONTENT-ADDRESSED store, and an empty
  ## one is a value every recipe that hits this path shares. Unrelated
  ## packages colliding on a cache key is the failure this whole identity
  ## exists to prevent, so producing one silently is the one thing this
  ## function must not do. It raises ``CacheKeyError`` — the same error the
  ## downstream key derivation raises for an identity that may not authorise
  ## reuse — because a caller that is prepared for one is prepared for this.
  # The empty root is refused on the ARGUMENT, before the revision is
  # computed, and that ordering is the whole point rather than a style
  # choice. Refusing only the empty RESULT leaves the worse half of the
  # defect in place: standing in the recipe's own directory, an empty root
  # resolves through the cwd, finds that recipe and returns a perfectly
  # good digest — so the call succeeds, for a reason none of its arguments
  # supplied, and the same call from one directory over produces a
  # different identity. That was measured, not supposed: this rule was
  # first written as a check on the revision alone and its own gate
  # reported it green-on-defect from inside a recipe directory.
  if projectRoot.len == 0:
    raise newException(CacheKeyError,
      "cannot derive a source cache identity for package '" & packageName &
      "': no project root was given. An empty root resolves the recipe " &
      "relative to the current working directory, so this call would " &
      "produce a different identity depending on where the process is " &
      "running — or no identity at all.")
  let providerRevision = sourceProviderRevisionHex(projectRoot)
  if providerRevision.len == 0:
    raise newException(CacheKeyError,
      "cannot derive a source cache identity for package '" & packageName &
      "': the provider revision is empty, because no non-empty recipe " &
      "file was found under '" & projectRoot & "'. An empty provider " &
      "revision is a cache-key component that every such package would " &
      "share.")
  result = newCacheEntryIdentity(
    packageName = packageName,
    packageVersion = packageVersion,
    platform = publicInterfaceTriple(),
    toolchain = publicInterfaceToolchain(conventionTag),
    providerRevision = providerRevision)
  result.addOption(PendingCacheIdentityOptionKey,
    "source closure, resolved dependencies/options and toolchain are unbound")

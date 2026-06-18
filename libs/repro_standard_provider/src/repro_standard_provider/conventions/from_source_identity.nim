## Shared M9.L.4-refactor Step B identity helpers for the four
## from-source conventions (``from_source_meson`` / ``from_source_cmake``
## / ``from_source_autotools`` / ``from_source_make``).
##
## ## Step A vs. Step B
##
## Step A added an engine-side ``BinaryCachePublisher`` closure hook that
## fires after a successful ``BuildAction`` if the action carries
## ``publishToBinaryCache = true`` and ``cacheEntryIdentity.isSome``.
## Step B retires the convention-emitted publish actions in favour of
## stamping those two fields on the install + stage-copy actions; the
## engine's hook then publishes transparently. The convention layer is
## back to fetch + configure + build + install + stage-copy and never
## emits a binary-cache CLI invocation as a build edge.
##
## This module therefore retains the **identity-composition helpers**
## (``m9L4PlatformTriple`` / ``m9L4ToolchainIdentity`` /
## ``providerRevisionHex`` / ``deriveCacheKeyHex``) plus a new
## ``computeCacheEntryIdentity`` proc the conventions feed into
## ``BuildActionDef.cacheEntryIdentity``. The Step-A-era
## ``emitPublishAction`` proc is gone — its responsibility moved into
## the engine's ``publishBinaryCacheBundle`` (see
## ``libs/repro_build_engine/src/repro_build_engine.nim``
## §publishBinaryCacheBundle).
##
## ## Cache-key composition (v1 — partial identity)
##
## ``computeCacheEntryIdentity`` populates a
## ``CacheEntryIdentity`` whose fields are:
##
##   * ``packageName`` (from the recipe's ``package <name>:`` header).
##   * ``packageVersion`` (the last entry of ``registeredVersions(pkg)``
##     — empty when no ``versions:`` block exists).
##   * ``providerRevision`` (BLAKE3 hex of the recipe file bytes,
##     truncated to 32 lowercase-hex chars).
##   * A hardcoded Linux x86_64 / GNU / glibc ``PlatformTriple`` (host
##     detection deferred).
##   * A ``ToolchainIdentity`` whose ``name`` is the convention tag
##     (``"meson"`` / ``"cmake"`` / ``"autotools"`` / ``"make"``);
##     version + host-ldso left empty (detection deferred).
##
## Deferred slots (intentionally empty for v1, will shift the key when
## populated): ``sortedOptions`` (M9.I per-channel flag projection),
## ``sortedDepClosureDigest`` (cross-recipe dep resolution).
##
## ## See also
##
##   * ``from_source_meson.nim`` / ``from_source_cmake.nim`` /
##     ``from_source_autotools.nim`` / ``from_source_make.nim`` — call
##     ``computeCacheEntryIdentity`` from their ``emitFragment`` and
##     pass the result into ``buildAction(... cacheEntryIdentity = ...)``
##     on the install + stage-copy edges.
##   * ``reprobuild-specs/M9-DSL-Port-Engine-Provider.milestones.org``
##     §M9.L for the milestone history.

import std/[options, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl

# M9.L.4 binary-cache identity wiring. ``cache_key`` derives the on-wire
# entry-key hex from a ``CacheEntryIdentity`` tuple; ``types`` carries
# the ``PlatformTriple`` + ``ToolchainIdentity`` shapes the identity
# tuple requires. Both are re-exported by ``repro_project_dsl`` since
# M9.L.4-refactor Step B added ``cacheEntryIdentity`` to
# ``BuildActionDef`` — but we keep the explicit imports so the helpers
# below can be unit-tested without dragging the whole DSL umbrella in.
import repro_binary_cache_client/cache_key
import repro_binary_cache_server/types as bcs_types
import blake3

proc providerRevisionHex*(projectRoot: string): string =
  ## BLAKE3 of the recipe file bytes, truncated to 32 hex chars. Empty
  ## when the recipe file can't be read (the publish key still derives
  ## via the rest of the identity tuple — the empty string round-trips
  ## through the canonical encoder).
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  let bodyStr =
    try: readFile(extendedPath(match.path))
    except CatchableError: ""
  if bodyStr.len == 0:
    return ""
  let dig = blake3.digest(bodyStr)
  let full = blake3.toHex(dig)
  if full.len >= 32: full[0 ..< 32] else: full

proc m9L4PlatformTriple*(): bcs_types.PlatformTriple =
  ## Hardcoded Linux x86_64 GNU glibc triple — the M9.L.4 vertical-slice
  ## target. A follow-up milestone lifts host detection (Windows / macOS
  ## / aarch64) into a shared helper. The convention DOES populate every
  ## field so the canonical encoder round-trips identically across hosts
  ## that compute the same identity tuple.
  bcs_types.PlatformTriple(
    cpu: "x86_64",
    os: "linux",
    abi: "gnu",
    libcVariant: "glibc")

proc m9L4ToolchainIdentity*(name: string): bcs_types.ToolchainIdentity =
  ## Toolchain identity for the from-source pipeline. The ``name`` is
  ## the convention tag (``"meson"`` / ``"cmake"`` / ``"autotools"`` /
  ## ``"make"``). Version + host-ldso detection are deferred (see
  ## module docstring); the empty strings round-trip through the
  ## canonical encoder so a follow-up that fills them in will produce
  ## a DIFFERENT cache key (intended — the spec mandates toolchain
  ## differences shift the key).
  bcs_types.ToolchainIdentity(
    name: name,
    version: "",
    hostLdSoAbi: "",
    extraFingerprint: "")

proc deriveCacheKeyHex*(projectRoot, packageName, toolchainName: string): string =
  ## Compose the M9.L.4 v1 ``CacheEntryIdentity`` and derive its
  ## 64-char hex key. The deferrals (empty options / empty dep-closure
  ## / hardcoded platform / partial toolchain) are documented in the
  ## module docstring. Kept public for tests that pin the key shape
  ## without round-tripping through the engine hook.
  let versionStr = block:
    var v = ""
    let vs = registeredVersions(packageName)
    if vs.len > 0:
      v = vs[^1].version
    v
  var identity = newCacheEntryIdentity(
    packageName = packageName,
    packageVersion = versionStr,
    platform = m9L4PlatformTriple(),
    toolchain = m9L4ToolchainIdentity(toolchainName),
    providerRevision = providerRevisionHex(projectRoot))
  # options + depClosure intentionally empty for v1.
  deriveCacheEntryKeyHex(identity)

proc computeCacheEntryIdentity*(projectRoot, packageName,
                                conventionTag: string):
    CacheEntryIdentity =
  ## Step B's single-call entry point: returns the populated
  ## ``CacheEntryIdentity`` tuple the convention stamps on the install
  ## + stage-copy ``BuildActionDef`` via the new
  ## ``cacheEntryIdentity = some(...)`` argument on ``buildAction``.
  ## The engine's ``BinaryCachePublisher`` hook re-derives the entry-key
  ## hex from the same tuple (drift-guard) and signs the manifest.
  ##
  ## Inputs:
  ##   * ``projectRoot`` — path to the recipe directory; used to read
  ##     the recipe file bytes for the BLAKE3 ``providerRevision``.
  ##   * ``packageName`` — the recipe header (``package <name>:``); also
  ##     the M9.H ``registeredFetchSpec`` / M9.K
  ##     ``registeredVersions`` registry key.
  ##   * ``conventionTag`` — ``"meson"`` / ``"cmake"`` / ``"autotools"``
  ##     / ``"make"``; lands in ``ToolchainIdentity.name``.
  let versionStr = block:
    var v = ""
    let vs = registeredVersions(packageName)
    if vs.len > 0:
      v = vs[^1].version
    v
  newCacheEntryIdentity(
    packageName = packageName,
    packageVersion = versionStr,
    platform = m9L4PlatformTriple(),
    toolchain = m9L4ToolchainIdentity(conventionTag),
    providerRevision = providerRevisionHex(projectRoot))

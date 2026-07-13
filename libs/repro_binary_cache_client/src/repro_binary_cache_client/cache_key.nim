## ReproOS-Generations-And-Foreign-Packages A3 P1 — cache-entry-key derivation.
##
## Public surface for deriving a ``CacheEntryKey`` (and the canonical
## 32-byte BLAKE3 digest of its encoding) from a structured
## ``CacheEntryIdentity`` tuple as defined by
## ``reprobuild-specs/Binary-Caches.md`` § "Cache Entry Identity":
##
##   * package name
##   * package version
##   * selected options (Table[string,string])
##   * target platform + ABI
##   * toolchain identity (gcc version + ldso ABI + binutils version)
##   * dep-closure identity (sorted list of dep entry-key hex)
##   * provider revision identity (recipe sha256)
##
## ## Why a separate identity type?
##
## ``CacheEntryKey`` (in ``repro_binary_cache_server/types.nim``) is the
## on-wire / on-disk shape — its fields are the codec's source of truth.
## ``CacheEntryIdentity`` is the **build-script-friendly** input shape:
##
##   * Options ride a ``Table[string,string]`` (the natural shape for a
##     build script that snapshots its option flags), not a
##     pre-sorted ``seq[(string, string)]``.
##   * Dep-closure carries a ``seq[string]`` of dep entry-key hex
##     strings; we BLAKE3-fold them into ``depClosureDigest``
##     internally so call sites don't repeat the canonical encoding.
##   * Toolchain identity is split into name + version + ldso + binutils
##     so the build script can populate fields it knows without
##     guessing the canonical concatenation.
##
## ## Canonical encoding
##
## The on-disk encoding lives in
## ``repro_binary_cache_server/key.encodeCacheEntryKey`` — the same
## function the manifest envelope uses on publish. We DELIBERATELY do
## not re-implement the canonical bytes here; instead this module
## constructs a ``CacheEntryKey`` value with the spec-mandated invariants
## (sorted options, hashed dep closure, normalised platform/ABI strings)
## and delegates the encoding to the existing implementation. This
## avoids the drift hazard called out in
## ``manifest_codec.decodeCacheEntryKey``.
##
## ## Collision resistance
##
## The final 32-byte digest is BLAKE3-256 over the canonical encoding.
## Two distinct ``CacheEntryIdentity`` tuples produce distinct canonical
## byte sequences (the encoder is injective modulo the sort + closure-
## fold normalisations), so digest collisions are bounded by BLAKE3-256
## (cryptographically infeasible for the campaign's lifetime).

import std/[algorithm, strutils, tables]

import blake3

import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../../repro_binary_cache_server/src/repro_binary_cache_server/key as bcsKey

export bcsKey.encodeCacheEntryKey, bcsKey.cacheEntryKeyDigest,
       bcsKey.cacheEntryKeyHex, bcsKey.digestToHex, bcsKey.hexToDigest

type
  CacheEntryIdentity* = object
    ## The build-script-friendly representation of the Binary-Caches.md
    ## § "Cache Entry Identity" tuple. ``deriveCacheEntryKey`` normalises
    ## this into a ``CacheEntryKey`` whose canonical encoding is the
    ## key.nim canonical bytes.
    packageName*: string
    packageVersion*: string
    selectedOptions*: TableRef[string, string]
      ## Build-script-friendly option store. Sorted lexicographically
      ## by name inside ``deriveCacheEntryKey`` so insertion order does
      ## not perturb the key.
    platform*: PlatformTriple
    toolchain*: ToolchainIdentity
    depClosure*: seq[string]
      ## Sorted-or-unsorted list of dep ``CacheEntryKey`` hex strings.
      ## ``deriveCacheEntryKey`` sorts lexicographically before
      ## BLAKE3-folding into ``depClosureDigest``.
    providerRevision*: string
      ## sha256 (or any opaque hex) of the recipe / provider script
      ## bytes. The build-script prelude computes this via
      ## ``sha256sum build-X.sh | awk '{print $1}'``.

  CacheKeyError* = object of CatchableError

# ---------------------------------------------------------------------------
# Identity constructor helpers
# ---------------------------------------------------------------------------

proc newCacheEntryIdentity*(packageName, packageVersion: string;
                            platform: PlatformTriple;
                            toolchain: ToolchainIdentity;
                            providerRevision: string): CacheEntryIdentity =
  ## Construct an identity with empty options + empty dep-closure.
  result = CacheEntryIdentity(
    packageName: packageName,
    packageVersion: packageVersion,
    selectedOptions: newTable[string, string](),
    platform: platform,
    toolchain: toolchain,
    depClosure: @[],
    providerRevision: providerRevision)

proc publicInterfaceTriple*(): PlatformTriple =
  ## L3 PUBLISH-SCOPE — the single source of truth for the M9.L.4
  ## vertical-slice platform triple (Linux x86_64 GNU glibc). Both the
  ## from-source conventions (via ``from_source_identity``) and the
  ## hand-authored ``build:``-block publish path (via the DSL stdlib's
  ## ``nim.c`` alias) compose their ``CacheEntryIdentity`` off this
  ## helper so a public-interface artifact built either way lands under
  ## a byte-identical cache-entry key. Host detection (Windows / macOS /
  ## aarch64) is deferred; every field is populated so the canonical
  ## encoder round-trips identically across hosts that compute the same
  ## identity tuple.
  PlatformTriple(cpu: "x86_64", os: "linux", abi: "gnu", libcVariant: "glibc")

proc publicInterfaceToolchain*(name: string): ToolchainIdentity =
  ## L3 PUBLISH-SCOPE — toolchain-identity shape shared between the
  ## from-source and build-block publish paths. ``name`` is the
  ## convention/toolchain tag (``"nim"`` for the ``nim.c`` alias);
  ## version + host-ldso detection are deferred (empty strings
  ## round-trip through the canonical encoder — a follow-up that fills
  ## them in intentionally shifts the key).
  ToolchainIdentity(name: name, version: "", hostLdSoAbi: "", extraFingerprint: "")

proc publicInterfaceIdentity*(packageName, packageVersion, toolchainName,
                              providerRevision: string): CacheEntryIdentity =
  ## L3 PUBLISH-SCOPE — compose the public-interface publish identity
  ## from already-resolved inputs. Kept layer-neutral (no ``os`` /
  ## recipe-registry access) so the DSL stdlib can call it with the
  ## member name as ``packageName`` and its own resolved recipe
  ## revision, producing the SAME tuple shape the Nim convention's
  ## ``computeCacheEntryIdentity`` builds for an auto-tagged member.
  newCacheEntryIdentity(
    packageName = packageName,
    packageVersion = packageVersion,
    platform = publicInterfaceTriple(),
    toolchain = publicInterfaceToolchain(toolchainName),
    providerRevision = providerRevision)

proc addOption*(idy: var CacheEntryIdentity; name, value: string) =
  if idy.selectedOptions.isNil:
    idy.selectedOptions = newTable[string, string]()
  idy.selectedOptions[name] = value

proc addDep*(idy: var CacheEntryIdentity; depEntryKeyHex: string) =
  ## Append a dep cache-entry-key hex to the closure. The encoder
  ## sorts + de-duplicates before BLAKE3-folding so call order
  ## does not affect the result.
  if depEntryKeyHex.len != 64:
    raise newException(CacheKeyError,
      "dep entry-key hex must be 64 chars; got " & $depEntryKeyHex.len &
      " for value " & depEntryKeyHex)
  for ch in depEntryKeyHex:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      raise newException(CacheKeyError,
        "dep entry-key hex carries non-hex char: " & depEntryKeyHex)
  idy.depClosure.add(depEntryKeyHex.toLowerAscii())

# ---------------------------------------------------------------------------
# Internal: canonical dep-closure digest
# ---------------------------------------------------------------------------

proc encodeDepClosure(sortedDeps: seq[string]): seq[byte] =
  ## Canonical encoding of the dep-closure list, fed to BLAKE3-256.
  ## Shape: u32-le count || (u32-le hex_len || hex_bytes) per entry.
  ## The hex is lowercased before encoding so the digest is
  ## independent of the input case.
  result = newSeqOfCap[byte](4 + sortedDeps.len * (4 + 64))
  let count = uint32(sortedDeps.len)
  for shift in countup(0, 24, 8):
    result.add(byte((count shr uint32(shift)) and 0xff'u32))
  for hex in sortedDeps:
    let n = uint32(hex.len)
    for shift in countup(0, 24, 8):
      result.add(byte((n shr uint32(shift)) and 0xff'u32))
    for ch in hex:
      result.add(byte(ch))

proc depClosureDigest*(deps: openArray[string]): Blake3Hash =
  ## Public for tests + the build-script prelude that wants the
  ## intermediate digest. Sorts + lowercases + de-duplicates the input
  ## before encoding.
  var normalised: seq[string] = @[]
  for hex in deps:
    if hex.len != 64:
      raise newException(CacheKeyError,
        "dep entry-key hex must be 64 chars; got " & $hex.len)
    normalised.add(hex.toLowerAscii())
  normalised.sort(cmp)
  # De-duplicate in-place: once sorted, equal values are adjacent.
  var deduped: seq[string] = @[]
  for hex in normalised:
    if deduped.len == 0 or deduped[^1] != hex:
      deduped.add(hex)
  let encoded = encodeDepClosure(deduped)
  if encoded.len == 0:
    # Empty-closure shortcut: BLAKE3 of the zero-length input still
    # yields a deterministic 32-byte hash, but we expose a clearer
    # all-zeros sentinel so build scripts can spot "no deps" at a
    # glance. The empty encoding (4 zero bytes for the count) maps to
    # a real BLAKE3 digest — we use that, not all-zeros, so the
    # zero sentinel can't accidentally collide with a real closure.
    discard
  let raw = blake3.digest(encoded)
  for i in 0 ..< 32:
    result[i] = raw[i]

# ---------------------------------------------------------------------------
# The main deriver
# ---------------------------------------------------------------------------

proc deriveCacheEntryKey*(idy: CacheEntryIdentity): CacheEntryKey =
  ## Maps a build-script-friendly ``CacheEntryIdentity`` into the
  ## canonical ``CacheEntryKey`` consumed by the manifest codec +
  ## the on-wire ``/manifests/<hex>`` route.
  ##
  ## Normalisations:
  ##   * ``selectedOptions`` is sorted lexicographically by key.
  ##   * ``depClosure`` is sorted, lowercased, de-duplicated, and
  ##     BLAKE3-folded into ``depClosureDigest``.
  ##   * Empty strings are preserved verbatim so the codec round-trips.
  ##
  ## The returned ``CacheEntryKey`` can be re-encoded via
  ## ``encodeCacheEntryKey`` (re-exported from this module) to obtain
  ## the canonical bytes, and ``cacheEntryKeyDigest`` returns the
  ## 32-byte BLAKE3-256 digest used as the on-wire entry key.
  result.packageName = idy.packageName
  result.packageVersion = idy.packageVersion
  # Options: extract + sort lexicographically by key.
  var opts: seq[(string, string)] = @[]
  if not idy.selectedOptions.isNil:
    for name, value in idy.selectedOptions.pairs:
      opts.add((name, value))
    opts.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  result.selectedOptions = opts
  result.platform = idy.platform
  result.toolchain = idy.toolchain
  result.depClosureDigest = depClosureDigest(idy.depClosure)
  result.providerRevision = idy.providerRevision

proc deriveCacheEntryKeyHex*(idy: CacheEntryIdentity): string =
  ## Convenience: derive + hex-encode in one call. The 64-char hex
  ## string is what the build-script prelude passes to
  ## ``repro-binary-cache-client lookup`` / ``substitute`` / ``publish``.
  cacheEntryKeyHex(deriveCacheEntryKey(idy))

## Windows-Runner-Binary-Cache-Deploy M4 — apply-time binary-cache
## substitute for `repro infra apply`'s build-action edges.
##
## M3b did the client-seed analog (substitute-first / build-from-source
## on miss) for the Windows client bootstrap. M4 is the apply-time
## analog: when `repro infra apply` runs a profile that carries
## build-action edges (extract this zip, run this config script, ...),
## and a binary cache is configured (`REPRO_BINARY_CACHE_URL` set), the
## apply PREFERS fetching each edge's OUTPUTS from the cache
## (`bakBinaryCacheSubstitute`) instead of building them locally. On a
## cache MISS (or when no cache is configured) it falls back to the
## existing local build, then publishes the freshly-built outputs back
## under the same content-addressable key so a subsequent fresh apply
## hits.
##
## Off-by-default: when `REPRO_BINARY_CACHE_URL` is unset,
## `resolveBuildActionCacheConfig` returns `configured = false` and the
## dispatcher takes the unchanged local-build path — behaviour is
## byte-identical to pre-M4 `repro infra apply`.
##
## Content-addressable key: the cache identity for a build-action edge
## folds the action's weak fingerprint (id + argv + cwd + outputs +
## tool refs + elevation flag — see
## `apply_build_actions.weakFingerprintForProfileBuildAction`) into the
## key material. Two applies of the SAME profile against the SAME
## toolchain derive the SAME key, so the substituted outputs are
## byte-identical to a local build (the cache is content-addressed).
## Any change to the action definition derives a DIFFERENT key, so a
## stale cache entry can never shadow a changed edge.

import std/[os, strutils]

import repro_binary_cache_client
import repro_binary_cache_client/engine_publisher as bcEnginePublisher
import repro_build_engine
import repro_hash

import repro_profile

import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

type
  BuildActionCacheConfig* = object
    ## Resolved binary-cache configuration for the action-edge half of
    ## an apply. `configured = false` (the default when
    ## `REPRO_BINARY_CACHE_URL` is unset) turns the whole M4 path off:
    ## the dispatcher builds locally, exactly as before.
    configured*: bool
    endpoint*: string
    keyPath*: string
    certPath*: string
    keypairOk*: bool
      ## True when a signing keypair (env-supplied or auto-generated)
      ## is available. Publish-on-miss needs it; a false value means we
      ## can still SUBSTITUTE (verification only needs the server's
      ## signature) but cannot PUBLISH — a cache miss then builds
      ## locally without re-populating the cache (loud, non-fatal).

  SubstituteAttempt* = object
    ## Result of one `trySubstituteBuildAction` call.
    hit*: bool            ## true when the outputs were served from cache
    reason*: string       ## populated on a miss / error (diagnostic)
    bytesFetched*: int64

proc resolveBuildActionCacheConfig*(): BuildActionCacheConfig =
  ## Read `REPRO_BINARY_CACHE_URL` (+ key/cert paths). When the URL is
  ## unset the cache is NOT configured and the result's other fields are
  ## empty — the dispatcher's local-build path is unchanged. When the
  ## URL is set we resolve a signing keypair the same way the engine's
  ## `BinaryCachePublisher` does: env-supplied key/cert if both exist,
  ## otherwise an auto-generated ECDSA-P256 keypair under the per-OS
  ## config dir. A keypair failure is non-fatal (substitute still works;
  ## publish-on-miss is skipped).
  let url = getEnv("REPRO_BINARY_CACHE_URL", "")
  if url.len == 0:
    result.configured = false
    return
  result.configured = true
  result.endpoint = url
  let env = bcEnginePublisher.readPublisherEnv()
  var keyPath = env.keyPath
  var certPath = env.certPath
  let envPathsUsable = keyPath.len > 0 and certPath.len > 0 and
    fileExists(keyPath) and fileExists(certPath)
  if envPathsUsable:
    result.keyPath = keyPath
    result.certPath = certPath
    result.keypairOk = true
  else:
    let dir = bcEnginePublisher.defaultAutoCredentialDir()
    var resolvedKey, resolvedCert: string
    let outcome = bcEnginePublisher.ensureAutoProducerKeypair(
      dir, resolvedKey, resolvedCert)
    if outcome.ok:
      result.keyPath = resolvedKey
      result.certPath = resolvedCert
      result.keypairOk = true
    else:
      result.keypairOk = false

# ---------------------------------------------------------------------------
# Content-addressable cache identity for a build-action edge.
# ---------------------------------------------------------------------------

proc contentDigestHex(d: ContentDigest): string =
  ## Lowercase hex of a `repro_hash.ContentDigest` (the weak-fingerprint
  ## type). 64 hex chars — used verbatim as the entry-key provider
  ## revision + toolchain extra-fingerprint so the cache key tracks the
  ## action definition.
  const HexChars = "0123456789abcdef"
  result = newStringOfCap(d.bytes.len * 2)
  for b in d.bytes:
    result.add(HexChars[(int(b) shr 4) and 0xf])
    result.add(HexChars[int(b) and 0xf])

proc outputRelPaths(action: ProfileBuildAction): seq[string]
  ## Forward declaration — the full definition lives below in the
  ## output-prefix mapping section; ``cacheFingerprintHex`` needs the
  ## cwd-relative output paths to build a placement-independent key.

proc cacheFingerprintHex(action: ProfileBuildAction): string =
  ## Content-addressable fingerprint for a build-action edge's BINARY
  ## CACHE key. Deliberately CWD-INDEPENDENT: it mixes the action id,
  ## argv, cwd-relative output paths, tool refs, elevation flag, and
  ## command-stats id — but NOT the absolute ``cwd``. The apply-scratch
  ## cwd is a per-apply placement detail (a fresh box may extract into
  ## a differently-rooted target dir), so folding it into the key would
  ## make two applies of the SAME profile derive DIFFERENT keys and
  ## never hit. Excluding it keeps the key a pure function of WHAT is
  ## built, independent of WHERE the local scratch lives. The engine's
  ## own weak fingerprint (which DOES include cwd) still governs the
  ## LOCAL action-cache; the two caches are keyed independently.
  var parts = @[
    "reprobuild.infraApply.binaryCacheKey.v1",
    action.id,
    (if action.requiresElevation: "elevated" else: "direct"),
    action.commandStatsId]
  for a in action.argv:
    parts.add("argv:" & a)
  for rel in outputRelPaths(action):
    parts.add("out:" & rel)
  for t in action.toolIdentityRefs:
    parts.add("tool:" & t)
  contentDigestHex(weakFingerprintFromText(parts.join("\n")))

proc buildActionCacheIdentity*(action: ProfileBuildAction;
                               storeRoot: string): CacheEntryIdentity =
  ## Derive the content-addressable `CacheEntryIdentity` for one
  ## build-action edge. The platform is the LOCAL platform (so the
  ## substitute compat-check passes on the host running the apply). The
  ## cwd-independent `cacheFingerprintHex` is folded into BOTH the
  ## provider-revision and the toolchain extra-fingerprint so the key is
  ## a pure function of the action definition + host platform (NOT the
  ## apply-scratch cwd — see `cacheFingerprintHex`).
  let local = detectLocalPlatform(storeRoot)
  let platform = PlatformTriple(cpu: local.cpu, os: local.os,
                                abi: local.abi, libcVariant: local.libcVariant)
  let fpHex = cacheFingerprintHex(action)
  result = newCacheEntryIdentity(
    packageName = "infra-apply-action." & action.id,
    packageVersion = "1",
    platform = platform,
    toolchain = ToolchainIdentity(name: "infra-apply", version: "1",
                                  hostLdSoAbi: "",
                                  extraFingerprint: fpHex),
    providerRevision = fpHex)

# ---------------------------------------------------------------------------
# Output-prefix <-> cwd mapping.
#
# A build-action edge declares its outputs as paths relative to (or
# under) `cwd`. To publish/substitute those outputs as a single
# rbcarc-v1 prefix we stage them into a temp prefix tree that mirrors
# their cwd-relative paths, then pack THAT. On substitute we extract the
# fetched archive into a temp dir and copy each member back under `cwd`,
# byte-identically.
# ---------------------------------------------------------------------------

proc outputRelPaths(action: ProfileBuildAction): seq[string] =
  ## Normalise the action's declared outputs to cwd-relative POSIX-style
  ## paths. An absolute output under `cwd` is made relative; an output
  ## that already is relative is kept as-is.
  let cwdAbs = (if action.cwd.len > 0: absolutePath(action.cwd)
                else: getCurrentDir())
  for o in action.outputs:
    var rel = o
    if isAbsolute(o):
      let oAbs = absolutePath(o)
      if oAbs.startsWith(cwdAbs & $DirSep) or oAbs == cwdAbs:
        rel = relativePath(oAbs, cwdAbs)
      else:
        # Output outside cwd — cannot map into a cwd-rooted prefix.
        # Signal by skipping; the caller treats an empty rel-set as
        # "not substitutable" and falls back to a local build.
        continue
    result.add(rel.replace('\\', '/'))

proc collectFilesUnder(root, rel: string; acc: var seq[string]) =
  ## Append every regular file under `root/rel` as a `root`-relative
  ## path. `rel` may name a file or a directory.
  let abs = root / rel
  if fileExists(abs):
    acc.add(rel.replace('\\', '/'))
  elif dirExists(abs):
    for path in walkDirRec(abs, yieldFilter = {pcFile, pcLinkToFile},
                           relative = true):
      acc.add((rel / path).replace('\\', '/'))

proc stagePrefixFromOutputs(action: ProfileBuildAction;
                            stageDir: string): bool =
  ## Copy the action's declared outputs (from `cwd`) into `stageDir`,
  ## preserving their cwd-relative paths, so `packPrefix(stageDir)`
  ## yields the outputs archive. Returns false when there is nothing
  ## substitutable (no in-cwd outputs, or an output missing on disk).
  let cwdAbs = (if action.cwd.len > 0: absolutePath(action.cwd)
                else: getCurrentDir())
  let rels = outputRelPaths(action)
  if rels.len == 0:
    return false
  var members: seq[string] = @[]
  for rel in rels:
    if not (fileExists(cwdAbs / rel) or dirExists(cwdAbs / rel)):
      # A declared output that doesn't exist after a build is an
      # engine-level problem; refuse to publish a partial prefix.
      return false
    collectFilesUnder(cwdAbs, rel, members)
  if members.len == 0:
    return false
  createDir(stageDir)
  for rel in members:
    let src = cwdAbs / rel
    let dst = stageDir / rel
    createDir(parentDir(dst))
    copyFileWithPermissions(src, dst)
  return true

proc materialisePrefixIntoCwd(action: ProfileBuildAction;
                              extractedDir: string) =
  ## Copy every file under `extractedDir` (a freshly-extracted rbcarc
  ## prefix) back under the action's `cwd`, byte-identically, preserving
  ## permissions (so the exec bit the archive carried survives).
  let cwdAbs = (if action.cwd.len > 0: absolutePath(action.cwd)
                else: getCurrentDir())
  for path in walkDirRec(extractedDir, yieldFilter = {pcFile, pcLinkToFile},
                         relative = true):
    let src = extractedDir / path
    let dst = cwdAbs / path
    createDir(parentDir(dst))
    copyFileWithPermissions(src, dst)

proc outputsExist(action: ProfileBuildAction): bool =
  ## True when every mappable declared output is present on disk under
  ## `cwd` — the post-substitute integrity check.
  let cwdAbs = (if action.cwd.len > 0: absolutePath(action.cwd)
                else: getCurrentDir())
  let rels = outputRelPaths(action)
  if rels.len == 0:
    return false
  for rel in rels:
    if not (fileExists(cwdAbs / rel) or dirExists(cwdAbs / rel)):
      return false
  return true

# ---------------------------------------------------------------------------
# Substitute-first + publish-on-miss.
# ---------------------------------------------------------------------------

proc trySubstituteBuildAction*(action: ProfileBuildAction;
                               cfg: BuildActionCacheConfig;
                               scratchRoot: string): SubstituteAttempt =
  ## Attempt to serve one build-action edge's OUTPUTS from the binary
  ## cache. On a HIT: materialise the outputs under `cwd`
  ## byte-identically and return `hit = true`. On a MISS / any error:
  ## return `hit = false` with a diagnostic `reason` so the caller
  ## falls back to a local build. Never raises — a cache problem must
  ## degrade to a local build, not abort the apply.
  result.hit = false
  if not cfg.configured:
    result.reason = "no binary cache configured"
    return
  # Only edges with mappable in-cwd outputs are substitutable.
  if outputRelPaths(action).len == 0:
    result.reason = "action declares no cwd-relative outputs"
    return
  let idy = buildActionCacheIdentity(action, scratchRoot)
  let entryHex = deriveCacheEntryKeyHex(idy)
  let store = scratchRoot / "store"
  let extractDir = scratchRoot / "extract"
  try:
    createDir(store)
    let endpoint = SubstituteEndpoint(
      baseUrl: cfg.endpoint, trustedSigners: @[], priority: 0)
    let res = substituteInProcess(entryHex, store, @[endpoint])
    if not res.ok or res.outcomes.len == 0:
      result.reason = "cache miss for " & entryHex &
        (if res.reason.len > 0: ": " & res.reason else: "")
      return
    let rootOutcome = res.outcomes[^1]
    if rootOutcome.casPath.len == 0 or not fileExists(rootOutcome.casPath):
      result.reason = "substitute produced no CAS blob for " & entryHex
      return
    let archiveText = readFile(rootOutcome.casPath)
    var archiveBytes = newSeq[byte](archiveText.len)
    for i, ch in archiveText:
      archiveBytes[i] = byte(ch)
    removeDir(extractDir)
    createDir(extractDir)
    extractPrefix(archiveBytes, extractDir)
    materialisePrefixIntoCwd(action, extractDir)
    if not outputsExist(action):
      result.reason = "substituted archive did not materialise the " &
        "declared outputs for " & action.id
      return
    result.hit = true
    result.bytesFetched = rootOutcome.bytesFetched
  except CatchableError as e:
    result.hit = false
    result.reason = "substitute error for " & action.id & ": " & e.msg
  finally:
    try: removeDir(extractDir) except CatchableError: discard
    try: removeDir(store) except CatchableError: discard

proc publishBuildActionOutputs*(action: ProfileBuildAction;
                                cfg: BuildActionCacheConfig;
                                scratchRoot: string): tuple[ok: bool; reason: string] =
  ## Publish a freshly-built edge's OUTPUTS to the binary cache under
  ## the same content-addressable key `trySubstituteBuildAction` reads.
  ## Best-effort: any failure returns `ok = false` with a reason but
  ## MUST NOT abort the apply — the box already converged locally. When
  ## no signing keypair is available (`cfg.keypairOk == false`) we skip
  ## publishing entirely.
  if not cfg.configured or not cfg.keypairOk:
    return (ok: false,
            reason: "publish skipped (no cache / no signing keypair)")
  let stageDir = scratchRoot / "publish-stage"
  try:
    removeDir(stageDir)
    if not stagePrefixFromOutputs(action, stageDir):
      return (ok: false,
              reason: "no publishable outputs staged for " & action.id)
    let idy = buildActionCacheIdentity(action, scratchRoot)
    let entryHex = deriveCacheEntryKeyHex(idy)
    let keypair = peerAuth.loadOrGenerateKeypair(cfg.certPath, cfg.keyPath)
    let pubReq = PublishInProcessRequest(
      entryKeyHex: entryHex,
      prefixDir: stageDir,
      identity: idy,
      endpoint: cfg.endpoint,
      keypair: keypair)
    let pubRes = publishInProcess(pubReq)
    if pubRes.ok:
      return (ok: true, reason: "")
    return (ok: false, reason: "publish failed: " & pubRes.error)
  except CatchableError as e:
    return (ok: false, reason: "publish error for " & action.id & ": " & e.msg)
  finally:
    try: removeDir(stageDir) except CatchableError: discard

## Publish and substitute the PROVIDER-COMPILE edge's outputs.
##
## ## Why this module exists
##
## The binary cache on a populated host is a *materialized-output* cache: its
## payloads are install prefixes for source packages, restored by
## ``substituteMaterializedBinaryCacheEntries``. That shortens the LAST step of
##
##     repro.nim -> [nim c: interface] -> [nim c: provider] -> graph -> payload
##
## and nothing before it. Every consumer of a source package therefore still
## pays a full single-threaded ``nim c`` to build that package's provider
## binary, even when the package's own build output arrives from the cache
## whole. On a large closure that compile IS the wall clock.
##
## The engine cannot close this gap on its own today. Its scheduler consults
## exactly one remote on a local action-cache miss — the LAN peer cache, keyed
## on a weak fingerprint — and there is no binary-cache lookup anywhere on the
## ``runBuild`` path; a federated action cache is a separate, unbuilt phase. So
## the provider compile is published and substituted the way the one existing
## per-edge precedent does it (``repro_profile_compile``'s
## ``binary_cache_build_actions``): explicitly, by content-addressed identity,
## around the edge rather than inside the scheduler.
##
## ## What makes it safe to serve
##
## A provider binary is a compiled ELF. Serving one to a consumer whose inputs
## differ would "fail by serving a stale binary rather than by erroring", which
## is the one failure mode this must not have. Three things prevent it.
##
## 1. **The entry identity is content-addressed and covers the compile's whole
##    input surface.** ``providerCompileCacheIdentity`` folds two digests:
##      * ``providerCompileActionKey`` — the v1 action key: the
##        ``ProviderArtifactId`` (frontend runtime identity, source semantic
##        identity, interface fingerprint, entry-point bodies, provider
##        imports, dependency interface fingerprints, compile options) plus
##        the Nim compiler identity and the canonical source input paths; and
##      * ``providerFingerprint`` — the CONTENT of every recipe source, the
##        interface fingerprint, and ``reproLibSourceFingerprint``.
##
##    The reprobuild library sources are the ones that matter most: they are
##    compiled INTO the provider binary, and an entry key that does not move
##    when they change would serve a binary linked against code the consumer
##    does not have. They are covered TWICE — once through
##    ``providerFingerprint`` directly, and once inside the action key, whose
##    ``ProviderArtifactId`` folds ``frontendRuntimeIdentity(workDir)``, which
##    IS ``reproLibSourceFingerprint``.
##
##    That redundancy was not designed; it was measured, and the measurement
##    is recorded here because the first version of this comment asserted the
##    opposite. Removing EITHER term alone leaves every case of
##    ``t_provider_compile_cache_entry_is_content_addressed`` green; removing
##    BOTH reddens the library-edit and recipe-edit cases. So neither term is
##    load-bearing on its own and the gate cannot tell them apart. Both are
##    kept anyway, deliberately: they are derived by two independent procs in
##    two libraries, and a future change to one derivation should not be able
##    to silently widen what a published binary is keyed on.
##
##    Everything the monitor observes is therefore either hashed by content
##    here (the recipe closure, the reprobuild libraries, the declared package
##    dependency sources), identified by the Nim compiler identity (the
##    stdlib), or named by an absolute immutable-store path inside the compile
##    options (the C toolchain, blake3, xxhash, clingo, sqlite, bearssl) —
##    where the path IS a content hash. The residual is a file read from a
##    mutable location that is none of those; no such read is known, and the
##    check in (3) is what catches one if it exists.
##
## 2. **It is scoped to a platform.** The identity carries the detected local
##    platform AND folds ``__cachePlatformTag__`` with the concrete build
##    triple (``x86_64-unknown-linux-gnu``), NOT the ``"native"`` sentinel the
##    engine collapses onto for same-platform builds. An ELF must never be
##    reachable under a key an aarch64-darwin consumer can derive.
##
## 3. **Every restore is verified by the same check a compile is.** The
##    substitution restores the provider-compile ARTIFACT alongside the binary
##    and hands both to ``providerCompileConsistencyAfterExecution``. A restore
##    whose artifact does not describe the restored binary, or names another
##    interface or another output path, or whose source fingerprint cannot be
##    reconciled against the local inputs, is DISCARDED and the compile runs.
##    A wrong entry costs a rebuild; it can never be served.
##
## No timestamp enters the identity. An mtime is a statement about one
## machine's clock and filesystem, so anything crossing a machine boundary has
## to be keyed on content instead; every component above is a digest or a
## pinned immutable-store path.
##
## ## Reach
##
## ``providerCompileActionKey`` embeds the canonical ABSOLUTE source paths and
## the compile options embed absolute toolchain paths, so an entry is only
## derivable by a consumer whose workspace and tool store sit at the same
## paths. That is a real limit and it is stated rather than papered over: this
## shares provider compiles across RUNS and AGENTS on one host layout, not
## across arbitrary machines. A differently-laid-out consumer derives a
## different key and simply misses.

import std/[options, os, strutils]

import repro_core
import repro_hash
import repro_interface_artifacts

import ./cache_key
import ./caches_config
import ./compat_check
import ./in_process
import ./types
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../../repro_build_engine/src/repro_build_engine/platform as enginePlatform

const
  ProviderCompileCacheDomain* = "reprobuild.provider-compile.cache.v1"
    ## Domain separator for the combined identity digest. Bumping this is how
    ## a change to WHAT the identity covers retires every existing entry
    ## instead of silently reinterpreting it.
  ProviderCompileCachePackagePrefix* = "provider-compile."
  ProviderCompileCacheToolchain* = "repro-provider-compile"
  ProviderCompileCacheVersion* = "1"

  # Stable layout inside the published prefix. The consumer copies these
  # back to the paths its OWN plan names, so the archive never carries the
  # producer's directory shape.
  PrefixBinaryName* = "provider-binary"
  PrefixArtifactName* = "provider-compile.rbsz"
  PrefixSidecarName* = "provider-compile.rbsz.inputs"

type
  ProviderCompileCacheConfig* = object
    ## Resolved once per process by ``resolveProviderCompileCacheConfig``.
    configured*: bool
      ## At least one trusted endpoint is configured and the cache is not
      ## disabled. Required for BOTH substitute and publish.
    keypairOk*: bool
      ## A signing keypair is available. Required for publish only —
      ## substitution verifies the server's signature and needs no key.
    endpoints*: seq[SubstituteEndpoint]
    publishEndpoint*: string
    keyPath*: string
    certPath*: string

  ProviderCompileSubstituteAttempt* = object
    hit*: bool
    reason*: string
      ## Always populated on a miss, and it names the reason rather than
      ## reporting a bare miss — a substitution that silently declines is
      ## indistinguishable from one that was never attempted.
    entryKeyHex*: string
    bytesFetched*: int64

  ProviderCompilePublishAttempt* = object
    ok*: bool
    reason*: string
    entryKeyHex*: string
    bytesUploaded*: int

proc cacheDisabled(): bool =
  getEnv("REPRO_CACHE_DISABLE", "") in ["1", "true", "yes"]

proc resolveProviderCompileCacheConfig*(): ProviderCompileCacheConfig =
  ## Resolve trust and credentials. Mirrors the from-source substitution's
  ## configuration probe (``loadEndpoints`` + ``REPRO_CACHE_DISABLE``) so a
  ## wrapper that disables one disables the other, and resolves the signing
  ## keypair exactly as the engine's publisher does.
  if cacheDisabled():
    return
  try:
    result.endpoints = loadEndpoints()
  except CatchableError:
    return
  if result.endpoints.len == 0:
    return
  result.configured = true
  result.publishEndpoint = getEnv("REPRO_BINARY_CACHE_URL", "")
  if result.publishEndpoint.len == 0:
    result.publishEndpoint = result.endpoints[0].baseUrl
  let keyPath = getEnv("REPRO_BINARY_CACHE_KEY_PATH", "")
  let certPath = getEnv("REPRO_BINARY_CACHE_CERT_PATH", "")
  # Deliberately NOT falling back to an auto-generated keypair. An
  # auto-generated producer is not on a shared cache's allowed-signer list, so
  # every publish would be refused with an authz error that reads like a bug.
  # No key means "this host does not publish", which is a legitimate state.
  if keyPath.len > 0 and certPath.len > 0 and
      fileExists(keyPath) and fileExists(certPath):
    result.keyPath = keyPath
    result.certPath = certPath
    result.keypairOk = true

proc providerCompileIdentityDigest*(plan: ProviderCompilePlan): ContentDigest =
  ## The one digest the entry key is a function of. See the module header for
  ## why BOTH inputs are required and what each covers.
  var payload = ProviderCompileCacheDomain & "\x00"
  payload.add(toHex(plan.providerCompileActionKey.bytes) & "\x00")
  payload.add(toHex(plan.providerFingerprint.bytes) & "\x00")
  payload.add(toHex(plan.interfaceFingerprint.bytes) & "\x00")
  # The output binary's own path participates: two recipes that somehow
  # produced the same fingerprints for different destinations must not share
  # an entry, because the artifact records the destination and the consumer's
  # verification compares it.
  payload.add(normalizedProviderOutputPath(plan.outputBinaryPath))
  casDigest(toBytes(payload))

proc providerCompileCacheIdentity*(plan: ProviderCompilePlan;
                                   projectName: string;
                                   storeRoot = ""): CacheEntryIdentity =
  ## The content-addressed cache identity for one provider compile.
  let digestHexValue = toHex(providerCompileIdentityDigest(plan).bytes)
  let local = detectLocalPlatform(
    if storeRoot.len > 0: storeRoot else: getTempDir())
  result = newCacheEntryIdentity(
    packageName = ProviderCompileCachePackagePrefix &
      (if projectName.len > 0: projectName else: "unnamed"),
    packageVersion = ProviderCompileCacheVersion,
    platform = PlatformTriple(cpu: local.cpu, os: local.os,
                              abi: local.abi, libcVariant: local.libcVariant),
    toolchain = ToolchainIdentity(
      name: ProviderCompileCacheToolchain,
      version: ProviderCompileCacheVersion,
      hostLdSoAbi: "",
      extraFingerprint: digestHexValue),
    providerRevision = digestHexValue)
  # Platform namespacing, the same channel the engine's publish sites use.
  # The CONCRETE triple, never the ``native`` sentinel: the sentinel collapses
  # every same-platform build onto one key, which is right for a recipe that
  # does not care about the platform and wrong for a compiled ELF.
  result.addOption(enginePlatform.CachePlatformTagOptionKey,
    enginePlatform.buildPlatformTriple())

proc providerCompileEntryKeyHex*(plan: ProviderCompilePlan;
                                 projectName: string;
                                 storeRoot = ""): string =
  deriveCacheEntryKeyHex(
    providerCompileCacheIdentity(plan, projectName, storeRoot))

proc sidecarPath(artifactPath: string): string =
  artifactPath & ".inputs"

proc stageProviderCompilePrefix*(plan: ProviderCompilePlan;
                                 artifactPath, stageDir: string): bool =
  ## Copy the three files a consumer needs into a flat, producer-independent
  ## layout. Returns false when either required file is absent.
  let binaryPath = normalizedProviderOutputPath(plan.outputBinaryPath)
  if not fileExists(extendedPath(binaryPath)):
    return false
  if not fileExists(extendedPath(artifactPath)):
    return false
  removeDir(extendedPath(stageDir))
  createDir(extendedPath(stageDir))
  copyFileWithPermissions(extendedPath(binaryPath),
    extendedPath(stageDir / PrefixBinaryName))
  copyFile(extendedPath(artifactPath),
    extendedPath(stageDir / PrefixArtifactName))
  if fileExists(extendedPath(sidecarPath(artifactPath))):
    copyFile(extendedPath(sidecarPath(artifactPath)),
      extendedPath(stageDir / PrefixSidecarName))
  true

proc installProviderCompilePrefix*(plan: ProviderCompilePlan;
                                   artifactPath, extractDir: string): bool =
  ## Place an extracted prefix at the paths THIS plan names.
  let stagedBinary = extractDir / PrefixBinaryName
  let stagedArtifact = extractDir / PrefixArtifactName
  if not fileExists(extendedPath(stagedBinary)):
    return false
  if not fileExists(extendedPath(stagedArtifact)):
    return false
  let binaryPath = normalizedProviderOutputPath(plan.outputBinaryPath)
  createDir(extendedPath(parentDir(binaryPath)))
  createDir(extendedPath(parentDir(artifactPath)))
  copyFileWithPermissions(extendedPath(stagedBinary), extendedPath(binaryPath))
  copyFile(extendedPath(stagedArtifact), extendedPath(artifactPath))
  let stagedSidecar = extractDir / PrefixSidecarName
  if fileExists(extendedPath(stagedSidecar)):
    copyFile(extendedPath(stagedSidecar),
      extendedPath(sidecarPath(artifactPath)))
  else:
    removeFile(extendedPath(sidecarPath(artifactPath)))
  true

proc discardRestoredProviderCompile*(plan: ProviderCompilePlan;
                                     artifactPath: string) =
  ## Leave nothing behind that a later step could mistake for a good compile.
  removeFile(extendedPath(artifactPath))
  removeFile(extendedPath(sidecarPath(artifactPath)))
  removeFile(extendedPath(normalizedProviderOutputPath(plan.outputBinaryPath)))

proc acceptRestoredProviderCompilePrefix*(plan: ProviderCompilePlan;
                                          artifactPath, extractDir: string):
    ProviderCompileConsistency =
  ## Install an EXTRACTED prefix and decide whether to keep it.
  ##
  ## This is the whole safety argument for substituting a compiled binary, and
  ## it is deliberately a separate, callable step rather than a few lines
  ## inside the network path: what makes a restore safe is not that the fetch
  ## succeeded, it is that the restored pair passes exactly the check a fresh
  ## compile's pair passes. On a refusal nothing is left behind — a
  ## half-installed provider is indistinguishable from a compiled one to
  ## everything downstream.
  if not installProviderCompilePrefix(plan, artifactPath, extractDir):
    discardRestoredProviderCompile(plan, artifactPath)
    return ProviderCompileConsistency(fresh: false,
      detail: "the cache entry did not carry both a provider binary and a " &
        "compile artifact")
  result = providerCompileConsistencyAfterExecution(plan, artifactPath)
  if not result.fresh:
    discardRestoredProviderCompile(plan, artifactPath)

proc trySubstituteProviderCompile*(plan: ProviderCompilePlan;
                                   projectName, artifactPath,
                                   scratchRoot: string;
                                   cfg: ProviderCompileCacheConfig):
    ProviderCompileSubstituteAttempt =
  ## Serve one provider compile from the binary cache. Never raises: a cache
  ## problem must degrade to a compile, not abort a build.
  if not cfg.configured:
    result.reason = "no trusted binary cache configured"
    return
  let entryHex = providerCompileEntryKeyHex(plan, projectName, scratchRoot)
  result.entryKeyHex = entryHex
  let store = scratchRoot / "provider-compile-cache" / "store"
  let extractDir = scratchRoot / "provider-compile-cache" / "extract"
  try:
    createDir(extendedPath(store))
    let res = substituteInProcess(entryHex, store, cfg.endpoints)
    if not res.ok or res.outcomes.len == 0:
      result.reason = "cache miss" &
        (if res.reason.len > 0: ": " & res.reason else: "")
      return
    let root = res.outcomes[^1]
    if root.casPath.len == 0 or not fileExists(root.casPath):
      result.reason = "cache entry carried no payload"
      return
    let archiveText = readFile(root.casPath)
    var archiveBytes = newSeq[byte](archiveText.len)
    for i, ch in archiveText:
      archiveBytes[i] = byte(ch)
    removeDir(extendedPath(extractDir))
    extractPrefix(archiveBytes, extractDir)
    # THE gate. A restored pair is accepted only if it passes the same
    # post-execution consistency check a freshly compiled pair does.
    let verdict = acceptRestoredProviderCompilePrefix(plan, artifactPath,
      extractDir)
    if not verdict.fresh:
      result.reason = "restored entry rejected, so the compile runs " &
        "instead:\n" & verdict.detail
      return
    result.hit = true
    result.bytesFetched = root.bytesFetched
  except CatchableError as err:
    discardRestoredProviderCompile(plan, artifactPath)
    result.hit = false
    result.reason = "substitute error: " & err.msg
  finally:
    try: removeDir(extendedPath(extractDir))
    except CatchableError: discard
    try: removeDir(extendedPath(store))
    except CatchableError: discard

proc publishProviderCompile*(plan: ProviderCompilePlan;
                             projectName, artifactPath, scratchRoot: string;
                             cfg: ProviderCompileCacheConfig):
    ProviderCompilePublishAttempt =
  ## Publish a provider compile's outputs under the key
  ## ``trySubstituteProviderCompile`` reads. Best-effort: a failure is
  ## reported and never aborts the build the compile already served.
  if not cfg.configured:
    result.reason = "no trusted binary cache configured"
    return
  if not cfg.keypairOk:
    result.reason = "no publisher keypair (" &
      "REPRO_BINARY_CACHE_KEY_PATH / REPRO_BINARY_CACHE_CERT_PATH)"
    return
  # Refuse to publish anything this host would itself refuse to accept. The
  # published bytes are a claim about the inputs in the entry key; making that
  # claim about a pair we have not verified is how a stale binary escapes.
  let verdict = providerCompileConsistencyAfterExecution(plan, artifactPath)
  if not verdict.fresh:
    result.reason = "refusing to publish an artifact that does not pass the " &
      "provider-compile consistency check:\n" & verdict.detail
    return
  let stageDir = scratchRoot / "provider-compile-cache" / "publish-stage"
  try:
    if not stageProviderCompilePrefix(plan, artifactPath, stageDir):
      result.reason = "provider binary or compile artifact missing on disk"
      return
    let identity = providerCompileCacheIdentity(plan, projectName, scratchRoot)
    let entryHex = deriveCacheEntryKeyHex(identity)
    result.entryKeyHex = entryHex
    let keypair = peerAuth.loadOrGenerateKeypair(cfg.certPath, cfg.keyPath)
    let pubRes = publishInProcess(PublishInProcessRequest(
      entryKeyHex: entryHex,
      prefixDir: stageDir,
      identity: identity,
      endpoint: cfg.publishEndpoint,
      keypair: keypair))
    result.ok = pubRes.ok
    result.bytesUploaded = pubRes.bytesUploaded
    if not pubRes.ok:
      result.reason = "publish failed (status " & $pubRes.statusCode & "): " &
        pubRes.error
  except CatchableError as err:
    result.ok = false
    result.reason = "publish error: " & err.msg
  finally:
    try: removeDir(extendedPath(stageDir))
    except CatchableError: discard

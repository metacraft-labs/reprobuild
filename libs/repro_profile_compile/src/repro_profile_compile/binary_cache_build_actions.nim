## Windows-Runner-Binary-Cache-Deploy M4 — apply-time binary-cache
## substitute for `repro infra apply`'s build-action edges.
##
## M3b did the client-seed analog (substitute-first / build-from-source
## on miss) for the Windows client bootstrap. M4 is the apply-time
## analog: when `repro infra apply` (or `repro deploy-agent`, which runs
## the same apply) runs a profile that carries build-action edges
## (extract this zip, run this config script, ...), and a binary cache is
## configured, the apply PREFERS fetching each edge's OUTPUTS from the
## cache (`bakBinaryCacheSubstitute`) instead of building them locally.
## On a cache MISS (or when no cache is configured) it falls back to the
## existing local build.
##
## Trust (Reprobuild-Binary-Cache-Fleet R1; Binary-Caches.md "Apply-time
## substitution and publishing"). The configuration is the shared
## `caches_config.resolveTrustedCacheConfig`, the same one the
## provider-compile cache and `repro cache substitute` use:
##
##   * Substitution reads the caches in `caches.conf`
##     (`/etc/repro/caches.conf`, then the per-user file, or only
##     `REPRO_CACHES_CONFIG`), plus the back-compat `REPRO_BINARY_CACHE_URL`
##     cache. Every endpoint enforces its `trusted-public-keys`: an entry
##     signed by any other key is a MISS, and a cache with no trusted key
##     is never substituted from. This path once built its endpoint by hand
##     with an empty signer list and no trust enforcement, which accepted an
##     entry signed by whatever key the manifest itself carried.
##   * Publish-on-miss happens only on a host the operator made a
##     publisher, by pointing `REPRO_BINARY_CACHE_KEY_PATH` and
##     `REPRO_BINARY_CACHE_CERT_PATH` at an existing keypair. A host that
##     was not given a key never generates one and never publishes. This
##     path once auto-generated a producer key and published every local
##     build, which made every applying host a publisher.
##
## Off-by-default: with no cache configured the dispatcher takes the
## unchanged local-build path.
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

import std/[os, sets, strutils]
when defined(posix):
  import std/posix
  # std/posix does not export these on every target; take them from libc.
  var oNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  var oCloExec {.importc: "O_CLOEXEC", header: "<fcntl.h>".}: cint

import repro_binary_cache_client
import repro_build_engine
import repro_hash

import repro_profile

import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

type
  BuildActionCacheConfig* = TrustedCacheConfig
    ## Resolved binary-cache configuration for the action-edge half of an
    ## apply. `configured = false` turns the whole M4 path off: the
    ## dispatcher builds locally, exactly as before. `keypairOk` gates
    ## publish-on-miss and is true only for an operator-supplied keypair.

  SubstituteAttempt* = object
    ## Result of one `trySubstituteBuildAction` call.
    hit*: bool            ## true when the outputs were served from cache
    reason*: string       ## populated on a miss / error (diagnostic)
    bytesFetched*: int64

proc resolveBuildActionCacheConfig*(): BuildActionCacheConfig =
  ## Resolve substitution trust and publish credentials once per dispatch.
  ## See the module header: endpoints come from `caches.conf` with their
  ## trust anchors enforced, and a publish keypair is never generated.
  resolveTrustedCacheConfig()

proc shouldPublishBuildActionOutputs*(cfg: BuildActionCacheConfig): bool =
  ## Whether a freshly built edge's outputs are published back. Only a host
  ## configured as a publisher (cache configured AND an operator-supplied
  ## keypair present) publishes; every other host is a pure consumer.
  cfg.configured and cfg.keypairOk and cfg.publishEndpoint.len > 0

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
  ## paths. An absolute output under `cwd` is made relative; a relative one
  ## is normalised (`./out.bin` is `out.bin`, `a/../b` is `b`); the working
  ## directory itself (`.`, or an absolute path equal to `cwd`) becomes the
  ## empty string, the prefix below which every member lies. An output that
  ## resolves outside `cwd` is skipped, as before: the caller treats an empty
  ## set as "not substitutable".
  ##
  ## Normalising matters because the substitute copy compares archive
  ## members against these paths; `./out.bin` spelled in a profile is the
  ## same output as `out.bin`, and treating it as a different string refused
  ## a substitutable edge.
  let cwdAbs = (if action.cwd.len > 0: absolutePath(action.cwd)
                else: getCurrentDir())
  for o in action.outputs:
    var rel = o
    if isAbsolute(o):
      let oAbs = absolutePath(o)
      if oAbs.startsWith(cwdAbs & $DirSep) or oAbs == cwdAbs:
        rel = relativePath(oAbs, cwdAbs)
      else:
        continue
    rel = normalizedPath(rel).replace(DirSep, '/')
    if rel == "." or rel == "":
      rel = ""
    elif rel == ".." or rel.startsWith("../"):
      continue
    result.add(rel.strip(leading = false, chars = {'/'}))

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

proc isDeclaredOutput(rel: string; declared: openArray[string];
                      archiveDirs: HashSet[string]): bool =
  ## True when the cwd-relative `rel` IS a declared output, or lies below a
  ## declared output that the archive itself carries as a directory entry
  ## (`archiveDirs`). Compared component-wise, so `bin2/x` is not below a
  ## declared `bin`; an empty declared path is the working directory and
  ## admits every member.
  ##
  ## The directory-entry requirement is what keeps a declared *file* output
  ## a file: the publisher packs a declared output directory with an explicit
  ## directory entry, so an archive whose only trace of `out.bin` is a member
  ## `out.bin/x` did not come from an action whose `out.bin` was a directory,
  ## and must not turn the declared file into one.
  for d in declared:
    if d.len == 0 or rel == d:
      return true
    if rel.startsWith(d & "/") and d in archiveDirs:
      return true
  false

proc writeFileNoFollow(dstDir, name: string; data: string; mode: set[FilePermission]) =
  ## Write `data` to `dstDir/name` without ever following a symbolic link:
  ## the bytes go to a fresh temporary file created with
  ## `O_CREAT|O_EXCL|O_NOFOLLOW` in the same directory, which is then renamed
  ## over the destination. `rename(2)` replaces a link at the destination
  ## rather than writing through it.
  let final = dstDir / name
  let tmp = dstDir / ("." & name & ".repro-substitute-" & $getCurrentProcessId())
  when defined(posix):
    # O_EXCL|O_NOFOLLOW: a planted link or file at the staging name makes
    # the open fail (nothing is followed, nothing removed), and the
    # substitution is refused.
    let fd = posix.open(tmp.cstring,
      O_WRONLY or O_CREAT or O_EXCL or oNoFollow or oCloExec, 0o600.Mode)
    if fd < 0:
      raiseOSError(osLastError(), "cannot create " & tmp)
  else:
    writeFile(tmp, data)
  # From here on the staging file is ours: every failure removes it.
  try:
    when defined(posix):
      var off = 0
      try:
        while off < data.len:
          let n = posix.write(fd, unsafeAddr data[off], data.len - off)
          if n < 0:
            raiseOSError(osLastError(), "cannot write " & tmp)
          off += n
      finally:
        discard posix.close(fd)
    setFilePermissions(tmp, mode)
    moveFile(tmp, final)
  except CatchableError:
    try: removeFile(tmp) except CatchableError: discard
    raise

proc materialisePrefixIntoCwd*(action: ProfileBuildAction;
                               extractedDir: string;
                               entries: openArray[ExtractedEntry]) =
  ## Copy the action's DECLARED outputs from `extractedDir` (a freshly
  ## extracted rbcarc prefix) back under the action's `cwd`, byte-identically,
  ## preserving permissions (so the exec bit the archive carried survives).
  ##
  ## The archive comes from a cache, so it is treated as hostile even after
  ## its signature checked out, and the copy runs inside a privileged apply:
  ##
  ##   * Only declared outputs are copied. A file the action did not declare
  ##     (`.git/hooks/post-checkout`, a shell profile) refuses the whole
  ##     substitution rather than landing in the working directory.
  ##   * The archive may carry no symbolic link. The publisher stages outputs
  ##     with `copyFileWithPermissions`, which dereferences links, so an honest
  ##     outputs archive holds regular files only; a link would make this copy
  ##     read whatever it points at (a secret) into the outputs.
  ##   * The destination is written without following links: no existing
  ##     component of the destination path may be a link, and each file is
  ##     created fresh and renamed into place.
  ##
  ## Any refusal raises `IOError`; the caller turns it into a cache miss and
  ## builds locally. Validation of every member happens before anything is
  ## written, so a refused archive writes nothing.
  let cwdAbs = (if action.cwd.len > 0: absolutePath(action.cwd)
                else: getCurrentDir())
  let declared = outputRelPaths(action)
  var archiveDirs = initHashSet[string]()
  for e in entries:
    if e.kind == aekDirectory:
      archiveDirs.incl(e.path)
  var members: seq[string] = @[]
  for path in walkDirRec(extractedDir,
                         yieldFilter = {pcFile, pcLinkToFile, pcLinkToDir},
                         followFilter = {pcDir}, relative = true):
    let rel = path.replace(DirSep, '/')
    let src = extractedDir / path
    if symlinkExists(src):
      raise newException(IOError,
        "substituted outputs carry a symbolic link (" & rel &
        "); an outputs archive holds regular files only")
    if not isDeclaredOutput(rel, declared, archiveDirs):
      raise newException(IOError,
        "substituted outputs carry " & rel &
        ", which the action does not declare as an output")
    members.add(rel)
  for rel in members:
    refuseWriteThroughSymlink(cwdAbs, rel)
  for rel in members:
    let dst = cwdAbs / rel
    createDir(parentDir(dst))
    refuseWriteThroughSymlink(cwdAbs, rel)
    writeFileNoFollow(parentDir(dst), extractFilename(dst),
                      readFile(extractedDir / rel),
                      getFilePermissions(extractedDir / rel))

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
    # The configured endpoints, NOT one built here: each carries its
    # `caches.conf` trust anchors with `enforceTrust` set, so an entry
    # signed by an unanchored key (or served by a cache with no anchors)
    # is rejected before any payload byte is fetched and reads as a miss.
    let res = substituteInProcess(entryHex, store, cfg.endpoints)
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
    let entries = extractPrefix(archiveBytes, extractDir)
    materialisePrefixIntoCwd(action, extractDir, entries)
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
  ## MUST NOT abort the apply — the box already converged locally. A host
  ## that is not configured as a publisher (no operator-supplied keypair,
  ## see `shouldPublishBuildActionOutputs`) publishes nothing, and no key
  ## is ever generated here.
  if not shouldPublishBuildActionOutputs(cfg):
    return (ok: false,
            reason: "publish skipped: this host is not configured as a " &
              "cache publisher (REPRO_BINARY_CACHE_KEY_PATH / " &
              "REPRO_BINARY_CACHE_CERT_PATH)")
  let stageDir = scratchRoot / "publish-stage"
  try:
    removeDir(stageDir)
    if not stagePrefixFromOutputs(action, stageDir):
      return (ok: false,
              reason: "no publishable outputs staged for " & action.id)
    let idy = buildActionCacheIdentity(action, scratchRoot)
    let entryHex = deriveCacheEntryKeyHex(idy)
    # `loadOrGenerateKeypair` GENERATES when a file is missing. The resolver
    # saw both files, but re-check here so a key removed since then is a
    # skipped publish rather than a freshly minted producer identity.
    if not (fileExists(cfg.keyPath) and fileExists(cfg.certPath)):
      return (ok: false,
              reason: "publish skipped: the configured publisher keypair " &
                "is no longer present")
    let keypair = peerAuth.loadOrGenerateKeypair(cfg.certPath, cfg.keyPath)
    let pubReq = PublishInProcessRequest(
      entryKeyHex: entryHex,
      prefixDir: stageDir,
      identity: idy,
      endpoint: cfg.publishEndpoint,
      keypair: keypair)
    let pubRes = publishInProcess(pubReq)
    if pubRes.ok:
      return (ok: true, reason: "")
    return (ok: false, reason: "publish failed: " & pubRes.error)
  except CatchableError as e:
    return (ok: false, reason: "publish error for " & action.id & ": " & e.msg)
  finally:
    try: removeDir(stageDir) except CatchableError: discard

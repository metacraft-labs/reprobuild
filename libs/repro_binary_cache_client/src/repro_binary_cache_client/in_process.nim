## ReproOS-Generations-And-Foreign-Packages A2.5 — single-user wrapper.
##
## Per the spec § Multi-user vs single-user mode: when a build tool
## opts out of the daemon (CI runners, container builds), it calls
## ``substituteInProcess`` directly. The wrapper builds a per-call
## ``ClientContext`` + ``HttpPool`` + ``ClientIndex``, walks the
## closure, and tears them down. No IPC, no daemon, same code path.
##
## Trades pool reuse + cache-info warm-cache for zero daemon
## management overhead. Appropriate when:
##
##   * One-shot CI runs (each job spawns a fresh ``repro build``).
##   * Container builds (the daemon would never amortise its
##     cost across builds).
##   * Test fixtures (the tests themselves run in this mode).
##
## M9.L.4-refactor Step A: ``publishInProcess`` lifts the publish
## pipeline (pack prefix → BLAKE3 → build + sign manifest → multipart
## POST) out of ``apps/repro-binary-cache-client/`` so the engine's
## new ``binaryCachePublisher`` closure can call it directly without
## shelling out to the CLI. The CLI's ``cmdPublish`` is refactored to
## a thin wrapper that builds a ``PublishInProcessRequest`` from CLI
## flags and forwards.

import std/[algorithm, httpclient, httpcore, os, random, strutils, times]

import blake3

import ./types
import ./http_pool
import ./scheduler_executor
import ./closure_walk
import ./index
import ./cache_key

import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes
import ../../../repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec as serverCodec
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

export peerAuth.PeerKeypair

type
  InProcessOutcome* = object
    plan*: seq[SubstitutePlan]
    outcomes*: seq[SubstituteOutcome]
    ok*: bool
    reason*: string

  PublishInProcessRequest* = object
    ## M9.L.4-refactor Step A. Self-contained request carrying every
    ## byte the publish pipeline needs. Mirrors the CLI's flag set so
    ## a CLI caller can build one from its parsed args without any
    ## drift.
    ##
    ## Fields:
    ##   * ``entryKeyHex`` — 64-char lowercase hex; the caller-asserted
    ##     entry key. The publisher re-derives the key from
    ##     ``identity`` and HARD-FAILS if they disagree (drift guard
    ##     ported from ``cmdPublish``).
    ##   * ``prefixDir`` — absolute path to the staging tree to pack.
    ##     The publisher tolerates a single-file prefix (the v1 CLI
    ##     also does) by wrapping it into a one-entry archive.
    ##   * ``identity`` — full ``CacheEntryIdentity`` used both for
    ##     the drift-guard re-derivation and to sign the manifest.
    ##     Callers MUST populate every field they want reflected in
    ##     the entry key; missing fields produce a DIFFERENT key
    ##     (intentional — the canonical encoder is injective).
    ##   * ``endpoint`` — base URL like ``http://localhost:7878``.
    ##     The publisher appends ``/publish`` to this.
    ##   * ``keypair`` — ECDSA-P256 signing key + matching pubkey, in
    ##     the shape the ``repro_peer_cache.auth`` module supplies.
    ##     Required; the publisher refuses to run without one.
    entryKeyHex*: string
    prefixDir*: string
    identity*: CacheEntryIdentity
    endpoint*: string
    keypair*: peerAuth.PeerKeypair

  PublishInProcessResult* = object
    ## Outcome of a single ``publishInProcess`` call.
    ##   * ``ok``  — true iff the server responded 2xx.
    ##   * ``statusCode`` — HTTP status from ``/publish``; ``0`` when
    ##     the call short-circuited before issuing the request
    ##     (e.g. drift-guard failed).
    ##   * ``error`` — populated on ``!ok`` with the diagnostic.
    ##     Empty on success.
    ##   * ``bytesUploaded`` — wire-bytes of the multipart body
    ##     uploaded (manifest + payload + framing); 0 on early
    ##     short-circuit.
    ##   * ``responseBody`` — server-side echo (the published
    ##     entry-key hex on success). Kept so CLI callers can keep
    ##     printing the same diagnostic line.
    ok*: bool
    statusCode*: int
    error*: string
    bytesUploaded*: int
    responseBody*: string

const
  ArchiveMagic = "RBCA"
  ArchiveVersion = 1'u32

# ---------------------------------------------------------------------------
# Archive writer (mirror of the CLI's deterministic ``rbcarc-v1`` writer).
#
# Kept in the library so engine-side callers don't pay the cost of
# shelling out to the CLI; the CLI's local copy delegates here.
# ---------------------------------------------------------------------------

proc writeU32LE(buf: var seq[byte]; v: uint32) =
  for shift in countup(0, 24, 8):
    buf.add(byte((v shr uint32(shift)) and 0xff'u32))

proc writeU64LE(buf: var seq[byte]; v: uint64) =
  for shift in countup(0, 56, 8):
    buf.add(byte((v shr uint64(shift)) and 0xff'u64))

proc normaliseSep(p: string): string =
  result = p.replace('\\', '/')

proc walkPrefix(prefix: string): seq[string] =
  let prefixAbs = absolutePath(prefix)
  for path in walkDirRec(prefixAbs, yieldFilter = {pcFile, pcLinkToFile},
                         relative = true):
    result.add(normaliseSep(path))
  result.sort(cmp)

proc fileModeOctal*(path: string): uint32 =
  ## Returns 0o755 if the file is executable, 0o644 otherwise. Public
  ## so the CLI's tests can re-use it via the re-exported in_process
  ## module surface.
  when defined(windows):
    let lower = path.toLowerAscii()
    if lower.endsWith(".exe") or lower.endsWith(".com") or
       lower.endsWith(".bat") or lower.endsWith(".ps1") or
       lower.endsWith(".sh"):
      return 0o755'u32
    return 0o644'u32
  else:
    let info = getFileInfo(path)
    if (info.permissions * {fpUserExec, fpGroupExec, fpOthersExec}).len > 0:
      return 0o755'u32
    return 0o644'u32

proc packPrefix*(prefix: string): seq[byte] =
  ## Builds the deterministic archive bytes for the prefix tree. Same
  ## ``rbcarc-v1`` layout the CLI documents at the top of
  ## ``repro_binary_cache_client_cli.nim``.
  let entries = walkPrefix(prefix)
  result = newSeqOfCap[byte](4096)
  for ch in ArchiveMagic:
    result.add(byte(ch))
  writeU32LE(result, ArchiveVersion)
  writeU32LE(result, uint32(entries.len))
  for rel in entries:
    let absPath = prefix / rel
    let mode = fileModeOctal(absPath)
    let pathBytes = rel
    let payload = readFile(absPath)
    writeU32LE(result, uint32(pathBytes.len))
    for ch in pathBytes:
      result.add(byte(ch))
    writeU32LE(result, mode)
    writeU64LE(result, uint64(payload.len))
    for ch in payload:
      result.add(byte(ch))

proc packSingleFilePrefix*(prefixPath: string): seq[byte] =
  ## Wraps a single-file prefix into a one-entry archive so the
  ## substitute path can extract uniformly. Mirrors the
  ## ``not dirExists`` branch in ``cmdPublish``.
  var pref = absolutePath(prefixPath)
  let name = extractFilename(pref)
  result = @[]
  for ch in ArchiveMagic:
    result.add(byte(ch))
  writeU32LE(result, ArchiveVersion)
  writeU32LE(result, 1'u32)
  writeU32LE(result, uint32(name.len))
  for ch in name: result.add(byte(ch))
  writeU32LE(result, fileModeOctal(pref))
  let body = readFile(pref)
  writeU64LE(result, uint64(body.len))
  for ch in body: result.add(byte(ch))

# ---------------------------------------------------------------------------
# Multipart body builder.
# ---------------------------------------------------------------------------

proc buildMultipartBody*(boundary: string;
                         manifestBytes: openArray[byte];
                         payload: openArray[byte]): string =
  result = ""
  result.add("--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"manifest\"\r\n\r\n")
  for b in manifestBytes:
    result.add(char(b))
  result.add("\r\n")
  result.add("--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"payload\"\r\n\r\n")
  for b in payload:
    result.add(char(b))
  result.add("\r\n")
  result.add("--" & boundary & "--\r\n")

# ---------------------------------------------------------------------------
# substituteInProcess.
# ---------------------------------------------------------------------------

proc substituteInProcess*(rootEntryKeyHex: string;
                          storeRoot: string;
                          endpoints: seq[SubstituteEndpoint]):
                            InProcessOutcome =
  ## Walk + materialise a closure rooted at ``rootEntryKeyHex`` via
  ## the first endpoint that successfully returns the root manifest.
  ## On any endpoint failure the wrapper records the reason and tries
  ## the next configured endpoint.
  result.ok = false
  if endpoints.len == 0:
    result.reason = "no substitute endpoints configured"
    return

  let cfg = defaultConfig(storeRoot, endpoints)
  let ctx = newClientContext(cfg)
  defer: ctx.close()
  let pool = newHttpPool(maxConnections = cfg.maxConnectionsPerHost * endpoints.len)
  defer: pool.close()
  let idx = openClientIndex(storeRoot)

  for endpoint in endpoints:
    try:
      let plan = planClosure(ctx, pool, endpoint, rootEntryKeyHex)
      var allOk = true
      var outcomes: seq[SubstituteOutcome] = @[]
      for step in plan:
        let req = SubstituteRequest(
          entryKeyHex: step.entryKeyHex,
          endpoint: endpoint)
        let outcome = executeSubstituteAction(ctx, pool, req, idx)
        outcomes.add(outcome)
        if not outcome.ok:
          allOk = false
          break
      if allOk:
        result.ok = true
        result.plan = plan
        result.outcomes = outcomes
        try: idx.flush() except CatchableError: discard
        return
      else:
        result.outcomes = outcomes
        result.reason = "one or more substitutes failed on " & endpoint.baseUrl
    except CatchableError as e:
      result.reason = "endpoint " & endpoint.baseUrl & ": " & e.msg
      continue
  # Fall-through: every endpoint failed.
  if result.reason.len == 0:
    result.reason = "no endpoint produced a usable manifest"

# ---------------------------------------------------------------------------
# publishInProcess.
# ---------------------------------------------------------------------------

proc publishInProcess*(req: PublishInProcessRequest): PublishInProcessResult =
  ## M9.L.4-refactor Step A. Lifts the body of
  ## ``cmdPublish`` (apps/repro-binary-cache-client/repro_binary_cache_
  ## client_cli.nim §cmdPublish 461-543) into the library so the
  ## engine's ``binaryCachePublisher`` closure can call it directly.
  ##
  ## Pipeline:
  ##
  ##   1. Drift-guard: derive the entry key from ``identity`` and
  ##      compare against ``entryKeyHex``; hard-fail on mismatch.
  ##      Without this gate, a stale baked-in hex on the caller side
  ##      would silently publish under the wrong key.
  ##   2. Pack the prefix (directory → ``rbcarc-v1`` archive; single
  ##      file → one-entry archive). Determinism mirrors the CLI's
  ##      ``packPrefix``.
  ##   3. BLAKE3-256 the archive bytes; populate the ``PayloadObject``
  ##      descriptor + ``realizedPrefixDigest`` (placeholder == payload
  ##      digest for v1).
  ##   4. Build + sign the ``BinaryCacheManifest`` (key, payloads,
  ##      depReferences, relocationPolicy=optional, createdAtUnix).
  ##   5. POST the manifest + payload as multipart/form-data to
  ##      ``<endpoint>/publish``.
  ##
  ## Soft-fail semantics: every error populates ``result.error`` and
  ## leaves ``result.ok == false``. The caller decides whether a
  ## publish failure aborts its workflow (the CLI: yes; the engine
  ## hook: no, per spec).
  result.ok = false

  # Drift-guard: confirm the supplied hex matches the identity-derived
  # hex BEFORE we touch the network. Without this check, a stale baked-
  # in hex would silently publish under the wrong key.
  let derivedKey = deriveCacheEntryKey(req.identity)
  let derivedHex = cacheEntryKeyHex(derivedKey)
  if derivedHex != req.entryKeyHex:
    result.error = "publish: identity-derived key does not match " &
      "supplied entry-key hex.\n" &
      "  supplied:  " & req.entryKeyHex & "\n" &
      "  derived:   " & derivedHex
    return

  # Prefix path must exist.
  if not dirExists(req.prefixDir) and not fileExists(req.prefixDir):
    result.error = "publish: prefix path does not exist: " & req.prefixDir
    return

  # Pack the prefix into the deterministic archive bytes.
  let payloadBytes =
    if dirExists(req.prefixDir): packPrefix(req.prefixDir)
    else: packSingleFilePrefix(req.prefixDir)

  # Hash the payload bytes (the digest the manifest must declare).
  let rawDigest = blake3.digest(payloadBytes)
  var payloadDigest: bcsTypes.Blake3Hash
  for i in 0 ..< 32:
    payloadDigest[i] = rawDigest[i]
  # Realized prefix digest: re-use the payload hash as v1 placeholder.
  var realizedDigest: bcsTypes.Blake3Hash = payloadDigest

  # Build dep-references (32-byte digests) from the identity's
  # dep-closure list. The closure is already lowercased + validated by
  # ``addDep`` so we just hex-decode each entry.
  var depRefs: seq[bcsTypes.Blake3Hash] = @[]
  for depHex in req.identity.depClosure:
    depRefs.add(hexToDigest(depHex))

  let payloadObj = bcsTypes.PayloadObject(
    kind: bcsTypes.pkPrefixArchive,
    compression: bcsTypes.ckNone,
    declaredSize: uint64(payloadBytes.len),
    uncompressedSize: uint64(payloadBytes.len),
    digest: payloadDigest,
    name: "prefix.rbcarc")
  var manifest = bcsTypes.BinaryCacheManifest(
    formatVersion: bcsTypes.BinaryCacheFormatVersion,
    entryKey: derivedKey,
    payloads: @[payloadObj],
    realizedPrefixDigest: realizedDigest,
    depReferences: depRefs,
    relocationPolicy: bcsTypes.rpOptional,
    createdAtUnix: getTime().toUnix())
  serverCodec.signManifest(req.keypair, manifest)
  let manifestBytes = serverCodec.encodeManifest(manifest)

  randomize()
  let boundary = "----RBC-cli-" & $rand(99_999_999)
  let body = buildMultipartBody(boundary, manifestBytes, payloadBytes)
  let baseUrl =
    if req.endpoint.len > 0: req.endpoint
    else: "http://localhost:7878"
  let url = baseUrl & "/publish"
  let client = newHttpClient(timeout = 60_000)
  defer: client.close()
  client.headers["Content-Type"] = "multipart/form-data; boundary=" & boundary
  result.bytesUploaded = body.len
  try:
    let resp = client.request(url, HttpPost, body)
    result.statusCode = int(resp.code)
    result.responseBody = resp.body
    if result.statusCode >= 300:
      result.error = "publish failed: HTTP " & $resp.code & " " & resp.body
      return
    result.ok = true
  except CatchableError as e:
    result.error = "publish failed: " & e.msg

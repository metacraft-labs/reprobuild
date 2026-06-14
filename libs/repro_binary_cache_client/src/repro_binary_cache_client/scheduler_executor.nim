## ReproOS-Generations-And-Foreign-Packages A2.5 — engine dispatcher.
##
## Glue between the build engine's ``bakBinaryCacheSubstitute`` action
## kind and the streaming payload sink. The engine calls
## ``executeSubstituteAction`` once per substitute action it dispatches;
## this proc:
##
##   1. Decodes the action's payload — the entry-key hex + the chosen
##      endpoint.
##   2. Fetches + verifies the manifest (or hits the manifest cache).
##   3. Walks the manifest's payload list; for each payload, calls
##      ``fetchPayloadStreaming``.
##   4. Updates the client-side index sidecar with the resulting
##      ``IndexEntry``.
##
## The engine's existing pool-capacity + dep-tracking semantics
## handle parallelism across multiple substitute actions; we don't
## introduce a second scheduler here.
##
## ## Action payload encoding
##
## ``bakBinaryCacheSubstitute`` reuses the existing
## ``BuildAction.builtinText`` slot to carry the action payload:
##
##   <entry-key-hex>\n
##   <endpoint-base-url>\n
##   <expected-realized-path>\n        (optional; informational)
##
## The trust+endpoint config is global to the ``ClientContext`` so
## per-action wiring stays minimal.

import std/[os, strutils, times]

import repro_local_store

import ./types
import ./http_pool
import ./payload_sink
import ./closure_walk
import ./compat_check
import ./index
import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes
import ../../../repro_binary_cache_server/src/repro_binary_cache_server/key as bcsKey

type
  SubstituteOutcome* = object
    ok*: bool
    reason*: string
    casPath*: string
    bytesFetched*: int64
    wallclockMillis*: int64
    skipped*: bool          ## True when entry was already present.

  SubstituteRequest* = object
    entryKeyHex*: string
    endpoint*: SubstituteEndpoint

proc parseActionPayload*(text: string): SubstituteRequest =
  let lines = text.splitLines()
  if lines.len < 2:
    raise newException(ClientError,
      "bakBinaryCacheSubstitute action payload requires entry-key + " &
      "endpoint URL lines (got " & $lines.len & ")")
  result.entryKeyHex = lines[0].strip()
  result.endpoint = SubstituteEndpoint(
    baseUrl: lines[1].strip(),
    trustedSigners: @[],
    priority: 0)

proc executeSubstituteAction*(ctx: ClientContext;
                              pool: HttpPool;
                              request: SubstituteRequest;
                              clientIdx: ClientIndex): SubstituteOutcome =
  let startMs = epochTime() * 1000.0
  result.ok = false
  result.skipped = false

  # Hot path: already substituted previously.
  let existing = clientIdx.lookup(request.entryKeyHex)
  if existing.found:
    let casPath = ctx.store.casPath(existing.entry.payloadHash)
    if fileExists(casPath):
      result.ok = true
      result.skipped = true
      result.casPath = casPath
      result.wallclockMillis = int64(epochTime() * 1000.0 - startMs)
      return

  # Fetch + verify manifest.
  let manifest =
    try:
      fetchAndVerifyManifest(ctx, pool, request.endpoint, request.entryKeyHex)
    except ClosureWalkError as e:
      result.reason = "manifest fetch failed: " & e.msg
      result.wallclockMillis = int64(epochTime() * 1000.0 - startMs)
      return

  # Compat check.
  let local = detectLocalPlatform(ctx.config.storeRoot)
  let (compatOk, compatReason) =
    checkCompat(manifest, local, request.endpoint.trustedSigners)
  if not compatOk:
    result.reason = "compat rejected: " & compatReason
    result.wallclockMillis = int64(epochTime() * 1000.0 - startMs)
    return

  if manifest.payloads.len == 0:
    result.reason = "manifest has no payloads"
    result.wallclockMillis = int64(epochTime() * 1000.0 - startMs)
    return

  # v1 materialises the FIRST payload (the prefix archive). Manifests
  # with multiple payloads (a prefix archive + a launcher, say)
  # iterate here.
  var lastCasPath = ""
  var totalBytes = 0'i64
  for payload in manifest.payloads:
    let sinkRes =
      try:
        fetchPayloadStreaming(ctx, pool, request.endpoint, payload)
      except CatchableError as e:
        result.reason = "payload " & bcsTypes.payloadDigestHex(payload) &
          " fetch failed: " & e.msg
        result.wallclockMillis = int64(epochTime() * 1000.0 - startMs)
        return
    lastCasPath = sinkRes.casPath
    totalBytes += sinkRes.bytesIn

  # Update the client index.
  let firstPayload = manifest.payloads[0]
  clientIdx.upsert(IndexEntry(
    entryKeyHex: request.entryKeyHex,
    manifestHash: bcsKey.cacheEntryKeyDigest(manifest.entryKey),
    payloadHash: firstPayload.digest,
    realizedPrefixPath: lastCasPath,
    createdAtUnix: getTime().toUnix(),
    sourceEndpoint: request.endpoint.baseUrl))
  try: clientIdx.flush() except CatchableError: discard

  result.ok = true
  result.casPath = lastCasPath
  result.bytesFetched = totalBytes
  result.wallclockMillis = int64(epochTime() * 1000.0 - startMs)

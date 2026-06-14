## ReproOS-Generations-And-Foreign-Packages A2.5 — closure walk.
##
## From a single manifest's ``depReferences`` we recursively enqueue
## substitute requests for the closure. The build engine's existing
## topological-sort + pool-capacity handles parallelism — we just
## walk the dep graph and emit ``substitute(K)`` requests in dep
## order.
##
## ## Algorithm
##
## 1. Push the root entry-key on the work queue.
## 2. Pop entry-key K.
## 3. If K is already in the local CAS index → emit no-op.
## 4. Else fetch K's manifest, decode + verify.
## 5. For each ``dep`` in the manifest's ``depReferences`` →
##    push the dep onto the queue (skip if visited).
## 6. Record (K, manifest) in the visit set.
## 7. After the BFS completes, return the topologically-sorted plan:
##    leaves first.
##
## The plan is a ``seq[SubstitutePlan]`` the scheduler-executor
## consumes; each element is one ``bakBinaryCacheSubstitute`` action.
##
## ## Why BFS, not DFS?
##
## BFS over the manifest dep refs lets the closure walker overlap
## **all** manifest fetches at one level — the work queue keeps the
## HTTP pool saturated with manifest GETs while the per-payload
## sinks consume bandwidth. Nix uses the same shape in its
## substitution-goal.cc.

import std/[strutils, tables]

import ./types
import ./http_pool
import ./manifest_codec
import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes
import ../../../repro_binary_cache_server/src/repro_binary_cache_server/key as bcsKey

type
  SubstitutePlan* = object
    entryKeyHex*: string
    manifest*: BinaryCacheManifest
    sourceEndpoint*: SubstituteEndpoint

  ClosureWalkError* = object of CatchableError

proc hexOfDigest(d: Blake3Hash): string =
  bcsKey.digestToHex(d)

proc fetchManifestRaw(pool: HttpPool;
                      endpoint: SubstituteEndpoint;
                      entryKeyHex: string): seq[byte] =
  let url = endpoint.baseUrl & "/manifests/" & entryKeyHex
  let (statusCode, body) = pool.getEntireBody(url)
  if statusCode != 200:
    raise newException(ClosureWalkError,
      "GET " & url & " failed: HTTP " & $statusCode)
  return body

proc fetchAndVerifyManifest*(ctx: ClientContext;
                             pool: HttpPool;
                             endpoint: SubstituteEndpoint;
                             entryKeyHex: string): BinaryCacheManifest =
  if ctx.manifestCache.hasKey(entryKeyHex):
    return ctx.manifestCache[entryKeyHex]
  let bytes = fetchManifestRaw(pool, endpoint, entryKeyHex)
  let m =
    try:
      manifest_codec.decodeAndVerify(bytes)
    except ClientManifestError as e:
      raise newException(ClosureWalkError,
        "manifest " & entryKeyHex & " from " & endpoint.baseUrl &
        ": " & e.msg)
  ctx.manifestCache[entryKeyHex] = m
  return m

proc planClosure*(ctx: ClientContext;
                  pool: HttpPool;
                  endpoint: SubstituteEndpoint;
                  rootEntryKeyHex: string): seq[SubstitutePlan] =
  ## BFS over manifest dep refs; returns a topologically-sorted plan
  ## (leaves first). Each ``SubstitutePlan`` is one
  ## ``bakBinaryCacheSubstitute`` action the engine schedules.
  var visited = initTable[string, BinaryCacheManifest]()
  var workQueue: seq[string] = @[rootEntryKeyHex]
  var depEdges = initTable[string, seq[string]]()

  while workQueue.len > 0:
    let key = workQueue[0]
    workQueue.delete(0)
    if visited.hasKey(key):
      continue
    let manifest = fetchAndVerifyManifest(ctx, pool, endpoint, key)
    visited[key] = manifest
    var children: seq[string] = @[]
    for depRef in manifest.depReferences:
      let depHex = hexOfDigest(depRef)
      children.add(depHex)
      if not visited.hasKey(depHex):
        workQueue.add(depHex)
    depEdges[key] = children

  # Topological sort: Kahn's algorithm in reverse so dependencies come
  # before dependents. Equivalent to a post-order DFS over depEdges.
  var indegree = initTable[string, int]()
  for key in visited.keys:
    indegree[key] = 0
  for key, children in depEdges:
    for child in children:
      if indegree.hasKey(child):
        indegree[child] = indegree[child] + 1
  # Reverse direction for "deps first": treat each (key -> child) as
  # an edge "child must come before key". So a dep with indegree=0
  # (no parents) becomes the LAST item, and a leaf with no children
  # becomes the FIRST. We invert the typical Kahn shape.
  # Simpler: emit a post-order DFS visit.
  var emitted = initTable[string, bool]()
  var plan: seq[SubstitutePlan] = @[]
  proc visit(key: string) =
    if emitted.getOrDefault(key, false):
      return
    emitted[key] = true
    if depEdges.hasKey(key):
      for child in depEdges[key]:
        if visited.hasKey(child):
          visit(child)
    plan.add(SubstitutePlan(
      entryKeyHex: key,
      manifest: visited[key],
      sourceEndpoint: endpoint))
  visit(rootEntryKeyHex)
  return plan

## A builtin's PEER-CACHE key binds its payload (owner decision 2026-10-31,
## Edge-Derived-Identities.md §10 decision 23 rider: `write-text` and
## `stamp` may cross hosts because what they write is their payload).
##
## Found by the independent verification of campaign M17 chunk 2b. Outside
## portable caching the key LAN peers agreed on was the action's weak
## fingerprint, and a builtin's weak fingerprint covers its payload only
## when its constructor mixed the payload in. The production constructor
## does; `builtinAction` keys on the action id alone unless its caller passes
## more, and the strong fingerprint covers inputs, not the payload. Two
## `write-text` actions with one id and different texts therefore asked for,
## and published under, ONE key with ONE strong fingerprint: a consumer was
## served the other text's output. The key is now `builtinPayloadPeerKey`,
## so the payload is bound whatever the constructor keyed.

import std/[options, os, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_hash
import repro_local_store
from repro_cas_store import CasStore

type Seen = ref object
  published: seq[array[32, byte]]
  asked: seq[array[32, byte]]

proc writeText(work, text: string): BuildAction =
  ## Keyed on its id alone, as `builtinAction` keys when the caller passes no
  ## fingerprint, with one declared input so that only its key decides.
  builtinAction(bakWriteText, "t-peer-key-write-text", cwd = work,
    inputs = [work / "src" / "in.txt"], outputs = [work / "out" / "o.txt"],
    cacheable = true, actionCachePolicy = ffpChecksum, text = text,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc run(work, cacheRoot: string; action: BuildAction; seen: Seen):
    BuildRunResult =
  var config = defaultBuildEngineConfig(cacheRoot)
  config.bypassRunQuota = true
  config.maxParallelism = 1
  config.peerCacheActionPublisher = proc (query: PeerCacheActionQuery;
      record: ActionResultRecord; cas: var CasStore) {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      seen.published.add(query.peerKey)
  config.peerCacheActionFetcher = proc (query: PeerCacheActionQuery):
      Option[seq[byte]] {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      seen.asked.add(query.peerKey)
    none(seq[byte])
  config.peerCacheActionInstaller = proc (query: PeerCacheActionQuery;
      bundle: seq[byte]; cas: var CasStore; cache: ptr ActionCache):
      tuple[ok: bool; reason: string] {.gcsafe, closure.} =
    (false, "not used")
  runBuild(graph([action]), config)

suite "a builtin's peer-cache key binds its payload":
  test "one id, two texts: two keys; the producer's and the consumer's agree":
    let root = createTempDir("t-peer-key-builtin", "")
    defer: removeDir(root)
    let work = root / "w"
    createDir(work / "src")
    writeFile(work / "src" / "in.txt", "same input\n")
    let v1 = writeText(work, "text v1\n")
    let v2 = writeText(work, "text v2\n")
    # The local key is payload-blind, which is what makes this a test of
    # the CROSS-HOST key and not of the constructor.
    require v1.weakFingerprint == v2.weakFingerprint
    let seen = Seen()
    let first = run(work, root / "cache-1", v1, seen)
    require first.results[0].status == asSucceeded
    require seen.published.len == 1
    require seen.asked.len == 1
    # Producer and consumer of one action compute one key.
    check seen.asked[0] == seen.published[0]
    let second = run(work, root / "cache-2", v2, seen)
    require second.results[0].status == asSucceeded
    require seen.published.len == 2
    require seen.asked.len == 2
    check seen.asked[1] == seen.published[1]
    # Another text is another key.
    check seen.published[0] != seen.published[1]
    check seen.asked[0] != seen.asked[1]
    # And neither is the bare weak fingerprint a payload-blind peer would use.
    check seen.published[0] != v1.weakFingerprint.bytes
    check builtinPayloadPeerKey(v1).bytes == seen.published[0]
    check builtinPayloadPeerKey(v2).bytes == seen.published[1]

  test "the key frames every payload field":
    var a = builtinAction(bakStamp, "s", text = "ab", entries = ["c"],
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var b = a
    b.builtinText = "a"
    b.builtinEntries = @["bc"]
    check builtinPayloadPeerKey(a) != builtinPayloadPeerKey(b)
    var c = a
    c.builtinEntries = @["c", ""]
    check builtinPayloadPeerKey(a) != builtinPayloadPeerKey(c)
    var d = a
    d.kind = bakWriteText
    check builtinPayloadPeerKey(a) != builtinPayloadPeerKey(d)

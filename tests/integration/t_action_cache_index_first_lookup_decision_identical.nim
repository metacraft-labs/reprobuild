## Action-Cache-Per-Edge-Store.md §8, §8.2, §10 — THE obligation.
##
## Tier 2 is an accelerator, and §1 states its whole safety condition in one
## sentence: *"the hit/miss and strong-fingerprint decision is byte-identical to
## the decision Tier 1 alone would produce, and every platform or configuration
## without the index runs correctly on Tier 1 only."* That is not a property you
## can inspect a diff for. It is a claim about a decision procedure over a
## matrix of states, so this file runs the matrix TWICE against identically
## constructed fixtures — once with the index attached, once with
## `REPRO_ACTION_CACHE_SHM=0` — and requires the `ActionCacheLookup` status,
## record identity and message to agree in every cell.
##
## The Tier-1-only arm is not a simulation. `REPRO_ACTION_CACHE_SHM=0` is the
## §6.8 opt-out an operator actually has, and it is the same code path a Windows
## host and a host where `mmap` fails both take: `cache.shm.enabled` is false
## and every read is the union read. Proving equality against it is therefore
## proving the property for all three.
##
## NO MOCKS. Both arms are the real `openActionCache` /`recordActionResult` /
## `lookupActionResult` over a real CAS and a real per-edge disk store on a real
## temp filesystem. The only difference between the arms is one environment
## variable, which is the point: anything else would make the comparison
## vacuous.

import std/[os, strutils, tempfiles, times, unittest]

import repro_hash
import repro_local_store

import repro_test_support

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.ac4c.identity." & name),
    hdActionFingerprint)

type
  Cell = object
    ## One cell of the decision matrix: a name, the fixture that builds the
    ## state, and the lookup that reads the decision back out.
    name: string
    status: ActionCacheLookupStatus
    message: string
    strongHex: string
    changedInputPath: string

proc summarise(name: string; lookup: ActionCacheLookup): Cell =
  Cell(name: name, status: lookup.status, message: lookup.message,
    strongHex: toHex(lookup.record.strongFingerprint.bytes),
    changedInputPath: lookup.changedInputPath)

proc `$`(c: Cell): string =
  c.name & " => " & $c.status & " strong=" & c.strongHex &
    " changed=" & c.changedInputPath & " msg=" & c.message

proc bumpTimestamp(path: string; seconds: int) =
  setLastModificationTime(path,
    getFileInfo(path).lastWriteTime + initDuration(seconds = seconds))

proc corruptNewestOutputBlob(cacheRoot, casRoot: string;
                             record: ActionResultRecord) =
  ## Rewrite the CAS blob the newest record points at so `verifyOutputs` fails
  ## against it. This is the state §5.3's "newest-corrupt rejects immediately"
  ## rule exists for, and it is the exact cell that diverges if a partial index
  ## is allowed to direct the read: a candidate set missing the newest record
  ## turns a REJECT into a HIT from an older one.
  let cas = openLocalCas(casRoot)
  for output in record.outputs:
    if output.blob.digest.bytes.len == 0: continue
    let path = cas.blobPath(output.blob.digest)
    if fileExists(path):
      writeFile(path, "corrupted-by-the-decision-identity-fixture")

proc runMatrix(rootDir: string; useIndex: bool): seq[Cell] =
  ## Build the fixture and read the decision out of every cell, in order.
  ##
  ## The two arms get SEPARATE roots so neither can warm the other's state, and
  ## the environment variable is set before the first `openActionCache` because
  ## that is where the tier is attached.
  if useIndex:
    delEnv("REPRO_ACTION_CACHE_SHM")
  else:
    putEnv("REPRO_ACTION_CACHE_SHM", "0")

  let cacheRoot = rootDir / "action-cache"
  let casRoot = rootDir / "cas"
  let work = rootDir / "work"
  createDir(work)
  let cas = openLocalCas(casRoot)
  var cache = openActionCache(cacheRoot)
  defer: cache.closeShmTier()

  if useIndex:
    doAssert cache.shm != nil and cache.shm.enabled,
      "the index arm must actually have the index attached"
  else:
    doAssert cache.shm == nil or not cache.shm.enabled,
      "the Tier-1-only arm must actually have the index off"

  # --- cell 1: an edge with no record at all --------------------------------
  # This is the cell the index answers with ZERO filesystem operations when it
  # is warm and complete, and the cell the union read answers with a `dirExists`
  # and a full directory enumeration. Both must say the same thing.
  let emptyWeak = weakFor("no-record")
  result.add(summarise("empty-cold",
    cache.lookupActionResult(cas, emptyWeak, ffpChecksum, outputRoot = work)))
  # …and again, now that the first lookup has warmed the index for this edge.
  # The SECOND probe is the one that exercises the complete-and-empty arm.
  result.add(summarise("empty-warm",
    cache.lookupActionResult(cas, emptyWeak, ffpChecksum, outputRoot = work)))

  # --- cell 2: a plain hit --------------------------------------------------
  let hitWeak = weakFor("plain-hit")
  writeFile(work / "hit-in.txt", "hit-input\n")
  writeFile(work / "hit-out.txt", "hit-output\n")
  discard cache.recordActionResult(cas, hitWeak, ffpChecksum,
    [work / "hit-in.txt"], ["hit-out.txt"], work)
  result.add(summarise("plain-hit",
    cache.lookupActionResult(cas, hitWeak, ffpChecksum, outputRoot = work)))
  result.add(summarise("plain-hit-warm",
    cache.lookupActionResult(cas, hitWeak, ffpChecksum, outputRoot = work)))

  # --- cell 3: an input that changed ---------------------------------------
  let changedWeak = weakFor("input-changed")
  writeFile(work / "chg-in.txt", "before\n")
  writeFile(work / "chg-out.txt", "chg-output\n")
  discard cache.recordActionResult(cas, changedWeak, ffpChecksum,
    [work / "chg-in.txt"], ["chg-out.txt"], work)
  writeFile(work / "chg-in.txt", "after-a-real-edit\n")
  bumpTimestamp(work / "chg-in.txt", 30)
  result.add(summarise("input-changed",
    cache.lookupActionResult(cas, changedWeak, ffpChecksum, outputRoot = work)))

  # --- cell 4: a metadata-only record with no output payload ---------------
  let noPayloadWeak = weakFor("no-payload")
  writeFile(work / "np-in.txt", "np-input\n")
  writeFile(work / "np-out.txt", "np-output\n")
  discard cache.recordActionResult(cas, noPayloadWeak, ffpChecksum,
    [work / "np-in.txt"], ["np-out.txt"], work, storeOutputBlobs = false)
  removeFile(work / "np-out.txt")
  result.add(summarise("no-output-payload",
    cache.lookupActionResult(cas, noPayloadWeak, ffpChecksum,
      outputRoot = work)))

  # --- cell 5: two path-sets for one edge; the NEWEST must win --------------
  # `loadRecordsForWeak` orders candidates by the `(writeSequence, strongFpHex)`
  # total order and the decision loop walks them newest-first. The index arm
  # recovers that order from the containers' own trailers, exactly as the union
  # read does — it deliberately does not carry the write sequence (§12.E).
  let multiWeak = weakFor("newest-wins")
  writeFile(work / "mw-a.txt", "path-set-a\n")
  writeFile(work / "mw-out.txt", "mw-output\n")
  discard cache.recordActionResult(cas, multiWeak, ffpChecksum,
    [work / "mw-a.txt"], ["mw-out.txt"], work)
  writeFile(work / "mw-b.txt", "path-set-b\n")
  let newestMulti = cache.recordActionResult(cas, multiWeak, ffpChecksum,
    [work / "mw-a.txt", work / "mw-b.txt"], ["mw-out.txt"], work)
  result.add(summarise("newest-wins",
    cache.lookupActionResult(cas, multiWeak, ffpChecksum, outputRoot = work)))

  # --- cell 6: newest-corrupt rejects immediately ---------------------------
  # THE divergence cell. With the `edge-complete` requirement removed so that a
  # PARTIAL index directs the read, the index arm resolves only the older
  # path-set, misses the corrupt newest one, and returns a HIT — while the
  # Tier-1 arm reads the whole directory and returns a REJECT. That is the
  # exact disagreement §8 step 4's completeness precondition exists to prevent,
  # and the comparison at the bottom of this file is what notices it.
  corruptNewestOutputBlob(cacheRoot, casRoot, newestMulti)
  result.add(summarise("newest-corrupt-rejects",
    cache.lookupActionResult(cas, multiWeak, ffpChecksum, outputRoot = work)))

  # --- cell 7: an unresolvable reference degrades to the union read ---------
  # §8 step 5 and §10: a live key that does not resolve is a MISS, never an
  # error and never a false hit. Deleting one `.rec` behind the index's back is
  # exactly the state a retention GC or another binary's eviction produces.
  let orphanWeak = weakFor("unresolvable")
  writeFile(work / "or-in.txt", "or-input\n")
  writeFile(work / "or-out.txt", "or-output\n")
  discard cache.recordActionResult(cas, orphanWeak, ffpChecksum,
    [work / "or-in.txt"], ["or-out.txt"], work)
  discard cache.lookupActionResult(cas, orphanWeak, ffpChecksum,
    outputRoot = work)                      # warm the index for this edge
  let orphanDir = cacheRoot / "hot-records" / perEdgeRecordFileName(orphanWeak)
  for kind, path in walkDir(orphanDir):
    if kind == pcFile:
      removeFile(path)
  result.add(summarise("unresolvable-reference",
    cache.lookupActionResult(cas, orphanWeak, ffpChecksum, outputRoot = work)))

  delEnv("REPRO_ACTION_CACHE_SHM")

suite "integration_action_cache_index_first_lookup_decision_identical":
  when isNixSupported:

    test "the decision matrix is identical with the index and with Tier 1 alone":
      let tempRoot = createTempDir("repro-ac4c-identity", "")
      defer: removeDir(tempRoot)

      # BOTH ARMS RUN AT THE SAME PATH, one after the other, with the tree
      # wiped in between. That is not tidiness: a record's strong fingerprint
      # is computed over its input paths, and `changedInputPath` and `message`
      # quote them verbatim, so two arms at two different directories would
      # differ in every cell for a reason that has nothing to do with the
      # index. Comparing them at one path is what makes the equality mean what
      # it claims to mean.
      let armRoot = tempRoot / "arm"
      let withIndex = runMatrix(armRoot, useIndex = true)
      removeDir(armRoot)
      let tier1Only = runMatrix(armRoot, useIndex = false)

      check withIndex.len == tier1Only.len
      check withIndex.len > 0
      for i in 0 ..< min(withIndex.len, tier1Only.len):
        # Compare cell by cell rather than sequence to sequence: a whole-seq
        # mismatch prints two walls of text and names neither cell.
        if withIndex[i] != tier1Only[i]:
          checkpoint("index arm:  " & $withIndex[i])
          checkpoint("tier-1 arm: " & $tier1Only[i])
        check withIndex[i] == tier1Only[i]

    test "the index arm really did serve lookups from shared memory":
      # Without this the test above would pass just as well if the index never
      # engaged at all — the two arms would be equal because they were the same
      # code path. `actionIndexStats` reports what the tier actually did, so a
      # silently disabled accelerator is a red case rather than a green one.
      when actionIndexSupported:
        let tempRoot = createTempDir("repro-ac4c-engaged", "")
        defer: removeDir(tempRoot)
        resetOutputStateCheckStats()
        discard runMatrix(tempRoot / "arm", useIndex = true)
        let engaged = actionIndexStats()
        checkpoint("negativeHits=" & $engaged.negativeHits &
          " resolvedHits=" & $engaged.resolvedHits &
          " unionFallbacks=" & $engaged.unionFallbacks &
          " unresolved=" & $engaged.unresolvedReferences)
        # The warm probe of the empty edge is answered from mapped memory with
        # no filesystem operation at all — §8 step 3, and §8.1's "largest single
        # effect".
        check engaged.negativeHits > 0
        # And at least one non-empty edge was answered from exactly the
        # containers the index named, with no directory enumeration.
        check engaged.resolvedHits > 0
        # The deleted-`.rec` cell must have been counted as unresolvable rather
        # than silently absorbed: §11 exists because a silently bypassed
        # accelerator is indistinguishable from a healthy idle one.
        check engaged.unresolvedReferences == 1

    test "with the index off, the chain records the bypass and voids completeness":
      # §6.8. The escape hatch is only safe if it is not silent: an engine that
      # declines the index still writes Tier 1, so another engine's
      # `edge-complete` claim about that edge is no longer true. Bumping
      # `bypassWrites` voids every claim chain-wide until the next flatten.
      when actionIndexSupported:
        let tempRoot = createTempDir("repro-ac4c-bypass", "")
        defer: removeDir(tempRoot)
        let cacheRoot = tempRoot / "action-cache"
        let casRoot = tempRoot / "cas"
        let work = tempRoot / "work"
        createDir(work)
        let cas = openLocalCas(casRoot)

        # Engine 1 populates and completes an edge through the index.
        var warm = openActionCache(cacheRoot)
        check warm.shm.enabled
        let weak = weakFor("bypass-edge")
        writeFile(work / "bp-in.txt", "bp-input\n")
        writeFile(work / "bp-out.txt", "bp-output\n")
        discard warm.recordActionResult(cas, weak, ffpChecksum,
          [work / "bp-in.txt"], ["bp-out.txt"], work)
        discard warm.lookupActionResult(cas, weak, ffpChecksum,
          outputRoot = work)
        check warm.shm.idx.enumerateEdge(weak).complete
        check warm.actionIndexCounters().bypassWrites == 0

        # Engine 2 declines the index and writes Tier 1 anyway.
        putEnv("REPRO_ACTION_CACHE_SHM", "0")
        var bypassing = openActionCache(cacheRoot)
        check not bypassing.shm.enabled
        writeFile(work / "bp-in2.txt", "bp-input-2\n")
        discard bypassing.recordActionResult(cas, weak, ffpChecksum,
          [work / "bp-in.txt", work / "bp-in2.txt"], ["bp-out.txt"], work)
        bypassing.closeShmTier()
        delEnv("REPRO_ACTION_CACHE_SHM")

        # Engine 1's completeness claim is now void, so its next lookup takes
        # the union read and sees the record engine 2 wrote. Falsifiable:
        # remove the `bypassWrites` bump and the claim survives, the index
        # directs the read at the stale candidate set, and the second record is
        # invisible.
        check warm.actionIndexCounters().bypassWrites > 0
        check not warm.shm.idx.enumerateEdge(weak).complete
        let after = warm.lookupActionResult(cas, weak, ffpChecksum,
          outputRoot = work)
        check after.status == aclHit
        warm.closeShmTier()

    test "a container this binary cannot decode withholds the completeness claim":
      # §6.2 defines `edge-complete` as a claim about the DIRECTORY: at the
      # moment it was inserted, every `.rec` file present in this edge's
      # directory had a live `record` element in the chain. A container this
      # binary cannot decode is most often one written by a NEWER reprobuild
      # sharing the cache root — so it is a file that exists, that this process
      # has no element for, and that a newer process CAN read. Claiming the
      # edge complete over the subset this binary happens to understand would
      # publish a false claim to that newer process, which would then resolve a
      # short candidate set and miss a record it could have served.
      #
      # The claim is therefore withheld, and this is the only place that guard
      # is observable: within one binary the candidate sets coincide (the union
      # read skips the undecodable file too), so no decision moves and no
      # comparison notices. Falsifiable: publish the `edge-complete` element
      # regardless of `everyContainerDecoded` and this case goes green while
      # everything else stays green — which is exactly why it exists.
      when actionIndexSupported:
        let tempRoot = createTempDir("repro-ac4c-undecodable", "")
        defer: removeDir(tempRoot)
        let cacheRoot = tempRoot / "action-cache"
        let casRoot = tempRoot / "cas"
        let work = tempRoot / "work"
        createDir(work)
        let cas = openLocalCas(casRoot)
        var cache = openActionCache(cacheRoot)
        defer: cache.closeShmTier()
        check cache.shm.enabled

        let weak = weakFor("undecodable-edge")
        writeFile(work / "ud-a.txt", "path-set-a\n")
        writeFile(work / "ud-out.txt", "ud-output\n")
        discard cache.recordActionResult(cas, weak, ffpChecksum,
          [work / "ud-a.txt"], ["ud-out.txt"], work)
        writeFile(work / "ud-b.txt", "path-set-b\n")
        discard cache.recordActionResult(cas, weak, ffpChecksum,
          [work / "ud-a.txt", work / "ud-b.txt"], ["ud-out.txt"], work)

        # A clean directory does claim completeness, so the negative below is a
        # withheld claim rather than a claim that was never available.
        discard cache.lookupActionResult(cas, weak, ffpChecksum,
          outputRoot = work)
        check cache.shm.idx.enumerateEdge(weak).complete

        # Now make one container unreadable to THIS binary, and withdraw the
        # claim so the next union read has to re-establish it from what it can
        # actually see.
        let edgeDir = cacheRoot / "hot-records" / perEdgeRecordFileName(weak)
        var recs: seq[string] = @[]
        for kind, path in walkDir(edgeDir):
          if kind == pcFile and path.endsWith(".rec"): recs.add(path)
        check recs.len == 2
        writeFile(recs[0], "not an RBPE container at all")
        check cache.shm.idx.evictEdgeComplete(weak) == isInserted
        check not cache.shm.idx.enumerateEdge(weak).complete

        # The union read still answers correctly from the container it can
        # decode — Tier 1 is authoritative and an undecodable file is treated
        # as absent, exactly as it always was.
        let served = cache.lookupActionResult(cas, weak, ffpChecksum,
          outputRoot = work)
        check served.status == aclHit

        # And it did NOT re-claim completeness over the directory it could only
        # partly read.
        check not cache.shm.idx.enumerateEdge(weak).complete

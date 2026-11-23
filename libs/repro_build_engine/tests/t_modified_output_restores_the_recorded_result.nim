## A cached record whose inputs match while a declared output on disk was
## MODIFIED (or deleted) in place is served the RECORDED result: its outputs
## are restored from the first tier that holds verified bytes, and the edge
## executes only when none does. Owner decision 2026-11-03, "Adopt + opt-in
## keep mode", which reverses agents 5427fcd2f8 / specs 55b39ef1 (reject and
## re-execute, no peer asked). BuildXL decides a hit without looking at disk
## and writes the recorded bytes back over a changed output; Bazel's local
## action cache rejects and its disk/remote cache restores.
##
## Specs: Incremental-Invalidation.md §"Minimum check set" Step 3.3 (the
## restore bullet, the overwrite report, the unsafe preserve-outputs mode),
## Peer-Cache.md §"Lookup (consumer)" (the 2026-11-03 rider),
## Caching-Architecture.md §"What is on by default" (the switch governs
## whether payloads are STORED, not whether stored ones are used).
##
## Every case runs the real engine (`runBuild`), the real per-edge action
## cache and the real content store:
##
##   * LOCAL CAS: an output modified in place is restored from the local CAS,
##     nothing executes, the overwrite is reported (path, on-disk hash,
##     restored hash), and the next build reuses the restored output in place.
##   * MISSING: an output deleted in place is restored the same way (the
##     2026-10-30 issue, resolved in favour of restoring).
##   * PEER: the local CAS lacks the bytes; the next tier serves them.
##   * CORRUPT: the local payload fails verification; it is dropped, the next
##     tier serves the bytes, the build does not fail; without a tier the edge
##     re-runs and the store holds the right bytes again.
##   * NOTHING: no tier can restore -> the edge re-runs.
##   * NO FALSE ACCEPT: a changed input plus a modified output re-runs; under
##     `ffpHybrid`, an input edited with its size and mtime put back plus a
##     modified output re-runs (the restore re-reads every hashed input).
##   * METADATA-ONLY: a record without payloads re-runs (asking the next tier
##     first, which may hold a payload for the same computation).
##   * DOWNSTREAM: a consumer of the restored output is not re-run and its
##     record keeps the recorded content hash: the edited bytes never reach
##     a downstream fingerprint.
##   * PROCESS EDGE: a depfile-evidenced process edge is restored, and when
##     nothing can restore it is re-run, never reported up to date.
##   * UNSAFE PRESERVE-OUTPUTS: the modified output is kept and the step
##     re-runs over it; the mode has its own fingerprint (neither mode's
##     record serves the other); none of its records is published and no
##     peer is asked.
##
## MOCK POLICY: the peer tier is the engine's own hook pair
## (`peerCacheActionFetcher` / `peerCacheActionInstaller`, and the two
## publisher hooks) with closures that hand back or record payloads, because
## what is under test is when the ENGINE consults or feeds the next tier; the
## real two-phase tier is `t_peer_cache_two_phase_lan_roundtrip`'s.
## Everything else is real.
##
## Falsifiers (each run as a mutation of the engine; see the campaign notes):
## dropping the restore-mode re-lookup re-executes LOCAL CAS / PEER / PROCESS;
## re-running every record whose output is missing (the old
## `rebuildMissingOutputsOnCacheHit` arm) re-executes MISSING; not dropping a
## corrupt blob re-executes CORRUPT (the peer's `casPut` keeps the corrupt
## file); skipping the content re-read restores over the hybrid edit; not
## honouring the preserve flag restores in PRESERVE; not deriving its weak
## fingerprint lets the normal record serve it; dropping its publication gate
## publishes it; dropping `cacheRejectedOutput = true` lets the PROCESS
## case's modified output be reported up to date.

import std/[options, os, strutils, times, unittest]
when defined(posix):
  import std/posix

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_cas_store
import repro_core/paths
import repro_local_store

const
  ToolFlag = "--write-text-and-depfile"
  AppendFlag = "--append-text-and-depfile"

# The process edge's tool (this binary, run as a child): writes the text it
# is given to its output and a make depfile naming its input, as a compiler's
# `-MD` does. With `AppendFlag` it APPENDS to whatever the output already
# holds, like an incremental tool working from its previous output. The text
# is an argv element, in no key (the weak fingerprint is given), so the bytes
# on disk say whether it ran and what it found there.
if paramCount() == 5 and paramStr(1) in [ToolFlag, AppendFlag]:
  var previous = ""
  if paramStr(1) == AppendFlag and fileExists(paramStr(3)):
    previous = readFile(paramStr(3))
  writeFile(paramStr(3), previous & paramStr(5))
  writeFile(paramStr(4), paramStr(3).replace('\\', '/') & ": " &
    paramStr(2).replace('\\', '/') & "\n")
  quit(0)

let TmpDir = absolutePath(
  "build/test-tmp/t_modified_output_restores-" & testCaseScratchSlug())

const
  ActionId = "t-modified-output"
  ConsumerId = "t-modified-output-consumer"
  ProcessId = "t-modified-output-depfile"
  Recorded = "the recorded result\n"
  Rerun = "a re-execution\n"
  Tampered = "modified in place\n"

let Weak = weakFingerprintFromText("t-modified-output-restores")

proc workspace(name: string): string =
  result = TmpDir / name / "ws"
  createDir(result / "src")
  createDir(result / "out")
  writeFile(result / "src" / "main.c", "int main;\n")

proc theAction(ws, text: string; policy = ffpChecksum): BuildAction =
  builtinAction(bakWriteText, ActionId, cwd = ws,
    inputs = [ws / "src" / "main.c"],
    outputs = [ws / "out" / "result.txt"],
    cacheable = true, weakFingerprint = Weak,
    actionCachePolicy = policy, text = text,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc consumerAction(ws, text: string): BuildAction =
  ## Reads the producer's output as a declared input, keyed by its content.
  builtinAction(bakWriteText, ConsumerId, cwd = ws, deps = [ActionId],
    inputs = [ws / "out" / "result.txt"],
    outputs = [ws / "out" / "consumer.txt"],
    cacheable = true,
    weakFingerprint = weakFingerprintFromText("t-modified-output-consumer"),
    actionCachePolicy = ffpChecksum, text = text,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc inPlaceConfig(cacheRoot: string): BuildEngineConfig =
  ## `repro build`'s warm in-place mode, with the output payloads kept in
  ## the local CAS (so the record is payload-backed).
  result = defaultBuildEngineConfig(cacheRoot)
  result.maxParallelism = 1'u32
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = false
  result.bypassRunQuota = true

type Ran = object
  results: seq[ActionResult]
  result: ActionResult
  trace: string

proc runGraph(actions: seq[BuildAction]; config: BuildEngineConfig): Ran =
  let res = runBuild(graph(actions, newSeq[BuildPool]()), config)
  require res.results.len == actions.len
  result.results = res.results
  result.result = res.results[0]
  for event in res.trace:
    result.trace.add(event.event & ": " & event.detail & "\n")
  checkpoint(result.trace)
  for item in res.results:
    require item.status in {asSucceeded, asCacheHit, asUpToDate}

proc run(ws, text: string; config: BuildEngineConfig;
         policy = ffpChecksum): Ran =
  runGraph(@[theAction(ws, text, policy)], config)

proc output(ws: string): string = readFile(ws / "out" / "result.txt")

when defined(posix):
  # Not in std/posix (t_portable_memo_hybrid_hit_publishes_only_recorded_
  # content.nim declares the same pair, for the same reason).
  var AtFdcwd {.importc: "AT_FDCWD", header: "<fcntl.h>".}: cint
  proc utimensat(dirfd: cint; path: cstring; times: ptr array[2, Timespec];
                 flags: cint): cint {.importc, header: "<sys/stat.h>".}

proc rewriteKeepingMetadata(path, text: string) =
  ## New bytes, the same size and the same mtime: an edit `ffpHybrid` cannot
  ## see without reading the file.
  ##
  ## The mtime is put back with `utimensat(2)`, to the nanosecond. With
  ## `os.setLastModificationTime` (`utimes(2)`, microseconds) the restored
  ## mtime differed from the recorded `mtimeNs` on any filesystem with
  ## sub-microsecond timestamps, the hybrid lookup saw the metadata move,
  ## hashed the input and missed -- so the restore's own input re-read, which
  ## these cases are about, was never reached. The final assertion is the
  ## control: the metadata the store compares is exactly what it was.
  doAssert readFile(path).len == text.len
  let before = observeFile(path, ffpTimestamp).metadata
  when defined(posix):
    var st: Stat
    doAssert stat(path.cstring, st) == 0
    var times = [st.st_atim, st.st_mtim]
    writeFile(path, text)
    doAssert utimensat(AtFdcwd, path.cstring, addr times, 0) == 0
  else:
    let mtime = getLastModificationTime(path)
    writeFile(path, text)
    setLastModificationTime(path, mtime)
  let after = observeFile(path, ffpTimestamp).metadata
  doAssert after == before,
    "the rewrite moved the metadata the hybrid lookup compares (" &
    $before & " -> " & $after & "); the case would then measure a miss, " &
    "not the restore's input re-read"

proc recordOf(cacheRoot, id: string): ActionResultRecord =
  let raw = readFile(dependencyEvidencePath(cacheRoot, id))
  var bytes = newSeq[byte](raw.len)
  if raw.len > 0:
    copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
  decodeActionResultRecord(bytes)

proc payloadHash(cacheRoot, id: string): ContentHash =
  let record = recordOf(cacheRoot, id)
  require record.outputPayloadKind == opkCasBlobs
  toContentHash(record.outputs[0].blob.digest.bytes)

proc removePayloads(cacheRoot, id: string) =
  let record = recordOf(cacheRoot, id)
  var cas = openCasStore(cacheRoot)
  defer: cas.close()
  for o in record.outputs:
    let h = toContentHash(o.blob.digest.bytes)
    if cas.casExists(h):
      removeFile(cas.casPath(h))

proc nameOf(text: string): string =
  ## The name the content store gives `text`'s bytes.
  var scratch = openCasStore(TmpDir / "names")
  defer: scratch.close()
  $scratch.casPut(text.toOpenArrayByte(0, text.high))

type Tier = ref object
  served: seq[byte]
  hash: ContentHash
  serve: bool
  fetched, installed: int

proc wireTier(config: var BuildEngineConfig; tier: Tier) =
  ## A next tier that holds `served` under `hash`, installed by `casPut`
  ## exactly as the real installer writes a verified blob.
  config.peerCacheActionFetcher = proc(query: PeerCacheActionQuery):
      Option[seq[byte]] {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      inc tier.fetched
      if tier.serve: some(tier.served) else: none(seq[byte])
  config.peerCacheActionInstaller = proc(query: PeerCacheActionQuery;
      bundleBytes: seq[byte]; cas: var CasStore; cache: ptr ActionCache):
      tuple[ok: bool; reason: string] {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      inc tier.installed
      if cas.casPut(bundleBytes) != tier.hash:
        return (false, "payload digest mismatch")
      (true, "")

proc depfileAction(ws, text: string; flag = ToolFlag): BuildAction =
  ## A PROCESS edge whose evidence is its make depfile: its dependency policy
  ## is not a monitor policy, so (unlike a builtin) nothing forces it to
  ## execute when no record serves it, and the engine's outputs-present
  ## shortcut is reachable for it.
  action(ProcessId,
    [getAppFilename(), flag, ws / "src" / "main.c",
     ws / "out" / "result.txt", ws / "out" / "result.d", text],
    cwd = ws, inputs = [ws / "src" / "main.c"],
    outputs = [ws / "out" / "result.txt"], depfile = ws / "out" / "result.d",
    cacheable = true, weakFingerprint = weakFingerprintFromText(
      "t-modified-output-depfile"), actionCachePolicy = ffpChecksum,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

suite "owner decision 2026-11-03: a modified output is restored, not rebuilt":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "LOCAL CAS: inputs unchanged, output modified in place -> restored and reported":
    let ws = workspace("local")
    let cacheRoot = TmpDir / "local" / "cache"
    let config = inPlaceConfig(cacheRoot)
    check run(ws, Recorded, config).result.launched
    check output(ws) == Recorded
    let restoredName = $payloadHash(cacheRoot, ActionId)
    writeFile(ws / "out" / "result.txt", Tampered)
    let second = run(ws, Rerun, config)
    check not second.result.launched
    check second.result.status == asCacheHit
    check second.result.cacheDecision in {cdHit, cdHybridCutoff}
    check output(ws) == Recorded
    check "cache-restore-modified-outputs: " in second.trace
    # The overwrite report: the path, what was there, what was restored.
    check second.result.outputOverwrites.len == 1
    let overwrite =
      if second.result.outputOverwrites.len > 0:
        second.result.outputOverwrites[0]
      else: OutputOverwrite()
    check overwrite.path.replace('\\', '/') ==
      (ws / "out" / "result.txt").replace('\\', '/')
    check overwrite.onDisk == "blake3:" & nameOf(Tampered)
    check overwrite.restored == "blake3:" & restoredName
    check restoredName == nameOf(Recorded)
    check "cache-restore-overwrote: " in second.trace
    let warning = restoreOverwriteWarning(ActionId, overwrite)
    check "WARNING" in warning and nameOf(Tampered) in warning and
      restoredName in warning and "result.txt" in warning
    # Never through the action's own observable output.
    check second.result.stdout.len == 0 and second.result.stderr.len == 0
    # The record's output state was refreshed to the restored file, so the
    # next build reuses it in place and reports nothing.
    let third = run(ws, Rerun, config)
    check not third.result.launched
    check third.result.status == asUpToDate
    check third.result.outputOverwrites.len == 0
    check output(ws) == Recorded

  test "MISSING: a deleted output of a payload-backed record is restored, not rebuilt":
    let ws = workspace("missing")
    let config = inPlaceConfig(TmpDir / "missing" / "cache")
    check run(ws, Recorded, config).result.launched
    removeFile(ws / "out" / "result.txt")
    let second = run(ws, Rerun, config)
    check not second.result.launched
    check second.result.status == asCacheHit
    check output(ws) == Recorded
    # Nothing was overwritten, so nothing is reported.
    check second.result.outputOverwrites.len == 0

  test "PEER: the local CAS cannot restore it -> the next tier does":
    let ws = workspace("tier")
    let cacheRoot = TmpDir / "tier" / "cache"
    var config = inPlaceConfig(cacheRoot)
    check run(ws, Recorded, config).result.launched
    let tier = Tier(serve: true, hash: payloadHash(cacheRoot, ActionId))
    block:
      var cas = openCasStore(cacheRoot)
      defer: cas.close()
      tier.served = cas.casGet(tier.hash)
      removeFile(cas.casPath(tier.hash))
    writeFile(ws / "out" / "result.txt", Tampered)
    config.wireTier(tier)
    let second = run(ws, Rerun, config)
    check tier.fetched == 1
    check tier.installed == 1
    check not second.result.launched
    check output(ws) == Recorded
    check "peer-cache-hit: " in second.trace
    check second.result.outputOverwrites.len == 1

  test "CORRUPT: a local payload that fails verification is dropped; the next tier restores; the build does not fail":
    let ws = workspace("corrupt")
    let cacheRoot = TmpDir / "corrupt" / "cache"
    var config = inPlaceConfig(cacheRoot)
    check run(ws, Recorded, config).result.launched
    let tier = Tier(serve: true, hash: payloadHash(cacheRoot, ActionId))
    block:
      var cas = openCasStore(cacheRoot)
      defer: cas.close()
      tier.served = cas.casGet(tier.hash)
      # Same name, wrong bytes: present, and failing verification.
      writeFile(cas.casPath(tier.hash), "corrupted payload bytes\n")
      require cas.casExists(tier.hash)
      require not cas.casVerify(tier.hash)
    writeFile(ws / "out" / "result.txt", Tampered)
    config.wireTier(tier)
    let second = run(ws, Rerun, config)
    check "cache-payload-unservable: " in second.trace
    check second.result.droppedCorruptPayloads == @[$tier.hash]
    check tier.fetched == 1
    check tier.installed == 1
    check not second.result.launched
    check second.result.status == asCacheHit
    check output(ws) == Recorded
    block:
      var cas = openCasStore(cacheRoot)
      defer: cas.close()
      check cas.casVerify(tier.hash)

  test "CORRUPT: with no tier to ask, the corrupt payload is dropped and the edge re-runs":
    let ws = workspace("corrupt-alone")
    let cacheRoot = TmpDir / "corrupt-alone" / "cache"
    let config = inPlaceConfig(cacheRoot)
    check run(ws, Recorded, config).result.launched
    let hash = payloadHash(cacheRoot, ActionId)
    block:
      var cas = openCasStore(cacheRoot)
      defer: cas.close()
      writeFile(cas.casPath(hash), "corrupted payload bytes\n")
    writeFile(ws / "out" / "result.txt", Tampered)
    let second = run(ws, Recorded, config)
    check second.result.launched
    check second.result.status == asSucceeded
    check second.result.droppedCorruptPayloads == @[$hash]
    check output(ws) == Recorded
    # The re-execution stored the right bytes under the name again: with the
    # corrupt blob left in place, `storeBlob` would have kept it.
    block:
      var cas = openCasStore(cacheRoot)
      defer: cas.close()
      check cas.casVerify(hash)

  test "NOTHING: no tier can restore it -> the edge re-runs":
    let ws = workspace("no-tier")
    let cacheRoot = TmpDir / "no-tier" / "cache"
    var config = inPlaceConfig(cacheRoot)
    check run(ws, Recorded, config).result.launched
    removePayloads(cacheRoot, ActionId)
    writeFile(ws / "out" / "result.txt", Tampered)
    let tier = Tier(serve: false)
    config.wireTier(tier)
    let second = run(ws, Rerun, config)
    check tier.fetched == 1
    check second.result.launched
    check output(ws) == Rerun
    # And without a tier at all, the same: never the modified output.
    writeFile(ws / "out" / "result.txt", Tampered)
    removePayloads(cacheRoot, ActionId)
    let third = run(ws, Rerun, inPlaceConfig(cacheRoot))
    check third.result.launched
    check output(ws) == Rerun

  test "NO FALSE ACCEPT: an input changed too -> the edge re-runs":
    let ws = workspace("input")
    let config = inPlaceConfig(TmpDir / "input" / "cache")
    check run(ws, Recorded, config).result.launched
    writeFile(ws / "src" / "main.c", "int changed;\n")
    writeFile(ws / "out" / "result.txt", Tampered)
    let second = run(ws, Rerun, config)
    check second.result.launched
    check output(ws) == Rerun
    check "cache-restore-modified-outputs: " notin second.trace
    check second.result.outputOverwrites.len == 0
    # Control: the same edit with the output untouched also re-runs.
    writeFile(ws / "src" / "main.c", "int changed again;\n")
    let third = run(ws, Recorded, config)
    check third.result.launched
    check output(ws) == Recorded

  test "NO FALSE ACCEPT (hybrid): an input edited under unchanged size and mtime, plus a modified output -> re-run":
    # `ffpHybrid` trusts an input whose kind, size and mtime are unchanged.
    # The restore writes the recorded bytes over a file, and must not do so
    # on the strength of an input it did not read: it re-reads every input
    # the record carries a content hash for.
    let ws = workspace("hybrid")
    let config = inPlaceConfig(TmpDir / "hybrid" / "cache")
    let source = ws / "src" / "main.c"
    check run(ws, Recorded, config, ffpHybrid).result.launched
    rewriteKeepingMetadata(source, "int MAIN;\n")   # same size, other content
    writeFile(ws / "out" / "result.txt", Tampered)
    let second = run(ws, Rerun, config, ffpHybrid)
    check second.result.launched
    check output(ws) == Rerun
    check second.result.outputOverwrites.len == 0
    check "cache-restore-declined: input changed" in second.trace

  test "NO FALSE ACCEPT (hybrid): the same edit plus a DELETED output -> re-run, not restored":
    # The in-place mode restores a missing output now, and must not restore
    # the output of inputs it trusted on their metadata: it re-reads every
    # hashed input before ANY restore. Falsifier: limiting that re-read to
    # restores that overwrite a present file.
    let ws = workspace("hybrid-missing")
    let config = inPlaceConfig(TmpDir / "hybrid-missing" / "cache")
    let source = ws / "src" / "main.c"
    check run(ws, Recorded, config, ffpHybrid).result.launched
    rewriteKeepingMetadata(source, "int MAIN;\n")
    removeFile(ws / "out" / "result.txt")
    let second = run(ws, Rerun, config, ffpHybrid)
    check second.result.launched
    check output(ws) == Rerun
    check "cache-restore-declined: input changed" in second.trace

  test "METADATA-ONLY: a record without payloads re-runs, after asking the next tier":
    let ws = workspace("metadata")
    var config = inPlaceConfig(TmpDir / "metadata" / "cache")
    config.deferLocalOutputBlobs = true
    check run(ws, Recorded, config).result.launched
    require recordOf(TmpDir / "metadata" / "cache", ActionId).
      outputPayloadKind != opkCasBlobs
    writeFile(ws / "out" / "result.txt", Tampered)
    let tier = Tier(serve: false)
    config.wireTier(tier)
    let second = run(ws, Rerun, config)
    check second.result.launched
    check output(ws) == Rerun
    # A peer may hold a payload-backed record for the same computation, so
    # the next tier is asked, as for a miss.
    check tier.fetched == 1
    check "metadata-only" in second.trace

  test "DOWNSTREAM: the edited bytes never reach a consumer's fingerprint":
    let ws = workspace("downstream")
    let cacheRoot = TmpDir / "downstream" / "cache"
    let config = inPlaceConfig(cacheRoot)
    let first = runGraph(@[theAction(ws, Recorded),
      consumerAction(ws, "consumed\n")], config)
    for item in first.results:
      check item.launched
    let consumerBefore = recordOf(cacheRoot, ConsumerId)
    writeFile(ws / "out" / "result.txt", Tampered)
    let second = runGraph(@[theAction(ws, Rerun),
      consumerAction(ws, "re-consumed\n")], config)
    check output(ws) == Recorded
    for item in second.results:
      checkpoint(item.id & ": " & $item.status & " " & item.reason)
      check not item.launched
    check readFile(ws / "out" / "consumer.txt") == "consumed\n"
    # The consumer's record still keys the RECORDED content of its input.
    let consumerAfter = recordOf(cacheRoot, ConsumerId)
    require consumerAfter.inputs.len == consumerBefore.inputs.len
    for i in 0 ..< consumerAfter.inputs.len:
      check consumerAfter.inputs[i].localHash ==
        consumerBefore.inputs[i].localHash
    check consumerAfter.strongFingerprint == consumerBefore.strongFingerprint

  test "PROCESS EDGE: restored when it can be; otherwise re-run, never reported up to date":
    let ws = workspace("process")
    let cacheRoot = TmpDir / "process" / "cache"
    let config = inPlaceConfig(cacheRoot)
    check runGraph(@[depfileAction(ws, Recorded)], config).result.launched
    check output(ws) == Recorded
    writeFile(ws / "out" / "result.txt", Tampered)
    let restored = runGraph(@[depfileAction(ws, Rerun)], config)
    check not restored.result.launched
    check output(ws) == Recorded
    check "cache-restore-modified-outputs: " in restored.trace
    removePayloads(cacheRoot, ProcessId)
    writeFile(ws / "out" / "result.txt", Tampered)
    let rerun = runGraph(@[depfileAction(ws, Rerun)], config)
    check rerun.result.launched
    check rerun.result.status == asSucceeded
    check output(ws) == Rerun

  test "RESTORE MODE, PROCESS EDGE: a corrupt payload under a modified output re-runs, never up to date":
    # `--restore-cached-outputs` (`enableCachedOutputRestore`): the lookup
    # verifies payloads, finds the stored one corrupt and drops it; nothing
    # else can restore, and the modified output must not be reported up to
    # date by the outputs-present shortcut. Falsifier: dropping
    # `rejectedOutput = true` from `dropUnservablePayloads`.
    let ws = workspace("restore-mode-corrupt")
    let cacheRoot = TmpDir / "restore-mode-corrupt" / "cache"
    var config = defaultBuildEngineConfig(cacheRoot)
    config.maxParallelism = 1'u32
    config.bypassRunQuota = true
    config.enableCachedOutputRestore()
    check runGraph(@[depfileAction(ws, Recorded)], config).result.launched
    let hash = payloadHash(cacheRoot, ProcessId)
    block:
      var cas = openCasStore(cacheRoot)
      defer: cas.close()
      writeFile(cas.casPath(hash), "corrupted payload bytes\n")
    writeFile(ws / "out" / "result.txt", Tampered)
    let rerun = runGraph(@[depfileAction(ws, Rerun)], config)
    check rerun.result.launched
    check rerun.result.status == asSucceeded
    check output(ws) == Rerun
    check rerun.result.droppedCorruptPayloads == @[$hash]

  test "PROCESS EDGE, METADATA-ONLY: a modified output is re-run, never reported up to date":
    # The record has no payload, so nothing can restore it; the process edge
    # reaches the outputs-present shortcut, which must not call the modified
    # output up to date. Falsifier: dropping `cacheRejectedOutput = true`
    # from the in-place restore block.
    let ws = workspace("process-metadata")
    var config = inPlaceConfig(TmpDir / "process-metadata" / "cache")
    config.deferLocalOutputBlobs = true
    check runGraph(@[depfileAction(ws, Recorded)], config).result.launched
    writeFile(ws / "out" / "result.txt", Tampered)
    let rerun = runGraph(@[depfileAction(ws, Rerun)], config)
    check rerun.result.launched
    check rerun.result.status == asSucceeded
    check output(ws) == Rerun

suite "owner decision 2026-11-03: the opt-in UNSAFE preserve-outputs mode":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "PRESERVE: the modified output is kept, the step re-runs over it, and it is reported":
    let ws = workspace("preserve")
    var config = inPlaceConfig(TmpDir / "preserve" / "cache")
    config.unsafePreserveOutputs = @[ProcessId]
    check runGraph(@[depfileAction(ws, Recorded, AppendFlag)],
      config).result.launched
    check output(ws) == Recorded
    writeFile(ws / "out" / "result.txt", Tampered)
    let second = runGraph(@[depfileAction(ws, Rerun, AppendFlag)], config)
    # Neither restored nor deleted: the tool found the modified output where
    # it was and appended to it.
    check second.result.launched
    check output(ws) == Tampered & Rerun
    check second.result.outputOverwrites.len == 0
    check second.result.preservedModifiedOutputs.len == 1
    check "cache-preserve-modified-output: " in second.trace
    check "cache-restore-modified-outputs: " notin second.trace

  test "PRESERVE, RESTORE MODE: a restore that would overwrite a modified output is declined":
    # Under `--restore-cached-outputs` a hit restores every output that is
    # not in place; for a preserve-mode step it must not write over a
    # modified one. Falsifier: ignoring the flag in `restoreRecordedOutputs`.
    let ws = workspace("preserve-restore-mode")
    var config = defaultBuildEngineConfig(TmpDir / "preserve-restore-mode" /
      "cache")
    config.maxParallelism = 1'u32
    config.bypassRunQuota = true
    config.enableCachedOutputRestore()
    config.unsafePreserveOutputs = @[ProcessId]
    check runGraph(@[depfileAction(ws, Recorded, AppendFlag)],
      config).result.launched
    writeFile(ws / "out" / "result.txt", Tampered)
    let second = runGraph(@[depfileAction(ws, Rerun, AppendFlag)], config)
    check second.result.launched
    check output(ws) == Tampered & Rerun
    check second.result.outputOverwrites.len == 0
    check second.result.preservedModifiedOutputs.len == 1
    # A MISSING output has nothing to keep: it is restored, mode or not.
    removeFile(ws / "out" / "result.txt")
    let third = runGraph(@[depfileAction(ws, Rerun & Rerun, AppendFlag)],
      config)
    check not third.result.launched
    check output(ws) == Tampered & Rerun

  test "PRESERVE: the mode is part of the fingerprint; neither mode's record serves the other":
    let ws = workspace("preserve-key")
    let cacheRoot = TmpDir / "preserve-key" / "cache"
    let normal = inPlaceConfig(cacheRoot)
    var preserving = inPlaceConfig(cacheRoot)
    preserving.unsafePreserveOutputs = @[ActionId]
    let declared = theAction(ws, Recorded)
    check preserveOutputsWeakFingerprint(declared.weakFingerprint) !=
      declared.weakFingerprint
    check run(ws, Recorded, normal).result.launched
    check recordOf(cacheRoot, ActionId).weakFingerprint ==
      declared.weakFingerprint
    # The normal record matches on every input, and does not serve the
    # preserve-mode step: it executes, under its own fingerprint.
    let first = run(ws, Recorded, preserving)
    check first.result.launched
    check recordOf(cacheRoot, ActionId).weakFingerprint ==
      preserveOutputsWeakFingerprint(declared.weakFingerprint)
    # And back: the normal mode is served by its own record, not by the
    # preserve-mode one.
    let back = run(ws, Recorded, normal)
    check not back.result.launched
    # A selector that names nothing selects nothing.
    var nobody = inPlaceConfig(cacheRoot)
    nobody.unsafePreserveOutputs = @["no-such-step"]
    check not run(ws, Recorded, nobody).result.launched

  test "PRESERVE: no record leaves the host and no peer is asked":
    let ws = workspace("preserve-publish")
    var config = inPlaceConfig(TmpDir / "preserve-publish" / "cache")
    config.unsafePreserveOutputs = @[ActionId]
    var published = new(int)
    config.peerCacheActionPublisher = proc (query: PeerCacheActionQuery;
        record: ActionResultRecord; cas: var CasStore) {.gcsafe, closure.} =
      {.cast(gcsafe).}:
        inc published[]
    let tier = Tier(serve: false)
    config.wireTier(tier)
    let first = run(ws, Recorded, config)
    check first.result.launched
    check published[] == 0
    check "peer-cache-publish-refused: " in first.trace
    check "preserve-outputs" in first.trace
    check tier.fetched == 0
    writeFile(ws / "out" / "result.txt", Tampered)
    let second = run(ws, Rerun, config)
    check second.result.launched
    check published[] == 0
    check tier.fetched == 0
    # Control: the same step in the normal mode is published.
    var normal = inPlaceConfig(TmpDir / "preserve-publish" / "normal-cache")
    normal.peerCacheActionPublisher = config.peerCacheActionPublisher
    let ws2 = workspace("preserve-publish-normal")
    check run(ws2, Recorded, normal).result.launched
    check published[] == 1

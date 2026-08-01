## A real, separately compiled compatibility peer for the cache lifecycle
## integration suite. The data-structure imports below are pinned verbatim to
## origin/dev commit 9f0a9be84c74985e094a32922b4dd4a210c64473.

import std/[os, strutils]

import ./origin/libs/repro_shm_index/src/repro_shm_index
import ./origin/libs/repro_shm_index/src/repro_shm_index/daemon

const
  ClaimAndBlockMode = "claim-block"
  TryClaimMode = "try-claim"
  ProduceMode = "produce"
  ConsumeMode = "consume"

proc decodeHex(raw: string): seq[byte] =
  if (raw.len and 1) != 0:
    raise newException(ValueError, "hex value has odd length")
  result = newSeq[byte](raw.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(raw[i * 2 .. i * 2 + 1]))

proc encodeHex(raw: openArray[byte]): string =
  result = newStringOfCap(raw.len * 2)
  for value in raw:
    result.add(toHex(value, 2))

proc claimAndBlock(cacheRoot: string) =
  var daemon = openCacheDaemon(cacheRoot)
  doAssert daemon.idx.available
  doAssert daemon.tryClaimOwnership()
  stdout.writeLine("CLAIMED")
  stdout.flushFile()
  discard stdin.readLine()
  daemon.close()

proc tryClaim(cacheRoot: string) =
  var daemon = openCacheDaemon(cacheRoot)
  doAssert daemon.idx.available
  if daemon.tryClaimOwnership():
    stdout.writeLine("CLAIMED")
  else:
    stdout.writeLine("REJECTED")
  stdout.flushFile()
  daemon.close()

proc produce(cacheRoot, digestHex, recordHex: string) =
  var idx = openShmIndex(cacheRoot, create = false)
  doAssert idx.available
  let digest = decodeHex(digestHex)
  let record = decodeHex(recordHex)
  doAssert digest.len == KeyDigestLen
  doAssert idx.submitRecord(digest, record)
  stdout.writeLine("PRODUCED")
  stdout.flushFile()
  idx.close()

proc consume(cacheRoot: string) =
  var daemon = openCacheDaemon(cacheRoot)
  doAssert daemon.idx.available
  doAssert daemon.tryClaimOwnership()
  var record: RingRecord
  doAssert daemon.idx.ringView.tryDrainOne(record)
  doAssert daemon.idx.liveSeg.writeSlot(record.digest, record.rec) == swsWritten
  stdout.writeLine("CONSUMED " & encodeHex(record.digest) & " " &
    encodeHex(record.rec))
  stdout.flushFile()
  daemon.close()

when isMainModule:
  let params = commandLineParams()
  if params.len == 2 and params[0] == ClaimAndBlockMode:
    claimAndBlock(params[1])
  elif params.len == 2 and params[0] == TryClaimMode:
    tryClaim(params[1])
  elif params.len == 4 and params[0] == ProduceMode:
    produce(params[1], params[2], params[3])
  elif params.len == 2 and params[0] == ConsumeMode:
    consume(params[1])
  else:
    stderr.writeLine(
      "usage: legacy_cache_peer <claim-block|try-claim|produce|consume> ...")
    quit(2)

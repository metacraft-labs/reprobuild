## Shared subprocess frontend for exact-origin and legacy-wire cache peers.
## The importing entrypoint selects the implementation modules first.

import std/[os, strutils]

const
  ClaimAndBlockMode = "claim-block"
  TryClaimMode = "try-claim"
  ProduceMode = "produce"
  ConsumeMode = "consume"
  IsolationServerMode = "isolation-server"

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

proc reply(line: string) =
  stdout.writeLine(line)
  stdout.flushFile()

proc claimAndBlock(cacheRoot: string) =
  var daemon = openCacheDaemon(cacheRoot)
  doAssert daemon.idx.available
  doAssert daemon.tryClaimOwnership()
  reply("CLAIMED")
  discard stdin.readLine()
  daemon.close()

proc tryClaim(cacheRoot: string) =
  var daemon = openCacheDaemon(cacheRoot)
  doAssert daemon.idx.available
  if daemon.tryClaimOwnership():
    reply("CLAIMED")
  else:
    reply("REJECTED")
  daemon.close()

proc produce(cacheRoot, digestHex, recordHex: string) =
  var idx = openShmIndex(cacheRoot, create = false)
  doAssert idx.available
  let digest = decodeHex(digestHex)
  let record = decodeHex(recordHex)
  doAssert digest.len == KeyDigestLen
  doAssert idx.submitRecord(digest, record)
  reply("PRODUCED")
  idx.close()

proc consume(cacheRoot: string) =
  var daemon = openCacheDaemon(cacheRoot)
  doAssert daemon.idx.available
  doAssert daemon.tryClaimOwnership()
  var record: RingRecord
  doAssert daemon.idx.ringView.tryDrainOne(record)
  doAssert daemon.idx.liveSeg.writeSlot(record.digest, record.rec) == swsWritten
  reply("CONSUMED " & encodeHex(record.digest) & " " &
    encodeHex(record.rec))
  daemon.close()

proc isolationServer(cacheRoot: string) =
  ## Holds one mapping open while the current implementation creates its
  ## Darwin-v2 mapping beside it. Line commands let the integration test prove
  ## ownership, ring and segment isolation without reopening the old v1 ctl.
  var daemon = openCacheDaemon(cacheRoot)
  doAssert daemon.idx.available
  doAssert daemon.tryClaimOwnership()
  reply("CLAIMED")

  var line: string
  while stdin.readLine(line):
    let parts = line.splitWhitespace()
    if parts.len == 0:
      reply("ERROR empty command")
    elif parts[0] == "state" and parts.len == 1:
      reply("STATE " & (if daemon.owns: "1" else: "0") & " " &
        $daemon.idx.ringView.pendingCount() & " " &
        $daemon.idx.currentGeneration())
    elif parts[0] == "produce" and parts.len == 3:
      let digest = decodeHex(parts[1])
      let record = decodeHex(parts[2])
      doAssert digest.len == KeyDigestLen
      doAssert daemon.idx.submitRecord(digest, record)
      reply("PRODUCED")
    elif parts[0] == "lookup" and parts.len == 2:
      let digest = decodeHex(parts[1])
      doAssert digest.len == KeyDigestLen
      var snapshot: SlotSnapshot
      if daemon.idx.liveSeg.lookupSlot(digest, snapshot) == srsHit:
        reply("HIT " & encodeHex(snapshot.rec))
      else:
        reply("MISS")
    elif parts[0] == "drain-persist" and parts.len == 1:
      let drained = daemon.drainOnce()
      let persisted = daemon.persist()
      reply("DRAINED " & $drained & " PERSISTED " & $persisted)
    elif parts[0] == "quit" and parts.len == 1:
      reply("BYE")
      break
    else:
      reply("ERROR invalid command")
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
  elif params.len == 2 and params[0] == IsolationServerMode:
    isolationServer(params[1])
  else:
    stderr.writeLine(
      "usage: legacy_cache_peer " &
      "<claim-block|try-claim|produce|consume|isolation-server> ...")
    quit(2)

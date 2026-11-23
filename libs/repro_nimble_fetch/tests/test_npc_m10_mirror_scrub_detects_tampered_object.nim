## NPC-M10 verification `test_npc_m10_mirror_scrub_detects_tampered_object`
## (threat model G27; DET-3, DET-4).
##
## A directory store holds three packages' source objects and a lock's
## closure index. The scrub re-hashes each against the digest it is
## stored under: before any change it reports nothing, and its control
## (a store with one object planted under the wrong digest) trips. Then one
## byte of one stored object is flipped. The next scrub reports that object
## alone, with the digest it is stored under and the digest it now hashes
## to, and the scheduled run (`runScrubDetector`) sends the finding to the
## evidence sink (the real sink binary, over TLS, with the detector host's
## own credential) as a `scrub-mismatch` detection naming the digest,
## beside a heartbeat whose control tripped.
##
## Falsifying mutation (recorded in the plan): a scrub that checks presence
## only passes the flipped byte, and fails the test.

import std/[os, strutils, tables, tempfiles, unittest]

import ./fetch_fixtures
import ./npc_sink_fixtures

proc flipByteIn(path, needle: string) =
  var data = readFile(path)
  let at = data.find(needle)
  doAssert at >= 0, "needle not found"
  data[at] = chr(ord(data[at]) xor 0x01)
  writeFile(path, data)

suite "NPC-M10: the scrub detects a tampered stored object":

  test "one flipped byte is reported with its digest and reaches the sink":
    let f = newFixture("m10-scrub")
    var sources: seq[PublishedSource]
    for name in ["alpha", "beta", "gamma"]:
      sources.add f.package("owner/" & name & ".git", @[nimbleFile(name),
        file("src/" & name & ".nim", "proc " & name & "Answer*(): int = 42\n")])
    let work = createTempDir("npc-m10-scrub-", "")
    let store = parseMirror(work / "store")
    var rows: seq[NimbleLockRow]
    var sizes = initTable[string, int64]()
    for i, s in sources:
      store.putSource(s)
      rows.add f.rowOf(["alpha", "beta", "gamma"][i], s)
      sizes[s.tree] = int64(s.archive.len)
    store.putObject(closureIndexPath(lockClosureKey(rows)),
      encodeClosureIndex(buildClosureIndex(rows, sizes, @[store],
        1_790_000_000)))
    let control = work / "control"
    plantScrubControl(control)

    # Before: nothing to report, and the control trips.
    let clean = scrubStore(store, work / "scratch-clean")
    check clean.objects == 4
    check clean.findings.len == 0
    check controlTripped(scrubStore(parseMirror(control),
      work / "scratch-control"))

    # One byte of beta's stored object, inside a file's content.
    let victim = store.location / sourceObjectPath(sources[1].tree)
    flipByteIn(victim, "betaAnswer")
    let r = scrubStore(store, work / "scratch-1")
    checkpoint $r.findings
    check r.objects == 4
    check r.findings.len == 1
    if r.findings.len == 1:
      check r.findings[0].digest == sources[1].tree
      check r.findings[0].observed.len == 64
      check r.findings[0].observed != sources[1].tree
      check r.findings[0].path == sourceObjectPath(sources[1].tree)

    # The scheduled run reports it to the sink.
    var s = startNpcSink("npc-m10-scrub-sink")
    defer: s.stop()
    let app = s.appender()
    app.registerDetector(ScrubDetector, 60_000, probed = true)
    let run = runScrubDetector(store, control, work / "scratch-2", app)
    check run.findings.len == 1
    check app.drain()
    let found = s.sink.detections("scrub-mismatch")
    check found.len == 1
    if found.len == 1:
      check found[0].record.detector == ScrubDetector
      check found[0].record.field("digest") == sources[1].tree
      check found[0].record.field("observedDigest") == r.findings[0].observed
      check found[0].senderHostId == s.writer.identity.hostId
    let beats = s.heartbeats(ScrubDetector)
    check beats.len == 1
    if beats.len == 1:
      check beats[0].record.field("control") == "tripped"
    check s.sink.detections("control-missed").len == 0
    app.close()

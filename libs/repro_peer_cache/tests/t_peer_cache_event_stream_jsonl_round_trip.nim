## Peer-Cache-Scale M4 verification: JSONL event stream round trip.
##
## Configures an `EventLog` to a temp file, emits three structured
## events (`swim_suspect`, `fetch_attempt`, `fetch_completed`), then
## reads the file back line-by-line and asserts every line parses
## cleanly through `parseJson` and carries the expected `event` /
## payload fields.
##
## See `Peer-Cache-Scale.milestones.org` §M4 verification list.

import std/[json, os, strutils, unittest]

import repro_peer_cache

suite "peer-cache M4 event stream JSONL round trip":
  test "emit + parseJson round trip preserves event + payload fields":
    let tmpDir = getTempDir() / "t_peer_cache_event_stream"
    createDir(tmpDir)
    let logPath = tmpDir / "events.jsonl"
    defer:
      try: removeFile(logPath) except CatchableError: discard
      try: removeDir(tmpDir) except CatchableError: discard

    let log = openEventLog(logPath)
    # Emit one event per spec-quoted shape.
    log.emit("swim_suspect", {
      "peerId": quoteString("LABC"),
      "incarnation": "7"})
    log.emit("fetch_attempt", {
      "digest": quoteString("deadbeef"),
      "candidate": quoteString("LXYZ")})
    log.emit("fetch_completed", {
      "digest": quoteString("deadbeef"),
      "from": quoteString("LXYZ"),
      "bytes": "12345",
      "latency_ms": "42"})
    closeLog(log)

    let raw = readFile(logPath)
    var lines: seq[string] = @[]
    for ln in raw.splitLines():
      if ln.len > 0:
        lines.add(ln)
    check lines.len == 3

    let j0 = parseJson(lines[0])
    check j0["event"].getStr() == "swim_suspect"
    check j0["peerId"].getStr() == "LABC"
    check j0["incarnation"].getInt() == 7
    check j0["ts"].getStr().len > 10  # ISO-8601 timestamp

    let j1 = parseJson(lines[1])
    check j1["event"].getStr() == "fetch_attempt"
    check j1["digest"].getStr() == "deadbeef"
    check j1["candidate"].getStr() == "LXYZ"

    let j2 = parseJson(lines[2])
    check j2["event"].getStr() == "fetch_completed"
    check j2["bytes"].getInt() == 12345
    check j2["latency_ms"].getInt() == 42
    check j2["from"].getStr() == "LXYZ"

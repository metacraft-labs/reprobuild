import std/[os, strutils, tempfiles, unittest]

import repro_core/codec
import repro_monitor_depfile

proc sampleRecord(path: string): MonitorRecord =
  MonitorRecord(
    kind: mrFileRead,
    observationKind: moFileRead,
    seq: 42,
    osPid: 100,
    parentOsPid: 1,
    threadId: 7,
    result: 12,
    probeResult: prUnknown,
    path: path)

proc expectReaderError(path: string; kind: MonitorDepFileReaderErrorKind) =
  try:
    discard readMonitorDepFile(path)
    check false
  except MonitorDepFileReaderError as err:
    check err.kind == kind

suite "monitor depfile reader validation":
  test "binary RMDF round-trips and JSON is inspection-only":
    let tempRoot = createTempDir("repro-rmdf-reader", "")
    defer: removeDir(tempRoot)

    let depfile = tempRoot / "ok.rdep"
    writeCanonical(depfile, [sampleRecord(tempRoot / "input.txt")])

    let raw = readFile(depfile)
    check raw[0 .. 3] == "RMDF"
    check raw[0] != '{'
    let dep = readMonitorDepFile(depfile)
    check dep.version == RmdfVersion
    check dep.records.len == 1
    check dep.records[0].seq == 1
    check dep.records[0].path.endsWith("input.txt")
    check renderMonitorDepFileJson(dep).contains("\"format\":\"RMDF\"")

  test "corrupt and truncated RMDF files fail validation":
    let tempRoot = createTempDir("repro-rmdf-corrupt", "")
    defer: removeDir(tempRoot)

    let depfile = tempRoot / "ok.rdep"
    writeCanonical(depfile, [sampleRecord(tempRoot / "input.txt")])

    let missing = tempRoot / "missing.rdep"
    expectReaderError(missing, mrMissingFile)

    let badMagic = tempRoot / "bad-magic.rdep"
    writeFile(badMagic, "NOPE" & readFile(depfile)[4 .. ^1])
    expectReaderError(badMagic, mrBadMagic)

    let truncated = tempRoot / "truncated.rdep"
    writeFile(truncated, readFile(depfile)[0 .. 15])
    expectReaderError(truncated, mrTruncated)

    let badChecksum = tempRoot / "bad-checksum.rdep"
    var raw = readFile(depfile)
    raw[^1] = char(ord(raw[^1]) xor 0x01)
    writeFile(badChecksum, raw)
    expectReaderError(badChecksum, mrChecksumMismatch)

    let badKind = tempRoot / "bad-kind.rdep"
    var badKindBytes = readFile(depfile).toBytes()
    badKindBytes[28] = 0xff'u8
    badKindBytes[29] = 0xff'u8
    let body = badKindBytes[24 ..< badKindBytes.len - 20]
    var encodedChecksum: seq[byte] = @[]
    encodedChecksum.writeU64Le(checksum(body))
    for i in 0 ..< encodedChecksum.len:
      badKindBytes[badKindBytes.len - 8 + i] = encodedChecksum[i]
    writeFile(badKind, badKindBytes.fromBytes())
    expectReaderError(badKind, mrSemanticValidationFailed)

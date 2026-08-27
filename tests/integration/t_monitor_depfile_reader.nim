import std/[os, strutils, tempfiles, unittest]

import repro_core/codec
import io_mon

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
  test "binary iomon round-trips and JSON is inspection-only":
    let tempRoot = createTempDir("repro-rmdf-reader", "")
    defer: removeDir(tempRoot)

    let depfile = tempRoot / "ok.iomon"
    writeCanonical(depfile, [sampleRecord(tempRoot / "input.txt")])

    let raw = readFile(depfile)
    check raw[0 .. 3] == "IOMN"
    check raw[0] != '{'
    let dep = readMonitorDepFile(depfile)
    check dep.version == IomonVersion
    check dep.records.len == 1
    check dep.records[0].seq == 1
    check dep.records[0].path.endsWith("input.txt")
    check renderMonitorDepFileJson(dep).contains("\"format\":\"iomon\"")

  test "corrupt and truncated iomon files fail validation":
    let tempRoot = createTempDir("repro-rmdf-corrupt", "")
    defer: removeDir(tempRoot)

    let depfile = tempRoot / "ok.iomon"
    writeCanonical(depfile, [sampleRecord(tempRoot / "input.txt")])

    let missing = tempRoot / "missing.iomon"
    expectReaderError(missing, mrMissingFile)

    let badMagic = tempRoot / "bad-magic.iomon"
    writeFile(badMagic, "NOPE" & readFile(depfile)[4 .. ^1])
    expectReaderError(badMagic, mrBadMagic)

    let truncated = tempRoot / "truncated.iomon"
    writeFile(truncated, readFile(depfile)[0 .. 15])
    expectReaderError(truncated, mrTruncated)

    let badChecksum = tempRoot / "bad-checksum.iomon"
    var raw = readFile(depfile)
    raw[^1] = char(ord(raw[^1]) xor 0x01)
    writeFile(badChecksum, raw)
    expectReaderError(badChecksum, mrChecksumMismatch)

    let badKind = tempRoot / "bad-kind.iomon"
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

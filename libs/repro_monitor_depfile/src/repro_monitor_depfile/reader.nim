import std/[os, options, strutils]

import repro_core/codec
import repro_monitor_depfile/types
import repro_monitor_depfile/writer

proc classifyEnvelopeError(err: ref EnvelopeError): MonitorDepFileReaderErrorKind =
  case err.kind
  of eeUnknownMagic:
    mrBadMagic
  of eeUnsupportedVersion:
    mrUnsupportedVersion
  of eeUnknownType:
    mrSemanticValidationFailed
  of eeMalformed:
    if err.msg.contains("truncated"):
      mrTruncated
    elif err.msg.contains("checksum"):
      mrChecksumMismatch
    else:
      mrSemanticValidationFailed

proc validateSequenceOrder(records: openArray[MonitorRecord]) =
  var expected = 1'u64
  for record in records:
    if record.seq != expected:
      raiseMonitorDepFileReaderError(mrRecordOrderInvalid,
        "RMDF record sequence is not canonical")
    inc expected

proc decodeMonitorDepFile(bytes: openArray[byte];
                          options: MonitorDepFileReaderOptions): MonitorDepFile =
  if bytes.len < 44:
    raiseMonitorDepFileReaderError(mrTruncated, "RMDF file is too short")
  if fromBytes(bytes.toOpenArray(0, 3)) != RmdfMagic:
    raiseMonitorDepFileReaderError(mrBadMagic, "unknown RMDF magic")

  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != RmdfVersion:
    raiseMonitorDepFileReaderError(mrUnsupportedVersion, "unsupported RMDF version")
  discard readU16Le(bytes, pos)
  let headerCount = readU64Le(bytes, pos)
  let bodyLen = int(readU64Le(bytes, pos))
  if headerCount > options.maxObservationCount:
    raiseMonitorDepFileReaderError(mrRecordLimitExceeded,
      "RMDF record count exceeds configured limit")
  if pos + bodyLen + 20 != bytes.len:
    raiseMonitorDepFileReaderError(mrTruncated,
      "RMDF body length/trailer mismatch")

  let bodyStart = pos
  let bodyEnd = bodyStart + bodyLen
  let body = bytes[bodyStart ..< bodyEnd]
  pos = bodyEnd
  if fromBytes(bytes.toOpenArray(pos, pos + 3)) != RmdfTrailerMagic:
    raiseMonitorDepFileReaderError(mrTruncated, "missing RMDF trailer")
  pos += 4
  let trailerCount = readU64Le(bytes, pos)
  let trailerChecksum = readU64Le(bytes, pos)
  if trailerCount != headerCount:
    raiseMonitorDepFileReaderError(mrSemanticValidationFailed,
      "RMDF record count mismatch")
  if options.requireTrailerChecksum and trailerChecksum != checksum(body):
    raiseMonitorDepFileReaderError(mrChecksumMismatch, "RMDF checksum mismatch")

  var records: seq[MonitorRecord]
  try:
    records = decodeFrames(body)
  except EnvelopeError as err:
    raiseMonitorDepFileReaderError(classifyEnvelopeError(err), err.msg)
  if uint64(records.len) != headerCount:
    raiseMonitorDepFileReaderError(mrSemanticValidationFailed,
      "RMDF frame count mismatch")
  validateSequenceOrder(records)

  result = depFileFromRecords(records)
  result.version = version

proc readMonitorDepFile*(path: string;
                         options: MonitorDepFileReaderOptions): MonitorDepFile =
  if not fileExists(path):
    raiseMonitorDepFileReaderError(mrMissingFile,
      "RMDF file does not exist: " & path)
  decodeMonitorDepFile(readFile(path).toBytes(), options)

proc readMonitorDepFile*(path: string): MonitorDepFile =
  readMonitorDepFile(path, defaultMonitorDepFileReaderOptions())

proc tryReadMonitorDepFile*(path: string;
                            options: MonitorDepFileReaderOptions):
                            MonitorDepFileReaderResult =
  try:
    result.depFile = some(readMonitorDepFile(path, options))
  except MonitorDepFileReaderError as err:
    result.depFile = none(MonitorDepFile)
    result.diagnostics.add MonitorDiagnostic(level: mdlError, message: err.msg)

iterator streamMonitorDepFile*(path: string;
                               options: MonitorDepFileReaderOptions):
                               FsSnoopStreamItem =
  let dep = readMonitorDepFile(path, options)
  for record in dep.records:
    case record.kind
    of mrProcessStart:
      yield FsSnoopStreamItem(kind: fsiProcessStarted, record: record)
    of mrProcessExec, mrProcessSpawn:
      yield FsSnoopStreamItem(kind: fsiObservation, record: record)
    of mrEventLoss:
      yield FsSnoopStreamItem(kind: fsiEventLoss, record: record)
    else:
      if record.observationKind == moEventLoss:
        yield FsSnoopStreamItem(kind: fsiEventLoss, record: record)
      else:
        yield FsSnoopStreamItem(kind: fsiObservation, record: record)
  yield FsSnoopStreamItem(kind: fsiSummary, summary: dep.summary)

iterator streamMonitorDepFile*(path: string): FsSnoopStreamItem =
  for item in streamMonitorDepFile(path, defaultMonitorDepFileReaderOptions()):
    yield item

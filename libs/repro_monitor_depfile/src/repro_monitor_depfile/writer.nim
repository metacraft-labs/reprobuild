import std/[algorithm, os, strutils]
from repro_core/paths import extendedPath

import repro_core/codec
import repro_monitor_depfile/capabilities
import repro_monitor_depfile/types

const
  CanonicalFileKind = 1'u16
  FnvOffset = 14695981039346656037'u64
  FnvPrime = 1099511628211'u64

proc checksum*(bytes: openArray[byte]): uint64 =
  result = FnvOffset
  for b in bytes:
    result = result xor uint64(b)
    result = result * FnvPrime

proc writeI64Le(outp: var seq[byte]; value: int64) =
  outp.writeU64Le(cast[uint64](value))

proc readI64Le(bytes: openArray[byte]; pos: var int): int64 =
  cast[int64](readU64Le(bytes, pos))

proc encodeRecordPayload*(record: MonitorRecord): seq[byte] =
  result = @[]
  result.writeU16Le(uint16(ord(record.kind)))
  result.writeU16Le(uint16(ord(record.observationKind)))
  result.writeU64Le(record.seq)
  result.writeU64Le(record.osPid)
  result.writeU64Le(record.parentOsPid)
  result.writeU64Le(record.threadId)
  result.writeU64Le(record.childOsPid)
  result.writeI64Le(record.result)
  result.writeU32Le(record.flags)
  result.writeU32Le(uint32(ord(record.probeResult)))
  result.writeString(record.path)
  result.writeString(record.detail)

proc decodeRecordPayload*(payload: openArray[byte]): MonitorRecord =
  var pos = 0
  let kindOrd = readU16Le(payload, pos)
  let obsOrd = readU16Le(payload, pos)
  if kindOrd < uint16(ord(low(MonitorRecordKind))) or
      kindOrd > uint16(ord(high(MonitorRecordKind))):
    raiseEnvelopeError(eeUnknownType, "unknown RMDF record kind")
  if obsOrd < uint16(ord(low(MonitorObservationKind))) or
      obsOrd > uint16(ord(high(MonitorObservationKind))):
    raiseEnvelopeError(eeUnknownType, "unknown RMDF observation kind")

  result.kind = MonitorRecordKind(kindOrd.int)
  result.observationKind = MonitorObservationKind(obsOrd.int)
  result.seq = readU64Le(payload, pos)
  result.osPid = readU64Le(payload, pos)
  result.parentOsPid = readU64Le(payload, pos)
  result.threadId = readU64Le(payload, pos)
  result.childOsPid = readU64Le(payload, pos)
  result.result = readI64Le(payload, pos)
  result.flags = readU32Le(payload, pos)
  let probeOrd = readU32Le(payload, pos)
  if probeOrd > uint32(ord(high(ProbeResult))):
    raiseEnvelopeError(eeUnknownType, "unknown RMDF probe result")
  result.probeResult = ProbeResult(probeOrd.int)
  result.path = readString(payload, pos)
  result.detail = readString(payload, pos)
  if pos != payload.len:
    raiseEnvelopeError(eeMalformed, "RMDF record has trailing bytes")

proc encodeFrame*(record: MonitorRecord): seq[byte] =
  let payload = encodeRecordPayload(record)
  result = @[]
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodeFrames*(bytes: openArray[byte]): seq[MonitorRecord] =
  var pos = 0
  while pos < bytes.len:
    let length = int(readU32Le(bytes, pos))
    if length <= 0 or pos + length > bytes.len:
      raiseEnvelopeError(eeMalformed, "truncated RMDF record frame")
    result.add decodeRecordPayload(bytes.toOpenArray(pos, pos + length - 1))
    pos += length

proc fragmentPath*(fragmentDir: string; osPid, threadId: uint64): string =
  fragmentDir / ("repro-monitor-" & $osPid & "-" & $threadId & ".rmdf-frag")

proc appendFragmentRecord*(fragmentDir: string; record: MonitorRecord) =
  createDir(extendedPath(fragmentDir))
  let path = fragmentPath(fragmentDir, record.osPid, record.threadId)
  var file: File
  if not open(file, extendedPath(path), fmAppend):
    raiseEnvelopeError(eeMalformed, "cannot open RMDF fragment for append: " & path)
  defer: close(file)
  let frame = encodeFrame(record)
  if frame.len > 0:
    discard file.writeBytes(frame, 0, frame.len)

proc readFragmentRecords*(path: string): seq[MonitorRecord] =
  let raw = readFile(extendedPath(path)).toBytes()
  decodeFrames(raw)

proc canonicalOrder(a, b: MonitorRecord): int =
  result = cmp(a.osPid, b.osPid)
  if result != 0: return
  result = cmp(a.threadId, b.threadId)
  if result != 0: return
  result = cmp(a.seq, b.seq)
  if result != 0: return
  result = cmp(ord(a.kind), ord(b.kind))
  if result != 0: return
  result = cmp(a.path, b.path)

proc summarizeRecords*(records: openArray[MonitorRecord]): MonitorSummary =
  result.recordCount = uint64(records.len)
  var processPids: seq[uint64] = @[]
  for record in records:
    if record.osPid != 0 and processPids.find(record.osPid) < 0:
      processPids.add(record.osPid)
    if record.kind == mrEventLoss or record.observationKind == moEventLoss:
      inc result.eventLossCount
    else:
      inc result.observationCount
  result.processCount = uint64(processPids.len)

proc depFileFromRecords*(records: openArray[MonitorRecord]): MonitorDepFile =
  let summary = summarizeRecords(records)
  var profile = profileFromRecords(records)
  if summary.eventLossCount != 0:
    profile.evidenceComplete = false
  MonitorDepFile(
    version: RmdfVersion,
    producerVersion: ReproMonitorDepfileProducer,
    backendFamily: profile.backendFamily,
    requiredFeatures: profile.requiredCapabilities,
    completeness: if profile.evidenceComplete and summary.eventLossCount == 0:
        mcComplete
      else:
        mcIncomplete,
    profile: profile,
    capabilityGaps: profile.gaps,
    summary: summary,
    records: @records)

proc encodeCanonical*(records: openArray[MonitorRecord]): seq[byte] =
  var ordered = @records
  ordered.sort(canonicalOrder)
  for i in 0 ..< ordered.len:
    ordered[i].seq = uint64(i + 1)

  var body: seq[byte] = @[]
  for record in ordered:
    body.add encodeFrame(record)

  result = @[]
  result.add RmdfMagic.toBytes()
  result.writeU16Le(RmdfVersion)
  result.writeU16Le(CanonicalFileKind)
  result.writeU64Le(uint64(ordered.len))
  result.writeU64Le(uint64(body.len))
  result.add body
  result.add RmdfTrailerMagic.toBytes()
  result.writeU64Le(uint64(ordered.len))
  result.writeU64Le(checksum(body))

proc mergeFragments*(fragmentDir, outputPath: string): MonitorDepFile =
  var records: seq[MonitorRecord] = @[]
  if dirExists(extendedPath(fragmentDir)):
    for kind, path in walkDir(extendedPath(fragmentDir)):
      if kind == pcFile and path.endsWith(".rmdf-frag"):
        records.add readFragmentRecords(path)
  records.add profileRecords(defaultHooksMonitorProfile(
    MacosMonitorShimTaxonomyCapabilities))

  let canonical = encodeCanonical(records)
  writeFile(extendedPath(outputPath), canonical.fromBytes())
  depFileFromRecords(records)

proc writeCanonical*(outputPath: string; records: openArray[MonitorRecord]) =
  let canonical = encodeCanonical(records)
  writeFile(extendedPath(outputPath), canonical.fromBytes())

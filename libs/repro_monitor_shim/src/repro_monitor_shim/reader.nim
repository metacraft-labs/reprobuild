import repro_core/codec
import repro_monitor_shim/types
import repro_monitor_shim/writer

proc readMonitorDepFile*(path: string): MonitorDepFile =
  let bytes = readFile(path).toBytes()
  if bytes.len < 44:
    raiseEnvelopeError(eeMalformed, "RMDF file is too short")
  if fromBytes(bytes.toOpenArray(0, 3)) != RmdfMagic:
    raiseEnvelopeError(eeUnknownMagic, "unknown RMDF magic")

  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != RmdfVersion:
    raiseEnvelopeError(eeUnsupportedVersion, "unsupported RMDF version")
  discard readU16Le(bytes, pos)
  let headerCount = readU64Le(bytes, pos)
  let bodyLen = int(readU64Le(bytes, pos))
  if pos + bodyLen + 20 != bytes.len:
    raiseEnvelopeError(eeMalformed, "RMDF body length/trailer mismatch")

  let bodyStart = pos
  let bodyEnd = bodyStart + bodyLen
  let body = bytes[bodyStart ..< bodyEnd]
  pos = bodyEnd
  if fromBytes(bytes.toOpenArray(pos, pos + 3)) != RmdfTrailerMagic:
    raiseEnvelopeError(eeMalformed, "missing RMDF trailer")
  pos += 4
  let trailerCount = readU64Le(bytes, pos)
  let trailerChecksum = readU64Le(bytes, pos)
  if trailerCount != headerCount:
    raiseEnvelopeError(eeMalformed, "RMDF record count mismatch")
  if trailerChecksum != checksum(body):
    raiseEnvelopeError(eeMalformed, "RMDF checksum mismatch")

  result.version = version
  result.records = decodeFrames(body)
  if uint64(result.records.len) != headerCount:
    raiseEnvelopeError(eeMalformed, "RMDF frame count mismatch")

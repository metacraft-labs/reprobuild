import cbor/types

proc fail(message: string) {.noreturn.} =
  raise newException(CborError, message)

proc readByte(bytes: openArray[byte]; pos: var int): byte =
  if pos >= bytes.len:
    fail("truncated CBOR")
  result = bytes[pos]
  inc pos

proc readLen(bytes: openArray[byte]; pos: var int; info: byte): uint64 =
  case info
  of 0 .. 23:
    result = uint64(info)
  of 24:
    result = uint64(readByte(bytes, pos))
  of 25:
    result = (uint64(readByte(bytes, pos)) shl 8) or uint64(readByte(bytes, pos))
  of 26:
    for _ in 0 ..< 4:
      result = (result shl 8) or uint64(readByte(bytes, pos))
  of 27:
    for _ in 0 ..< 8:
      result = (result shl 8) or uint64(readByte(bytes, pos))
  else:
    fail("indefinite CBOR lengths are unsupported")

proc readBytes(bytes: openArray[byte]; pos: var int; length: int): seq[byte] =
  if pos + length > bytes.len:
    fail("truncated CBOR byte string")
  result = newSeq[byte](length)
  for i in 0 ..< length:
    result[i] = bytes[pos + i]
  pos += length

proc readText(bytes: openArray[byte]; pos: var int; length: int): string =
  if pos + length > bytes.len:
    fail("truncated CBOR text string")
  result = newString(length)
  for i in 0 ..< length:
    result[i] = char(bytes[pos + i])
  pos += length

proc decodeValue(bytes: openArray[byte]; pos: var int): DynamicValue =
  let initial = readByte(bytes, pos)
  let major = initial shr 5
  let info = initial and 0x1f
  case major
  of 0:
    cborUInt(readLen(bytes, pos, info))
  of 2:
    cborBytes(readBytes(bytes, pos, int(readLen(bytes, pos, info))))
  of 3:
    cborText(readText(bytes, pos, int(readLen(bytes, pos, info))))
  of 4:
    let length = int(readLen(bytes, pos, info))
    var values = newSeq[DynamicValue](length)
    for i in 0 ..< length:
      values[i] = decodeValue(bytes, pos)
    cborArray(values)
  of 5:
    let length = int(readLen(bytes, pos, info))
    var entries = newSeq[DynamicMapEntry](length)
    for i in 0 ..< length:
      let key = decodeValue(bytes, pos)
      if key.kind != dvText:
        fail("minimal metadata maps require text keys")
      entries[i] = entry(key.textValue, decodeValue(bytes, pos))
    cborMap(entries)
  of 7:
    case info
    of 20: cborBool(false)
    of 21: cborBool(true)
    of 22: cborNull()
    else: fail("unsupported CBOR simple value")
  else:
    fail("unsupported CBOR major type")

proc decode*(bytes: openArray[byte]): DynamicValue =
  var pos = 0
  result = decodeValue(bytes, pos)
  if pos != bytes.len:
    fail("trailing CBOR bytes")

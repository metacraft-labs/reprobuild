import std/[algorithm]
import cbor/types

proc addTypeAndLen(outp: var seq[byte]; major: byte; length: uint64) =
  if length < 24:
    outp.add((major shl 5) or byte(length))
  elif length <= uint64(high(uint8)):
    outp.add((major shl 5) or 24)
    outp.add(byte(length))
  elif length <= uint64(high(uint16)):
    outp.add((major shl 5) or 25)
    outp.add(byte((length shr 8) and 0xff'u64))
    outp.add(byte(length and 0xff'u64))
  elif length <= uint64(high(uint32)):
    outp.add((major shl 5) or 26)
    for shift in [24, 16, 8, 0]:
      outp.add(byte((length shr shift) and 0xff'u64))
  else:
    outp.add((major shl 5) or 27)
    for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
      outp.add(byte((length shr shift) and 0xff'u64))

proc addText(outp: var seq[byte]; value: string) =
  outp.addTypeAndLen(3, uint64(value.len))
  for ch in value:
    outp.add(byte(ord(ch)))

proc encodeInto(outp: var seq[byte]; value: DynamicValue)

proc canonicalEntries(entries: seq[DynamicMapEntry]): seq[DynamicMapEntry] =
  result = entries
  result.sort(proc(a, b: DynamicMapEntry): int = cmp(a.key, b.key))

proc encodeInto(outp: var seq[byte]; value: DynamicValue) =
  case value.kind
  of dvNull:
    outp.add(0xf6'u8)
  of dvBool:
    outp.add(if value.boolValue: 0xf5'u8 else: 0xf4'u8)
  of dvUInt:
    outp.addTypeAndLen(0, value.uintValue)
  of dvBytes:
    outp.addTypeAndLen(2, uint64(value.bytesValue.len))
    outp.add(value.bytesValue)
  of dvText:
    outp.addText(value.textValue)
  of dvArray:
    outp.addTypeAndLen(4, uint64(value.arrayValue.len))
    for item in value.arrayValue:
      outp.encodeInto(item)
  of dvMap:
    let entries = canonicalEntries(value.mapValue)
    outp.addTypeAndLen(5, uint64(entries.len))
    for item in entries:
      outp.addText(item.key)
      outp.encodeInto(item.value)

proc encode*(value: DynamicValue): seq[byte] =
  result = @[]
  result.encodeInto(value)

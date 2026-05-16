type
  CborError* = object of CatchableError

  DynamicValueKind* = enum
    dvNull
    dvBool
    dvUInt
    dvBytes
    dvText
    dvArray
    dvMap

  DynamicMapEntry* = object
    key*: string
    value*: DynamicValue

  DynamicValue* = object
    case kind*: DynamicValueKind
    of dvNull:
      discard
    of dvBool:
      boolValue*: bool
    of dvUInt:
      uintValue*: uint64
    of dvBytes:
      bytesValue*: seq[byte]
    of dvText:
      textValue*: string
    of dvArray:
      arrayValue*: seq[DynamicValue]
    of dvMap:
      mapValue*: seq[DynamicMapEntry]

proc cborNull*(): DynamicValue =
  DynamicValue(kind: dvNull)

proc cborBool*(value: bool): DynamicValue =
  DynamicValue(kind: dvBool, boolValue: value)

proc cborUInt*(value: uint64): DynamicValue =
  DynamicValue(kind: dvUInt, uintValue: value)

proc cborBytes*(value: openArray[byte]): DynamicValue =
  DynamicValue(kind: dvBytes, bytesValue: @value)

proc cborText*(value: string): DynamicValue =
  DynamicValue(kind: dvText, textValue: value)

proc cborArray*(value: openArray[DynamicValue]): DynamicValue =
  DynamicValue(kind: dvArray, arrayValue: @value)

proc cborMap*(value: openArray[DynamicMapEntry]): DynamicValue =
  DynamicValue(kind: dvMap, mapValue: @value)

proc entry*(key: string; value: DynamicValue): DynamicMapEntry =
  DynamicMapEntry(key: key, value: value)

proc `==`*(a, b: DynamicMapEntry): bool {.noSideEffect.}

proc `==`*(a, b: DynamicValue): bool {.noSideEffect.} =
  if a.kind != b.kind:
    return false
  case a.kind
  of dvNull:
    true
  of dvBool:
    a.boolValue == b.boolValue
  of dvUInt:
    a.uintValue == b.uintValue
  of dvBytes:
    a.bytesValue == b.bytesValue
  of dvText:
    a.textValue == b.textValue
  of dvArray:
    a.arrayValue == b.arrayValue
  of dvMap:
    a.mapValue == b.mapValue

proc `==`*(a, b: DynamicMapEntry): bool {.noSideEffect.} =
  a.key == b.key and a.value == b.value

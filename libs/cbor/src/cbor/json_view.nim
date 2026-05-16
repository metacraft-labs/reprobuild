import std/strutils
import cbor/types

proc escapeJson(text: string): string =
  result = newStringOfCap(text.len + 2)
  for ch in text:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(ch)

proc bytesHex(bytes: openArray[byte]): string =
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii())

proc toJson*(value: DynamicValue): string =
  case value.kind
  of dvNull:
    "null"
  of dvBool:
    if value.boolValue: "true" else: "false"
  of dvUInt:
    $value.uintValue
  of dvBytes:
    "{\"bytes\":\"" & bytesHex(value.bytesValue) & "\"}"
  of dvText:
    "\"" & escapeJson(value.textValue) & "\""
  of dvArray:
    var parts: seq[string] = @[]
    for item in value.arrayValue:
      parts.add(toJson(item))
    "[" & parts.join(",") & "]"
  of dvMap:
    var parts: seq[string] = @[]
    for item in value.mapValue:
      parts.add("\"" & escapeJson(item.key) & "\":" & toJson(item.value))
    "{" & parts.join(",") & "}"

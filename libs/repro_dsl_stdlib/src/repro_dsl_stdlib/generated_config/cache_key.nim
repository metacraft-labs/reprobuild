## Cache-key computation for `fs.configFile`, `fs.writeStructured`, and
## `fs.managedBlock`. Per `Generated-Configuration-Files.md`:
##
##   store-key = BLAKE3-256(reprobuild-owned-bytes || resolved-configurable-inputs)
##
## For `owned` files: `reprobuild-owned-bytes` is the entire rendered
## content. For `merged` files: only the bytes between the sentinels.
##
## Resolved-configurable-inputs are encoded as length-prefixed
## `(scope-derived-name, value-kind, value-bytes)` triples in
## *sorted-by-scope-name* order to be invariant under configurable
## declaration order.

import std/[algorithm]

import blake3
import ../configurables

type
  ResolvedInput* = object
    name*: string
    value*: ConfigurableValue

  CacheKeyKind* = enum
    ckkOwned
      ## The cache key derives from the full rendered content plus the
      ## resolved-configurable-inputs.
    ckkManagedBlock
      ## The cache key derives from the block content (between sentinels,
      ## exclusive), the block id, the host file path, and the
      ## resolved-configurable-inputs.

proc writeU32Le(buf: var seq[byte]; v: uint32) =
  buf.add(byte(v and 0xFF'u32))
  buf.add(byte((v shr 8) and 0xFF'u32))
  buf.add(byte((v shr 16) and 0xFF'u32))
  buf.add(byte((v shr 24) and 0xFF'u32))

proc writeString(buf: var seq[byte]; s: string) =
  buf.writeU32Le(uint32(s.len))
  for ch in s: buf.add(byte(ord(ch)))

proc encodeValue(buf: var seq[byte]; v: ConfigurableValue) =
  buf.add(byte(ord(v.kind)))
  case v.kind
  of cvkBool:
    buf.add(if v.boolVal: 1'u8 else: 0'u8)
  of cvkInt:
    let u = cast[uint64](v.intVal)
    buf.writeU32Le(uint32(u and 0xFFFF_FFFF'u64))
    buf.writeU32Le(uint32((u shr 32) and 0xFFFF_FFFF'u64))
  of cvkString:
    buf.writeString(v.strVal)
  of cvkBytes:
    buf.writeU32Le(uint32(v.bytesVal.len))
    for b in v.bytesVal: buf.add(b)
  of cvkAny:
    # Object-typed configurables are not persisted into cache keys
    # directly; the caller must materialize them to a primitive form
    # before pushing them through cache. We stringify defensively.
    buf.writeString("<any>")

proc sortedInputsPayload(inputs: seq[ResolvedInput]): seq[byte] =
  var sorted = inputs
  sorted.sort(proc(a, b: ResolvedInput): int = cmp(a.name, b.name))
  result = @[]
  result.writeU32Le(uint32(sorted.len))
  for inp in sorted:
    result.writeString(inp.name)
    result.encodeValue(inp.value)

# ---------------------------------------------------------------------------
# Public cache-key computation
# ---------------------------------------------------------------------------

proc cacheKeyOwned*(content: openArray[byte];
                    inputs: seq[ResolvedInput]): array[32, byte] =
  ## CacheKeyKind = ckkOwned. The full content participates.
  ##
  ## Layout (LE u32 lengths throughout):
  ##   "RBCG-OWNED" magic (10 bytes)
  ##   <u32 content-length><content-bytes>
  ##   <inputs-payload>
  var payload: seq[byte] = @[]
  for ch in "RBCG-OWNED": payload.add(byte(ord(ch)))
  payload.writeU32Le(uint32(content.len))
  for b in content: payload.add(b)
  let inp = sortedInputsPayload(inputs)
  for b in inp: payload.add(b)
  blake3.digest(payload)

proc cacheKeyManagedBlock*(blockId, hostPath: string;
                           blockContent: openArray[byte];
                           inputs: seq[ResolvedInput]): array[32, byte] =
  ## CacheKeyKind = ckkManagedBlock. Field order:
  ##   "RBCG-MBLOCK" magic (11 bytes)
  ##   <u32 len><blockId>
  ##   <u32 len><hostPath>
  ##   <u32 len><blockContent>
  ##   <inputs-payload>
  ## NOTE: the host file's bytes outside the sentinels are NOT included.
  var payload: seq[byte] = @[]
  for ch in "RBCG-MBLOCK": payload.add(byte(ord(ch)))
  payload.writeString(blockId)
  payload.writeString(hostPath)
  payload.writeU32Le(uint32(blockContent.len))
  for b in blockContent: payload.add(b)
  let inp = sortedInputsPayload(inputs)
  for b in inp: payload.add(b)
  blake3.digest(payload)

proc hashContent*(content: openArray[byte]): array[32, byte] =
  blake3.digest(content)

proc toHex*(digest: array[32, byte]): string =
  result = newStringOfCap(64)
  const HEX = "0123456789abcdef"
  for b in digest:
    result.add HEX[int(b shr 4) and 0xF]
    result.add HEX[int(b) and 0xF]

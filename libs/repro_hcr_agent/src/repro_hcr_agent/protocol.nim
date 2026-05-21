import std/[json, strutils]

import repro_hcr_linkgraph

const
  HcrAgentProtocolSchemaId* = "reprobuild.hcr.agent-protocol.message.v1"
  HcrAgentProtocolVersion* = 1'u32
  HcrAgentTransportScope* = "hcr-agent-protocol"
  HcrPatchRequestSchemaId* = "reprobuild.hcr.agent-protocol.patch-request.v1"

type
  HcrPatchMode* = enum
    hpmDirect

  HcrAgentMessageKind* = enum
    hmkHello
    hmkHelloAck
    hmkPatchRequest
    hmkPatchApplied
    hmkPatchFailed
    hmkLifecycleEvent

  HcrProtocolPayload* = object
    digest*: string
    bytes*: seq[byte]

  HcrSourceGenerationEntry* = object
    sourcePath*: string
    generation*: uint32
    snapshotDigest*: string
    lineTableDigest*: string

  HcrHello* = object
    supportProfile*: string
    agentPid*: int
    capabilities*: seq[string]

  HcrPatchRequest* = object
    schemaId*: string
    patchId*: string
    supportProfile*: string
    mode*: HcrPatchMode
    changedFunctions*: seq[string]
    targetSymbols*: seq[string]
    directPatchPayload*: HcrProtocolPayload
    debugObjectPayload*: HcrProtocolPayload
    unwindMetadataPayload*: HcrProtocolPayload
    sourceGenerationMap*: seq[HcrSourceGenerationEntry]

  HcrPatchApplied* = object
    patchId*: string
    changedFunctions*: seq[string]
    symbolGeneration*: uint64
    debugObjectDigest*: string
    unwindMetadataDigest*: string
    sourceGenerationMapDigest*: string
    entryAddress*: string
    dispatchAddress*: string
    oldCodeRetained*: bool
    sharedLibraryPositivePath*: bool

  HcrPatchFailed* = object
    patchId*: string
    stage*: string
    message*: string

  HcrLifecycleEvent* = object
    patchId*: string
    event*: string
    sequence*: uint64

  HcrAgentMessage* = object
    schemaId*: string
    transportScope*: string
    protocolVersion*: uint32
    messageId*: string
    case kind*: HcrAgentMessageKind
    of hmkHello, hmkHelloAck:
      hello*: HcrHello
    of hmkPatchRequest:
      patchRequest*: HcrPatchRequest
    of hmkPatchApplied:
      patchApplied*: HcrPatchApplied
    of hmkPatchFailed:
      patchFailed*: HcrPatchFailed
    of hmkLifecycleEvent:
      lifecycleEvent*: HcrLifecycleEvent

proc kindName*(kind: HcrAgentMessageKind): string =
  case kind
  of hmkHello: "hello"
  of hmkHelloAck: "helloAck"
  of hmkPatchRequest: "patchRequest"
  of hmkPatchApplied: "patchApplied"
  of hmkPatchFailed: "patchFailed"
  of hmkLifecycleEvent: "lifecycleEvent"

proc patchModeName*(mode: HcrPatchMode): string =
  case mode
  of hpmDirect: "direct"

proc parseKind(value: string): HcrAgentMessageKind =
  case value
  of "hello": hmkHello
  of "helloAck": hmkHelloAck
  of "patchRequest": hmkPatchRequest
  of "patchApplied": hmkPatchApplied
  of "patchFailed": hmkPatchFailed
  of "lifecycleEvent": hmkLifecycleEvent
  else:
    raise newException(ValueError, "unknown HCR agent message kind: " & value)

proc parsePatchMode(value: string): HcrPatchMode =
  case value
  of "direct": hpmDirect
  else:
    raise newException(ValueError, "unsupported HCR patch mode: " & value)

proc payload*(bytes: openArray[byte]): HcrProtocolPayload =
  HcrProtocolPayload(digest: byteDigest(bytes), bytes: @bytes)

proc hexNibble(ch: char): byte =
  case ch
  of '0' .. '9': byte(ord(ch) - ord('0'))
  of 'a' .. 'f': byte(ord(ch) - ord('a') + 10)
  of 'A' .. 'F': byte(ord(ch) - ord('A') + 10)
  else:
    raise newException(ValueError, "invalid hex digit: " & $ch)

proc bytesFromHex*(hex: string): seq[byte] =
  if (hex.len mod 2) != 0:
    raise newException(ValueError, "hex payload has odd length")
  result = newSeq[byte](hex.len div 2)
  var i = 0
  while i < hex.len:
    result[i div 2] = byte((hexNibble(hex[i]) shl 4) or hexNibble(hex[i + 1]))
    i += 2

proc stringArray(values: openArray[string]): JsonNode =
  result = newJArray()
  for value in values:
    result.add newJString(value)

proc payloadJson(value: HcrProtocolPayload): JsonNode =
  %*{
    "digest": value.digest,
    "byteCount": value.bytes.len,
    "bytesHex": bytesHex(value.bytes)
  }

proc sourceGenerationJson(entry: HcrSourceGenerationEntry): JsonNode =
  %*{
    "sourcePath": entry.sourcePath,
    "generation": entry.generation,
    "snapshotDigest": entry.snapshotDigest,
    "lineTableDigest": entry.lineTableDigest
  }

proc helloJson(value: HcrHello): JsonNode =
  %*{
    "supportProfile": value.supportProfile,
    "agentPid": value.agentPid,
    "capabilities": stringArray(value.capabilities)
  }

proc patchRequestJson*(request: HcrPatchRequest): JsonNode =
  result = newJObject()
  result["schemaId"] = newJString(
    if request.schemaId.len == 0: HcrPatchRequestSchemaId else: request.schemaId)
  result["patchId"] = newJString(request.patchId)
  result["supportProfile"] = newJString(request.supportProfile)
  result["mode"] = newJString(request.mode.patchModeName)
  result["changedFunctions"] = stringArray(request.changedFunctions)
  result["targetSymbols"] = stringArray(request.targetSymbols)
  result["directPatchPayload"] = payloadJson(request.directPatchPayload)
  result["debugObjectPayload"] = payloadJson(request.debugObjectPayload)
  result["unwindMetadataPayload"] = payloadJson(request.unwindMetadataPayload)
  var generations = newJArray()
  for entry in request.sourceGenerationMap:
    generations.add sourceGenerationJson(entry)
  result["sourceGenerationMap"] = generations

proc patchAppliedJson(value: HcrPatchApplied): JsonNode =
  result = %*{
    "patchId": value.patchId,
    "changedFunctions": stringArray(value.changedFunctions),
    "symbolGeneration": value.symbolGeneration,
    "debugObjectDigest": value.debugObjectDigest,
    "unwindMetadataDigest": value.unwindMetadataDigest,
    "sourceGenerationMapDigest": value.sourceGenerationMapDigest,
    "oldCodeRetained": value.oldCodeRetained,
    "sharedLibraryPositivePath": value.sharedLibraryPositivePath
  }
  if value.dispatchAddress.len > 0:
    result["dispatchAddress"] = newJString(value.dispatchAddress)
  if value.entryAddress.len > 0:
    result["entryAddress"] = newJString(value.entryAddress)

proc patchFailedJson(value: HcrPatchFailed): JsonNode =
  %*{
    "patchId": value.patchId,
    "stage": value.stage,
    "message": value.message
  }

proc lifecycleEventJson(value: HcrLifecycleEvent): JsonNode =
  %*{
    "patchId": value.patchId,
    "event": value.event,
    "sequence": value.sequence
  }

proc agentMessageJson*(message: HcrAgentMessage): JsonNode =
  result = newJObject()
  result["schemaId"] = newJString(
    if message.schemaId.len == 0: HcrAgentProtocolSchemaId else: message.schemaId)
  result["transportScope"] = newJString(
    if message.transportScope.len == 0: HcrAgentTransportScope else: message.transportScope)
  result["protocolVersion"] = newJInt(BiggestInt(
    if message.protocolVersion == 0: HcrAgentProtocolVersion else: message.protocolVersion))
  result["messageId"] = newJString(message.messageId)
  result["kind"] = newJString(message.kind.kindName)
  case message.kind
  of hmkHello, hmkHelloAck:
    result["hello"] = helloJson(message.hello)
  of hmkPatchRequest:
    result["patch"] = patchRequestJson(message.patchRequest)
  of hmkPatchApplied:
    result["patchApplied"] = patchAppliedJson(message.patchApplied)
  of hmkPatchFailed:
    result["patchFailed"] = patchFailedJson(message.patchFailed)
  of hmkLifecycleEvent:
    result["lifecycleEvent"] = lifecycleEventJson(message.lifecycleEvent)

proc requireField(node: JsonNode; field: string): JsonNode =
  if not node.hasKey(field):
    raise newException(ValueError, "missing JSON field: " & field)
  node[field]

proc requireStr(node: JsonNode; field: string): string =
  let value = node.requireField(field)
  if value.kind != JString:
    raise newException(ValueError, "JSON field is not a string: " & field)
  value.getStr()

proc optionalStr(node: JsonNode; field: string): string =
  if node.hasKey(field) and node[field].kind != JNull:
    node[field].getStr()
  else:
    ""

proc requireInt(node: JsonNode; field: string): int =
  let value = node.requireField(field)
  if value.kind != JInt:
    raise newException(ValueError, "JSON field is not an integer: " & field)
  value.getInt()

proc requireBool(node: JsonNode; field: string): bool =
  let value = node.requireField(field)
  if value.kind != JBool:
    raise newException(ValueError, "JSON field is not a bool: " & field)
  value.getBool()

proc stringSeq(node: JsonNode; field: string): seq[string] =
  let values = node.requireField(field)
  if values.kind != JArray:
    raise newException(ValueError, "JSON field is not an array: " & field)
  for value in values:
    if value.kind != JString:
      raise newException(ValueError, "JSON array contains non-string: " & field)
    result.add value.getStr()

proc parsePayload(node: JsonNode; field: string): HcrProtocolPayload =
  let value = node.requireField(field)
  result.digest = value.requireStr("digest")
  result.bytes = bytesFromHex(value.requireStr("bytesHex"))
  if result.digest != byteDigest(result.bytes):
    raise newException(ValueError, "payload digest mismatch for " & field)
  if value.hasKey("byteCount") and value["byteCount"].kind == JInt and
      value["byteCount"].getInt() != result.bytes.len:
    raise newException(ValueError, "payload byteCount mismatch for " & field)

proc parseSourceGeneration(node: JsonNode): HcrSourceGenerationEntry =
  HcrSourceGenerationEntry(
    sourcePath: node.requireStr("sourcePath"),
    generation: uint32(node.requireInt("generation")),
    snapshotDigest: node.requireStr("snapshotDigest"),
    lineTableDigest: node.requireStr("lineTableDigest"))

proc parseSourceGenerationMap(node: JsonNode): seq[HcrSourceGenerationEntry] =
  let values = node.requireField("sourceGenerationMap")
  if values.kind != JArray:
    raise newException(ValueError, "sourceGenerationMap must be an array")
  for value in values:
    result.add parseSourceGeneration(value)

proc parseHello(node: JsonNode): HcrHello =
  HcrHello(
    supportProfile: node.requireStr("supportProfile"),
    agentPid: node.requireInt("agentPid"),
    capabilities: node.stringSeq("capabilities"))

proc parsePatchRequest*(node: JsonNode): HcrPatchRequest =
  result = HcrPatchRequest(
    schemaId: node.optionalStr("schemaId"),
    patchId: node.requireStr("patchId"),
    supportProfile: node.requireStr("supportProfile"),
    mode: parsePatchMode(node.requireStr("mode")),
    changedFunctions: node.stringSeq("changedFunctions"),
    targetSymbols: node.stringSeq("targetSymbols"),
    directPatchPayload: node.parsePayload("directPatchPayload"),
    debugObjectPayload: node.parsePayload("debugObjectPayload"),
    unwindMetadataPayload: node.parsePayload("unwindMetadataPayload"),
    sourceGenerationMap: node.parseSourceGenerationMap())
  if result.schemaId.len == 0:
    result.schemaId = HcrPatchRequestSchemaId

proc parsePatchApplied(node: JsonNode): HcrPatchApplied =
  HcrPatchApplied(
    patchId: node.requireStr("patchId"),
    changedFunctions: node.stringSeq("changedFunctions"),
    symbolGeneration: uint64(node.requireInt("symbolGeneration")),
    debugObjectDigest: node.requireStr("debugObjectDigest"),
    unwindMetadataDigest: node.requireStr("unwindMetadataDigest"),
    sourceGenerationMapDigest: node.requireStr("sourceGenerationMapDigest"),
    entryAddress: node.optionalStr("entryAddress"),
    dispatchAddress: node.optionalStr("dispatchAddress"),
    oldCodeRetained: node.requireBool("oldCodeRetained"),
    sharedLibraryPositivePath: node.requireBool("sharedLibraryPositivePath"))

proc parsePatchFailed(node: JsonNode): HcrPatchFailed =
  HcrPatchFailed(
    patchId: node.requireStr("patchId"),
    stage: node.requireStr("stage"),
    message: node.requireStr("message"))

proc parseLifecycleEvent(node: JsonNode): HcrLifecycleEvent =
  HcrLifecycleEvent(
    patchId: node.requireStr("patchId"),
    event: node.requireStr("event"),
    sequence: uint64(node.requireInt("sequence")))

proc parseAgentMessage*(node: JsonNode): HcrAgentMessage =
  let schemaId = node.requireStr("schemaId")
  if schemaId != HcrAgentProtocolSchemaId:
    raise newException(ValueError, "unsupported HCR agent schema: " & schemaId)
  let transportScope = node.requireStr("transportScope")
  if transportScope != HcrAgentTransportScope:
    raise newException(ValueError, "unsupported HCR transport scope: " & transportScope)
  let protocolVersion = uint32(node.requireInt("protocolVersion"))
  if protocolVersion != HcrAgentProtocolVersion:
    raise newException(ValueError, "unsupported HCR protocol version: " & $protocolVersion)
  let messageId = node.requireStr("messageId")
  let kind = parseKind(node.requireStr("kind"))

  case kind
  of hmkHello, hmkHelloAck:
    HcrAgentMessage(
      schemaId: schemaId,
      transportScope: transportScope,
      protocolVersion: protocolVersion,
      messageId: messageId,
      kind: kind,
      hello: parseHello(node.requireField("hello")))
  of hmkPatchRequest:
    HcrAgentMessage(
      schemaId: schemaId,
      transportScope: transportScope,
      protocolVersion: protocolVersion,
      messageId: messageId,
      kind: hmkPatchRequest,
      patchRequest: parsePatchRequest(node.requireField("patch")))
  of hmkPatchApplied:
    HcrAgentMessage(
      schemaId: schemaId,
      transportScope: transportScope,
      protocolVersion: protocolVersion,
      messageId: messageId,
      kind: hmkPatchApplied,
      patchApplied: parsePatchApplied(node.requireField("patchApplied")))
  of hmkPatchFailed:
    HcrAgentMessage(
      schemaId: schemaId,
      transportScope: transportScope,
      protocolVersion: protocolVersion,
      messageId: messageId,
      kind: hmkPatchFailed,
      patchFailed: parsePatchFailed(node.requireField("patchFailed")))
  of hmkLifecycleEvent:
    HcrAgentMessage(
      schemaId: schemaId,
      transportScope: transportScope,
      protocolVersion: protocolVersion,
      messageId: messageId,
      kind: hmkLifecycleEvent,
      lifecycleEvent: parseLifecycleEvent(node.requireField("lifecycleEvent")))

proc frameAgentMessage*(message: HcrAgentMessage): string =
  let body = $agentMessageJson(message)
  "Content-Length: " & $body.len & "\r\n\r\n" & body

proc parseFramedAgentMessage*(frame: string): HcrAgentMessage =
  let separator = "\r\n\r\n"
  let splitAt = frame.find(separator)
  if splitAt < 0:
    raise newException(ValueError, "missing HCR protocol frame separator")
  let header = frame[0 ..< splitAt]
  let body = frame[splitAt + separator.len .. ^1]
  const prefix = "Content-Length: "
  if not header.startsWith(prefix):
    raise newException(ValueError, "missing Content-Length header")
  let length = parseInt(header[prefix.len .. ^1].strip())
  if length != body.len:
    raise newException(ValueError, "Content-Length mismatch")
  parseAgentMessage(parseJson(body))

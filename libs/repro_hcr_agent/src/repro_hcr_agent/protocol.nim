import std/[base64, json, strutils]

import repro_hcr_linkgraph
import repro_hcr_agent/source_digest

export source_digest

const
  HcrAgentProtocolSchemaId* = "reprobuild.hcr.agent-protocol.message.v1"
  HcrAgentProtocolVersion* = 1'u32
  HcrAgentTransportScope* = "hcr-agent-protocol"
  HcrPatchRequestSchemaId* = "reprobuild.hcr.agent-protocol.patch-request.v1"

  HcrAgentProtocolVersionSourceReload* = 2'u32
    ## GDH design §4.4. `protocolVersion` 1 is the pre-`sourceChanged` wire;
    ## 2 is the wire that carries `sourceChanged` / `sourceReloadResult`. A
    ## `sourceChanged` at version 1 is refused BY NAME rather than parsed,
    ## because a host that silently accepted it would be a host the
    ## coordinator cannot tell apart from one that understands the message.

  HcrSourceReloadCapability* = "source-reload"
    ## Advertised in `HcrHello.capabilities` by a host that can apply one
    ## (design §4.4).

  HcrSourceChangedFirstGeneration* = 2'u32
    ## §4.3: `generation` 1 is the content the process STARTED with, so the
    ## first notification carries 2 and a literal 1 is never valid here. That
    ## is deliberate — it makes the `symbolGeneration: 1` hardcode
    ## (`repro_hcr_agent.c`) a protocol error on this wire instead of a
    ## plausible value.

  # §5.5's refusal vocabulary, spelled once so the host and the coordinator
  # cannot drift into two spellings of the same reason.
  HcrReloadReasonCapabilityNotNegotiated* = "capability-not-negotiated"
  HcrReloadReasonDigestMismatch* = "digest-mismatch"
  HcrReloadReasonDigestAlgorithmUnsupported* = "digest-algorithm-unsupported"
  HcrReloadReasonLineCountMismatch* = "line-count-mismatch"
  HcrReloadReasonLineTableMismatch* = "line-table-mismatch"
  HcrReloadReasonParseError* = "parse-error"
  HcrReloadReasonWriterRefused* = "writer-refused"
  HcrReloadReasonInstancesAliveHardReload* = "instances-alive-hard-reload"
  HcrReloadReasonUnsupportedEncoding* = "unsupported-content-encoding"
  HcrReloadReasonMultipleFilesUnsupported* = "multiple-changed-files-unsupported"

  # GDH-M8. `writer-refused` means the TRACE WRITER refused and nothing else;
  # the GDScript host used to answer it for six unrelated conditions, so a
  # check on that one string could not tell them apart. Additive — no existing
  # reason changes meaning. Kept in sync with the `REPRO_HCR_RELOAD_REASON_*`
  # block in `libs/repro_hcr_agent/c/repro_hcr_agent.h`.
  HcrReloadReasonScriptNotLoaded* = "script-not-loaded"
  HcrReloadReasonHostBusy* = "host-busy"
  HcrReloadReasonNoSafePoint* = "no-safe-point"
  HcrReloadReasonTraceClosed* = "trace-closed"
    ## Design §8.1's steps 4-6 failure: the trace had already committed to the
    ## new version, so the recorder CLOSED it with a recorded reason and the
    ## engine continues unreloaded. Unlike every other refusal here, the
    ## session is degraded rather than untouched.

  HcrReloadReasonCompileError* = "compile-error"
    ## GDH-M8b. The new content PARSES and ANALYZES and the compiler refuses
    ## it. It cannot be pre-checked: `GDScriptCompiler::compile` writes into a
    ## `GDScript`, so the only candidate to compile into is the live script the
    ## pre-check exists to protect. The host therefore finds out after the
    ## swap, which puts this in §8.1's steps-4-6 class — the trace is closed
    ## with the reason recorded in it and the engine is put back on the source
    ## it was running. Its own name rather than `parse-error` because the two
    ## have different consequences: `parse-error` means nothing was touched,
    ## and this one does not. `outcome` is `failed`, not `refused`.

  HcrMacosArm64DirectSupportProfile* =
    "macos-arm64-direct-hcr-in-codetracer-v1"
    ## The Mach-O/arm64 direct-patch profile (M26-M28).
  HcrLinuxX86_64DirectSupportProfile* = "linux-x86_64-elf-direct-hcr-v1"
    ## HLX-M0: the ELF/x86_64 direct-patch profile. Registered on the agent
    ## wire alongside the macOS profile; the two are not interchangeable and
    ## the session rejects a mismatch during negotiation. Must stay in sync
    ## with `REPRO_HCR_AGENT_SUPPORT_PROFILE_LINUX_X86_64` in
    ## `libs/repro_hcr_agent/c/repro_hcr_agent.h`.

proc defaultDirectSupportProfile*(): string =
  ## The profile a C agent compiled for this host advertises in its hello.
  ## Empty when the host has no direct-patch arm at all.
  when defined(macosx) and defined(arm64):
    HcrMacosArm64DirectSupportProfile
  elif defined(linux) and defined(amd64):
    HcrLinuxX86_64DirectSupportProfile
  else:
    ""

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
    hmkSourceChanged
    hmkSourceReloadResult

  HcrProtocolPayload* = object
    digest*: string
    bytes*: seq[byte]

  HcrSourceGenerationEntry* = object
    sourcePath*: string
    generation*: uint32
    snapshotDigest*: string
    lineTableDigest*: string

  HcrSourceContentEncoding* = enum
    ## §4.3. `inline` is the default and the only one this campaign writes:
    ## a `path` handle races the next edit, which would put v3's text in v2's
    ## slot — the exact misattribution the design exists to prevent. `path` is
    ## representable because §8.2 permits it once the digest is re-verified
    ## against the bytes read.
    hsceInline = "inline"
    hscePath = "path"

  HcrSourceChangedFile* = object
    ## §4.3's `changedFiles` element. The first four fields are
    ## `HcrSourceGenerationEntry`'s, name for name — the design's "no fourth
    ## vocabulary" rule.
    sourcePath*: string
    generation*: uint32
    snapshotDigest*: string
    lineTableDigest*: string
    lineCount*: uint32
    contentEncoding*: HcrSourceContentEncoding
    content*: seq[byte]

  HcrSourceChanged* = object
    reloadId*: string
    language*: string
    changedFiles*: seq[HcrSourceChangedFile]

  HcrSourceReloadOutcome* = enum
    hsroApplied = "applied"
    hsroRefused = "refused"
    hsroFailed = "failed"

  HcrSourceReloadAppliedFile* = object
    ## §4.3's `appliedFiles` element, plus three fields the design's sketch
    ## does not carry and GDH-M4/M5's gates need.
    ##
    ## `appliedDigest` and `appliedLineCount` are the host's OWN recomputation
    ## over the bytes it applied, not an echo of the request. That distinction
    ## is the whole difference between this acknowledgement and a chain of
    ## `success: true` (Verification-Harness-Traps §2): a host that echoed the
    ## coordinator's digest would report a byte-perfect apply for content it
    ## never looked at.
    ##
    ## `unpreservedState` is §5.3's list of what Godot's reload did NOT keep —
    ## static variables, `@export` metadata, pending coroutines. Reported,
    ## never silently absorbed (GDH-M5).
    sourcePath*: string
    generation*: uint32
    pathIndex*: uint64
    stepIndex*: uint64
    appliedDigest*: string
    appliedLineCount*: uint32
    unpreservedState*: seq[string]

  HcrSourceReloadRefusedFile* = object
    sourcePath*: string
    generation*: uint32
    reason*: string
    detail*: string

  HcrSourceReloadResult* = object
    reloadId*: string
    outcome*: HcrSourceReloadOutcome
    appliedFiles*: seq[HcrSourceReloadAppliedFile]
    refusedFiles*: seq[HcrSourceReloadRefusedFile]
    reason*: string

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

  HcrCodePatchEvent* = object
    ## HLX-M7 — what the agent did about the `CodePatchEvent` the protocol's
    ## §7.2 requires when the patched process is being recorded by MCR.
    ##
    ## The event itself lives in the trace; this is the agent's REPORT of it, so
    ## that a coordinator learns whether the recording carries the boundary and,
    ## when it does not, why.  Before HLX-M7 a patch applied under `ct-mcr
    ## record` and a patch applied outside one were indistinguishable to the
    ## client, which is how a missing code-patch event would go unnoticed twice.
    present*: bool          ## the agent emitted a `codePatchEvent` object
    recorded*: bool         ## the recorder accepted and published the event
    bridgePresent*: bool    ## `libct_interpose` was in the target process
    bridgeResult*: int      ## the bridge's own return code (negative = refused)
    hashSelfTest*: bool     ## the agent's SHA-256 passed its FIPS vectors
    publicationTier*: uint32  ## 1 = no quiescence, so the geid boundary is
                              ## approximate (design §6.1/§10.3)
    codeHashBefore*: string   ## "sha256:<hex>" over the patched byte range
    codeHashAfter*: string
    patchBundle*: string      ## "sha256:<hex>" over the direct-patch bytes
    claimHeld*: bool          ## this provider owns the window's claim (§10.1)

  HcrSkippedFunction* = object
    ## §10.1 — a function this patch did NOT touch, and the named reason.
    ## `"claimed-by-recorder"` means MCR already held bytes in the window, which
    ## is not a defect in the target and not a whole-patch failure; the claim
    ## map's rule ends "never to a silent skip", and this field is how the skip
    ## is not silent.
    function*: string
    reason*: string
    holder*: uint32
    windowAddress*: string

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
    codePatchEvent*: HcrCodePatchEvent
    skippedFunctions*: seq[HcrSkippedFunction]

  HcrPatchFailed* = object
    patchId*: string
    stage*: string
    message*: string
    skippedFunctions*: seq[HcrSkippedFunction]

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
    of hmkSourceChanged:
      sourceChanged*: HcrSourceChanged
    of hmkSourceReloadResult:
      sourceReloadResult*: HcrSourceReloadResult

proc kindName*(kind: HcrAgentMessageKind): string =
  case kind
  of hmkHello: "hello"
  of hmkHelloAck: "helloAck"
  of hmkPatchRequest: "patchRequest"
  of hmkPatchApplied: "patchApplied"
  of hmkPatchFailed: "patchFailed"
  of hmkLifecycleEvent: "lifecycleEvent"
  of hmkSourceChanged: "sourceChanged"
  of hmkSourceReloadResult: "sourceReloadResult"

proc requiresSourceReloadWire*(kind: HcrAgentMessageKind): bool =
  kind in {hmkSourceChanged, hmkSourceReloadResult}

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
  of "sourceChanged": hmkSourceChanged
  of "sourceReloadResult": hmkSourceReloadResult
  else:
    raise newException(ValueError, "unknown HCR agent message kind: " & value)

proc parseContentEncoding(value: string): HcrSourceContentEncoding =
  case value
  of "inline": hsceInline
  of "path": hscePath
  else:
    raise newException(ValueError,
      "unsupported sourceChanged contentEncoding: " & value)

proc parseSourceReloadOutcome(value: string): HcrSourceReloadOutcome =
  case value
  of "applied": hsroApplied
  of "refused": hsroRefused
  of "failed": hsroFailed
  else:
    raise newException(ValueError,
      "unsupported sourceReloadResult outcome: " & value)

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

proc sourceChangedFileJson(file: HcrSourceChangedFile): JsonNode =
  result = %*{
    "sourcePath": file.sourcePath,
    "generation": file.generation,
    "snapshotDigest": file.snapshotDigest,
    "lineTableDigest": file.lineTableDigest,
    "lineCount": file.lineCount,
    "contentEncoding": $file.contentEncoding
  }
  if file.contentEncoding == hsceInline:
    result["content"] = newJString(encode(file.content))

proc sourceChangedJson*(value: HcrSourceChanged): JsonNode =
  result = %*{
    "reloadId": value.reloadId,
    "language": value.language
  }
  var files = newJArray()
  for file in value.changedFiles:
    files.add sourceChangedFileJson(file)
  result["changedFiles"] = files

proc sourceReloadResultJson*(value: HcrSourceReloadResult): JsonNode =
  result = %*{
    "reloadId": value.reloadId,
    "outcome": $value.outcome,
    "reason": value.reason
  }
  var applied = newJArray()
  for file in value.appliedFiles:
    var entry = %*{
      "sourcePath": file.sourcePath,
      "generation": file.generation,
      "pathIndex": file.pathIndex,
      "stepIndex": file.stepIndex,
      "appliedDigest": file.appliedDigest,
      "appliedLineCount": file.appliedLineCount
    }
    entry["unpreservedState"] = stringArray(file.unpreservedState)
    applied.add entry
  result["appliedFiles"] = applied
  var refused = newJArray()
  for file in value.refusedFiles:
    refused.add(%*{
      "sourcePath": file.sourcePath,
      "generation": file.generation,
      "reason": file.reason,
      "detail": file.detail
    })
  result["refusedFiles"] = refused

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

proc codePatchEventJson(value: HcrCodePatchEvent): JsonNode =
  %*{
    "recorded": value.recorded,
    "bridgePresent": value.bridgePresent,
    "bridgeResult": value.bridgeResult,
    "hashSelfTest": value.hashSelfTest,
    "publicationTier": value.publicationTier,
    "codeHashBefore": value.codeHashBefore,
    "codeHashAfter": value.codeHashAfter,
    "patchBundle": value.patchBundle,
    "claimHeld": value.claimHeld
  }

proc skippedFunctionsJson(values: seq[HcrSkippedFunction]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%*{
      "function": value.function,
      "reason": value.reason,
      "holder": value.holder,
      "windowAddress": value.windowAddress
    })

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
  if value.codePatchEvent.present:
    result["codePatchEvent"] = codePatchEventJson(value.codePatchEvent)
  if value.skippedFunctions.len > 0:
    result["skippedFunctions"] = skippedFunctionsJson(value.skippedFunctions)

proc patchFailedJson(value: HcrPatchFailed): JsonNode =
  result = %*{
    "patchId": value.patchId,
    "stage": value.stage,
    "message": value.message
  }
  if value.skippedFunctions.len > 0:
    result["skippedFunctions"] = skippedFunctionsJson(value.skippedFunctions)

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
  of hmkSourceChanged:
    result["sourceChanged"] = sourceChangedJson(message.sourceChanged)
  of hmkSourceReloadResult:
    result["sourceReloadResult"] =
      sourceReloadResultJson(message.sourceReloadResult)

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

proc parseCodePatchEvent(node: JsonNode): HcrCodePatchEvent =
  ## Absent means the agent did not attempt a code-patch event at all (a
  ## non-Linux arm).  Present-but-`recorded: false` is a DIFFERENT statement:
  ## the agent tried and the recorder did not take it.  The two must not
  ## collapse into one, because only the second is ever a defect.
  if not node.hasKey("codePatchEvent") or
      node["codePatchEvent"].kind != JObject:
    return HcrCodePatchEvent(present: false)
  let value = node["codePatchEvent"]
  HcrCodePatchEvent(
    present: true,
    recorded: value.requireBool("recorded"),
    bridgePresent: value.requireBool("bridgePresent"),
    bridgeResult: value.requireInt("bridgeResult"),
    hashSelfTest: value.requireBool("hashSelfTest"),
    publicationTier: uint32(value.requireInt("publicationTier")),
    codeHashBefore: value.requireStr("codeHashBefore"),
    codeHashAfter: value.requireStr("codeHashAfter"),
    patchBundle: value.requireStr("patchBundle"),
    claimHeld: value.requireBool("claimHeld"))

proc parseSkippedFunctions(node: JsonNode): seq[HcrSkippedFunction] =
  if not node.hasKey("skippedFunctions") or
      node["skippedFunctions"].kind != JArray:
    return @[]
  for value in node["skippedFunctions"]:
    result.add HcrSkippedFunction(
      function: value.requireStr("function"),
      reason: value.requireStr("reason"),
      holder: uint32(value.requireInt("holder")),
      windowAddress: value.optionalStr("windowAddress"))

proc parsePatchApplied(node: JsonNode): HcrPatchApplied =
  HcrPatchApplied(
    codePatchEvent: parseCodePatchEvent(node),
    skippedFunctions: parseSkippedFunctions(node),
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
    message: node.requireStr("message"),
    skippedFunctions: parseSkippedFunctions(node))

proc requireUint32(node: JsonNode; field: string): uint32 =
  let value = node.requireInt(field)
  if value < 0:
    raise newException(ValueError, "JSON field is negative: " & field)
  uint32(value)

proc requireUint64(node: JsonNode; field: string): uint64 =
  let value = node.requireField(field)
  if value.kind != JInt:
    raise newException(ValueError, "JSON field is not an integer: " & field)
  let raw = value.getBiggestInt()
  if raw < 0:
    raise newException(ValueError, "JSON field is negative: " & field)
  uint64(raw)

proc parseSourceChangedFile(node: JsonNode): HcrSourceChangedFile =
  result = HcrSourceChangedFile(
    sourcePath: node.requireStr("sourcePath"),
    generation: node.requireUint32("generation"),
    snapshotDigest: node.requireStr("snapshotDigest"),
    lineTableDigest: node.requireStr("lineTableDigest"),
    lineCount: node.requireUint32("lineCount"),
    contentEncoding: parseContentEncoding(node.requireStr("contentEncoding")))

  # §4.3: generation 1 is the content the process STARTED with, so the first
  # notification carries 2. A literal 1 here is not a plausible value that
  # happens to be wrong; it is the `symbolGeneration: 1` hardcode arriving on
  # a wire that can name it. Refusing it by name is the whole reason the
  # numbering starts where it does.
  if result.generation < HcrSourceChangedFirstGeneration:
    raise newException(ValueError,
      "sourceChanged generation must be >= " &
        $HcrSourceChangedFirstGeneration & " (1 is the content the process " &
        "started with, so it is never a valid notification generation); got " &
        $result.generation & " for " & result.sourcePath)
  # §4.3: `lineCount` is mandatory because `registerPath` under bit 14 refuses
  # a path with no count. Zero is the shape of a caller that could not count.
  if result.lineCount == 0:
    raise newException(ValueError,
      "sourceChanged lineCount must be non-zero for " & result.sourcePath)
  if result.sourcePath.len == 0:
    raise newException(ValueError, "sourceChanged file has empty sourcePath")

  case result.contentEncoding
  of hsceInline:
    if not node.hasKey("content") or node["content"].kind != JString:
      raise newException(ValueError,
        "sourceChanged contentEncoding is inline but no content is present " &
          "for " & result.sourcePath)
    let decoded = decode(node["content"].getStr())
    result.content = bytesOfString(decoded)
  of hscePath:
    if node.hasKey("content") and node["content"].kind == JString and
        node["content"].getStr().len > 0:
      raise newException(ValueError,
        "sourceChanged contentEncoding is path but content bytes travelled " &
          "with it for " & result.sourcePath)

proc parseSourceChanged(node: JsonNode): HcrSourceChanged =
  result = HcrSourceChanged(
    reloadId: node.requireStr("reloadId"),
    language: node.requireStr("language"))
  if result.reloadId.len == 0:
    raise newException(ValueError, "sourceChanged has empty reloadId")
  let files = node.requireField("changedFiles")
  if files.kind != JArray:
    raise newException(ValueError, "changedFiles must be an array")
  if files.len == 0:
    # An empty notification is indistinguishable from a notification that was
    # dropped on the way, and would let a host answer `applied` having done
    # nothing at all.
    raise newException(ValueError, "sourceChanged has no changed files")
  for file in files:
    result.changedFiles.add parseSourceChangedFile(file)

proc parseSourceReloadResult(node: JsonNode): HcrSourceReloadResult =
  result = HcrSourceReloadResult(
    reloadId: node.requireStr("reloadId"),
    outcome: parseSourceReloadOutcome(node.requireStr("outcome")),
    reason: node.optionalStr("reason"))
  if result.reloadId.len == 0:
    raise newException(ValueError, "sourceReloadResult has empty reloadId")

  let applied = node.requireField("appliedFiles")
  if applied.kind != JArray:
    raise newException(ValueError, "appliedFiles must be an array")
  for entry in applied:
    let file = HcrSourceReloadAppliedFile(
      sourcePath: entry.requireStr("sourcePath"),
      generation: entry.requireUint32("generation"),
      pathIndex: entry.requireUint64("pathIndex"),
      stepIndex: entry.requireUint64("stepIndex"),
      appliedDigest: entry.optionalStr("appliedDigest"),
      appliedLineCount: entry.requireUint32("appliedLineCount"),
      unpreservedState:
        if entry.hasKey("unpreservedState"): entry.stringSeq("unpreservedState")
        else: @[])
    # The same rule as on the request side, and it is here that it bites: a
    # host that answers with a hardcoded generation `1` is refused BY NAME
    # instead of being read as "the first reload, which is fine".
    if file.generation < HcrSourceChangedFirstGeneration:
      raise newException(ValueError,
        "sourceReloadResult acknowledged generation " & $file.generation &
          " for " & file.sourcePath & ", but generation 1 is the content the " &
          "process started with and can never be the result of a reload")
    if file.appliedLineCount == 0:
      raise newException(ValueError,
        "sourceReloadResult reports an applied file with no lines: " &
          file.sourcePath)
    # ADDED AT REVIEW. `appliedDigest` is the host's OWN recomputation over the
    # bytes it applied — the whole difference between this acknowledgement and
    # a chain of `success: true` (Verification-Harness-Traps §2). Leaving it
    # optional made exactly one shape representable: a host whose digest
    # computation FAILED, answering `applied` with the evidence field empty and
    # every other field intact. That is "report success when you failed to
    # observe", and the parser refused the neighbouring shapes
    # (`applied` with no files, an applied file with no lines) while letting
    # this one through. It must carry an `<alg>:<hex>` tag, because an untagged
    # digest cannot be recomputed by the reader and so is not one.
    if file.appliedDigest.len == 0:
      raise newException(ValueError,
        "sourceReloadResult reports " & file.sourcePath & " as applied with " &
          "an empty appliedDigest. That field is the host's recomputation " &
          "over the bytes it applied; without it the acknowledgement asserts " &
          "an apply it offers no evidence for")
    if digestAlgorithmOf(file.appliedDigest).len == 0:
      raise newException(ValueError,
        "sourceReloadResult appliedDigest \"" & file.appliedDigest &
          "\" for " & file.sourcePath & " carries no \"<alg>:<hex>\" tag, so " &
          "no reader can recompute it")
    result.appliedFiles.add file

  let refused = node.requireField("refusedFiles")
  if refused.kind != JArray:
    raise newException(ValueError, "refusedFiles must be an array")
  for entry in refused:
    let file = HcrSourceReloadRefusedFile(
      sourcePath: entry.requireStr("sourcePath"),
      generation: entry.requireUint32("generation"),
      reason: entry.requireStr("reason"),
      detail: entry.optionalStr("detail"))
    if file.reason.len == 0:
      raise newException(ValueError,
        "a refused file must carry a named reason: " & file.sourcePath)
    result.refusedFiles.add file

  # §4.3: `reason` is non-empty iff the outcome is not `applied`.
  case result.outcome
  of hsroApplied:
    if result.reason.len != 0:
      raise newException(ValueError,
        "sourceReloadResult outcome is applied but carries reason: " &
          result.reason)
    if result.appliedFiles.len == 0:
      # "Applied, with nothing applied" is the chain-of-`success: true` shape
      # trap 2 exists for. It is refused at the parser so no consumer has to
      # remember to check.
      raise newException(ValueError,
        "sourceReloadResult outcome is applied but appliedFiles is empty")
    if result.refusedFiles.len != 0:
      raise newException(ValueError,
        "sourceReloadResult outcome is applied but files were refused; " &
          "§5.5 makes refusal per file and atomic, so a mixed result must " &
          "not be reported as applied")
  of hsroRefused, hsroFailed:
    if result.reason.len == 0:
      raise newException(ValueError,
        "sourceReloadResult outcome is " & $result.outcome &
          " but carries no reason")

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
  if protocolVersion != HcrAgentProtocolVersion and
      protocolVersion != HcrAgentProtocolVersionSourceReload:
    raise newException(ValueError, "unsupported HCR protocol version: " & $protocolVersion)
  let messageId = node.requireStr("messageId")
  let kind = parseKind(node.requireStr("kind"))
  # Design §4.4. The source-reload messages exist only on version 2. A version-1
  # peer that met one and parsed it anyway would be indistinguishable, from the
  # other end, from a peer that understood it.
  if kind.requiresSourceReloadWire() and
      protocolVersion < HcrAgentProtocolVersionSourceReload:
    raise newException(ValueError,
      kind.kindName & " requires protocolVersion " &
        $HcrAgentProtocolVersionSourceReload & ", got " & $protocolVersion)

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
  of hmkSourceChanged:
    HcrAgentMessage(
      schemaId: schemaId,
      transportScope: transportScope,
      protocolVersion: protocolVersion,
      messageId: messageId,
      kind: hmkSourceChanged,
      sourceChanged: parseSourceChanged(node.requireField("sourceChanged")))
  of hmkSourceReloadResult:
    HcrAgentMessage(
      schemaId: schemaId,
      transportScope: transportScope,
      protocolVersion: protocolVersion,
      messageId: messageId,
      kind: hmkSourceReloadResult,
      sourceReloadResult:
        parseSourceReloadResult(node.requireField("sourceReloadResult")))

proc sourceChangedFile*(sourcePath: string; generation: uint32;
                        content: openArray[byte]): HcrSourceChangedFile =
  ## Build a §4.3 `changedFiles` entry from the bytes themselves, so the three
  ## digest/count fields cannot disagree with the content they describe.
  HcrSourceChangedFile(
    sourcePath: sourcePath,
    generation: generation,
    snapshotDigest: sourceSnapshotDigest(content),
    lineTableDigest: sourceLineTableDigest(content),
    lineCount: sourceLineCount(content),
    contentEncoding: hsceInline,
    content: @content)

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

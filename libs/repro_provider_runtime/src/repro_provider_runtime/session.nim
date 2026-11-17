## RP2 (Project-Provider-Runtime-Protocol.milestones.org) — the runtime
## provider-SESSION protocol (Provider-Runtime-Protocol-v1.md §2-4).
##
## This module turns the pre-RP2 one-process-per-invocation, file-based
## provider protocol into a long-lived stdio SESSION: the engine launches a
## materialized provider binary once, performs the EngineHello /
## ProviderManifest handshake, and then invokes entry points over the wire
## across the session's lifetime — reused across the many consumer edges that
## bind the same provider within a build.
##
## Transport + framing (v1 §2): stdio between engine (parent) and provider
## (child). Each frame is ``u32le length`` + ``u16le messageType`` + payload
## bytes, where ``length`` counts the ``u16le messageType`` + payload. One
## request → one response; synchronous per session.
##
## The frame length is bounded by a value the two ends negotiate in the
## handshake, and a reader allocates only as bytes arrive
## (Low-Level-Provider-Protocol.md §2.1). On the provider side the protocol
## travels on private descriptors, not on the fd 0 / fd 1 recipe code uses
## (``protocol_channel``, §2.2); on the engine side the provider's stderr is
## drained for the session's life (``stderr_drain``). A framing error, an
## unexpected end of stream or a failed write tears the session down and is
## reported with the provider's exit status and stderr tail (§2.6).
##
## Codec (v1 §2): typed arg/result payloads travel as ``BoxedValue =
## (typeId: string, jsonStr: string)`` pairs, marshalled via the
## Typed-Graph-Extensions ``registerExtension`` registry. This module is
## transport-only and stays free of the DSL dependency (``repro_project_dsl``
## imports ``repro_provider_runtime``, not the reverse): it moves the already
## marshalled ``(typeId, jsonStr)`` pairs across the boundary. The provider
## side (``runtime_provider.nim``, inside the DSL) links the registry and does
## the typed marshal/unmarshal; the engine side marshals through the same
## registry at its call boundary.
##
## Message set (v1 §3, MVP subset): EngineHello, ProviderManifest,
## InvokeEntryPoint{entryPointId, args:[BoxedValue]}, EntryPointResult{ok,
## value?:BoxedValue, evaluationInputs:[ObservedInput], diagnostics:[Diag]}.
## BindDependencies is RP3; the ``dependencyBindings`` field is carried but
## unused in RP2.

import std/[os, osproc, streams, strutils]

import repro_core
import repro_core/portable_release_launch
import repro_hash
import repro_provider_runtime/types
import repro_provider_runtime/stderr_drain

type
  ProviderSessionError* = object of CatchableError
  ProviderSessionClosed* = object of ProviderSessionError
    ## End of stream exactly at a frame boundary: the peer closed the
    ## session. Whether that is a clean shutdown or a lost peer depends on
    ## whether a frame was due (Low-Level-Provider-Protocol.md §2.6).

  SessionMessageType* = enum
    ## The v1 §3 message set. BindDependencies (RP3) wires dependency handles
    ## into a provider session between the ProviderManifest handshake and the
    ## first InvokeEntryPoint.
    smtEngineHello = 1'u16
    smtProviderManifest = 2'u16
    smtBindDependencies = 5'u16
    smtBindDependenciesAck = 6'u16
    smtInvokeEntryPoint = 3'u16
    smtEntryPointResult = 4'u16

  BoxedValue* = object
    ## v1 §2 payload codec: a typed value marshalled via the
    ## Typed-Graph-Extensions ``registerExtension`` registry as an opaque
    ## ``(typeId, jsonStr)`` pair. The transport moves the pair; the two ends
    ## rehydrate it through the shared registry.
    typeId*: string
    jsonStr*: string

  SessionDiagnostic* = object
    severity*: string
    message*: string

  EngineHello* = object
    ## v1 §3 EngineHello. Sent first by the engine at session open.
    protocolVersion*: uint32
    engineCapabilities*: seq[string]
    lockSliceId*: string
    canonicalExecutionRoot*: string
    maxFrameLength*: uint32
      ## The largest frame the engine sends or accepts. 0 when building a
      ## hello means "the default", ``ProviderSessionMaxFrameLength``; on the
      ## wire it is always the explicit value (Low-Level-Provider-Protocol.md
      ## §2.1).

  InvokeEntryPoint* = object
    ## v1 §3 InvokeEntryPoint. entryPointId names a manifest entry point; the
    ## args are the marshalled BoxedValues the provider unmarshals. RP3 adds
    ## cross-provider ``dependencyBindings`` (carried, unused in RP2).
    entryPointId*: string
    args*: seq[BoxedValue]
    dependencyBindings*: seq[BoxedValue]

  EntryPointResult* = object
    ## v1 §3 EntryPointResult. ``ok`` gates ``value``; ``evaluationInputs``
    ## carry the provider's observed/declared inputs back across the boundary
    ## (consumer-edge invalidation, RP3-consumed).
    ok*: bool
    value*: BoxedValue
    hasValue*: bool
    evaluationInputs*: seq[GraphEvaluationInput]
    diagnostics*: seq[SessionDiagnostic]

  DependencyBinding* = object
    ## v1 §4 BindDependencies entry: the engine wires ONE dependency handle
    ## into a consumer's provider session under a ``logicalDependencyName``.
    ##
    ## The engine resolves the dependency's realization FIRST (opening/REUSING
    ## the dependency's provider session through the shared pool, keyed by
    ## ProviderArtifactId and lock slice — this is where two consumers of the
    ## same library version, under the same slice, converge on ONE launched
    ## dependency provider), then hands the
    ## consumer the dependency's identities plus its already-computed result.
    ## The consumer provider looks bindings up by ``logicalName``; it NEVER
    ## discovers a sibling through ambient/global state. The provider does not
    ## know whether the handle is backed by a local process, a remote worker,
    ## or (as in the v1 synchronous-stdio case) a precomputed static result.
    logicalName*: string
    providerArtifactId*: string
      ## The dependency's RP1 content-addressed id — the same across two
      ## consumers that resolve the same dependency version.
    providerSessionKey*: string
      ## The dependency's RP2 ProviderSessionKey — the live session both
      ## consumers share.
    entryPointId*: string
      ## The dependency entry point whose result is bound (v1: the dependency
      ## root fragment producer).
    hasResult*: bool
    result*: BoxedValue
      ## The dependency's already-computed result the consumer invokes
      ## "through" (v1 synchronous-stdio: the engine precomputes it on the
      ## shared session and binds the value; a future transport lets the
      ## provider call back live). Gated by ``hasResult``.
    evaluationInputs*: seq[GraphEvaluationInput]
      ## The dependency's observed inputs (files read, locks), carried so the
      ## consumer edge invalidates when the dependency's realization changes
      ## (v1 §3 observed-input propagation).

  BindDependencies* = object
    ## v1 §4 BindDependencies message. Sent by the engine after the
    ## ProviderManifest handshake and before InvokeEntryPoint.
    bindings*: seq[DependencyBinding]

const
  ## The stdio-serve invocation flag the provider binary recognizes to enter
  ## the RP2 session serve loop (instead of the file-based single-shot path).
  ProviderServeFlag* = "--repro-provider-serve"

  ProviderSessionMaxFrameLength* = 256'u32 * 1024 * 1024
    ## The largest frame ``length`` either side offers by default
    ## (Low-Level-Provider-Protocol.md §2.1). Large enough for any graph
    ## fragment seen in practice; a frame above the negotiated bound is
    ## refused before anything sized by it is allocated.
  ProviderSessionMinFrameLength* = 64'u32 * 1024
    ## An offer below this is malformed: no useful session fits in it.
  ProviderSessionHelloFrameLength* = 1'u32 * 1024 * 1024
    ## The bound on the ``EngineHello`` frame, which is read before any
    ## bound has been negotiated.
  FrameReadChunk = 64 * 1024
    ## A frame is read in chunks of this size, so a length the stream never
    ## delivers costs only the bytes that did arrive.

proc raiseSession(message: string) {.noreturn.} =
  raise newException(ProviderSessionError, message)

# --------------------------------------------------------------------------
# BoxedValue + payload field codecs
# --------------------------------------------------------------------------

proc writeBoxedValue(outp: var seq[byte]; value: BoxedValue) =
  outp.writeString(value.typeId)
  outp.writeString(value.jsonStr)

proc readBoxedValue(bytes: openArray[byte]; pos: var int): BoxedValue =
  BoxedValue(typeId: readString(bytes, pos), jsonStr: readString(bytes, pos))

proc writeBoxedValueSeq(outp: var seq[byte]; values: openArray[BoxedValue]) =
  outp.writeU32Le(uint32(values.len))
  for value in values:
    outp.writeBoxedValue(value)

proc readBoxedValueSeq(bytes: openArray[byte]; pos: var int): seq[BoxedValue] =
  let count = readElementCount(bytes, pos, 8)
  result = newSeq[BoxedValue](count)
  for i in 0 ..< count:
    result[i] = readBoxedValue(bytes, pos)

proc evaluationInputKindOf(value: byte): GraphEvaluationInputKind =
  if value > byte(ord(gevActivitySelection)):
    raiseEnvelopeError(eeMalformed, "invalid graph evaluation input kind")
  GraphEvaluationInputKind(value)

proc writeEvalInput(outp: var seq[byte]; value: GraphEvaluationInput) =
  outp.add(byte(ord(value.kind)))
  outp.writeString(value.identity)
  outp.writeString(value.digest)
  outp.writeU32Le(uint32(value.directoryMembers.len))
  for member in value.directoryMembers:
    outp.writeString(member)
  outp.writeString(value.memberEntryPointId)
  outp.writeString(value.memberEntryPointBodyHash)
  outp.writeString(value.memberArgumentRoot)
  outp.writeString(value.memberNamespace)

proc readEvalInput(bytes: openArray[byte]; pos: var int): GraphEvaluationInput =
  if pos >= bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated evaluation input")
  let kindByte = bytes[pos]
  inc pos
  result.kind = evaluationInputKindOf(kindByte)
  result.identity = readString(bytes, pos)
  result.digest = readString(bytes, pos)
  let members = readElementCount(bytes, pos, 4)
  result.directoryMembers = newSeq[string](members)
  for i in 0 ..< members:
    result.directoryMembers[i] = readString(bytes, pos)
  result.memberEntryPointId = readString(bytes, pos)
  result.memberEntryPointBodyHash = readString(bytes, pos)
  result.memberArgumentRoot = readString(bytes, pos)
  result.memberNamespace = readString(bytes, pos)

# --------------------------------------------------------------------------
# Message payload codecs
# --------------------------------------------------------------------------

proc encodeEngineHello*(value: EngineHello): seq[byte] =
  result.writeU32Le(value.protocolVersion)
  result.writeU32Le(uint32(value.engineCapabilities.len))
  for cap in value.engineCapabilities:
    result.writeString(cap)
  result.writeString(value.lockSliceId)
  result.writeString(value.canonicalExecutionRoot)
  result.writeU32Le(value.maxFrameLength)

proc decodeEngineHello*(bytes: openArray[byte]): EngineHello =
  var pos = 0
  result.protocolVersion = readU32Le(bytes, pos)
  let caps = readElementCount(bytes, pos, 4)
  result.engineCapabilities = newSeq[string](caps)
  for i in 0 ..< caps:
    result.engineCapabilities[i] = readString(bytes, pos)
  result.lockSliceId = readString(bytes, pos)
  result.canonicalExecutionRoot = readString(bytes, pos)
  result.maxFrameLength = readU32Le(bytes, pos)

proc encodeProviderManifestMsg*(value: ProviderManifest): seq[byte] =
  result.writeString(value.providerArtifactId)
  result.writeU32Le(value.protocolVersion)
  result.writeU32Le(uint32(value.entryPoints.len))
  for descriptor in value.entryPoints:
    result.writeString(descriptor.id)
    result.add(byte(ord(descriptor.kind)))
    result.writeString(descriptor.stableName)
    result.writeString(descriptor.bodyHash)
    result.writeString(descriptor.argumentSchemaId)
    result.writeString(descriptor.outputSchemaId)
  result.writeU32Le(value.maxFrameLength)

proc decodeProviderManifestMsg*(bytes: openArray[byte]): ProviderManifest =
  var pos = 0
  result.providerArtifactId = readString(bytes, pos)
  result.protocolVersion = readU32Le(bytes, pos)
  let count = readElementCount(bytes, pos, 4)
  result.entryPoints = newSeq[GraphEntryPointDescriptor](count)
  for i in 0 ..< count:
    result.entryPoints[i].id = readString(bytes, pos)
    if pos >= bytes.len:
      raiseEnvelopeError(eeMalformed, "truncated entry point kind")
    let kindByte = bytes[pos]
    inc pos
    if kindByte > byte(ord(gpkDevEnvIntrospection)):
      raiseEnvelopeError(eeMalformed, "invalid entry point kind")
    result.entryPoints[i].kind = GraphEntryPointKind(kindByte)
    result.entryPoints[i].stableName = readString(bytes, pos)
    result.entryPoints[i].bodyHash = readString(bytes, pos)
    result.entryPoints[i].argumentSchemaId = readString(bytes, pos)
    result.entryPoints[i].outputSchemaId = readString(bytes, pos)
  result.maxFrameLength = readU32Le(bytes, pos)

proc encodeInvokeEntryPoint*(value: InvokeEntryPoint): seq[byte] =
  result.writeString(value.entryPointId)
  result.writeBoxedValueSeq(value.args)
  result.writeBoxedValueSeq(value.dependencyBindings)

proc decodeInvokeEntryPoint*(bytes: openArray[byte]): InvokeEntryPoint =
  var pos = 0
  result.entryPointId = readString(bytes, pos)
  result.args = readBoxedValueSeq(bytes, pos)
  result.dependencyBindings = readBoxedValueSeq(bytes, pos)

proc encodeEntryPointResult*(value: EntryPointResult): seq[byte] =
  result.add(if value.ok: 1'u8 else: 0'u8)
  result.add(if value.hasValue: 1'u8 else: 0'u8)
  if value.hasValue:
    result.writeBoxedValue(value.value)
  result.writeU32Le(uint32(value.evaluationInputs.len))
  for input in value.evaluationInputs:
    result.writeEvalInput(input)
  result.writeU32Le(uint32(value.diagnostics.len))
  for diag in value.diagnostics:
    result.writeString(diag.severity)
    result.writeString(diag.message)

proc decodeEntryPointResult*(bytes: openArray[byte]): EntryPointResult =
  var pos = 0
  if pos + 2 > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated entry point result flags")
  result.ok = bytes[pos] != 0'u8
  inc pos
  result.hasValue = bytes[pos] != 0'u8
  inc pos
  if result.hasValue:
    result.value = readBoxedValue(bytes, pos)
  let inputs = readElementCount(bytes, pos, 4)
  result.evaluationInputs = newSeq[GraphEvaluationInput](inputs)
  for i in 0 ..< inputs:
    result.evaluationInputs[i] = readEvalInput(bytes, pos)
  let diags = readElementCount(bytes, pos, 4)
  result.diagnostics = newSeq[SessionDiagnostic](diags)
  for i in 0 ..< diags:
    result.diagnostics[i].severity = readString(bytes, pos)
    result.diagnostics[i].message = readString(bytes, pos)

proc writeEvalInputSeq(outp: var seq[byte]; inputs: openArray[GraphEvaluationInput]) =
  outp.writeU32Le(uint32(inputs.len))
  for input in inputs:
    outp.writeEvalInput(input)

proc readEvalInputSeq(bytes: openArray[byte]; pos: var int): seq[GraphEvaluationInput] =
  let count = readElementCount(bytes, pos, 4)
  result = newSeq[GraphEvaluationInput](count)
  for i in 0 ..< count:
    result[i] = readEvalInput(bytes, pos)

proc encodeBindDependencies*(value: BindDependencies): seq[byte] =
  result.writeU32Le(uint32(value.bindings.len))
  for binding in value.bindings:
    result.writeString(binding.logicalName)
    result.writeString(binding.providerArtifactId)
    result.writeString(binding.providerSessionKey)
    result.writeString(binding.entryPointId)
    result.add(if binding.hasResult: 1'u8 else: 0'u8)
    if binding.hasResult:
      result.writeBoxedValue(binding.result)
    result.writeEvalInputSeq(binding.evaluationInputs)

proc decodeBindDependencies*(bytes: openArray[byte]): BindDependencies =
  var pos = 0
  let count = readElementCount(bytes, pos, 4)
  result.bindings = newSeq[DependencyBinding](count)
  for i in 0 ..< count:
    result.bindings[i].logicalName = readString(bytes, pos)
    result.bindings[i].providerArtifactId = readString(bytes, pos)
    result.bindings[i].providerSessionKey = readString(bytes, pos)
    result.bindings[i].entryPointId = readString(bytes, pos)
    if pos >= bytes.len:
      raiseEnvelopeError(eeMalformed, "truncated dependency binding result flag")
    result.bindings[i].hasResult = bytes[pos] != 0'u8
    inc pos
    if result.bindings[i].hasResult:
      result.bindings[i].result = readBoxedValue(bytes, pos)
    result.bindings[i].evaluationInputs = readEvalInputSeq(bytes, pos)

# --------------------------------------------------------------------------
# Framing (v1 §2): u32le length + u16le messageType + payload
# --------------------------------------------------------------------------

proc hexBytes(bytes: openArray[byte]): string =
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii)

proc frameHeaderText(bytes: openArray[byte]): string =
  ## The header bytes as printable text, so a stray ``echo`` in the stream
  ## is recognisable in the error ("hell" rather than 1819043176).
  result = "\""
  for b in bytes:
    if b >= 0x20'u8 and b < 0x7f'u8: result.add(char(b))
    else: result.add("\\x" & toHex(int(b), 2))
  result.add("\"")

proc writeFrame*(stream: Stream; messageType: SessionMessageType;
                 payload: openArray[byte];
                 maxFrameLength = ProviderSessionMaxFrameLength) =
  ## Emit one length-prefixed frame. ``length`` covers the ``u16le
  ## messageType`` + payload (so the reader knows how many bytes follow the
  ## length word). A frame above ``maxFrameLength`` is refused before any
  ## byte of it is written: the peer would refuse it, and a half-written
  ## frame would leave the stream unusable (Low-Level-Provider-Protocol.md
  ## §2.1).
  let length = payload.len + 2
  if length > int(maxFrameLength):
    raiseSession("provider session frame of " & $length &
      " bytes exceeds the negotiated maximum of " & $maxFrameLength &
      " bytes")
  var header: seq[byte] = @[]
  header.writeU32Le(uint32(length))
  header.writeU16Le(uint16(ord(messageType)))
  stream.writeData(addr header[0], header.len)
  if payload.len > 0:
    stream.writeData(unsafeAddr payload[0], payload.len)
  stream.flush()

proc readExact(stream: Stream; count: int): seq[byte] =
  ## Read exactly ``count`` bytes, growing the buffer only as bytes arrive:
  ## a ``count`` the stream does not deliver costs at most the received
  ## bytes plus one chunk, never ``count`` up front (Failure-Semantics.md
  ## §"Cache And Store Failures", the stream rule).
  result = newSeqOfCap[byte](min(count, FrameReadChunk))
  while result.len < count:
    let want = min(FrameReadChunk, count - result.len)
    let at = result.len
    result.setLen(at + want)
    let got = stream.readData(addr result[at], want)
    if got < want:
      result.setLen(at + max(got, 0))
      raiseSession("provider session stream closed mid-frame (wanted " &
        $count & " bytes, got " & $result.len & ")")

proc readFrame*(stream: Stream;
                maxFrameLength = ProviderSessionMaxFrameLength):
    tuple[messageType: SessionMessageType; payload: seq[byte]] =
  ## Read one length-prefixed frame. Raises ``ProviderSessionError`` at
  ## EOF before the length (the message says so: callers tell a clean
  ## shutdown from a lost peer by when it happens), at a truncated frame, at
  ## a length below 2 or above ``maxFrameLength`` (refused before anything
  ## sized by it is allocated), and at an unknown message type.
  var lb: array[4, byte]
  let firstGot = stream.readData(addr lb[0], 4)
  if firstGot <= 0:
    raise newException(ProviderSessionClosed,
      "provider session stream closed at frame boundary")
  if firstGot != 4:
    raiseSession("truncated provider session frame length")
  var pos = 0
  let length = readU32Le(lb, pos)
  if length < 2'u32:
    raiseSession("provider session frame too short")
  if length > maxFrameLength:
    raiseSession("provider session frame length " & $length &
      " exceeds the negotiated maximum of " & $maxFrameLength & " bytes" &
      " (header bytes " & hexBytes(lb) & ", as text " & frameHeaderText(lb) &
      "); the stream is corrupt or the provider wrote non-protocol bytes")
  let rest = readExact(stream, int(length))
  var rp = 0
  let typeWord = readU16Le(rest, rp)
  if typeWord notin [uint16(ord(smtEngineHello)),
      uint16(ord(smtProviderManifest)), uint16(ord(smtBindDependencies)),
      uint16(ord(smtBindDependenciesAck)), uint16(ord(smtInvokeEntryPoint)),
      uint16(ord(smtEntryPointResult))]:
    raiseSession("unknown provider session message type " & $typeWord)
  result.messageType = SessionMessageType(typeWord)
  result.payload = rest[2 ..< rest.len]

# --------------------------------------------------------------------------
# Session identity (v1 §4)
# --------------------------------------------------------------------------

type
  SessionLifetimePolicy* = enum
    slpPerEngineRun

  SessionPolicy* = object
    ## Engine-owned session policy. v1 §4 keys a session by these fields plus
    ## the ProviderArtifactId + protocolVersion.
    platformRuntimeCompatibility*: string
    trustTenantBoundary*: string
    sessionLifetimePolicy*: SessionLifetimePolicy

proc defaultSessionPolicy*(): SessionPolicy =
  SessionPolicy(
    platformRuntimeCompatibility: hostOS & "-" & hostCPU,
    trustTenantBoundary: "local",
    sessionLifetimePolicy: slpPerEngineRun)

proc providerSessionKey*(providerArtifactId: string; protocolVersion: uint32;
                         lockSliceId: string; policy: SessionPolicy): string =
  ## ``ProviderSessionKey = hash(ProviderArtifactId, protocolVersion,
  ## lockSliceId, platformRuntimeCompatibility, trustTenantBoundary,
  ## sessionLifetimePolicy)`` (Project-Provider-Runtime-Protocol.md
  ## §"Identity"). Sessions with an identical key are reused across consumer
  ## edges within an engine run.
  ##
  ## ``lockSliceId`` is part of the key because a session is told its slice
  ## once, in the EngineHello handshake: two builds whose lock slices for a
  ## project differ must never share that project's session, or the second
  ## would be served by a provider that was told the first build's slice.
  ## The domain tag moved to ``.v2`` when the slice joined the key, so no
  ## v1 key can collide with a v2 one.
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.provider-session-key.v2")
  payload.writeString(providerArtifactId)
  payload.writeU32Le(protocolVersion)
  payload.writeString(lockSliceId)
  payload.writeString(policy.platformRuntimeCompatibility)
  payload.writeString(policy.trustTenantBoundary)
  payload.writeU32Le(uint32(ord(policy.sessionLifetimePolicy)))
  toHex(blake3DomainDigest(payload, hdMetadataEnvelope).bytes)

# --------------------------------------------------------------------------
# Engine-side session: launch + handshake + invoke + reuse (v1 §2-4)
# --------------------------------------------------------------------------

type
  ProviderArtifactRef* = object
    ## Reference to a materialized provider binary (RP1 produces the binary +
    ## its content-addressed ``providerArtifactId``). The engine launches this
    ## binary as the session's child process.
    binaryPath*: string
    providerArtifactId*: string
      ## The RP1 content-addressed ProviderArtifactId the engine derived for
      ## this binary. It KEYS the session pool (v1 §4). Reconciliation with the
      ## handshake manifest (v1): a provider binary cannot self-compute its own
      ## content-address (that would be circular — the id hashes the compile
      ## inputs), so in v1 the provider reports an EMPTY manifest
      ## ``providerArtifactId`` and the engine binds the session to the id it
      ## derived for the launched (content-addressed) binary. Should a provider
      ## ever self-attest a non-empty id, the engine hard-errors on a
      ## disagreement — see ``validateHandshakeManifest``.
    expectedProtocolVersion*: uint32
      ## The protocol version the engine requires the provider to speak. 0 ⇒
      ## the current ``ProviderProtocolVersion``. A disagreement is a HARD
      ## handshake error (the genuinely-falsifiable v1 reconciliation check: a
      ## stale binary built against a different protocol version is rejected).
    extraArgs*: seq[string]
    workingDir*: string

  ProviderSession* = ref object
    ## A live provider child process the engine talks to over stdio for the
    ## session's lifetime. Reused across ``invokeEntryPoint`` calls.
    key*: string
    providerArtifactId*: string
    manifest*: ProviderManifest
    process: Process
    toChild: Stream
    fromChild: Stream
    open: bool
    maxFrameLength*: uint32
      ## The bound negotiated in the handshake; binds both directions.
    stderrDrain: ProviderStderrDrain
      ## Drains the provider's stderr for the session's life (see
      ## ``stderr_drain``); its tail goes into failure reports.
    boundDependencies*: seq[DependencyBinding]
      ## The dependency bindings the engine last wired into this session (v1
      ## §4). Carried on the session so a consumer's invoke can forward them to
      ## the provider and so the engine can fold each binding's
      ## ``evaluationInputs`` onto the consumer edge (observed-input
      ## propagation, v1 §3).

  ProviderHandle* = object
    ## Opaque handle the engine passes to ``invokeEntryPoint``. The provider
    ## does not know whether it is backed by a local process, a remote worker,
    ## or a precomputed static result (v1 §4).
    session*: ProviderSession

  ProviderSessionPool* = ref object
    ## Engine-owned pool: one long-lived session per ``ProviderSessionKey``
    ## per engine run (v1 §4 lifetime policy). ``launchCount`` counts child
    ## processes actually spawned (a session-reuse observability hook the
    ## RP2 reuse test asserts against).
    sessions: seq[ProviderSession]
    launchCount*: int

proc newProviderSessionPool*(): ProviderSessionPool =
  ProviderSessionPool(sessions: @[], launchCount: 0)

proc sendFrame(session: ProviderSession; messageType: SessionMessageType;
               payload: openArray[byte]; maxFrameLength: uint32) =
  ## Engine-side write of one frame to the provider. A provider that is gone
  ## makes the write fail with ``EPIPE`` (a Nim program ignores ``SIGPIPE``
  ## unless built with ``-d:nimLegacySigpipeHandler``) or lose the frame,
  ## and the read that follows sees end-of-file; either way the caller's
  ## ``guardSession`` fails the session (Low-Level-Provider-Protocol.md §2.6).
  session.toChild.writeFrame(messageType, payload, maxFrameLength)

proc reapChild(session: ProviderSession): string =
  ## Tear the child down and describe how it ended: close its input, give it
  ## 2 s to exit, then terminate it, 2 s more, then kill it
  ## (Low-Level-Provider-Protocol.md §2.6). Stops the stderr drain once the
  ## child is gone, so the tail includes its last words.
  const graceMillis = 2000
  const stepMillis = 20
  try: session.toChild.close() except CatchableError: discard
  proc exitedWithin(p: Process; millis: int): bool =
    var waited = 0
    while true:
      try:
        if not p.running(): return true
      except CatchableError:
        return true
      if waited >= millis: return false
      sleep(stepMillis)
      waited += stepMillis
  var how = ""
  if not exitedWithin(session.process, graceMillis):
    try: session.process.terminate() except CatchableError: discard
    if exitedWithin(session.process, graceMillis):
      how = "terminated by the engine after it did not exit; "
    else:
      try: session.process.kill() except CatchableError: discard
      how = "killed by the engine after it did not exit; "
  var status = -1
  try: status = session.process.waitForExit() except CatchableError: discard
  session.stderrDrain.stop()
  how & "exit status " & $status

proc failSession(session: ProviderSession; phase, cause: string)
    {.noreturn.} =
  ## A protocol failure (Low-Level-Provider-Protocol.md §2.6,
  ## Failure-Semantics.md §"Provider Failures"): the in-flight result is
  ## discarded, the session is marked failed (the pool never hands it out
  ## again), the child is torn down, and the error names the artifact, the
  ## phase, the cause, the exit status and the provider's stderr tail.
  session.open = false
  let ended = session.reapChild()
  let tail = session.stderrDrain.tail()
  try: session.process.close() except CatchableError: discard
  session.stderrDrain.release()
  var message = "provider session " &
    (if session.providerArtifactId.len > 0: session.providerArtifactId
     else: "(no artifact id)") &
    " failed during " & phase & ": " & cause & "; provider " & ended
  if tail.len > 0:
    message.add("; provider stderr (last " & $tail.len & " bytes):\n" & tail)
  else:
    message.add("; provider wrote nothing to stderr")
  raiseSession(message)

template guardSession(session: ProviderSession; phase: string;
                      body: untyped) =
  ## Run one protocol exchange; any failure in it fails the session.
  try:
    body
  except CatchableError as err:
    failSession(session, phase, err.msg)

proc readManifestFrame(session: ProviderSession;
                       offered: uint32): ProviderManifest =
  let frame = session.fromChild.readFrame(offered)
  if frame.messageType != smtProviderManifest:
    raiseSession("expected ProviderManifest from provider, got frame type " &
      $ord(frame.messageType))
  decodeProviderManifestMsg(frame.payload)

proc validateHandshakeManifest(manifest: ProviderManifest;
                               expected: ProviderArtifactRef;
                               offeredFrameLength: uint32) =
  ## The handshake ProviderManifest is checked against what the engine
  ## expected (v1 §3). A HARD error tears the session down:
  ##
  ## * protocolVersion disagreement — the falsifiable v1 reconciliation check
  ##   (a stale binary built against a different protocol version is rejected);
  ## * providerArtifactId disagreement, ONLY when the provider self-attests a
  ##   non-empty id. In v1 the provider reports "" (it cannot self-address),
  ##   and the engine binds the session to the id it derived for the launched,
  ##   content-addressed binary (``expected.providerArtifactId``);
  ## * a negotiated frame bound above the engine's offer or below
  ##   ``ProviderSessionMinFrameLength`` (Low-Level-Provider-Protocol.md §2.1).
  let wantVersion =
    if expected.expectedProtocolVersion != 0'u32: expected.expectedProtocolVersion
    else: ProviderProtocolVersion
  if manifest.protocolVersion != wantVersion:
    raiseSession("provider session protocol version mismatch: engine expects " &
      $wantVersion & ", provider reports " & $manifest.protocolVersion)
  if manifest.providerArtifactId.len > 0 and
      expected.providerArtifactId.len > 0 and
      manifest.providerArtifactId != expected.providerArtifactId:
    raiseSession("provider session artifact id mismatch: engine expects " &
      expected.providerArtifactId & ", provider reports " &
      manifest.providerArtifactId)
  if manifest.maxFrameLength < ProviderSessionMinFrameLength or
      manifest.maxFrameLength > offeredFrameLength:
    raiseSession("provider session negotiated frame bound " &
      $manifest.maxFrameLength & " is outside [" &
      $ProviderSessionMinFrameLength & ", " & $offeredFrameLength & "]")

proc launchSession(pool: ProviderSessionPool; artifact: ProviderArtifactRef;
                   key: string; hello: EngineHello): ProviderSession =
  if artifact.binaryPath.len == 0:
    raiseSession("provider artifact binary path is required")
  let cwd =
    if artifact.workingDir.len > 0: artifact.workingDir
    else: getCurrentDir()
  var offered = hello
  if offered.maxFrameLength == 0'u32:
    offered.maxFrameLength = ProviderSessionMaxFrameLength
  if offered.maxFrameLength < ProviderSessionMinFrameLength:
    raiseSession("engine frame bound " & $offered.maxFrameLength &
      " is below the minimum " & $ProviderSessionMinFrameLength)
  # Under the portable Linux release a provider it compiled starts through
  # the bundled loader (`portableReleaseHelperArgv`), or it cannot load the
  # release's clingo on a host glibc older than the release's.
  let argv = portableReleaseHelperArgv(@[artifact.binaryPath] &
    artifact.extraArgs & @[ProviderServeFlag], cwd = cwd)
  let process = startProcess(argv[0],
    workingDir = cwd, args = argv[1 .. ^1],
    options = {poUsePath})
  inc pool.launchCount
  let session = ProviderSession(
    key: key,
    providerArtifactId: artifact.providerArtifactId,
    process: process,
    toChild: process.inputStream,
    fromChild: process.outputStream,
    open: true,
    stderrDrain: startProviderStderrDrain(process.errorHandle))
  # A failed handshake tears the child down (``failSession``) so a bad
  # binary never lingers in the pool.
  guardSession(session, "handshake"):
    session.sendFrame(smtEngineHello, encodeEngineHello(offered),
      ProviderSessionHelloFrameLength)
    session.manifest = session.readManifestFrame(offered.maxFrameLength)
    validateHandshakeManifest(session.manifest, artifact,
      offered.maxFrameLength)
    session.maxFrameLength = session.manifest.maxFrameLength
  session

proc openProviderSession*(pool: ProviderSessionPool;
                          artifact: ProviderArtifactRef; policy: SessionPolicy;
                          hello: EngineHello): ProviderHandle =
  ## v1 §2-4: launch (or REUSE) the provider child for this
  ## ``ProviderSessionKey`` and perform the EngineHello / ProviderManifest
  ## handshake. A compatible session already in the pool is returned as-is
  ## (no relaunch); a fresh key spawns a new child.
  # The slice comes from the hello because the hello is what this session
  # will be told; keying on anything else could pool a session under a slice
  # it never received.
  let key = providerSessionKey(artifact.providerArtifactId,
    ProviderProtocolVersion, hello.lockSliceId, policy)
  # A failed session is never handed out again (Failure-Semantics.md
  # §"Provider Failures"); drop the ones a protocol failure closed.
  var live: seq[ProviderSession] = @[]
  for existing in pool.sessions:
    if existing.open:
      live.add(existing)
  pool.sessions = live
  for existing in pool.sessions:
    if existing.key == key:
      return ProviderHandle(session: existing)
  let session = launchSession(pool, artifact, key, hello)
  pool.sessions.add(session)
  ProviderHandle(session: session)

proc sessionKey*(handle: ProviderHandle): string =
  ## The ProviderSessionKey backing this handle — the identity two consumers
  ## of the same dependency version converge on (v1 §4).
  if handle.session == nil: "" else: handle.session.key

proc providerArtifactId*(handle: ProviderHandle): string =
  if handle.session == nil: "" else: handle.session.providerArtifactId

proc resolveDependencyBinding*(dependency: ProviderHandle;
                               logicalName, entryPointId: string;
                               dependencyResult: EntryPointResult):
    DependencyBinding =
  ## Build the wire ``DependencyBinding`` for a dependency the engine has
  ## already resolved. ``dependency`` is the SHARED session handle (from
  ## ``openProviderSession`` on the dependency's ProviderArtifactId and lock
  ## slice, so two consumers converge on one launched process only when they
  ## agree on both), and ``dependencyResult`` is
  ## the result the engine obtained by invoking the dependency on that shared
  ## session — carried into the consumer plus the dependency's observed
  ## ``evaluationInputs`` for consumer-edge invalidation (v1 §3).
  DependencyBinding(
    logicalName: logicalName,
    providerArtifactId: dependency.providerArtifactId,
    providerSessionKey: dependency.sessionKey,
    entryPointId: entryPointId,
    hasResult: dependencyResult.hasValue,
    result: dependencyResult.value,
    evaluationInputs: dependencyResult.evaluationInputs)

proc bindDependencies*(consumer: ProviderHandle;
                       bindings: openArray[DependencyBinding]) =
  ## v1 §4: wire dependency handles into the CONSUMER's provider session. Sent
  ## after the handshake, before any InvokeEntryPoint. The engine owns the
  ## bindings; the provider receives them and never discovers siblings through
  ## ambient state. The bindings are also retained on the session so the
  ## engine can fold each dependency's observed inputs onto the consumer edge
  ## (v1 §3).
  let session = consumer.session
  if session == nil or not session.open:
    raiseSession("provider session is not open")
  session.boundDependencies = @bindings
  let payload = encodeBindDependencies(BindDependencies(bindings: @bindings))
  guardSession(session, "bind dependencies"):
    session.sendFrame(smtBindDependencies, payload, session.maxFrameLength)
    let frame = session.fromChild.readFrame(session.maxFrameLength)
    if frame.messageType != smtBindDependenciesAck:
      raiseSession("expected BindDependenciesAck from provider, got " &
        "frame type " & $ord(frame.messageType))

proc boundDependencyInputs*(handle: ProviderHandle): seq[GraphEvaluationInput] =
  ## v1 §3: the union of every bound dependency's observed inputs. The engine
  ## folds these onto the consumer edge so a change to a dependency's
  ## realization invalidates the consumer.
  if handle.session == nil:
    return
  for binding in handle.session.boundDependencies:
    for input in binding.evaluationInputs:
      result.add(input)

proc invokeEntryPoint*(handle: ProviderHandle; entryPointId: string;
                       args: openArray[BoxedValue];
                       dependencyBindings: openArray[BoxedValue] = []):
    EntryPointResult =
  ## v1 §3: send InvokeEntryPoint over the live session and read the
  ## EntryPointResult back. Synchronous (one request → one response). The
  ## dependency bindings previously wired via ``bindDependencies`` remain in
  ## effect on the session; the provider reads them from its binding table.
  let session = handle.session
  if session == nil or not session.open:
    raiseSession("provider session is not open")
  let invoke = InvokeEntryPoint(
    entryPointId: entryPointId,
    args: @args,
    dependencyBindings: @dependencyBindings)
  let payload = encodeInvokeEntryPoint(invoke)
  var res: EntryPointResult
  guardSession(session, "invoke of entry point '" & entryPointId & "'"):
    session.sendFrame(smtInvokeEntryPoint, payload, session.maxFrameLength)
    let frame = session.fromChild.readFrame(session.maxFrameLength)
    if frame.messageType != smtEntryPointResult:
      raiseSession("expected EntryPointResult from provider, got frame " &
        "type " & $ord(frame.messageType))
    res = decodeEntryPointResult(frame.payload)
  # v1 §3 observed-input propagation: fold the bound dependencies' observed
  # inputs onto the consumer edge so the consumer invalidates when a
  # dependency's realization changes. Deduplicated by (kind, identity, digest).
  for binding in session.boundDependencies:
    for depInput in binding.evaluationInputs:
      var seen = false
      for existing in res.evaluationInputs:
        if existing.kind == depInput.kind and
            existing.identity == depInput.identity and
            existing.digest == depInput.digest:
          seen = true
          break
      if not seen:
        res.evaluationInputs.add(depInput)
  res

proc closeSession(session: ProviderSession) =
  if not session.open:
    return
  session.open = false
  try: session.toChild.close() except CatchableError: discard
  try: discard session.process.waitForExit() except CatchableError:
    try: session.process.terminate() except CatchableError: discard
  # The drain must stop before ``close`` releases the handle it reads.
  session.stderrDrain.release()
  try: session.process.close() except CatchableError: discard

proc closeAll*(pool: ProviderSessionPool) =
  ## v1 §4: tear every session down at engine-run end. Closing the engine's
  ## write end lets the provider's serve loop see EOF and exit cleanly.
  for session in pool.sessions:
    closeSession(session)
  pool.sessions = @[]

proc closeProviderSession*(pool: ProviderSessionPool;
                           providerArtifactId: string): bool =
  ## Tear down just the session(s) for one ``providerArtifactId`` and drop them
  ## from the pool, leaving every other session live. Returns true if anything
  ## was closed.
  ##
  ## WHY A SINGLE-SESSION CLOSE EXISTS BESIDE ``closeAll``. An engine run ends
  ## all at once, so ``closeAll`` is the whole lifetime policy it needs. A
  ## LONG-LIVED pool does not: the Ephemeral-State-Leases reaper (§4.2) keeps
  ## one pool for the daemon's life and must evict the child for a provider the
  ## store has stopped referencing — a rebuilt provider gets a new
  ## content-addressed id every time — WITHOUT dropping the sessions its next
  ## tick still wants. Expressed as ``closeAll``, that eviction had to discard
  ## every session, which made a daemon reaping two providers with
  ## non-simultaneous deadlines relaunch both on every other tick.
  ##
  ## Idempotent: an id with no session returns false and changes nothing.
  var kept: seq[ProviderSession] = @[]
  for session in pool.sessions:
    if session.providerArtifactId == providerArtifactId:
      closeSession(session)
      result = true
    else:
      kept.add(session)
  pool.sessions = kept

proc sessionCount*(pool: ProviderSessionPool): int =
  ## Number of live sessions in the pool (for reuse observability).
  for session in pool.sessions:
    if session.open:
      inc result

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

import std/[os, osproc, streams]

import repro_core
import repro_hash
import repro_provider_runtime/types

type
  ProviderSessionError* = object of CatchableError

  SessionMessageType* = enum
    ## The v1 §3 message set (MVP subset). BindDependencies is RP3.
    smtEngineHello = 1'u16
    smtProviderManifest = 2'u16
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

const
  ## The stdio-serve invocation flag the provider binary recognizes to enter
  ## the RP2 session serve loop (instead of the file-based single-shot path).
  ProviderServeFlag* = "--repro-provider-serve"

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
  let count = int(readU32Le(bytes, pos))
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
  let members = int(readU32Le(bytes, pos))
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

proc decodeEngineHello*(bytes: openArray[byte]): EngineHello =
  var pos = 0
  result.protocolVersion = readU32Le(bytes, pos)
  let caps = int(readU32Le(bytes, pos))
  result.engineCapabilities = newSeq[string](caps)
  for i in 0 ..< caps:
    result.engineCapabilities[i] = readString(bytes, pos)
  result.lockSliceId = readString(bytes, pos)
  result.canonicalExecutionRoot = readString(bytes, pos)

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

proc decodeProviderManifestMsg*(bytes: openArray[byte]): ProviderManifest =
  var pos = 0
  result.providerArtifactId = readString(bytes, pos)
  result.protocolVersion = readU32Le(bytes, pos)
  let count = int(readU32Le(bytes, pos))
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
  let inputs = int(readU32Le(bytes, pos))
  result.evaluationInputs = newSeq[GraphEvaluationInput](inputs)
  for i in 0 ..< inputs:
    result.evaluationInputs[i] = readEvalInput(bytes, pos)
  let diags = int(readU32Le(bytes, pos))
  result.diagnostics = newSeq[SessionDiagnostic](diags)
  for i in 0 ..< diags:
    result.diagnostics[i].severity = readString(bytes, pos)
    result.diagnostics[i].message = readString(bytes, pos)

# --------------------------------------------------------------------------
# Framing (v1 §2): u32le length + u16le messageType + payload
# --------------------------------------------------------------------------

proc writeFrame*(stream: Stream; messageType: SessionMessageType;
                 payload: openArray[byte]) =
  ## Emit one length-prefixed frame. ``length`` covers the ``u16le
  ## messageType`` + payload (so the reader knows how many bytes follow the
  ## length word).
  var header: seq[byte] = @[]
  header.writeU32Le(uint32(payload.len + 2))
  header.writeU16Le(uint16(ord(messageType)))
  stream.writeData(addr header[0], header.len)
  if payload.len > 0:
    var buf = @payload
    stream.writeData(addr buf[0], buf.len)
  stream.flush()

proc readExact(stream: Stream; count: int): seq[byte] =
  result = newSeq[byte](count)
  if count == 0:
    return
  let got = stream.readData(addr result[0], count)
  if got != count:
    raiseSession("provider session stream closed mid-frame (wanted " &
      $count & " bytes, got " & $got & ")")

proc readFrame*(stream: Stream):
    tuple[messageType: SessionMessageType; payload: seq[byte]] =
  ## Read one length-prefixed frame. Raises ``ProviderSessionError`` at clean
  ## EOF-before-length or a truncated frame.
  var lb = newSeq[byte](4)
  let firstGot = stream.readData(addr lb[0], 4)
  if firstGot == 0:
    raiseSession("provider session stream closed at frame boundary")
  if firstGot != 4:
    raiseSession("truncated provider session frame length")
  var pos = 0
  let length = int(readU32Le(lb, pos))
  if length < 2:
    raiseSession("provider session frame too short")
  let rest = readExact(stream, length)
  var rp = 0
  let typeWord = readU16Le(rest, rp)
  if typeWord < uint16(ord(smtEngineHello)) or
      typeWord > uint16(ord(smtEntryPointResult)):
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
                         policy: SessionPolicy): string =
  ## v1 §4: ``ProviderSessionKey = hash(ProviderArtifactId, protocolVersion,
  ## platformRuntimeCompatibility, trustTenantBoundary,
  ## sessionLifetimePolicy)``. Sessions with an identical key are reused
  ## across consumer edges within an engine run.
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.provider-session-key.v1")
  payload.writeString(providerArtifactId)
  payload.writeU32Le(protocolVersion)
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

  ProviderHandle* = object
    ## Opaque handle the engine passes to ``invokeEntryPoint``.
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

proc engineHello(pool: ProviderSessionPool; hello: EngineHello;
                 session: ProviderSession) =
  session.toChild.writeFrame(smtEngineHello, encodeEngineHello(hello))

proc readManifestFrame(session: ProviderSession): ProviderManifest =
  let frame = session.fromChild.readFrame()
  if frame.messageType != smtProviderManifest:
    raiseSession("expected ProviderManifest from provider, got frame type " &
      $ord(frame.messageType))
  decodeProviderManifestMsg(frame.payload)

proc validateHandshakeManifest(manifest: ProviderManifest;
                               expected: ProviderArtifactRef) =
  ## The handshake ProviderManifest is checked against what the engine
  ## expected (v1 §3). A HARD error tears the session down:
  ##
  ## * protocolVersion disagreement — the falsifiable v1 reconciliation check
  ##   (a stale binary built against a different protocol version is rejected);
  ## * providerArtifactId disagreement, ONLY when the provider self-attests a
  ##   non-empty id. In v1 the provider reports "" (it cannot self-address),
  ##   and the engine binds the session to the id it derived for the launched,
  ##   content-addressed binary (``expected.providerArtifactId``).
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

proc launchSession(pool: ProviderSessionPool; artifact: ProviderArtifactRef;
                   key: string; hello: EngineHello): ProviderSession =
  if artifact.binaryPath.len == 0:
    raiseSession("provider artifact binary path is required")
  let cwd =
    if artifact.workingDir.len > 0: artifact.workingDir
    else: getCurrentDir()
  let argv = artifact.extraArgs & @[ProviderServeFlag]
  let process = startProcess(artifact.binaryPath,
    workingDir = cwd, args = argv,
    options = {poUsePath})
  inc pool.launchCount
  let session = ProviderSession(
    key: key,
    providerArtifactId: artifact.providerArtifactId,
    process: process,
    toChild: process.inputStream,
    fromChild: process.outputStream,
    open: true)
  try:
    pool.engineHello(hello, session)
    session.manifest = session.readManifestFrame()
    validateHandshakeManifest(session.manifest, artifact)
  except CatchableError as err:
    # A failed handshake tears the child down so a bad binary never lingers
    # in the pool.
    try: process.terminate() except CatchableError: discard
    try: discard process.waitForExit() except CatchableError: discard
    try: process.close() except CatchableError: discard
    session.open = false
    raise err
  session

proc openProviderSession*(pool: ProviderSessionPool;
                          artifact: ProviderArtifactRef; policy: SessionPolicy;
                          hello: EngineHello): ProviderHandle =
  ## v1 §2-4: launch (or REUSE) the provider child for this
  ## ``ProviderSessionKey`` and perform the EngineHello / ProviderManifest
  ## handshake. A compatible session already in the pool is returned as-is
  ## (no relaunch); a fresh key spawns a new child.
  let key = providerSessionKey(artifact.providerArtifactId,
    ProviderProtocolVersion, policy)
  for existing in pool.sessions:
    if existing.key == key and existing.open:
      return ProviderHandle(session: existing)
  let session = launchSession(pool, artifact, key, hello)
  pool.sessions.add(session)
  ProviderHandle(session: session)

proc invokeEntryPoint*(handle: ProviderHandle; entryPointId: string;
                       args: openArray[BoxedValue];
                       dependencyBindings: openArray[BoxedValue] = []):
    EntryPointResult =
  ## v1 §3: send InvokeEntryPoint over the live session and read the
  ## EntryPointResult back. Synchronous (one request → one response).
  let session = handle.session
  if session == nil or not session.open:
    raiseSession("provider session is not open")
  let invoke = InvokeEntryPoint(
    entryPointId: entryPointId,
    args: @args,
    dependencyBindings: @dependencyBindings)
  session.toChild.writeFrame(smtInvokeEntryPoint, encodeInvokeEntryPoint(invoke))
  let frame = session.fromChild.readFrame()
  if frame.messageType != smtEntryPointResult:
    raiseSession("expected EntryPointResult from provider, got frame type " &
      $ord(frame.messageType))
  decodeEntryPointResult(frame.payload)

proc closeSession(session: ProviderSession) =
  if not session.open:
    return
  session.open = false
  try: session.toChild.close() except CatchableError: discard
  try: discard session.process.waitForExit() except CatchableError:
    try: session.process.terminate() except CatchableError: discard
  try: session.process.close() except CatchableError: discard

proc closeAll*(pool: ProviderSessionPool) =
  ## v1 §4: tear every session down at engine-run end. Closing the engine's
  ## write end lets the provider's serve loop see EOF and exit cleanly.
  for session in pool.sessions:
    closeSession(session)
  pool.sessions = @[]

proc sessionCount*(pool: ProviderSessionPool): int =
  ## Number of live sessions in the pool (for reuse observability).
  for session in pool.sessions:
    if session.open:
      inc result

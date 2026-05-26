## TryCompile direct-provider metadata schema (Tier 2a).
##
## The CMake Reprobuild generator's TryCompile codepath emits a small
## binary metadata file (``trycompile.rbsz``) describing the 1- or 2-edge
## graph the test compile produces (a compile, and optionally a link).
## The engine routes such projects to the pre-built
## ``repro-cmake-trycompile-provider`` binary instead of compiling a
## per-project ``reprobuild.nim`` — the binary parses this metadata,
## synthesises the same ``BuildActionDef`` shape the DSL would produce,
## and emits the graph fragment.
##
## The schema is the smallest superset of ``ReprobuildAction`` that the
## C++ generator currently writes inline into ``reprobuild.nim``. It is
## NOT a general project description — there is no ``cli:`` interface,
## no ``config:``, no foreach. TryCompiles are stereotyped and that
## limitation is the whole point of taking this fast path.
##
## Format (little-endian, length-prefixed):
##
##   magic        : "RBCT"                (4 bytes)
##   version      : u16                   (=1)
##   payloadLen   : u32
##   payload {
##     usedTools  : seq[string]
##     pools      : seq[ (name: string, capacity: u32) ]
##     actions    : seq[TryCompileAction]
##     targetName : string                 (the canonical cmTC target name)
##     targetActionIds : seq[string]       (action.id values that compose
##                                          the target, in declaration order)
##   }
##
## TryCompileAction (mirrors generator's ``ReprobuildAction``):
##
##   id              : string
##   inline          : u8     (1 = inlineExec, 0 = publicCli)
##   inlineArgv      : seq[string]  (if inline)
##   inlineCwd       : string       (if inline)
##   toolId          : string       (if not inline)
##   args            : seq[string]  (if not inline)
##   deps            : seq[string]
##   inputs          : seq[string]
##   outputs         : seq[string]
##   pool            : string
##   poolUnits       : u32
##   depfile         : string       (empty = no depfile)
##   dynamicDepsFile : string       (empty = none)
##   cacheable       : u8
##   commandStatsId  : string
##
## See ``reprobuild-specs/Provider-Compile-Tiering.md`` §"2a" for the
## design rationale. The encoder is byte-compatible with the C++
## emitter in ``cmGlobalReprobuildGenerator.cxx``.

import std/[strutils]

import repro_core

const
  TryCompileMetadataMagic* = "RBCT"
  TryCompileMetadataVersion* = 1'u16
  ## Stable identity of the direct provider binary. Goes into the
  ## engine's ``providerArtifactId`` for every TryCompile, so every
  ## project on the same ``repro`` release shares an action cache key
  ## for the provider artifact itself. Bumping ``Version`` invalidates
  ## that share — keep it in lockstep with the binary protocol.
  TryCompileProviderArtifactId* =
    "repro-cmake-trycompile-provider.v1"
  TryCompileProviderRootEntryPointId* =
    "cmakeReprobuildTryCompile.root"
  TryCompileProviderRootBodyHash* =
    "cmakeReprobuildTryCompile.root.v1"
  TryCompileProviderPackageName* = "cmakeReprobuildTryCompile"
  TryCompileProviderNamespace* = "project"

type
  TryCompileActionDef* = object
    id*: string
    inline*: bool
    inlineArgv*: seq[string]
    inlineCwd*: string
    toolId*: string
    args*: seq[string]
    deps*: seq[string]
    inputs*: seq[string]
    outputs*: seq[string]
    pool*: string
    poolUnits*: uint32
    depfile*: string
    dynamicDepsFile*: string
    cacheable*: bool
    commandStatsId*: string

  TryCompilePoolDef* = object
    name*: string
    capacity*: uint32

  TryCompileMetadata* = object
    usedTools*: seq[string]
    pools*: seq[TryCompilePoolDef]
    actions*: seq[TryCompileActionDef]
    targetName*: string
    targetActionIds*: seq[string]

  TryCompileMetadataError* = object of CatchableError

proc raiseMetadata(msg: string) {.noreturn.} =
  raise newException(TryCompileMetadataError, msg)

proc writeBool(outp: var seq[byte]; value: bool) =
  outp.add(if value: 1'u8 else: 0'u8)

proc readBool(bytes: openArray[byte]; pos: var int): bool =
  if pos >= bytes.len:
    raiseMetadata("truncated bool")
  let v = bytes[pos]
  inc pos
  if v != 0 and v != 1:
    raiseMetadata("invalid bool value")
  v == 1

proc writeStringSeq(outp: var seq[byte]; values: openArray[string]) =
  outp.writeU32Le(uint32(values.len))
  for value in values:
    outp.writeString(value)

proc readStringSeq(bytes: openArray[byte]; pos: var int): seq[string] =
  let count = int(readU32Le(bytes, pos))
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = readString(bytes, pos)

proc writeAction(outp: var seq[byte]; action: TryCompileActionDef) =
  outp.writeString(action.id)
  outp.writeBool(action.inline)
  outp.writeStringSeq(action.inlineArgv)
  outp.writeString(action.inlineCwd)
  outp.writeString(action.toolId)
  outp.writeStringSeq(action.args)
  outp.writeStringSeq(action.deps)
  outp.writeStringSeq(action.inputs)
  outp.writeStringSeq(action.outputs)
  outp.writeString(action.pool)
  outp.writeU32Le(action.poolUnits)
  outp.writeString(action.depfile)
  outp.writeString(action.dynamicDepsFile)
  outp.writeBool(action.cacheable)
  outp.writeString(action.commandStatsId)

proc readAction(bytes: openArray[byte]; pos: var int): TryCompileActionDef =
  result.id = readString(bytes, pos)
  result.inline = readBool(bytes, pos)
  result.inlineArgv = readStringSeq(bytes, pos)
  result.inlineCwd = readString(bytes, pos)
  result.toolId = readString(bytes, pos)
  result.args = readStringSeq(bytes, pos)
  result.deps = readStringSeq(bytes, pos)
  result.inputs = readStringSeq(bytes, pos)
  result.outputs = readStringSeq(bytes, pos)
  result.pool = readString(bytes, pos)
  result.poolUnits = readU32Le(bytes, pos)
  result.depfile = readString(bytes, pos)
  result.dynamicDepsFile = readString(bytes, pos)
  result.cacheable = readBool(bytes, pos)
  result.commandStatsId = readString(bytes, pos)

proc encodeTryCompileMetadata*(meta: TryCompileMetadata): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeStringSeq(meta.usedTools)
  payload.writeU32Le(uint32(meta.pools.len))
  for pool in meta.pools:
    payload.writeString(pool.name)
    payload.writeU32Le(pool.capacity)
  payload.writeU32Le(uint32(meta.actions.len))
  for action in meta.actions:
    payload.writeAction(action)
  payload.writeString(meta.targetName)
  payload.writeStringSeq(meta.targetActionIds)

  result = @[]
  for ch in TryCompileMetadataMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(TryCompileMetadataVersion)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodeTryCompileMetadata*(bytes: openArray[byte]): TryCompileMetadata =
  if bytes.len < 10:
    raiseMetadata("truncated trycompile.rbsz envelope")
  for i in 0 ..< TryCompileMetadataMagic.len:
    if bytes[i] != byte(ord(TryCompileMetadataMagic[i])):
      raiseMetadata("unknown trycompile.rbsz magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != TryCompileMetadataVersion:
    raiseMetadata("unsupported trycompile.rbsz version: " & $version)
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raiseMetadata("trycompile.rbsz payload length mismatch (envelope " &
      $payloadLength & ", actual " & $(bytes.len - pos) & ")")

  result.usedTools = readStringSeq(bytes, pos)
  let poolCount = int(readU32Le(bytes, pos))
  result.pools = newSeq[TryCompilePoolDef](poolCount)
  for i in 0 ..< poolCount:
    result.pools[i].name = readString(bytes, pos)
    result.pools[i].capacity = readU32Le(bytes, pos)
  let actionCount = int(readU32Le(bytes, pos))
  result.actions = newSeq[TryCompileActionDef](actionCount)
  for i in 0 ..< actionCount:
    result.actions[i] = readAction(bytes, pos)
  result.targetName = readString(bytes, pos)
  result.targetActionIds = readStringSeq(bytes, pos)

  if pos != bytes.len:
    raiseMetadata("trailing trycompile.rbsz bytes")

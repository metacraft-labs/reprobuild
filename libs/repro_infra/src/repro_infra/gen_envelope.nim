## The `RBSG` ("Reprobuild System Generation") per-generation envelope
## (M69 Phase B — System-Profile-And-Infra-Apply.md "State Directory").
##
## The system state directory mirrors the home state dir's slim shape:
## a small pointer envelope per generation, `current` marking the
## active one, no `history.bin`. Phase A committed a generation
## DIRECTORY and its `log/apply.log`; Phase B adds the per-generation
## envelope (`generations/<id>/pointer.bin`) the spec's layout names —
## so `repro system history` can enumerate generations and
## `repro system rollback` can re-apply a prior generation's
## `system.nim`.
##
## The envelope carries the `system.nim` text the generation applied:
## the system intent layer is per-host and not synced, and the system
## state dir has no CAS, so the profile text is embedded directly
## (it is small — a handful of resource stanzas).
##
## On-disk shape (little-endian throughout), modelled on the M62 RBPT
## and the M69 RBIP / RBSL envelopes:
##
##   offset 0  : magic            4 bytes ASCII "RBSG"
##   offset 4  : schemaVersion    u16 LE
##   offset 6  : bodyLength       u32 LE
##   offset 10 : body             bodyLength bytes
##   trailing  : checksum         32 bytes BLAKE3-256
##
## Body field order (audited, NO extras):
##
##   1. generationId        length-prefixed UTF-8
##   2. activationTimestamp i64 LE (unix epoch seconds)
##   3. hostIdentity        length-prefixed UTF-8
##   4. planId              length-prefixed UTF-8
##   5. profileDigestHex    length-prefixed UTF-8 (BLAKE3 hex)
##   6. profileText         length-prefixed UTF-8 (the applied system.nim)
##   7. appliedCount        u32 LE
##   8. noOpCount           u32 LE
##
## The writer / reader are STRICT — extra body bytes, a bad checksum,
## or an unsupported schema version fail closed via `EPlanCorrupt`
## (the system-scope corrupt-envelope error; an envelope is an
## envelope).

import std/[algorithm, os, strutils]

import blake3
import repro_core

import ./errors
import ./state_dir

const
  GenMagic* = "RBSG"
  GenSchemaVersion*: uint16 = 1
  GenHeaderSize = 4 + 2 + 4
  GenTrailerSize = 32

type
  GenerationEnvelope* = object
    ## In-memory view of an `RBSG` generation envelope.
    schemaVersion*: uint16
    generationId*: string
    activationTimestamp*: int64
    hostIdentity*: string
    planId*: string
    profileDigestHex*: string
    profileText*: string
    appliedCount*: int
    noOpCount*: int

  GenerationRecord* = object
    ## One enumerated system-scope generation. `isActive` is true when
    ## `current` points at this generation.
    generationId*: string
    pointerPath*: string
    envelope*: GenerationEnvelope
    isActive*: bool

# ---------------------------------------------------------------------------
# Encode.
# ---------------------------------------------------------------------------

proc encodeBody(env: GenerationEnvelope): seq[byte] =
  result.writeString(env.generationId)
  result.writeU64Le(uint64(env.activationTimestamp))
  result.writeString(env.hostIdentity)
  result.writeString(env.planId)
  result.writeString(env.profileDigestHex)
  result.writeString(env.profileText)
  result.writeU32Le(uint32(env.appliedCount))
  result.writeU32Le(uint32(env.noOpCount))

proc encodeGeneration*(env: GenerationEnvelope): seq[byte] =
  ## Serialize a generation envelope to RBSG bytes. Deterministic for
  ## a fixed input.
  let body = encodeBody(env)
  result = newSeqOfCap[byte](GenHeaderSize + body.len + GenTrailerSize)
  for ch in GenMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(GenSchemaVersion)
  result.writeU32Le(uint32(body.len))
  for b in body:
    result.add(b)
  let checksum = blake3.digest(result)
  for b in checksum:
    result.add(b)

# ---------------------------------------------------------------------------
# Decode.
# ---------------------------------------------------------------------------

proc decodeGenerationBytes*(bytes: openArray[byte];
                            filePath = "<memory>"): GenerationEnvelope =
  ## Strict reader: validates magic / version / body-length bounds and
  ## the trailing BLAKE3 checksum BEFORE returning any field.
  if bytes.len < GenHeaderSize + GenTrailerSize:
    raisePlanCorrupt("envelope",
      filePath & ": file is too short to be an RBSG generation envelope")
  for i in 0 ..< 4:
    if bytes[i] != byte(ord(GenMagic[i])):
      raisePlanCorrupt("magic", filePath & ": expected '" & GenMagic & "'")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != GenSchemaVersion:
    raisePlanCorrupt("schemaVersion",
      filePath & ": unsupported RBSG schema version " & $version)
  let bodyLen = int(readU32Le(bytes, pos))
  if pos + bodyLen + GenTrailerSize != bytes.len:
    raisePlanCorrupt("bodyLength",
      filePath & ": declared body length " & $bodyLen &
      " disagrees with file size " & $bytes.len)
  let bodyEnd = pos + bodyLen
  var prefix = newSeqOfCap[byte](bodyEnd)
  for i in 0 ..< bodyEnd:
    prefix.add(bytes[i])
  let expected = blake3.digest(prefix)
  for i in 0 ..< 32:
    if bytes[bodyEnd + i] != expected[i]:
      raisePlanCorrupt("trailingChecksum",
        filePath & ": BLAKE3-256 trailing checksum mismatch")
  result.schemaVersion = version
  result.generationId = readString(bytes, pos)
  result.activationTimestamp = int64(readU64Le(bytes, pos))
  result.hostIdentity = readString(bytes, pos)
  result.planId = readString(bytes, pos)
  result.profileDigestHex = readString(bytes, pos)
  result.profileText = readString(bytes, pos)
  result.appliedCount = int(readU32Le(bytes, pos))
  result.noOpCount = int(readU32Le(bytes, pos))
  if pos != bodyEnd:
    raisePlanCorrupt("body",
      filePath & ": trailing " & $(bodyEnd - pos) &
      " bytes after the audited field set (extras are forbidden)")

# ---------------------------------------------------------------------------
# File I/O.
# ---------------------------------------------------------------------------

proc writeGenerationEnvelope*(pointerFilePath: string;
                              env: GenerationEnvelope) =
  ## Atomically write the generation envelope (tmp-then-rename).
  let bytes = encodeGeneration(env)
  let parent = parentDir(pointerFilePath)
  if parent.len > 0:
    createDir(parent)
  var s = newString(bytes.len)
  for i, b in bytes:
    s[i] = char(b)
  let tmp = pointerFilePath & ".tmp"
  writeFile(tmp, s)
  if fileExists(pointerFilePath):
    removeFile(pointerFilePath)
  moveFile(tmp, pointerFilePath)

proc readGenerationEnvelope*(pointerFilePath: string): GenerationEnvelope =
  if not fileExists(pointerFilePath):
    raisePlanCorrupt("file", pointerFilePath & ": no such generation envelope")
  let raw = readFile(pointerFilePath)
  var bytes = newSeq[byte](raw.len)
  for i, ch in raw:
    bytes[i] = byte(ord(ch))
  decodeGenerationBytes(bytes, pointerFilePath)

# ---------------------------------------------------------------------------
# Generation enumeration (`repro system history`).
# ---------------------------------------------------------------------------

proc enumerateSystemGenerations*(stateDir: string): seq[GenerationRecord] =
  ## Walk `<state-dir>/generations/` and return one record per
  ## directory holding a parseable `pointer.bin`, sorted oldest-first
  ## by `activationTimestamp` (ties broken by id for determinism). A
  ## directory WITHOUT a `pointer.bin` (a Phase-A generation, or a
  ## partial apply) is skipped — `history` reports only the
  ## envelope-bearing generations.
  let root = generationsRoot(stateDir)
  if not dirExists(root):
    return @[]
  let activeId = readCurrentGenerationId(stateDir)
  for kind, entry in walkDir(root, relative = false):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let id = extractFilename(entry)
    if id.startsWith("."):
      continue
    let pointerFile = entry / PointerFileName
    if not fileExists(pointerFile):
      continue
    let env = readGenerationEnvelope(pointerFile)
    result.add(GenerationRecord(
      generationId: id,
      pointerPath: pointerFile,
      envelope: env,
      isActive: id == activeId))
  result.sort(proc(a, b: GenerationRecord): int =
    if a.envelope.activationTimestamp < b.envelope.activationTimestamp: -1
    elif a.envelope.activationTimestamp > b.envelope.activationTimestamp: 1
    else: cmp(a.generationId, b.generationId))

proc resolveGenerationId*(stateDir, requested: string): string =
  ## Resolve a (possibly partial) generation id to a full id. An empty
  ## `requested` returns the immediately-previous generation (the
  ## second-newest by activation timestamp). A non-empty value is
  ## matched exactly, then as an unambiguous prefix.
  let all = enumerateSystemGenerations(stateDir)
  if requested.len == 0:
    if all.len <= 1:
      raiseSystemStateDirInvalid(
        "no previous system generation to roll back to")
    # all is oldest-first; the active one is the newest, "previous" is
    # the newest that is not the active one.
    let activeId = readCurrentGenerationId(stateDir)
    var ordered: seq[string]
    for rec in all:
      ordered.add(rec.generationId)
    ordered.reverse()                   # newest first
    for id in ordered:
      if id != activeId:
        return id
    raiseSystemStateDirInvalid(
      "no previous system generation to roll back to")
  # Exact match.
  for rec in all:
    if rec.generationId == requested:
      return requested
  # Unambiguous prefix.
  var matches: seq[string]
  for rec in all:
    if rec.generationId.startsWith(requested):
      matches.add(rec.generationId)
  if matches.len == 0:
    raiseSystemStateDirInvalid(
      "no system generation matches id '" & requested & "'")
  if matches.len > 1:
    matches.sort()
    raiseSystemStateDirInvalid(
      "generation id '" & requested & "' is ambiguous: " &
      matches.join(", "))
  return matches[0]

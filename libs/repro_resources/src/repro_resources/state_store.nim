## L1 (Ephemeral-State-Leases.md §3): the persistent, reconstructable
## resource-state store.
##
## Between `repro` invocations there is no in-memory desired graph and no
## live provider closure — only what was written to disk. This module is
## that on-disk record: one file per materialized resource under a
## `.repro/state/` directory, holding everything a later run (or the L3
## reaper) needs to reconstruct the `ResourceInstance` and drive its
## provider WITHOUT the original graph:
##
##   * `address`, `typeId`, `determinism`, `dependsOn` (reverse-topo reap
##     order),
##   * the resource's SERIALIZED attrs — the `ExtensionBox` payload,
##     carried as `(attrsTypeId, attrsJson)` through the SAME
##     Typed-Graph-Extensions marshaller the RP protocol lane uses
##     (`marshalAttrs` / `unmarshalAttrs` in `marshal.nim`); this module
##     does NOT invent a new attrs serialization,
##   * `identity` + last-observed `digest` (the reuse / cache-hit index),
##   * lease fields (`holders: consumerId->deadline`, `effectiveDeadline`,
##     `lastRenewed`) — defined + round-tripped now, populated by L2/L3.
##
## Writes are ATOMIC: a record is serialized to a temp file in the same
## directory and `moveFile`-renamed over the destination, so a crash or a
## concurrent run never observes a half-written record (a partial temp is
## simply never renamed and is ignored on read). The record body is a
## small binary envelope built on `repro_core`'s length-prefixed
## primitives — the same codec vocabulary `protocol.nim` uses — so the
## `Digest256` array + the attrs payload survive verbatim (no lossy JSON
## of binary bytes).

import std/[os, tables, times, options]
from std/strutils import toHex, startsWith, endsWith
from std/algorithm import sort, sortedByIt

import blake3
import ssz_serialization
import repro_core                       # writeString / readString / writeU32Le …
from repro_home_generations/pointer import Digest256, DigestSize
import repro_resources/instance
import repro_resources/marshal          # marshalAttrs / unmarshalAttrs (extension registry)

const
  StateRecordMagic = "RSST"             ## resource-state store, record
  StateRecordVersion = 2'u32
    ## LEGACY hand-rolled LE framing (magic + u32 version). v2:
    ## `effectiveDeadline` is an OPTIONAL deadline (presence flag + u64) so
    ## "never reap" (keep / no dated holder) is `none`, not an
    ## epoch-0/PAST sentinel that a `deadline < now -> reap` gate would
    ## wrongly destroy. v1 stored a bare u64 and is not read. Track B keeps
    ## the v2 reader (`decodeRecordLegacy`) so on-disk records written
    ## before the SSZ migration still decode — nothing on disk breaks.
  StateRecordSszVersion = 3'u16
    ## Track B (Typed-Extension-Interfaces-And-Provider-Libraries.md,
    ## Incremental-Invalidation.md §"Binary formats from Reprobuild domain
    ## types"): the CURRENT, WRITTEN format. The record body is now a
    ## versioned SSZ envelope (magic + u16 version + u16 typeId + u32
    ## payloadLen + SSZ payload + 32-byte BLAKE3 trailer) over the fixed
    ## `ResourceStateRecordSsz` mirror type — spec-mandated versioned SSZ
    ## over domain types, not a hand-written binary struct. The reader
    ## accepts BOTH the SSZ envelope (this) and the legacy LE framing
    ## (`StateRecordVersion` above): read-old / write-new, so pre-migration
    ## caches degrade to a normal read, never a crash.
  StateRecordSszTypeId = 1'u16
  RecordSuffix = ".rec"
  TempPrefix = ".tmp-"

  # SSZ collection bounds. Generous — these records are one-per-resource
  # and small; the bounds only fail a pathological / adversarial record.
  MaxStateTextBytes = 64 * 1024
  MaxStateDeps = 4096
  MaxStateHolders = 4096
  MaxAttrsBytes = 8 * 1024 * 1024

type
  StateStore* = object
    ## A handle to a `.repro/state/` directory. `root` is the store
    ## directory itself (the caller decides where `.repro/state` lives so
    ## tests can point it at a throwaway dir).
    root*: string

  ResourceStateRecord* = object
    ## One persisted, reconstructable resource. Everything here survives a
    ## process restart; nothing here references the in-memory desired
    ## graph.
    address*: string
    typeId*: string
    determinism*: ResourceDeterminism
    attrsTypeId*: string
      ## The attrs `ExtensionBox.typeId` — the key the extension registry
      ## marshaller is registered under. Usually equal to `typeId`, kept
      ## distinct so a provider that boxes attrs under a different id still
      ## round-trips.
    attrsJson*: string
      ## The marshalled attrs payload (`marshalAttrs`). Opaque to this
      ## module; rehydrated by `unmarshalAttrs(attrsTypeId, attrsJson)`.
    dependsOn*: seq[string]
    identity*: string
      ## The provider's real-world identity (`driver.identity`) at write
      ## time — the reuse correlation key.
    digest*: Digest256
      ## Last-observed / post-write digest — the cross-run cache-hit test.
    present*: bool
      ## False once destroyed; a record may linger briefly for the reaper.
    # ----- lease fields (shape defined at L1; L2 populates, L3 uses) -----
    holders*: Table[string, Time]
      ## consumerId -> that lease's deadline.
    effectiveDeadline*: Option[Time]
      ## Derived: MAX over live dated holders' deadlines — the reaper's gate
      ## (`some(t)`: reapable once `now >= t`). `none` means NEVER REAP: no
      ## dated holder, or at least one `keep` holder pinning the state with
      ## no expiry. This is deliberately an `Option`, NOT an epoch-0/PAST
      ## sentinel: a PAST sentinel would make the reaper's natural
      ## `deadline < now -> reap` gate DESTROY a pinned state. The reaper
      ## MUST skip `none` and only reap a `some(t)` with `t <= now`.
    lastRenewed*: Time
      ## Wall-clock of the most recent lease renewal.

# ---------------------------------------------------------------------------
# Store handle / directory management.
# ---------------------------------------------------------------------------

proc openStateStore*(root: string): StateStore =
  ## Open (creating on demand) the state-store directory at `root`. A
  ## typical caller passes `<projectRoot>/.repro/state`.
  createDir(root)
  StateStore(root: root)

proc recordPath(store: StateStore; address: string): string =
  ## The on-disk file for `address`. The address is a stable DSL graph key
  ## (dotted, possibly with `/`); encode it to a flat, filesystem-safe
  ## name so a nested address never escapes the store dir.
  var safe = newStringOfCap(address.len * 2)
  for ch in address:
    case ch
    of 'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-':
      safe.add(ch)
    else:
      # percent-ish escape keeping the mapping injective + reversible-free
      safe.add('%')
      safe.add(toHex(ord(ch).uint8))
  store.root / (safe & RecordSuffix)

# ---------------------------------------------------------------------------
# Binary envelope codec. Reuses repro_core's length-prefixed primitives —
# the same vocabulary protocol.nim uses — so Digest256 + opaque attrs
# bytes survive verbatim.
# ---------------------------------------------------------------------------

proc writeDigest(outp: var seq[byte]; d: Digest256) =
  for b in d:
    outp.add(b)

proc readDigest(bytes: openArray[byte]; pos: var int): Digest256 =
  if pos + DigestSize > bytes.len:
    raise newException(IOError, "truncated digest in state record")
  for i in 0 ..< DigestSize:
    result[i] = bytes[pos + i]
  pos += DigestSize

# --- Legacy LE reader (read-old). Kept verbatim so `.rec` files written
#     before the Track B SSZ migration still decode into the SAME record
#     — a pre-migration cache is a normal read, never a crash. NOTHING
#     writes this format anymore; `encodeRecord` emits the SSZ envelope. ---

proc decodeRecordLegacy(bytes: openArray[byte]): ResourceStateRecord =
  var pos = StateRecordMagic.len
  let ver = readU32Le(bytes, pos)
  if ver != StateRecordVersion:
    raise newException(IOError,
      "unsupported legacy state-record version " & $ver)
  result.address = readString(bytes, pos)
  result.typeId = readString(bytes, pos)
  result.determinism = ResourceDeterminism(int(readU32Le(bytes, pos)))
  result.attrsTypeId = readString(bytes, pos)
  result.attrsJson = readString(bytes, pos)
  let deps = int(readU32Le(bytes, pos))
  result.dependsOn = newSeq[string](deps)
  for i in 0 ..< deps:
    result.dependsOn[i] = readString(bytes, pos)
  result.identity = readString(bytes, pos)
  result.digest = readDigest(bytes, pos)
  if pos >= bytes.len:
    raise newException(IOError, "truncated present flag in state record")
  result.present = bytes[pos] != 0'u8
  inc pos
  result.holders = initTable[string, Time]()
  let holderCount = int(readU32Le(bytes, pos))
  for i in 0 ..< holderCount:
    let consumerId = readString(bytes, pos)
    let deadline = fromUnix(int64(readU64Le(bytes, pos)))
    result.holders[consumerId] = deadline
  if pos >= bytes.len:
    raise newException(IOError,
      "truncated effectiveDeadline flag in state record")
  let hasDeadline = bytes[pos] != 0'u8
  inc pos
  if hasDeadline:
    result.effectiveDeadline = some(fromUnix(int64(readU64Le(bytes, pos))))
  else:
    result.effectiveDeadline = none(Time)
  result.lastRenewed = fromUnix(int64(readU64Le(bytes, pos)))

# ---------------------------------------------------------------------------
# Track B: versioned SSZ envelope over a fixed `ResourceStateRecordSsz` mirror
# type. The append-only-per-file framing (one atomic `.rec` file per record)
# is unchanged; only the record BODY moved from hand-rolled LE primitives to
# the project-mandated versioned-SSZ format (Incremental-Invalidation.md
# §"Binary formats from Reprobuild domain types"). Modelled on
# repro_dev_env_artifacts/codec.nim: a proper SSZ mirror type for the fixed
# schema, `SSZ.encode/decode` kept in NON-generic concrete procs (Nim #11225
# generic-sandwich), and a magic+version envelope with a BLAKE3 trailer.
# ---------------------------------------------------------------------------

const
  SszEnvelopeHeaderLen = 4 + 2 + 2 + 4   # magic + version + typeId + payloadLen
  SszEnvelopeTrailerLen = 32             # BLAKE3-256 over header+payload

type
  StateStoreCodecError* = object of CatchableError

  SszText = List[byte, MaxStateTextBytes]

  StateHolderSsz = object
    consumerId: SszText
    deadlineUnix: uint64

  ResourceStateRecordSsz = object
    ## Fixed-schema SSZ mirror of `ResourceStateRecord`. Field order is the
    ## schema; changing it requires a new `StateRecordSszTypeId`/version.
    address: SszText
    typeId: SszText
    determinism: uint32
    attrsTypeId: SszText
    attrsJson: List[byte, MaxAttrsBytes]
    dependsOn: List[SszText, MaxStateDeps]
    identity: SszText
    digest: array[DigestSize, byte]
    present: bool
    holders: List[StateHolderSsz, MaxStateHolders]
    hasEffectiveDeadline: bool
    effectiveDeadlineUnix: uint64
    lastRenewedUnix: uint64

proc failCodec(message: string) {.noreturn.} =
  raise newException(StateStoreCodecError, message)

proc toStateText(value: string): SszText =
  if value.len > MaxStateTextBytes:
    failCodec("state-record text field exceeds SSZ bound")
  var wire = newSeq[byte](value.len)
  for i, ch in value:
    wire[i] = byte(ord(ch))
  SszText.init(wire)

proc fromStateText(value: SszText): string =
  let raw = value.asSeq()
  result = newString(raw.len)
  for i, b in raw:
    result[i] = char(b)

proc toSszRecord(rec: ResourceStateRecord): ResourceStateRecordSsz =
  result.address = toStateText(rec.address)
  result.typeId = toStateText(rec.typeId)
  result.determinism = uint32(ord(rec.determinism))
  result.attrsTypeId = toStateText(rec.attrsTypeId)
  if rec.attrsJson.len > MaxAttrsBytes:
    failCodec("state-record attrs payload exceeds SSZ bound")
  var attrsBytes = newSeq[byte](rec.attrsJson.len)
  for i, ch in rec.attrsJson:
    attrsBytes[i] = byte(ord(ch))
  result.attrsJson = List[byte, MaxAttrsBytes].init(attrsBytes)
  var deps: seq[SszText] = @[]
  if rec.dependsOn.len > MaxStateDeps:
    failCodec("state-record dependsOn exceeds SSZ bound")
  for dep in rec.dependsOn:
    deps.add(toStateText(dep))
  result.dependsOn = List[SszText, MaxStateDeps].init(deps)
  result.identity = toStateText(rec.identity)
  result.digest = rec.digest
  result.present = rec.present
  # Tables have no stable iteration order; sort holders by consumerId so the
  # SSZ payload (hence the on-disk bytes) is canonical for a given record.
  var holders: seq[StateHolderSsz] = @[]
  if rec.holders.len > MaxStateHolders:
    failCodec("state-record holders exceeds SSZ bound")
  var keys: seq[string] = @[]
  for consumerId in rec.holders.keys:
    keys.add(consumerId)
  for consumerId in keys.sortedByIt(it):
    holders.add(StateHolderSsz(
      consumerId: toStateText(consumerId),
      deadlineUnix: uint64(rec.holders[consumerId].toUnix())))
  result.holders = List[StateHolderSsz, MaxStateHolders].init(holders)
  if rec.effectiveDeadline.isSome:
    result.hasEffectiveDeadline = true
    result.effectiveDeadlineUnix = uint64(rec.effectiveDeadline.get.toUnix())
  else:
    result.hasEffectiveDeadline = false
    result.effectiveDeadlineUnix = 0
  result.lastRenewedUnix = uint64(rec.lastRenewed.toUnix())

proc fromSszRecord(wire: ResourceStateRecordSsz): ResourceStateRecord =
  result.address = fromStateText(wire.address)
  result.typeId = fromStateText(wire.typeId)
  result.determinism = ResourceDeterminism(int(wire.determinism))
  result.attrsTypeId = fromStateText(wire.attrsTypeId)
  let attrsBytes = wire.attrsJson.asSeq()
  result.attrsJson = newString(attrsBytes.len)
  for i, b in attrsBytes:
    result.attrsJson[i] = char(b)
  result.dependsOn = @[]
  for dep in wire.dependsOn:
    result.dependsOn.add(fromStateText(dep))
  result.identity = fromStateText(wire.identity)
  result.digest = wire.digest
  result.present = wire.present
  result.holders = initTable[string, Time]()
  for holder in wire.holders:
    result.holders[fromStateText(holder.consumerId)] =
      fromUnix(int64(holder.deadlineUnix))
  if wire.hasEffectiveDeadline:
    result.effectiveDeadline = some(fromUnix(int64(wire.effectiveDeadlineUnix)))
  else:
    result.effectiveDeadline = none(Time)
  result.lastRenewed = fromUnix(int64(wire.lastRenewedUnix))

# `SSZ.encode`/`SSZ.decode` are the generic seam #11225 warns about: keep
# them in these concrete, NON-generic wrappers so no generic proc closes over
# the SSZ machinery.
proc encodeSszPayload(rec: ResourceStateRecord): seq[byte] =
  try:
    SSZ.encode(toSszRecord(rec))
  except SszError as err:
    failCodec("could not SSZ-encode state record: " & err.msg)
  except IOError as err:
    failCodec("could not write SSZ state-record payload: " & err.msg)

proc decodeSszPayload(payload: openArray[byte]): ResourceStateRecordSsz =
  try:
    SSZ.decode(payload, ResourceStateRecordSsz)
  except SszError as err:
    failCodec("invalid SSZ state-record payload: " & err.msg)
  except IOError as err:
    failCodec("could not read SSZ state-record payload: " & err.msg)

proc encodeRecord(rec: ResourceStateRecord): seq[byte] =
  ## WRITE-NEW: emit the versioned SSZ envelope (the only format written).
  let payload = encodeSszPayload(rec)
  result = newSeqOfCap[byte](
    SszEnvelopeHeaderLen + payload.len + SszEnvelopeTrailerLen)
  for ch in StateRecordMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(StateRecordSszVersion)
  result.writeU16Le(StateRecordSszTypeId)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)
  let checksum = blake3.digest(result)   # over header + payload
  for b in checksum:
    result.add(b)

proc decodeSszEnvelope(bytes: openArray[byte]): ResourceStateRecord =
  if bytes.len < SszEnvelopeHeaderLen + SszEnvelopeTrailerLen:
    failCodec("SSZ state-record envelope too short")
  var pos = StateRecordMagic.len
  let version = readU16Le(bytes, pos)
  if version != StateRecordSszVersion:
    failCodec("unsupported SSZ state-record version " & $version)
  let typeId = readU16Le(bytes, pos)
  if typeId != StateRecordSszTypeId:
    failCodec("unexpected SSZ state-record type id " & $typeId)
  let payloadLen = int(readU32Le(bytes, pos))
  let payloadStart = pos
  let payloadStop = payloadStart + payloadLen
  if payloadStop + SszEnvelopeTrailerLen != bytes.len:
    failCodec("SSZ state-record envelope length mismatch")
  let expected = blake3.digest(bytes.toOpenArray(0, payloadStop - 1))
  for i in 0 ..< SszEnvelopeTrailerLen:
    if bytes[payloadStop + i] != expected[i]:
      failCodec("SSZ state-record checksum mismatch")
  var payload = newSeq[byte](payloadLen)
  for i in 0 ..< payloadLen:
    payload[i] = bytes[payloadStart + i]
  fromSszRecord(decodeSszPayload(payload))

proc decodeRecord(bytes: openArray[byte]): ResourceStateRecord =
  ## READ-BOTH dispatcher: after the shared `RSST` magic, sniff the format
  ## by the first version half-word. The SSZ envelope's version is a u16 LE
  ## `StateRecordSszVersion` (3); the legacy LE framing's version is a u32 LE
  ## `StateRecordVersion` (2), whose low half-word is therefore 2. The two
  ## never collide (3 vs 2), so reading a u16 at the post-magic offset
  ## disambiguates cleanly. A future SSZ version bump stays > any legacy
  ## value, preserving the split.
  if bytes.len < StateRecordMagic.len + 2:
    raise newException(IOError, "state record too short for magic")
  for i, ch in StateRecordMagic:
    if bytes[i] != byte(ord(ch)):
      raise newException(IOError, "bad state-record magic")
  var probe = StateRecordMagic.len
  let versionWord = readU16Le(bytes, probe)
  if versionWord == StateRecordSszVersion:
    decodeSszEnvelope(bytes)
  else:
    decodeRecordLegacy(bytes)

# ---------------------------------------------------------------------------
# Public store operations.
# ---------------------------------------------------------------------------

proc writeStateRecord*(store: StateStore; rec: ResourceStateRecord) =
  ## Persist `rec` atomically: serialize to a temp file in the store
  ## directory, then `moveFile` it over the destination. A crash before
  ## the rename leaves the prior record (or absence) intact — the partial
  ## temp is never observed as a record and is skipped by `listStateRecords`.
  createDir(store.root)
  let dest = recordPath(store, rec.address)
  let tmp = store.root / (TempPrefix & extractFilename(dest))
  let bytes = encodeRecord(rec)
  var s = newString(bytes.len)
  if bytes.len > 0:
    copyMem(addr s[0], unsafeAddr bytes[0], bytes.len)
  writeFile(tmp, s)
  # moveFile is a rename within one directory => atomic on POSIX/NTFS.
  moveFile(tmp, dest)

proc buildStateRecord*(inst: ResourceInstance; binding: ResourceBinding;
                       holders: Table[string, Time] = initTable[string, Time]();
                       effectiveDeadline: Option[Time] = none(Time);
                       lastRenewed: Time = fromUnix(0)): ResourceStateRecord =
  ## Assemble a record from a reconciled resource + its recorded binding.
  ## The attrs are serialized HERE via the extension-registry marshaller
  ## (`marshalAttrs`) — the exact seam the RP protocol lane uses — so the
  ## store never re-implements attrs serialization.
  ResourceStateRecord(
    address: inst.address,
    typeId: inst.typeId,
    determinism: inst.determinism,
    attrsTypeId: inst.attrs.typeId,
    attrsJson: marshalAttrs(inst.attrs),
    dependsOn: inst.dependsOn,
    identity: binding.resourceId,
    digest: binding.postWriteDigest,
    present: binding.present,
    holders: holders,
    effectiveDeadline: effectiveDeadline,
    lastRenewed: lastRenewed)

proc writeStateRecord*(store: StateStore; inst: ResourceInstance;
                       binding: ResourceBinding;
                       holders: Table[string, Time] = initTable[string, Time]();
                       effectiveDeadline: Option[Time] = none(Time);
                       lastRenewed: Time = fromUnix(0)) =
  ## Convenience overload: build + atomically write in one call.
  writeStateRecord(store,
    buildStateRecord(inst, binding, holders, effectiveDeadline, lastRenewed))

proc readStateRecord*(store: StateStore; address: string): ResourceStateRecord =
  ## Read the record for `address`. Raises `IOError` if absent (callers
  ## use `hasStateRecord` to probe).
  let p = recordPath(store, address)
  if not fileExists(p):
    raise newException(IOError, "no state record for address '" & address & "'")
  let s = readFile(p)
  var bytes = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr bytes[0], unsafeAddr s[0], s.len)
  decodeRecord(bytes)

proc hasStateRecord*(store: StateStore; address: string): bool =
  fileExists(recordPath(store, address))

proc removeStateRecord*(store: StateStore; address: string) =
  ## Remove the record for `address` (idempotent — a missing record is a
  ## no-op, matching the reaper's crash-safety contract).
  let p = recordPath(store, address)
  if fileExists(p):
    removeFile(p)

proc listStateRecords*(store: StateStore): seq[ResourceStateRecord] =
  ## Every persisted record, in a stable (sorted-by-filename) order.
  ## Temp files (a partial write) are skipped, so an interrupted write is
  ## invisible here.
  result = @[]
  if not dirExists(store.root):
    return
  var names: seq[string] = @[]
  for kind, path in walkDir(store.root):
    if kind != pcFile: continue
    let fn = extractFilename(path)
    if fn.startsWith(TempPrefix): continue
    if not fn.endsWith(RecordSuffix): continue
    names.add(path)
  names.sort()
  for path in names:
    let s = readFile(path)
    var bytes = newSeq[byte](s.len)
    if s.len > 0:
      copyMem(addr bytes[0], unsafeAddr s[0], s.len)
    result.add(decodeRecord(bytes))

proc reconstructInstance*(rec: ResourceStateRecord): ResourceInstance =
  ## Rebuild a `ResourceInstance` from a persisted record WITHOUT the
  ## original desired graph: the attrs box is re-hydrated through the
  ## extension registry (`unmarshalAttrs`), so the returned instance is
  ## equal to the original (same typeId/address/attrs/determinism/dependsOn)
  ## and can be fed to `lookupResourceProvider(typeId).driver.observe/apply`.
  ## The attrs marshaller for `attrsTypeId` MUST be registered in this
  ## process (the reaper/consumer links the provider module) — an unknown
  ## id is a HARD `KeyError`, never a silent drop.
  ResourceInstance(
    typeId: rec.typeId,
    address: rec.address,
    attrs: unmarshalAttrs(rec.attrsTypeId, rec.attrsJson),
    dependsOn: rec.dependsOn,
    determinism: rec.determinism)

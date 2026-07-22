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
from std/algorithm import sort

import repro_core                       # writeString / readString / writeU32Le …
from repro_home_generations/pointer import Digest256, DigestSize
import repro_resources/instance
import repro_resources/marshal          # marshalAttrs / unmarshalAttrs (extension registry)

const
  StateRecordMagic = "RSST"             ## resource-state store, record
  StateRecordVersion = 2'u32
    ## v2: `effectiveDeadline` is an OPTIONAL deadline (presence flag +
    ## u64) so "never reap" (keep / no dated holder) is `none`, not an
    ## epoch-0/PAST sentinel that a `deadline < now -> reap` gate would
    ## wrongly destroy. v1 stored a bare u64 and is not read.
  RecordSuffix = ".rec"
  TempPrefix = ".tmp-"

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

proc encodeRecord(rec: ResourceStateRecord): seq[byte] =
  for ch in StateRecordMagic:
    result.add(byte(ord(ch)))
  result.writeU32Le(StateRecordVersion)
  result.writeString(rec.address)
  result.writeString(rec.typeId)
  result.writeU32Le(uint32(ord(rec.determinism)))
  result.writeString(rec.attrsTypeId)
  result.writeString(rec.attrsJson)
  result.writeU32Le(uint32(rec.dependsOn.len))
  for dep in rec.dependsOn:
    result.writeString(dep)
  result.writeString(rec.identity)
  result.writeDigest(rec.digest)
  result.add(if rec.present: 1'u8 else: 0'u8)
  # lease fields
  result.writeU32Le(uint32(rec.holders.len))
  for consumerId, deadline in rec.holders:
    result.writeString(consumerId)
    result.writeU64Le(uint64(deadline.toUnix()))
  # effectiveDeadline: presence flag (1 = a dated reap deadline, 0 = never
  # reap / none) followed, when present, by the u64 unix deadline.
  if rec.effectiveDeadline.isSome:
    result.add(1'u8)
    result.writeU64Le(uint64(rec.effectiveDeadline.get.toUnix()))
  else:
    result.add(0'u8)
  result.writeU64Le(uint64(rec.lastRenewed.toUnix()))

proc decodeRecord(bytes: openArray[byte]): ResourceStateRecord =
  var pos = 0
  if bytes.len < StateRecordMagic.len:
    raise newException(IOError, "state record too short for magic")
  for i, ch in StateRecordMagic:
    if bytes[i] != byte(ord(ch)):
      raise newException(IOError, "bad state-record magic")
  pos = StateRecordMagic.len
  let ver = readU32Le(bytes, pos)
  if ver != StateRecordVersion:
    raise newException(IOError,
      "unsupported state-record version " & $ver)
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

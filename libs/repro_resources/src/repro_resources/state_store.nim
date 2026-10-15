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
##   * lease fields (`holders: consumerId->deadline` for the DATED holders,
##     `keepHolders` for the `keep` holders that pin with no deadline,
##     `keepHoldersKnown`, `effectiveDeadline`, `lastRenewed`) — defined +
##     round-tripped here, populated by L2 (reconcile) and L4 (daemon renew),
##     read by the L3 reaper,
##   * `providerArtifact` — HOW TO REACH THE PROVIDER that owns `typeId`
##     (Ephemeral-State-Leases.md §4.2, v5). A reaper can reconstruct a record
##     of an out-of-tree type and still have no route to its real-world state:
##     the destroy has to go over a provider SESSION, and opening one needs the
##     provider binary's path + its content-addressed artifact id. Recording it
##     WITH the record is what makes the session transport reachable after a
##     daemon restart, with no re-evaluation of the recipe that produced it —
##     the §4.3 "the on-disk store is the source of truth" property applied to
##     the transport as well as to the lease.
##
## Writes are ATOMIC and DURABLE: a record is serialized to a temp file
## (unique per write) in the same directory, the temp is flushed + fsynced,
## renamed over the destination, and the directory is fsynced. Atomic
## alone (the rename) protects against a PROCESS crash; it does not protect
## against a power loss or kernel crash, after which the rename can be
## durable and the data not — a zero-length or truncated `.rec`, i.e. an
## undecodable record (Ephemeral-State-Leases.md §4.2–§4.3). The record
## body is a versioned SSZ envelope (below) so the `Digest256` array + the
## attrs payload survive verbatim (no lossy JSON of binary bytes).
##
## READING NEVER LETS ONE RECORD TAKE THE STORE OFFLINE. `scanStateRecords`
## guards every record on its own: a record written by a NEWER repro is
## FOREIGN (left untouched, reported, never reaped — several repro versions
## share one per-user store), and genuine corruption is QUARANTINED (moved
## into `quarantine/` under a findable name, bytes kept, reported) so the
## store returns to a fully decodable state. Before this, one bad `.rec`
## made the listing raise and every reap sweep reap nothing, forever.

import std/[os, tables, times, options, atomics]
from std/strutils import toHex, startsWith, endsWith
from std/algorithm import sort, sortedByIt

when defined(windows):
  import std/winlean
else:
  # Qualified-only: std/posix exports its own `Time`, which would make every
  # `Time` in this module ambiguous.
  from std/posix import nil

import blake3
import ssz_serialization
import repro_core                       # writeString / readString / writeU32Le …
from repro_home_generations/pointer import Digest256, DigestSize
import repro_resources/instance
import repro_resources/marshal          # marshalAttrs / unmarshalAttrs /
                                        # unmarshalAttrsOrRaw (extension registry)

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
  StateRecordSszVersion* = 5'u16
    ## Track B (Typed-Extension-Interfaces-And-Provider-Libraries.md,
    ## Incremental-Invalidation.md §"Binary formats from Reprobuild domain
    ## types"): the CURRENT, WRITTEN format. The record body is a versioned
    ## SSZ envelope (magic + u16 version + u16 typeId + u32 payloadLen + SSZ
    ## payload + 32-byte BLAKE3 trailer) over the fixed
    ## `ResourceStateRecordSsz` mirror type — spec-mandated versioned SSZ
    ## over domain types, not a hand-written binary struct.
    ##
    ## v5 adds `providerArtifact` (Ephemeral-State-Leases.md §4.2): the
    ## provider binary a reaper opens a SESSION to in order to destroy this
    ## record's state. Before it, a reaping process could only learn that from
    ## its own memory, so no shipped code path could give the daemon the
    ## artifact and the session transport was unreachable from the product
    ## (reprobuild-pm issue
    ## 2026-10-14-no-production-path-enables-the-daemons-session-reap-transport).
    ##
    ## v4 added `keepHolders` + `keepHoldersKnown` to the mirror: before it, a
    ## `keep` holder was recorded nowhere, so `effectiveDeadline == none`
    ## could not say whether a keep holder pinned the state or no dated holder
    ## existed, and no reader could name the pin (reprobuild-pm issue
    ## 2026-10-09-a-keep-holders-identity-is-never-persisted-in-a-lease-record).
    ##
    ## The reader accepts FOUR framings: this v5 envelope, the v4 envelope
    ## (`StateRecordSszVersionV4`, the same mirror without the provider
    ## artifact), the v3 envelope (`StateRecordSszVersionV3`, v4 without the
    ## keep-holder fields), and the legacy LE framing (`StateRecordVersion`
    ## above). Read-old / write-new: a pre-v5 record decodes with
    ## `providerArtifact = none`, a pre-v4 record also with no keep holders and
    ## `keepHoldersKnown = false` (true if it carries a dated deadline or was
    ## never renewed — see `pre4KeepHoldersKnown`), and the next write upgrades
    ## it to v5.
  StateRecordSszVersionV4 = 4'u16
    ## The pre-provider-artifact SSZ envelope. READ-ONLY: nothing writes it.
    ## Its payload is `ResourceStateRecordSszV4`.
  StateRecordSszVersionV3 = 3'u16
    ## The pre-keep-holder SSZ envelope. READ-ONLY: nothing writes it. Its
    ## payload is `ResourceStateRecordSszV3`.
  StateRecordSszTypeId = 1'u16
  RecordSuffix = ".rec"
  TempPrefix = ".tmp-"
  StaleTempAge = initDuration(hours = 1)
    ## A temp older than this belongs to a write that died before its rename
    ## (a crash between create and rename). A live write holds its temp for
    ## the duration of one small write + sync + rename, i.e. milliseconds, so
    ## an hour is far outside any live writer's window. Temp names are unique
    ## per write, so nothing else would ever overwrite such an orphan: without
    ## this sweep each crashed write would leak one file for good.
  QuarantineDirName* = "quarantine"
    ## Subdirectory of the store root that undecodable records are moved
    ## into. Listing walks only the root's FILES, so it is invisible there.

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

  ResourceProviderArtifactRef* = object
    ## The provider binary that serves a resource `typeId` — the three fields a
    ## session launch needs, a strict subset of the RP runtime's
    ## `ProviderArtifactRef`.
    ##
    ## It lives HERE, with the store, because from v5 on it is PERSISTED in the
    ## state record (see `ResourceStateRecord.providerArtifact`). One definition
    ## serves all three consumers — the store, the L3 reaper's session transport,
    ## and the CLI's run-edge resolver — so a field cannot be added to one
    ## reader's idea of a provider artifact and not another's.
    binaryPath*: string
    providerArtifactId*: string
    workingDir*: string

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
      ## The DATED holders: consumerId -> that lease's deadline
      ## (`immediate` / `delayed`).
    keepHolders*: seq[string]
      ## The consumer ids holding a `keep` lease — pinned with no deadline,
      ## so they have no entry in `holders` (Ephemeral-State-Leases §2.3:
      ## keep never auto-reaps and dominates every dated holder). Canonical:
      ## sorted ascending, no duplicates; the codec writes it that way
      ## whatever order a caller built it in.
      ##
      ## Invariant: a consumer id is in AT MOST ONE of `holders` /
      ## `keepHolders` — a consumer holds one lease on a state, under the
      ## policy it last renewed with. The codec refuses a record that breaks
      ## it rather than persisting a holder with two answers.
      ##
      ## A keep holder persists across runs: it leaves this list only when
      ## that same consumer renews under a dated policy (it moves to
      ## `holders`), or the record is removed (explicit teardown / reap).
    keepHoldersKnown*: bool
      ## Whether `keepHolders` is the COMPLETE keep-holder set. True for every
      ## record written in the v4 format by current code. For a record decoded
      ## from the v3 SSZ or legacy LE formats, which never recorded keep
      ## holders, it is false — UNLESS that record carries a dated
      ## `effectiveDeadline` or was never renewed (`lastRenewed ==
      ## fromUnix(0)`), either of which proves no keep holder existed (see
      ## `pre4KeepHoldersKnown`). An unknown record therefore always has a
      ## `none` deadline and may be pinned by a keep holder nobody can name,
      ## so a renewal of it stays unknown and never re-arms a deadline under
      ## it (see `reconcile.applyHolderRenewal`).
      ##
      ## Written to disk as-is (v4) so a still-unknown record stays unknown
      ## across a re-write. NOTE Nim's object default for a `bool` is
      ## `false`: a record built with an object constructor that omits this
      ## field claims NOT to know its keep holders. `buildStateRecord` (and the
      ## convenience `writeStateRecord` overload) default it to `true`.
    effectiveDeadline*: Option[Time]
      ## Derived: the reaper's gate (`some(t)`: reapable once `now >= t`).
      ##
      ##   * `none` with non-empty `keepHolders` — PINNED by those keep
      ##     holders; never reap.
      ##   * `none` with empty `keepHolders` and `keepHoldersKnown` — no holder
      ##     pins it and none has a deadline: never reap (no lease asks for it).
      ##   * `none` with `keepHoldersKnown == false` — a pre-v4 record: may be
      ##     an anonymous keep pin; never reap.
      ##   * `some(t)` — MAX over the dated holders' deadlines; only possible
      ##     when no keep holder is recorded.
      ##
      ## This is deliberately an `Option`, NOT an epoch-0/PAST sentinel: a
      ## PAST sentinel would make the reaper's natural `deadline < now ->
      ## reap` gate DESTROY a pinned state. The reaper MUST skip `none` and
      ## only reap a `some(t)` with `t <= now`.
    lastRenewed*: Time
      ## Wall-clock of the most recent lease renewal.
    providerArtifact*: Option[ResourceProviderArtifactRef]
      ## v5 (Ephemeral-State-Leases.md §4.2): the provider binary a reaper
      ## opens a SESSION to in order to destroy this state, written by the
      ## reconcile that materialized it over such a session. `none` for a
      ## resource whose driver was linked in the materializing process (an
      ## in-tree type has no artifact to launch) and for every record written
      ## before v5.
      ##
      ## WHY IT IS IN THE RECORD. A reap needs two things the record otherwise
      ## supplies on its own — `typeId` and the attrs payload — plus a ROUTE to
      ## the code that knows how to destroy the thing. For an out-of-tree type
      ## the reaping process has no such code and cannot get it: the daemon is a
      ## fixed binary with no recipe to import. Carrying the route here makes
      ## the §4.2 session transport reachable from the on-disk store alone, so
      ## it survives a daemon restart and needs no re-evaluation — the same
      ## reason §4.3 puts the lease itself on disk rather than in daemon memory.
      ##
      ## IT CAN GO STALE, and that is tolerated rather than prevented: the
      ## recorded path is a build output, so a rebuild or a store garbage
      ## collection can leave it naming nothing. A stale ref makes the session
      ## fail to launch, which is a PER-RECORD reap failure `reapOnce` already
      ## records and §4.5 already reports — not a sweep failure, and not
      ## something the record can be trusted to notice about itself. An artifact
      ## registered with the running daemon (`registerLeaseReapProvider`) comes
      ## from a run that is using the type right now, so it is fresher and
      ## OUTRANKS this one; see `reapTransportFactory`.

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

proc pre4KeepHoldersKnown(effectiveDeadline: Option[Time];
                          lastRenewed: Time): bool =
  ## Can a record decoded from a format that never recorded keep holders (v3
  ## SSZ, legacy LE) be trusted to have NONE? (Ephemeral-State-Leases §3.)
  ##
  ##   * It carries `some(deadline)`: every pre-v4 writer of a lease renewal
  ##     — the reconcile merge and the daemon's renew — wrote a dated
  ##     deadline only when the renewal it applied had no `keep` holder, so
  ##     the record already says nothing pins it, and a pre-v4 reaper already
  ##     acted on that.
  ##   * It was never renewed (`lastRenewed == fromUnix(0)`): every pre-v4
  ##     renewal set `lastRenewed = now`, and the non-leased write left it at
  ##     the epoch default, so no lease ever touched it. Treating it as
  ##     unknown would pin it forever (see `reconcile.applyHolderRenewal`)
  ##     for a holder that never existed.
  ##
  ## Anything else — a renewed record whose deadline is `none` — may hide an
  ## anonymous keep pin: unknown.
  ##
  ## Decided HERE, at decode, rather than in the renewal: it is a fact about
  ## what the OLD writers did, so it belongs with the old readers, and every
  ## consumer of the record (the reaper, a refusal naming holders) then sees
  ## the same answer instead of each re-deriving it.
  effectiveDeadline.isSome or lastRenewed == fromUnix(0)

# Checked narrowing of decoded integers. A plain `ResourceDeterminism(x)` or
# `int64(u64)` conversion of an out-of-range value raises a `RangeDefect`,
# which is NOT a `CatchableError`: a corrupt record would then escape the
# per-record guard in `scanStateRecords` and abort the whole sweep again —
# the exact failure that guard exists to prevent. Every decoder path narrows
# through these instead, so ANY bad byte surfaces as a catchable error.

proc decodeDeterminism(raw: uint32): ResourceDeterminism =
  if raw > uint32(ord(high(ResourceDeterminism))):
    raise newException(IOError,
      "state record determinism " & $raw & " is out of range")
  ResourceDeterminism(int(raw))

proc decodeUnixTime(raw: uint64): Time =
  ## The writer stores `uint64(t.toUnix())`, which only ever succeeds for a
  ## non-negative `toUnix()`; anything above `high(int64)` is corruption.
  if raw > uint64(high(int64)):
    raise newException(IOError,
      "state record timestamp " & $raw & " is out of range")
  fromUnix(int64(raw))

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
  result.determinism = decodeDeterminism(readU32Le(bytes, pos))
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
    let deadline = decodeUnixTime(readU64Le(bytes, pos))
    result.holders[consumerId] = deadline
  # The legacy framing never recorded keep holders (see `keepHoldersKnown`);
  # whether it can be TRUSTED to have none is decided from the deadline and
  # `lastRenewed`, read below.
  result.keepHolders = @[]
  if pos >= bytes.len:
    raise newException(IOError,
      "truncated effectiveDeadline flag in state record")
  let hasDeadline = bytes[pos] != 0'u8
  inc pos
  if hasDeadline:
    result.effectiveDeadline = some(decodeUnixTime(readU64Le(bytes, pos)))
  else:
    result.effectiveDeadline = none(Time)
  result.lastRenewed = decodeUnixTime(readU64Le(bytes, pos))
  result.keepHoldersKnown =
    pre4KeepHoldersKnown(result.effectiveDeadline, result.lastRenewed)

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

  ForeignStateRecordError* = object of CatchableError
    ## The record was written by a NEWER repro: its envelope version is
    ## greater than `StateRecordSszVersion`. It is not corrupt, it is not
    ## this reader's to interpret — so it must be neither reaped, quarantined,
    ## nor overwritten (a renew that rewrote it would downgrade it).
    version*: uint16

  SszText = List[byte, MaxStateTextBytes]

  StateHolderSsz = object
    consumerId: SszText
    deadlineUnix: uint64

  ResourceStateRecordSsz = object
    ## Fixed-schema SSZ mirror of `ResourceStateRecord` — the v5 schema
    ## (`StateRecordSszVersion`). Field order is the schema; changing it
    ## requires a new `StateRecordSszTypeId`/version.
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
    keepHolders: List[SszText, MaxStateHolders]
      ## v4: the keep holders, sorted + de-duplicated. `holders.len +
      ## keepHolders.len` is bounded by `MaxStateHolders` TOGETHER: it is one
      ## holder population, split by policy.
    keepHoldersKnown: bool
      ## v4: `ResourceStateRecord.keepHoldersKnown`, written as-is.
    hasEffectiveDeadline: bool
    effectiveDeadlineUnix: uint64
    lastRenewedUnix: uint64
    hasProviderArtifact: bool
      ## v5: whether the three fields below carry a provider artifact ref.
      ## An explicit presence flag rather than "empty `binaryPath` means
      ## none", because an empty path is a corrupt ref and must be
      ## distinguishable from a record that never had one — `none` is the
      ## in-tree case and routes in-process, while a present-but-empty ref
      ## would be a session launch of nothing.
    providerBinaryPath: SszText
    providerArtifactId: SszText
    providerWorkingDir: SszText

  ResourceStateRecordSszV4 = object
    ## The v4 mirror (`StateRecordSszVersionV4`), kept so v4 records still
    ## decode. READ-ONLY and FROZEN: it must match what the v4 encoder wrote,
    ## byte for byte, or a v4 record stops decoding. What it lacks is the
    ## provider artifact ref.
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
    keepHolders: List[SszText, MaxStateHolders]
    keepHoldersKnown: bool
    hasEffectiveDeadline: bool
    effectiveDeadlineUnix: uint64
    lastRenewedUnix: uint64

  ResourceStateRecordSszV3 = object
    ## The v3 mirror (`StateRecordSszVersionV3`), kept so v3 records still
    ## decode. READ-ONLY and FROZEN: it must match what the v3 encoder wrote,
    ## byte for byte, or a v3 record stops decoding. What it lacks is the
    ## keep-holder fields AND the provider artifact ref.
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

proc canonicalKeepHolders(ids: openArray[string]): seq[string] =
  ## The canonical form of a keep-holder list: sorted ascending, duplicates
  ## dropped. A consumer that renewed under `keep` twice is one holder.
  result = @[]
  for id in ids:
    result.add(id)
  result.sort()
  var w = 0
  for r in 0 ..< result.len:
    if w == 0 or result[r] != result[w - 1]:
      result[w] = result[r]
      inc w
  result.setLen(w)

proc checkHolderSets(holders: Table[string, Time]; keepHolders: seq[string]) =
  ## The two holder sets are one population split by policy: bound them
  ## TOGETHER, and refuse an id that is in both (a consumer holds one lease
  ## on a state, so a record naming it twice has two answers to "when may
  ## this be reaped" and we will not persist — or trust — either).
  if holders.len + keepHolders.len > MaxStateHolders:
    failCodec("state-record holders + keepHolders exceeds SSZ bound")
  for id in keepHolders:
    if holders.hasKey(id):
      failCodec("state-record consumer '" & id &
        "' is both a dated holder and a keep holder")

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
  let keepHolders = canonicalKeepHolders(rec.keepHolders)
  checkHolderSets(rec.holders, keepHolders)
  var holders: seq[StateHolderSsz] = @[]
  var keys: seq[string] = @[]
  for consumerId in rec.holders.keys:
    keys.add(consumerId)
  for consumerId in keys.sortedByIt(it):
    holders.add(StateHolderSsz(
      consumerId: toStateText(consumerId),
      deadlineUnix: uint64(rec.holders[consumerId].toUnix())))
  result.holders = List[StateHolderSsz, MaxStateHolders].init(holders)
  var keepWire: seq[SszText] = @[]
  for consumerId in keepHolders:
    keepWire.add(toStateText(consumerId))
  result.keepHolders = List[SszText, MaxStateHolders].init(keepWire)
  result.keepHoldersKnown = rec.keepHoldersKnown
  if rec.effectiveDeadline.isSome:
    result.hasEffectiveDeadline = true
    result.effectiveDeadlineUnix = uint64(rec.effectiveDeadline.get.toUnix())
  else:
    result.hasEffectiveDeadline = false
    result.effectiveDeadlineUnix = 0
  result.lastRenewedUnix = uint64(rec.lastRenewed.toUnix())
  if rec.providerArtifact.isSome:
    let a = rec.providerArtifact.get
    # A ref with no binary path cannot launch anything, so persisting it as
    # PRESENT would turn an in-tree record into one whose reap tries to spawn
    # the empty string on every tick. Refuse at the codec, where the record is
    # still the writer's problem, rather than leave it for the reaper.
    if a.binaryPath.len == 0:
      failCodec("state-record providerArtifact has an empty binaryPath")
    result.hasProviderArtifact = true
    result.providerBinaryPath = toStateText(a.binaryPath)
    result.providerArtifactId = toStateText(a.providerArtifactId)
    result.providerWorkingDir = toStateText(a.workingDir)
  else:
    result.hasProviderArtifact = false
    result.providerBinaryPath = toStateText("")
    result.providerArtifactId = toStateText("")
    result.providerWorkingDir = toStateText("")

proc fromSszRecord(wire: ResourceStateRecordSsz): ResourceStateRecord =
  result.address = fromStateText(wire.address)
  result.typeId = fromStateText(wire.typeId)
  result.determinism = decodeDeterminism(wire.determinism)
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
      decodeUnixTime(holder.deadlineUnix)
  var keepHolders: seq[string] = @[]
  for consumerId in wire.keepHolders:
    keepHolders.add(fromStateText(consumerId))
  # Canonicalize on read too: the record a caller sees obeys the documented
  # shape even if the bytes came from somewhere other than `encodeRecord`.
  result.keepHolders = canonicalKeepHolders(keepHolders)
  checkHolderSets(result.holders, result.keepHolders)
  result.keepHoldersKnown = wire.keepHoldersKnown
  if wire.hasEffectiveDeadline:
    result.effectiveDeadline = some(decodeUnixTime(wire.effectiveDeadlineUnix))
  else:
    result.effectiveDeadline = none(Time)
  result.lastRenewed = decodeUnixTime(wire.lastRenewedUnix)
  if wire.hasProviderArtifact:
    let binaryPath = fromStateText(wire.providerBinaryPath)
    # The presence flag and an empty path contradict each other; the encoder
    # refuses to write that pair, so reading it means the bytes are not what
    # this codec produced. A `some(ref)` with no path would be handed to a
    # session launch, so it is corruption, not a tolerable oddity.
    if binaryPath.len == 0:
      failCodec("state-record providerArtifact is present with an empty " &
        "binaryPath")
    result.providerArtifact = some(ResourceProviderArtifactRef(
      binaryPath: binaryPath,
      providerArtifactId: fromStateText(wire.providerArtifactId),
      workingDir: fromStateText(wire.providerWorkingDir)))
  else:
    result.providerArtifact = none(ResourceProviderArtifactRef)

proc fromSszRecordV4(wire: ResourceStateRecordSszV4): ResourceStateRecord =
  ## READ-OLD: lift a v4 payload into the current record. Every v4 field has
  ## the same meaning in v5, so the v4 mirror is copied field-for-field into a
  ## v5 mirror and decoded by the ONE v5 reader. What v4 lacks is the provider
  ## artifact ref: a v4 writer recorded no route to the provider, so the record
  ## has none and the reaper falls back to its in-memory registry or to the
  ## in-process arm for that type (Ephemeral-State-Leases.md §4.2). There is no
  ## equivalent of `pre4KeepHoldersKnown` to decide here — an absent artifact is
  ## simply absent, never an unknown that must be treated conservatively, because
  ## nothing is pinned by it and the §4.5 finding reports a type it cannot reach.
  fromSszRecord(ResourceStateRecordSsz(
    address: wire.address,
    typeId: wire.typeId,
    determinism: wire.determinism,
    attrsTypeId: wire.attrsTypeId,
    attrsJson: wire.attrsJson,
    dependsOn: wire.dependsOn,
    identity: wire.identity,
    digest: wire.digest,
    present: wire.present,
    holders: wire.holders,
    keepHolders: wire.keepHolders,
    keepHoldersKnown: wire.keepHoldersKnown,
    hasEffectiveDeadline: wire.hasEffectiveDeadline,
    effectiveDeadlineUnix: wire.effectiveDeadlineUnix,
    lastRenewedUnix: wire.lastRenewedUnix,
    hasProviderArtifact: false,
    providerBinaryPath: toStateText(""),
    providerArtifactId: toStateText(""),
    providerWorkingDir: toStateText("")))

proc fromSszRecordV3(wire: ResourceStateRecordSszV3): ResourceStateRecord =
  ## READ-OLD: lift a v3 payload into the current record. Every v3 field has
  ## the same meaning in v4, so the v3 mirror is copied field-for-field into
  ## a v4 mirror and decoded by the ONE v4 reader (which in turn funnels into
  ## the v5 one). What v3 lacks is the keep
  ## holders, and since a v3 writer dropped them on the floor the record
  ## cannot claim to know them — unless its deadline or `lastRenewed` proves
  ## there are none: no `keepHolders`, and `keepHoldersKnown` from
  ## `pre4KeepHoldersKnown`.
  result = fromSszRecordV4(ResourceStateRecordSszV4(
    address: wire.address,
    typeId: wire.typeId,
    determinism: wire.determinism,
    attrsTypeId: wire.attrsTypeId,
    attrsJson: wire.attrsJson,
    dependsOn: wire.dependsOn,
    identity: wire.identity,
    digest: wire.digest,
    present: wire.present,
    holders: wire.holders,
    keepHolders: List[SszText, MaxStateHolders].init(newSeq[SszText]()),
    keepHoldersKnown: false,            # decided below, from the decoded record
    hasEffectiveDeadline: wire.hasEffectiveDeadline,
    effectiveDeadlineUnix: wire.effectiveDeadlineUnix,
    lastRenewedUnix: wire.lastRenewedUnix))
  result.keepHoldersKnown =
    pre4KeepHoldersKnown(result.effectiveDeadline, result.lastRenewed)

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

proc decodeSszPayloadV4(payload: openArray[byte]): ResourceStateRecordSszV4 =
  try:
    SSZ.decode(payload, ResourceStateRecordSszV4)
  except SszError as err:
    failCodec("invalid v4 SSZ state-record payload: " & err.msg)
  except IOError as err:
    failCodec("could not read v4 SSZ state-record payload: " & err.msg)

proc decodeSszPayloadV3(payload: openArray[byte]): ResourceStateRecordSszV3 =
  try:
    SSZ.decode(payload, ResourceStateRecordSszV3)
  except SszError as err:
    failCodec("invalid v3 SSZ state-record payload: " & err.msg)
  except IOError as err:
    failCodec("could not read v3 SSZ state-record payload: " & err.msg)

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
  if version != StateRecordSszVersion and
     version != StateRecordSszVersionV4 and
     version != StateRecordSszVersionV3:
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
  # Same envelope, same checksum; only the payload schema differs by version.
  if version == StateRecordSszVersionV3:
    fromSszRecordV3(decodeSszPayloadV3(payload))
  elif version == StateRecordSszVersionV4:
    fromSszRecordV4(decodeSszPayloadV4(payload))
  else:
    fromSszRecord(decodeSszPayload(payload))

proc decodeRecord(bytes: openArray[byte]): ResourceStateRecord =
  ## READ-ALL dispatcher: after the shared `RSST` magic, sniff the format
  ## by the first version half-word. The SSZ envelope's version is a u16 LE
  ## — `StateRecordSszVersion` (5, written) or one of the read-only
  ## `StateRecordSszVersionV4` (4) / `StateRecordSszVersionV3` (3); the legacy
  ## LE framing's version is a u32 LE
  ## `StateRecordVersion` (2), whose low half-word is therefore 2. None of
  ## them collide (5 / 4 / 3 vs 2), so reading a u16 at the post-magic offset
  ## disambiguates cleanly; `decodeSszEnvelope` then picks the payload schema
  ## by that same version. A future SSZ version bump stays > any legacy
  ## value, preserving the split.
  if bytes.len < StateRecordMagic.len + 2:
    raise newException(IOError, "state record too short for magic")
  for i, ch in StateRecordMagic:
    if bytes[i] != byte(ord(ch)):
      raise newException(IOError, "bad state-record magic")
  var probe = StateRecordMagic.len
  let versionWord = readU16Le(bytes, probe)
  if versionWord == StateRecordSszVersion or
     versionWord == StateRecordSszVersionV4 or
     versionWord == StateRecordSszVersionV3:
    decodeSszEnvelope(bytes)
  elif versionWord > StateRecordSszVersion:
    # A newer writer's record. Checked BEFORE the legacy fallback, which
    # would otherwise misread it as a malformed legacy record — and a
    # "corrupt" verdict gets it quarantined out from under the newer repro
    # that owns it. Nothing past the version word is trusted here.
    var err = newException(ForeignStateRecordError,
      "state record written by a newer repro (envelope version " &
      $versionWord & ", this reader knows up to " & $StateRecordSszVersion &
      ")")
    err.version = versionWord
    raise err
  else:
    decodeRecordLegacy(bytes)

# ---------------------------------------------------------------------------
# Public store operations.
# ---------------------------------------------------------------------------

var tempCounter: Atomic[int]
  ## Per-process write counter: with the pid and a nanosecond stamp it makes
  ## every temp name unique, across processes AND across threads of one.

proc uniqueSuffix(): string =
  let now = getTime()
  $getCurrentProcessId() & "-" & $(tempCounter.fetchAdd(1) + 1) & "-" &
    $now.toUnix() & $now.nanosecond

when not defined(windows):
  when defined(macosx):
    # <fcntl.h>: plain fsync(2) on macOS only hands the data to the drive,
    # whose cache may still lose it on power loss; F_FULLFSYNC asks the
    # drive to flush too. https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html
    const F_FULLFSYNC = cint(51)

  proc syncFd(fd: cint): bool =
    when defined(macosx):
      # Not every filesystem supports F_FULLFSYNC (e.g. some network
      # mounts); fall back to fsync rather than failing the write.
      if posix.fcntl(fd, F_FULLFSYNC) == 0:
        return true
    posix.fsync(fd) == 0

  proc syncDirectory(dir: string) =
    ## Make the rename itself durable: on POSIX a rename is a directory
    ## entry update, persisted only once the DIRECTORY is fsynced.
    ## Best-effort — a filesystem that cannot fsync a directory (EINVAL on
    ## some) still got the atomic rename, which is the pre-existing contract.
    let fd = posix.open(cstring(dir), posix.O_RDONLY)
    if fd < 0:
      return
    discard syncFd(fd)
    discard posix.close(fd)

proc writeFileDurable(path: string; bytes: openArray[byte]) =
  ## Write + flush + sync `path` (a fresh temp). Raises on any failure; the
  ## caller removes the temp.
  var f: File
  if not open(f, path, fmWrite):
    raise newException(IOError, "cannot open '" & path & "' for writing: " &
      osErrorMsg(osLastError()))
  try:
    if bytes.len > 0 and f.writeBuffer(unsafeAddr bytes[0], bytes.len) != bytes.len:
      raise newException(IOError, "short write to '" & path & "'")
    f.flushFile()
    when defined(windows):
      if flushFileBuffers(Handle(getOsFileHandle(f))) == 0:
        raise newException(IOError, "FlushFileBuffers of '" & path &
          "' failed: " & osErrorMsg(osLastError()))
    else:
      if not syncFd(getFileHandle(f)):
        raise newException(IOError, "fsync of '" & path & "' failed: " &
          osErrorMsg(osLastError()))
  finally:
    f.close()

proc writeStateRecord*(store: StateStore; rec: ResourceStateRecord) =
  ## Persist `rec` atomically AND durably (see the module doc): write a temp
  ## in the store directory, sync it, rename it over the destination, sync
  ## the directory. A crash before the rename leaves the prior record (or
  ## absence) intact — the temp is never observed as a record and is skipped
  ## by listing (its name starts with `TempPrefix`).
  ##
  ## The temp name is UNIQUE per write. A fixed `.tmp-<name>` let two
  ## concurrent writers of one address share a temp: one could rename the
  ## other's half-written file into place — a torn record, which a reader
  ## now (correctly) quarantines.
  createDir(store.root)
  let dest = recordPath(store, rec.address)
  let tmp = store.root /
    (TempPrefix & extractFilename(dest) & "." & uniqueSuffix())
  let bytes = encodeRecord(rec)
  try:
    writeFileDurable(tmp, bytes)
    when defined(windows):
      # MOVEFILE_WRITE_THROUGH: return only once the rename is on disk —
      # the Windows counterpart of the POSIX directory fsync below (NTFS
      # offers no fsync of a directory handle from user code).
      let wsrc = newWideCString(tmp)
      let wdst = newWideCString(dest)
      if moveFileExW(wsrc, wdst,
          MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) == 0:
        raiseOSError(osLastError(), "rename '" & tmp & "' -> '" & dest & "'")
    else:
      # rename(2) within one directory: atomic replace.
      moveFile(tmp, dest)
  except CatchableError:
    try: removeFile(tmp)
    except CatchableError: discard
    raise
  when not defined(windows):
    syncDirectory(store.root)

proc buildStateRecord*(inst: ResourceInstance; binding: ResourceBinding;
                       holders: Table[string, Time] = initTable[string, Time]();
                       effectiveDeadline: Option[Time] = none(Time);
                       lastRenewed: Time = fromUnix(0);
                       keepHolders: seq[string] = @[];
                       keepHoldersKnown = true;
                       providerArtifact =
                         none(ResourceProviderArtifactRef)):
    ResourceStateRecord =
  ## Assemble a record from a reconciled resource + its recorded binding.
  ## The attrs are serialized HERE via the extension-registry marshaller
  ## (`marshalAttrs`) — the exact seam the RP protocol lane uses — so the
  ## store never re-implements attrs serialization.
  ##
  ## `keepHoldersKnown` defaults to TRUE: a record assembled by current code
  ## knows its keep holders (possibly none). Only a renewal of a pre-v4
  ## record that could not see them passes `false` through.
  ##
  ## `providerArtifact` defaults to NONE, which is the correct answer for the
  ## in-process reconcile: the type's driver is linked in the materializing
  ## process, so there is no provider binary to record. The session reconcile
  ## passes the artifact it launched the type over
  ## (Ephemeral-State-Leases.md §4.2).
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
    keepHolders: keepHolders,
    keepHoldersKnown: keepHoldersKnown,
    effectiveDeadline: effectiveDeadline,
    lastRenewed: lastRenewed,
    providerArtifact: providerArtifact)

proc writeStateRecord*(store: StateStore; inst: ResourceInstance;
                       binding: ResourceBinding;
                       holders: Table[string, Time] = initTable[string, Time]();
                       effectiveDeadline: Option[Time] = none(Time);
                       lastRenewed: Time = fromUnix(0);
                       keepHolders: seq[string] = @[];
                       keepHoldersKnown = true;
                       providerArtifact =
                         none(ResourceProviderArtifactRef)) =
  ## Convenience overload: build + atomically write in one call.
  writeStateRecord(store,
    buildStateRecord(inst, binding, holders, effectiveDeadline, lastRenewed,
                     keepHolders, keepHoldersKnown, providerArtifact))

proc readStateRecord*(store: StateStore; address: string): ResourceStateRecord =
  ## Read the record for `address`. Raises `IOError` if absent (callers
  ## use `hasStateRecord` to probe), `ForeignStateRecordError` if a NEWER
  ## repro wrote it (a caller must then leave it alone — never rewrite it),
  ## and `IOError`/`StateStoreCodecError` if it is corrupt.
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

type
  ForeignStateRecord* = object
    ## A record a newer repro wrote (see `ForeignStateRecordError`).
    path*: string
    version*: uint16

  QuarantinedStateRecord* = object
    ## A corrupt record this scan moved aside. `quarantinePath` holds its
    ## bytes exactly as they failed to decode.
    path*, quarantinePath*, reason*: string

  UnreadableStateRecord* = object
    ## A record that could neither be decoded nor quarantined (e.g. a
    ## permission error). It stays where it is and will be met again.
    path*, reason*: string

  StateRecordScan* = object
    records*: seq[ResourceStateRecord]   ## every record that decoded
    foreign*: seq[ForeignStateRecord]
    quarantined*: seq[QuarantinedStateRecord]
    unreadable*: seq[UnreadableStateRecord]

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

type
  RestoreOutcome = enum
    roRestored    ## renamed back into place
    roSuperseded  ## the destination already exists: a newer write landed
    roFailed      ## could not tell / could not rename; the source is kept

proc renameNoReplace(src, dst: string): RestoreOutcome =
  ## Rename `src` to `dst` only if `dst` does not exist, atomically: a
  ## check-then-rename would let a writer's newer record land in between and
  ## be overwritten by the older one. POSIX `link(2)` fails with EEXIST rather
  ## than replacing; `MoveFileExW` without MOVEFILE_REPLACE_EXISTING likewise
  ## (https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-movefileexw).
  ## Only an "already exists" failure means superseded: any OTHER failure
  ## (a filesystem without hard links, an I/O error) must not be read as
  ## "a newer record is there", or the caller would delete a good record.
  when defined(windows):
    const ErrorAlreadyExists = 183'i32   # ERROR_ALREADY_EXISTS
    if moveFileExW(newWideCString(src), newWideCString(dst), 0) != 0:
      return roRestored
    let err = osLastError().int32
    if err == ErrorAlreadyExists or err == ERROR_FILE_EXISTS:
      roSuperseded
    else:
      roFailed
  else:
    if posix.link(cstring(src), cstring(dst)) != 0:
      return (if osLastError().cint == posix.EEXIST: roSuperseded else: roFailed)
    discard posix.unlink(cstring(src))
    roRestored

var quarantineCounter: Atomic[int]

proc quarantineRecord(store: StateStore; path, reason: string;
                      failed: string; scan: var StateRecordScan) =
  ## Move the undecodable record at `path` into `quarantine/` and report it.
  ## `failed` is the content that failed to decode.
  ##
  ## Race with a concurrent writer: between our read and our rename, a
  ## writer may have renamed a fresh, VALID record over `path`, and our
  ## rename would carry it off. So the moved file is re-read: if it is not
  ## the bytes that failed, it is someone's good record — put it back
  ## (unless an even newer one has landed, which supersedes it) and do not
  ## report a quarantine. The bad bytes were already replaced by the writer.
  let qdir = store.root / QuarantineDirName
  let qpath = qdir / (extractFilename(path) & "." & $getTime().toUnix() &
    "-" & $getCurrentProcessId() & "-" & $(quarantineCounter.fetchAdd(1) + 1))
  try:
    createDir(qdir)
    moveFile(path, qpath)
  except CatchableError as err:
    if not fileExists(path):
      return       # another sweep quarantined (or a remover removed) it first
    scan.unreadable.add(UnreadableStateRecord(path: path,
      reason: reason & "; could not quarantine: " & err.msg))
    return
  let moved =
    try: readFile(qpath)
    except CatchableError: failed    # cannot re-check; trust the rename
  if moved != failed:
    case renameNoReplace(qpath, path)
    of roRestored:
      discard
    of roSuperseded:
      try: removeFile(qpath)          # a newer write already replaced it
      except CatchableError: discard
    of roFailed:
      # A writer's (decodable) record is now in quarantine and could not be
      # put back. Never delete it: report where it is so it can be restored
      # by hand. It is reported as quarantined because that is where it is.
      scan.quarantined.add(QuarantinedStateRecord(path: path,
        quarantinePath: qpath,
        reason: reason & "; a concurrent write replaced the record before " &
          "it was moved aside and it could not be put back"))
    return
  scan.quarantined.add(QuarantinedStateRecord(path: path,
    quarantinePath: qpath, reason: reason))

proc scanStateRecords*(store: StateStore): StateRecordScan =
  ## Every persisted record that decodes, in a stable (sorted-by-filename)
  ## order, plus what was NOT returned and why. Never raises for a single
  ## record — one bad `.rec` must not hide the rest (the reaper sweeps from
  ## this; a raise here once meant no record on the host was ever reaped).
  ##
  ## Per record:
  ##   * vanished between the walk and the read (a concurrent remove/reap):
  ##     silently skipped — it is simply not there any more;
  ##   * written by a newer repro (`ForeignStateRecordError`): `foreign`,
  ##     file untouched;
  ##   * fails to decode for any other reason: quarantined (moved into
  ##     `quarantine/` as `<filename>.<unix-seconds>-<pid>-<n>`) and listed in
  ##     `quarantined`; if even that fails, `unreadable`.
  ## Temp files (a write in progress) are never read; one older than
  ## `StaleTempAge` is an orphan of a crashed write and is removed.
  if not dirExists(store.root):
    return
  var names: seq[string] = @[]
  for kind, path in walkDir(store.root):
    if kind != pcFile: continue
    let fn = extractFilename(path)
    if fn.startsWith(TempPrefix):
      # Never read: a write may be in progress. Only an orphan from a write
      # that died long ago is removed (see `StaleTempAge`); any failure (it
      # was renamed or removed meanwhile) is harmless and ignored.
      try:
        if getTime() - getLastModificationTime(path) > StaleTempAge:
          removeFile(path)
      except CatchableError:
        discard
      continue
    if not fn.endsWith(RecordSuffix): continue
    names.add(path)
  names.sort()
  for path in names:
    let content =
      try: readFile(path)
      except CatchableError as err:
        if fileExists(path):
          # Present but unreadable (permissions, I/O error): we cannot see
          # the bytes, so we cannot judge it corrupt — leave it in place.
          result.unreadable.add(UnreadableStateRecord(path: path,
            reason: err.msg))
        continue
    try:
      result.records.add(decodeRecord(toBytes(content)))
    except ForeignStateRecordError as err:
      result.foreign.add(ForeignStateRecord(path: path, version: err.version))
    except CatchableError as err:
      quarantineRecord(store, path, err.msg, content, result)

proc listStateRecords*(store: StateStore): seq[ResourceStateRecord] =
  ## Every record that decodes, in a stable (sorted-by-filename) order.
  ## NEVER raises for a single record: foreign records are omitted and
  ## corrupt ones quarantined, silently from this proc's point of view —
  ## callers that must report those use `scanStateRecords`.
  scanStateRecords(store).records

proc reconstructInstance*(rec: ResourceStateRecord): ResourceInstance =
  ## Rebuild a `ResourceInstance` from a persisted record WITHOUT the
  ## original desired graph: the attrs box is re-hydrated through the
  ## extension registry (`unmarshalAttrs`), so the returned instance is
  ## equal to the original (same typeId/address/attrs/determinism/dependsOn)
  ## and can be fed to `lookupResourceProvider(typeId).driver.observe/apply`.
  ## The attrs marshaller for `attrsTypeId` MUST be registered in this
  ## process (the reaper/consumer links the provider module) — an unknown
  ## id is a HARD `KeyError`, never a silent drop.
  ##
  ## USE THIS ONLY WHEN THE CONSUMER DEREFERENCES THE TYPED VALUE. A linked
  ## `ResourceProviderDriver` does exactly that (`TypedExtensionBox[T](
  ## inst.attrs).val`), so for an in-process op a missing codec has to be a
  ## hard error here rather than a wrong-type crash three frames later. A
  ## consumer that only ROUTES the box onward wants
  ## `reconstructInstanceOpaque` instead — see its docstring for why the
  ## distinction is load-bearing rather than a convenience.
  ResourceInstance(
    typeId: rec.typeId,
    address: rec.address,
    attrs: unmarshalAttrs(rec.attrsTypeId, rec.attrsJson),
    dependsOn: rec.dependsOn,
    determinism: rec.determinism)

proc reconstructInstanceOpaque*(rec: ResourceStateRecord): ResourceInstance =
  ## `reconstructInstance` for a consumer that FORWARDS the attrs box rather
  ## than reading it: the payload is re-hydrated through
  ## `unmarshalAttrsOrRaw`, so an `attrsTypeId` whose codec is not registered
  ## in THIS process becomes a `RawExtensionBox` carrying the persisted bytes
  ## verbatim. `marshalAttrs` re-serializes such a box to those same bytes
  ## with no registry lookup (M2 opaque pass-through), so what reaches the
  ## provider session — or goes back to the store — is byte-for-byte what was
  ## read.
  ##
  ## WHY THIS EXISTS. §4.2 of Ephemeral-State-Leases.md gives the daemon a
  ## provider-SESSION destroy transport precisely so it can tear down an
  ## out-of-tree provider's resources "WITHOUT linking it into the daemon",
  ## and states that the persisted `typeId` + attrs are transport-agnostic.
  ## They were not: the reaper reconstructed through the STRICT path before it
  ## picked a transport, so a process holding a provider artifact but not that
  ## provider's attrs codec — the configuration §4.2 describes — could not
  ## reap over the session it had. Routing a box one does not need to read
  ## through a codec one cannot have is the defect; this proc is the seam that
  ## does not.
  ##
  ## NOT the cause of the outage recorded in
  ## reprobuild-pm/issues/2026-09-29-lease-reap-tick-has-never-once-succeeded.md.
  ## That daemon reaped on the IN-PROCESS transport throughout (no provider
  ## artifact was registered, and at the time nothing in the shipped tree could
  ## register one), where its record had no linked driver either and the strict
  ## path is still the right one. A record written by current code carries its
  ## own artifact (`providerArtifact`, above), so the session arm is now
  ## reachable — see `reaper.nim`'s module header.
  ResourceInstance(
    typeId: rec.typeId,
    address: rec.address,
    attrs: unmarshalAttrsOrRaw(rec.attrsTypeId, rec.attrsJson),
    dependsOn: rec.dependsOn,
    determinism: rec.determinism)

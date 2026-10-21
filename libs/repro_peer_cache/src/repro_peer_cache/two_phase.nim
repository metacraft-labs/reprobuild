## Two-phase peer-cache publish and lookup — Distributed-Execution M0.
##
## This is the step-by-step BuildXL two-phase cache lookup
## (`references/buildxl/Documentation/Wiki/Advanced-Features/
## Two-Phase-Cache-Lookup.md`) over the peer-cache wire:
##
##   Step 1  WeakFingerprint -> selectors {PathSet digest, StrongFingerprint}
##           (`mkGetSelectorsRequest`, memoization plane).
##   Step 2  For each distinct PathSet: fetch the PathSet blob by content
##           digest (`mkFetchRequest`, content plane, BLAKE3-verified),
##           rebase its entries onto THIS workspace, and observe each path's
##           current identity on THIS filesystem.
##   Step 3  StrongFingerprint' = H(Weak || PathSetDigest || identities).
##           A selector whose strong fingerprint equals it describes an
##           execution whose every observed input has the same content here.
##           No match is a strong-fingerprint miss: the action rebuilds.
##   Step 4  Fetch the memo entry for the matching selector
##           (`mkGetActionRecordRequest`), check it describes that selector,
##           and fetch every output blob it references by content digest.
##
## The producer side (`publishTwoPhase`) writes exactly what those steps
## read: the PathSet blob and the output blobs into the local CAS (the
## content plane serves them), and a memo entry under its own
## `(weak, strong)` file (the memoization plane serves it).
##
## Under `REPRO_PORTABLE_CACHE=1` (`TwoPhaseContext.portable`), every path in
## the published record and PathSet that lies inside the workspace is written
## as `$WORKSPACE/<rel>` and rebased onto the consumer's workspace root on
## lookup and install (`workspace_paths.nim`).

import std/[asyncdispatch, options, os, strutils]
when defined(posix):
  from std/posix import Stat, stat, S_ISREG, S_ISDIR

from repro_core/codec import elementCountFits
import repro_cas_store
import repro_local_store

import ./client
import ./memo_store
import ./types
import ./workspace_paths

export workspace_paths

type
  TwoPhaseContext* = object
    ## Everything the two-phase logic needs to know about the action and the
    ## workspace it runs in.
    peerKey*: BlobDigest
      ## The WeakFingerprint peers agree on. Under portable caching this is
      ## the action's portable weak fingerprint (logical paths, so the same
      ## on every checkout); otherwise the engine's local weak fingerprint.
    cwd*: string
      ## The action's working directory: relative record names (relocatable
      ## actions) resolve against it.
    workspaceRoot*: string
      ## The workspace checkout root `$WORKSPACE` stands for.
    portable*: bool
      ## Normalize on publish and rebase on lookup/install.

  TwoPhasePublishOutcome* = object
    published*: bool
      ## A memo entry for this selector exists after the call (newly written
      ## or already present).
    newlyWritten*: bool
    reason*: string
      ## Why nothing was published; empty on success.
    entry*: MemoEntry
    advertKeys*: seq[BlobDigest]
      ## Keys the caller should add to its advertisement set.

  TwoPhaseBundle* = object
    ## What a successful lookup hands the installer: the memo entry exactly
    ## as the peer served it (normalized), the identities the consumer
    ## observed for its PathSet (so the installer can refuse an input that
    ## changed between lookup and install), and the output payloads.
    entryBytes*: seq[byte]
    pathSetBytes*: seq[byte]
      ## The PathSet blob itself, so the installer can keep it in the local
      ## CAS and this node can serve the selector onward.
    identities*: seq[string]
    blobs*: seq[seq[byte]]

  TwoPhaseFetchOutcome* = object
    hit*: bool
    reason*: string
    peerId*: PeerId
    bundle*: TwoPhaseBundle
    selectorsOffered*: int
    pathSetsEvaluated*: int
    strongMisses*: int
      ## PathSets whose recomputed strong fingerprint matched no offered
      ## selector — the "dynamic input changed" case.

const
  TwoPhaseBundleMagic = "RPTB"
  TwoPhaseBundleVersion = 1'u16
  AbsentIdentity* = "absent"
  DirectoryIdentityPrefix* = "dir:"

# ---------------------------------------------------------------------------
# Path handling.
# ---------------------------------------------------------------------------

proc normalizeName*(name: string; ctx: TwoPhaseContext): string =
  if ctx.portable: normalizeWorkspacePath(name, ctx.workspaceRoot)
  else: name

proc rebaseName*(name: string; ctx: TwoPhaseContext): string =
  if ctx.portable: rebaseWorkspacePath(name, ctx.workspaceRoot)
  else: name

proc physicalLocation*(name: string; ctx: TwoPhaseContext): string =
  ## Where a (normalized) record name lives for THIS action: rebased onto
  ## the workspace, then resolved against the action's cwd if relative.
  recordedInputLocation(ctx.cwd, rebaseName(name, ctx))

proc isAncestorExistenceProbe*(input: FileFingerprint;
                                ctx: TwoPhaseContext): bool =
  ## An input that says only "this proper ancestor of the workspace root is
  ## a directory": the walk up the parent chain a shell's `getcwd`, a
  ## compiler's config search or `realpath` performs. It is implied by the
  ## workspace existing at all — every ancestor of an existing directory is
  ## an existing directory — so it carries no information a consumer could
  ## disagree on, yet naming it by absolute path makes two checkouts under
  ## different parents (the cross-host case) produce different PathSets that
  ## can never match. Under portable caching such entries are left out of
  ## the published record and its PathSet.
  ##
  ## Deliberately narrow, so dropping it can never hide a real input:
  ##   * only existence-only DIRECTORY observations — an enumerated ancestor
  ##     (membership-tracked) depends on the ancestor's other entries and is
  ##     kept; so is an ancestor recorded missing or as anything else;
  ##   * only PROPER ancestors of the workspace root — any path inside the
  ##     workspace, or beside it (a sibling, a file under an ancestor), is
  ##     kept and keyed by content as before.
  if not ctx.portable or ctx.workspaceRoot.len == 0:
    return false
  if input.metadata.kind != ffkDirectory or
      membershipTrackedDirectory(input.metadata):
    return false
  let physical =
    if input.path.isAbsolute: input.path
    elif ctx.cwd.len > 0: normalizedPath(ctx.cwd / input.path)
    else: return false
  isWorkspaceAncestor(physical, ctx.workspaceRoot)

proc normalizeRecord*(record: ActionResultRecord;
                      ctx: TwoPhaseContext): ActionResultRecord =
  ## The record as published: input and output paths workspace-normalized,
  ## and (portable caching) the workspace's ancestor existence probes left
  ## out — see `isAncestorExistenceProbe`.
  result = record
  result.inputs = @[]
  for input in record.inputs:
    if isAncestorExistenceProbe(input, ctx):
      continue
    var kept = input
    kept.path = normalizeName(input.path, ctx)
    result.inputs.add(kept)
  for output in result.outputs.mitems:
    output.path = normalizeName(output.path, ctx)

proc rebaseRecord*(record: ActionResultRecord;
                   ctx: TwoPhaseContext): ActionResultRecord =
  ## The record as the consumer sees it: markers replaced by its own root.
  result = record
  for input in result.inputs.mitems:
    input.path = rebaseName(input.path, ctx)
  for output in result.outputs.mitems:
    output.path = rebaseName(output.path, ctx)

const
  ReadEntryTag* = "r:"
    ## PathSet entry for an input observed by READ or PROBE: its identity is
    ## the file's content, or what stands there instead (a directory, a
    ## special file, nothing).
  EnumerationEntryTag* = "e:"
    ## PathSet entry for a directory the execution ENUMERATED (the record
    ## tracks its membership): its identity is which names it contains.

proc pathSetEntryOf*(input: FileFingerprint): string =
  ## The PathSet entry of one recorded input: an observation-kind tag and the
  ## (normalized) name. The tag matters because the same directory can be an
  ## existence probe in one record — a shell's walk up its ancestors, where
  ## only "it is a directory" was observed — and an enumeration in another.
  ## Keying the probe on membership would make every unrelated sibling of
  ## every ancestor an input and two checkouts could never match; keying the
  ## enumeration on existence would miss a file appearing in it.
  (if membershipTrackedDirectory(input.metadata): EnumerationEntryTag
   else: ReadEntryTag) & input.path

proc splitPathSetEntry*(entry: string): tuple[enumerated: bool; name: string] =
  if entry.startsWith(EnumerationEntryTag):
    (true, entry[EnumerationEntryTag.len .. ^1])
  elif entry.startsWith(ReadEntryTag):
    (false, entry[ReadEntryTag.len .. ^1])
  else:
    raise newException(ValueError, "untagged path set entry: " & entry)

proc pathSetOf*(normalized: ActionResultRecord): PeerPathSet =
  ## The PathSet of a (normalized) record: its tagged input entries,
  ## canonical (sorted, de-duplicated).
  var entries: seq[string] = @[]
  for input in normalized.inputs:
    entries.add(pathSetEntryOf(input))
  canonicalPathSet(entries)

# ---------------------------------------------------------------------------
# Observed identities.
# ---------------------------------------------------------------------------

proc isSpecialFile(path: string): bool =
  ## A device, FIFO or socket: something `fileExists` accepts but whose
  ## "content" is not a fixed byte string (`/dev/urandom` never ends).
  when defined(posix):
    var st: Stat
    if stat(path.cstring, st) != 0:
      return false
    not S_ISREG(st.st_mode) and not S_ISDIR(st.st_mode)
  else:
    false

proc observedIdentity*(path: string; enumerated = false): string =
  ## The identity of one observed input on this filesystem:
  ##   * a regular file: the BLAKE3-256 of its bytes;
  ##   * a directory: its membership digest when the execution ENUMERATED
  ##     it, else just `directory` (a probe observed existence and kind);
  ##   * a device/FIFO/socket: `special` (never read);
  ##   * nothing there: `absent`.
  ## An unreadable file yields `unreadable:` followed by the path: the
  ## producer refuses to publish such an observation, so it never matches.
  if dirExists(path):
    if enumerated: DirectoryIdentityPrefix & membershipHex(path)
    else: ReadOfDirectory
  elif fileExists(path):
    if isSpecialFile(path):
      "special"
    else:
      let hex = fileContentHex(path)
      if hex.len == 0: "unreadable:" & path else: hex
  else:
    AbsentIdentity

proc entryIdentity*(entry: string; ctx: TwoPhaseContext): string =
  ## The identity of one tagged PathSet entry, observed through `ctx`.
  let (enumerated, name) = splitPathSetEntry(entry)
  observedIdentity(physicalLocation(name, ctx), enumerated)

proc identitiesFor*(pathSet: PeerPathSet; ctx: TwoPhaseContext): seq[string] =
  for entry in pathSet:
    result.add(entryIdentity(entry, ctx))

proc inputsStillMatch*(record: ActionResultRecord;
                       cwd: string): tuple[ok: bool; changed: string] =
  ## Whether every input the record names still observes as recorded, under
  ## the record's own policy. The publisher checks this before it computes
  ## identities: an input edited between execution and publish would
  ## otherwise pair the OLD outputs with the NEW content — a false hit
  ## waiting for the next consumer.
  for input in record.inputs:
    let location = recordedInputLocation(cwd, input.path)
    let current =
      if membershipTrackedDirectory(input.metadata):
        observeEnumeratedDirectory(location, record.policy)
      else:
        observeFile(location, record.policy)
    if current.metadata != input.metadata:
      return (false, input.path)
    if input.hasLocalHash and
        (not current.hasLocalHash or current.localHash != input.localHash):
      return (false, input.path)
  (true, "")

# ---------------------------------------------------------------------------
# Bundle codec (lookup -> installer hand-off).
# ---------------------------------------------------------------------------

proc putU32(dst: var seq[byte]; v: uint32) =
  for shift in countup(0, 24, 8):
    dst.add(byte((v shr uint32(shift)) and 0xff'u32))

proc getU32(data: openArray[byte]; pos: var int): uint32 =
  if pos + 4 > data.len:
    raise newException(ValueError, "truncated two-phase bundle")
  for i in 0 ..< 4:
    result = result or (uint32(data[pos + i]) shl uint32(i * 8))
  pos += 4

proc getBytes(data: openArray[byte]; pos: var int; n: int): seq[byte] =
  if n < 0 or pos + n > data.len:
    raise newException(ValueError, "truncated two-phase bundle")
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = data[pos + i]
  pos += n

proc encodeTwoPhaseBundle*(bundle: TwoPhaseBundle): seq[byte] =
  ## "RPTB" u16 version u32 entryLen entry u32 pathSetLen pathSet
  ## u32 idCount {u32 len bytes}* u32 blobCount {u32 len bytes}*
  for ch in TwoPhaseBundleMagic:
    result.add(byte(ord(ch)))
  result.add(byte(TwoPhaseBundleVersion and 0xff))
  result.add(byte(TwoPhaseBundleVersion shr 8))
  result.putU32(uint32(bundle.entryBytes.len))
  result.add(bundle.entryBytes)
  result.putU32(uint32(bundle.pathSetBytes.len))
  result.add(bundle.pathSetBytes)
  result.putU32(uint32(bundle.identities.len))
  for id in bundle.identities:
    result.putU32(uint32(id.len))
    for ch in id:
      result.add(byte(ord(ch)))
  result.putU32(uint32(bundle.blobs.len))
  for blob in bundle.blobs:
    result.putU32(uint32(blob.len))
    result.add(blob)

proc decodeTwoPhaseBundle*(data: openArray[byte]): TwoPhaseBundle =
  if data.len < 6:
    raise newException(ValueError, "truncated two-phase bundle")
  for i, ch in TwoPhaseBundleMagic:
    if data[i] != byte(ord(ch)):
      raise newException(ValueError, "not a two-phase bundle")
  let version = uint16(data[4]) or (uint16(data[5]) shl 8)
  if version != TwoPhaseBundleVersion:
    raise newException(ValueError,
      "unsupported two-phase bundle version " & $version)
  var pos = 6
  result.entryBytes = getBytes(data, pos, int(getU32(data, pos)))
  result.pathSetBytes = getBytes(data, pos, int(getU32(data, pos)))
  # Each identity / blob is at least its u32 length (repro_core/codec).
  let rawIds = getU32(data, pos)
  if not elementCountFits(rawIds, data.len - pos, 4):
    raise newException(ValueError,
      "two-phase bundle identity count exceeds remaining bytes")
  let ids = int(rawIds)
  if ids > MaxPathSetEntries:
    raise newException(ValueError, "two-phase bundle identity count too large")
  for _ in 0 ..< ids:
    let raw = getBytes(data, pos, int(getU32(data, pos)))
    var s = newString(raw.len)
    for i, b in raw:
      s[i] = char(b)
    result.identities.add(s)
  let rawBlobs = getU32(data, pos)
  if not elementCountFits(rawBlobs, data.len - pos, 4):
    raise newException(ValueError,
      "two-phase bundle blob count exceeds remaining bytes")
  let blobs = int(rawBlobs)
  if blobs > MaxMemoOutputs:
    raise newException(ValueError, "two-phase bundle blob count too large")
  for _ in 0 ..< blobs:
    result.blobs.add(getBytes(data, pos, int(getU32(data, pos))))
  if pos != data.len:
    raise newException(ValueError, "trailing bytes after two-phase bundle")

# ---------------------------------------------------------------------------
# Producer side.
# ---------------------------------------------------------------------------

proc contentHashOf(d: BlobDigest): ContentHash =
  toContentHash(bytes(d))

proc blobDigestOf(blob: CasBlobRef): BlobDigest =
  blobDigestFromBytes(blob.digest.bytes)

proc publishTwoPhase*(store: PeerMemoStore; cas: var CasStore;
                      record: ActionResultRecord;
                      ctx: TwoPhaseContext): TwoPhasePublishOutcome =
  ## Publishes one freshly recorded execution into the two-phase stores.
  ##
  ## Refuses (returns `published = false` with a reason) rather than
  ## publishing anything it cannot stand behind:
  ##   * a record without CAS payloads (nothing a peer could restore);
  ##   * an output blob missing from the CAS;
  ##   * an input that no longer observes as recorded (edited since the
  ##     execution);
  ##   * an input that cannot be read (its identity would be meaningless).
  ##
  ## On success the PathSet blob is in the CAS under its BLAKE3-256 digest,
  ## the memo entry is on disk under `(peerKey, strong)`, and `advertKeys`
  ## lists what the caller should advertise. Re-publishing the same
  ## execution is idempotent and never rewrites another selector's entry.
  if record.outputPayloadKind != opkCasBlobs:
    return TwoPhasePublishOutcome(reason: "record carries no output payloads")
  var outputDigests: seq[BlobDigest] = @[]
  for output in record.outputs:
    let d = blobDigestOf(output.blob)
    if not cas.casExists(contentHashOf(d)):
      return TwoPhasePublishOutcome(
        reason: "output blob missing from the CAS: " & output.path)
    outputDigests.add(d)
  let still = inputsStillMatch(record, ctx.cwd)
  if not still.ok:
    return TwoPhasePublishOutcome(
      reason: "input changed since execution: " & still.changed)
  let normalized =
    try:
      normalizeRecord(record, ctx)
    except CatchableError as err:
      return TwoPhasePublishOutcome(reason: "normalize failed: " & err.msg)
  let pathSet = pathSetOf(normalized)
  let pathSetBytes = encodePeerPathSet(pathSet)
  let pathSetDigest = digestOf(pathSetBytes)
  var identities: seq[string] = @[]
  for entry in pathSet:
    # The producer resolves names through its OWN root and cwd. A
    # normalized name rebases onto the producer root, which is where the
    # unnormalized record pointed.
    let id = entryIdentity(entry, ctx)
    if id.startsWith("unreadable:"):
      return TwoPhasePublishOutcome(reason: "input unreadable: " & entry)
    identities.add(id)
  let stored = cas.casPut(pathSetBytes)
  if stored != contentHashOf(pathSetDigest):
    return TwoPhasePublishOutcome(reason: "CAS returned a different digest " &
      "for the path set blob")
  let strong = twoPhaseStrongFingerprint(ctx.peerKey, pathSetDigest, identities)
  let entry = MemoEntry(
    weakFingerprint: ctx.peerKey,
    pathSetDigest: pathSetDigest,
    strongFingerprint: strong,
    recordBytes: encodeActionResultRecord(normalized),
    outputDigests: outputDigests)
  result.newlyWritten = store.writeMemoEntry(entry)
  result.published = true
  result.entry = entry
  result.advertKeys.add(memoAdvertKey(ctx.peerKey))
  result.advertKeys.add(pathSetDigest)
  for d in outputDigests:
    result.advertKeys.add(d)

proc republishInstalled*(store: PeerMemoStore; cas: var CasStore;
                         bundle: TwoPhaseBundle): seq[BlobDigest] =
  ## After a successful install from a peer, keep serving what was fetched:
  ## the memo entry goes into this node's own memo store (unchanged, so its
  ## selector is the producer's) and the advertisement keys are returned.
  ## The PathSet and output blobs are already in the CAS. Never raises.
  try:
    let entry = decodeMemoEntry(bundle.entryBytes)
    if not cas.casExists(contentHashOf(entry.pathSetDigest)):
      return @[]
    for d in entry.outputDigests:
      if not cas.casExists(contentHashOf(d)):
        return @[]
    store.writeMemoEntry(entry)
    result.add(memoAdvertKey(entry.weakFingerprint))
    result.add(entry.pathSetDigest)
    for d in entry.outputDigests:
      result.add(d)
  except CatchableError:
    result = @[]

# ---------------------------------------------------------------------------
# Consumer side.
# ---------------------------------------------------------------------------

proc fetchContent(client: PeerCacheClient; localRead: LocalStoreReader;
                  offeredBy: seq[PeerId]; digest: BlobDigest):
                  Future[Option[seq[byte]]] {.async.} =
  ## A content-plane blob: local store first, then each peer that offered
  ## the selector naming it. Every peer reply is BLAKE3-verified by the
  ## client before it reaches us.
  if not localRead.isNil:
    let local = localRead(digest)
    if local.isSome and digestOf(local.get()) == digest:
      return local
  for peerId in offeredBy:
    let fetched = await client.requestFetchFrom(peerId, digest)
    if fetched.isSome:
      return fetched
  return none(seq[byte])

proc fetchTwoPhase*(client: PeerCacheClient; ctx: TwoPhaseContext;
                    localRead: LocalStoreReader = nil):
                    Future[TwoPhaseFetchOutcome] {.async.} =
  ## Steps 1–4 of the two-phase lookup for one action (see the module doc).
  ## `localRead` consults the local CAS before the wire for PathSet and
  ## output blobs. Returns `hit = false` with a reason on every miss path;
  ## never raises for peer misbehaviour (a reply that fails a check is
  ## skipped and the next candidate tried).
  var outcome = TwoPhaseFetchOutcome()
  let offered = await client.requestSelectors(ctx.peerKey)
  outcome.selectorsOffered = offered.len
  if offered.len == 0:
    outcome.reason = "no peer holds a selector for this weak fingerprint"
    return outcome
  var pathSetDigests: seq[BlobDigest] = @[]
  for item in offered:
    if item.selector.pathSetDigest notin pathSetDigests:
      pathSetDigests.add(item.selector.pathSetDigest)
  for psd in pathSetDigests:
    var offeringPeers: seq[PeerId] = @[]
    for item in offered:
      if item.selector.pathSetDigest == psd and item.peerId notin offeringPeers:
        offeringPeers.add(item.peerId)
    # Step 2: the PathSet blob, content-addressed.
    let psBytes = await fetchContent(client, localRead, offeringPeers, psd)
    if psBytes.isNone:
      outcome.reason = "path set blob unavailable: " & $psd
      continue
    var pathSet: PeerPathSet
    try:
      pathSet = decodePeerPathSet(psBytes.get())
    except CatchableError as err:
      outcome.reason = "malformed path set " & $psd & ": " & err.msg
      continue
    var identities: seq[string]
    try:
      identities = identitiesFor(pathSet, ctx)
    except CatchableError as err:
      outcome.reason = "cannot observe path set " & $psd & ": " & err.msg
      continue
    inc outcome.pathSetsEvaluated
    # Step 3: the consumer's own strong fingerprint for this PathSet.
    let strong = twoPhaseStrongFingerprint(ctx.peerKey, psd, identities)
    var matching: seq[PeerSelector] = @[]
    for item in offered:
      if item.selector.pathSetDigest == psd and
          item.selector.strongFingerprint == strong:
        matching.add(item)
    if matching.len == 0:
      inc outcome.strongMisses
      outcome.reason = "strong fingerprint miss: no selector matches the " &
        "observed inputs of path set " & $psd
      continue
    # Step 4: the memo entry, then every output blob.
    for item in matching:
      let entryBytes = await client.requestMemoEntryFrom(item.peerId,
        ctx.peerKey, strong)
      if entryBytes.isNone:
        outcome.reason = "peer " & $item.peerId & " did not serve the entry"
        continue
      var entry: MemoEntry
      var record: ActionResultRecord
      try:
        entry = decodeMemoEntry(entryBytes.get())
        record = decodeActionResultRecord(entry.recordBytes)
      except CatchableError as err:
        outcome.reason = "malformed memo entry: " & err.msg
        continue
      if entry.weakFingerprint != ctx.peerKey or
          entry.pathSetDigest != psd or entry.strongFingerprint != strong:
        outcome.reason = "memo entry does not describe the requested selector"
        continue
      if pathSetOf(record) != pathSet:
        outcome.reason = "memo entry record disagrees with its path set"
        continue
      if record.outputPayloadKind != opkCasBlobs or
          record.outputs.len != entry.outputDigests.len:
        outcome.reason = "memo entry carries no restorable outputs"
        continue
      var consistent = true
      for i, output in record.outputs:
        if blobDigestOf(output.blob) != entry.outputDigests[i]:
          consistent = false
      if not consistent:
        outcome.reason = "memo entry output digests disagree with its record"
        continue
      var blobs: seq[seq[byte]] = @[]
      var complete = true
      for i, d in entry.outputDigests:
        let payload = await fetchContent(client, localRead, @[item.peerId], d)
        if payload.isNone or
            uint64(payload.get().len) != record.outputs[i].blob.sizeBytes:
          complete = false
          outcome.reason = "output blob unavailable: " & $d
          break
        blobs.add(payload.get())
      if not complete:
        continue
      outcome.hit = true
      outcome.reason = ""
      outcome.peerId = item.peerId
      outcome.bundle = TwoPhaseBundle(entryBytes: entryBytes.get(),
        pathSetBytes: psBytes.get(), identities: identities, blobs: blobs)
      return outcome
  return outcome

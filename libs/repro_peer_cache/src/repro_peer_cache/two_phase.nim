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
## Campaign M17 (Edge-Derived-Identities.md §3.3a, §3.4 item 1, §3.6) applies
## one publication rule at both ends (`publicationRefusalOf`): only a record
## made under `ffpChecksum` or `ffpHybrid`, graded Level 0 by the producer's
## engine, and naming at least one observed input crosses hosts. The producer
## refuses anything else before computing an identity; the consumer refuses
## it in Step 4 as a miss, judging the record's own policy and the evidence
## level its issuer signed into the memo entry (`memo_store.nim`, entry v3).
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
import ./evidence_record
import ./identity
import ./memo_attestation
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
    newerFormatMisses*: int
      ## Entries skipped because a newer node wrote them in a format this
      ## build does not read (a miss, never a rejection).
    publicationRuleMisses*: int
      ## Entries skipped because the record may not cross hosts at all
      ## (`publicationRefusalOf`): a timestamp-policy, non-Level-0, unstated-
      ## level or zero-evidence record. What an older or non-conforming
      ## producer publishes; a miss, never a rejection, and no suspicion.

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

proc publicationRefusalOf*(record: ActionResultRecord;
                           level: EvidenceLevel): string =
  ## Why `record` may not cross hosts through the peer cache, or "" when it
  ## may: `repro_local_store.publicationRefusal`, the one rule every
  ## publisher and consumer applies (Edge-Derived-Identities.md §3.3a, §3.4
  ## item 1, §3.6). The producer asks it of the record it is about to
  ## publish, before computing a single identity; the consumer asks it of the
  ## record a peer served, with the level the issuer signed, whatever that
  ## producer's version or conformance.
  publicationRefusal(record, level)

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
                      ctx: TwoPhaseContext;
                      attestor: LeafProvider = nil;
                      evidenceLevel = elUnstated): TwoPhasePublishOutcome =
  ## Publishes one freshly recorded execution into the two-phase stores.
  ##
  ## Refuses (returns `published = false` with a reason) rather than
  ## publishing anything it cannot stand behind:
  ##   * a record that may not leave this host at all
  ##     (`publicationRefusalOf`, campaign M17): made under `ffpTimestamp`,
  ##     a regular-file input without a content hash, monitor evidence other
  ##     than Level 0 (`evidenceLevel`, which the engine graded; a caller
  ##     that does not say is refused), or no observed input. Checked FIRST,
  ##     before any input is re-observed or hashed: publication never
  ##     computes content identities for such a record after the fact;
  ##   * a record without CAS payloads (nothing a peer could restore);
  ##   * an output blob missing from the CAS;
  ##   * an input that no longer observes as recorded (edited since the
  ##     execution);
  ##   * an input that cannot be read (its identity would be meaningless).
  ##
  ##   * no issuer identity (`attestor` nil): an unattested entry is one
  ##     every consumer refuses (Distributed-Execution M7), so the memo
  ##     plane needs a node with a host identity (`tls=1`).
  ##
  ## On success the PathSet blob is in the CAS under its BLAKE3-256 digest,
  ## the memo entry is on disk under `(peerKey, strong)`, and `advertKeys`
  ## lists what the caller should advertise. Re-publishing the same
  ## execution is idempotent and never rewrites another selector's entry.
  let refusal = publicationRefusalOf(record, evidenceLevel)
  if refusal.len > 0:
    return TwoPhasePublishOutcome(reason: "not published: " & refusal)
  if attestor.isNil:
    return TwoPhasePublishOutcome(reason: "no issuer identity to attest " &
      "the entry with (the memoization plane requires tls=1)")
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
  # What a consumer receives is the NORMALIZED record, which drops the
  # workspace's ancestor existence probes; it has to pass the same rule the
  # consumer will apply to it.
  let normalizedRefusal = publicationRefusalOf(normalized, evidenceLevel)
  if normalizedRefusal.len > 0:
    return TwoPhasePublishOutcome(reason: "not published: " &
      normalizedRefusal)
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
  var entry = MemoEntry(
    weakFingerprint: ctx.peerKey,
    pathSetDigest: pathSetDigest,
    strongFingerprint: strong,
    recordBytes: encodeActionResultRecord(normalized),
    outputDigests: outputDigests,
    evidenceLevel: evidenceLevel)
  try:
    attest(entry, attestor())
  except CatchableError as err:
    return TwoPhasePublishOutcome(reason: "cannot attest the entry: " &
      err.msg)
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
  if client.trustMode != tmTls:
    # Memo entries are accepted only with a verified issuer attestation,
    # which needs trust anchors; a CIDR-only node has none (and peers do
    # not answer an unauthenticated memo query).
    outcome.reason = "the memoization plane requires authenticated " &
      "issuers (tls=1)"
    return outcome
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
      # Every check below that fails is a REJECTION, REPORTED off-host, and
      # the serving peer is marked suspect (DET-2: a cache that quietly
      # drops a poisoned record teaches us nothing about who sent it).
      template report(trigger, why: string) =
        outcome.reason = why
        client.reportDetection(newEvidenceRecord(ecDetection,
          "peer-cache-memo", trigger,
          [("peer", $item.peerId), ("weakFingerprint", $ctx.peerKey),
           ("strongFingerprint", $strong), ("pathSetDigest", $psd),
           ("issuer", $entry.issuerHostId), ("reason", why)],
          payload = entryBytes.get()))
      template reject(trigger, why: string) =
        report(trigger, why)
        client.markPeerSuspect(item.peerId, trigger, why)
      var decodingRecord = false
      try:
        entry = decodeMemoEntry(entryBytes.get())
        decodingRecord = true
        record = decodeActionResultRecord(entry.recordBytes)
      except CatchableError as err:
        # A mixed-version fleet: an honest NEWER peer serves an entry (or a
        # record inside one) in a format this build does not read. Well
        # formed for its writer, so a plain miss — no detection, no
        # suspicion (Distributed-Execution M1). Anything else that fails to
        # decode is malformed or forged, and rejected as before.
        let newer =
          if decodingRecord: actionRecordIsNewerFormat(entry.recordBytes)
          else: memoEntryIsNewerFormat(entryBytes.get())
        if newer.newer:
          inc outcome.newerFormatMisses
          outcome.reason = "peer " & $item.peerId & " serves a " &
            (if decodingRecord: "record" else: "memo entry") &
            " in a newer format (version " & $newer.version &
            ") than this build reads: a miss"
          continue
        reject("selector-validation-failed", "malformed memo entry: " &
          err.msg)
        continue
      if entry.weakFingerprint != ctx.peerKey or
          entry.pathSetDigest != psd or entry.strongFingerprint != strong:
        reject("memo-selector-mismatch",
          "memo entry does not describe the requested selector")
        continue
      let verdict = verifyAttestation(entry, client.trustAnchorSet,
        client.revokedIssuers)
      if verdict.expired:
        # Judged at OUR clock the issuer's leaf has expired (threat model
        # G15). Refused and reported, but an expired attestation is not
        # evidence that the serving peer forged anything: no suspicion.
        report("memo-attestation-expired", verdict.reason)
        continue
      if not verdict.ok:
        reject("memo-issuer-unbound", verdict.reason)
        continue
      if pathSetOf(record) != pathSet:
        reject("selector-validation-failed",
          "memo entry record disagrees with its path set")
        continue
      if record.outputPayloadKind != opkCasBlobs or
          record.outputs.len != entry.outputDigests.len:
        reject("selector-validation-failed",
          "memo entry carries no restorable outputs")
        continue
      var consistent = true
      for i, output in record.outputs:
        if blobDigestOf(output.blob) != entry.outputDigests[i]:
          consistent = false
      if not consistent:
        reject("selector-validation-failed",
          "memo entry output digests disagree with its record")
        continue
      # Campaign M17 (Edge-Derived-Identities.md §3.6): a record that may not
      # cross hosts is refused HERE, whatever produced it -- an older
      # producer that published timestamp-policy or Level-1 records, or a
      # non-conforming one. Judged after every consistency check above, so a
      # malformed or relabelled entry is still rejected and reported rather
      # than passing as a plain miss, and before any output blob is fetched,
      # so nothing it names is materialised. Not suspicion: an honest older
      # producer serves exactly this.
      let ruleRefusal = publicationRefusalOf(record, entry.evidenceLevel)
      if ruleRefusal.len > 0:
        inc outcome.publicationRuleMisses
        outcome.reason = "peer " & $item.peerId & " serves a record this " &
          "host does not accept from another host: " & ruleRefusal
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

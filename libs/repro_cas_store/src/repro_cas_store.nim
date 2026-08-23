## Reprobuild content-addressed blob-store facade — R11 Layer 1.
##
## Spec: reprobuild-specs/Store-And-Installation-Layout.md
##       §"Human-Friendly Package Store Versus Opaque Content Store"
##       → §R11 — Two-Layer Split (normative).
##
## This module is a deliberately narrow facade over the CAS primitives
## that already live in ``repro_local_store/store.nim`` (the M56
## "unified local content-addressed store"). Downstream code that
## needs only put / get / verify / path / gc semantics MUST import
## ``repro_cas_store`` rather than ``repro_local_store`` so it does
## not silently gain access to the Layer-2 surface (prefixes, roots,
## receipts, per-generation-root registry, recovery).
##
## The layering invariant:
##
##   * Layer 1 (this module) knows about content-addressed blobs only.
##     It MUST NOT reason about packages, versions, receipts,
##     prefixes, roots, or generations.
##   * Layer 2 (``repro_local_store``) knows about the human-friendly
##     realized package prefixes + the root-driven GC graph. Layer 2
##     depends on Layer 1. Layer 1 MUST NOT depend on Layer 2's
##     public surface.
##
## The facade is intentionally implemented BY re-exporting a curated
## subset of ``repro_local_store``. That preserves a single on-disk
## implementation of the CAS layer (no divergence) while still giving
## downstream code a narrower import surface. When the Layer-1
## implementation is later split into its own module (a follow-on
## when the code base has more R11 pressure), this facade's public
## API stays byte-identical and only the underlying import changes.

import std/[hashes, os, sets, strutils]

import blake3
from repro_core/paths import extendedPath

import repro_local_store

# Re-export the error taxonomy the facade may raise. Layer-2 error
# types (EReceiptMismatch, EStoreSchemaTooNew, ...) are deliberately
# NOT re-exported — they belong to the prefix layer.
export StoreError, ECasMissing, ECasDigestMismatch

# Local-CAS-Hardlink-Materialization M2 — the ingest side's named default
# and its per-call mechanism record. The implementation lives one layer
# down (``repro_local_store/store.nim``) because it is the module that owns
# the on-disk staging and commit protocol; the constant is re-exported here
# so a Layer-1 caller can read the policy without importing Layer 2, and so
# a test can watch the value the way M1's watches
# ``CasMaterializeAllowSharedInodeDefault``.
export CasIngestAllowSharedInodeDefault, CasIngestOutcome,
  casIngestRaceWindowHook

# Local-CAS-Hardlink-Materialization M0 — the filesystem link-capability
# model and probe. It lives in ``repro_local_store`` because the ingest
# side (M2, ``storeCasFileBlobDetailed``) sits below this facade and needs
# the same answer, but it is a Layer-1 concern end to end: it knows about
# files and filesystems only, never about prefixes, receipts or roots.
# Re-exported whole so a Layer-1 caller can implement the spec's
# reflink → hardlink → copy preference order without importing Layer 2.
#
# Both directions are now production callers of the probe, and both have
# their hardlink arm implemented but DISABLED by default:
# ``casMaterialize`` below (M1, ``CasMaterializeAllowSharedInodeDefault``)
# on the way out, and ``casPutPath`` below (M2,
# ``CasIngestAllowSharedInodeDefault``) on the way in.
import repro_local_store/link_capability
export link_capability

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  ContentHash* = distinct array[32, byte]
    ## A BLAKE3-256 digest over blob bytes. The R11 canonical key type
    ## for every Layer-1 operation. Distinct so it does not silently
    ## coerce to raw bytes.

  CasStore* = object
    ## Opaque handle to the CAS on-disk store rooted at ``root``.
    ##
    ## The current implementation holds a ``repro_local_store.Store``
    ## because the CAS + prefix + index tables share one on-disk
    ## layout. That is a private implementation detail: the facade's
    ## consumers MUST NOT reach through to ``inner`` to use the Layer-2
    ## surface.
    inner*: Store

# ---------------------------------------------------------------------------
# Value semantics for ContentHash
# ---------------------------------------------------------------------------

proc `==`*(a, b: ContentHash): bool {.borrow.}

proc hash*(h: ContentHash): Hash =
  var acc: Hash = 0
  let bytes = array[32, byte](h)
  for i in 0 ..< 32:
    acc = acc !& int(bytes[i])
  !$acc

proc bytes*(h: ContentHash): array[32, byte] =
  array[32, byte](h)

proc toContentHash*(bytes: array[32, byte]): ContentHash =
  ContentHash(bytes)

proc `$`*(h: ContentHash): string =
  ## Lowercase hex encoding matching the on-disk layout under
  ## ``cas/blake3/``.
  const HexChars = "0123456789abcdef"
  let raw = array[32, byte](h)
  result = newString(64)
  for i in 0 ..< 32:
    result[2 * i] = HexChars[int(raw[i]) shr 4]
    result[2 * i + 1] = HexChars[int(raw[i]) and 0x0F]

# ---------------------------------------------------------------------------
# Store handle lifecycle
# ---------------------------------------------------------------------------

proc openCasStore*(root: string): CasStore =
  ## Open (or create) the CAS store rooted at ``root``. The underlying
  ## on-disk layout is exactly what
  ## ``Local-Content-Addressed-Store.md`` §"Layout" specifies.
  result.inner = openStore(root)

proc close*(cas: var CasStore) =
  ## Close the underlying handle. Idempotent on already-closed stores.
  cas.inner.close()

proc root*(cas: CasStore): string =
  ## The absolute store-root path this facade was opened against. Used
  ## by higher-layer callers that need to build a Layer-2 path from a
  ## Layer-1 handle without re-parsing the environment.
  cas.inner.root

# ---------------------------------------------------------------------------
# Core Layer-1 operations
# ---------------------------------------------------------------------------

proc casPut*(cas: var CasStore; payload: openArray[byte]): ContentHash =
  ## Insert ``payload`` into the CAS. Returns the BLAKE3-256 digest
  ## the caller MUST use to read it back. Idempotent: repeat calls
  ## with the same bytes are cheap after the first because the on-
  ## disk atomic-rename layer sees the target already exists.
  let raw = storeCasBlob(cas.inner, payload)
  ContentHash(raw)

type
  CasPutPathOutcome* = object
    ## Per-call record of how ``casPutPath`` got a file into the store.
    ## Mirrors ``CasMaterializeOutcome`` on the restore side so both
    ## directions are asserted the same way: on the mechanism actually
    ## used, never on timing.
    hash*: ContentHash
    mechanism*: LinkMechanism
    perFileFallback*: bool
    alreadyPresent*: bool
    sourceChanged*: bool
    diagnostic*: string

proc casPutPathDetailed*(cas: var CasStore; path: string;
                         allowSharedInode =
                           CasIngestAllowSharedInodeDefault):
    CasPutPathOutcome =
  ## Insert the file at ``path`` into the CAS *by adopting it* — reflink
  ## where the filesystem pair supports it, hardlink where it is enabled,
  ## and the streaming copy otherwise. Returns the same
  ## ``ContentHash`` ``casPut`` would return for the same bytes, and a
  ## blob byte-identical to the one ``casPut`` would have written.
  ##
  ## This is the entry point Local-CAS-Hardlink-Materialization M2 adds
  ## because ``casPut`` takes ``openArray[byte]``: a caller holding a
  ## PATH could not express "adopt this file" without first reading the
  ## whole payload into memory, which is both the memory cost and — since
  ## the store then wrote its own second copy — the disk cost the
  ## milestone exists to remove.
  ##
  ## The source is stat'd here for its size, which is also the first half
  ## of the identity witness the hardlink arm compares. A source that
  ## cannot be stat'd is an error before anything is staged.
  let identity = fileIdentity(path)
  if not identity.known:
    raise newException(StoreError,
      "cannot stat CAS ingest source: " & path)
  let outcome = cas.inner.storeCasFileBlobDetailed(
    path, identity.sizeBytes, allowSharedInode = allowSharedInode)
  CasPutPathOutcome(
    hash: ContentHash(outcome.digest),
    mechanism: outcome.mechanism,
    perFileFallback: outcome.perFileFallback,
    alreadyPresent: outcome.alreadyPresent,
    sourceChanged: outcome.sourceChanged,
    diagnostic: outcome.diagnostic)

proc casPutPath*(cas: var CasStore; path: string): ContentHash =
  ## ``casPutPathDetailed`` with the mechanism record discarded. This is
  ## the shape a caller that merely holds a path wants; the detailed
  ## overload exists for callers that want to log or assert on the
  ## mechanism that was actually used.
  cas.casPutPathDetailed(path).hash

proc casGet*(cas: CasStore; hash: ContentHash): seq[byte] =
  ## Retrieve the blob whose digest is ``hash``. The bytes are
  ## verified against ``hash`` BEFORE they reach the caller — a
  ## mismatch raises ``ECasDigestMismatch``. A missing blob raises
  ## ``ECasMissing``.
  readCasBlob(cas.inner, PrefixIdBytes(array[32, byte](hash)))

proc casExists*(cas: CasStore; hash: ContentHash): bool =
  ## Fast existence check that does NOT read + verify the bytes. Use
  ## ``casVerify`` when integrity matters. This is the appropriate
  ## check for "have I already published this blob?" call sites.
  fileExists(cas.inner.casPath(PrefixIdBytes(array[32, byte](hash))))

proc casVerify*(cas: CasStore; hash: ContentHash): bool =
  ## Read the blob and confirm its BLAKE3-256 digest matches
  ## ``hash``. Returns ``false`` on missing / mismatched / read
  ## error. Callers that want the mismatch reason should use
  ## ``casGet`` and catch ``ECasMissing`` / ``ECasDigestMismatch``.
  try:
    discard cas.casGet(hash)
    true
  except ECasMissing, ECasDigestMismatch:
    false

proc casPath*(cas: CasStore; hash: ContentHash): string =
  ## Absolute on-disk path for the blob whose digest is ``hash``. The
  ## caller MUST NOT open the returned path for write — every Layer-1
  ## mutation MUST go through ``casPut`` so the atomic-rename
  ## semantics are preserved.
  cas.inner.casPath(PrefixIdBytes(array[32, byte](hash)))

# ---------------------------------------------------------------------------
# Garbage collection
# ---------------------------------------------------------------------------

proc casBlobRoot(cas: CasStore): string =
  ## The absolute directory under which the sharded blob tree lives.
  cas.inner.root / "cas"

proc parseHexToBytes(hex: string): array[32, byte] {.raises: [].} =
  ## Best-effort parse of a 64-char lowercase hex digest to bytes.
  ## Returns the zero array on any malformation — callers that
  ## receive zero must ignore the blob.
  if hex.len != 64:
    return
  for i in 0 ..< 32:
    let hi = hex[2 * i]
    let lo = hex[2 * i + 1]
    let hiVal =
      if hi >= '0' and hi <= '9': int(hi) - int('0')
      elif hi >= 'a' and hi <= 'f': 10 + int(hi) - int('a')
      elif hi >= 'A' and hi <= 'F': 10 + int(hi) - int('A')
      else: return
    let loVal =
      if lo >= '0' and lo <= '9': int(lo) - int('0')
      elif lo >= 'a' and lo <= 'f': 10 + int(lo) - int('a')
      elif lo >= 'A' and lo <= 'F': 10 + int(lo) - int('A')
      else: return
    result[i] = byte((hiVal shl 4) or loVal)

type
  CasMaterialization* = object
    ## One (hash → destination) pair passed to ``casMaterialize`` for
    ## the cache-hit rehydrate flow. The destination path is treated
    ## as an absolute host path; the caller is responsible for
    ## ensuring parent dirs exist iff ``createParentDirs`` is false.
    hash*: ContentHash
    destination*: string
    applyPermissions*: bool
    permissions*: set[FilePermission]

  CasVerifyMode* = enum
    ## What ``casMaterialize`` checks before it commits a destination.
    ##
    ## Before M1 this was not a choice: ``casMaterialize`` read every
    ## blob's bytes into memory up front, so the BLAKE3 verification
    ## mandated by ``Local-Content-Addressed-Store.md`` §"Corruption
    ## Detection" fell out of the read for free. Linking does not read,
    ## so the check has to be named, and naming it makes the weaker
    ## setting an explicit opt-in rather than a silent regression.
    cvmDigest
      ## DEFAULT. Every materialized result is hash-verified against
      ## its ``ContentHash`` before ANY destination is committed —
      ## uniformly, by streaming the STAGED file, in every arm. This is
      ## the pre-M1 guarantee, unchanged in what it observes and
      ## stronger in what it covers: the bytes verified are the ones
      ## that become the destination, so a mechanism that reported
      ## success while producing a wrong file is caught too, which
      ## "read the source, then write it again" could not do.
    cvmExistence
      ## OPT-IN, weaker. Only the blob's existence is checked; its
      ## digest is trusted because the CAS verified it at ingest and
      ## the store is append-only with atomic renames. This is the
      ## "trust-on-write" mode; it turns a restore into pure link
      ## calls with no read at all. A caller choosing it accepts that
      ## on-disk corruption of a blob is propagated to the
      ## destination rather than raising ``ECasDigestMismatch``.

  CasMaterializeOutcome* = object
    ## Per-entry record of HOW a destination was produced. Returned by
    ## ``casMaterializeDetailed`` so callers (and tests) can assert on
    ## the mechanism actually used instead of inferring it from timing,
    ## and so a log line can explain a fallback.
    mechanism*: LinkMechanism
    perFileFallback*: bool
      ## ``true`` when a link mechanism was available for this
      ## filesystem pair but refused THIS file — the NTFS 1024-name cap
      ## (``ERROR_TOO_MANY_LINKS``) or ReFS's per-extent reference cap.
      ## Per ``Local-Content-Addressed-Store.md`` §"Per-file limits are
      ## not pair capabilities" this falls back to copy for the one
      ## file, never downgrades the cached pair verdict, and never
      ## surfaces as an error.
    diagnostic*: string
      ## Human-readable reason the chosen mechanism was not the first
      ## one in the preference order. Empty when the best available
      ## mechanism succeeded. Safe to log; never parsed.

const
  CasMaterializeAllowSharedInodeDefault* = false
    ## The hardlink arm is IMPLEMENTED but OFF BY DEFAULT, and this
    ## constant is where that is decided — deliberately a named
    ## constant rather than a literal in a signature, so flipping it is
    ## a reviewable one-line change with a test that watches it.
    ##
    ## Why off: a materialized hardlink shares an inode with the CAS
    ## blob, so an action that opens its restored output and writes in
    ## place edits the cache's copy of somebody else's result. That
    ## hazard is Local-CAS-Hardlink-Materialization **M3**'s to answer
    ## (read-only blobs, link-count checks at ingest, or
    ## copy-on-materialize for declared-mutable outputs); until it is
    ## answered, this facade MUST NOT hand a caller a shared inode it
    ## did not ask for.
    ##
    ## Why the reflink arm is nevertheless on: a reflink is
    ## copy-on-write. A write through it copies the touched extents
    ## instead of editing the shared ones, so it is indistinguishable
    ## from a copy to every observer while costing like a link. It has
    ## no mutation hazard and therefore needs no M3 guard rail.
    ##
    ## Callers that know their destination is never written in place
    ## may pass ``allowSharedInode = true`` explicitly. M3 flips the
    ## default.

  CasStreamChunkSize = 1024 * 1024
    ## Bounded working buffer for the copy and verify passes. It is the
    ## reason peak memory is O(chunk) rather than O(sum of every output
    ## being restored), which is what the pre-M1 ``seq[seq[byte]]``
    ## cost.

# ---------------------------------------------------------------------------
# Cache-hit rehydrate helper (R11 Layer-1 primitive)
# ---------------------------------------------------------------------------

var casTmpSerial: int

proc casStageName(dest: string): string =
  ## A temp name BESIDE ``dest`` — same directory, therefore same
  ## filesystem, therefore a rename that is atomic. Unique per process
  ## and per call so two concurrent materializations of one destination
  ## cannot stage over each other.
  casTmpSerial.inc
  dest & ".reprocastmp-" & $getCurrentProcessId() & "-" & $casTmpSerial

proc quietRemoveFile(path: string) =
  try:
    if fileExists(extendedPath(path)):
      removeFile(extendedPath(path))
  except CatchableError, Defect:
    discard

proc streamHashFile(path: string): array[32, byte] =
  ## BLAKE3-256 over ``path`` read in ``CasStreamChunkSize`` chunks. The
  ## whole file is never resident.
  var f = open(extendedPath(path), fmRead)
  let hasher = blake3.initHasher()
  try:
    var buffer = newSeq[byte](CasStreamChunkSize)
    while true:
      let n = f.readBuffer(addr buffer[0], buffer.len)
      if n <= 0:
        break
      hasher.update(addr buffer[0], n)
    result = hasher.finalize()
  finally:
    try: hasher.close() except CatchableError: discard
    try: f.close() except CatchableError: discard

proc streamCopyFile(src, dst: string) =
  ## The always-available final arm. Copies ``src`` to ``dst`` in
  ## bounded chunks. It deliberately does NOT hash on the way through:
  ## the digest check runs over the staged RESULT so that every arm is
  ## verified identically (see ``casMaterializeDetailed``).
  var input = open(extendedPath(src), fmRead)
  var output: File
  var outputOpen = false
  try:
    output = open(extendedPath(dst), fmWrite)
    outputOpen = true
    var buffer = newSeq[byte](CasStreamChunkSize)
    while true:
      let n = input.readBuffer(addr buffer[0], buffer.len)
      if n <= 0:
        break
      if output.writeBuffer(addr buffer[0], n) != n:
        raise newException(IOError,
          "short write while materializing CAS blob to " & dst)
  finally:
    if outputOpen:
      try: output.close() except CatchableError: discard
    try: input.close() except CatchableError: discard

proc describeCopyOnlyPair(cap: LinkCapability;
                          allowSharedInode: bool): string =
  ## Why a pair got no link arm at all. Worth spelling out because the
  ## raw probe record understates one case: a cross-volume reflink on
  ## Windows fails ``ERROR_INVALID_PARAMETER`` (87), which the probe
  ## classifies ``loUnsupported``. The capability answer is right — the
  ## clone genuinely cannot happen — but "unsupported" reads as "this
  ## filesystem has no clone primitive" when the truth is "not across
  ## this device boundary". The hardlink attempt on the same pair
  ## answers ``loCrossDevice`` and settles it, so name that here.
  if not cap.probed:
    return "copy: the filesystem pair could not be probed (" &
      cap.describe() & ")"
  var reason =
    if cap.hardlinkAttempt.outcome == loCrossDevice:
      "copy: destination is on a different filesystem from the CAS " &
      "(hardlink reported cross-device; the reflink refusal on the " &
      "same pair is the same boundary, whatever error code it used)"
    else:
      "copy: neither reflink nor hardlink is available for this pair"
  if cap.hardlink and not allowSharedInode:
    reason = "copy: the pair supports hardlinks but the shared-inode " &
      "arm is disabled (M3 owns the mutation hazard)"
  reason & " [" & cap.describe() & "]"

proc casProbeSourceDir(cas: CasStore): string =
  ## The directory the capability probe attempts FROM. It is the blob
  ## tree's own root rather than one shard, so every shard shares one
  ## cached answer, and rather than the store's ``tmp/`` so the probe
  ## measures the filesystem that actually holds the blobs instead of
  ## assuming ``tmp/`` is mounted with it.
  cas.casBlobRoot() / "blake3"

proc casMaterializeDetailed*(cas: CasStore;
                             entries: openArray[CasMaterialization];
                             createParentDirs = true;
                             allowSharedInode =
                               CasMaterializeAllowSharedInodeDefault;
                             verify = cvmDigest): seq[CasMaterializeOutcome] =
  ## R11 Layer-1 cache-hit rehydrate, link-based since
  ## Local-CAS-Hardlink-Materialization M1. Materializes each
  ## ``entries[i].hash`` at ``entries[i].destination`` by the best
  ## mechanism the (CAS filesystem → destination filesystem) pair
  ## supports, in the order
  ## ``Local-Content-Addressed-Store.md`` §"Hardlink, Reflink, and Copy
  ## Policy" mandates: reflink → hardlink → copy. Returns one
  ## ``CasMaterializeOutcome`` per entry, in order.
  ##
  ## This is the seam a future ``repro_build_engine`` migration MUST
  ## call in place of ``LocalCas.restoreOutputs``; ``casMaterialize``
  ## is the same operation with the outcomes discarded.
  ##
  ## **Availability is probed, never predicted.** The mechanism list
  ## comes from ``preferredMechanisms`` over a real
  ## ``linkCapabilities`` probe of the filesystem pair, cached
  ## process-wide, so a cross-volume destination degrades to copy
  ## because ``link()`` said ``EXDEV`` / ``ERROR_NOT_SAME_DEVICE`` and
  ## not because anyone read a mount table.
  ##
  ## **Every arm falls back rather than fails.** A per-file limit
  ## (``isPerFileFallback`` — NTFS's 1024-name cap, ReFS's per-extent
  ## reference cap) drops THIS file to copy, records
  ## ``perFileFallback``, and leaves the cached pair capability alone.
  ##
  ## **The hardlink arm is off unless the caller opts in.** See
  ## ``CasMaterializeAllowSharedInodeDefault``.
  ##
  ## The no-partial-materialization contract
  ## ---------------------------------------
  ##
  ## The pre-M1 implementation promised that "a missing or corrupt
  ## later blob cannot leave an earlier output on disk", and got it for
  ## free by reading every blob into memory before writing any of them.
  ## Linking reads nothing, so the promise is now kept by construction
  ## in three explicit steps rather than as a side effect:
  ##
  ## 1. **Existence pre-pass.** Every blob is stat'd before any
  ##    destination is touched. A missing blob raises ``ECasMissing``
  ##    with nothing staged and nothing committed — byte-identical
  ##    observable behaviour to the old up-front ``casGet`` loop.
  ## 2. **Stage everything, commit nothing.** Each entry is
  ##    linked/cloned/copied into a temp name BESIDE its destination
  ##    (same directory ⇒ same filesystem ⇒ atomic rename) and, under
  ##    ``cvmDigest``, hash-verified there. Any failure — missing,
  ##    corrupt, unwritable, short write — unwinds every temp staged so
  ##    far and re-raises. No destination has been written.
  ## 3. **Commit.** Only once every entry has staged AND verified are
  ##    the renames performed.
  ##
  ## The guarantee is therefore preserved, and step 2 strengthens it:
  ## the bytes verified are the ones that will BE the destination, so a
  ## mechanism that silently produced a wrong file is caught, which the
  ## old "verify the source, then write it again" order could not do.
  ##
  ## The one difference: the commit renames themselves are not a single
  ## transaction, so a rename failing midway (a destination held open
  ## by another process, say) can leave earlier destinations replaced.
  ## That window existed before M1 too and is strictly narrower now —
  ## the old code interleaved write-then-rename per entry, so ANY later
  ## failure, including a failed write, left earlier outputs committed.
  result = newSeq[CasMaterializeOutcome](entries.len)
  if entries.len == 0:
    return

  # --- Step 1: existence pre-pass. Nothing on disk is touched yet.
  for entry in entries:
    if not fileExists(extendedPath(cas.casPath(entry.hash))):
      raise newException(ECasMissing,
        "missing CAS blob " & $entry.hash)

  let probeSrc = casProbeSourceDir(cas)

  type StagedEntry = object
    tmp: string
    dest: string

  var staged: seq[StagedEntry] = @[]

  template unwind() =
    ## Remove every temp name this call created. Deliberately
    ## best-effort: a temp we cannot delete is debris, not a
    ## half-materialized output, because nothing has been renamed.
    for s in staged:
      quietRemoveFile(s.tmp)

  # --- Step 2: stage every entry, commit none of them.
  for i, entry in entries:
    let dest = entry.destination
    let parent = parentDir(dest)
    if createParentDirs and parent.len > 0:
      try:
        createDir(extendedPath(parent))
      except CatchableError:
        unwind()
        raise

    let tmp = casStageName(dest)
    staged.add(StagedEntry(tmp: tmp, dest: dest))
    quietRemoveFile(tmp)

    # ``applyPermissions`` says this destination carries its own mode
    # bits. Mode bits are per-INODE, so honouring that request through
    # a hardlink would chmod the CAS blob itself — the first of the
    # three "consequences that follow from one inode" the spec lists.
    # Windows never applies permissions here (see the guarded block
    # below), so the exclusion is POSIX-only; making it unconditional
    # would disable the arm on the very platform M3 will enable it on.
    var entryAllowsSharedInode = allowSharedInode
    when not defined(windows):
      if entry.applyPermissions:
        entryAllowsSharedInode = false

    let cap =
      if parent.len > 0: linkCapabilities(probeSrc, parent)
      else: LinkCapability()
    let mechanisms = cap.preferredMechanisms(
      allowSharedInode = entryAllowsSharedInode)

    var outcome = CasMaterializeOutcome(mechanism: lmCopy)
    if mechanisms == @[lmCopy]:
      # No link arm was even offered for this pair, so no attempt will
      # run and no attempt-level message will exist. Record WHY here,
      # because "it copied" without a reason is the log line that makes
      # a misconfigured store look like a working one.
      outcome.diagnostic = describeCopyOnlyPair(cap,
                                                entryAllowsSharedInode)
    let blobPath = cas.casPath(entry.hash)

    try:
      for mech in mechanisms:
        case mech
        of lmReflink:
          let attempt = attemptReflink(blobPath, tmp)
          if attempt.outcome == loOk:
            outcome.mechanism = lmReflink
            break
          if attempt.isPerFileFallback():
            outcome.perFileFallback = true
          outcome.diagnostic = "reflink: " & attempt.message &
            " [" & cap.describe() & "]"
          quietRemoveFile(tmp)
        of lmHardlink:
          let attempt = attemptHardlink(blobPath, tmp)
          if attempt.outcome == loOk:
            outcome.mechanism = lmHardlink
            break
          if attempt.isPerFileFallback():
            outcome.perFileFallback = true
          outcome.diagnostic = outcome.diagnostic & " hardlink: " &
            attempt.message
          quietRemoveFile(tmp)
        of lmCopy:
          streamCopyFile(blobPath, tmp)
          outcome.mechanism = lmCopy
          break

      if verify == cvmDigest:
        # Deliberately the STAGED result, uniformly, in every arm —
        # never the source blob and never the bytes the copy arm
        # happened to have in a buffer. Verifying per-mechanism would
        # make integrity depend on which mechanism ran, which is the
        # one thing ``Local-Content-Addressed-Store.md`` says
        # correctness must never do. It costs the copy arm one extra
        # read of a file it just wrote (so, still cache-warm); it buys
        # the same guarantee for the link arms, which have no read of
        # their own to piggyback on.
        let actual = streamHashFile(tmp)
        if actual != entry.hash.bytes():
          raise newException(ECasDigestMismatch,
            "CAS digest mismatch materializing " & $entry.hash &
            " to " & dest & " via " & $outcome.mechanism)

      when not defined(windows):
        if entry.applyPermissions:
          setFilePermissions(extendedPath(tmp), entry.permissions)
    except CatchableError:
      unwind()
      raise

    result[i] = outcome

  # --- Step 3: commit. Every entry staged and verified.
  for s in staged:
    if fileExists(extendedPath(s.dest)):
      removeFile(extendedPath(s.dest))
    moveFile(extendedPath(s.tmp), extendedPath(s.dest))

  when not defined(windows):
    # Re-applied after the rename, as the pre-M1 code did: some
    # filesystems drop bits across a rename, and the destination's mode
    # is what the caller asked about.
    for entry in entries:
      if entry.applyPermissions:
        setFilePermissions(extendedPath(entry.destination), entry.permissions)

proc casMaterialize*(cas: CasStore;
                     entries: openArray[CasMaterialization];
                     createParentDirs = true;
                     allowSharedInode =
                       CasMaterializeAllowSharedInodeDefault;
                     verify = cvmDigest) =
  ## ``casMaterializeDetailed`` with the per-entry outcomes discarded.
  ## This is the shape every existing caller uses; the detailed
  ## overload exists for callers that want to log or assert on the
  ## mechanism that was actually used.
  discard cas.casMaterializeDetailed(entries, createParentDirs,
                                     allowSharedInode, verify)

# ---------------------------------------------------------------------------
# Garbage collection
# ---------------------------------------------------------------------------

proc casGc*(cas: var CasStore;
            retainRoots: HashSet[ContentHash]): int =
  ## CAS-only garbage collection. Walks the on-disk blob tree,
  ## unlinks every blob whose digest is NOT in ``retainRoots``, and
  ## returns the freed bytes.
  ##
  ## This is the narrow Layer-1 GC — it does NOT consult the Layer-2
  ## prefix or root tables. Callers that want the full store GC
  ## (walking the prefix graph and reclaiming everything unreachable
  ## from any live root) use ``repro store gc`` which delegates into
  ## ``repro_local_store.Store.gc``.
  ##
  ## The R11 canonical use is:
  ##   * builder computes a HashSet of blobs it wants to keep (e.g.
  ##     every output referenced by the current build plan);
  ##   * calls this to reclaim everything else.
  ##
  ## The ``retainRoots`` set is checked with O(1) membership; the
  ## on-disk walk is O(n) in the number of stored blobs.
  let blobRoot = cas.casBlobRoot() / "blake3"
  if not dirExists(blobRoot):
    return 0
  var freed = 0
  for shardKind, shardPath in walkDir(blobRoot):
    if shardKind != pcDir:
      continue
    let shardName = extractFilename(shardPath)
    if shardName.len != 2:
      continue
    for blobKind, blobPath in walkDir(shardPath):
      if blobKind != pcFile:
        continue
      let blobName = extractFilename(blobPath)
      # ``casBlobRelative`` writes the FULL 64-char hex as the blob
      # filename under the 2-char shard dir; the shard is a
      # duplicated prefix for FS-level fan-out, not a suffix
      # concatenation. If the layout is unexpected, skip.
      if blobName.len != 64:
        continue
      if not blobName.startsWith(shardName):
        continue
      let bytesArr = parseHexToBytes(blobName)
      # Zero-array from parseHexToBytes means malformed hex; skip.
      var allZero = true
      for i in 0 ..< 32:
        if bytesArr[i] != 0'u8:
          allZero = false
          break
      let candidate = ContentHash(bytesArr)
      if not allZero and candidate in retainRoots:
        continue
      let size =
        try: getFileSize(blobPath).int
        except: 0
      try:
        removeFile(blobPath)
        freed += size
      except OSError:
        discard
  freed

import std/[algorithm, monotimes, nativesockets, options, os, sets,
            strutils, tables, times]

when defined(posix):
  import std/posix

when defined(windows):
  import std/winlean

when defined(posix):
  # Nim's `std/posix` does not expose `flock(2)` uniformly across macOS and
  # Linux, so bind the small `sys/file.h` surface directly (mirrors
  # repro_home_generations/locks.nim). Used to serialize the durable
  # per-cache-root write-sequence counter (AC-1b: deterministic newest-wins
  # record ordering) across concurrent build engine processes.
  const
    SeqLockExclusive = 2.cint

  proc cFlockSeq(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}

import repro_core
import repro_hash

# Re-export the new M56 content-addressed local store API. The pre-M56
# `LocalCas` and `ActionCache` types below remain for the action-cache
# code path the M9 build engine still consumes; the M56 entry points
# live in `repro_local_store/store.nim` and
# `repro_local_store/sqlite3_binding.nim`.
import ./repro_local_store/action_index
import ./repro_local_store/sqlite3_binding
import ./repro_local_store/store
import ./repro_local_store/lru_eviction
import ./repro_local_store/sandbox_manifest
import ./repro_local_store/optimise
export action_index
export sqlite3_binding
export store
export lru_eviction
export sandbox_manifest
export optimise

type
  LocalStoreError* = object of CatchableError
  CacheIntegrityError* = object of LocalStoreError
  ActionRecordError* = object of LocalStoreError

  FileFingerprintPolicy* = enum
    ffpTimestamp
    ffpChecksum
    ffpHybrid

  FingerprintedFileKind* = enum
    ffkMissing
    ffkRegular
    ffkDirectory
    ffkOther

  FileMetadata* = object
    kind*: FingerprintedFileKind
    sizeBytes*: uint64
    mtimeNs*: uint64

  FileFingerprint* = object
    path*: string
    policy*: FileFingerprintPolicy
    metadata*: FileMetadata
    hasLocalHash*: bool
    localHash*: LocalInvalidationHash

  CasBlobRef* = object
    digest*: ContentDigest
    sizeBytes*: uint64

  OutputPayloadKind* = enum
    opkCasBlobs
    opkMetadataOnly

  OutputBlob* = object
    path*: string
    metadata*: FileMetadata
    blob*: CasBlobRef
    permissions*: set[FilePermission]
    changeTimeNs*: uint64
      ## POSIX `st_ctime` of the output at record time; 0 when the platform
      ## cannot report it (Windows) or when no witness sidecar was found.
      ##
      ## NOT serialized into the RBAR frame -- carried in the witness
      ## sidecar (`writeWitnessSidecar`), so the record format is unchanged
      ## and older binaries sharing a cache root are unaffected.
      ##
      ## This is the field that makes in-place output tampering detectable
      ## at zero extra cost. `kind`/`size`/`mtime` are all settable from
      ## userspace -- `utimensat(2)` restores an mtime exactly, and a write
      ## that stays inside the file leaves the size alone -- so a metadata
      ## comparison over those three accepts a silently corrupted artifact.
      ## `st_ctime` is maintained by the kernel on every inode change and
      ## has no userspace setter, so any write to the file moves it and it
      ## cannot be moved back. It costs nothing: it arrives in the same
      ## `lstat(2)` that already produces kind/size/mtime.
      ##
      ## It is deliberately NOT part of `FileMetadata`: inputs keep exactly
      ## their previous comparison semantics (and `strongIdentityPayload`
      ## keeps producing identical fingerprints), so this cannot cause a
      ## spurious input invalidation or invalidate an existing cache.
      ##
      ## WINDOWS: this stays 0. NTFS does maintain an unsettable ChangeTime,
      ## reachable through `GetFileInformationByHandleEx(FileBasicInfo)`, but
      ## `fingerprintMetadata`'s Windows path uses `GetFileAttributesExW`,
      ## which does not report it. Until that is wired up, the defect this
      ## field exists to close remains OPEN on Windows: a regular-file output
      ## rewritten in place with its size and write time restored still
      ## compares equal there.
    linkTarget*: string
      ## `readlink()` of the output at record time, empty when it was not a
      ## symlink. `fingerprintMetadata` reports a symlink-to-file as
      ## `ffkRegular` carrying the LINK's own lstat size and mtime, so a
      ## retargeted link whose mtime is restored with
      ## `utimensat(..., AT_SYMLINK_NOFOLLOW)` compares equal on every
      ## recorded field. Comparing the target string is O(1) and exact.
    treeDigest*: uint64
      ## Order-independent digest over the recursive METADATA of a directory
      ## output (relative path, kind, size, mtime, change time per entry).
      ## Meaningful only when `hasTreeDigest`.
      ##
      ## A directory's own recorded metadata is deliberately empty --
      ## `fingerprintMetadata` zeroes `sizeBytes`/`mtimeNs` for
      ## `ffkDirectory` -- so comparing it asks only "does the directory
      ## still exist". That leaves an opaque directory output completely
      ## unprotected, which is a shipped shape (the JS/TS convention declares
      ## `node_modules/`). This digest is the comparison that actually says
      ## something.
      ##
      ## It costs one `lstat(2)` per entry in the tree on every warm
      ## consultation of an edge that declares a directory output -- O(tree
      ## entries), no content reads. That is a real and openly acknowledged
      ## cost for such edges. The cheaper alternatives were all unsound: the
      ## directory's own mtime/ctime move only for top-level entry changes
      ## and say nothing about a nested file being rewritten. An edge that
      ## cannot afford the walk should be made payload-backed (CAS directory
      ## snapshot plus digest verification), not left unchecked.
    hasTreeDigest*: bool

  EnvFingerprint* = object
    ## One OBSERVED ENVIRONMENT VARIABLE, and what it held when the action
    ## ran.
    ##
    ## io-mon records `mrEnvRead` with the variable's NAME: the monitor saw
    ## that the build asked for it, and folding the VALUE into the cache key
    ## is the consumer's half of the contract (BuildXL's observed-environment
    ## model). This is that half. Before it existed, `foldMonitorDepFileEvidence`
    ## dropped `mrEnvRead` on its `else: discard` arm -- so a build could read
    ## `SOURCE_DATE_EPOCH` or `CFLAGS`, the capture could record the read
    ## faithfully, and the action cache would still serve a stale result when
    ## the value changed.
    ##
    ## `present` is carried separately from an empty `value` because the two
    ## are DIFFERENT states that programs act on differently: `if
    ## os.environ.get("X")` and `if os.environ["X"] != ""` are not the same
    ## test, and a variable going from unset to empty must invalidate.
    name*: string
    present*: bool
    value*: string

  EntryDeterminism* = object
    ## The determinism metadata one cache entry carries, per §3's table.
    ##
    ## `declared = false` is the state of every record written before this
    ## existed, and of every edge whose tool declares no `determinism`
    ## directive. It is NOT the same as `class = edWeak`: an undeclared entry
    ## has no host fingerprint and no write time either, so a consumer that
    ## needs one of those must fail closed rather than assume.
    declared*: bool
    class*: EdgeDeterminism
    retention*: CacheRetention
    writeTimeUnix*: int64
      ## Wall-clock seconds at which the entry was written. §3's `volatile`
      ## write column. 0 when unknown, which `retentionVerdict` treats as
      ## `rvUnknownWriteTime` — a miss, never a hit.
    hostFingerprint*: string
      ## §3's `host-bound` write column: machine-id / OS / architecture,
      ## enough to say WHICH host's realization this is. Empty when
      ## undeclared. It is not a security token and is never compared for
      ## equality on the local read path — a local hit is by definition on
      ## the producing host. It exists so a cross-machine substitution can be
      ## REFUSED with the producing host named, rather than refused blankly.
    buildEpoch*: string
      ## Identifies the `repro build` invocation that wrote the entry, for
      ## §2.2's `this-build` clause. Empty when undeclared.

  ActionResultRecord* = object
    weakFingerprint*: ContentDigest
    policy*: FileFingerprintPolicy
    inputs*: seq[FileFingerprint]
    envInputs*: seq[EnvFingerprint]
      ## The environment variables the monitor observed this action reading.
      ## Empty for every action that read none, and for every record written
      ## before this field existed -- which is why an empty seq contributes
      ## NOTHING to `strongIdentityPayload` and leaves the record at the older
      ## on-disk version. Existing cache entries keep their keys and stay
      ## readable by an older peer.
    strongFingerprint*: ContentDigest
    outputPayloadKind*: OutputPayloadKind
    outputs*: seq[OutputBlob]
    determinism*: EntryDeterminism
      ## `Edge-Determinism-And-Soft-Rebuild.md` §3's per-class cache metadata:
      ## the producing action's determinism class, the host fingerprint that
      ## makes a `host-bound` realization attributable, and the wall-clock
      ## write time + retention clause that bound a `volatile` one.
      ##
      ## NOT serialized into the RBAR frame and NOT part of either
      ## fingerprint. It travels in a SIDECAR file next to the `.rec`, exactly
      ## as the output witnesses do and for exactly the same reason (see
      ## `ActionRecordVersion`'s "DELIBERATELY NOT BUMPED" comment): growing
      ## the frame would lock every older `repro` sharing the per-user cache
      ## root out of the records this binary writes.
      ##
      ## Keeping it out of the KEY is also a spec requirement, not just a
      ## compatibility convenience — §10.2: "The class is NOT part of the
      ## cache key (so a relabel from `weak` to `strong` does not invalidate
      ## existing entries) — it is metadata that gates HOW the cached bytes
      ## are used."

  EnvResolver* = proc(name: string): tuple[present: bool, value: string]
    {.gcsafe, raises: [].}
    ## How a lookup re-reads an observed variable's CURRENT value.
    ##
    ## Supplied by the caller rather than read from the process environment,
    ## because the value that matters is the one the ACTION would see -- the
    ## engine composes that env per action, and the daemon process running the
    ## lookup has a different one. A `nil` resolver means the caller cannot
    ## answer, and a record carrying env inputs is then treated as CHANGED:
    ## re-running an action is recoverable, serving a stale result is not.

  LocalCas* = object
    root*: string

  ShmTier* = ref object
    ## The engine's attached view of the Tier-2 shared-memory index
    ## (Action-Cache-Per-Edge-Store.md §6) for one cache root. A `ref` so an
    ## `ActionCache` VALUE can be copied (the warm handle in the engine is
    ## copied in and out of a process-wide table) without duplicating the
    ## mapping or double-detaching — every copy shares the one attached chain.
    ##
    ## `enabled` gates the whole tier: when false (non-POSIX, attach failed, or
    ## opted out) every read is pure Tier-1 disk and every record is Tier-1
    ## only — the identical decision, reached without the accelerator.
    ##
    ## There is no submission slot here and no size test anywhere on the write
    ## path. The index holds 84-byte REFERENCES, so a record's size is not an
    ## admission criterion: the structure grows by sharding, an insert never
    ## blocks and nothing is ever dropped for want of capacity.
    enabled*: bool
    idx*: ActionIndex
    bypassNoted*: bool
      ## §6.8: an engine that declines the index still writes Tier 1, so it
      ## bumps `bypassWrites` ONCE before its first write if a chain exists.
      ## That voids every completeness claim in the chain until the next
      ## flatten, which is what keeps the escape hatch safe rather than merely
      ## documented.

  ActionCache* = object
    root*: string
    shm*: ShmTier
      ## The optional Tier-2 shared-memory index (§6). nil / disabled ⇒ pure
      ## Tier-1 disk-only. The DECISION (hit/miss/strong-fp) is identical
      ## either way; the index only changes HOW the candidate set for an edge
      ## is discovered — from mapped memory instead of from a directory
      ## enumeration — and can turn a miss into a hit when another engine on
      ## the host published a record this process has not read from disk.
    # Root holding the authoritative per-edge record store. Each edge (keyed
    # by its weak fingerprint via `perEdgeDirName`) owns a DIRECTORY
    # `hot-records/<key>/` containing one `<nonce>.rec` file per observed
    # path-set (AC-1b, Action-Cache-Per-Edge-Store.md §3, §8). There is no
    # global append-only log; every write is a temp-file + atomic-rename
    # publish of a SINGLE path-set's `.rec` file, so cross-edge contention is
    # impossible AND two independent concurrent builds of the same edge that
    # saw DIFFERENT path-sets never clobber each other (last-rename-wins
    # affected only the single AC-1 file; here they target distinct `.rec`
    # nonces). Identical path-sets converge on the same nonce file. A
    # pre-existing AC-1 single `hot-records/<key>` FILE is still read for
    # back-compat.
    hotRoot: string

  FileMetadataCache* = object
    entries: Table[string, FileMetadata]
    stats: FileMetadataCacheStats

  FileMetadataCacheStats* = object
    currentRunHits*: int
    coldStats*: int
    warmEntries*: int
    warmRevalidated*: int
    warmUnchanged*: int
    warmChanged*: int
    # The DURATION half of the three counts above, in nanoseconds, measured
    # around the WHOLE check -- table probe, prefix scan, `lstat(2)`,
    # comparison -- and attributed to the arm the check actually took.
    #
    # In the cache object rather than in a process-global, deliberately: the
    # counts beside them are per-cache, a build makes more than one cache
    # (the whole-graph fast-noop scan's and the scheduler's), and only one
    # of those is ever reported. A global duration would describe both while
    # the count described one, which is the failure mode that makes a row
    # worse than no row at all.
    #
    # They cost one `getMonoTime` pair per outermost check, measured at
    # 33-36 ns on macOS arm64. Against `cold stat` and `warm revalidate`,
    # which are syscall-bound at microseconds, that is under 1%. Against
    # `current-run hit`, which is a `Table` probe at ~100 ns, it is a large
    # fraction of the reading, so READ THAT ROW AS AN UPPER BOUND: subtract
    # ~34 ns per hit to recover the work alone.
    currentRunHitNanos*: int64
    coldStatNanos*: int64
    warmRevalidateNanos*: int64

  ActionCacheLookupStatus* = enum
    aclMissNoRecord
    aclMissInputChanged
    aclMissNoOutputPayload
    aclHit
    aclHybridCutoff
    aclRejectedCorruptOutput
    aclMissRetentionExpired
      ## `Edge-Determinism-And-Soft-Rebuild.md` §4.4. The record matched on
      ## every input, its outputs verified, and it was still not served:
      ## its producing action is `volatile` and its `cacheRetention` clause
      ## says this realization is no longer good. Deliberately a DISTINCT
      ## status from `aclMissInputChanged`, because the operator question
      ## it answers is different -- nothing changed, the answer simply
      ## aged out -- and collapsing the two would make a retention that is
      ## set too tight indistinguishable from a real invalidation storm.
      ##
      ## APPENDED, not inserted. `aclHit` and its neighbours keep their
      ## ordinals so nothing that persisted or compared one shifts.

  ActionCacheLookup* = object
    status*: ActionCacheLookupStatus
    record*: ActionResultRecord
    message*: string
    changedInputPath*: string

  HotMetadataProbe* = object
    weakFingerprint*: ContentDigest
    policy*: FileFingerprintPolicy
    outputRoot*: string
      ## The action's cwd, used to resolve the record's relative output
      ## paths so the whole-build fast path can revalidate output state
      ## (Incremental-Invalidation.md §"Minimum check set" Step 3.3).
    refuseRecordWithNoInputs*: bool
      ## Treat a matched record that has NO input fingerprints and NO
      ## environment inputs as if there were no record at all.
      ##
      ## Such a record is keyed on the weak fingerprint alone: the loop below
      ## finds nothing to compare against the filesystem, so it reports a hit
      ## unconditionally, forever, whatever changed. WHICH edges may never be
      ## in that state is an engine policy question and stays there — see
      ## `repro_build_engine.unservableCacheRecordReason`, which sets this and
      ## owns the scope. Defaulted false, so every other caller of this scan
      ## behaves exactly as before (a built-in write-text edge legitimately
      ## has no file inputs and is keyed on text its caller mixed into the
      ## weak fingerprint).
      ##
      ## It has to be HERE, and not only at `lookupActionResult`, because this
      ## scan is the whole-graph shortcut: when it answers `hmssHit` the
      ## scheduler never runs and no per-edge lookup happens at all.
      ## `skipCacheHitEvidence` — the arm that reaches this function — is the
      ## default on the main CLI path, so a check placed only at the per-edge
      ## lookup is a check the production path does not execute.

  HotMetadataScanStatus* = enum
    hmssUnavailable
    hmssHit
    hmssMissingRecord
    hmssInputChanged
    hmssCorrupt
    hmssOutputChanged
    hmssPolicyNeedsContentHash
      ## The probe's fingerprint policy is not one this scan can decide: its
      ## validation criterion is the recorded CONTENT HASH, and everything on
      ## this path compares `FileMetadata` — `{kind, sizeBytes, mtimeNs}` —
      ## only. See `MetadataValidatedPolicies`. Not an error and not a miss:
      ## it means "ask the per-edge lookup", which computes the hash.

  HotMetadataScan* = object
    status*: HotMetadataScanStatus
    recordCount*: int
    inputCount*: int
    checkedInputCount*: int
    detail*: string

const
  MetadataValidatedPolicies* = {ffpTimestamp, ffpHybrid}
    ## THE POLICIES A METADATA-ONLY CHECK MAY DECIDE, written down ONCE.
    ##
    ## `ffpTimestamp`'s validation criterion IS the recorded `FileMetadata`
    ## — `{kind, sizeBytes, mtimeNs}` — so a metadata comparison is the whole
    ## answer. `ffpHybrid` compares metadata FIRST and only reaches for the
    ## content hash when the metadata moved, so metadata-unchanged is a
    ## sufficient (never a false) hit for it too.
    ##
    ## `ffpChecksum` is NOT here, and that is the point. Its criterion is
    ## `FileFingerprint.localHash`, which lives OUTSIDE `metadata`: a write
    ## that keeps the length and restores the mtime (`utimensat(2)` does it
    ## exactly) changes the content and leaves every metadata field alone. A
    ## metadata-only check therefore answers "unchanged" for an input that
    ## changed, and an edge that asked to be validated by content is served
    ## a stale artifact.
    ##
    ## IT IS A SHARED CONST BECAUSE IT WAS TWO COPIES AND ONE OF THEM WAS
    ## MISSING. `lookupHotMetadataRecord` carried the set inline and refused
    ## correctly; `scanHotIndexMetadataInputsUnchanged` — the OTHER arm of
    ## the same whole-graph shortcut, and the one the CLI takes by default —
    ## carried no such test at all, so a `ffpChecksum` edge whose content
    ## changed under a preserved size and mtime came back `hmssHit` and the
    ## whole graph was reported up to date. Measured on the engine API, same
    ## graph and same mutation: the evidence-skipping arm returned
    ## `asUpToDate`/`cdHit`/`launched = false` with the stale output still in
    ## place, while the per-record arm relaunched and produced the right one.
    ## Both arms now read this name; there is no second copy to forget.
    ##
    ## Spec: Incremental-Invalidation.md §"File Fingerprint Policies",
    ## Failure-Semantics.md:11-12 (ambiguous correctness failures MUST fail
    ## closed). Issue #382 defect 2.

  ActionRecordMagic = "RBAR"
  # THE VERSIONS BELOW ARE FORMAT HISTORY. The evidence epochs below define
  # which records may be read and written -- see `ActionRecordVersionEvidenceEpoch`, which
  # explains why this decoder refuses every earlier frame rather than
  # tolerating it. The earlier constants stay because the decoder's shape is
  # still expressed in terms of them ("does this frame have an env section?",
  # "are its paths interned?") and deleting them would turn readable version
  # gates into bare integers.
  #
  # DELIBERATELY NOT BUMPED FOR FORMAT GROWTH. The output witnesses this file
  # adds (change time, symlink target, directory metadata digest) live in a
  # SIDECAR file next to the `.rec`, not inside the RBAR frame -- see
  # `OutputWitness` and `writeWitnessSidecar`. Growing the frame would have
  # required a version bump, and a bump is never cheap: a frame at an unknown
  # version makes `loadPerEdgeRecords` return ZERO records (the per-frame
  # `except EnvelopeError: break` swallows it), and `decodeActionResultRecord`,
  # the public codec the peer cache and the dependency-evidence reader use,
  # raises outright. An 8-byte field does not justify that. That judgement is
  # unchanged by the epoch bump below: bump this only to draw another TRUST
  # line, never to grow the format, and write down which line and why.
  ActionRecordVersion = 3'u16
  ActionRecordVersionEnv = 4'u16
    ## Written ONLY for a record that actually carries observed environment
    ## inputs; a record with none stayed at version 3. Retained as the gate
    ## that asks whether a frame has an env section at all.
  ActionRecordVersionInterned = 5'u16
    ## Action-Cache-Per-Edge-Store.md §5.5 C4: the record carries a path table
    ## LOCAL TO ITSELF, and every path field is an index into it plus the
    ## file's own name. Retained as the gate that asks whether a frame's paths
    ## are interned.
    ##
    ## This changed the STORAGE encoding only. The strong fingerprint is
    ## computed by `strongIdentityPayload`, which is untouched, so no key in
    ## any existing cache moves and no warm build anywhere misses because of
    ## it. Interning inside `strongIdentityPayload` would have shifted every
    ## strong fingerprint on every disk in the world; that is why the two
    ## payloads are separate functions and must stay separate.
  ActionRecordVersionInheritedEnv = 7'u16
    ## Same layout as v6, but observed environment values include inheritance
    ## and launch overlays. A v6 record with env inputs can falsely label a
    ## value as absent, so only v7 is trusted for that class of record.
    ## Records without env inputs retain v6 and do not pay an unrelated miss.
  ActionRecordVersionEvidenceEpoch = 6'u16
    ## The minimum trusted version for records without environment inputs. This is
    ## a TRUST boundary, not a format one: byte-for-byte, a v6 frame is a v5
    ## frame. Nothing about the encoding changed; what changed is whether the
    ## producer's evidence could be believed.
    ##
    ## WHAT IS UNTRUSTED. Starting 2026-09-02 03:44 the engine seeded an
    ## observed-evidence channel from its own bookkeeping and then asked the
    ## guard whether the monitor had observed anything WITHOUT distinguishing
    ## the two: `collectEvidence`'s root-image fold put the action's own
    ## `argv[0]`, a path the launcher RECONSTRUCTS, into `monitorReads`, and the
    ## guard tested that set for emptiness. That made the check which refuses to
    ## publish a record from an action that observed nothing unreachable for
    ## every action whose image resolves -- which is the same set of actions the
    ## check protects. Measured: a capture holding one process-start record and
    ## nothing else published, and the engine then took a cache hit on that
    ## record and did not run the action.
    ##
    ## The guard was re-armed by `engineSuppliedRootImage` /
    ## `monitorObservedNoReads` (b43238d2), which record the engine's own
    ## contribution separately so the guard can ask about observations alone.
    ## EVERY record version that existed before that point -- 2, 3, 4 and 5
    ## alike -- was written by a binary whose guard was dead. Version 5 is not a
    ## safe floor merely because it is the newest: it landed 2026-09-09, a week
    ## INTO the window, for an unrelated path-interning change. The first
    ## trustworthy version is this one.
    ##
    ## WHY AN EPOCH AND NOT A PREDICATE THAT RECOGNISES THE BAD RECORDS.
    ## Because there is no such predicate. What identifies one of these records
    ## -- "the monitor observed nothing" -- was never written into it: the
    ## reconstruction and the observation were merged into one input list at
    ## publish time, and Dependency-Observation-Attribution.md rule 6 is
    ## precisely that once they are merged nothing downstream can separate
    ## them. A record whose input list is `["/bin/sh"]` because the engine
    ## reconstructed it is byte-identical to one whose input list is
    ## `["/bin/sh"]` because a process really read it. The publish-side fix
    ## cannot reach them either: lookup is by weak fingerprint, happens before
    ## the action runs, and re-derives the strong fingerprint from the record's
    ## OWN input list, so a bad record keeps validating against itself forever.
    ## The only sound discriminator left is WHEN the record was written, and a
    ## version is the cheapest and most total form of "written before this
    ## point".
    ##
    ## WHY A CONSTANT OF OUR OWN RATHER THAN REUSING 5. Because the boundary
    ## has to stay attached to its REASON. Pinning it to `…Interned` would
    ## pin a trust decision to the accidental date of a format change, and a
    ## later renumbering of that format constant would move the trust line
    ## silently.
    ##
    ## WHAT IT COSTS, PLAINLY. Every action-cache record, peer-cache bundle and
    ## shm slot that exists today is ignored -- not some of them, all of them.
    ## That is one full rebuild, once, for everyone. Build OUTPUTS are
    ## unaffected: this invalidates cached ANSWERS, never artifacts. An older
    ## `repro` sharing a per-user cache root also ignores what this one writes,
    ## so the installed binary must move with this change (DA-1h) or the two
    ## will thrash on one cache root. That is a large cost and it is the
    ## correct trade: a one-time rebuild is recoverable, and silently serving
    ## an entry keyed on inputs nothing observed is not (Failure-Semantics.md:
    ## 11-12 -- "reject cache reuse, rerun, or require review rather than
    ## silently accepting stale state").
    ##
    ## THIS OVERRIDES A DELIBERATE UPSTREAM COMPATIBILITY DECISION. The
    ## interning bump chose to keep reading 2, 3 and 4 so that "an existing
    ## cache keeps working, and this binary keeps reading every record it could
    ## read before". That choice was right for a format change and is wrong for
    ## this one: back-compatibility is exactly the property that keeps the
    ## untrustworthy records reachable.
    ##
    ## Every reader degrades to a MISS rather than an error, verified by
    ## reading each call site rather than assumed: `decodeRecord` is the ONLY
    ## parser of RBAR bytes in the tree, and its four callers are
    ## `decodePerEdgeFileWithSeq` (stops at the first undecodable frame and
    ## returns a shorter list; `loadPerEdgeRecords` treats an empty list as an
    ## undecodable container), `perEdgeRecordFileIsIntact` (returns false),
    ## `decodeActionResultRecord` via the peer-cache bundle decoder (wrapped in
    ## `except CatchableError` -> peer miss), and the standalone `.rbar`
    ## diagnostic reader. The shm tier stores digests, not bytes, and reopens
    ## the containers through the same path.
  MaxRecordPathTableEntries = 4_000_000'u32
  # Per-edge record file: a small self-describing container holding the
  # edge's bounded record set. Each contained record is the existing
  # `RBAR` full-record frame, so producers/consumers (incl. the peer cache)
  # stay byte-compatible with `encodeActionResultRecord`.
  PerEdgeFileMagic = "RBPE"
  # v1: header {magic, version, recordCount} then the record frames.
  # v2 (AC-1b fix): inserts a durable u64 `writeSequence` immediately after
  # the version, BEFORE the record count. The sequence is a strictly
  # monotonic per-cache-root counter (see `nextWriteSequence`) stamped at
  # write time, so the union read can order the split `.rec` files by TRUE
  # write recency (newest-wins / newest-corrupt-rejects) rather than by racy
  # filesystem mtime. v1 files and legacy AC-1 single files decode fine and
  # are assigned sequence 0 (treated as oldest), then re-stamped on next write.
  PerEdgeFileVersion = 2'u16
  PerEdgeFileVersionLegacy = 1'u16
  # Filename of the durable, flock-serialized write-sequence counter, kept at
  # the `hot-records/` root (a SIBLING of the per-edge `<key>/` directories).
  # It is never a `<key>/` directory and never a `.rec` file, so no per-edge
  # dir listing or record read path ever mistakes it for an edge or a record.
  WriteSequenceFileName = ".seq"
  RecordTailMask = 0xffff_ffff'u64
  MaxActionRecordFrameBytes = 64 * 1024 * 1024
  MaxRecordsPerWeakFingerprint = 2
  DirectorySnapshotMagic = "RBDT"
  DirectorySnapshotVersion = 1'u16
  MaxDirectorySnapshotEntries = 10_000_000'u32
  MaxDirectorySnapshotPathBytes = 32 * 1024
  # AC-1b: Tier-1 is a DIRECTORY per edge (`hot-records/<key>/`) with one
  # `<nonce>.rec` file per observed path-set, so two independent concurrent
  # builds of the same edge that saw DIFFERENT path-sets (different strong
  # fingerprints) never clobber each other's record via last-rename-wins
  # (Action-Cache-Per-Edge-Store.md §3, §8). Distinct path-sets are few, so
  # the directory is capped at `MaxRecFilesPerEdge` files (oldest by durable
  # write sequence evicted beyond the cap), keeping the disk store small.
  PerEdgeRecFileExt = ".rec"
  MaxRecFilesPerEdge = 8
  # Action-Cache-Per-Edge-Store.md §5.5 C1: "Give the newest container a
  # fixed, distinguished name in the edge directory, so a consultation can
  # open it by name."
  #
  # The name deliberately does NOT end in `PerEdgeRecFileExt`, `WitnessFileExt`
  # or `DeterminismFileExt`, which is what §5.5 "Compatibility" requires: every
  # reader that existed before this change filters on one of those three
  # suffixes, so all of them IGNORE this file. It is invisible to the union
  # read, to `capRecFiles`' retention accounting and to its sidecar reaper, and
  # a binary that predates it behaves exactly as it did.
  NewestAliasFileName = "newest.rbal"
  NewestAliasMagic = "RBNA"
  NewestAliasVersion = 1'u16
  AllFilePermissions {.used.} = {fpUserExec, fpUserWrite, fpUserRead,
    fpGroupExec, fpGroupWrite, fpGroupRead,
    fpOthersExec, fpOthersWrite, fpOthersRead}
    # Windows: marked {.used.} because readPermissions only iterates this set
    # on POSIX hosts; on Windows we discard the recorded mask entirely.

var processWarmFileMetadataEntries = initTable[string, FileMetadata]()

proc byteString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc bytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc readByte(data: openArray[byte]; pos: var int): byte =
  if pos >= data.len:
    raiseEnvelopeError(eeMalformed, "truncated byte")
  result = data[pos]
  inc pos

proc writeDigest(outp: var seq[byte]; digest: ContentDigest) =
  outp.add(byte(ord(digest.algorithm)))
  outp.add(byte(ord(digest.domain)))
  outp.add(digest.bytes)

proc readDigest(data: openArray[byte]; pos: var int): ContentDigest =
  let algorithm = readByte(data, pos)
  let domain = readByte(data, pos)
  if algorithm > byte(ord(haXxh3_64)):
    raiseEnvelopeError(eeMalformed, "invalid digest algorithm")
  if domain > byte(ord(hdMetadataEnvelope)):
    raiseEnvelopeError(eeMalformed, "invalid digest domain")
  if pos + 32 > data.len:
    raiseEnvelopeError(eeMalformed, "truncated digest bytes")
  result.algorithm = HashAlgorithm(algorithm)
  result.domain = HashDomain(domain)
  for i in 0 ..< 32:
    result.bytes[i] = data[pos + i]
  pos += 32

proc writeLocalHash(outp: var seq[byte]; value: LocalInvalidationHash) =
  outp.add(byte(ord(value.algorithm)))
  outp.add(byte(ord(value.domain)))
  outp.writeU64Le(value.value)

proc readLocalHash(data: openArray[byte]; pos: var int): LocalInvalidationHash =
  let algorithm = readByte(data, pos)
  let domain = readByte(data, pos)
  if algorithm > byte(ord(haXxh3_64)):
    raiseEnvelopeError(eeMalformed, "invalid local hash algorithm")
  if domain > byte(ord(hdMetadataEnvelope)):
    raiseEnvelopeError(eeMalformed, "invalid local hash domain")
  result.algorithm = HashAlgorithm(algorithm)
  result.domain = HashDomain(domain)
  result.value = readU64Le(data, pos)

proc writeMetadata(outp: var seq[byte]; metadata: FileMetadata) =
  outp.add(byte(ord(metadata.kind)))
  outp.writeU64Le(metadata.sizeBytes)
  outp.writeU64Le(metadata.mtimeNs)

proc readMetadata(data: openArray[byte]; pos: var int): FileMetadata =
  let kind = readByte(data, pos)
  if kind > byte(ord(ffkOther)):
    raiseEnvelopeError(eeMalformed, "invalid file metadata kind")
  result.kind = FingerprintedFileKind(kind)
  result.sizeBytes = readU64Le(data, pos)
  result.mtimeNs = readU64Le(data, pos)

proc writePermissions(outp: var seq[byte]; permissions: set[FilePermission]) =
  # Windows: the POSIX rwx model does not apply to NTFS (NTFS uses ACLs).
  # For the first round of the Windows port, serialize 0 so cached records
  # round-trip without applying nonsensical permissions on restore. Proper
  # ACL / SetFileAttributes preservation is a follow-up.
  when defined(windows):
    outp.writeU16Le(0'u16)
  else:
    var mask = 0'u16
    for permission in permissions:
      mask = mask or (1'u16 shl ord(permission))
    outp.writeU16Le(mask)

proc readPermissions(data: openArray[byte]; pos: var int): set[FilePermission] =
  let mask = readU16Le(data, pos)
  let knownMask = (1'u16 shl (ord(fpOthersRead) + 1)) - 1
  if (mask and not knownMask) != 0:
    raiseEnvelopeError(eeMalformed, "invalid file permission mask")
  # Windows: any mask we encounter (whether 0 from a Windows writer or
  # a non-zero mask from a POSIX writer) is intentionally discarded — the
  # rwx bits have no Windows equivalent and we don't try to translate them
  # onto NTFS ACLs yet.
  when defined(windows):
    discard mask
    result = {}
  else:
    for permission in AllFilePermissions:
      if (mask and (1'u16 shl ord(permission))) != 0:
        result.incl(permission)

type
  DirectorySnapshotEntryKind = enum
    dsekDirectory
    dsekRegularFile
    dsekSymlink

  DirectorySnapshotEntry = object
    kind: DirectorySnapshotEntryKind
    relativePath: string
    permissions: set[FilePermission]
    sourcePath: string
    symlinkTarget: string

  DecodedDirectorySnapshotEntry = object
    kind: DirectorySnapshotEntryKind
    relativePath: string
    permissions: set[FilePermission]
    contentStart: int
    contentLength: int
    symlinkTarget: string

proc snapshotPermissions(path: string): set[FilePermission] =
  when defined(windows):
    result = {}
  else:
    try:
      result = getFilePermissions(extendedPath(path))
    except OSError:
      result = {}

proc directorySnapshotRelativePath(root, path: string): string =
  # ``walkDir(extendedPath(...))`` preserves the ``\\?\`` prefix in paths it
  # yields on Windows. Compare against the root in the same namespace so the
  # prefix cannot be mistaken for part of a relative output path.
  result = relativePath(path, extendedPath(root)).replace('\\', '/')
  if result.len == 0 or result == "." or result.startsWith("/"):
    raise newException(CacheIntegrityError,
      "directory snapshot produced an invalid relative path: " & result)
  for component in result.split('/'):
    if component.len == 0 or component == "." or component == "..":
      raise newException(CacheIntegrityError,
        "directory snapshot path escapes its root: " & result)

proc collectDirectorySnapshotEntries(root, current: string;
                                     entries: var seq[DirectorySnapshotEntry]) =
  for kind, path in walkDir(extendedPath(current)):
    let relative = directorySnapshotRelativePath(root, path)
    case kind
    of pcDir:
      entries.add(DirectorySnapshotEntry(
        kind: dsekDirectory,
        relativePath: relative,
        permissions: snapshotPermissions(path),
        sourcePath: path))
      collectDirectorySnapshotEntries(root, path, entries)
    of pcFile:
      entries.add(DirectorySnapshotEntry(
        kind: dsekRegularFile,
        relativePath: relative,
        permissions: snapshotPermissions(path),
        sourcePath: path))
    of pcLinkToFile, pcLinkToDir:
      when defined(windows):
        raise newException(CacheIntegrityError,
          "directory snapshots containing symbolic links are not supported " &
          "on Windows: " & path)
      else:
        entries.add(DirectorySnapshotEntry(
          kind: dsekSymlink,
          relativePath: relative,
          permissions: {},
          sourcePath: path,
          symlinkTarget: expandSymlink(path)))

proc directorySnapshotPayload*(root: string): seq[byte] =
  ## Encode a directory output as one deterministic CAS payload. Traversal
  ## never follows symbolic links; sorted relative paths make identical trees
  ## produce identical blobs regardless of filesystem enumeration order.
  if symlinkExists(extendedPath(root)) or not dirExists(extendedPath(root)):
    raise newException(CacheIntegrityError,
      "directory snapshot root is not a direct directory: " & root)
  var entries: seq[DirectorySnapshotEntry] = @[]
  collectDirectorySnapshotEntries(root, root, entries)
  entries.sort(proc(a, b: DirectorySnapshotEntry): int =
    cmp(a.relativePath, b.relativePath))
  if uint64(entries.len) > uint64(MaxDirectorySnapshotEntries):
    raise newException(CacheIntegrityError,
      "directory snapshot has too many entries: " & $entries.len)

  for ch in DirectorySnapshotMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(DirectorySnapshotVersion)
  result.writeU32Le(uint32(entries.len))
  for entry in entries:
    result.add(byte(ord(entry.kind)))
    result.writeString(entry.relativePath)
    result.writePermissions(entry.permissions)
    case entry.kind
    of dsekDirectory:
      discard
    of dsekRegularFile:
      let content = bytes(readFile(extendedPath(entry.sourcePath)))
      result.writeU64Le(uint64(content.len))
      result.add(content)
    of dsekSymlink:
      result.writeString(entry.symlinkTarget)

proc validSnapshotRelativePath(path: string): bool =
  if path.len == 0 or path.len > MaxDirectorySnapshotPathBytes or
      path.startsWith("/") or '\\' in path:
    return false
  when defined(windows):
    if ':' in path:
      return false
  for component in path.split('/'):
    if component.len == 0 or component == "." or component == "..":
      return false
  true

proc decodeDirectorySnapshot(payload: openArray[byte]):
    seq[DecodedDirectorySnapshotEntry] =
  var pos = 0
  for expected in DirectorySnapshotMagic:
    if readByte(payload, pos) != byte(ord(expected)):
      raise newException(CacheIntegrityError,
        "invalid directory snapshot magic")
  if readU16Le(payload, pos) != DirectorySnapshotVersion:
    raise newException(CacheIntegrityError,
      "unsupported directory snapshot version")
  let entryCount = readU32Le(payload, pos)
  if entryCount > MaxDirectorySnapshotEntries:
    raise newException(CacheIntegrityError,
      "directory snapshot has too many entries: " & $entryCount)

  var seen = initHashSet[string]()
  var symlinks = initHashSet[string]()
  var previous = ""
  for _ in 0 ..< int(entryCount):
    let rawKind = readByte(payload, pos)
    if rawKind > byte(ord(dsekSymlink)):
      raise newException(CacheIntegrityError,
        "invalid directory snapshot entry kind")
    var entry = DecodedDirectorySnapshotEntry(
      kind: DirectorySnapshotEntryKind(rawKind),
      relativePath: readString(payload, pos))
    if not validSnapshotRelativePath(entry.relativePath):
      raise newException(CacheIntegrityError,
        "invalid directory snapshot path: " & entry.relativePath)
    if entry.relativePath in seen or
        (previous.len > 0 and cmp(previous, entry.relativePath) >= 0):
      raise newException(CacheIntegrityError,
        "directory snapshot paths are duplicated or unsorted: " &
        entry.relativePath)
    var ancestor = ""
    let components = entry.relativePath.split('/')
    for i in 0 ..< components.len - 1:
      if ancestor.len > 0:
        ancestor.add('/')
      ancestor.add(components[i])
      if ancestor in symlinks:
        raise newException(CacheIntegrityError,
          "directory snapshot entry descends through a symbolic link: " &
          entry.relativePath)
    seen.incl(entry.relativePath)
    previous = entry.relativePath
    entry.permissions = readPermissions(payload, pos)
    case entry.kind
    of dsekDirectory:
      discard
    of dsekRegularFile:
      let contentLength = readU64Le(payload, pos)
      if contentLength > uint64(high(int)) or
          contentLength > uint64(payload.len - pos):
        raise newException(CacheIntegrityError,
          "truncated directory snapshot file: " & entry.relativePath)
      entry.contentStart = pos
      entry.contentLength = int(contentLength)
      pos += entry.contentLength
    of dsekSymlink:
      when defined(windows):
        raise newException(CacheIntegrityError,
          "directory snapshot symbolic links cannot be restored on Windows")
      else:
        entry.symlinkTarget = readString(payload, pos)
        if '\x00' in entry.symlinkTarget:
          raise newException(CacheIntegrityError,
            "directory snapshot symbolic link target contains NUL")
        symlinks.incl(entry.relativePath)
    result.add(entry)
  if pos != payload.len:
    raise newException(CacheIntegrityError,
      "directory snapshot has trailing bytes")

proc materialPathExists(path: string): bool =
  symlinkExists(extendedPath(path)) or fileExists(extendedPath(path)) or
    dirExists(extendedPath(path))

proc removeMaterialPath(path: string) =
  if symlinkExists(extendedPath(path)) or fileExists(extendedPath(path)):
    removeFile(extendedPath(path))
  elif dirExists(extendedPath(path)):
    removeDir(extendedPath(path))

proc moveMaterialPath(source, destination: string) =
  if symlinkExists(extendedPath(source)) or fileExists(extendedPath(source)):
    moveFile(extendedPath(source), extendedPath(destination))
  else:
    moveDir(extendedPath(source), extendedPath(destination))

proc materializeDirectorySnapshotPayload*(payload: openArray[byte];
                                          destination: string;
                                          rootPermissions:
                                            set[FilePermission] = {}) =
  ## Restore a validated directory snapshot through a sibling staging tree,
  ## then rename it into place. A malformed payload never touches the current
  ## destination, and a failed final rename rolls the previous tree back.
  let entries = decodeDirectorySnapshot(payload)
  let now = getTime()
  let nonce = $getCurrentProcessId() & "." & $now.toUnix & "." &
    $now.nanosecond
  let stage = destination & ".reprotmp." & nonce
  let backup = destination & ".reprobackup." & nonce
  createDir(extendedPath(parentDir(destination)))
  if stage.materialPathExists():
    removeMaterialPath(stage)
  createDir(extendedPath(stage))
  var staged = true
  try:
    var directories: seq[tuple[path: string,
      permissions: set[FilePermission]]] = @[]
    for entry in entries:
      let target = stage / entry.relativePath.replace('/', DirSep)
      case entry.kind
      of dsekDirectory:
        createDir(extendedPath(target))
        directories.add((path: target, permissions: entry.permissions))
      of dsekRegularFile:
        createDir(extendedPath(parentDir(target)))
        let last = entry.contentStart + entry.contentLength - 1
        let content =
          if entry.contentLength == 0: ""
          else: byteString(payload.toOpenArray(entry.contentStart, last))
        writeFile(extendedPath(target), content)
        when not defined(windows):
          setFilePermissions(extendedPath(target), entry.permissions)
      of dsekSymlink:
        createDir(extendedPath(parentDir(target)))
        createSymlink(entry.symlinkTarget, extendedPath(target))
    when not defined(windows):
      for i in countdown(directories.high, 0):
        setFilePermissions(extendedPath(directories[i].path),
          directories[i].permissions)
      setFilePermissions(extendedPath(stage), rootPermissions)

    var backedUp = false
    if destination.materialPathExists():
      if backup.materialPathExists():
        removeMaterialPath(backup)
      moveMaterialPath(destination, backup)
      backedUp = true
    try:
      moveDir(extendedPath(stage), extendedPath(destination))
      staged = false
    except CatchableError:
      if backedUp and not destination.materialPathExists():
        moveMaterialPath(backup, destination)
        backedUp = false
      raise
    if backedUp:
      removeMaterialPath(backup)
  finally:
    if staged and stage.materialPathExists():
      try:
        removeMaterialPath(stage)
      except OSError:
        discard

proc writeFingerprint(outp: var seq[byte]; fp: FileFingerprint) =
  outp.writeString(fp.path)
  outp.add(byte(ord(fp.policy)))
  outp.writeMetadata(fp.metadata)
  outp.add(if fp.hasLocalHash: 1'u8 else: 0'u8)
  if fp.hasLocalHash:
    outp.writeLocalHash(fp.localHash)

proc readFingerprint(data: openArray[byte]; pos: var int): FileFingerprint =
  result.path = readString(data, pos)
  let policy = readByte(data, pos)
  if policy > byte(ord(ffpHybrid)):
    raiseEnvelopeError(eeMalformed, "invalid fingerprint policy")
  result.policy = FileFingerprintPolicy(policy)
  result.metadata = readMetadata(data, pos)
  case readByte(data, pos)
  of 0:
    result.hasLocalHash = false
  of 1:
    result.hasLocalHash = true
    result.localHash = readLocalHash(data, pos)
  else:
    raiseEnvelopeError(eeMalformed, "invalid local hash presence flag")

proc digestKey(digest: ContentDigest): string =
  $ord(digest.algorithm) & ":" & $ord(digest.domain) & ":" & toHex(digest.bytes)

proc digestFileName(digest: ContentDigest): string =
  $ord(digest.algorithm) & "-" & $ord(digest.domain) & "-" &
    toHex(digest.bytes) & ".rbar"

proc perEdgeDirName(weak: ContentDigest): string =
  ## Name of the per-edge DIRECTORY for `weak` inside `hot-records/`. The
  ## directory holds one `<nonce>.rec` file per observed path-set (AC-1b).
  digestFileName(weak)

proc recFileNameForStrong(strong: ContentDigest): string =
  ## Nonce for a path-set's `.rec` file, derived from its STRONG fingerprint
  ## so identical path-sets converge on the SAME filename (an atomic overwrite,
  ## never an accumulation) while distinct path-sets get distinct files that
  ## never clobber each other.
  toHex(strong.bytes) & PerEdgeRecFileExt

proc perEdgeRecordFileName*(weak: ContentDigest): string =
  ## Name of the per-edge record DIRECTORY for `weak` inside the cache's
  ## `hot-records/` directory. Exposed so callers (GC/retention, tooling,
  ## tests) can locate an individual edge's store without duplicating the
  ## naming scheme. (AC-1b: this is now a directory of `<nonce>.rec` files,
  ## not a single file.)
  perEdgeDirName(weak)

when defined(windows):
  # Minimal binding to GetFileAttributesExW so fingerprintMetadata can collect
  # kind+size+mtime in ONE syscall. The stdlib path (fileExists + dirExists +
  # getFileInfo) was three calls -- two GetFileAttributesW plus a much heavier
  # CreateFile/GetFileInformationByHandle/CloseHandle round trip -- and noop
  # cache hits stat hundreds of inputs/outputs per build.
  type
    Win32FileAttributeData = object
      dwFileAttributes: int32
      ftCreationTime: FILETIME
      ftLastAccessTime: FILETIME
      ftLastWriteTime: FILETIME
      nFileSizeHigh: int32
      nFileSizeLow: int32

  proc getFileAttributesExW(lpFileName: WideCString;
                            fInfoLevelId: int32;
                            lpFileInformation: pointer): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "GetFileAttributesExW",
    sideEffect.}

  const
    GetFileExInfoStandard = 0'i32
    FileTimeEpochDiff100Ns = 116_444_736_000_000_000'i64

proc fingerprintMetadata(path: string): FileMetadata =
  let fsPath = extendedPath(path)
  when defined(posix):
    # ONE `lstat(2)` answers kind, size and mtime together.
    #
    # This branch used to be `when defined(linux)`, and every other POSIX host
    # -- macOS above all -- fell through to the generic branch below, which
    # asks the same kernel the same question three times: `fileExists`, then
    # `dirExists`, then `getFileInfo`. Measured on a warm no-op of the zlib
    # CMake project, 4,359 calls cost 37.3 ms, of which the two existence
    # probes were 36.4 ms and the `getFileInfo` that actually produces the
    # answer was 0.67 ms. The probes dominate because 3,928 of the 4,363
    # recorded inputs DO NOT EXIST -- they are linker and CMake library-search
    # paths -- so the common case paid a failed `stat` for `fileExists` AND a
    # failed `stat` for `dirExists` before concluding nothing, and a negative
    # path lookup costs roughly twice a positive one.
    #
    # The two branches did not agree on every entity, and widening this one
    # settles the disagreement in its favour. Both divergences are argued at
    # the arm that causes them and pinned by
    # `t_fingerprint_metadata_classifies_every_posix_entity`.
    var stat: Stat
    if lstat(fsPath.cstring, stat) != 0:
      return FileMetadata(kind: ffkMissing)
    result.kind =
      if S_ISREG(stat.st_mode):
        ffkRegular
      elif S_ISDIR(stat.st_mode):
        ffkDirectory
      elif S_ISLNK(stat.st_mode):
        # A symlink is classified by what it points AT while carrying the
        # LINK's own size and mtime -- Incremental-Invalidation.md §"Symlink
        # outputs": "A symlink to a file is classified as a regular file
        # carrying the *link's own* size and mtime". A DANGLING symlink has no
        # target to classify by and lands on `ffkRegular`, which is the only
        # honest answer a four-kind format has for it: the entity exists,
        # `lstat` describes it, and its own size (the length of the target
        # string) and mtime are recorded facts that MOVE when the link is
        # retargeted.
        #
        # The generic branch answered `ffkMissing` here, because `fileExists`
        # follows the link and fails. That is not a cheaper spelling of this
        # rule, it is a different rule, and the two have opposite holes.
        # `ffkMissing` records 0/0, so retargeting a dangling link at another
        # absent target is invisible to it; and on the OUTPUT side
        # `outputStateMismatchImpl` SKIPS EVERY CHECK for an output recorded
        # `ffkMissing`, so a dangling symlink output was recorded as
        # unverifiable and then never verified. `ffkRegular` keeps the retarget
        # signal and the whole output check set, `linkTarget` witness included.
        #
        # What `ffkRegular` cannot see, and `ffkMissing` could: the link's
        # target APPEARING. `lstat` of the link is byte-identical before and
        # after, so that transition stops invalidating. It never invalidated on
        # Linux either. Closing it needs a recorded link target for INPUTS --
        # Incremental-Invalidation.md already requires one for outputs
        # (`OutputWitness.linkTarget`) and `FileFingerprint` has no equivalent
        # field -- so it is a record-format question, not a syscall-count one.
        try:
          let info = getFileInfo(fsPath, followSymlink = false)
          case info.kind
          of pcFile, pcLinkToFile:
            ffkRegular
          of pcDir, pcLinkToDir:
            ffkDirectory
        except OSError:
          ffkMissing
      else:
        # FIFOs, sockets, devices. `isRecordableInput` drops `ffkOther`
        # entirely, which is the point: a socket has no meaningful size or
        # mtime, so recording one as a comparable input asserts something that
        # is not true. The generic branch called these `ffkMissing` --
        # `fileExists` is false for a FIFO -- and so recorded a path that
        # exists as an absent-path probe.
        ffkOther
    result.sizeBytes =
      if stat.st_size < 0: 0'u64 else: uint64(stat.st_size)
    result.mtimeNs = uint64(cast[int64](stat.st_mtim.tv_sec)) *
      1_000_000_000'u64 + uint64(stat.st_mtim.tv_nsec)
  elif defined(windows):
    var data: Win32FileAttributeData
    let wide = newWideCString(fsPath)
    if getFileAttributesExW(wide, GetFileExInfoStandard, addr data) == 0:
      return FileMetadata(kind: ffkMissing)
    if (data.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) != 0:
      result.kind = ffkDirectory
    else:
      result.kind = ffkRegular
      result.sizeBytes = (uint64(cast[uint32](data.nFileSizeHigh)) shl 32) or
        uint64(cast[uint32](data.nFileSizeLow))
      # FILETIME is 100-ns ticks since 1601-01-01 UTC; convert to ns since
      # the Unix epoch so the value matches what the Linux stat path emits.
      let ft100Ns = (int64(cast[uint32](data.ftLastWriteTime.dwHighDateTime)) shl 32) or
        int64(cast[uint32](data.ftLastWriteTime.dwLowDateTime))
      let unixNs100 = ft100Ns - FileTimeEpochDiff100Ns
      if unixNs100 > 0:
        result.mtimeNs = uint64(unixNs100) * 100'u64
  else:
    # Stdlib-only fallback for a host that is neither POSIX nor Windows. No
    # such host is supported today; this exists so the module still compiles
    # for one. Three syscalls where the branches above need one, and it cannot
    # tell a dangling symlink or a FIFO apart from an absent path -- see the
    # POSIX branch for why that matters. Do not route a platform back onto it.
    if not fileExists(fsPath) and not dirExists(fsPath):
      return FileMetadata(kind: ffkMissing)
    let info = getFileInfo(fsPath, followSymlink = false)
    result.kind =
      case info.kind
      of pcFile, pcLinkToFile:
        ffkRegular
      of pcDir, pcLinkToDir:
        ffkDirectory
    result.sizeBytes = uint64(max(info.size, 0))
    let mtime = info.lastWriteTime
    result.mtimeNs = uint64(mtime.toUnix) * 1_000_000_000'u64 +
      uint64(mtime.nanosecond)
  if result.kind == ffkDirectory:
    # Existing-directory probes depend on the fact that a directory exists,
    # not on the physical directory inode mtime. Directory enumeration needs a
    # membership fingerprint; the transitional monitor path stores those
    # observations as probes, so recording directory mtimes would make actions
    # miss whenever their own output directory is touched.
    result.sizeBytes = 0
    result.mtimeNs = 0

type
  OutputWitness* = object
    ## The evidence about ONE declared output that the recorded
    ## `FileMetadata` cannot carry. See `OutputBlob` for why each field
    ## exists. Collected at record time, compared at lookup time.
    changeTimeNs*: uint64
    linkTarget*: string
    treeDigest*: uint64
    hasTreeDigest*: bool

# Unsynchronized process-global counters. Safe today because the scheduler
# runs single-threaded (it spawns tool subprocesses, never `createThread`);
# they would need atomics or per-thread accumulation if that ever changes.
var
  outputStateCheckCalls = 0
  storeAbsenceSkips = 0
  outputStateCheckNanos = 0'i64
  revalidateDirWalks = 0
  revalidateDirEntries = 0'i64
  recordDirWalks = 0
  recordDirEntries = 0'i64
  casContentDigestCalls = 0
  casContentDigestBytes = 0'i64
  actionRecordDecodes = 0
  actionRecordDecodeBytes = 0'i64
  perEdgeContainerReads = 0
  perEdgeSidecarReads = 0
  # The DURATION half of the three rows above. The counts say how much
  # record content a consultation touched; these say what that cost. Both
  # are needed: a count alone cannot tell an 8 ms term from a 0.4 ms one,
  # and a duration alone is unreadable under ambient load without the count
  # to divide by.
  actionRecordDecodeNanos = 0'i64
  perEdgeContainerReadNanos = 0'i64
  perEdgeSidecarReadNanos = 0'i64
  actionIndexNegativeHits = 0
  actionIndexResolvedHits = 0
  actionIndexUnionFallbacks = 0
  actionIndexUnresolvedRefs = 0
  # The DURATION half of `storeAbsenceSkipStats`, and of the recorded-input
  # revalidation LOOP that encloses every metadata check a consultation
  # makes. Global rather than per-cache because that is the lifetime of the
  # count each sits beside -- see `FileMetadataCacheStats` for the four rows
  # whose durations live in the cache object instead, for exactly the same
  # reason.
  storeAbsenceSkipNanos = 0'i64
  recordedInputRevalidateChecks = 0
  recordedInputRevalidateNanos = 0'i64
  # A SUBSET of `warm revalidate`, split out because the two are not the same
  # kind of work at all: a plain warm revalidation is one `lstat(2)`, while a
  # membership-tracked directory has to be RE-LISTED and digested. Without
  # the split, `warm revalidate` is an average over two populations whose
  # per-item costs differ by two orders of magnitude, and the average
  # describes neither.
  membershipRelists = 0
  membershipRelistNanos = 0'i64
  membershipRelistEntries = 0'i64
  # The interval that ENCLOSES the three MAC-3 record rows. Those three time
  # the `readFile` calls and the decode; this times everything a record load
  # does, including the directory enumeration, the `fileExists` probes and
  # the path building that sit between them. The gap between this and their
  # sum was measured at ~40% of a `readHotRecord` and was previously
  # invisible.
  perEdgeRecordLoads = 0
  perEdgeRecordLoadNanos = 0'i64
  # The DISTRIBUTION, because on this population the average is known to be a
  # lie. "One pathological path can dominate a whole probe population" is a
  # recorded hazard of this campaign -- a single autofs lookup cost 15 ms of
  # an 18 ms loop, and dividing by the count turned that into a plausible
  # ~4 us that produced two wrong estimates. A max and a tail count cost one
  # comparison per check, no extra clock read, and they are what makes the
  # difference between "272 slow checks" and "one slow check" decidable from
  # the stats table.
  slowMetadataProbes = 0
  slowMetadataProbeNanos = 0'i64
  slowestMetadataProbeNanos = 0'i64
  slowestMetadataProbePath = ""

const SlowMetadataProbeNanos = 1_000_000'i64
  ## 1 ms. A metadata probe is a `lstat(2)`; anything at millisecond scale is
  ## not a local filesystem answering and is an actionable fact about the
  ## ENVIRONMENT rather than about the build -- an automount, a network
  ## mount, a sleeping disk. Deliberately far above any plausible local
  ## answer (~1-5 us) so a busy host cannot populate the row.

type
  MetadataProbeClass = enum
    ## Which arm a recorded-input metadata check took. The four non-`mpcNone`
    ## values are one-to-one with the four `repro file metadata *` /
    ## `repro store absence skips` rows, so a duration attributed here lands
    ## beside the count it explains and nowhere else.
    mpcNone
      ## No counter moved: the caller passed no cache, so this check is
      ## outside the population the rows describe.
    mpcCurrentRunHit
    mpcColdStat
    mpcWarmRevalidate
    mpcStoreAbsenceSkip

var
  metadataProbeClass = mpcNone
    ## Set at each counter increment, read by the timing wrapper once the
    ## call returns. A return value would be cleaner and is not available:
    ## these procs have eight exits between them and every one already
    ## returns a `FileMetadata`.
  metadataProbeDepth = 0
    ## Re-entrancy guard. `fingerprintRecordedMetadata` calls
    ## `fingerprintMetadata` for the store-absence exclusion's condition 2,
    ## and timing both would credit those nanoseconds to two classes at once
    ## -- which breaks the one property these rows are worth having: that the
    ## four are DISJOINT and sum to no more than the revalidation loop that
    ## encloses them. Only the outermost call is timed, so the condition-2
    ## probe is charged to the skip that needed it. Its COUNT still moves, so
    ## `current-run hit` counts a few checks whose time is credited to
    ## `store absence skips`; at 1,004 skips over a handful of distinct store
    ## roots that is a handful of calls.
    ##
    ## LOAD-BEARING IN EXACTLY ONE OF THE TWO WRAPPERS, and it is worth
    ## saying which, because the other reads as covered when it is not. The
    ## guard in `fingerprintMetadata`'s wrapper is the one that matters:
    ## deleting it reddens the recorded-input suite, mutation-checked. The
    ## identical guard in `fingerprintRecordedMetadata`'s wrapper is
    ## UNREACHABLE today -- nothing re-enters that proc -- so deleting it
    ## changes no behaviour and no test catches it. It stays for symmetry and
    ## for the day a caller does re-enter; it is not evidence of anything.
  revalidateLoopDepth = 0
    ## Non-zero while a recorded-input revalidation loop is on the stack.
    ## Two jobs: it stops a nested loop from being counted twice, and it is
    ## what tells the metadata wrapper that a check belongs to the
    ## revalidation population rather than to record-time `observeFile`.

template timedPerEdgeRecordLoad(body: untyped) =
  ## Time ONE edge's record load, everything included.
  ##
  ## The three MAC-3 rows time the two `readFile` calls and the decode; this
  ## times the whole load, so `perEdgeRecordLoadNanos` minus their sum is the
  ## directory enumeration, the `fileExists` probes, the path building and
  ## the record copying -- the part of "hot-record read and decode" that the
  ## three rows do NOT cover, and which MAC-3 observed to be ~40% of a
  ## `readHotRecord` without having a row to put it in.
  ##
  ## One pair per edge (~40 per no-op), and `try`/`finally` because both
  ## bodies return from inside a loop.
  let recordLoadStart = getMonoTime()
  inc perEdgeRecordLoads
  try:
    body
  finally:
    perEdgeRecordLoadNanos +=
      (getMonoTime() - recordLoadStart).inNanoseconds

template timedRecordedInputRevalidation(body: untyped) =
  ## Time ONE record's recorded-input loop, machinery included.
  ##
  ## One `getMonoTime` pair per RECORD (~40 per warm no-op), not per input
  ## (~4,659), because at 33-36 ns a pair the per-input version would cost
  ## ~0.16 ms of the very term it is trying to resolve. The per-input timers
  ## that DO exist are the four class rows, and they are inside this
  ## interval, so this reading includes them -- see
  ## `recordedInputRevalidateStats`.
  ##
  ## `try`/`finally` because every one of these loops returns early the
  ## moment an input compares unequal, which is the common case on a MISS
  ## and the case an un-finallied timer would silently drop.
  let revalidationStart = getMonoTime()
  inc revalidateLoopDepth
  try:
    body
  finally:
    dec revalidateLoopDepth
    if revalidateLoopDepth == 0:
      recordedInputRevalidateNanos +=
        (getMonoTime() - revalidationStart).inNanoseconds

proc noteActionRecordDecode(frameBytes: int) =
  ## Count ONE decoded `RBAR` record frame and the bytes it spanned.
  ##
  ## Action-Cache-Per-Edge-Store.md §5.5 C1 states the property this makes
  ## observable: "the cost of a consultation MUST be proportional to the
  ## candidates it evaluates, not to the candidates the edge has". A
  ## consultation that needs the edge's newest record must therefore decode
  ## ONE record, not every record the edge has. That is a claim about work
  ## performed, and a stopwatch cannot demonstrate it on a loaded machine --
  ## the same command measured 351 ms and 108 ms an hour apart. A count can.
  ##
  ## C4 (per-record path interning) lands in the BYTES half of the same pair:
  ## interning does not change how many records a consultation decodes, it
  ## changes how big each one is.
  inc actionRecordDecodes
  actionRecordDecodeBytes += int64(frameBytes)

proc noteCasContentDigest(sizeBytes: uint64) =
  ## Count one pass over an artifact's BYTES.
  ##
  ## Caching-Architecture.md §"Known Limit: The Default Policy Can Serve A
  ## Stale Result" makes the cost model explicit: "metadata comparison costs
  ## one `lstat(2)` per input and scales with input count, while content
  ## verification scales with input bytes. Reprobuild is not willing to pay
  ## that on every consultation by default." That sentence is only
  ## enforceable if the byte-scaled work is
  ## countable, so every CAS content digest in this module is funnelled
  ## through here. A warm no-op consultation of a metadata-only record must
  ## leave this counter at zero; see
  ## `t_warm_noop_consultation_hashes_no_bytes.nim`.
  inc casContentDigestCalls
  casContentDigestBytes += int64(sizeBytes)

proc symlinkTargetOf(path: string): string =
  ## `readlink()` or "" when `path` is not a symlink. Never follows.
  when defined(posix):
    var st: Stat
    if lstat(extendedPath(path).cstring, st) == 0 and S_ISLNK(st.st_mode):
      try:
        return expandSymlink(extendedPath(path))
      except OSError:
        return ""
  ""

proc directoryMetadataDigest(root: string; entriesWalked: var int64): uint64 =
  ## Order-independent digest over the recursive metadata of `root`.
  ##
  ## Entries are folded in with a commutative accumulator (wrapping sum)
  ## rather than a sorted hash, so no O(n log n) sort of path strings is
  ## needed for what can be a very large tree. Order independence also means
  ## the result does not depend on `walkDirRec`'s traversal order, which is
  ## filesystem-defined. This is LOCAL INVALIDATION evidence, in the sense of
  ## Incremental-Invalidation.md §"Hash-function strategy": it must be fast
  ## and reliable against honest workloads, not collision-resistant against
  ## an adversary. It never crosses a machine boundary.
  ##
  ## Cost is one `lstat(2)` and one small hash per entry. The per-entry
  ## payload is packed as raw little-endian bytes rather than formatted
  ## text: decimal formatting of five integers per entry measured ~3x the
  ## cost of the syscall it was describing.
  var entries = 0'u64
  var scratch = newSeq[byte](0)
  for entry in walkDirRec(extendedPath(root),
      yieldFilter = {pcFile, pcLinkToFile, pcDir, pcLinkToDir},
      relative = true):
    inc entries
    let full = root / entry
    scratch.setLen(0)
    for c in entry:
      scratch.add(byte(c))
    when defined(posix):
      var st: Stat
      if lstat(extendedPath(full).cstring, st) == 0:
        scratch.writeU64Le(uint64(st.st_mode))
        scratch.writeU64Le(if st.st_size < 0: 0'u64 else: uint64(st.st_size))
        scratch.writeU64Le(uint64(cast[int64](st.st_mtim.tv_sec)) *
          1_000_000_000'u64 + uint64(st.st_mtim.tv_nsec))
        scratch.writeU64Le(uint64(cast[int64](st.st_ctim.tv_sec)) *
          1_000_000_000'u64 + uint64(st.st_ctim.tv_nsec))
        if S_ISLNK(st.st_mode):
          for c in symlinkTargetOf(full):
            scratch.add(byte(c))
    else:
      let m = fingerprintMetadata(full)
      scratch.writeU64Le(uint64(ord(m.kind)))
      scratch.writeU64Le(m.sizeBytes)
      scratch.writeU64Le(m.mtimeNs)
    result = result + localHash(scratch).value
  # Fold the count in so that an empty tree and a missing tree differ, and so
  # that a pair of entries cannot cancel out.
  entriesWalked = int64(entries)
  result = result xor (entries * 0x9E3779B97F4A7C15'u64)

const
  DirectoryMembershipUnlistable* = 0xFFFFFFFFFFFFFFFF'u64
    ## Recorded in place of a membership digest when the directory exists
    ## but could not be enumerated. Distinct from 0 ("not tracked") and from
    ## every real listing, so "was empty, now unreadable" and "was
    ## unreadable, now listable" both compare unequal and re-execute.
  DirectoryMembershipDigestCollisionEscape = 0xD1B54A32D192ED03'u64
    ## Substituted when a real listing happens to hash to one of the two
    ## reserved values.

proc directoryMembershipDigest*(root: string; entriesWalked: var int64): uint64 =
  ## Order-independent digest over the IMMEDIATE children of `root` -- their
  ## names and kinds, one `readdir` sweep, no per-entry `lstat`.
  ##
  ## Deliberately SHALLOW, and deliberately not `directoryMetadataDigest`.
  ## The question a recorded directory ENUMERATION has to answer is the one
  ## in Incremental-Invalidation.md §"Validation Criteria" -- "adding or
  ## removing a file in an enumerated directory invalidates the action" --
  ## and that is a statement about the entries the action's `readdir`
  ## returned. It is not a statement about the contents of those entries: a
  ## file the action went on to READ is recorded as its own input with its
  ## own fingerprint, and a subdirectory the action went on to enumerate is
  ## recorded as its own enumeration. Recursing here would re-derive that
  ## information at a cost proportional to the whole subtree.
  ##
  ## The cost difference is not academic. Measured on this repository, the
  ## directories a real test edge enumerates that still exist at record time
  ## are ~50, and are almost entirely `/nix/store/<pkg>/lib/` -- small and
  ## immutable. But an edge's recorded PROBES include `/home/<user>/<work>`
  ## and the repo root, and a recursive digest of those would walk the whole
  ## multi-repo workspace on every warm consultation. Shallow keeps the
  ## sweep proportional to what was actually read.
  ##
  ## Same accumulator rationale as `directoryMetadataDigest`: a commutative
  ## sum, so no sort of path strings, and no dependence on `walkDir`'s
  ## filesystem-defined order. LOCAL INVALIDATION evidence only -- fast and
  ## reliable against honest workloads, never collision-resistant against an
  ## adversary, never crossing a machine boundary.
  ## `checkDir = true` is load-bearing. At Nim's default of `false` an
  ## `opendir` failure yields ZERO entries and raises NOTHING, so an
  ## unlistable directory produced a digest bit-identical to an empty one
  ## (measured: both 15111065706836454659, entries=0). That fails OPEN in
  ## two ways -- a directory recorded while empty and later unlistable but
  ## non-empty is a false hit, and a record written under a transient
  ## EMFILE claims the directory is empty forever. The OUTPUT side already
  ## fails closed for the analogous case (see the `hasTreeDigest` branch in
  ## `outputStateMismatchImpl`); this now does too, by raising here and
  ## letting `fingerprintDirectoryMembership` substitute
  ## `DirectoryMembershipUnlistable`.
  var entries = 0'u64
  var scratch = newSeq[byte](0)
  for kind, path in walkDir(extendedPath(root), relative = true,
      checkDir = true):
    inc entries
    scratch.setLen(0)
    for c in path:
      scratch.add(byte(c))
    scratch.writeU64Le(uint64(ord(kind)))
    result = result + localHash(scratch).value
  entriesWalked = int64(entries)
  # Fold the count in so an empty directory and a missing one differ, and so
  # a pair of entries cannot cancel out.
  result = result xor (entries * 0x9E3779B97F4A7C15'u64)
  # Two values are reserved and must never be produced by a real listing: 0
  # means "not membership-tracked" (`membershipTrackedDirectory`), and
  # `DirectoryMembershipUnlistable` means "could not be listed".
  if result == 0'u64 or result == DirectoryMembershipUnlistable:
    result = DirectoryMembershipDigestCollisionEscape

proc membershipTrackedDirectory*(metadata: FileMetadata): bool {.inline.} =
  ## Is this recorded input a directory whose MEMBERSHIP was fingerprinted?
  ##
  ## Self-describing, and that is the point: `fingerprintMetadata` forces
  ## `mtimeNs` to 0 for every `ffkDirectory`, so a non-zero `mtimeNs` on a
  ## directory cannot arise any other way and needs no new record field. The
  ## record format is unchanged -- Incremental-Invalidation.md §"Storage
  ## Format" is explicit that adding evidence must not change the schema,
  ## because a cache root is shared between whatever `repro` binaries a user
  ## has installed.
  ##
  ## CROSS-BINARY BEHAVIOUR IS NOT SYMMETRIC, and the asymmetric direction
  ## is a false hit. Do not restate this as "a miss in both directions"; it
  ## was written that way once and it was wrong.
  ##
  ## * OLD reader, NEW record: the reader recomputes 0 for a directory this
  ##   writer recorded with a digest, sees a mismatch, and re-executes. A
  ##   miss. Self-correcting.
  ## * NEW reader, OLD record (or any record written before this change):
  ##   the recorded `mtimeNs` is 0, so `membershipTrackedDirectory` is
  ##   FALSE, so the directory is never re-listed and the comparison is
  ##   existence-only -- exactly the pre-fix behaviour. And because the hit
  ##   path does not re-record, the record is never upgraded. A directory
  ##   enumerated by an edge whose record predates this change is therefore
  ##   a PERMANENT false hit for that record. Measured.
  ##
  ## The remedy is to discard records written before this change: delete the
  ## action-cache root, or let retention evict them. Every record written
  ## from here on carries membership from its first execution.
  ##
  ## WHY NOT FORCE THE UPGRADE, given that `outputStateMismatchImpl` sets
  ## exactly that precedent for directory OUTPUTS ("directory output has no
  ## recorded tree digest" -> fail closed -> re-execute once)? Two reasons,
  ## both checked rather than assumed:
  ##
  ## 1. On the output side the record names its declared outputs, so "a
  ##    directory output with no witness" is unambiguous. On the INPUT side
  ##    a directory with no membership digest is indistinguishable from a
  ##    directory that was correctly only PROBED -- and probe-only
  ##    directories are the common case, measured at 4 of 5 directory inputs
  ##    on a small edge and 285-of-338-tracked-plus-hundreds-probed on a
  ##    real one. Failing closed on them would make every monitored edge a
  ##    permanent miss, which is the whole regression this work exists to
  ##    remove.
  ## 2. The other way to discriminate is the record version, and that door
  ##    is already closed with reasons: see the comment on
  ##    `ActionRecordVersion` above. A v4 frame makes `loadPerEdgeRecords`
  ##    return ZERO records for any older `repro` sharing the per-user cache
  ##    root, and makes the public `decodeActionResultRecord` raise. That
  ##    was judged not worth an 8-byte field; it is not worth this either.
  ##
  ## Closing it properly needs a discriminator that identifies the WRITER
  ## rather than the per-input evidence, in a shape older readers ignore --
  ## the sidecar route Incremental-Invalidation.md §"Storage Format"
  ## prescribes for exactly this. That is follow-up work, not a comment.
  metadata.kind == ffkDirectory and metadata.mtimeNs != 0'u64

proc isImmutablePackageStoreRoot*(path: string): bool =
  ## Is this the ROOT of a content-addressed package store?
  ##
  ## THIS IS A DELIBERATE HOLE, NOT A PROOF THAT THERE IS NO HOLE. Read the
  ## whole comment before touching it; an earlier version of it claimed the
  ## exemption was correctness-neutral and that claim is false.
  ##
  ## COST -- the reason the exemption exists, and it is decisive.
  ## `/nix/store` here holds 376,169 immediate children. One sweep costs
  ## 1.14-1.16 s, which by itself exceeds the entire 0.82 s fast-noop scan
  ## over all 338 membership-tracked directories of a real edge. Worse, its
  ## membership changes whenever anything on the machine builds or
  ## garbage-collects, so it churns essentially every run. Measured with the
  ## root tracked: two consecutive warm passes of an edge that had listed it
  ## took 463 s and 543 s where the steady state is ~5 s. Tracking it does
  ## not slow the warm path down, it abolishes it.
  ##
  ## WHAT IT COSTS IN CORRECTNESS, stated plainly because it is real. An
  ## edge whose behaviour depends on the store's MEMBERSHIP -- `ls
  ## /nix/store | wc -l`, or any scan for a package by name -- is silently
  ## reused when that membership changes. Demonstrated: an edge counting
  ## store entries records `/nix/store` with `tracked = false` and is reused
  ## across a change in the count. Code in this repository has that shape:
  ## `repro_interface_artifacts.nim` walks the store for `nixPrefix` /
  ## `nixLibDir` (~:3616-3690), and `autotools_package.nim:388` /
  ## `cmake_package.nim:36` do the same. Those recipes are OUT OF SCOPE of
  ## the enumerated-directory guarantee until there is a cheaper mechanism
  ## -- a store generation marker (one stat of a counter the package manager
  ## bumps) rather than a 376k-entry readdir. Do not describe this as safe.
  ##
  ## The individual package directories INSIDE the store stay tracked: 53 of
  ## the 338 on the measured edge. They are small, and being store paths
  ## they are immutable, so they cost one cheap readdir each and never
  ## churn.
  ## NOT configurable from the environment, and that was a real hole rather
  ## than a hypothetical one. This runs in the ENGINE process at fingerprint
  ## time, so honouring `NIX_STORE_DIR` let any ambient value nominate a
  ## directory as exempt: measured, `NIX_STORE_DIR` pointed at a directory
  ## the edge enumerated stopped a newly added file from re-running it, and
  ## CLEARING the variable did not recover, because the record had been
  ## written with `mtimeNs = 0` and a 0 is never re-listed. A transient env
  ## var permanently poisoned the record. If the store location ever needs
  ## to vary it must arrive through something the engine controls -- a
  ## config field on `BuildEngineConfig`, threaded to this call -- never
  ## through `getEnv` here.
  ##
  ## The match is normalized-string equality on a trailing-slash-stripped
  ## path. `//nix/store`, `/nix/./store`, `/NIX/STORE` and symlink aliases
  ## are therefore NOT exempt. That is a performance cliff, not a
  ## correctness one -- an unexempted store root is membership-tracked,
  ## which is the conservative direction -- but it is worth knowing that the
  ## monitor demonstrably emits both `/nix/store` and `/nix/store/` as
  ## separate inputs, so both spellings are handled by the strip.
  let normalized = path.replace('\\', '/').strip(leading = false,
    trailing = true, chars = {'/'})
  if normalized.len == 0:
    return false
  normalized == "/nix/store"

proc immutableStoreOutputPath*(path: string): string =
  ## The package-store OUTPUT PATH that `path` lies STRICTLY INSIDE, or `""`
  ## when it lies inside none.
  ##
  ## `isImmutablePackageStoreRoot` answers a different question -- "is this
  ## the store root itself" -- and the two must not be conflated, because
  ## their guarantees point in opposite directions. The store root is
  ## CONSTANTLY written: every new package appears as a fresh entry directly
  ## inside it. An individual output path, once published, never gains an
  ## entry.
  ##
  ## STRICTLY INSIDE is the load-bearing word, and dropping it would be
  ## unsound. `/nix/store/<entry>` -- the output path itself -- CAN come into
  ## existence, because that is precisely what building or substituting the
  ## package does. Only a path with at least one component BELOW an output
  ## path is covered by the never-gains-an-entry guarantee, so this returns
  ## `""` for the store root, for a bare output path, and for anything
  ## outside the store.
  ##
  ## NOT CONFIGURABLE FROM THE ENVIRONMENT, for the reason recorded on
  ## `isImmutablePackageStoreRoot`: honouring an ambient `NIX_STORE_DIR` here
  ## once let a transient value nominate an arbitrary directory as exempt and
  ## PERMANENTLY poisoned the records written while it was set. The prefix
  ## stays a constant; if the store location ever has to vary it must arrive
  ## through a config field the engine controls.
  ##
  ## The same normalization cliff applies as there: `//nix/store/...` and
  ## `/nix/./store/...` are not recognised. That is a performance cliff and
  ## never a correctness one -- an unrecognised path is probed as before.
  const prefix = "/nix/store/"
  let normalized = path.replace('\\', '/')
  if not normalized.startsWith(prefix):
    return ""
  let relative = normalized[prefix.len .. ^1]
  let slash = relative.find('/')
  if slash <= 0:
    # Either the store root with a trailing slash, or a bare output path
    # with nothing below it. Neither is covered.
    return ""
  prefix & relative[0 ..< slash]

proc storeAbsenceSkipStats*(): int =
  ## Recorded-input checks answered WITHOUT a syscall because the input was
  ## absent inside a published store output path.
  ##
  ## This is the population the exclusion removes from `fs probe`. Reading it
  ## beside `absent first touches` is how the mechanism is confirmed: the two
  ## should move in opposite directions by the same amount, and a change that
  ## reduced probes without this rising did so some other way.
  ##
  ## Reset by `resetOutputStateCheckStats`, so a reading after a build
  ## describes THAT build.
  storeAbsenceSkips

var lastMembershipWalkEntries = 0'i64
  ## How many directory entries the LAST `fingerprintDirectoryMembership`
  ## walked. Read by the recorded-input path, which is the only caller that
  ## attributes the walk to revalidation; `observeEnumeratedDirectory` walks
  ## the same trees at RECORD time and must not be counted there, exactly as
  ## `recordDirWalks` is kept apart from `revalidateDirWalks`.

proc fingerprintDirectoryMembership*(path: string): FileMetadata =
  ## `fingerprintMetadata` plus the membership digest, for a path the action
  ## ENUMERATED. Returns the plain existence fingerprint when the path is no
  ## longer a directory -- an action that created, listed and then deleted a
  ## scratch directory records it as `ffkMissing` and keeps comparing as
  ## "still missing", which is what stops per-run temporary directories from
  ## making every such edge a permanent miss.
  lastMembershipWalkEntries = 0
  result = fingerprintMetadata(path)
  if result.kind != ffkDirectory:
    return
  if path.isImmutablePackageStoreRoot():
    return
  try:
    var walked = 0'i64
    result.mtimeNs = directoryMembershipDigest(path, walked)
    lastMembershipWalkEntries = walked
  except OSError, IOError:
    # The directory exists but could not be listed. Leaving `mtimeNs` at 0
    # would mean "not membership-tracked", i.e. existence-only, i.e. a false
    # hit the moment it becomes listable again with different contents.
    # Record the fact instead, so a later successful listing compares
    # unequal and re-executes -- Incremental-Invalidation.md §"Rebuild
    # Decision Model": "If any required condition cannot be checked,
    # Reprobuild MUST fail closed."
    result.mtimeNs = DirectoryMembershipUnlistable

proc observeOutputWitness(path: string; metadata: FileMetadata): OutputWitness =
  ## One `lstat(2)` for the scalar fields, plus a recursive walk only when
  ## the output is a directory.
  when defined(posix):
    var st: Stat
    if lstat(extendedPath(path).cstring, st) == 0:
      result.changeTimeNs = uint64(cast[int64](st.st_ctim.tv_sec)) *
        1_000_000_000'u64 + uint64(st.st_ctim.tv_nsec)
      if S_ISLNK(st.st_mode):
        try:
          result.linkTarget = expandSymlink(extendedPath(path))
        except OSError:
          discard
  if metadata.kind == ffkDirectory:
    try:
      var walked = 0'i64
      result.treeDigest = directoryMetadataDigest(path, walked)
      result.hasTreeDigest = true
      # Attributed to the RECORD phase. Folding it into the revalidation
      # counters made a COLD build report "revalidate dir walks = 1" for work
      # that was not revalidation at all.
      inc recordDirWalks
      recordDirEntries += walked
    except OSError, IOError:
      result.hasTreeDigest = false

proc initFileMetadataCache*(): FileMetadataCache =
  FileMetadataCache(entries: initTable[string, FileMetadata]())

proc clear*(cache: var FileMetadataCache) =
  cache.entries.clear()

proc invalidate*(cache: var FileMetadataCache; path: string) =
  cache.entries.del(path)

proc metadataStats*(cache: FileMetadataCache): FileMetadataCacheStats =
  cache.stats

proc attributeMetadataProbe(cache: ptr FileMetadataCache; path: string;
                            elapsedNanos: int64) =
  ## Credit one timed check to the row for the arm it took.
  ##
  ## The four arms are mutually exclusive by construction -- each is a
  ## distinct `return` path -- so the four accumulators are DISJOINT
  ## sub-intervals of the revalidation loop that called into here, and their
  ## sum can never exceed `recordedInputRevalidateNanos`. That inequality is
  ## what the tests assert; it is the only claim about these numbers that
  ## does not depend on how busy the host is.
  if revalidateLoopDepth > 0:
    inc recordedInputRevalidateChecks
  if elapsedNanos > slowestMetadataProbeNanos:
    slowestMetadataProbeNanos = elapsedNanos
    slowestMetadataProbePath = path
  if elapsedNanos >= SlowMetadataProbeNanos:
    inc slowMetadataProbes
    slowMetadataProbeNanos += elapsedNanos
  case metadataProbeClass
  of mpcNone: discard
  of mpcCurrentRunHit: cache[].stats.currentRunHitNanos += elapsedNanos
  of mpcColdStat: cache[].stats.coldStatNanos += elapsedNanos
  of mpcWarmRevalidate: cache[].stats.warmRevalidateNanos += elapsedNanos
  of mpcStoreAbsenceSkip: storeAbsenceSkipNanos += elapsedNanos

proc fingerprintMetadataImpl(path: string;
                             cache: ptr FileMetadataCache): FileMetadata =
  if cache.isNil:
    metadataProbeClass = mpcNone
    return fingerprintMetadata(path)
  if cache[].entries.hasKey(path):
    inc cache[].stats.currentRunHits
    metadataProbeClass = mpcCurrentRunHit
    return cache[].entries[path]
  let hadWarmEntry = processWarmFileMetadataEntries.hasKey(path)
  let priorMetadata =
    if hadWarmEntry: processWarmFileMetadataEntries[path]
    else: FileMetadata()
  if hadWarmEntry:
    inc cache[].stats.warmEntries
    inc cache[].stats.warmRevalidated
    metadataProbeClass = mpcWarmRevalidate
  else:
    inc cache[].stats.coldStats
    metadataProbeClass = mpcColdStat
  result = fingerprintMetadata(path)
  if hadWarmEntry:
    if result == priorMetadata:
      inc cache[].stats.warmUnchanged
    else:
      inc cache[].stats.warmChanged
  cache[].entries[path] = result
  processWarmFileMetadataEntries[path] = result

proc fingerprintMetadata(path: string;
                         cache: ptr FileMetadataCache): FileMetadata =
  ## Timed wrapper over `fingerprintMetadataImpl`.
  ##
  ## See `FileMetadataCacheStats` for what the timer costs and which row it
  ## is a material fraction of. The nesting guard is `metadataProbeDepth`:
  ## when this is reached from inside `fingerprintRecordedMetadata` the outer
  ## call is already holding the clock, and starting a second one here would
  ## credit the same nanoseconds to two rows.
  if cache.isNil or metadataProbeDepth > 0:
    return fingerprintMetadataImpl(path, cache)
  inc metadataProbeDepth
  let started = getMonoTime()
  try:
    result = fingerprintMetadataImpl(path, cache)
  finally:
    dec metadataProbeDepth
    attributeMetadataProbe(cache, path,
      (getMonoTime() - started).inNanoseconds)

proc fingerprintRecordedMetadataImpl(path: string; recorded: FileMetadata;
                                     cache: ptr FileMetadataCache): FileMetadata =
  # A membership-tracked directory has to be re-listed, not just stat'd, and
  # it must not be served from (or stored into) the plain metadata cache:
  # that cache is keyed on path alone and is shared with call sites that
  # want the existence-only answer for the same directory.
  if recorded.membershipTrackedDirectory():
    if not cache.isNil:
      inc cache[].stats.warmEntries
      inc cache[].stats.warmRevalidated
      metadataProbeClass = mpcWarmRevalidate
    # Timed here as well as by the enclosing wrapper, deliberately: this is a
    # strict sub-interval of the `warm revalidate` reading, not a fifth
    # disjoint class, and the row says so. One pair per re-listed directory,
    # a population in the hundreds at most.
    let relistStart = getMonoTime()
    result = fingerprintDirectoryMembership(path)
    if not cache.isNil:
      inc membershipRelists
      membershipRelistNanos += (getMonoTime() - relistStart).inNanoseconds
      # The load-independent half, and the one that says whether a duration
      # is large because the work is slow or because there is a lot of it.
      membershipRelistEntries += lastMembershipWalkEntries
      if result == recorded:
        inc cache[].stats.warmUnchanged
      else:
        inc cache[].stats.warmChanged
    return
  if cache.isNil:
    metadataProbeClass = mpcNone
    return fingerprintMetadata(path)
  if cache[].entries.hasKey(path):
    inc cache[].stats.currentRunHits
    metadataProbeClass = mpcCurrentRunHit
    return cache[].entries[path]
  # An input that was ABSENT inside a published store output path cannot
  # become present, so re-probing it every build buys nothing. This is the
  # largest single term in a warm no-op: on a zlib build 4,009 of 4,441
  # first touches are absent paths and 98.9% of them are store paths, at
  # ~4.1 us each.
  #
  # WHY THIS IS SOUND, and the two conditions it rests on:
  #
  #   1. The path lies STRICTLY INSIDE an output path. A bare output path
  #      can appear -- see `immutableStoreOutputPath`.
  #   2. That output path EXISTS NOW. If it does not, the package can still
  #      be built or substituted and would bring this path with it, so the
  #      absence is not stable and the probe must happen.
  #
  # Condition 2 costs one probe per distinct output path rather than one per
  # absent input, and it goes through this same cache, so a store root
  # shared by hundreds of probes is stat'd once. Garbage collection does not
  # break it: a collected output path re-materializes with the same contents
  # under the same name, because the name is derived from what produces it.
  #
  # Keyed on the root's CLASS, decided from the path with no syscall. The
  # class-3 residue -- a PATH-resolved linker driver, `nim.cfg` searched up
  # toward the home directory, `nimble.lock`, `config.nims`, other package
  # managers' prefixes, transient parameter files -- is outside the store,
  # so it keeps being probed AND keeps being recorded. That residue is
  # genuine exposure and is exactly what a blanket evidence-scope narrowing
  # would have discarded.
  if recorded.kind == ffkMissing:
    let outputPath = immutableStoreOutputPath(path)
    if outputPath.len > 0 and
        fingerprintMetadata(outputPath, cache).kind != ffkMissing:
      # Deliberately NOT counted as a metadata-cache hit: it is not one, and
      # folding it into `currentRunHits` would hide the skip inside a metric
      # that already moves for other reasons. `storeAbsenceSkips` is the only
      # place this shows up.
      inc storeAbsenceSkips
      # Set AFTER the condition-2 probe above, which sets the class for
      # itself: last write wins, and the outermost arm is the one that
      # decided the outcome.
      metadataProbeClass = mpcStoreAbsenceSkip
      # Cache the answer, or the REPEATS pay for the skip. A warm zlib no-op
      # consults these paths 11,893 times across only ~4,000 distinct paths,
      # and without this insert every repeat re-ran the prefix scan and the
      # root lookup instead of being served by the `currentRunHits` branch
      # above. Measured: the uncached version eliminated 87% of the probes
      # and saved nothing.
      #
      # Sound to insert because it is the current truth, not a guess: the
      # two conditions above establish that this path is absent and cannot
      # become present. Deliberately NOT written to
      # `processWarmFileMetadataEntries`, which records what a run actually
      # OBSERVED; this run observed nothing here.
      cache[].entries[path] = recorded
      return recorded
  inc cache[].stats.warmEntries
  inc cache[].stats.warmRevalidated
  metadataProbeClass = mpcWarmRevalidate
  result = fingerprintMetadata(path)
  if result == recorded:
    inc cache[].stats.warmUnchanged
  else:
    inc cache[].stats.warmChanged
  cache[].entries[path] = result
  processWarmFileMetadataEntries[path] = result

proc fingerprintRecordedMetadata(path: string; recorded: FileMetadata;
                                 cache: ptr FileMetadataCache): FileMetadata =
  ## Timed wrapper over `fingerprintRecordedMetadataImpl`.
  ##
  ## This is THE recorded-input check: one call per input a cache
  ## consultation revalidates, ~4,659 of them on a warm zlib CMake no-op. The
  ## four counts it moves used to render a literal `0.0` in the stats table's
  ## total column, which reads as "measured, and free" when what it meant was
  ## "never measured" -- and an estimate of ~18 ms was carried against that
  ## silence for two milestones because nothing in the table could contradict
  ## it. See `FileMetadataCacheStats` for the timer's own cost and for which
  ## of the four rows it is a material fraction of.
  if cache.isNil or metadataProbeDepth > 0:
    return fingerprintRecordedMetadataImpl(path, recorded, cache)
  inc metadataProbeDepth
  let started = getMonoTime()
  try:
    result = fingerprintRecordedMetadataImpl(path, recorded, cache)
  finally:
    dec metadataProbeDepth
    attributeMetadataProbe(cache, path,
      (getMonoTime() - started).inNanoseconds)

proc fileBytesForHash(path: string; metadata: FileMetadata): seq[byte] =
  if metadata.kind != ffkRegular:
    return @[]
  bytes(readFile(extendedPath(path)))

proc isDirectRegularFile(path: string): bool =
  when defined(linux):
    var stat: Stat
    lstat(extendedPath(path).cstring, stat) == 0 and S_ISREG(stat.st_mode)
  else:
    let info = getFileInfo(extendedPath(path), followSymlink = false)
    info.kind == pcFile

proc observeFileWithMetadata(path: string; policy: FileFingerprintPolicy;
                             metadata: FileMetadata): FileFingerprint =
  result.path = path
  result.policy = policy
  result.metadata = metadata
  if policy in {ffpChecksum, ffpHybrid}:
    result.hasLocalHash = true
    result.localHash = localHash(fileBytesForHash(path, result.metadata))

proc observeFile*(path: string; policy: FileFingerprintPolicy): FileFingerprint =
  observeFileWithMetadata(path, policy, fingerprintMetadata(path))

proc observeFile*(path: string; policy: FileFingerprintPolicy;
                  cache: ptr FileMetadataCache): FileFingerprint =
  observeFileWithMetadata(path, policy, fingerprintMetadata(path, cache))

proc observeEnumeratedDirectory*(path: string;
                                 policy: FileFingerprintPolicy): FileFingerprint =
  ## Record a directory the action ENUMERATED, carrying its membership.
  ## Bypasses the metadata cache deliberately: that cache holds the
  ## existence-only answer for the same path.
  observeFileWithMetadata(path, policy, fingerprintDirectoryMembership(path))

proc isVolatileDevicePath(path: string): bool =
  ## Shared with the build engine's ``isVolatileMonitorPath`` — see
  ## ``repro_core/paths.isVolatileRuntimeStatePath``. This used to be a
  ## hand-copied duplicate of that prefix list; the two layers must admit
  ## and drop exactly the same paths, because an input the engine puts in
  ## the fingerprint and this layer silently leaves out of the record is a
  ## cache entry keyed on something it does not carry.
  isVolatileRuntimeStatePath(path)

proc isRecordableInput(input: FileFingerprint): bool =
  if input.path.isVolatileDevicePath():
    return false
  input.metadata.kind != ffkOther

proc digestHex*(digest: ContentDigest): string =
  toHex(digest.bytes)

proc openLocalCas*(root: string): LocalCas =
  result.root = root
  createDir(extendedPath(result.root))
  createDir(extendedPath(result.root / "tmp"))

proc blobPath*(cas: LocalCas; digest: ContentDigest): string =
  let hex = digestHex(digest)
  cas.root / hex[0 .. 1] / hex[2 .. ^1]

proc blobRef*(digest: ContentDigest; sizeBytes: uint64): CasBlobRef =
  CasBlobRef(digest: digest, sizeBytes: sizeBytes)

proc r11CasDigest(hash: PrefixIdBytes): ContentDigest =
  ContentDigest(algorithm: haBlake3_256, domain: hdCasContent, bytes: hash)

proc r11CasHash(blob: CasBlobRef): PrefixIdBytes =
  if blob.digest.algorithm != haBlake3_256:
    raise newException(CacheIntegrityError,
      "unsupported CAS digest algorithm for " & digestHex(blob.digest))
  blob.digest.bytes

proc readBlob*(cas: LocalCas; blob: CasBlobRef): seq[byte] =
  let path = cas.blobPath(blob.digest)
  if not fileExists(extendedPath(path)):
    raise newException(CacheIntegrityError, "missing CAS object " &
      digestHex(blob.digest))
  result = bytes(readFile(extendedPath(path)))
  if uint64(result.len) != blob.sizeBytes:
    raise newException(CacheIntegrityError, "CAS size mismatch for " &
      digestHex(blob.digest))
  let actual = casDigest(result)
  if actual != blob.digest:
    raise newException(CacheIntegrityError, "CAS digest mismatch for " &
      digestHex(blob.digest))

proc verifyBlob*(cas: LocalCas; blob: CasBlobRef) =
  let path = cas.blobPath(blob.digest)
  if not fileExists(extendedPath(path)):
    raise newException(CacheIntegrityError, "missing CAS object " &
      digestHex(blob.digest))
  let info = getFileInfo(extendedPath(path), followSymlink = false)
  if uint64(info.size) != blob.sizeBytes:
    raise newException(CacheIntegrityError, "CAS size mismatch for " &
      digestHex(blob.digest))
  noteCasContentDigest(blob.sizeBytes)
  let actual = casFileDigest(extendedPath(path), blob.sizeBytes)
  if actual != blob.digest:
    raise newException(CacheIntegrityError, "CAS digest mismatch for " &
      digestHex(blob.digest))

proc storeBlob*(cas: LocalCas; payload: openArray[byte]): CasBlobRef =
  noteCasContentDigest(uint64(payload.len))
  result.digest = casDigest(payload)
  result.sizeBytes = uint64(payload.len)
  let finalPath = cas.blobPath(result.digest)
  if fileExists(extendedPath(finalPath)):
    cas.verifyBlob(result)
    return
  createDir(extendedPath(finalPath.splitPath.head))
  let now = getTime()
  let tmpPath = cas.root / "tmp" / (digestHex(result.digest) & "." &
    $getCurrentProcessId() & "." & $now.toUnix & "." & $now.nanosecond)
  writeFile(extendedPath(tmpPath), byteString(payload))
  try:
    moveFile(extendedPath(tmpPath), extendedPath(finalPath))
  except OSError:
    if fileExists(extendedPath(tmpPath)):
      removeFile(extendedPath(tmpPath))
    if fileExists(extendedPath(finalPath)):
      cas.verifyBlob(result)
    else:
      raise

proc storeFileBlob*(cas: LocalCas; path: string; sizeBytes: uint64): CasBlobRef =
  noteCasContentDigest(sizeBytes)
  result.digest = casFileDigest(extendedPath(path), sizeBytes)
  result.sizeBytes = sizeBytes
  let finalPath = cas.blobPath(result.digest)
  let finalFsPath = extendedPath(finalPath)
  if fileExists(finalFsPath):
    cas.verifyBlob(result)
    return
  createDir(extendedPath(finalPath.splitPath.head))
  let now = getTime()
  let tmpPath = cas.root / "tmp" / (digestHex(result.digest) & "." &
    $getCurrentProcessId() & "." & $now.toUnix & "." & $now.nanosecond)
  let tmpFsPath = extendedPath(tmpPath)
  copyFile(extendedPath(path), tmpFsPath)
  try:
    moveFile(tmpFsPath, finalFsPath)
  except OSError:
    if fileExists(tmpFsPath):
      removeFile(tmpFsPath)
    if fileExists(finalFsPath):
      cas.verifyBlob(result)
    else:
      raise

proc blobPath*(cas: Store; digest: ContentDigest): string =
  cas.casPath(PrefixIdBytes(digest.bytes))

proc readBlob*(cas: Store; blob: CasBlobRef): seq[byte] =
  try:
    result = cas.readCasBlob(blob.r11CasHash())
  except StoreError as err:
    raise newException(CacheIntegrityError, err.msg)
  if uint64(result.len) != blob.sizeBytes:
    raise newException(CacheIntegrityError, "CAS size mismatch for " &
      digestHex(blob.digest))

proc verifyBlob*(cas: Store; blob: CasBlobRef) =
  noteCasContentDigest(blob.sizeBytes)
  discard cas.readBlob(blob)

proc storeBlob*(cas: var Store; payload: openArray[byte]): CasBlobRef =
  noteCasContentDigest(uint64(payload.len))
  result.digest = r11CasDigest(cas.storeCasBlob(payload))
  result.sizeBytes = uint64(payload.len)

proc storeFileBlob*(cas: var Store; path: string; sizeBytes: uint64): CasBlobRef =
  noteCasContentDigest(sizeBytes)
  result.digest = r11CasDigest(cas.storeCasFileBlob(path, sizeBytes))
  result.sizeBytes = sizeBytes

proc materialPath(root, path: string): string =
  if path.isAbsolute or root.len == 0:
    path
  else:
    root / path

const
  WitnessMagic = "RBOW"
  WitnessVersion = 2'u16
  WitnessFileExt = ".octime"

proc witnessFileName(strongHex: string): string =
  strongHex & WitnessFileExt

proc isEmpty(w: OutputWitness): bool =
  w.changeTimeNs == 0'u64 and w.linkTarget.len == 0 and not w.hasTreeDigest

proc encodeWitnesses(witnesses: Table[string, OutputWitness];
                     recordWriteSequence: uint64): seq[byte] =
  for i in 0 ..< 4:
    result.add(byte(ord(WitnessMagic[i])))
  result.writeU16Le(WitnessVersion)
  # Back-reference to the `.rec` this sidecar describes. A reader that finds a
  # different sequence in the record file treats the sidecar as absent. This
  # is what makes an OLD binary rewriting `<hex>.rec` -- which cannot know
  # about the sidecar -- safe: the stale witness is discarded rather than
  # compared against outputs it no longer describes.
  result.writeU64Le(recordWriteSequence)
  result.writeU32Le(uint32(witnesses.len))
  for path, w in witnesses:
    result.writeString(path)
    result.writeU64Le(w.changeTimeNs)
    result.writeString(w.linkTarget)
    result.add(if w.hasTreeDigest: 1'u8 else: 0'u8)
    result.writeU64Le(w.treeDigest)

proc decodeWitnesses(raw: openArray[byte]):
    tuple[recordWriteSequence: uint64; witnesses: Table[string, OutputWitness]] =
  result.witnesses = initTable[string, OutputWitness]()
  if raw.len < 18:
    return
  for i in 0 ..< 4:
    if raw[i] != byte(ord(WitnessMagic[i])):
      return
  var pos = 4
  let version = readU16Le(raw, pos)
  if version != WitnessVersion:
    return
  result.recordWriteSequence = readU64Le(raw, pos)
  let count = int(readU32Le(raw, pos))
  for _ in 0 ..< count:
    let path = readString(raw, pos)
    var w: OutputWitness
    w.changeTimeNs = readU64Le(raw, pos)
    w.linkTarget = readString(raw, pos)
    w.hasTreeDigest = readByte(raw, pos) == 1
    w.treeDigest = readU64Le(raw, pos)
    result.witnesses[path] = w

proc witnessesOf(records: openArray[ActionResultRecord]):
    tuple[witnesses: Table[string, OutputWitness]; any: bool] =
  ## Merge the witnesses carried by `records`. All records in one `.rec` share
  ## a strong fingerprint, so they describe the same outputs; a non-empty
  ## witness always wins over an empty one.
  result.witnesses = initTable[string, OutputWitness]()
  for record in records:
    for output in record.outputs:
      let w = OutputWitness(changeTimeNs: output.changeTimeNs,
        linkTarget: output.linkTarget, treeDigest: output.treeDigest,
        hasTreeDigest: output.hasTreeDigest)
      if not w.isEmpty:
        result.any = true
        result.witnesses[output.path] = w
      elif output.path notin result.witnesses:
        result.witnesses[output.path] = w

proc attachWitnesses(record: var ActionResultRecord;
                     witnesses: Table[string, OutputWitness]) {.used.} =
  for i in 0 ..< record.outputs.len:
    let w = witnesses.getOrDefault(record.outputs[i].path)
    record.outputs[i].changeTimeNs = w.changeTimeNs
    record.outputs[i].linkTarget = w.linkTarget
    record.outputs[i].treeDigest = w.treeDigest
    record.outputs[i].hasTreeDigest = w.hasTreeDigest

# ---------------------------------------------------------------------------
# Determinism sidecar (`Edge-Determinism-And-Soft-Rebuild.md` §3).
#
# Same mechanism as the output-witness sidecar above, and chosen for the same
# reason: the RBAR frame cannot grow. `decodeRecord` raises
# `eeMalformed` on trailing bytes and `eeUnsupportedVersion` on an unknown
# version, and `decodePerEdgeFileWithSeq` swallows both with `break` -- so a
# frame an older `repro` cannot parse makes that binary see ZERO records for
# the edge, silently and permanently. A sidecar is invisible to every reader
# that filters on `PerEdgeRecFileExt`, which all of them do.
#
# One difference from the witness sidecar: this one is written ONLY for an
# entry whose producing action actually DECLARED a class. The overwhelming
# majority of edges declare nothing, write no sidecar, and cost nothing.
# ---------------------------------------------------------------------------

const
  DeterminismMagic = "RBDM"
  DeterminismVersion = 1'u16
  DeterminismFileExt* = ".det"
    ## Exported so the retention GC can enumerate sidecars without
    ## re-deriving the extension.

proc determinismFileName*(strongHex: string): string =
  strongHex & DeterminismFileExt

proc encodeDeterminism(meta: EntryDeterminism;
                       recordWriteSequence: uint64): seq[byte] =
  for i in 0 ..< 4:
    result.add(byte(ord(DeterminismMagic[i])))
  result.writeU16Le(DeterminismVersion)
  # Same back-reference as the witness sidecar: names the `.rec` this
  # describes so a rewrite by a binary that knows nothing about sidecars
  # invalidates it instead of leaving it paired with a record it no longer
  # describes.
  result.writeU64Le(recordWriteSequence)
  result.add(byte(ord(meta.class)))
  result.add(byte(ord(meta.retention.kind)))
  result.writeU64Le(uint64(max(0'i64, meta.retention.seconds)))
  result.writeU64Le(uint64(max(0'i64, meta.writeTimeUnix)))
  result.writeString(meta.hostFingerprint)
  result.writeString(meta.buildEpoch)

proc decodeDeterminism(raw: openArray[byte]):
    tuple[recordWriteSequence: uint64; meta: EntryDeterminism] =
  ## Returns `meta.declared == false` on any problem. A sidecar that cannot be
  ## read is exactly a sidecar that is not there; it must never abort a build.
  if raw.len < 14:
    return
  for i in 0 ..< 4:
    if raw[i] != byte(ord(DeterminismMagic[i])):
      return
  var pos = 4
  let version = readU16Le(raw, pos)
  if version != DeterminismVersion:
    return
  try:
    result.recordWriteSequence = readU64Le(raw, pos)
    let cls = readByte(raw, pos)
    if cls > byte(ord(high(EdgeDeterminism))):
      return (0'u64, EntryDeterminism())
    let retKind = readByte(raw, pos)
    if retKind > byte(ord(high(CacheRetentionKind))):
      return (0'u64, EntryDeterminism())
    var meta = EntryDeterminism(declared: true)
    meta.class = EdgeDeterminism(cls)
    meta.retention = CacheRetention(kind: CacheRetentionKind(retKind),
      seconds: int64(readU64Le(raw, pos)))
    meta.writeTimeUnix = int64(readU64Le(raw, pos))
    meta.hostFingerprint = readString(raw, pos)
    meta.buildEpoch = readString(raw, pos)
    result.meta = meta
  except EnvelopeError, CatchableError:
    return (0'u64, EntryDeterminism())

proc metaOf(records: openArray[ActionResultRecord]): EntryDeterminism =
  ## All records in one `.rec` share a strong fingerprint and therefore one
  ## producing action, so they share one class. A declared entry wins over an
  ## undeclared one, for the same reason a non-empty witness wins over an
  ## empty one: a republish that lost the metadata must not erase it.
  for record in records:
    if record.determinism.declared:
      return record.determinism
  EntryDeterminism()

var cachedHostFingerprint = ""

proc hostFingerprint*(): string =
  ## §3's `host-bound` write column: "the host fingerprint (machine-id, OS,
  ## architecture)".
  ##
  ## STRICTLY READ-ONLY. `repro_profile`'s `ensureMachineId` would be the
  ## richer answer, but it PERSISTS a UUID to `/etc/repro/machine-id` when it
  ## finds none, and writing to `/etc` to label a cache entry is not a trade
  ## this metadata is worth. `/etc/machine-id` is read if it happens to be
  ## there and simply skipped if it is not.
  ##
  ## This value is never a security boundary and is never compared for
  ## equality on the local read path -- a local hit is by construction on the
  ## producing host. Its whole job is to let a cross-machine substitution be
  ## refused with the producing host NAMED rather than refused blankly.
  if cachedHostFingerprint.len > 0:
    return cachedHostFingerprint
  var parts: seq[string] = @[]
  when defined(posix):
    try:
      if fileExists("/etc/machine-id"):
        let mid = readFile("/etc/machine-id").strip()
        if mid.len > 0:
          parts.add("machine-id=" & mid)
    except OSError, IOError:
      discard
  try:
    let host = getHostname()
    if host.len > 0:
      parts.add("host=" & host)
  except OSError, CatchableError:
    discard
  parts.add("os=" & hostOS)
  parts.add("arch=" & hostCPU)
  cachedHostFingerprint = parts.join(" ")
  cachedHostFingerprint

proc declaredDeterminism*(class: EdgeDeterminism;
                          retention = forever();
                          nowUnix: int64 = 0;
                          buildEpoch = ""): EntryDeterminism =
  ## Build the metadata a producing action stamps onto its cache entry.
  ## `nowUnix = 0` means "read the wall clock now"; a caller with an injected
  ## clock (every test that asserts on expiry) passes its own.
  EntryDeterminism(
    declared: true,
    class: class,
    retention: retention,
    writeTimeUnix: (if nowUnix != 0: nowUnix else: toUnix(getTime())),
    hostFingerprint: hostFingerprint(),
    buildEpoch: buildEpoch)

proc resetOutputStateCheckStats*() =
  ## Zero the accumulators, including the CAS content-digest counter read by
  ## `casContentDigestStats`. The engine calls this at the start of every build:
  ## these are process-global, and a process that runs more than one build
  ## (the daemon, the test binaries, `repro watch`) would otherwise report
  ## each build's cost plus every earlier build's.
  outputStateCheckCalls = 0
  storeAbsenceSkips = 0
  outputStateCheckNanos = 0'i64
  revalidateDirWalks = 0
  revalidateDirEntries = 0'i64
  recordDirWalks = 0
  recordDirEntries = 0'i64
  casContentDigestCalls = 0
  casContentDigestBytes = 0'i64
  actionRecordDecodes = 0
  actionRecordDecodeBytes = 0'i64
  perEdgeContainerReads = 0
  perEdgeSidecarReads = 0
  actionRecordDecodeNanos = 0'i64
  perEdgeContainerReadNanos = 0'i64
  perEdgeSidecarReadNanos = 0'i64
  actionIndexNegativeHits = 0
  actionIndexResolvedHits = 0
  actionIndexUnionFallbacks = 0
  actionIndexUnresolvedRefs = 0
  storeAbsenceSkipNanos = 0'i64
  recordedInputRevalidateChecks = 0
  recordedInputRevalidateNanos = 0'i64
  membershipRelists = 0
  membershipRelistNanos = 0'i64
  membershipRelistEntries = 0'i64
  perEdgeRecordLoads = 0
  perEdgeRecordLoadNanos = 0'i64
  slowMetadataProbes = 0
  slowMetadataProbeNanos = 0'i64
  slowestMetadataProbeNanos = 0'i64
  slowestMetadataProbePath = ""

proc slowMetadataProbeStats*():
    tuple[slowProbes: int; slowNanos, slowestNanos: int64;
          slowestPath: string] =
  ## The TAIL of the recorded-input probe population: how many checks took a
  ## millisecond or more, what they cost together, and the single worst one
  ## with its path.
  ##
  ## This exists because the average over this population is not evidence.
  ## "One pathological path can dominate a whole probe population" is a
  ## recorded hazard: 15 ms of an 18 ms loop went to ONE autofs lookup, and
  ## the resulting 3.4 us/probe average was most of a figure that produced
  ## two separate wrong estimates. A max plus a tail count settles from the
  ## stats table which of the two shapes a reading has, and no division can.
  (slowMetadataProbes, slowMetadataProbeNanos, slowestMetadataProbeNanos,
   slowestMetadataProbePath)

proc membershipRelistStats*():
    tuple[relists: int; nanos, entries: int64] =
  ## Recorded-input checks on a MEMBERSHIP-TRACKED DIRECTORY, which are
  ## re-listed and digested rather than stat'd.
  ##
  ## A strict SUBSET of `repro file metadata warm revalidate` in both count
  ## and duration -- these rows nest, they do not partition. Split out
  ## because `warm revalidate` otherwise averages a one-syscall check
  ## together with a whole-directory walk, and the average describes neither
  ## population.
  ##
  ## `entries` is the load-independent half: a duration alone cannot say
  ## whether a slow re-list walked a big tree or a slow filesystem.
  (membershipRelists, membershipRelistNanos, membershipRelistEntries)

proc perEdgeRecordLoadStats*(): tuple[loads: int; nanos: int64] =
  ## The interval that ENCLOSES `repro per-edge container read`, `repro
  ## per-edge sidecar read` and `repro action record decode`.
  ##
  ## Those three time file reads and CPU; this times the whole load. The
  ## difference is the directory enumeration, the existence probes and the
  ## record copying, which MAC-3 measured at roughly 40% of a `readHotRecord`
  ## and had nowhere to report.
  (perEdgeRecordLoads, perEdgeRecordLoadNanos)

proc recordedInputRevalidateStats*(): tuple[checks: int; nanos: int64] =
  ## The recorded-input revalidation LOOP: `checks` metadata checks in
  ## `nanos` nanoseconds, summed over every record a build revalidated.
  ##
  ## This is the term that a warm no-op's `repro cache lookup` was assumed to
  ## be almost entirely made of, on no measurement -- `cache lookup` minus
  ## the three record-read rows, divided by these counts, quoted as "~4 us a
  ## check". It is measured here instead, at the loop rather than at the
  ## check: one `getMonoTime` pair per record costs ~35 ns against ~4,659
  ## per-check pairs costing ~0.16 ms.
  ##
  ## `checks` counts checks made INSIDE such a loop, so it excludes the
  ## record-time `observeFile` population that shares the same cache and the
  ## same counters. It is therefore <= the sum of the four
  ## `repro file metadata *` counts, not equal to it.
  ##
  ## The four class durations are measured INSIDE this interval and are
  ## disjoint, so `currentRunHitNanos + coldStatNanos + warmRevalidateNanos +
  ## storeAbsenceSkipNanos <= nanos` always. The difference is the loop's own
  ## machinery: the `FileMetadata` comparison, the seen-set insert, and the
  ## per-check timers themselves.
  (recordedInputRevalidateChecks, recordedInputRevalidateNanos)

proc storeAbsenceSkipNanoStats*(): int64 =
  ## The DURATION half of `storeAbsenceSkipStats`, in nanoseconds.
  ##
  ## Process-global, like the count it explains, and reset with it -- unlike
  ## the other three class durations, which live in the cache object because
  ## their counts do. See `FileMetadataCacheStats`.
  storeAbsenceSkipNanos

proc actionRecordDecodeNanoStats*(): tuple[decode, container, sidecar: int64] =
  ## The DURATION half of `actionRecordDecodeStats`, in nanoseconds.
  ##
  ## `decode` is the pure-CPU time inside `decodeRecord` and NOTHING else;
  ## `container` is the `readFile` of a `<strongHex>.rec` alone, with its
  ## decode excluded (that time lands in `decode`); `sidecar` is the read +
  ## decode of a `.octime` witness file.
  ##
  ## Split this way on purpose: "hot-record read and decode" was a single
  ## budgeted line item, and splitting the read from the decode is what shows
  ## which half a change would have to attack. Reset by
  ## `resetOutputStateCheckStats`, like every row beside it, so a reading
  ## after a build describes THAT build.
  ##
  ## These are a stopwatch and inherit a stopwatch's weakness under ambient
  ## load. They do NOT replace the counts, which are the load-independent
  ## evidence for Action-Cache-Per-Edge-Store.md §5.5.
  (actionRecordDecodeNanos, perEdgeContainerReadNanos, perEdgeSidecarReadNanos)

proc actionIndexStats*(): tuple[negativeHits, resolvedHits, unionFallbacks,
                                unresolvedReferences: int] =
  ## What the Tier-2 index actually did for THIS build
  ## (Action-Cache-Per-Edge-Store.md §11, §8.1).
  ##
  ## `negativeHits` is the effect the tier exists for: an edge the index
  ## reported complete and empty, answered from mapped memory with zero
  ## filesystem operations. It applies to every cache miss, the dominant case
  ## in a cold build, and it is what lets the batch up-to-date scan
  ## short-circuit on the first probe with no record.
  ##
  ## `unionFallbacks` is its complement — every lookup that had to list a
  ## directory — and the two together are the only honest way to say whether
  ## the accelerator is engaged. A build where the index is attached, healthy
  ## and answering nothing looks, from the outside, exactly like a build where
  ## it is working; these rows are the difference.
  (negativeHits: actionIndexNegativeHits, resolvedHits: actionIndexResolvedHits,
   unionFallbacks: actionIndexUnionFallbacks,
   unresolvedReferences: actionIndexUnresolvedRefs)

proc actionRecordDecodeStats*(): tuple[records: int; bytes: int64;
                                       containerReads: int;
                                       sidecarReads: int] =
  ## How much RECORD content this build decoded to answer cache questions.
  ##
  ## `records` counts decoded `RBAR` frames, `bytes` their total size,
  ## `containerReads` the `.rec` files opened by the Tier-1 read paths, and
  ## `sidecarReads` the `.octime` / `.det` files opened alongside them.
  ##
  ## These are the load-independent evidence for
  ## Action-Cache-Per-Edge-Store.md §5.5. C1 is exactly the statement
  ## "`records` per consultation is 1, not the number of containers the edge
  ## has"; C4 is exactly the statement "`bytes` per decoded record falls".
  ## Asserted on by
  ## `libs/repro_local_store/tests/t_newest_alias_decodes_one_record.nim`.
  ##
  ## Reset by `resetOutputStateCheckStats`, which `runBuild` calls, so a
  ## reading after a build describes THAT build.
  (records: actionRecordDecodes, bytes: actionRecordDecodeBytes,
   containerReads: perEdgeContainerReads, sidecarReads: perEdgeSidecarReads)

proc casContentDigestStats*(): tuple[calls: int; bytes: int64] =
  ## How much artifact CONTENT this build read to answer cache questions.
  ##
  ## `calls` is the number of CAS blobs whose bytes were hashed or re-read;
  ## `bytes` is their total size. Both are zero for a build that only
  ## consulted metadata-only records, which is what `repro build` publishes
  ## and consults unless `--restore-cached-outputs` is given.
  ##
  ## Reset by `resetOutputStateCheckStats`, which `runBuild` calls, so the
  ## reading after a build describes THAT build.
  (calls: casContentDigestCalls, bytes: casContentDigestBytes)

proc outputStateCheckStats*(): tuple[calls: int; nanos: int64;
                                     revalidateDirWalks: int;
                                     revalidateDirEntries: int64;
                                     recordDirWalks: int;
                                     recordDirEntries: int64] =
  ## Accumulated cost of EVERY `outputStateMismatch` call in this process.
  ##
  ## Counted inside the proc, not at the call sites, deliberately: the check
  ## runs from three places (the whole-build fast-noop scan, the per-edge
  ## metadata-only lookup, and the per-edge candidate walk), two of which are
  ## inside this module where the engine's stats plumbing does not reach.
  ## Instrumenting one call site and reporting the number as "the cost of the
  ## check" would under-count it by the other two.
  (calls: outputStateCheckCalls, nanos: outputStateCheckNanos,
   revalidateDirWalks: revalidateDirWalks,
   revalidateDirEntries: revalidateDirEntries,
   recordDirWalks: recordDirWalks, recordDirEntries: recordDirEntries)

proc outputStateMismatchImpl(record: ActionResultRecord;
                             outputRoot: string): string =
  ## Incremental-Invalidation.md §"Minimum check set per target
  ## consultation", Step 3.3: "For an in-place local build, declared outputs
  ## must already exist **and match the recorded output metadata**."
  ##
  ## Returns "" when every declared output still matches, otherwise a short
  ## human-readable reason naming the first output that does not. The engine
  ## turns a non-empty result into `aclRejectedCorruptOutput` / `cdRejected`
  ## and re-executes, which is the fail-closed behaviour the same document's
  ## §"Rebuild Decision Model" requires.
  ##
  ## Cost is one `lstat(2)` per declared output on a cache hit. The engine
  ## already stats every output to decide whether it exists at all, so this
  ## is not a new class of work; it is the same class of work, comparing
  ## more of what the syscall already returned.
  ##
  ## What it does NOT do is hash the output. Hashing every output on every
  ## consultation would be correct and would also make the warm no-op path
  ## scale with total artifact bytes instead of artifact count. The change
  ## time is what buys tamper evidence without that: see `OutputBlob`.
  for output in record.outputs:
    if output.metadata.kind == ffkMissing:
      # Nothing was recorded for this output; there is nothing to compare
      # against and inventing a rule here would reject valid records.
      continue
    let path = materialPath(outputRoot, output.path)
    let live = fingerprintMetadata(path)
    if live.kind == ffkMissing:
      return "output missing: " & output.path
    if live != output.metadata:
      return "output metadata changed: " & output.path

    # -- symlink -----------------------------------------------------------
    # A recorded link target means the output WAS a symlink. `live` cannot
    # distinguish that case (a symlink to a file reports as ffkRegular), so
    # the target string is the whole comparison.
    if output.linkTarget.len > 0:
      let liveTarget = symlinkTargetOf(path)
      if liveTarget.len == 0:
        return "output is no longer a symlink: " & output.path
      if liveTarget != output.linkTarget:
        return "symlink output retargeted: " & output.path
      # NO early exit. A symlink to a DIRECTORY is classified `ffkDirectory`
      # and therefore carries a tree digest; returning here once the target
      # matched left that digest uncompared, so tampering INSIDE the linked
      # tree survived as a hit. The link target and the kind-specific check
      # are additive.

    # -- directory ---------------------------------------------------------
    if output.metadata.kind == ffkDirectory:
      if not output.hasTreeDigest:
        # `fingerprintMetadata` zeroes size and mtime for a directory, so
        # everything compared above was vacuous and the only thing actually
        # established is that the directory still exists. With no tree
        # digest there is no way to answer the question, so fail closed --
        # Incremental-Invalidation.md §"Rebuild Decision Model": "If any
        # required condition cannot be checked, Reprobuild MUST fail closed."
        # This is what makes a pre-existing record (written before witnesses
        # existed) re-execute ONCE; the replacement record carries a digest.
        return "directory output has no recorded tree digest: " & output.path
      var liveDigest = 0'u64
      try:
        var walked = 0'i64
        liveDigest = directoryMetadataDigest(path, walked)
        inc revalidateDirWalks
        revalidateDirEntries += walked
      except OSError, IOError:
        return "directory output could not be walked: " & output.path
      if liveDigest != output.treeDigest:
        return "directory output contents changed: " & output.path
      continue

    # -- regular file ------------------------------------------------------
    if output.metadata.kind == ffkRegular:
      if output.changeTimeNs == 0'u64:
        # Either the record predates witnesses, or the platform reports no
        # change time (Windows). Degrading to the kind/size/mtime comparison
        # above is what every record did before this change, so this is not
        # a new hole -- but it IS the hole, and it stays open for records in
        # an existing cache until each edge next executes.
        continue
      let liveCtime = observeOutputWitness(path, live).changeTimeNs
      if liveCtime != 0'u64 and liveCtime != output.changeTimeNs:
        # Size and mtime match but the inode changed after the action wrote
        # it. Something rewrote, chmod'd or relinked the artifact behind the
        # build's back; the recorded result no longer describes what is on
        # disk. Fail closed.
        return "output changed after it was recorded: " & output.path
  ""

proc outputStateMismatch*(record: ActionResultRecord;
                          outputRoot: string): string =
  let started = getMonoTime()
  result = outputStateMismatchImpl(record, outputRoot)
  inc outputStateCheckCalls
  outputStateCheckNanos += (getMonoTime() - started).inNanoseconds

proc restoreOutputs*(cas: LocalCas; record: ActionResultRecord;
                     outputRoot = "") =
  if record.outputPayloadKind != opkCasBlobs:
    raise newException(CacheIntegrityError,
      "cache record does not contain output payloads")
  var payloads: seq[seq[byte]] = @[]
  for output in record.outputs:
    payloads.add(cas.readBlob(output.blob))
  for i, output in record.outputs:
    let destination = materialPath(outputRoot, output.path)
    if output.metadata.kind == ffkDirectory:
      materializeDirectorySnapshotPayload(payloads[i], destination,
        output.permissions)
      continue
    createDir(extendedPath(destination.splitPath.head))
    let tmpPath = destination & ".reprotmp." & $getCurrentProcessId()
    writeFile(extendedPath(tmpPath), byteString(payloads[i]))
    # Windows: rwx permissions are not preserved (see writePermissions);
    # applying setFilePermissions with an empty set would clobber the file's
    # NTFS ACLs in unhelpful ways, so we skip it entirely. Follow-up:
    # preserve ACLs / read-only attribute via icacls / SetFileAttributes.
    when not defined(windows):
      setFilePermissions(extendedPath(tmpPath), output.permissions)
    # The unlink+rename below can fail for reasons that have nothing to
    # do with cache integrity: the destination may be an executable image
    # another process currently has mapped (Windows refuses to unlink a
    # running image), the parent directory may be read-only, or the
    # destination may be held by a mandatory lock. Without this handler
    # the raise escapes with the staged temp file still on disk, so every
    # retry cycle leaves another ``<output>.reprotmp.<pid>`` sibling
    # behind and the directory accumulates them indefinitely.
    #
    # Mirrors the recovery in ``storeFileBlob`` above: drop the temp file,
    # then re-raise. The error is deliberately still propagated — the
    # caller asked for the declared outputs to be materialized and they
    # were not, so swallowing it here would report a cache restore that
    # silently left a stale file in place. Only the leak is fixed; the
    # failure stays visible.
    try:
      if fileExists(extendedPath(destination)):
        removeFile(extendedPath(destination))
      moveFile(extendedPath(tmpPath), extendedPath(destination))
    except OSError:
      if fileExists(extendedPath(tmpPath)):
        try:
          removeFile(extendedPath(tmpPath))
        except OSError:
          # Cleanup is best-effort; never mask the original failure.
          discard
      raise
    when not defined(windows):
      setFilePermissions(extendedPath(destination), output.permissions)

proc strongIdentityPayload(weak: ContentDigest;
                           inputs: openArray[FileFingerprint];
                           envInputs: openArray[EnvFingerprint]): seq[byte] =
  result.add(byte(ord('R')))
  result.add(byte(ord('B')))
  result.add(byte(ord('S')))
  result.add(byte(ord('F')))
  result.writeDigest(weak)
  result.writeU32Le(uint32(inputs.len))
  for input in inputs:
    result.writeString(input.path)
    result.add(byte(ord(input.policy)))
    case input.policy
    of ffpTimestamp:
      result.writeMetadata(input.metadata)
    of ffpChecksum, ffpHybrid:
      if not input.hasLocalHash:
        raise newException(ActionRecordError,
          "content fingerprint missing for " & input.path)
      result.writeLocalHash(input.localHash)
  # THE ENV SECTION IS APPENDED ONLY WHEN THERE IS ONE.
  #
  # Not a stylistic choice. Emitting a zero count for every action would
  # change the payload bytes of EVERY record ever written, so every strong
  # fingerprint in every existing cache would shift and every warm build on
  # every machine would miss once -- a full rebuild of the world to add a
  # field that the overwhelming majority of records do not use. Appending
  # nothing for an empty set keeps those keys identical and confines the new
  # bytes to the records that actually observed a variable.
  if envInputs.len > 0:
    result.add(byte(ord('E')))
    result.add(byte(ord('N')))
    result.add(byte(ord('V')))
    result.writeU32Le(uint32(envInputs.len))
    for env in envInputs:
      result.writeString(env.name)
      result.add(byte(if env.present: 1 else: 0))
      result.writeString(env.value)

proc computeStrongFingerprint*(weak: ContentDigest;
                               inputs: openArray[FileFingerprint];
                               envInputs: openArray[EnvFingerprint] = []):
                               ContentDigest =
  blake3DomainDigest(strongIdentityPayload(weak, inputs, envInputs),
    hdActionFingerprint)

proc splitPathPrefix(path: string): tuple[prefix, name: string] =
  ## Split at the LAST separator, keeping the separator on the prefix, so
  ## `prefix & name == path` for every string without exception -- absolute,
  ## relative, empty, trailing-separator, separator-only.
  ##
  ## Deliberately NOT `parentDir` / `extractFilename`: those normalise, and a
  ## codec that normalises does not round-trip. A recorded input path is
  ## compared byte-for-byte against the path the monitor observed, so a
  ## re-encode that "tidied" one would turn a hit into a permanent miss.
  var idx = -1
  for i in countdown(path.high, 0):
    if path[i] == '/' or (DirSep != '/' and path[i] == DirSep) or
        (AltSep != '/' and path[i] == AltSep):
      idx = i
      break
  if idx < 0:
    (prefix: "", name: path)
  else:
    (prefix: path[0 .. idx], name: path[idx + 1 .. ^1])

proc buildRecordPathTable(record: ActionResultRecord):
    tuple[table: seq[string]; index: Table[string, int]] =
  ## Action-Cache-Per-Edge-Store.md §5.5 C4, the table half.
  ##
  ## The table holds the record's distinct DIRECTORY PREFIXES, not its
  ## distinct whole paths. §5.5 says the saving "is bounded by repetition
  ## *within* one record, which is where the measured mass is: a record
  ## carrying 78 inputs at p50 and 10,018 at p90 is dominated by long shared
  ## directory prefixes from one checkout" -- and that is the repetition that
  ## exists. Whole paths within one record are essentially all distinct, so a
  ## table of whole paths dedups nothing and adds an index word per path.
  ## Measured over the 5,230 containers of a live developer cache
  ## (1.23 GB of encoded records, 84.5% of it path bytes): interning whole
  ## paths made the store 3.3% LARGER, interning directory prefixes made it
  ## 56.7% smaller.
  ##
  ## Both of §5.5's prohibitions hold, and they are the ones that separate
  ## this from the shared `PathTable` §12.B rejected: the table is built from,
  ## and stored inside, this record alone, so nothing is interned across
  ## containers and no byte outside the record is needed to decode it.
  result.index = initTable[string, int]()
  for input in record.inputs:
    let prefix = splitPathPrefix(input.path).prefix
    if prefix notin result.index:
      result.index[prefix] = result.table.len
      result.table.add(prefix)
  for output in record.outputs:
    let prefix = splitPathPrefix(output.path).prefix
    if prefix notin result.index:
      result.index[prefix] = result.table.len
      result.table.add(prefix)

proc writeInternedPath(outp: var seq[byte]; path: string;
                       index: Table[string, int]) =
  let split = splitPathPrefix(path)
  outp.writeU32Le(uint32(index[split.prefix]))
  outp.writeString(split.name)

proc readInternedPath(data: openArray[byte]; pos: var int;
                      table: seq[string]): string =
  let idx = int(readU32Le(data, pos))
  if idx < 0 or idx >= table.len:
    raiseEnvelopeError(eeMalformed, "path table index out of range")
  table[idx] & readString(data, pos)

proc encodeRecord(record: ActionResultRecord): seq[byte] =
  result.add(byte(ord(ActionRecordMagic[0])))
  result.add(byte(ord(ActionRecordMagic[1])))
  result.add(byte(ord(ActionRecordMagic[2])))
  result.add(byte(ord(ActionRecordMagic[3])))
  result.writeU16Le(if record.envInputs.len > 0:
    ActionRecordVersionInheritedEnv else: ActionRecordVersionEvidenceEpoch)
  result.writeDigest(record.weakFingerprint)
  result.add(byte(ord(record.policy)))
  let paths = buildRecordPathTable(record)
  result.writeU32Le(uint32(paths.table.len))
  for prefix in paths.table:
    result.writeString(prefix)
  result.writeU32Le(uint32(record.inputs.len))
  for input in record.inputs:
    result.writeInternedPath(input.path, paths.index)
    result.add(byte(ord(input.policy)))
    result.writeMetadata(input.metadata)
    result.add(if input.hasLocalHash: 1'u8 else: 0'u8)
    if input.hasLocalHash:
      result.writeLocalHash(input.localHash)
  # v5 and later always carry the env count, zero included. v4 appended the
  # section only when non-empty because doing otherwise would have rewritten
  # every record's bytes for nothing; v5 was already rewriting them, so the
  # format took the simpler shape rather than carrying the conditional forward.
  result.writeU32Le(uint32(record.envInputs.len))
  for env in record.envInputs:
    result.writeString(env.name)
    result.add(byte(if env.present: 1 else: 0))
    result.writeString(env.value)
  result.writeDigest(record.strongFingerprint)
  result.add(byte(ord(record.outputPayloadKind)))
  result.writeU32Le(uint32(record.outputs.len))
  for output in record.outputs:
    result.writeInternedPath(output.path, paths.index)
    result.writeMetadata(output.metadata)
    result.writePermissions(output.permissions)
    case record.outputPayloadKind
    of opkCasBlobs:
      result.writeDigest(output.blob.digest)
      result.writeU64Le(output.blob.sizeBytes)
    of opkMetadataOnly:
      discard

proc decodeRecordImpl(payload: openArray[byte]): ActionResultRecord =
  # Counted here rather than at the call sites: a record is decoded from the
  # per-edge container read, from the shm slot, from a peer bundle and from a
  # standalone `.rbar` file, and the property C1 states is about the total.
  noteActionRecordDecode(payload.len)
  if payload.len < 6:
    raiseEnvelopeError(eeMalformed, "truncated action record")
  for i in 0 ..< 4:
    if payload[i] != byte(ord(ActionRecordMagic[i])):
      raiseEnvelopeError(eeUnknownMagic, "unknown action record magic")
  var pos = 4
  let version = readU16Le(payload, pos)
  # Versions 2, 3, 4 and 5 are deliberately NOT accepted. They are the frames
  # written while the no-evidence publish guard was dead, and refusing them is
  # the whole mechanism -- see `ActionRecordVersionEvidenceEpoch`. This is a
  # trust decision, so it is a SET and not a `>=`: a version is readable only
  # once someone has said why it is trustworthy.
  if version notin {ActionRecordVersionEvidenceEpoch, ActionRecordVersionInheritedEnv}:
    raiseEnvelopeError(eeUnsupportedVersion, "unsupported action record version")
  let interned = version >= ActionRecordVersionInterned
  result.weakFingerprint = readDigest(payload, pos)
  let policy = readByte(payload, pos)
  if policy > byte(ord(ffpHybrid)):
    raiseEnvelopeError(eeMalformed, "invalid record policy")
  result.policy = FileFingerprintPolicy(policy)
  # The record-local path table (§5.5 C4). Empty for every pre-v5 record, and
  # nothing outside this payload is ever consulted to build it -- that is the
  # property that keeps a container independently decodable.
  var pathTable: seq[string] = @[]
  if interned:
    let tableCount = readU32Le(payload, pos)
    if tableCount > MaxRecordPathTableEntries:
      raiseEnvelopeError(eeMalformed, "implausible record path table size")
    pathTable = newSeq[string](int(tableCount))
    for i in 0 ..< int(tableCount):
      pathTable[i] = readString(payload, pos)
  let inputCount = int(readU32Le(payload, pos))
  result.inputs = newSeq[FileFingerprint](inputCount)
  for i in 0 ..< inputCount:
    if interned:
      result.inputs[i].path = readInternedPath(payload, pos, pathTable)
      let inputPolicy = readByte(payload, pos)
      if inputPolicy > byte(ord(ffpHybrid)):
        raiseEnvelopeError(eeMalformed, "invalid fingerprint policy")
      result.inputs[i].policy = FileFingerprintPolicy(inputPolicy)
      result.inputs[i].metadata = readMetadata(payload, pos)
      case readByte(payload, pos)
      of 0:
        result.inputs[i].hasLocalHash = false
      of 1:
        result.inputs[i].hasLocalHash = true
        result.inputs[i].localHash = readLocalHash(payload, pos)
      else:
        raiseEnvelopeError(eeMalformed, "invalid local hash flag")
    else:
      result.inputs[i] = readFingerprint(payload, pos)
  if version >= ActionRecordVersionEnv:
    let envCount = int(readU32Le(payload, pos))
    if envCount > 0 and version < ActionRecordVersionInheritedEnv:
      raiseEnvelopeError(eeUnsupportedVersion,
        "action record predates inherited environment evidence")
    result.envInputs = newSeq[EnvFingerprint](envCount)
    for i in 0 ..< envCount:
      result.envInputs[i].name = readString(payload, pos)
      result.envInputs[i].present = readByte(payload, pos) != 0'u8
      result.envInputs[i].value = readString(payload, pos)
  result.strongFingerprint = readDigest(payload, pos)
  if version >= 3'u16:
    let outputPayloadKind = readByte(payload, pos)
    if outputPayloadKind > byte(ord(opkMetadataOnly)):
      raiseEnvelopeError(eeMalformed, "invalid output payload kind")
    result.outputPayloadKind = OutputPayloadKind(outputPayloadKind)
  else:
    result.outputPayloadKind = opkCasBlobs
  let outputCount = int(readU32Le(payload, pos))
  result.outputs = newSeq[OutputBlob](outputCount)
  for i in 0 ..< outputCount:
    result.outputs[i].path =
      if interned: readInternedPath(payload, pos, pathTable)
      else: readString(payload, pos)
    if version >= 3'u16:
      result.outputs[i].metadata = readMetadata(payload, pos)
      result.outputs[i].permissions = readPermissions(payload, pos)
      case result.outputPayloadKind
      of opkCasBlobs:
        let digest = readDigest(payload, pos)
        let size = readU64Le(payload, pos)
        result.outputs[i].blob = blobRef(digest, size)
      of opkMetadataOnly:
        discard
    else:
      let digest = readDigest(payload, pos)
      let size = readU64Le(payload, pos)
      result.outputs[i].blob = blobRef(digest, size)
      result.outputs[i].permissions = readPermissions(payload, pos)
  if pos != payload.len:
    raiseEnvelopeError(eeMalformed, "trailing action record bytes")

proc decodeRecord(payload: openArray[byte]): ActionResultRecord =
  ## Timed wrapper over `decodeRecordImpl`.
  ##
  ## The COUNT rows (`actionRecordDecodes` / `actionRecordDecodeBytes`, see
  ## `noteActionRecordDecode`) remain the load-independent evidence for
  ## Action-Cache-Per-Edge-Store.md §5.5 C1/C4 and nothing here replaces
  ## them. The nanosecond accumulator answers a DIFFERENT question — "how
  ## much of a consultation is decode?" — which the count cannot answer at
  ## all, and which the rows previously rendered as a literal `0.0`, a figure
  ## indistinguishable from "measured and free".
  ##
  ## Two `getMonoTime` calls per decoded frame. Priced by amplification
  ## rather than assumed negligible: repeating the decode 200 extra times
  ## inside this same timed region on the zlib CMake no-op moved the
  ## accumulator from 0.4 ms to ~68 ms — i.e. the timer region tracks
  ## proportionally to real decode work over a 200x range, so the timer's own
  ## overhead is not a material share of the reading at 1x.
  ##
  ## What this does NOT establish: that the accumulated figure is accurate to
  ## better than the host clock, and that the decode of one record is
  ## representative of another. It is an aggregate over the build.
  let started = getMonoTime()
  try:
    result = decodeRecordImpl(payload)
  finally:
    actionRecordDecodeNanos += (getMonoTime() - started).inNanoseconds

proc writeActionResultRecordFile*(path: string; record: ActionResultRecord) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), byteString(encodeRecord(record)))

proc encodeActionResultRecord*(record: ActionResultRecord): seq[byte] =
  ## Public wrapper over the on-disk record codec. Used by the peer-cache
  ## action-bundle (`repro_peer_cache/action_bundle.nim`) so producer and
  ## consumer agree byte-for-byte with the on-disk action-cache encoding.
  encodeRecord(record)

proc decodeActionResultRecord*(payload: openArray[byte]): ActionResultRecord =
  ## Public wrapper over the on-disk record codec. Inverse of
  ## `encodeActionResultRecord`. Raises `EnvelopeError` on malformed
  ## input.
  decodeRecord(payload)

proc metadataOnly(input: FileFingerprint): FileFingerprint =
  FileFingerprint(
    path: input.path,
    policy: input.policy,
    metadata: input.metadata,
    hasLocalHash: false)

proc perEdgeDirPath(cache: ActionCache; weak: ContentDigest): string =
  ## Directory holding the edge's `<nonce>.rec` path-set files (AC-1b).
  cache.hotRoot / perEdgeDirName(weak)

proc legacyHotRecordPath(cache: ActionCache; weak: ContentDigest): string =
  ## Pre-AC-1b single-file location `hot-records/<key>`. Read for back-compat;
  ## never written by AC-1b (writes go to the per-edge directory).
  cache.hotRoot / perEdgeDirName(weak)

proc hotMetadataRecord(record: ActionResultRecord): ActionResultRecord =
  ## The metadata-only projection used by the warm in-place reuse paths.
  ##
  ## It drops everything needed to RESTORE an output (the CAS blob refs, and
  ## with them `opkCasBlobs`) and the strong fingerprint, because a
  ## metadata-only result "MUST NOT be treated as a remote-cache hit or as a
  ## local restore hit" (Caching-Architecture.md §"Memoization Layer").
  ##
  ## It deliberately KEEPS the per-output metadata. That is precisely what
  ## Caching-Architecture.md says a metadata-only record carries -- "output
  ## entries record existence/type, timestamp/size where relevant,
  ## permissions" -- and what Incremental-Invalidation.md §Step 3.3 requires
  ## the reuse decision to compare against. Discarding it here is what made
  ## every warm consultation accept an output it had never looked at.
  result = record
  result.inputs.setLen(0)
  for input in record.inputs:
    result.inputs.add(metadataOnly(input))
  for i in 0 ..< result.outputs.len:
    result.outputs[i].blob = CasBlobRef()
  result.outputPayloadKind = opkMetadataOnly
  result.strongFingerprint = ContentDigest()

proc recordTail(payload: openArray[byte]): uint32 =
  uint32(localHash(payload).value and RecordTailMask)

proc encodePerEdgeFile(records: openArray[ActionResultRecord];
                       writeSequence: uint64): seq[byte] =
  ## Serialize an edge's bounded record set into its per-edge container (v2).
  ## The header + record frames are byte-identical to v1 (magic, version,
  ## record count, then each `RBAR` full-record frame — the RBAR frame stays
  ## at the same offset); v2 only bumps the version and appends an 8-byte
  ## `writeSequence` TRAILER after the last record frame. Keeping the sequence
  ## in a trailer preserves the header layout for structural readers while
  ## still carrying the durable, strictly-monotonic per-cache-root counter the
  ## union read orders `.rec` files by (descending = newest first) so
  ## newest-wins / newest-corrupt-rejects is deterministic regardless of
  ## filesystem mtime resolution.
  result.add(byte(ord(PerEdgeFileMagic[0])))
  result.add(byte(ord(PerEdgeFileMagic[1])))
  result.add(byte(ord(PerEdgeFileMagic[2])))
  result.add(byte(ord(PerEdgeFileMagic[3])))
  result.writeU16Le(PerEdgeFileVersion)
  result.writeU32Le(uint32(records.len))
  for record in records:
    let payload = encodeRecord(record)
    result.writeU32Le(uint32(payload.len))
    result.add(payload)
    result.writeU32Le(recordTail(payload))
  result.writeU64Le(writeSequence)

proc decodePerEdgeFileWithSeq(raw: openArray[byte]):
    tuple[records: seq[ActionResultRecord]; writeSequence: uint64] =
  ## Inverse of `encodePerEdgeFile`. Tolerates a truncated tail (a crashed
  ## writer that lost the rename race leaves either the old file or a
  ## complete new file; a torn body is treated as "stop at the last intact
  ## record" rather than raising, matching the pre-existing frame reader).
  ## Back-compat: a v1 file (pre-fix `.rec`, no sequence trailer) decodes with
  ## `writeSequence = 0` so it sorts as OLDEST and is re-stamped on next write.
  if raw.len < 10:
    return
  for i in 0 ..< 4:
    if raw[i] != byte(ord(PerEdgeFileMagic[i])):
      return
  var pos = 4
  let version = readU16Le(raw, pos)
  if version notin {PerEdgeFileVersionLegacy, PerEdgeFileVersion}:
    return
  let count = int(readU32Le(raw, pos))
  for _ in 0 ..< count:
    if pos + 8 > raw.len:
      break
    let length = int(readU32Le(raw, pos))
    if length < 0 or length > MaxActionRecordFrameBytes or pos + length + 4 > raw.len:
      break
    let payload = raw[pos .. pos + length - 1]
    pos += length
    let tail = readU32Le(raw, pos)
    if tail != recordTail(payload):
      break
    try:
      result.records.add(decodeRecord(payload))
    except EnvelopeError:
      break
  # v2 trailer: the 8-byte write sequence follows the last complete frame.
  # Read it only if the whole body decoded intactly AND exactly 8 trailing
  # bytes remain (a torn body already `break`ed above and leaves no trailer).
  if version >= PerEdgeFileVersion and pos + 8 == raw.len:
    result.writeSequence = readU64Le(raw, pos)

proc decodePerEdgeFile(raw: openArray[byte]): seq[ActionResultRecord] =
  ## Records-only view over `decodePerEdgeFileWithSeq` for callers that don't
  ## need the write sequence (legacy migration + intactness probes).
  decodePerEdgeFileWithSeq(raw).records

proc scanPerEdgeFileWriteSequence(raw: openArray[byte]): uint64 =
  ## The ORDERING half of `decodePerEdgeFileWithSeq`, with the record bodies
  ## left where they are.
  ##
  ## §5.3's total order over an edge's containers is `(writeSequence,
  ## strongHex)`. BOTH components are addressable without interpreting a
  ## single record: the sequence is an 8-byte trailer and the strong-fp hex
  ## is the file's own name. A reader that only needs to know WHICH container
  ## is newest therefore needs no record from any of them — which is what
  ## lets `readHotRecord` decode one container instead of all of them
  ## (Action-Cache-Per-Edge-Store.md §5.5 C1: "the cost of a consultation
  ## MUST be proportional to the candidates it evaluates, not to the
  ## candidates the edge has").
  ##
  ## Byte-for-byte the SAME walk as `decodePerEdgeFileWithSeq`: same magic
  ## and version gate, same frame-length bounds, the same per-frame tail
  ## checksum, the same `break` on a torn body leaving `pos` past the frame
  ## it stopped on, and the same "exactly 8 bytes remain" trailer rule. It
  ## omits exactly two things, and both are per-record work: the slice that
  ## copies a frame's payload out of `raw`, and `decodeRecord` itself.
  ##
  ## THE ONE WAY IT CAN DISAGREE, and why that is safe. A frame whose
  ## checksum matches but whose BODY `decodeRecord` refuses — most often a
  ## record written by a newer reprobuild sharing the cache root — makes the
  ## full decoder `break` where this walk continues, so the full decoder
  ## reports `0` and this reports the file's true sequence. Callers must
  ## therefore treat this as the ordering key ONLY and re-derive the
  ## authoritative sequence from the container they go on to decode; the one
  ## caller does exactly that, and refuses the fast path when the two differ.
  if raw.len < 10:
    return
  for i in 0 ..< 4:
    if raw[i] != byte(ord(PerEdgeFileMagic[i])):
      return
  var pos = 4
  let version = readU16Le(raw, pos)
  if version notin {PerEdgeFileVersionLegacy, PerEdgeFileVersion}:
    return
  let count = int(readU32Le(raw, pos))
  for _ in 0 ..< count:
    if pos + 8 > raw.len:
      break
    let length = int(readU32Le(raw, pos))
    if length < 0 or length > MaxActionRecordFrameBytes or pos + length + 4 > raw.len:
      break
    let payloadStart = pos
    pos += length
    let tail = readU32Le(raw, pos)
    if tail != recordTail(raw.toOpenArray(payloadStart, pos - 5)):
      break
  if version >= PerEdgeFileVersion and pos + 8 == raw.len:
    result = readU64Le(raw, pos)

proc perEdgeRecordFileIsIntact*(raw: openArray[byte]): bool =
  ## Strict validator: true iff `raw` is a byte-complete per-edge file — a
  ## valid RBPE header whose declared record count is fully present and every
  ## contained RBAR frame decodes with a matching tail, followed only by the
  ## optional 8-byte v2 write-sequence trailer. Unlike `decodePerEdgeFile`
  ## (which stops at the first torn frame), this rejects a torn/interleaved
  ## file. Used to prove atomicity: an atomic rename never publishes a file
  ## that fails this check; a truncate-then-write can. An empty file is treated
  ## as "not yet an intact record file". Accepts both v1 (no trailer) and v2
  ## (durable write-sequence trailer) files.
  if raw.len == 0:
    return false
  if raw.len < 10:
    return false
  for i in 0 ..< 4:
    if raw[i] != byte(ord(PerEdgeFileMagic[i])):
      return false
  var pos = 4
  let version = readU16Le(raw, pos)
  if version notin {PerEdgeFileVersionLegacy, PerEdgeFileVersion}:
    return false
  let count = int(readU32Le(raw, pos))
  for _ in 0 ..< count:
    if pos + 8 > raw.len:
      return false
    let length = int(readU32Le(raw, pos))
    if length < 0 or length > MaxActionRecordFrameBytes or
        pos + length + 4 > raw.len:
      return false
    let payload = raw[pos .. pos + length - 1]
    pos += length
    if readU32Le(raw, pos) != recordTail(payload):
      return false
    try:
      discard decodeRecord(payload)
    except EnvelopeError:
      return false
  if version >= PerEdgeFileVersion:
    # A complete v2 file ends with exactly the 8-byte sequence trailer.
    pos + 8 == raw.len
  else:
    pos == raw.len

type
  NewestAlias = object
    ## Action-Cache-Per-Edge-Store.md §5.5 C1, the accelerator's payload.
    ##
    ## `<strongHex>.rec` stays THE DURABLE COPY; this names which of them was
    ## newest when it was published, and states what the directory held at
    ## that moment. The second half is what lets a reader tell a current
    ## alias from a stale one without opening a single container: any publish
    ## since either added or removed a `.rec` name (so `members` differs) or
    ## rewrote an existing one (so its container's `writeSequence` differs
    ## from `writeSequence` here, because every publish stamps a fresh value
    ## from the durable `.seq` counter). Both are checked, and either one
    ## failing sends the reader to the union read of §5.3 -- which is
    ## unconditionally correct, because Tier 1 is authoritative.
    ##
    ## This is why a crash between the two renames, a race between two
    ## publishers of the same edge, and a `.rec` written by a binary that has
    ## never heard of this file are all handled by the same rule and none of
    ## them can lose a record or serve a stale one.
    writeSequence: uint64
    strongName: string
      ## The newest container's file name, `<strongHex>.rec`.
    members: seq[string]
      ## Every `.rec` name in the directory at publish time, sorted.

proc encodeNewestAlias(alias: NewestAlias): seq[byte] =
  for ch in NewestAliasMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(NewestAliasVersion)
  result.writeU64Le(alias.writeSequence)
  result.writeString(alias.strongName)
  result.writeU32Le(uint32(alias.members.len))
  for name in alias.members:
    result.writeString(name)

proc decodeNewestAlias(raw: openArray[byte]): Option[NewestAlias] =
  ## Total: every malformed, truncated or future-version alias decodes to
  ## `none`, which the caller turns into the union fallback. An accelerator
  ## must fail like one (§5.5 C1), so nothing in here raises.
  if raw.len < 14:
    return none(NewestAlias)
  for i in 0 ..< 4:
    if raw[i] != byte(ord(NewestAliasMagic[i])):
      return none(NewestAlias)
  var pos = 4
  try:
    if readU16Le(raw, pos) != NewestAliasVersion:
      return none(NewestAlias)
    var alias = NewestAlias()
    alias.writeSequence = readU64Le(raw, pos)
    alias.strongName = readString(raw, pos)
    let count = int(readU32Le(raw, pos))
    if count < 0 or count > MaxRecFilesPerEdge * 4:
      return none(NewestAlias)
    for _ in 0 ..< count:
      alias.members.add(readString(raw, pos))
    if pos != raw.len:
      return none(NewestAlias)
    some(alias)
  except EnvelopeError:
    none(NewestAlias)

proc listRecFileNames(dirPath: string): seq[string] =
  ## The directory's `.rec` basenames, sorted. One directory enumeration and
  ## no file opens; this is the cheap half of the union read, and C1 keeps it
  ## precisely because it is what makes the alias's currency checkable.
  for kind, path in walkDir(extendedPath(dirPath)):
    if kind == pcFile and path.endsWith(PerEdgeRecFileExt):
      result.add(path.extractFilename)
  result.sort()

proc newestAliasPath(dirPath: string): string =
  dirPath / NewestAliasFileName

proc publishNewestAlias(dirPath: string; alias: NewestAlias) =
  ## §5.5 C1 step two: republish the newest container under the distinguished
  ## name, itself by atomic rename.
  ##
  ## Best-effort throughout. The `<strongHex>.rec` renames have already
  ## happened and are the durable publish; everything here only decides how
  ## fast the NEXT reader gets to the newest one. A failure, a crash, or a
  ## concurrent publisher that wins the race leaves the alias absent or
  ## stale, which the reader detects and answers with the union read.
  ##
  ## The read-then-skip guard below is not a lock and does not pretend to be
  ## one. It closes the ordinary interleaving -- two engines publishing the
  ## same edge, the one that allocated the LOWER sequence renaming its alias
  ## last -- so the alias does not routinely regress under concurrency. The
  ## residual window it cannot close is the same one a crash opens, and the
  ## reader's staleness check covers both.
  if alias.strongName.len == 0 or alias.strongName notin alias.members:
    return
  let aliasPath = newestAliasPath(dirPath)
  if fileExists(extendedPath(aliasPath)):
    try:
      let existing = decodeNewestAlias(bytes(readFile(extendedPath(aliasPath))))
      if existing.isSome and
          existing.get().writeSequence > alias.writeSequence and
          existing.get().strongName in alias.members:
        return
    except OSError, IOError:
      discard
  let tmpPath = aliasPath & ".tmp." & $getCurrentProcessId() & "." &
    $getMonoTime().ticks
  try:
    writeFile(extendedPath(tmpPath), byteString(encodeNewestAlias(alias)))
    moveFile(extendedPath(tmpPath), extendedPath(aliasPath))
  except OSError, IOError:
    if fileExists(extendedPath(tmpPath)):
      try: removeFile(extendedPath(tmpPath))
      except OSError: discard

proc loadLegacyPerEdgeFile(cache: ActionCache; weak: ContentDigest):
    seq[ActionResultRecord] =
  ## Read a pre-AC-1b single `hot-records/<key>` FILE if one exists (an
  ## un-migrated AC-1 cache). Returns empty when the path is a directory (the
  ## AC-1b layout) or absent.
  let path = cache.legacyHotRecordPath(weak)
  let ep = extendedPath(path)
  if not fileExists(ep) or dirExists(ep):
    return
  try:
    result = decodePerEdgeFile(bytes(readFile(ep)))
  except OSError, IOError:
    result = @[]

proc writeSequenceFilePath(cache: ActionCache): string =
  ## The durable write-sequence counter, a SIBLING of the per-edge directories
  ## at the `hot-records/` root (never a `<key>/` dir, never a `.rec`).
  cache.hotRoot / WriteSequenceFileName

proc readSequenceValue(path: string): uint64 =
  ## Best-effort read of the persisted u64 counter (decimal text). A missing,
  ## empty, or unparseable file reads as 0 (fresh cache / legacy layout).
  let ep = extendedPath(path)
  if not fileExists(ep):
    return 0'u64
  try:
    let text = readFile(ep).strip()
    if text.len == 0:
      return 0'u64
    result = parseBiggestUInt(text).uint64
  except CatchableError:
    result = 0'u64

proc nextWriteSequence(cache: ActionCache): uint64 =
  ## Allocate the next value of the durable, strictly-monotonic per-cache-root
  ## write-sequence counter. The counter is serialized across concurrent build
  ## engine processes by an exclusive `flock` (POSIX) / exclusive-open retry
  ## (Windows) on the `hot-records/.seq` file, so two records written
  ## microseconds apart — in one process OR across processes sharing one cache
  ## root — always receive distinct, increasing sequences. This is the total,
  ## race-free order the union read uses for newest-wins / newest-corrupt-
  ## rejects, replacing the racy nanosecond-mtime tie-break.
  createDir(extendedPath(cache.hotRoot))
  let path = cache.writeSequenceFilePath()
  when defined(posix):
    # Serialize the read-modify-write across processes with an exclusive
    # `flock` held on a dedicated lock fd for the duration of the bump. The
    # value itself is (re)written with `writeFile` (truncating) while the lock
    # is held, so a concurrent process blocks on the flock and observes the
    # committed value on its next read.
    let fd = posix.open(path.cstring, O_RDWR or O_CREAT, Mode(0o600))
    if fd < 0:
      # Counter fd unavailable: fall back to a monotonic value from the
      # persisted counter + 1. Never 0 for a real write, so it still outranks
      # a legacy/seq-0 record.
      return readSequenceValue(path) + 1'u64
    var acquired = false
    while true:
      if cFlockSeq(fd, SeqLockExclusive) == 0:
        acquired = true
        break
      if errno != EINTR:
        break
    if not acquired:
      discard posix.close(fd)
      return readSequenceValue(path) + 1'u64
    result = readSequenceValue(path) + 1'u64
    try:
      writeFile(extendedPath(path), $result)
    except CatchableError:
      discard
    # Closing the fd releases the exclusive flock.
    discard posix.close(fd)
  else:
    # Windows / other: no flock. The build model has one engine process per
    # build touching the cache serially; cross-build contention on one cache
    # root is the concern, and a truncating rewrite keeps the counter strictly
    # increasing for the common single-writer case.
    result = readSequenceValue(path) + 1'u64
    writeFile(extendedPath(path), $result)

type
  RecContainer = object
    ## One `<strongHex>.rec` file, decoded, with its sidecars already
    ## attached. Shared by the union read and the C1 alias read so both
    ## produce byte-identical records from the same file — a fast path that
    ## reconstructed a record even slightly differently would be a
    ## correctness hazard, not an optimization.
    ok: bool
    writeSequence: uint64
    strongHex: string
    records: seq[ActionResultRecord]

proc readRecBytes(dirPath, fileName: string):
    tuple[ok: bool; raw: seq[byte]] =
  ## The I/O half of `readRecContainer`, split out so a caller that only has
  ## to ORDER the candidates can get their bytes without interpreting any
  ## record in them. `ok = false` means "treat this file as absent" — the
  ## same meaning `RecContainer.ok = false` has always carried, and reached
  ## through the same exception set, so splitting the proc cannot change
  ## which files a reader considers present.
  try:
    # Timed around the `readFile` ONLY, so the container row prices the I/O
    # and the decode row prices the CPU; overlapping the two regions would
    # double-count the decode into both.
    let readStart = getMonoTime()
    result.raw = bytes(readFile(extendedPath(dirPath / fileName)))
    perEdgeContainerReadNanos += (getMonoTime() - readStart).inNanoseconds
    inc perEdgeContainerReads
    result.ok = true
  except OSError, IOError:
    result = (ok: false, raw: @[])

proc decodeRecContainer(dirPath, fileName: string;
                        raw: openArray[byte]): RecContainer =
  ## The CPU half of `readRecContainer`: decode one container's already-read
  ## bytes and staple on its `.octime` / `.det` sidecars. Split from the read
  ## so it can be deferred to the one container a consultation actually
  ## needs; the body below is the body `readRecContainer` has always had.
  var decoded: tuple[records: seq[ActionResultRecord]; writeSequence: uint64]
  try:
    decoded = decodePerEdgeFileWithSeq(raw)
  except EnvelopeError:
    return RecContainer(ok: false)
  # Tie-break key from the file's own strong-fp nonce (its base name), so
  # even legacy/seq-0 files or a hypothetical duplicate sequence still sort
  # deterministically.
  let strongHex = fileName.splitFile.name
  # Attach the witness sidecar, when present, to the records it belongs to.
  # One extra small read per `.rec`; absent/undecodable means "no witness",
  # which is the pre-change behaviour, not a hard failure.
  var witnesses = initTable[string, OutputWitness]()
  let witnessPath = dirPath / witnessFileName(strongHex)
  if fileExists(extendedPath(witnessPath)):
    try:
      inc perEdgeSidecarReads
      let sidecarStart = getMonoTime()
      let sidecar = decodeWitnesses(bytes(readFile(extendedPath(witnessPath))))
      perEdgeSidecarReadNanos += (getMonoTime() - sidecarStart).inNanoseconds
      # The back-reference must name the record file we just read. If an
      # older binary rewrote the `.rec` (it cannot know about sidecars), the
      # sequence moved and this witness describes outputs that have since
      # been replaced -- discard it rather than fail closed against stale
      # evidence.
      if sidecar.recordWriteSequence == decoded.writeSequence:
        witnesses = sidecar.witnesses
    except OSError, IOError, EnvelopeError:
      witnesses = initTable[string, OutputWitness]()
  if witnesses.len > 0:
    for i in 0 ..< decoded.records.len:
      decoded.records[i].attachWitnesses(witnesses)
  # The determinism sidecar, same shape and same back-reference rule as the
  # witness one. Absent / undecodable / mismatched sequence all mean "this
  # entry declared nothing", which is the pre-change behaviour.
  let detPath = dirPath / determinismFileName(strongHex)
  if fileExists(extendedPath(detPath)):
    try:
      inc perEdgeSidecarReads
      let detStart = getMonoTime()
      let det = decodeDeterminism(bytes(readFile(extendedPath(detPath))))
      perEdgeSidecarReadNanos += (getMonoTime() - detStart).inNanoseconds
      if det.meta.declared and
          det.recordWriteSequence == decoded.writeSequence:
        for i in 0 ..< decoded.records.len:
          decoded.records[i].determinism = det.meta
    except OSError, IOError, EnvelopeError:
      discard
  RecContainer(ok: true, writeSequence: decoded.writeSequence,
    strongHex: strongHex, records: decoded.records)

proc readRecContainer(dirPath, fileName: string): RecContainer =
  ## Read + decode ONE container and staple on its `.octime` / `.det`
  ## sidecars. `ok = false` means "treat this file as absent", which is what
  ## every failure here has always meant: a `.rec` this binary cannot decode
  ## is most often one written by a NEWER reprobuild sharing the cache root,
  ## and letting the envelope error escape would abort an otherwise healthy
  ## build over a cache file — the opposite of the fail-closed rule in
  ## Failure-Semantics.md.
  let read = readRecBytes(dirPath, fileName)
  if not read.ok:
    return RecContainer(ok: false)
  decodeRecContainer(dirPath, fileName, read.raw)

proc loadNewestPerEdgeRecordsViaAlias(cache: ActionCache;
                                      weak: ContentDigest):
    Option[seq[ActionResultRecord]] =
  ## Action-Cache-Per-Edge-Store.md §5.5 C1, the read half.
  ##
  ## Return the edge's NEWEST container without reading or decoding any other
  ## container, or `none` — in which case the caller MUST take the union read
  ## of §5.3, which is unconditionally correct because Tier 1 is
  ## authoritative. This is the same degradation an unresolvable Tier-2
  ## reference already takes (§8, step 5).
  ##
  ## `none` is returned when the alias is absent, unreadable, malformed, from
  ## a version this binary does not know, names a container that is gone or
  ## unreadable, or — the two staleness checks that make this sound —
  ##
  ##   * the directory's `.rec` name set is not the set the alias attests to,
  ##     which catches every publish, eviction or GC that added or removed a
  ##     container since (including one performed by a binary that has never
  ##     heard of the alias, and one that is in flight right now, between its
  ##     `.rec` rename and its alias rename); or
  ##   * the named container's durable write sequence is not the one the
  ##     alias recorded, which catches a CONVERGENT rewrite — same strong
  ##     fingerprint, same file name, fresh sequence — that leaves the name
  ##     set unchanged.
  ##
  ## Those two exhaust the ways the directory can move: every publish stamps
  ## a fresh sequence from the durable `.seq` counter, so it either changes
  ## the name set or changes a sequence. An alias that survives both checks
  ## therefore names the container the union read would have ordered last.
  let dirPath = cache.perEdgeDirPath(weak)
  let aliasPath = newestAliasPath(dirPath)
  var aliasRaw: seq[byte]
  try:
    if not fileExists(extendedPath(aliasPath)):
      return none(seq[ActionResultRecord])
    aliasRaw = bytes(readFile(extendedPath(aliasPath)))
  except OSError, IOError:
    return none(seq[ActionResultRecord])
  let decodedAlias = decodeNewestAlias(aliasRaw)
  if decodedAlias.isNone:
    return none(seq[ActionResultRecord])
  let alias = decodedAlias.get()
  var members: seq[string]
  try:
    members = listRecFileNames(dirPath)
  except OSError:
    return none(seq[ActionResultRecord])
  if members != alias.members:
    return none(seq[ActionResultRecord])
  if alias.strongName notin members:
    return none(seq[ActionResultRecord])
  let container = readRecContainer(dirPath, alias.strongName)
  if not container.ok or container.writeSequence != alias.writeSequence:
    return none(seq[ActionResultRecord])
  some(container.records)

proc loadPerEdgeRecords*(cache: ActionCache; weak: ContentDigest;
                         warmNewestAlias = false;
                         undecodableContainers: ptr int = nil):
    seq[ActionResultRecord] =
  ## Union-read every path-set the edge has on disk: all `<nonce>.rec` files
  ## in `hot-records/<key>/` PLUS any pre-AC-1b single-file record for
  ## back-compat. Cost is O(records for THIS edge) — it lists exactly one
  ## edge's directory, NEVER a whole-cache scan (the anti-wedge invariant).
  ## Records are deduped by strong fingerprint (a legacy file and a migrated
  ## `.rec` for the same path-set converge). Ordered OLDEST→NEWEST by each
  ## `.rec` file's DURABLE write sequence (a `.seq`-backed monotonic counter),
  ## with the strong-fingerprint hex as a total-order tie-break, so a caller
  ## iterating in reverse (as `lookupActionResult` does) considers the truly
  ## newest path-set first — preserving AC-1's "newest record wins /
  ## newest-corrupt rejects immediately" semantics deterministically across the
  ## multi-file split (mtime is NOT used: it is racy at sub-microsecond writes).
  ##
  ## `warmNewestAlias` republishes the §5.5 C1 accelerator from what this read
  ## just established, exactly as §8 step 5 warms the shared-memory index after
  ## a union fallback. Without it a cache written before C1 existed would keep
  ## paying the union read forever, because the alias is only ever written by a
  ## publish and a warm no-op build publishes nothing. Best-effort: a read-only
  ## or full cache root simply stays on the union read.
  let dirPath = cache.perEdgeDirPath(weak)
  var seenStrong = initHashSet[string]()
  if dirExists(extendedPath(dirPath)):
    # (writeSequence, strongHex) is a TOTAL, STABLE key: each `.rec` file gets a
    # distinct durable sequence at write time, and the strong-fp hex is unique
    # per file, so no two distinct files ever compare equal.
    var recFiles: seq[tuple[seq: uint64; strongHex: string;
        recs: seq[ActionResultRecord]]] = @[]
    # Every `.rec` NAME in the directory, decodable or not. The alias attests
    # to the directory's contents, so it has to name the undecodable ones too
    # -- otherwise the reader's set comparison would fail against a directory
    # this very read had just described, and the alias would be rewritten on
    # every lookup and used on none.
    var allRecNames: seq[string] = @[]
    for kind, path in walkDir(extendedPath(dirPath)):
      if kind != pcFile or not path.endsWith(PerEdgeRecFileExt):
        continue
      allRecNames.add(path.extractFilename)
      let container = readRecContainer(dirPath, path.extractFilename)
      # A `.rec` this binary cannot interpret is skipped here exactly as it
      # always was. What is new is that it is REPORTED, so a caller warming the
      # Tier-2 index knows not to claim the edge complete over a directory it
      # could only partly read.
      #
      # "Cannot interpret" is deliberately wider than "raised". The container
      # decoder is TOLERANT by design: a wrong magic, an unknown version, or a
      # torn body all return an empty record set rather than an error, because
      # the common cause is a container written by a NEWER reprobuild sharing
      # the cache root — precisely the reader whose completeness claim must not
      # be falsified. A container is never legitimately empty (a publish always
      # writes at least one record), so zero records means the same thing an
      # I/O failure does here.
      if not container.ok or container.records.len == 0:
        if undecodableContainers != nil: inc undecodableContainers[]
        continue
      recFiles.add((seq: container.writeSequence,
        strongHex: container.strongHex, recs: container.records))
    recFiles.sort(proc (a, b: tuple[seq: uint64; strongHex: string;
        recs: seq[ActionResultRecord]]): int =
      result = cmp(a.seq, b.seq)
      if result == 0:
        result = cmp(a.strongHex, b.strongHex))
    if warmNewestAlias and recFiles.len > 0:
      var alias = NewestAlias(
        writeSequence: recFiles[^1].seq,
        strongName: recFiles[^1].strongHex & PerEdgeRecFileExt,
        members: allRecNames)
      alias.members.sort()
      publishNewestAlias(dirPath, alias)
    for entry in recFiles:
      for rec in entry.recs:
        let key = digestKey(rec.strongFingerprint)
        if key notin seenStrong:
          seenStrong.incl(key)
          result.add(rec)
  else:
    # No directory: an AC-1 single file may still live at this path.
    for rec in cache.loadLegacyPerEdgeFile(weak):
      let key = digestKey(rec.strongFingerprint)
      if key notin seenStrong:
        seenStrong.incl(key)
        result.add(rec)

proc writeRecFileAtomically(cache: ActionCache; dirPath, finalName: string;
                            records: openArray[ActionResultRecord]) =
  ## Encode `records` (one path-set's bounded set) to a fresh temp file and
  ## atomically `rename()` it to `dirPath/finalName`. fsync-less: a cache needs
  ## consistency, not durability. Never clobbers a sibling `.rec` of a distinct
  ## path-set — only the same-named (same strong fp) file, which is convergence.
  ## Stamps a FRESH durable write sequence so a convergent rewrite of the same
  ## path-set becomes strictly newest (higher sequence) than every sibling.
  createDir(extendedPath(dirPath))
  # Read the sequence of the record we are replacing BEFORE the rename, so a
  # witness-free republish can tell "the sidecar belongs to the record I am
  # replacing" from "the sidecar is stale".
  var priorWriteSequence = 0'u64
  let priorRecPath = dirPath / finalName
  if fileExists(extendedPath(priorRecPath)):
    try:
      priorWriteSequence =
        decodePerEdgeFileWithSeq(bytes(readFile(priorRecPath))).writeSequence
    except OSError, IOError, EnvelopeError:
      priorWriteSequence = 0'u64
  let writeSequence = cache.nextWriteSequence()
  let now = getTime()
  let tmpPath = dirPath / (finalName & ".tmp." &
    $getCurrentProcessId() & "." & $now.toUnix & "." & $now.nanosecond)
  writeFile(extendedPath(tmpPath),
    byteString(encodePerEdgeFile(records, writeSequence)))
  try:
    moveFile(extendedPath(tmpPath), extendedPath(dirPath / finalName))
  except OSError:
    if fileExists(extendedPath(tmpPath)):
      removeFile(extendedPath(tmpPath))
    raise
  # Output witnesses go in a SIDECAR beside the `.rec`, never inside the RBAR
  # frame. Every reader of an edge directory -- including binaries built
  # before this change -- filters on `PerEdgeRecFileExt`, so a `.octime` file
  # is invisible to them and the record format stays at v3. Best-effort: a
  # sidecar that fails to write, or is lost, simply means "no witness", and
  # the lookup degrades exactly as a pre-witness record does.
  #
  # DURABILITY: the `.rec` renames first and the `.octime` second, neither is
  # fsynced, and a sidecar write that fails is swallowed below. A crash in
  # that window leaves a record with no witness. For a regular-file output
  # that silently reopens the corruption hole until the edge next executes;
  # for a directory it fails closed. The store is a cache and is not crash-
  # durable by design (see `writeRecFileAtomically`'s "fsync-less" note), so
  # this is consistent with the rest of it -- but it is a real gap, not an
  # oversight, and a mode that needs durable evidence needs payload-backed
  # records rather than metadata-only ones.
  #
  # CRITICAL: a WITNESS-FREE record must never overwrite a witnessed sidecar.
  # Records are republished by writers that never saw the filesystem: the
  # cache daemon decodes a record out of its shared-memory slot -- a plain
  # record frame, witness-free by construction -- and republishes it here,
  # and the peer cache installs a remote record the same way. Writing
  # all-zero witnesses on their behalf destroyed the evidence within seconds
  # of it being recorded, silently reverting every shm-eligible edge to the
  # size+mtime comparison this whole mechanism replaces. Such a republish
  # does not touch the outputs, so the existing witness still describes them:
  # carry it forward, re-stamped against the new record sequence.
  if records.len > 0:
    let witnessPath = dirPath / witnessFileName(finalName.splitFile.name)
    let merged = witnessesOf(records)
    var payload: seq[byte] = @[]
    var write = true
    if merged.any:
      payload = encodeWitnesses(merged.witnesses, writeSequence)
    else:
      # Carry forward only a sidecar that genuinely belonged to the record we
      # are replacing; anything else is stale and must not be resurrected.
      #
      # NOTE on peer installs: `installActionBundle` writes a REMOTE record
      # here, whose output metadata describes another machine's bytes, and
      # this staples the LOCAL witness onto it. That is sound -- the witness
      # still describes the local outputs, and the change time is monotone
      # and kernel-owned, so a carried witness is never LESS restrictive than
      # having none -- but it does mean that for a peer-installed record a
      # hit no longer asserts "the local outputs match this record's blobs",
      # only "the local outputs are unchanged since this machine last
      # produced them".
      var carried = false
      if priorWriteSequence != 0'u64 and fileExists(extendedPath(witnessPath)):
        try:
          let prior = decodeWitnesses(bytes(readFile(witnessPath)))
          if prior.recordWriteSequence == priorWriteSequence and
              prior.witnesses.len > 0:
            payload = encodeWitnesses(prior.witnesses, writeSequence)
            carried = true
        except OSError, IOError, EnvelopeError:
          discard
      if not carried:
        # No witness to write and none to keep: drop any stale sidecar so a
        # later reader cannot pair it with an unrelated record.
        write = false
        if fileExists(extendedPath(witnessPath)):
          try: removeFile(extendedPath(witnessPath))
          except OSError: discard
    if write:
      let witnessTmp = tmpPath & WitnessFileExt
      try:
        writeFile(extendedPath(witnessTmp), byteString(payload))
        moveFile(extendedPath(witnessTmp), extendedPath(witnessPath))
      except OSError, IOError:
        if fileExists(extendedPath(witnessTmp)):
          try: removeFile(extendedPath(witnessTmp))
          except OSError: discard

    # The determinism sidecar. Same carry-forward rule as the witness one and
    # for the same reason: the cache daemon and the peer-cache installer both
    # republish records decoded from a plain frame, which is
    # determinism-metadata-free by construction. Letting such a republish
    # write an UNDECLARED sidecar would erase the class of a `volatile` entry
    # seconds after it was recorded, and the entry would then be served
    # forever with no retention at all -- the exact defect this metadata
    # exists to prevent, arrived at silently.
    let detPath = dirPath / determinismFileName(finalName.splitFile.name)
    let meta = metaOf(records)
    var detPayload: seq[byte] = @[]
    var writeDet = false
    if meta.declared:
      detPayload = encodeDeterminism(meta, writeSequence)
      writeDet = true
    elif priorWriteSequence != 0'u64 and fileExists(extendedPath(detPath)):
      try:
        let prior = decodeDeterminism(bytes(readFile(detPath)))
        if prior.meta.declared and
            prior.recordWriteSequence == priorWriteSequence:
          detPayload = encodeDeterminism(prior.meta, writeSequence)
          writeDet = true
      except OSError, IOError, EnvelopeError:
        discard
    if writeDet:
      let detTmp = tmpPath & DeterminismFileExt
      try:
        writeFile(extendedPath(detTmp), byteString(detPayload))
        moveFile(extendedPath(detTmp), extendedPath(detPath))
      except OSError, IOError:
        if fileExists(extendedPath(detTmp)):
          try: removeFile(extendedPath(detTmp))
          except OSError: discard
    elif fileExists(extendedPath(detPath)):
      # No metadata to write and none worth keeping: drop the stale sidecar
      # so no later reader pairs it with an unrelated record.
      try: removeFile(extendedPath(detPath))
      except OSError: discard

proc capRecFiles(cache: ActionCache; dirPath: string): seq[string]
    {.discardable.} =
  ## Bound the per-edge directory: keep at most `MaxRecFilesPerEdge` `.rec`
  ## files, evicting the OLDEST by DURABLE write sequence beyond the cap (the
  ## same total order the lookup uses, so eviction never drops a record the
  ## lookup would have considered newest). Distinct path-sets are few, so this
  ## rarely fires; it guarantees the disk store stays small even if an
  ## adversarial stream of distinct path-sets accumulates.
  ##
  ## This is also where the §5.5 C1 newest-alias is (re)published, for two
  ## reasons. It is the LAST step of every publish, so an alias written here
  ## cannot be invalidated by an eviction that follows it -- §8.2's "cap
  ## before insert" rule applied to the alias. And it already reads every
  ## container's durable write sequence in order to decide what to evict, so
  ## it can name the newest from GROUND TRUTH rather than from the assumption
  ## that the record just written is the newest -- an assumption that is
  ## false whenever a sibling with a higher sequence was published
  ## concurrently, or by a binary that has never heard of the alias.
  ##
  ## Returns the strong-fingerprint hex of every container it UNLINKED, so the
  ## caller can follow each unlink with a Tier-2 tombstone. §8.2 requires that
  ## order, and it requires the cap to run BEFORE the insert for the record
  ## just written, so a record can never be published to the index and then
  ## immediately capped by its own writer.
  var entries: seq[tuple[seq: uint64; strongHex, path: string]] = @[]
  for kind, path in walkDir(extendedPath(dirPath)):
    if kind == pcFile and path.endsWith(PerEdgeRecFileExt):
      var writeSequence = 0'u64
      try:
        writeSequence = decodePerEdgeFileWithSeq(bytes(readFile(path))).writeSequence
      except OSError, IOError:
        discard
      entries.add((seq: writeSequence, strongHex: path.splitFile.name,
        path: path))
  # Reap sidecars whose `.rec` is gone BEFORE the cap check. An older binary's
  # eviction removes the record without knowing the sidecar exists, and an
  # edge directory almost never holds more than `MaxRecFilesPerEdge` files --
  # so a reap placed after the early return below would essentially never run.
  for kind, path in walkDir(extendedPath(dirPath)):
    if kind == pcFile and
        (path.endsWith(WitnessFileExt) or path.endsWith(DeterminismFileExt)):
      let owner = path.parentDir / (path.splitFile.name & PerEdgeRecFileExt)
      if not fileExists(extendedPath(owner)):
        try:
          removeFile(extendedPath(path))
        except OSError:
          discard
  # The SAME total order the union read and the lookup use: `(writeSequence,
  # strongFpHex)`. Sorting unconditionally (rather than only above the cap)
  # is what lets the alias below name the newest survivor in every case.
  entries.sort(proc (a, b: tuple[seq: uint64; strongHex, path: string]): int =
    result = cmp(a.seq, b.seq)
    if result == 0:
      result = cmp(a.strongHex, b.strongHex))
  if entries.len > MaxRecFilesPerEdge:
    for i in 0 ..< entries.len - MaxRecFilesPerEdge:
      try:
        removeFile(entries[i].path)
        result.add(entries[i].strongHex)
      except OSError:
        discard
      # Drop the evicted record's sidecars too, or they leak.
      for sidecar in [entries[i].path.parentDir /
                        witnessFileName(entries[i].strongHex),
                      entries[i].path.parentDir /
                        determinismFileName(entries[i].strongHex)]:
        if fileExists(extendedPath(sidecar)):
          try:
            removeFile(extendedPath(sidecar))
          except OSError:
            discard
    entries = entries[entries.len - MaxRecFilesPerEdge .. ^1]
  if entries.len == 0:
    return
  var alias = NewestAlias(
    writeSequence: entries[^1].seq,
    strongName: entries[^1].strongHex & PerEdgeRecFileExt)
  for entry in entries:
    alias.members.add(entry.strongHex & PerEdgeRecFileExt)
  alias.members.sort()
  publishNewestAlias(dirPath, alias)


proc migrateLegacyFile(cache: ActionCache; weak: ContentDigest) =
  ## If a pre-AC-1b single FILE sits at `hot-records/<key>` (the same path the
  ## AC-1b directory needs), fold its records into per-path-set `.rec` files and
  ## remove the file, so the directory layout can take over cleanly.
  let legacyPath = cache.legacyHotRecordPath(weak)
  let ep = extendedPath(legacyPath)
  if not fileExists(ep) or dirExists(ep):
    return
  var legacyRecords: seq[ActionResultRecord]
  try:
    legacyRecords = decodePerEdgeFile(bytes(readFile(ep)))
  except OSError, IOError:
    legacyRecords = @[]
  # Remove the file FIRST so `createDir` on the same path can succeed; the
  # records are held in memory and re-published as `.rec` files below.
  try:
    removeFile(ep)
  except OSError:
    return
  let dirPath = cache.perEdgeDirPath(weak)
  var byStrong = initTable[string, seq[ActionResultRecord]]()
  for rec in legacyRecords:
    byStrong.mgetOrPut(digestKey(rec.strongFingerprint), @[]).add(rec)
  for strongKey, recs in byStrong:
    cache.writeRecFileAtomically(dirPath,
      recFileNameForStrong(recs[0].strongFingerprint), recs)
  # Migration rewrites the whole directory, so it must leave a current
  # newest-alias behind like any other publish; otherwise every read of a
  # just-migrated edge takes the union fallback until the edge is next
  # recorded.
  if byStrong.len > 0:
    discard cache.capRecFiles(dirPath)

# --- Tier-2 index writes (Action-Cache-Per-Edge-Store.md §9, §8.2) ---------

proc indexRecord(cache: ActionCache; weak, strong: ContentDigest) =
  ## Publish ONE reference into the shared-memory index. This is the engine's
  ## ENTIRE Tier-2 write cost: a probe-run walk plus, at most, one arena bump
  ## and one CAS. Re-recording an unchanged path-set stops at the liveness
  ## probe and writes nothing at all.
  ##
  ## There is no size test here, and that absence is the point. The tier this
  ## replaces refused any record whose encoded form exceeded a 256 B inline
  ## slot — 93% of a measured developer cache — and the refusal could not
  ## converge: the submit always failed, so the shared read could never hit, so
  ## the warm-on-miss path re-encoded the same doomed record on the next build.
  ## An 84-byte reference is the same 84 bytes whatever the record weighs.
  if cache.shm == nil or not cache.shm.enabled: return
  discard cache.shm.idx.insertRecord(weak, strong)

proc indexEvictByHex(cache: ActionCache; weak: ContentDigest;
                     strongHexes: openArray[string]) =
  ## §8.2's "unlink before tombstone": the `.rec` file is removed BEFORE the
  ## tombstone for its key is inserted. The window in between shows a live key
  ## that does not resolve, which the read path turns into the union fallback —
  ## correct. The reverse order would show a complete-looking edge missing a
  ## file that is still on disk, which could turn a hit into a miss.
  ##
  ## The evicted key is recovered from the INDEX rather than reconstructed from
  ## the file name: a `.rec` name carries only the strong fingerprint's hex, not
  ## its algorithm or domain, and a tombstone whose bytes are not a pure
  ## function of the element it retires would simply fail to retire it.
  if cache.shm == nil or not cache.shm.enabled: return
  if strongHexes.len == 0: return
  for elem in cache.shm.idx.enumerateEdge(weak).liveStrong:
    if toHex(elem.bytes) in strongHexes:
      discard cache.shm.idx.evictRecord(weak, elem)

proc indexBypassOnce(cache: ActionCache) =
  ## §6.8. An engine that declined the index still writes Tier 1, so before its
  ## first write it says so in the chain — if a chain exists at all. A nonzero
  ## `bypassWrites` voids every completeness claim in the chain until the next
  ## flatten, so the opt-out cannot leave another engine trusting a claim this
  ## one has quietly falsified.
  if cache.shm == nil or cache.shm.enabled or cache.shm.bypassNoted: return
  cache.shm.bypassNoted = true
  if cache.shm.idx != nil: cache.shm.idx.noteBypassWrite()

proc writePerEdgeRecord(cache: ActionCache; record: ActionResultRecord) =
  ## Publish ONE path-set's record into its edge directory
  ## `hot-records/<key>/<strongFp>.rec` via temp-file + atomic rename, WITHOUT
  ## touching any sibling `.rec` from a distinct concurrent path-set (AC-1b).
  ## Same strong fingerprint → same filename → convergence (an overwrite, never
  ## an accumulation). Bounded by `MaxRecFilesPerEdge`.
  ##
  ## The DURABLE Tier-1 write is unchanged and remains the backstop. What
  ## follows it is §9's three steps, in §8.2's order: publish before reference
  ## (the rename completes before the element is inserted, so a reader that
  ## sees an element finds the file); cap before insert (so a record can never
  ## be published to the index and then immediately capped by its own writer);
  ## unlink before tombstone.
  cache.indexBypassOnce()
  cache.migrateLegacyFile(record.weakFingerprint)
  let dirPath = cache.perEdgeDirPath(record.weakFingerprint)
  cache.writeRecFileAtomically(dirPath,
    recFileNameForStrong(record.strongFingerprint), @[record])
  let evicted = cache.capRecFiles(dirPath)
  cache.indexEvictByHex(record.weakFingerprint, evicted)
  cache.indexRecord(record.weakFingerprint, record.strongFingerprint)

proc writePerEdgeRecords*(cache: ActionCache; weak: ContentDigest;
                         records: openArray[ActionResultRecord]) =
  ## Publish a set of records for `weak`, grouping by strong fingerprint so each
  ## path-set lands in its own `<nonce>.rec` file (temp + atomic rename). This
  ## NEVER clobbers a sibling path-set written by a concurrent build; distinct
  ## strong fingerprints target distinct files and identical ones converge on
  ## the same file. Used by the AC-2b daemon persist bridge and by internal
  ## record installs. Bounded by `MaxRecFilesPerEdge`.
  cache.migrateLegacyFile(weak)
  let dirPath = cache.perEdgeDirPath(weak)
  var byStrong = initOrderedTable[string, seq[ActionResultRecord]]()
  for rec in records:
    if rec.weakFingerprint != weak:
      continue
    byStrong.mgetOrPut(digestKey(rec.strongFingerprint), @[]).add(rec)
  for _, recs in byStrong:
    cache.writeRecFileAtomically(dirPath,
      recFileNameForStrong(recs[0].strongFingerprint), recs)
  if byStrong.len > 0:
    cache.indexBypassOnce()
    let evicted = cache.capRecFiles(dirPath)
    cache.indexEvictByHex(weak, evicted)
    for _, recs in byStrong:
      cache.indexRecord(weak, recs[0].strongFingerprint)

proc hotInputKey(input: FileFingerprint): string =
  input.path & "\0" & $ord(input.policy) & "\0" &
    $ord(input.metadata.kind) & "\0" & $input.metadata.sizeBytes & "\0" &
    $input.metadata.mtimeNs

proc envInputChanged*(record: ActionResultRecord; resolver: EnvResolver;
                     changedName: var string): bool =
  ## Has any observed environment variable moved since the action ran?
  ##
  ## This is the whole point of `mcapObservedEnv` reaching the consumer: a
  ## build that read `SOURCE_DATE_EPOCH` must re-run when it changes and must
  ## NOT re-run when it does not. Both directions matter -- always answering
  ## "changed" would make every action that reads a variable uncacheable,
  ## which is the same damage as a stale hit arriving from the other side.
  ##
  ## A record with no env inputs is unaffected and never consults the
  ## resolver, so nothing that existed before this feature changes behaviour.
  ## A record that HAS them and no resolver is CHANGED: the caller could not
  ## establish that the inputs still hold, and an unnecessary re-run is
  ## recoverable where a stale result is not.
  changedName = ""
  if record.envInputs.len == 0:
    return false
  if resolver == nil:
    changedName = record.envInputs[0].name & " (no environment resolver)"
    return true
  for env in record.envInputs:
    let current = resolver(env.name)
    # `present` is compared as well as `value`: unset and set-to-empty are
    # different states, and a program that branches on `is None` sees the
    # difference even though both render as "".
    if current.present != env.present or current.value != env.value:
      changedName = env.name
      return true
  false

proc warmIndexFromDisk(cache: ActionCache; weak: ContentDigest;
                       records: openArray[ActionResultRecord];
                       everyContainerDecoded: bool) =
  ## §8 step 5's second half. A union fallback has just established the edge's
  ## true contents, so publish them: a `record` element for every record read,
  ## and — ONLY after all of them succeed — the `edge-complete` element.
  ##
  ## "Records before completeness" is §8.2 and it is the rule the whole
  ## index-first read rests on. An `edge-complete` element that outran one of
  ## its records would direct a later reader at an incomplete candidate set,
  ## and an incomplete candidate set is how a newest-corrupt-rejects case
  ## becomes a hit from an older record. The completeness claim is a claim
  ## about the DIRECTORY, so a container this binary could not decode also
  ## withholds it: the claim would be false, and a false claim is the one
  ## failure mode this tier is not allowed to have.
  if cache.shm == nil or not cache.shm.enabled: return
  var everyInsert = true
  for record in records:
    if cache.shm.idx.insertRecord(weak, record.strongFingerprint) == isSaturated:
      everyInsert = false
  if everyInsert and everyContainerDecoded:
    discard cache.shm.idx.insertEdgeComplete(weak)

type
  IndexArmKind = enum
    ## What §8's index-first arm was able to say about an edge.
    iakUnavailable
      ## The index cannot answer. The caller MUST take a path that does not
      ## depend on it; Tier 1 is authoritative and unconditionally correct.
    iakNegative
      ## The index is complete and holds NO reference for this edge, so the
      ## edge has no record. Reached with zero filesystem operations.
    iakCandidates
      ## The index resolved the edge's containers. `entries` holds every one
      ## of them, ordered OLDEST→NEWEST by §5.3's total order.

  IndexedCandidates = object
    kind: IndexArmKind
    dirPath: string
    entries: seq[tuple[writeSequence: uint64; strongHex, fileName: string;
                       raw: seq[byte]]]

proc indexedCandidatesForWeak(cache: ActionCache; weak: ContentDigest):
    IndexedCandidates =
  ## §8 steps 1-4, up to but NOT including record decoding.
  ##
  ## Every container the index references is read and ORDERED here, and none
  ## is interpreted. That split is the point: §5.3's order is
  ## `(writeSequence, strongHex)`, the sequence is an 8-byte trailer and the
  ## hex is the file name, so ordering the candidates costs no record decode
  ## at all (see `scanPerEdgeFileWriteSequence`). Which candidates a caller
  ## then decodes is the caller's decision, and it is where §5.5 C1's "cost
  ## proportional to the candidates it EVALUATES" is either honoured or lost.
  ##
  ## An unresolvable reference is a MISS, never an error and never a false
  ## hit: it is counted and the caller falls back to the path that does not
  ## depend on the index at all.
  if cache.shm == nil or not cache.shm.enabled:
    return IndexedCandidates(kind: iakUnavailable)
  let view = cache.shm.idx.enumerateEdge(weak)
  if not view.attached or not view.complete:
    return IndexedCandidates(kind: iakUnavailable)
  if view.liveStrong.len == 0:
    inc actionIndexNegativeHits
    return IndexedCandidates(kind: iakNegative)
  result = IndexedCandidates(kind: iakCandidates,
    dirPath: cache.perEdgeDirPath(weak))
  for strong in view.liveStrong:
    let fileName = recFileNameForStrong(strong)
    let read = readRecBytes(result.dirPath, fileName)
    if not read.ok:
      cache.shm.idx.noteUnresolvedReference()
      inc actionIndexUnresolvedRefs
      return IndexedCandidates(kind: iakUnavailable)
    result.entries.add((
      writeSequence: scanPerEdgeFileWriteSequence(read.raw),
      strongHex: fileName.splitFile.name,
      fileName: fileName,
      raw: read.raw))
  # The SAME total order §5.3 makes semantic, recovered from the containers'
  # own trailers. The index deliberately does not carry the write sequence
  # (§12.E): carrying it would make the element bytes change on every
  # convergent rewrite of one path-set, so the element count would grow with
  # WRITES instead of with distinct keys — the one property the structure is
  # chosen for.
  result.entries.sort(proc (a, b: tuple[writeSequence: uint64;
                                        strongHex, fileName: string;
                                        raw: seq[byte]]): int =
    result = cmp(a.writeSequence, b.writeSequence)
    if result == 0:
      result = cmp(a.strongHex, b.strongHex))
  inc actionIndexResolvedHits

proc indexedRecordsForWeak(cache: ActionCache; weak: ContentDigest):
    Option[seq[ActionResultRecord]] =
  ## §8 steps 1-4: the index-first arm.
  ##
  ## `none` means "the index cannot answer for this edge" and the caller MUST
  ## take the Tier-1 union read, which is unconditionally correct because
  ## Tier 1 is authoritative. `some(@[])` is the answer this tier exists for:
  ## the edge is known to have NO record, reached with ZERO filesystem
  ## operations — no `dirExists`, no directory enumeration, no `open`. That is
  ## the largest single effect, because it applies to every cache miss, the
  ## dominant case in a cold build.
  ##
  ## A positive answer still opens and decodes the containers it resolves: the
  ## decision needs the recorded input paths and their metadata, and those are
  ## 78-81% of record bytes — the very bytes the index does not hold. What it
  ## saves on a positive lookup is the directory enumeration, not the reads.
  ##
  ## An unresolvable reference is a MISS, never an error and never a false hit:
  ## it is counted and the caller falls back to the path that does not depend
  ## on the index at all.
  let candidates = cache.indexedCandidatesForWeak(weak)
  case candidates.kind
  of iakUnavailable:
    return none(seq[ActionResultRecord])
  of iakNegative:
    return some(newSeq[ActionResultRecord]())
  of iakCandidates:
    discard
  var records: seq[ActionResultRecord] = @[]
  var seenStrong = initHashSet[string]()
  for entry in candidates.entries:
    let container = decodeRecContainer(candidates.dirPath, entry.fileName,
      entry.raw)
    for record in container.records:
      let key = digestKey(record.strongFingerprint)
      if key notin seenStrong:
        seenStrong.incl(key)
        records.add(record)
  some(records)

proc indexedNewestRecordForWeak(cache: ActionCache; weak: ContentDigest):
    tuple[kind: IndexArmKind; found: bool; record: ActionResultRecord] =
  ## §8's index arm answering the ONE question a warm consultation asks:
  ## which record does the newest-wins rule select? — and decoding only the
  ## containers it has to look at to answer it.
  ##
  ## §5.5 C1 is normative ("the cost of a consultation MUST be proportional
  ## to the candidates it EVALUATES, not to the candidates the edge has") and
  ## the newest-alias accelerator has honoured it since it was written. The
  ## index arm did not: it runs FIRST, and it decoded every container the
  ## edge has before discarding all but one. On a developer cache that is
  ## most of the work a no-op does — measured on a warm zlib CMake no-op,
  ## 103 containers decoded across 37 edges, 4.36 MB, of which the 37 that
  ## were used are 427 KB. The other 90.2% was read, slice-copied, checksummed,
  ## decoded, deduped and dropped. This walks the SAME order from the other
  ## end and stops.
  ##
  ## WHY STOPPING IS THE SAME ANSWER. `indexedRecordsForWeak` concatenates
  ## each container's records in oldest→newest order, dropping any record
  ## whose strong fingerprint an EARLIER container already contributed, and
  ## the caller then scans that list backwards for the first weak match. A
  ## container's records all carry the strong fingerprint the container is
  ## NAMED for (`recFileNameForStrong`), so two containers in one edge
  ## directory contribute disjoint strong fingerprints and the cross-container
  ## dedup can never drop a newer record on account of an older one. The
  ## concatenation is therefore a per-container dedup pasted end to end, and
  ## scanning it backwards is scanning containers newest→oldest, each one's
  ## deduped records backwards. That is what this loop does.
  ##
  ## Both premises are CHECKED rather than assumed, because a cache root is
  ## shared with other binaries and neither is this reader's to guarantee:
  ##
  ##   * a container whose records do not all carry its own name's strong
  ##     fingerprint is misfiled, so the disjointness argument does not hold
  ##     for it; and
  ##   * `scanPerEdgeFileWriteSequence` orders on a sequence read without
  ##     decoding, which a frame this binary cannot decode makes larger than
  ##     the one the full decode reports — so the order this walk used may
  ##     not be §5.3's.
  ##
  ## Either one returns `iakUnavailable`, which sends the caller to the alias
  ## read and then to the union read: the same degradation an unresolvable
  ## reference already takes, and unconditionally correct because Tier 1 is
  ## authoritative.
  ##
  ## WHAT THAT DOES TO THE §11 ROWS, said out loud because a row that
  ## double-counts silently is worse than one that does not exist. Both
  ## refusals happen AFTER `indexedCandidatesForWeak` has counted the
  ## resolved hit, so an edge that trips one contributes to `resolvedHits`
  ## and then to `unionFallbacks`. The two rows stop partitioning the
  ## consultations exactly in the states this proc declines to answer in —
  ## which is the same thing a climbing `unresolvedReferences` already
  ## signals, and on a healthy root neither moves.
  let candidates = cache.indexedCandidatesForWeak(weak)
  if candidates.kind != iakCandidates:
    return (kind: candidates.kind, found: false,
            record: ActionResultRecord())
  for i in countdown(candidates.entries.high, 0):
    let entry = candidates.entries[i]
    let container = decodeRecContainer(candidates.dirPath, entry.fileName,
      entry.raw)
    if container.writeSequence != entry.writeSequence:
      return (kind: iakUnavailable, found: false,
              record: ActionResultRecord())
    var seenStrong = initHashSet[string]()
    var deduped: seq[ActionResultRecord] = @[]
    for record in container.records:
      if toHex(record.strongFingerprint.bytes) != entry.strongHex:
        return (kind: iakUnavailable, found: false,
                record: ActionResultRecord())
      let key = digestKey(record.strongFingerprint)
      if key notin seenStrong:
        seenStrong.incl(key)
        deduped.add(record)
    for j in countdown(deduped.high, 0):
      if deduped[j].weakFingerprint == weak:
        return (kind: iakCandidates, found: true,
                record: hotMetadataRecord(deduped[j]))
  (kind: iakCandidates, found: false, record: ActionResultRecord())

proc unionReadEdge(cache: ActionCache; weak: ContentDigest):
    seq[ActionResultRecord] =
  ## §8 step 5: the full Tier-1 read, followed by the index warm. Every path
  ## that cannot be answered from the index lands here, and it is the only
  ## place the index learns what an edge holds.
  inc actionIndexUnionFallbacks
  var undecodable = 0
  result = cache.loadPerEdgeRecords(weak, warmNewestAlias = true,
    undecodableContainers = addr undecodable)
  cache.warmIndexFromDisk(weak, result, undecodable == 0)

proc readHotRecord*(cache: var ActionCache; weak: ContentDigest):
    tuple[found: bool; record: ActionResultRecord] =
  ## Read the newest metadata-only view of the edge's record.
  ##
  ## Index first (§8): an edge the index reports complete and empty is answered
  ## from mapped memory with no syscall at all, which is what makes the
  ## engine's batch up-to-date scan short-circuit on the first probe with no
  ## record. An edge it reports complete and non-empty is answered from exactly
  ## the referenced containers, with no directory enumeration.
  ##
  ## Otherwise the C1 newest-alias accelerator (§5.5) still applies: it answers
  ## the same question from ONE container and returns `none` — falling through
  ## to the union read — whenever it cannot prove that container is the newest.
  ## The union read is last and is unconditionally correct.
  timedPerEdgeRecordLoad:
    let indexedNewest = cache.indexedNewestRecordForWeak(weak)
    case indexedNewest.kind
    of iakNegative:
      return (found: false, record: ActionResultRecord())
    of iakCandidates:
      if indexedNewest.found:
        return (found: true, record: indexedNewest.record)
      return (found: false, record: ActionResultRecord())
    of iakUnavailable:
      discard
    let viaAlias = cache.loadNewestPerEdgeRecordsViaAlias(weak)
    if viaAlias.isSome:
      let aliasRecords = viaAlias.get()
      for i in countdown(aliasRecords.high, 0):
        if aliasRecords[i].weakFingerprint == weak:
          return (found: true, record: hotMetadataRecord(aliasRecords[i]))
    let records = cache.unionReadEdge(weak)
    for i in countdown(records.high, 0):
      if records[i].weakFingerprint == weak:
        return (found: true, record: hotMetadataRecord(records[i]))
    return (found: false, record: ActionResultRecord())

proc appendActionResultRecord*(cache: var ActionCache;
                               record: ActionResultRecord) {.gcsafe.} =
  ## Public bridge so the peer-cache reader can install a peer-fetched
  ## record into the local action cache. Writes the edge's per-edge file
  ## (temp + atomic rename), never an append. Idempotency is bounded by
  ## `MaxRecordsPerWeakFingerprint`; re-installing an identical record
  ## leaves the file's record set unchanged.
  {.cast(gcsafe).}:
    cache.writePerEdgeRecord(record)

proc loadRecordsForWeak(cache: ActionCache; weak: ContentDigest):
    seq[ActionResultRecord] =
  ## Full-record candidate set for one edge, ordered OLDEST→NEWEST so the
  ## decision loop iterating in reverse considers the truly newest path-set
  ## first.
  ##
  ## Index first (§8): when the chain reports the edge complete, the candidate
  ## set comes from the index and the reads are directed at exactly the
  ## referenced files. Because the completeness claim means the index's key set
  ## for this edge EQUALS the directory's, that candidate set and that order
  ## are exactly what a Tier-1 union read would have produced — so the
  ## hit/miss, strong-fingerprint and newest-corrupt-rejects outcomes are
  ## byte-identical to the Tier-1-only decision. Otherwise, or on any
  ## unresolvable reference, the union read of §5.3 answers and warms the
  ## index.
  ##
  ## Either way this is O(records for THIS edge) and never a whole-cache scan.
  timedPerEdgeRecordLoad:
    let indexed = cache.indexedRecordsForWeak(weak)
    let candidates =
      if indexed.isSome: indexed.get()
      else: cache.unionReadEdge(weak)
    for record in candidates:
      if record.weakFingerprint == weak:
        result.add(record)
        if result.len > MaxRecFilesPerEdge:
          result = result[result.len - MaxRecFilesPerEdge .. ^1]

proc scanHotIndexMetadataInputsUnchanged*(cache: ActionCache;
                                          probes: openArray[HotMetadataProbe];
                                          metadataCache: ptr FileMetadataCache = nil;
                                          envResolvers: openArray[EnvResolver] = []):
                                          HotMetadataScan =
  ## Batch "are all these edges still cache hits" check, served by reading
  ## each probe's authoritative `hot-records/<key>` files instead of scanning
  ## a global index. Cost is O(records for the probed edges), page-cached,
  ## never a whole-cache scan.
  ##
  ## `hmssHit` iff, for EVERY probe, the NEWEST matching record revalidates:
  ## its observed environment still reads the same, every recorded input's
  ## metadata is unchanged, and its declared outputs on disk are still the
  ## ones it describes. `hmssMissingRecord` if any probe has no matching
  ## record (or only an unservable one); `hmssInputChanged` /
  ## `hmssOutputChanged` name which half moved;
  ## `hmssPolicyNeedsContentHash` if a probe asked for a policy this scan is
  ## not entitled to decide.
  ##
  ## TWO THINGS THIS PROC MUST NOT DO, both of which it used to.
  ##
  ## 1. IT MUST NOT DECIDE A POLICY IT CANNOT CHECK. Everything below
  ##    compares `FileMetadata`; `ffpChecksum`'s criterion is the content
  ##    hash, which is not in `metadata`. See `MetadataValidatedPolicies` for
  ##    the measurement. The refusal is FIRST, before any record is read: the
  ##    scan has no answer for such a probe, so there is nothing to be gained
  ##    by looking.
  ##
  ## 2. IT MUST NOT QUANTIFY OVER THE EDGE'S WHOLE HISTORY. It used to check
  ##    EVERY matching record and fail the probe if ANY of them had a changed
  ##    input — a ∀ where both this docstring and `lookupActionResultImpl`'s
  ##    candidate walk say ∃. `loadRecordsForWeak` returns up to
  ##    `MaxRecFilesPerEdge` (8) records — the edge's history — so a single
  ##    superseded record poisoned the edge permanently. Not unsound (strictly
  ##    stricter, so only false MISSES), but it made this whole-graph shortcut
  ##    useless on any edge that had ever been rebuilt: measured on a zlib
  ##    graph, this arm and the per-record arm disagreed on 31 of 37 edges,
  ##    and agreed 300/300 only on a fresh cache with one record per edge —
  ##    i.e. it worked in CI and nowhere else.
  ##
  ##    The record it now checks is the NEWEST matching one, which is exactly
  ##    the record `readHotRecord` (and therefore the per-record arm of the
  ##    same whole-graph shortcut) selects. That is deliberate: the two arms
  ##    of `tryFastNoopCacheHits` are chosen by a flag the caller sets for
  ##    reasons that have nothing to do with cache validity, so a verdict
  ##    that depends on which one ran is the defect, whichever way it leans.
  ##    It stays fail-closed with respect to the scheduler, whose ∃ walk over
  ##    all candidates can only turn a miss here into a hit there.
  ##
  ## Issue #382 defects 1 and 2.
  if probes.len == 0:
    return HotMetadataScan(status: hmssHit)
  var checkedInputs = 0
  var totalRecords = 0
  for probeIndex, probe in probes:
    if probe.policy notin MetadataValidatedPolicies:
      return HotMetadataScan(status: hmssPolicyNeedsContentHash,
        recordCount: totalRecords, checkedInputCount: checkedInputs,
        detail: "fingerprint policy " & $probe.policy &
          " is validated by content hash, which this metadata-only scan " &
          "does not compute")
    let records = cache.loadRecordsForWeak(probe.weakFingerprint)
    totalRecords += records.len
    # NEWEST-FIRST, because `loadRecordsForWeak` yields OLDEST→NEWEST and the
    # newest matching record is the one this scan decides on (see 2. above).
    var newest = -1
    for i in countdown(records.high, 0):
      if records[i].weakFingerprint == probe.weakFingerprint and
          records[i].policy == probe.policy:
        newest = i
        break
    if newest < 0:
      return HotMetadataScan(status: hmssMissingRecord,
        recordCount: totalRecords, checkedInputCount: checkedInputs)
    let record = records[newest]
    # A record with nothing in it to check is not a hit. Reported as
    # `hmssMissingRecord` rather than a new status because that is what it
    # means to the caller — there is no usable record here — and it is
    # already the status that sends the graph to the full scheduler, where
    # the per-edge refusal states the reason. See
    # `HotMetadataProbe.refuseRecordWithNoInputs`.
    if probe.refuseRecordWithNoInputs and record.inputs.len == 0 and
        record.envInputs.len == 0:
      return HotMetadataScan(status: hmssMissingRecord,
        recordCount: totalRecords, checkedInputCount: checkedInputs)
    # M10 — the OBSERVED ENVIRONMENT has to be checked on this path too.
    # It is the whole-graph "everything is already up to date" shortcut,
    # so a record whose environment moved and is not caught HERE is served
    # as a hit without any other check ever running. `envInputChanged`
    # fails closed when no resolver was supplied for this probe.
    var changedEnv = ""
    let resolver =
      if probeIndex < envResolvers.len: envResolvers[probeIndex]
      else: nil
    if envInputChanged(record, resolver, changedEnv):
      return HotMetadataScan(status: hmssInputChanged,
        recordCount: totalRecords, checkedInputCount: checkedInputs)
    timedRecordedInputRevalidation:
      for input in record.inputs:
        inc checkedInputs
        if fingerprintRecordedMetadata(input.path, input.metadata,
            metadataCache) != input.metadata:
          return HotMetadataScan(status: hmssInputChanged,
            recordCount: totalRecords, checkedInputCount: checkedInputs)
    # Same rule as `lookupActionResultImpl`: unchanged inputs are only
    # half the hit condition. The declared outputs on disk must still be
    # the ones this record describes (Incremental-Invalidation.md
    # §"Minimum check set" Step 3.3). Without this the whole-build fast
    # path would keep accepting an artifact that was overwritten after
    # the build produced it.
    let outputMismatch = outputStateMismatch(record, probe.outputRoot)
    if outputMismatch.len > 0:
      return HotMetadataScan(status: hmssOutputChanged,
        recordCount: totalRecords, checkedInputCount: checkedInputs,
        detail: outputMismatch)
  HotMetadataScan(status: hmssHit, recordCount: totalRecords,
    checkedInputCount: checkedInputs)

const LegacyGlobalStoreFiles = [
  "action-results.records",
  "action-results.hot.records",
  "action-results.hot.index"]

proc removeLegacyGlobalStore(root: string) =
  ## One-time ignore-then-delete of the pre-existing global append-log files
  ## (Action-Cache-Per-Edge-Store.md §3). Best-effort: a busy concurrent
  ## reader on another host/process may still hold one open; a failed unlink
  ## is harmless because the per-edge store is authoritative and the global
  ## files are never read.
  for name in LegacyGlobalStoreFiles:
    let path = root / name
    if fileExists(extendedPath(path)):
      try:
        removeFile(extendedPath(path))
      except OSError:
        discard

# --- Tier-2 shared-memory index wiring (Action-Cache-Per-Edge-Store.md §6) --
#
# The index is OPTIONAL and BEST-EFFORT (§6.8, §10). `openActionCache` attempts
# to attach the chain for the root; ANY failure (non-POSIX, permission, a stale
# post-reboot chain that could not be recreated, opted out via env) leaves
# `cache.shm` disabled and the engine runs pure Tier-1 — the identical
# decision. A build NEVER fails or blocks because the index is unavailable.
#
# There is no process to exist. No ownership election, no PID or heartbeat
# arbitration, no stale-owner takeover, no self-reaping, no respawn-on-submit
# and no launch-coordination protocol: every participant is an engine, and
# every shared-memory operation an engine performs is an insert into a
# structure whose merge is set union.

const
  ShmDisableEnv = "REPRO_ACTION_CACHE_SHM"
    ## §6.8's opt-out. Set to "0"/"off"/"false"/"no" to force pure Tier-1.
    ## Such an engine still writes Tier 1, so it bumps `bypassWrites` in the
    ## chain before its first write if a chain exists — see `indexBypassOnce`.

const LegacyRingTierFiles = ["action-index.ctl"]
const LegacyRingSegmentPrefix = "action-index."

proc removeLegacyRingTier(root: string) =
  ## Ignore-then-delete the shared-memory state of the RETIRED ring tier —
  ## `action-index.ctl` and every `action-index.<gen>.seg` — exactly as this
  ## store already does for the removed global `action-results.*` files.
  ##
  ## Shared-memory state is a cache of a cache, so nothing is migrated: the
  ## shard chain starts empty and warms itself from Tier 1 on the first
  ## lookups. Best-effort; a file that will not unlink is never read again
  ## either way.
  for name in LegacyRingTierFiles:
    let path = root / name
    if fileExists(extendedPath(path)):
      try: removeFile(extendedPath(path))
      except OSError: discard
  try:
    for kind, path in walkDir(extendedPath(root)):
      if kind != pcFile: continue
      let name = path.extractFilename
      if name.startsWith(LegacyRingSegmentPrefix) and name.endsWith(".seg"):
        try: removeFile(path)
        except OSError: discard
  except OSError:
    discard

proc shmTierEnabledByEnv(): bool =
  ## The index is on by default for callers that ask for it; an explicit falsey
  ## env var forces it off.
  let v = getEnv(ShmDisableEnv, "1").toLowerAscii()
  v notin ["0", "off", "false", "no"]

proc attachShmTier(root: string): ShmTier =
  ## Create-or-attach the chain for `root` (§6.1). Best-effort in every
  ## direction. When the caller opted out, the tier is disabled but the chain
  ## handle is still opened if one exists, so `indexBypassOnce` can record the
  ## bypass — an opt-out that left other engines trusting a completeness claim
  ## it had quietly falsified would be an escape hatch that is not safe.
  result = ShmTier(enabled: false)
  when actionIndexSupported:
    let wanted = shmTierEnabledByEnv()
    let idx = openActionIndex(root)
    if idx.attached:
      result.idx = idx
      result.enabled = wanted
      if not wanted:
        result.bypassNoted = true
        idx.noteBypassWrite()

proc openActionCache*(root: string; attachShm = true): ActionCache =
  ## Open the per-edge Tier-1 store for `root`, and — when `attachShm` — the
  ## optional Tier-2 index over it. `attachShm = false` is a pure Tier-1 store
  ## for callers that must not touch shared memory at all (hermetic fixtures,
  ## tools that only inspect the durable files).
  result.root = root
  result.hotRoot = root / "hot-records"
  createDir(extendedPath(result.root))
  createDir(extendedPath(result.hotRoot))
  # One-time cleanup: the old global append-log store and the retired ring
  # tier are both gone. Ignore any pre-existing files of either and delete them
  # on open, so a migrated cache root stops carrying them without a re-init.
  removeLegacyGlobalStore(result.root)
  removeLegacyRingTier(result.root)
  if attachShm:
    result.shm = attachShmTier(root)
  else:
    result.shm = ShmTier(enabled: false)

proc actionIndexCounters*(cache: ActionCache):
    tuple[attached: bool; shards: int; liveElements: uint64;
          growthFailed, unresolvedReferences, bypassWrites: uint64] =
  ## §11's observability surface. On a healthy root `growthFailed`,
  ## `unresolvedReferences` and `bypassWrites` are all zero; a climbing
  ## `unresolvedReferences` means Tier-1 retention and index retirement have
  ## drifted apart. They exist because a silently bypassed accelerator is
  ## indistinguishable from a healthy idle one.
  if cache.shm == nil or cache.shm.idx == nil:
    return
  let idx = cache.shm.idx
  (attached: cache.shm.enabled, shards: idx.shardCount(),
   liveElements: idx.liveElementCount(), growthFailed: idx.growthFailed(),
   unresolvedReferences: idx.unresolvedReferences(),
   bypassWrites: idx.bypassWrites())

proc flattenActionIndex*(cache: ActionCache): bool {.discardable.} =
  ## §6.7's maintenance pass, `flock`-guarded so at most one flattener runs per
  ## root and every other process simply skips it. Not a daemon: no election,
  ## no heartbeat, no long-lived state, and it blocks nothing.
  if cache.shm == nil or cache.shm.idx == nil: return false
  cache.shm.idx.flattenChain()

proc flushHotIndex*(cache: var ActionCache) =
  ## Retained as a public no-op for callers that flushed the former
  ## write-behind hot index. Per-edge records are now written synchronously
  ## and atomically at record time, so there is nothing to flush. (The
  ## shared-memory write-back tier is AC-2; this proc gains real work there.)
  discard

proc closeShmTier*(cache: var ActionCache) =
  ## Detach the Tier-2 index (unmap + drop the producer registration).
  ## Best-effort; safe to call on a disabled or nil tier. The engine's
  ## process-long warm handle need not call it — process exit reclaims the
  ## mappings — but a test that opens and discards many caches does, to avoid
  ## fd growth. There is nothing else to stop: no process owns the chain.
  if cache.shm != nil and cache.shm.idx != nil:
    cache.shm.idx.closeActionIndex()
    cache.shm.enabled = false

proc lookupHotMetadataRecord*(cache: var ActionCache; weak: ContentDigest;
                              policy: FileFingerprintPolicy):
    Option[ActionResultRecord] =
  ## Metadata-only lookup served from the edge's single per-edge file.
  ##
  ## The refusal below and `scanHotIndexMetadataInputsUnchanged`'s are the
  ## SAME refusal — the two arms of one whole-graph shortcut — so they read
  ## one shared name. They did not always; see `MetadataValidatedPolicies`.
  if policy notin MetadataValidatedPolicies:
    return none(ActionResultRecord)
  let hot = cache.readHotRecord(weak)
  if not hot.found or hot.record.policy != policy:
    return none(ActionResultRecord)
  some(hot.record)

proc hotMetadataInputsUnchanged*(cache: var ActionCache;
                                 metadataCache: ptr FileMetadataCache = nil): bool =
  ## Retained for API compatibility. There is no whole-cache hot-input set
  ## to scan anymore; per-edge input freshness is checked by the batch
  ## `scanHotIndexMetadataInputsUnchanged` / per-record helpers. With no
  ## global set to iterate, this trivially holds.
  true

proc hotMetadataRecordCount*(cache: var ActionCache): int =
  ## The former whole-cache count is meaningless without a global hot store.
  ## Returning 0 makes the build engine's `actions.len == count` shortcut
  ## never fire, so it always takes the per-record path (which reads each
  ## edge's file) — semantics-preserving, no whole-cache scan.
  0

proc hotMetadataRecordInputsUnchanged*(records: openArray[ActionResultRecord];
                                       metadataCache: ptr FileMetadataCache = nil;
                                       envResolvers: openArray[EnvResolver] = []): bool =
  var seen = initHashSet[string]()
  for recordIndex, record in records:
    # M10 — see `scanHotIndexMetadataInputsUnchanged`: this is the other
    # whole-graph shortcut, and an unchecked environment here is a stale hit
    # nothing downstream would catch.
    var changedEnv = ""
    let resolver =
      if recordIndex < envResolvers.len: envResolvers[recordIndex]
      else: nil
    if envInputChanged(record, resolver, changedEnv):
      return false
    timedRecordedInputRevalidation:
      for input in record.inputs:
        let inputKey = hotInputKey(input)
        if seen.contains(inputKey):
          continue
        seen.incl(inputKey)
        if fingerprintRecordedMetadata(input.path, input.metadata,
            metadataCache) != input.metadata:
          return false
  true

proc recordActionResult*(cache: var ActionCache; cas: LocalCas;
                         weak: ContentDigest; policy: FileFingerprintPolicy;
                         inputPaths, outputPaths: openArray[string];
                         outputRoot = "";
                         storeOutputBlobs = true;
                         metadataCache: ptr FileMetadataCache = nil;
                         envInputs: openArray[EnvFingerprint] = [];
                         enumeratedDirectories: openArray[string] = [];
                         determinism = EntryDeterminism()):
                         ActionResultRecord =
  result.weakFingerprint = weak
  result.policy = policy
  # §3's write column. Stamped here, at the one moment the wall clock means
  # what the retention clause needs it to mean: the instant the realization
  # was produced. Defaulted-empty, so every existing caller records exactly
  # what it recorded before and writes no sidecar.
  result.determinism = determinism
  var enumerated = initHashSet[string]()
  for path in enumeratedDirectories:
    enumerated.incl(path.replace('\\', '/'))
  for path in inputPaths:
    let input =
      if enumerated.contains(path.replace('\\', '/')):
        observeEnumeratedDirectory(path, policy)
      else:
        observeFile(path, policy, metadataCache)
    if input.isRecordableInput():
      result.inputs.add(input)
  for env in envInputs:
    result.envInputs.add(env)
  result.strongFingerprint = computeStrongFingerprint(weak, result.inputs,
    result.envInputs)
  result.outputPayloadKind =
    if storeOutputBlobs: opkCasBlobs else: opkMetadataOnly
  for path in outputPaths:
    let source = materialPath(outputRoot, path)
    # Read straight from the inode we just wrote, not through
    # `metadataCache`: the engine invalidates that entry right after
    # execution anyway, and the witness is only meaningful fresh.
    let sourceMetadata = fingerprintMetadata(source)
    let observed = observeOutputWitness(source, sourceMetadata)
    # Windows: getFilePermissions returns a synthetic POSIX set derived from
    # the read-only attribute; we don't preserve it (see writePermissions),
    # so emit an empty set here. The cache record still round-trips cleanly.
    when defined(windows):
      let perms: set[FilePermission] = {}
    else:
      let perms =
        try:
          getFilePermissions(extendedPath(source))
        except OSError:
          set[FilePermission]({})
    let blob =
      if storeOutputBlobs:
        if sourceMetadata.kind == ffkDirectory:
          cas.storeBlob(directorySnapshotPayload(source))
        elif sourceMetadata.kind == ffkRegular and isDirectRegularFile(source):
          cas.storeFileBlob(source, sourceMetadata.sizeBytes)
        else:
          cas.storeBlob(bytes(readFile(extendedPath(source))))
      else:
        CasBlobRef()
    result.outputs.add(OutputBlob(path: path, metadata: sourceMetadata,
      blob: blob, permissions: perms,
      changeTimeNs: observed.changeTimeNs, linkTarget: observed.linkTarget,
      treeDigest: observed.treeDigest,
      hasTreeDigest: observed.hasTreeDigest))
  cache.writePerEdgeRecord(result)

proc recordActionResult*(cache: var ActionCache; cas: var Store;
                         weak: ContentDigest; policy: FileFingerprintPolicy;
                         inputPaths, outputPaths: openArray[string];
                         outputRoot = "";
                         storeOutputBlobs = true;
                         metadataCache: ptr FileMetadataCache = nil;
                         envInputs: openArray[EnvFingerprint] = [];
                         enumeratedDirectories: openArray[string] = [];
                         determinism = EntryDeterminism()):
                         ActionResultRecord =
  result.weakFingerprint = weak
  result.policy = policy
  # §3's write column. Stamped here, at the one moment the wall clock means
  # what the retention clause needs it to mean: the instant the realization
  # was produced. Defaulted-empty, so every existing caller records exactly
  # what it recorded before and writes no sidecar.
  result.determinism = determinism
  var enumerated = initHashSet[string]()
  for path in enumeratedDirectories:
    enumerated.incl(path.replace('\\', '/'))
  for path in inputPaths:
    let input =
      if enumerated.contains(path.replace('\\', '/')):
        observeEnumeratedDirectory(path, policy)
      else:
        observeFile(path, policy, metadataCache)
    if input.isRecordableInput():
      result.inputs.add(input)
  for env in envInputs:
    result.envInputs.add(env)
  result.strongFingerprint = computeStrongFingerprint(weak, result.inputs,
    result.envInputs)
  result.outputPayloadKind =
    if storeOutputBlobs: opkCasBlobs else: opkMetadataOnly
  for path in outputPaths:
    let source = materialPath(outputRoot, path)
    # Read straight from the inode we just wrote, not through
    # `metadataCache`: the engine invalidates that entry right after
    # execution anyway, and the witness is only meaningful fresh.
    let sourceMetadata = fingerprintMetadata(source)
    let observed = observeOutputWitness(source, sourceMetadata)
    # Windows: getFilePermissions returns a synthetic POSIX set derived from
    # the read-only attribute; we don't preserve it (see writePermissions),
    # so emit an empty set here. The cache record still round-trips cleanly.
    when defined(windows):
      let perms: set[FilePermission] = {}
    else:
      let perms = getFilePermissions(extendedPath(source))
    let blob =
      if storeOutputBlobs:
        if sourceMetadata.kind == ffkDirectory:
          cas.storeBlob(directorySnapshotPayload(source))
        elif sourceMetadata.kind == ffkRegular and isDirectRegularFile(source):
          cas.storeFileBlob(source, sourceMetadata.sizeBytes)
        else:
          cas.storeBlob(bytes(readFile(extendedPath(source))))
      else:
        CasBlobRef()
    result.outputs.add(OutputBlob(path: path, metadata: sourceMetadata,
      blob: blob, permissions: perms,
      changeTimeNs: observed.changeTimeNs, linkTarget: observed.linkTarget,
      treeDigest: observed.treeDigest,
      hasTreeDigest: observed.hasTreeDigest))
  cache.writePerEdgeRecord(result)

proc refreshedInputs(record: ActionResultRecord; changed: var bool;
                     hybridCutoff: var bool;
                     changedInputPath: var string;
                     metadataCache: ptr FileMetadataCache):
                     tuple[inputs: seq[FileFingerprint],
                           reusedRecordedInputs: bool] =
  result.reusedRecordedInputs = true
  timedRecordedInputRevalidation:
    for i, recorded in record.inputs:
      let currentMetadata = fingerprintRecordedMetadata(recorded.path,
        recorded.metadata, metadataCache)
      if recorded.metadata.membershipTrackedDirectory() and
          currentMetadata != recorded.metadata:
        # An enumerated directory whose membership moved. This returns BEFORE
        # the policy switch on purpose: `fileBytesForHash` is empty for a
        # directory, so both the `ffpChecksum` comparison and the `ffpHybrid`
        # cutoff would find the content hashes equal and call it unchanged --
        # turning the one signal that exists for a directory back into
        # nothing. Incremental-Invalidation.md §"Validation Criteria" requires
        # this to invalidate.
        changed = true
        changedInputPath = recorded.path
        return
      case recorded.policy
      of ffpTimestamp:
        if currentMetadata != recorded.metadata:
          changed = true
          changedInputPath = recorded.path
          return
        if not result.reusedRecordedInputs:
          result.inputs[i] = recorded
      of ffpChecksum:
        let current = observeFileWithMetadata(recorded.path, recorded.policy,
          currentMetadata)
        if (not recorded.hasLocalHash) or (not current.hasLocalHash) or
            current.localHash != recorded.localHash:
          changed = true
          changedInputPath = recorded.path
          return
        if not result.reusedRecordedInputs:
          result.inputs[i] = recorded
      of ffpHybrid:
        if currentMetadata == recorded.metadata:
          if not result.reusedRecordedInputs:
            result.inputs[i] = recorded
          continue
        if not recorded.hasLocalHash:
          changed = true
          changedInputPath = recorded.path
          return
        let current = observeFileWithMetadata(recorded.path, recorded.policy,
          currentMetadata)
        if not current.hasLocalHash:
          changed = true
          changedInputPath = recorded.path
          return
        if current.localHash == recorded.localHash:
          if result.reusedRecordedInputs:
            result.inputs = newSeq[FileFingerprint](record.inputs.len)
            for prior in 0 ..< i:
              result.inputs[prior] = record.inputs[prior]
            result.reusedRecordedInputs = false
          result.inputs[i] = current
          hybridCutoff = true
        else:
          changed = true
          changedInputPath = recorded.path
          return

proc verifyOutputs(cas: LocalCas; record: ActionResultRecord) =
  if record.outputPayloadKind != opkCasBlobs:
    raise newException(CacheIntegrityError,
      "cache record does not contain output payloads")
  for output in record.outputs:
    cas.verifyBlob(output.blob)

proc verifyOutputs(cas: Store; record: ActionResultRecord) =
  if record.outputPayloadKind != opkCasBlobs:
    raise newException(CacheIntegrityError,
      "cache record does not contain output payloads")
  for output in record.outputs:
    cas.verifyBlob(output.blob)

proc lookupActionResultImpl[CasT](cache: var ActionCache; cas: CasT;
                                  weak: ContentDigest;
                                  policy: FileFingerprintPolicy;
                                  verifyOutputBlobs = true;
                                  allowMetadataOnlyHit = false;
                                  metadataCache: ptr FileMetadataCache = nil;
                                  envResolver: EnvResolver = nil;
                                  outputRoot = ""):
                                  ActionCacheLookup =
  if allowMetadataOnlyHit and not verifyOutputBlobs and policy in {ffpTimestamp, ffpHybrid}:
    let hot = cache.readHotRecord(weak)
    if hot.found and hot.record.policy == policy:
      var changed = false
      var changedInput = ""
      # The env check comes FIRST on this path because it is the cheap one --
      # a handful of string compares against values the caller already has,
      # versus a stat per recorded input.
      if envInputChanged(hot.record, envResolver, changedInput):
        changed = true
      timedRecordedInputRevalidation:
        for input in hot.record.inputs:
          if changed:
            break
          if fingerprintRecordedMetadata(input.path, input.metadata,
              metadataCache) != input.metadata:
            changed = true
            changedInput = input.path
            break
      if not changed:
        # Inputs are unchanged, so this record still describes the right
        # computation. It is still only a hit if the DECLARED OUTPUTS on disk
        # are the ones the record describes -- Incremental-Invalidation.md
        # §"Minimum check set" Step 3.3. Existence alone (which is all the
        # engine's `allOutputsExist` pre-check establishes) is not enough.
        let outputMismatch = outputStateMismatch(hot.record, outputRoot)
        if outputMismatch.len > 0:
          return ActionCacheLookup(status: aclRejectedCorruptOutput,
            record: hot.record, message: outputMismatch)
        return ActionCacheLookup(status: aclHit, record: hot.record)
      if policy != ffpHybrid:
        return ActionCacheLookup(
          status: aclMissInputChanged,
          record: hot.record,
          message: "input metadata changed: " & changedInput,
          changedInputPath: changedInput)
      # ffpHybrid, metadata moved: this is exactly the case the hybrid
      # policy exists for -- "compare timestamp metadata first; when the
      # metadata changed, compute the local content hash. If the content
      # hash is unchanged ... cut off without rebuilding dependents"
      # (Incremental-Invalidation.md §"File Fingerprint Policies"). Reporting
      # a miss from here made hybrid behave identically to timestamp on the
      # warm path, so the cutoff in §"Validation Criteria" never happened.
      # Fall through to the full candidate walk below, which implements it.

  let records = cache.loadRecordsForWeak(weak)
  if records.len == 0:
    return ActionCacheLookup(status: aclMissNoRecord,
      message: "no cache record for weak fingerprint")
  var sawInputChange = false
  var firstChangedInput = ""
  for i in countdown(records.high, 0):
    let record = records[i]
    if record.policy != policy:
      continue
    var changed = false
    var hybridCutoff = false
    var changedInput = ""
    if envInputChanged(record, envResolver, changedInput):
      sawInputChange = true
      if firstChangedInput.len == 0:
        firstChangedInput = "environment: " & changedInput
      continue
    let refreshed = refreshedInputs(record, changed, hybridCutoff,
      changedInput, metadataCache)
    if changed:
      sawInputChange = true
      if firstChangedInput.len == 0:
        firstChangedInput = changedInput
      continue
    var candidate = record
    if not refreshed.reusedRecordedInputs:
      candidate.inputs = refreshed.inputs
      candidate.strongFingerprint = computeStrongFingerprint(weak,
        candidate.inputs, candidate.envInputs)
      if candidate.strongFingerprint != record.strongFingerprint:
        sawInputChange = true
        if firstChangedInput.len == 0:
          firstChangedInput = "strong fingerprint"
        continue
    if verifyOutputBlobs:
      if candidate.outputPayloadKind != opkCasBlobs:
        return ActionCacheLookup(status: aclMissNoOutputPayload,
          record: candidate,
          message: "cache record does not contain output payloads")
      try:
        cas.verifyOutputs(candidate)
      except CacheIntegrityError as err:
        return ActionCacheLookup(status: aclRejectedCorruptOutput,
          record: candidate, message: err.msg)
    elif allowMetadataOnlyHit:
      # In-place local reuse: the bytes stay at their declared paths, so the
      # CAS verification above is not what protects them. Revalidate the
      # workspace copies against the recorded output state instead.
      # `verifyOutputBlobs` mode is the restore mode and materializes over
      # whatever is there, so it needs no such check.
      let outputMismatch = outputStateMismatch(candidate, outputRoot)
      if outputMismatch.len > 0:
        return ActionCacheLookup(status: aclRejectedCorruptOutput,
          record: candidate, message: outputMismatch)
    if hybridCutoff:
      cache.writePerEdgeRecord(candidate)
      return ActionCacheLookup(status: aclHybridCutoff, record: candidate)
    return ActionCacheLookup(status: aclHit, record: candidate)
  if sawInputChange:
    ActionCacheLookup(
      status: aclMissInputChanged,
      message:
        if firstChangedInput.len > 0:
          "input changed: " & firstChangedInput
        else:
          "input changed",
      changedInputPath: firstChangedInput)
  else:
    ActionCacheLookup(status: aclMissNoRecord,
      message: "no matching cache record for policy")

proc determinismMetaFor*(cache: ActionCache; weak, strong: ContentDigest):
    EntryDeterminism =
  ## Read the determinism sidecar for one (edge, path-set) pair directly.
  ##
  ## `loadPerEdgeRecords` already attaches this to every record it returns,
  ## and it validates the sidecar's write-sequence back-reference before doing
  ## so. This entry point deliberately does NOT validate that back-reference,
  ## because the callers that need it -- the shared-memory hot tier, which
  ## decodes a plain frame and has no write sequence, and the retention GC,
  ## which walks sidecars rather than records -- do not have one to compare.
  ##
  ## Skipping the check is sound HERE and only here, because of which
  ## direction it errs in. A mismatched sequence means an older binary
  ## rewrote the `.rec` after this sidecar was written, so the sidecar's
  ## `writeTimeUnix` is EARLIER than the entry's true write time. Under a
  ## `max-age` clause an earlier write time makes the entry look OLDER, i.e.
  ## more expired, i.e. a miss. The failure mode is a redundant re-run, never
  ## a stale realization served as fresh.
  let dirPath = cache.perEdgeDirPath(weak)
  let detPath = dirPath / determinismFileName(digestHex(strong))
  if not fileExists(extendedPath(detPath)):
    return EntryDeterminism()
  try:
    decodeDeterminism(bytes(readFile(detPath))).meta
  except OSError, IOError, EnvelopeError:
    EntryDeterminism()

proc applyRetention(cache: ActionCache; weak: ContentDigest;
                    lookup: var ActionCacheLookup;
                    retention: CacheRetention;
                    nowUnix: int64; buildEpoch: string) =
  ## `Edge-Determinism-And-Soft-Rebuild.md` §4.4: an expired `volatile` entry
  ## becoming a cache miss is "the only automatic invalidation the default
  ## mode does". This is that invalidation, and it is deliberately the LAST
  ## gate: an entry that already failed on inputs, env, or output integrity
  ## keeps the more specific diagnosis it earned.
  ##
  ## `crkForever` -- every non-`volatile` class, and every caller that passes
  ## nothing -- returns before touching the filesystem, so the hot path is
  ## byte-for-byte the path it was before this existed.
  if retention.kind == crkForever:
    return
  if lookup.status notin {aclHit, aclHybridCutoff}:
    return
  var meta = lookup.record.determinism
  if not meta.declared:
    # The shared-memory tier decodes a plain record frame, which carries no
    # sidecar data. Fall back to reading it by (edge, path-set).
    meta = cache.determinismMetaFor(weak, lookup.record.strongFingerprint)
  let now = if nowUnix != 0: nowUnix else: toUnix(getTime())
  let verdict = retentionVerdict(retention, meta.writeTimeUnix, now,
    entryBuildEpoch = meta.buildEpoch, currentBuildEpoch = buildEpoch)
  if servesCachedBytes(verdict):
    return
  lookup.status = aclMissRetentionExpired
  lookup.message =
    case verdict
    of rvUnknownWriteTime:
      "cached entry carries no recorded write time; retention '" &
        $retention & "' cannot be evaluated, so the entry is not served"
    of rvRevalidate:
      "retention '" & $retention & "' requires revalidation on every read"
    else:
      "cached entry expired under retention '" & $retention & "' (written " &
        $max(0'i64, now - meta.writeTimeUnix) & "s ago)"

proc lookupActionResult*(cache: var ActionCache; cas: LocalCas;
                         weak: ContentDigest; policy: FileFingerprintPolicy;
                         verifyOutputBlobs = true;
                         allowMetadataOnlyHit = false;
                         metadataCache: ptr FileMetadataCache = nil;
                         envResolver: EnvResolver = nil;
                         outputRoot = "";
                         retention = forever();
                         nowUnix: int64 = 0;
                         buildEpoch = ""): ActionCacheLookup =
  result = cache.lookupActionResultImpl(cas, weak, policy,
    verifyOutputBlobs = verifyOutputBlobs,
    allowMetadataOnlyHit = allowMetadataOnlyHit,
    metadataCache = metadataCache,
    envResolver = envResolver,
    outputRoot = outputRoot)
  cache.applyRetention(weak, result, retention, nowUnix, buildEpoch)

proc lookupActionResult*(cache: var ActionCache; cas: Store;
                         weak: ContentDigest; policy: FileFingerprintPolicy;
                         verifyOutputBlobs = true;
                         allowMetadataOnlyHit = false;
                         metadataCache: ptr FileMetadataCache = nil;
                         envResolver: EnvResolver = nil;
                         outputRoot = "";
                         retention = forever();
                         nowUnix: int64 = 0;
                         buildEpoch = ""): ActionCacheLookup =
  result = cache.lookupActionResultImpl(cas, weak, policy,
    verifyOutputBlobs = verifyOutputBlobs,
    allowMetadataOnlyHit = allowMetadataOnlyHit,
    metadataCache = metadataCache,
    envResolver = envResolver,
    outputRoot = outputRoot)
  cache.applyRetention(weak, result, retention, nowUnix, buildEpoch)

# ===========================================================================
# Retention-aware GC (`Edge-Determinism-And-Soft-Rebuild.md` §9's deferred
# follow-up, and §10.2's "retention-driven eviction runs before size-driven
# eviction").
#
# §9 named exactly one gap and deferred it: "A `volatile` entry with
# `max-age = 1` clutters the cache fast. A retention-aware GC that evicts
# stale `volatile` entries preferentially is a follow-up; the current spec
# leaves it to the existing reprobuild GC." The existing GC could not do it,
# and not because nobody had wired it up: NOTHING in reprobuild evicted on
# age. The reaper evicts on lease deadline + holder liveness, the store GC on
# root reachability, and the home GC on keep-last-N-generations. None of the
# three can express "this realization has aged out of its declared window".
#
# What this is NOT: a replacement for any of those three. It runs at the
# ACTION-CACHE ENTRY level and deletes records and their sidecars. It never
# unlinks a CAS blob, because a blob is shared and the only component that
# knows whether one is still referenced is the reachability GC in
# `store.nim`. Instead it REPORTS the digests the evicted entries referenced,
# so an `evictToSoftCap` pass afterwards reclaims whatever genuinely became
# unreachable. Two owners, one direction, no double authority over deletion.
# ===========================================================================

type
  CacheEntryRef* = object
    ## One action-cache entry as the retention GC sees it: a `.rec` file, its
    ## sidecars, and the determinism metadata that decides its fate.
    weakDirName*: string       ## `hot-records/<this>` — the per-edge directory
    strongHex*: string         ## the `.rec` basename, i.e. the path-set nonce
    recPath*: string
    recordBytes*: int64        ## the `.rec` plus its sidecars
    payloadBytes*: int64       ## the output blobs this entry references
    mtimeUnix*: int64
    meta*: EntryDeterminism
    expired*: bool
    blobDigests*: seq[string]

  RetentionGcPolicy* = object
    nowUnix*: int64
      ## Injected clock. Every test that asserts on expiry passes its own;
      ## 0 means read the wall clock. There is no `sleep` anywhere in this
      ## mechanism and there must not be.
    currentBuildEpoch*: string
      ## For §2.2's `this-build` clause. Empty means "no build in progress",
      ## under which every `this-build` entry is expired — which is right:
      ## the invocation that owned it is over.
    softCapBytes*: int64
      ## 0 disables the size pass entirely, leaving a pure retention sweep.
      ## That is the useful default for a periodic hook: §10.2 says a stale
      ## `volatile` entry "should leave even if the cache is below quota".
    dryRun*: bool

  RetentionGcReport* = object
    scannedEntries*: int
    expiredEvicted*: int
    sizeEvicted*: int
    bytesBefore*: int64
    bytesAfter*: int64
    evicted*: seq[string]        ## `<weakDirName>/<strongHex>`
    releasedBlobs*: seq[string]  ## CAS digests the evicted entries referenced
    orderViolation*: bool
      ## Set if the size pass was ever about to evict an unexpired entry
      ## while an expired one was still on disk. It must never be true; the
      ## field exists so a test can assert on the INVARIANT rather than on
      ## the incidental fact that phase 1 happens to run first.

proc hotRecordsRoot*(cache: ActionCache): string =
  ## The directory holding one per-edge subdirectory per cached edge. Exposed
  ## for the retention GC and for tooling that must walk the whole cache; the
  ## per-edge read path deliberately never does (the anti-wedge invariant).
  cache.hotRoot

proc fileSizeOrZero(path: string): int64 =
  try: getFileSize(extendedPath(path))
  except OSError, IOError: 0'i64

proc scanCacheEntries*(cache: ActionCache;
                       policy: RetentionGcPolicy): seq[CacheEntryRef] =
  ## Walk `hot-records/` and classify every entry. This IS a whole-cache scan
  ## — the one place in this module that does one — because a GC has no
  ## smaller honest question to ask. It is never on a build's critical path.
  result = @[]
  let root = cache.hotRecordsRoot
  if not dirExists(extendedPath(root)):
    return
  let now = if policy.nowUnix != 0: policy.nowUnix else: toUnix(getTime())
  for edgeKind, edgeDir in walkDir(extendedPath(root)):
    if edgeKind != pcDir:
      continue
    let weakDirName = extractFilename(edgeDir)
    for kind, path in walkDir(edgeDir):
      if kind != pcFile or not path.endsWith(PerEdgeRecFileExt):
        continue
      let strongHex = path.splitFile.name
      var entry = CacheEntryRef(
        weakDirName: weakDirName,
        strongHex: strongHex,
        recPath: path,
        recordBytes: fileSizeOrZero(path))
      for ext in [WitnessFileExt, DeterminismFileExt]:
        entry.recordBytes += fileSizeOrZero(edgeDir / (strongHex & ext))
      try:
        entry.mtimeUnix = toUnix(getLastModificationTime(extendedPath(path)))
      except OSError, IOError:
        entry.mtimeUnix = 0
      let detPath = edgeDir / determinismFileName(strongHex)
      if fileExists(extendedPath(detPath)):
        try:
          entry.meta = decodeDeterminism(bytes(readFile(detPath))).meta
        except OSError, IOError, EnvelopeError:
          discard
      # Payload size + the blob digests this entry holds a claim on. A record
      # this binary cannot decode contributes 0 bytes and no digests rather
      # than aborting the sweep: an undecodable record is one an OLDER or
      # NEWER reprobuild wrote, and a GC must not delete what it cannot read.
      var decodable = true
      try:
        let decoded = decodePerEdgeFileWithSeq(bytes(readFile(path)))
        for record in decoded.records:
          if record.outputPayloadKind != opkCasBlobs:
            continue
          for output in record.outputs:
            entry.payloadBytes += int64(output.blob.sizeBytes)
            entry.blobDigests.add(digestHex(output.blob.digest))
      except OSError, IOError, EnvelopeError:
        decodable = false
      if not decodable:
        entry.payloadBytes = 0
        entry.blobDigests = @[]
      entry.expired =
        entry.meta.declared and
        isExpired(entry.meta.retention, entry.meta.writeTimeUnix, now,
          entryBuildEpoch = entry.meta.buildEpoch,
          currentBuildEpoch = policy.currentBuildEpoch)
      result.add(entry)

proc removeEntry(entry: CacheEntryRef): bool =
  ## Unlink one entry's `.rec` and both sidecars. Best-effort on the
  ## sidecars: an orphaned one is reaped by `capRecFiles` anyway, whereas a
  ## `.rec` that survives is a live cache entry, so only its removal decides
  ## success.
  let dir = entry.recPath.parentDir
  for ext in [WitnessFileExt, DeterminismFileExt]:
    let sidecar = dir / (entry.strongHex & ext)
    if fileExists(extendedPath(sidecar)):
      try: removeFile(extendedPath(sidecar))
      except OSError: discard
  try:
    removeFile(extendedPath(entry.recPath))
    true
  except OSError:
    false

proc runRetentionGc*(cache: ActionCache;
                     policy: RetentionGcPolicy): RetentionGcReport =
  ## Two passes, in this order and never the other:
  ##
  ##   1. RETENTION. Every entry whose declared `cacheRetention` says it has
  ##      aged out goes, whatever the size budget says. §10.2: "a stale
  ##      `volatile` entry should leave even if the cache is below quota."
  ##      By construction this pass touches only `volatile` entries —
  ##      `isExpired` is false for `crkForever`, and `crkForever` is what
  ##      every non-`volatile` class carries — but the code does not rely on
  ##      that: it asks the retention clause, which is the thing that
  ##      actually decides.
  ##
  ##   2. SIZE. Only if a soft cap was given and the footprint is still over
  ##      it. Oldest-mtime-first over what remains, which is exactly the
  ##      existing LRU order. An entry is never evicted here while an expired
  ##      entry is still on disk; that is asserted rather than assumed (see
  ##      `orderViolation`).
  var entries = scanCacheEntries(cache, policy)
  result.scannedEntries = entries.len
  for entry in entries:
    result.bytesBefore += entry.recordBytes + entry.payloadBytes
  result.bytesAfter = result.bytesBefore

  var survivors: seq[CacheEntryRef] = @[]
  for entry in entries:
    if not entry.expired:
      survivors.add(entry)
      continue
    if policy.dryRun:
      inc result.expiredEvicted
      result.evicted.add(entry.weakDirName & "/" & entry.strongHex)
      # Decrement here too, not only on the real path. The size pass below
      # reads `bytesAfter` to decide how much more it must take; a dry run
      # that left it at the pre-sweep total would plan a size eviction the
      # real run would not perform, and a preview that over-reports is a
      # preview nobody can act on.
      result.bytesAfter -= entry.recordBytes + entry.payloadBytes
      continue
    if removeEntry(entry):
      inc result.expiredEvicted
      result.bytesAfter -= entry.recordBytes + entry.payloadBytes
      result.evicted.add(entry.weakDirName & "/" & entry.strongHex)
      for d in entry.blobDigests:
        result.releasedBlobs.add(d)
    else:
      survivors.add(entry)

  if policy.softCapBytes <= 0 or result.bytesAfter <= policy.softCapBytes:
    return

  # The invariant, checked rather than trusted: nothing expired may still be
  # on disk when the size pass begins. If it is, the size pass does not run —
  # evicting a `strong` entry to make room while an aged-out `volatile` one
  # survives is precisely the inversion this milestone exists to prevent, and
  # a silently-inverted GC is worse than one that declines.
  for entry in survivors:
    if entry.expired:
      result.orderViolation = true
      return

  survivors.sort(proc (a, b: CacheEntryRef): int =
    # Primary key is the `.rec` file's mtime, which is what the existing
    # `evictToSoftCap` uses and therefore what "LRU" already means here.
    result = cmp(a.mtimeUnix, b.mtimeUnix)
    if result == 0 and a.meta.writeTimeUnix > 0 and b.meta.writeTimeUnix > 0:
      # Two entries written inside the same clock second tie on mtime, and
      # a whole cache warmed by one build ties on ALL of them -- at which
      # point a strongHex tie-break makes the eviction order effectively
      # arbitrary. The recorded write time is a strictly finer statement of
      # the same fact, so it breaks the tie when BOTH entries carry one.
      # Guarded on both being non-zero because an undeclared entry has no
      # write time, and treating its 0 as "oldest" would evict the
      # unlabelled corpus first for no reason.
      result = cmp(a.meta.writeTimeUnix, b.meta.writeTimeUnix)
    if result == 0:
      result = cmp(a.strongHex, b.strongHex))
  for entry in survivors:
    if result.bytesAfter <= policy.softCapBytes:
      break
    if policy.dryRun:
      inc result.sizeEvicted
      result.evicted.add(entry.weakDirName & "/" & entry.strongHex)
      result.bytesAfter -= entry.recordBytes + entry.payloadBytes
      continue
    if removeEntry(entry):
      inc result.sizeEvicted
      result.bytesAfter -= entry.recordBytes + entry.payloadBytes
      result.evicted.add(entry.weakDirName & "/" & entry.strongHex)
      for d in entry.blobDigests:
        result.releasedBlobs.add(d)

## Generation registry: write/read/enumerate generations under the
## state directory and insert their realized-prefix holds into the
## store (M62 — Home-Profile-Generations-And-State.md "Store GC
## Interaction").
##
## Public surface:
##
##   - `writeGeneration(stateDir, envelope, manifestBytes,
##                      intentSnapshotBytes, store)` writes all three
##     artifacts (the pointer envelope on the state-dir side, the
##     activation manifest and the intent-snapshot blob on the store
##     side) and inserts the corresponding root + holds into the
##     store index.
##
##   - `enumerateGenerations(stateDir)` walks
##     `<state-dir>/generations/` and returns one `GenerationRecord`
##     per directory found. Used by `repro home history`.
##
##   - `setActiveGeneration(stateDir, id)` is a thin re-export of the
##     state-dir `current` writer for callers that already have a
##     `Store` open.

import std/[algorithm, os]

import repro_local_store

import ./errors
import ./pointer
import ./state_dir

type
  GenerationRecord* = object
    ## One walked generation. The pointer envelope is the source of
    ## truth — if its checksum fails, the directory is reported as
    ## corrupt and the caller decides whether to surface that to the
    ## user or quarantine.
    generationId*: string            ## hex of pointer.generationId
    pointerPath*: string
    envelope*: PointerEnvelope
    isActive*: bool
    activationTimestamp*: int64

proc digestToPrefixId(d: Digest256): PrefixIdBytes =
  for i in 0 ..< 32:
    result[i] = d[i]

# ---------------------------------------------------------------------------
# Generation writer.
# ---------------------------------------------------------------------------

proc writeGeneration*(stateDir: string;
                     envelope: var PointerEnvelope;
                     manifestBytes: openArray[byte];
                     intentSnapshotBytes: openArray[byte];
                     configurableGraphBytes: openArray[byte];
                     store: var Store) =
  ## Compose and persist a complete generation.
  ##
  ## - Stores `manifestBytes`, `intentSnapshotBytes`, and
  ##   `configurableGraphBytes` in the local CAS via the M56 store.
  ##   The returned BLAKE3-256 digests are written into `envelope`,
  ##   so the caller does NOT need to pre-populate the three digest
  ##   fields — they are sealed atomically with the pointer.
  ## - Atomically writes the pointer envelope to
  ##   `<state-dir>/generations/<gen-id>/pointer.bin`.
  ## - Registers a `profile`-kind root in the store index whose id is
  ##   the hex generation id, and inserts one `root_holds_prefix` row
  ##   per entry in `envelope.realizedPrefixIds`.
  ##
  ## The caller IS responsible for: choosing the activation
  ## timestamp, choosing the host identity, choosing the generation
  ## id (use `computeGenerationId` for the recommended derivation),
  ## and supplying the realized-prefix id list.
  ensureStateDir(stateDir)
  # Seal the three CAS-resident artifacts first; their digests then
  # feed into the pointer's audited field set.
  let manifestKey = store.storeCasBlob(manifestBytes)
  let snapshotKey = store.storeCasBlob(intentSnapshotBytes)
  let rbcgKey = store.storeCasBlob(configurableGraphBytes)
  for i in 0 ..< 32:
    envelope.activationManifestDigest[i] = manifestKey[i]
    envelope.intentSnapshotDigest[i] = snapshotKey[i]
    envelope.configurableGraphDigest[i] = rbcgKey[i]
  # Materialize the generation directory and the pointer envelope.
  let genIdHex = generationIdHex(envelope.generationId)
  let dir = generationDir(stateDir, genIdHex)
  createDir(dir)
  let pointerFile = pointerPath(stateDir, genIdHex)
  writePointerFile(pointerFile, envelope)
  # Register the profile root + the per-prefix holds in the store
  # index. The root id is the hex generation id, matching the
  # "Store GC Interaction" section's contract that store GC unions
  # the prefix-id lists across every generation present under
  # `<state-dir>/generations/`.
  registerRoot(store, genIdHex, rkProfile,
    holderUid = -1, ttlSeconds = -1)
  for prefixDigest in envelope.realizedPrefixIds:
    let prefixId = digestToPrefixId(prefixDigest)
    attachPrefixToRoot(store, genIdHex, prefixId)

# ---------------------------------------------------------------------------
# Generation enumeration.
# ---------------------------------------------------------------------------

proc enumerateGenerations*(stateDir: string): seq[GenerationRecord] =
  ## Walk `<state-dir>/generations/` and return one record per
  ## directory that contains a parseable `pointer.bin`. Order is by
  ## ascending `activationTimestamp` (oldest first); ties broken by
  ## hex id for determinism.
  ##
  ## A corrupt pointer raises `EPointerCorrupt`; the caller decides
  ## whether to surface that to the user or to skip + quarantine the
  ## directory. (M62 surfaces directly; the M63 apply pipeline will
  ## skip + quarantine.)
  let root = generationsRoot(stateDir)
  if not dirExists(root):
    return @[]
  let activeId = readCurrentGenerationId(stateDir)
  for kind, entry in walkDir(root, relative = false):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let id = extractFilename(entry)
    let pointerFile = entry / PointerFileName
    if not fileExists(pointerFile):
      # Treat as a partial-apply leftover. M62 reports it; the
      # apply pipeline (M63) decides whether to resume or
      # quarantine.
      raiseGenerationDirInvalid(entry,
        "missing pointer.bin (partial apply or quarantined)")
    let env = readPointerFile(pointerFile)
    var record = GenerationRecord(
      generationId: id,
      pointerPath: pointerFile,
      envelope: env,
      isActive: id == activeId,
      activationTimestamp: env.activationTimestamp)
    result.add(record)
  result.sort(proc(a, b: GenerationRecord): int =
    if a.activationTimestamp < b.activationTimestamp: -1
    elif a.activationTimestamp > b.activationTimestamp: 1
    else: cmp(a.generationId, b.generationId))

proc setActiveGeneration*(stateDir, generationId: string) =
  ## Convenience: re-export the state-dir current-marker writer.
  writeCurrentGenerationId(stateDir, generationId)

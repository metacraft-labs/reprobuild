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
##   - `profileRootId(stateDir, generationIdHex)` is the id of the
##     `profile` root one generation of one state directory holds its
##     prefixes through. `ensureGenerationRoots(stateDir, store)`
##     registers it for every generation the state directory keeps.
##
##   - `enumerateGenerations(stateDir)` walks
##     `<state-dir>/generations/` and returns one `GenerationRecord`
##     per directory found. Used by `repro home history`.
##
##   - `setActiveGeneration(stateDir, id)` is a thin re-export of the
##     state-dir `current` writer for callers that already have a
##     `Store` open.

import std/[algorithm, os, sets, strutils]
from repro_core/paths import extendedPath

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
# Profile root ids.
# ---------------------------------------------------------------------------

const
  HomeProfileRootPrefix* = "home/"
    ## Every `profile` root a home state directory registers starts with
    ## this. A `profile` root named by a bare generation id was registered
    ## by a build that did not scope its roots.

proc profileRootIdForKey*(stateDirKey, generationIdHex: string): string =
  HomeProfileRootPrefix & stateDirKey & "/" & generationIdHex

proc profileRootId*(stateDir, generationIdHex: string): string =
  ## `home/<state-dir-key>/<generation-id>`: the root one generation of one
  ## state directory holds its realized prefixes through. Creates the
  ## state directory's key when it has none (`stateDirRootKey`).
  profileRootIdForKey(stateDirRootKey(stateDir), generationIdHex)

proc holdGeneration(store: var Store; rootId: string;
                    realizedPrefixIds: openArray[Digest256];
                    registered: bool): bool =
  ## Register `rootId` unless it is `registered`, and attach every prefix
  ## it does not hold yet. True when it registered or attached anything.
  ##
  ## A root that is present is never registered again: `registerRoot`
  ## replaces the row, which drops every hold until they are re-attached,
  ## and another state directory's store GC can run in between (apply
  ## locks are per state directory; the index is shared).
  var held = initHashSet[PrefixIdBytes]()
  if registered:
    for prefixId in store.prefixesHeldByRoot(rootId):
      held.incl(prefixId)
  else:
    registerRoot(store, rootId, rkProfile, holderUid = -1, ttlSeconds = -1)
    result = true
  for prefixDigest in realizedPrefixIds:
    let prefixId = digestToPrefixId(prefixDigest)
    if prefixId notin held:
      # A prefix the store no longer indexes cannot be held: the attach is
      # then ignored.
      attachPrefixToRoot(store, rootId, prefixId)
      result = true

proc rootIsRegistered(store: Store; rootId: string): bool =
  for row in store.listRoots():
    if row.rootId == rootId:
      return true

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
  ##   `profileRootId(stateDir, <hex generation id>)`, and inserts one
  ##   `root_holds_prefix` row per entry in `envelope.realizedPrefixIds`.
  ##   A root already there (a re-apply of an earlier profile) is kept and
  ##   only gains the holds it lacks.
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
  # The root id names this state directory and the generation, matching
  # the "Store GC Interaction" section's contract that store GC unions
  # the prefix-id lists across every generation present under
  # `<state-dir>/generations/` -- of every state directory that uses the
  # store, each through a root of its own. It is resolved before anything
  # is written: a key that cannot be read or created then fails the
  # commit before it leaves a pointer without a root.
  let rootId = profileRootId(stateDir, genIdHex)
  let dir = generationDir(stateDir, genIdHex)
  createDir(extendedPath(dir))
  let pointerFile = pointerPath(stateDir, genIdHex)
  writePointerFile(pointerFile, envelope)
  # Register the profile root + the per-prefix holds in the store index.
  discard holdGeneration(store, rootId, envelope.realizedPrefixIds,
    registered = rootIsRegistered(store, rootId))

proc ensureGenerationRoots*(stateDir: string; store: var Store):
    seq[string] =
  ## Give every generation under `<state-dir>/generations/` the `profile`
  ## root `writeGeneration` registers for it, when it does not have it in
  ## full. Returns the generation ids it registered or completed.
  ##
  ## A generation lacks its root when a build that named roots by the bare
  ## generation id committed it, when the state directory lost its key, or
  ## when a kill fell between the root row and its last hold. A root that
  ## is present only gains the holds it lacks.
  ##
  ## A root named by a bare generation id is left alone. Another state
  ## directory that has not run this build yet may hold the same generation
  ## through it, and nothing here can tell.
  let root = generationsRoot(stateDir)
  if not dirExists(extendedPath(root)):
    return @[]
  var registered = initHashSet[string]()
  for row in store.listRoots():
    registered.incl(row.rootId)
  var key = ""
  # TODO(win-longpath): walk results escape; needs review
  for kind, entry in walkDir(root, relative = false):
    if kind != pcDir:
      continue
    let id = extractFilename(entry)
    if id.startsWith("."):
      continue
    var envelope: PointerEnvelope
    try:
      envelope = readPointerFile(entry / PointerFileName)
    except CatchableError:
      # Not a committed generation this build can read: it names no
      # prefixes to hold.
      continue
    if generationIdHex(envelope.generationId) != id:
      continue
    if key.len == 0:
      key = stateDirRootKey(stateDir)
    let rootId = profileRootIdForKey(key, id)
    if holdGeneration(store, rootId, envelope.realizedPrefixIds,
        registered = rootId in registered):
      result.add(id)
  result.sort()

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
  if not dirExists(extendedPath(root)):
    return @[]
  let activeId = readCurrentGenerationId(stateDir)
  # TODO(win-longpath): walk results escape; needs review
  for kind, entry in walkDir(root, relative = false):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let id = extractFilename(entry)
    # `.aborted/` is M63's quarantine bucket for partial-apply
    # generations; it never holds a pointer.bin and isn't a real
    # generation. Skip it (the apply pipeline's
    # `recoverPartialApply` already iterates the bucket itself).
    if id.startsWith("."):
      continue
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

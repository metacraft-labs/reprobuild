## `repro home resource move <old> <new>` — M68 Phase B.
##
## Renames a resource record WITHOUT re-applying. The resource's
## underlying real-world state (registry value, file, managed
## block, gsettings key, ...) is untouched — only the resource's
## IDENTITY in the manifest changes from `<old>` to `<new>`.
##
## Use case: the user renamed the resource in `home.nim` (e.g.
## `fs.gitconfig` -> `fs.git-config`) and wants Reprobuild to carry
## the existing binding forward rather than do a destroy-old +
## create-new on the next apply.
##
## This is a METADATA operation:
##   - NO resource driver `apply` / `destroy` runs.
##   - The current generation's manifest is read, the
##     `ResourceBinding` whose `resourceAddress == old` has its
##     address rewritten to `new`, and a new generation is written
##     reflecting the rename.
##   - If `<old>` is not a known binding -> `EUnknownResource`.
##   - If `<new>` already exists as a binding -> `EResourceConflict`.
##
## The new generation reuses the prior generation's intent
## snapshot, configurable graph, and realized-prefix list verbatim;
## only the activation manifest's resource-binding addresses differ.

import std/[os, times]
from repro_core/paths import extendedPath

import blake3
import repro_home_generations
import repro_home_resources
import repro_local_store

import ./current_rotation
import ./errors

proc deriveMoveGenerationId(prevIntentSnapshotDigest: Digest256;
                            manifestBytes: openArray[byte];
                            hostIdentity: string;
                            activationTimestamp: int64): GenerationId =
  ## A `resource move` produces a new generation whose only delta
  ## is one renamed binding. The id is content-addressed over the
  ## post-rename manifest bytes + the (unchanged) intent snapshot +
  ## host + timestamp so the renamed generation has a distinct,
  ## reproducible identity that never collides with the prior one.
  var buf: seq[byte] = @[]
  for ch in "reprobuild.home.resource-move.id.v1":
    buf.add(byte(ord(ch)))
  for b in prevIntentSnapshotDigest: buf.add(b)
  for b in manifestBytes: buf.add(b)
  for ch in hostIdentity: buf.add(byte(ord(ch)))
  var tsLe = uint64(activationTimestamp)
  for _ in 0 ..< 8:
    buf.add(byte(tsLe and 0xff'u64))
    tsLe = tsLe shr 8
  let full = blake3.digest(buf)
  for i in 0 ..< GenerationIdSize:
    result[i] = full[i]

type
  ResourceMoveOutcome* = object
    ## Result of a successful `resource move`.
    fromGenerationIdHex*: string
    toGenerationIdHex*: string
    oldAddress*: string
    newAddress*: string

proc runResourceMove*(oldAddress, newAddress: string;
                      stateDir = ""; storeRoot = "";
                      activationTimestamp: int64 = 0):
    ResourceMoveOutcome =
  ## Carry the binding for `oldAddress` forward under `newAddress`.
  ## Pure metadata: no driver runs. Produces a new generation whose
  ## manifest is the prior manifest with exactly one binding's
  ## `resourceAddress` rewritten.
  let resolvedStateDir =
    if stateDir.len > 0: stateDir else: resolveStateDir()
  let resolvedStoreRoot =
    if storeRoot.len > 0: storeRoot else: resolveStoreRoot()
  let ts =
    if activationTimestamp != 0: activationTimestamp
    else: getTime().toUnix()

  if oldAddress == newAddress:
    raiseResourceMove(
      "repro home resource move: <old> and <new> are identical (" &
      oldAddress & "); nothing to rename")

  var lock = acquireApplyLock(resolvedStateDir)
  try:
    let activeIdHex = readCurrentGenerationId(resolvedStateDir)
    if activeIdHex.len == 0:
      raiseResourceMove(
        "repro home resource move: no active generation — run " &
        "`repro home apply` before renaming a resource")
    let pointerFile = pointerPath(resolvedStateDir, activeIdHex)
    if not fileExists(extendedPath(pointerFile)):
      raiseResourceMove(
        "repro home resource move: active generation pointer missing " &
        "at " & pointerFile)

    var store = openStore(resolvedStoreRoot)
    var storeClosed = false
    try:
      let prevEnv = readPointerFile(pointerFile)

      # Pull the prior generation's manifest, intent snapshot, and
      # configurable graph from CAS.
      var manifestKey: PrefixIdBytes
      var snapshotKey: PrefixIdBytes
      var graphKey: PrefixIdBytes
      for i in 0 ..< 32:
        manifestKey[i] = prevEnv.activationManifestDigest[i]
        snapshotKey[i] = prevEnv.intentSnapshotDigest[i]
        graphKey[i] = prevEnv.configurableGraphDigest[i]
      let prevManifestBytes = readCasBlob(store, manifestKey)
      let snapshotBytes = readCasBlob(store, snapshotKey)
      let graphBytes = readCasBlob(store, graphKey)
      var manifest = decodeManifestBytes(prevManifestBytes)

      # Locate the old binding; refuse if the new address collides.
      var oldIdx = -1
      for i, rb in manifest.resourceBindings:
        if rb.resourceAddress == oldAddress:
          oldIdx = i
        if rb.resourceAddress == newAddress:
          raiseResourceConflict(oldAddress, newAddress,
            rb.realWorldIdentity)
      if oldIdx < 0:
        raiseUnknownResource(oldAddress)

      # Metadata-only rename: rewrite the binding's address. The
      # `realWorldIdentity` (the actual object) is unchanged, the
      # pre/post-write digests are unchanged, the payload bytes are
      # unchanged — only the resource's manifest IDENTITY moves.
      manifest.resourceBindings[oldIdx].resourceAddress = newAddress

      let newManifestBytes = encodeManifest(manifest)

      # The manifest changed, so the generation is a new content-
      # addressed identity. Derive it from the (unchanged) intent
      # snapshot digest + host + timestamp, matching the M62
      # `computeGenerationId` derivation the rest of the pipeline
      # uses for non-apply generation writes.
      var envelope = PointerEnvelope(schemaVersion: 1'u16,
        activationTimestamp: ts,
        hostIdentity: prevEnv.hostIdentity,
        realizedPrefixIds: prevEnv.realizedPrefixIds)
      envelope.generationId = deriveMoveGenerationId(
        prevEnv.intentSnapshotDigest, newManifestBytes,
        prevEnv.hostIdentity, ts)

      writeGeneration(resolvedStateDir, envelope, newManifestBytes,
        snapshotBytes, graphBytes, store)
      rotateCurrent(resolvedStateDir,
        generationIdHex(envelope.generationId))

      result.fromGenerationIdHex = activeIdHex
      result.toGenerationIdHex = generationIdHex(envelope.generationId)
      result.oldAddress = oldAddress
      result.newAddress = newAddress

      store.close()
      storeClosed = true
    finally:
      if not storeClosed:
        try: store.close()
        except CatchableError: discard
  finally:
    releaseApplyLock(lock)

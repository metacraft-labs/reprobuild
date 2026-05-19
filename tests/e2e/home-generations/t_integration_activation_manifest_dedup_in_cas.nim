## M62 gate 2: integration_activation_manifest_dedup_in_cas.
##
## Per Reprobuild-Development.milestones.org:
##
##   "Apply the same intent twice (rolling back in between to force the
##    second apply to write a fresh pointer with a fresh timestamp);
##    verify both pointers reference the same `activationManifestDigest`
##    and only one CAS blob exists for it."
##
## At M62 there is no apply pipeline yet, so we exercise the byte-
## level invariant: two activation manifests with byte-identical
## content (and therefore byte-identical digests) share one CAS blob.
## The two pointers are written with different activation timestamps
## (simulating an apply -> rollback -> re-apply cycle), so the pointer
## bytes differ but the manifest digest field is identical.

import std/[os, unittest]

import repro_home_generations
import repro_local_store

const FixtureDir = "build/test-tmp/m62-gate2"

proc resetDir(path: string) =
  if dirExists(path):
    removeDir(path)
  createDir(path)

proc makeDigest(seed: byte): Digest256 =
  for i in 0 ..< 32:
    result[i] = byte((int(seed) + i) and 0xff)

proc seedPrefix(store: var Store; idx: int): Digest256 =
  result = makeDigest(byte(0x60 + idx))
  var prefixId: PrefixIdBytes
  for i in 0 ..< 32: prefixId[i] = result[i]
  let row = PrefixRow(prefixId: prefixId, packageName: "pkg-" & $idx,
    version: "1.0", realizedPath: "prefixes/pkg-" & $idx & "/1.0-" & $idx,
    adapter: "path", receiptDigest: prefixId, createdAtUnix: 1700000000)
  discard insertPrefixOrIgnore(store, row)

proc identicalManifestBytes(prefixDigest: Digest256): seq[byte] =
  ## A manifest with a fixed set of records. The bytes are
  ## deterministic, so two calls to this proc return byte-equal
  ## sequences and therefore the same BLAKE3-256 digest.
  var manifest = ActivationManifest(schemaVersion: 1'u16)
  manifest.realizedPackages = @[
    RealizedPackage(packageId: "shared-pkg",
      realizedPrefixId: prefixDigest, adapter: "path",
      provenance: @[byte('p'), byte('a'), byte('t'), byte('h')])]
  manifest.exportedCommands = @[
    ExportedCommand(commandName: "shared-cmd",
      launchPlanDigest: makeDigest(0xa0'u8),
      binDirRelativePath: "shared-cmd",
      binDirArtifactKind: "symlink")]
  manifest.generatedFiles = @[]
  manifest.managedBlocks = @[]
  manifest.resourceBindings = @[]
  encodeManifest(manifest)

proc identicalSnapshotBytes(): seq[byte] =
  ## Same as above but for the intent snapshot.
  var snap = IntentSnapshot(schemaVersion: 1'u16)
  let body = "profile shared"
  var content = newSeq[byte](body.len)
  for i, ch in body: content[i] = byte(ord(ch))
  snap.files = @[IntentFileEntry(path: "home.nim", content: content)]
  encodeSnapshot(snap)

proc identicalRbcgBytes(): seq[byte] =
  result.add(byte('R'))
  result.add(byte('B'))
  result.add(byte('C'))
  result.add(byte('G'))
  for i in 0 ..< 32: result.add(byte(i and 0xff))

# ---------------------------------------------------------------------------
# The gate.
# ---------------------------------------------------------------------------

suite "M62 gate 2: activation manifest dedup in CAS":

  let storeRoot = absolutePath(FixtureDir / "store")
  let stateDir = absolutePath(FixtureDir / "state")
  resetDir(FixtureDir)
  resetDir(storeRoot)
  resetDir(stateDir)
  var store = openStore(storeRoot)

  let prefixDigest = seedPrefix(store, 0)
  # Build the SAME manifest / snapshot / RBCG bytes twice, just with
  # different *pointer* timestamps (simulating apply -> rollback ->
  # re-apply).
  let manifestBytesA = identicalManifestBytes(prefixDigest)
  let manifestBytesB = identicalManifestBytes(prefixDigest)
  doAssert manifestBytesA == manifestBytesB,
    "fixture-level error: manifest bytes are NOT byte-identical"

  let snapshotBytes = identicalSnapshotBytes()
  let rbcgBytes = identicalRbcgBytes()

  # Two pointers with different timestamps + different host identities
  # (to force a different generation id), but identical manifest /
  # snapshot / RBCG content.
  var envA = PointerEnvelope(schemaVersion: 1'u16,
    activationTimestamp: 1700000000'i64,
    hostIdentity: "dev-laptop")
  envA.realizedPrefixIds = @[prefixDigest]
  envA.generationId = computeGenerationId(makeDigest(0x11'u8),
    "dev-laptop", 1700000000'i64)

  var envB = PointerEnvelope(schemaVersion: 1'u16,
    activationTimestamp: 1700000999'i64,
    hostIdentity: "dev-laptop")
  envB.realizedPrefixIds = @[prefixDigest]
  envB.generationId = computeGenerationId(makeDigest(0x22'u8),
    "dev-laptop", 1700000999'i64)

  writeGeneration(stateDir, envA, manifestBytesA, snapshotBytes,
    rbcgBytes, store)
  writeGeneration(stateDir, envB, manifestBytesB, snapshotBytes,
    rbcgBytes, store)
  store.close()

  test "both pointers reference the same activation manifest digest":
    let a = readPointerFile(pointerPath(stateDir,
      generationIdHex(envA.generationId)))
    let b = readPointerFile(pointerPath(stateDir,
      generationIdHex(envB.generationId)))
    check a.activationManifestDigest == b.activationManifestDigest
    # And the timestamps DIFFER (this is the "fresh timestamp" part of
    # the spec's invariant).
    check a.activationTimestamp != b.activationTimestamp

  test "only one CAS blob exists for the activation manifest digest":
    # Compute the on-disk CAS path for the manifest digest and verify
    # exactly one blob is present at that path.
    let manifestKeyA: array[32, byte] = block:
      var k: array[32, byte]
      for i in 0 ..< 32: k[i] = envA.activationManifestDigest[i]
      k
    let manifestKeyB: array[32, byte] = block:
      var k: array[32, byte]
      for i in 0 ..< 32: k[i] = envB.activationManifestDigest[i]
      k
    check manifestKeyA == manifestKeyB
    let casRelative = casBlobRelative(manifestKeyA)
    let blobPath = storeRoot / casRelative
    check fileExists(blobPath)
    # Read it back and compare to the manifest bytes — round-trip.
    var verifyStore = openStore(storeRoot)
    defer: verifyStore.close()
    let raw = readCasBlob(verifyStore, manifestKeyA)
    check raw == manifestBytesA

  test "the intent snapshot also dedups (byte-identical inputs)":
    # While we're here: snapshot dedup is the same invariant. Spec's
    # "Intent Snapshot" section: two generations whose intent layer
    # is byte-identical share one CAS intent snapshot.
    let a = readPointerFile(pointerPath(stateDir,
      generationIdHex(envA.generationId)))
    let b = readPointerFile(pointerPath(stateDir,
      generationIdHex(envB.generationId)))
    check a.intentSnapshotDigest == b.intentSnapshotDigest
    var snapKey: array[32, byte]
    for i in 0 ..< 32: snapKey[i] = a.intentSnapshotDigest[i]
    let blobPath = storeRoot / casBlobRelative(snapKey)
    check fileExists(blobPath)

## M62 gate 1: integration_pointer_envelope_and_history_enumeration.
##
## Per Reprobuild-Development.milestones.org:
##
##   "Write three generations through the apply pipeline; verify each
##    pointer contains only the audited field set and that all CAS-
##    digest references resolve; verify `repro home history` lists all
##    three by walking `generations/` without reading any separate
##    history file; corrupt a pointer and verify it is quarantined
##    rather than silently used."
##
## At M62 there is no apply pipeline yet (M63 owns that). This gate
## composes the three generations by hand through the library API:
## each generation gets a complete pointer + manifest + intent
## snapshot, written via `writeGeneration`, with the CAS-resident
## artifacts sealed atomically with the pointer.

import std/[os, osproc, streams, strtabs, strutils, unittest]

import repro_home_generations
import repro_local_store

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir()
  .parentDir()

const FixtureDir = "build/test-tmp/m62-gate1"

proc resetDir(path: string) =
  if dirExists(path):
    removeDir(path)
  createDir(path)

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; the gate's `just` recipe is responsible for building it"
  candidate

proc makeDigest(seed: byte): Digest256 =
  for i in 0 ..< 32:
    result[i] = byte((int(seed) + i) and 0xff)

proc seedPrefix(store: var Store; idx: int): Digest256 =
  ## Seed a `prefixes` row so the FK from `root_holds_prefix` is
  ## satisfied when we attach this prefix to the generation root.
  result = makeDigest(byte(0x10 + idx))
  var prefixId: PrefixIdBytes
  for i in 0 ..< 32:
    prefixId[i] = result[i]
  let row = PrefixRow(prefixId: prefixId, packageName: "pkg-" & $idx,
    version: "1.0", realizedPath: "prefixes/pkg-" & $idx & "/1.0-" & $idx,
    adapter: "path", receiptDigest: prefixId, createdAtUnix: 1700000000)
  discard insertPrefixOrIgnore(store, row)

proc buildManifestBytes(idx: int; prefixDigest: Digest256): seq[byte] =
  var manifest = ActivationManifest(schemaVersion: 1'u16)
  manifest.realizedPackages = @[
    RealizedPackage(packageId: "pkg-" & $idx,
      realizedPrefixId: prefixDigest, adapter: "path",
      provenance: @[byte(idx)])]
  manifest.exportedCommands = @[]
  manifest.generatedFiles = @[]
  manifest.managedBlocks = @[]
  manifest.resourceBindings = @[]
  encodeManifest(manifest)

proc buildSnapshotBytes(idx: int): seq[byte] =
  var snap = IntentSnapshot(schemaVersion: 1'u16)
  let body = "profile gen-" & $idx
  var content = newSeq[byte](body.len)
  for i, ch in body: content[i] = byte(ord(ch))
  snap.files = @[IntentFileEntry(path: "home.nim", content: content)]
  encodeSnapshot(snap)

proc buildRbcgBytes(idx: int): seq[byte] =
  result.add(byte('R'))
  result.add(byte('B'))
  result.add(byte('C'))
  result.add(byte('G'))
  result.add(byte(idx))
  for i in 0 ..< 32: result.add(byte(i * idx and 0xff))

proc writeFixtureGeneration(stateDir: string; store: var Store;
                           hostIdentity: string; timestamp: int64;
                           idx: int): PointerEnvelope =
  let prefixDigest = seedPrefix(store, idx)
  let manifestBytes = buildManifestBytes(idx, prefixDigest)
  let snapshotBytes = buildSnapshotBytes(idx)
  let rbcgBytes = buildRbcgBytes(idx)
  # The id is computed pre-write off the *intended* snapshot digest;
  # writeGeneration overwrites the three digest fields with the
  # actual CAS keys it sealed, but the id field itself is honored
  # verbatim. M63's apply pipeline will derive the id from the
  # resolved inputs in one pass.
  var envelope = PointerEnvelope(
    schemaVersion: 1'u16,
    activationTimestamp: timestamp,
    hostIdentity: hostIdentity)
  envelope.realizedPrefixIds = @[prefixDigest]
  let placeholderSnapshotDigest = makeDigest(byte(0x80 + idx))
  envelope.generationId = computeGenerationId(placeholderSnapshotDigest,
    hostIdentity, timestamp)
  writeGeneration(stateDir, envelope, manifestBytes, snapshotBytes,
    rbcgBytes, store)
  result = envelope

proc runReproHomeHistory(stateDir: string):
    tuple[exitCode: int; combined: string] =
  let bin = reproBinary()
  var processEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    processEnv[k] = v
  processEnv["REPRO_HOME_STATE_DIR"] = stateDir
  let p = startProcess(bin, args = ["home", "history"], env = processEnv,
    options = {poUsePath, poStdErrToStdOut})
  let stream = p.outputStream()
  var combined = ""
  while not stream.atEnd():
    let chunk = stream.readAll()
    if chunk.len == 0:
      break
    combined.add chunk
  let code = p.waitForExit()
  p.close()
  result = (exitCode: code, combined: combined)

# ---------------------------------------------------------------------------
# The gate.
# ---------------------------------------------------------------------------

suite "M62 gate 1: pointer envelope + history enumeration":

  let storeRoot = absolutePath(FixtureDir / "store")
  let stateDir = absolutePath(FixtureDir / "state")
  resetDir(FixtureDir)
  resetDir(storeRoot)
  resetDir(stateDir)
  var store = openStore(storeRoot)

  var envelopes: seq[PointerEnvelope]
  for idx in 0 .. 2:
    let env = writeFixtureGeneration(stateDir, store, "dev-laptop",
      timestamp = 1700000000'i64 + int64(idx * 60), idx = idx)
    envelopes.add(env)
  setActiveGeneration(stateDir, generationIdHex(envelopes[2].generationId))
  store.close()

  test "audited field set: file size matches expected_size for each generation":
    for env in envelopes:
      let p = pointerPath(stateDir, generationIdHex(env.generationId))
      let bytes = readFile(p)
      check bytes.len == expectedPointerFileSize(env)

  test "every CAS-digest reference resolves":
    var verifyStore = openStore(storeRoot)
    defer: verifyStore.close()
    for env in envelopes:
      var snapshotKey: PrefixIdBytes
      var rbcgKey: PrefixIdBytes
      var manifestKey: PrefixIdBytes
      for i in 0 ..< 32:
        snapshotKey[i] = env.intentSnapshotDigest[i]
        rbcgKey[i] = env.configurableGraphDigest[i]
        manifestKey[i] = env.activationManifestDigest[i]
      let snapshotBytes = readCasBlob(verifyStore, snapshotKey)
      let rbcgBytes = readCasBlob(verifyStore, rbcgKey)
      let manifestBytes = readCasBlob(verifyStore, manifestKey)
      check snapshotBytes.len > 0
      check rbcgBytes.len > 0
      check manifestBytes.len > 0
      let manifest = decodeManifestBytes(manifestBytes)
      check manifestDigest(manifest) == env.activationManifestDigest
      let snapshot = decodeSnapshotBytes(snapshotBytes)
      check snapshot.files.len == 1
      check snapshot.files[0].path == "home.nim"
      for prefixDigest in env.realizedPrefixIds:
        var prefixId: PrefixIdBytes
        for i in 0 ..< 32: prefixId[i] = prefixDigest[i]
        let lookup = lookupPrefix(verifyStore, prefixId)
        check lookup.found

  test "no history.bin file exists anywhere under the state dir":
    var historyFiles: seq[string]
    for path in walkDirRec(stateDir):
      if extractFilename(path).toLowerAscii() == "history.bin":
        historyFiles.add(path)
    check historyFiles.len == 0

  test "enumerateGenerations walks generations/ only and returns all three":
    let records = enumerateGenerations(stateDir)
    check records.len == 3
    check records[0].activationTimestamp == 1700000000'i64
    check records[1].activationTimestamp == 1700000060'i64
    check records[2].activationTimestamp == 1700000120'i64
    check records[2].isActive
    check (not records[0].isActive)
    check (not records[1].isActive)

  test "`repro home history` prints all three generations":
    let (rc, combined) = runReproHomeHistory(stateDir)
    check rc == 0
    for env in envelopes:
      let id = generationIdHex(env.generationId)
      # Use the first 12 hex chars as the short form (the CLI prints
      # short ids alongside the active marker).
      check combined.contains(id[0 ..< 12])
    let activeId = generationIdHex(envelopes[2].generationId)
    check combined.contains(activeId[0 ..< 12])
    check combined.contains("active")

  test "corrupt pointer fails closed (EPointerCorrupt) rather than silently used":
    let p = pointerPath(stateDir,
      generationIdHex(envelopes[0].generationId))
    let originalBytes = readFile(p)
    var corrupted = originalBytes
    let mid = (10 + originalBytes.len - 32) div 2
    corrupted[mid] = char(byte(corrupted[mid]) xor 0xff'u8)
    let corruptPath = p & ".corrupt"
    writeFile(corruptPath, corrupted)
    var raised = false
    try:
      discard readPointerFile(corruptPath)
    except EPointerCorrupt:
      raised = true
    check raised
    writeFile(p, originalBytes)

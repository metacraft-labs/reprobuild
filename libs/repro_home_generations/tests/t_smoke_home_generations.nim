## Smoke test for the M62 home generation registry library. Pins the
## library compiles + the basic round-trips work: pointer envelope,
## activation manifest, intent snapshot. The integration gates under
## `tests/e2e/home-generations/` exercise the full plan-apply-record
## pipeline against the M56 store + apply lock.

import std/[os, unittest]
from repro_core/paths import extendedPath

import blake3
import repro_home_generations
from repro_test_support import testCaseScratchSlug

let SmokeDir = "build/test-tmp/home-generations-smoke" / testCaseScratchSlug()

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc writeSamplePointer(p: string): tuple[env: PointerEnvelope,
                                             realized: Digest256] =
  ## The envelope both pointer cases start from. Each case writes its OWN
  ## copy: cases run as separate processes, in no guaranteed order, so the
  ## corruption case cannot rely on a file the round-trip case left behind.
  var env = PointerEnvelope(
    schemaVersion: 1'u16,
    activationTimestamp: 1700000000'i64,
    hostIdentity: "dev-laptop")
  for i in 0 ..< 32:
    env.intentSnapshotDigest[i] = byte(i)
    env.configurableGraphDigest[i] = byte(0x40 + i)
    env.activationManifestDigest[i] = byte(0x80 + i)
  var realized: Digest256
  for i in 0 ..< 32:
    realized[i] = byte(0xc0 + i)
  env.realizedPrefixIds = @[realized]
  env.generationId = computeGenerationId(env.intentSnapshotDigest,
    env.hostIdentity, env.activationTimestamp)
  writePointerFile(p, env)
  (env, realized)

suite "Home-generations smoke":

  test "pointer envelope round-trip preserves audited field set":
    resetDir(SmokeDir)
    let p = SmokeDir / "pointer.bin"
    let (env, realized) = writeSamplePointer(p)
    let decoded = readPointerFile(p)
    check decoded.schemaVersion == 1'u16
    check decoded.activationTimestamp == 1700000000'i64
    check decoded.hostIdentity == "dev-laptop"
    check decoded.generationId == env.generationId
    check decoded.intentSnapshotDigest == env.intentSnapshotDigest
    check decoded.configurableGraphDigest == env.configurableGraphDigest
    check decoded.activationManifestDigest == env.activationManifestDigest
    check decoded.realizedPrefixIds.len == 1
    check decoded.realizedPrefixIds[0] == realized
    # No padding, no extras: the on-disk file size equals the field
    # sizes plus the envelope frame.
    let onDiskBytes = readFile(extendedPath(p))
    check onDiskBytes.len == expectedPointerFileSize(env)

  test "corrupt pointer body byte fails closed":
    resetDir(SmokeDir)
    let p = SmokeDir / "pointer.bin"
    discard writeSamplePointer(p)
    var raw = readFile(extendedPath(p))
    # Flip a byte in the middle of the body (well past the magic +
    # version + bodyLen header, well before the trailing checksum).
    let mid = raw.len div 2
    raw[mid] = char(byte(raw[mid]) xor 0xff'u8)
    let corrupt = SmokeDir / "pointer-corrupt.bin"
    writeFile(extendedPath(corrupt), raw)
    expect EPointerCorrupt:
      discard readPointerFile(corrupt)

  test "activation manifest digest is stable across re-encodes":
    var manifest = ActivationManifest(schemaVersion: 1'u16)
    var prefixId: Digest256
    for i in 0 ..< 32: prefixId[i] = byte(i)
    manifest.realizedPackages = @[RealizedPackage(
      packageId: "fd",
      realizedPrefixId: prefixId,
      adapter: "scoop",
      provenance: @[byte('s'), byte('c')])]
    let a = encodeManifest(manifest)
    let b = encodeManifest(manifest)
    check a == b
    check manifestDigest(manifest) == manifestDigest(manifest)
    let decoded = decodeManifestBytes(a)
    check decoded.realizedPackages.len == 1
    check decoded.realizedPackages[0].packageId == "fd"
    check decoded.realizedPackages[0].adapter == "scoop"

  test "a manifest with owned concerns is schema 3; without, schema 2 and " &
       "byte-identical":
    # GM7: a generation whose host declares the concerns Reprobuild applies
    # records them (trailing section, schema 3). Without a declaration the
    # writer stays at schema 2, so every earlier manifest's bytes -- and
    # their CAS dedup -- are unchanged.
    var plain = ActivationManifest(schemaVersion: 2'u16)
    plain.resourceBindings = @[ResourceBinding(resourceAddress: "a",
      resourceKind: "fs.userFile")]
    let plainBytes = encodeManifest(plain)
    check plainBytes[4] == 2'u8 and plainBytes[5] == 0'u8
    var owned = plain
    owned.concernsDeclared = true
    owned.ownedConcerns = @["applications", "environment"]
    let ownedBytes = encodeManifest(owned)
    check ownedBytes[4] == 3'u8 and ownedBytes[5] == 0'u8
    let decoded = decodeManifestBytes(ownedBytes)
    check decoded.concernsDeclared
    check decoded.ownedConcerns == @["applications", "environment"]
    check decoded.resourceBindings.len == 1
    check decoded.resourceBindings[0].resourceKind == "fs.userFile"
    let decodedPlain = decodeManifestBytes(plainBytes)
    check not decodedPlain.concernsDeclared
    check decodedPlain.ownedConcerns.len == 0
    # Declared but empty: a host where Reprobuild applies nothing.
    var none = plain
    none.concernsDeclared = true
    let noneDecoded = decodeManifestBytes(encodeManifest(none))
    check noneDecoded.concernsDeclared and noneDecoded.ownedConcerns.len == 0

  test "intent snapshot is bit-exact":
    var snap = IntentSnapshot(schemaVersion: 1'u16)
    let fileA = IntentFileEntry(path: "home.nim",
      content: @[byte('p'), byte('r'), byte('o'), byte('f'), byte('i'),
        byte('l'), byte('e')])
    let fileB = IntentFileEntry(path: "helpers.nim", content: @[])
    snap.files = @[fileA, fileB]
    let bytes = encodeSnapshot(snap)
    let decoded = decodeSnapshotBytes(bytes)
    check decoded.files.len == 2
    check decoded.files[0].path == "home.nim"
    check decoded.files[0].content == fileA.content
    check decoded.files[1].path == "helpers.nim"
    check decoded.files[1].content.len == 0

  test "GM4: data files carry a role; a source-only snapshot stays version 1":
    let source = IntentFileEntry(path: "home.nim", content: @[byte('p')])
    let sourceOnly = IntentSnapshot(files: @[source])
    let v1 = encodeSnapshot(sourceOnly)
    # Version 1 framing, no role byte: the bytes (and so the generation id of
    # a profile without data files) are what they were before GM4.
    check v1[4] == 1'u8 and v1[5] == 0'u8
    check encodedVersion(sourceOnly) == SnapshotSourceOnlyVersion
    let data = IntentFileEntry(path: "data/apps.toml",
      content: @[byte('['), byte('[')], role: ifrData)
    let withData = IntentSnapshot(files: @[source, data])
    let v2 = encodeSnapshot(withData)
    check v2[4] == 2'u8 and v2[5] == 0'u8
    let decoded = decodeSnapshotBytes(v2)
    check decoded.schemaVersion == 2'u16
    check decoded.files.len == 2
    check decoded.files[0].role == ifrSource
    check decoded.files[1].role == ifrData
    check decoded.files[1].path == "data/apps.toml"
    check decoded.files[1].content == data.content
    # Different data bytes, different snapshot digest (and generation id).
    var edited = withData
    edited.files[1].content = @[byte('#')]
    check snapshotDigest(edited) != snapshotDigest(withData)
    # An unknown role is corruption, not a source file.
    var corrupt = v2
    let roleAt = 10 + 4 + 4 + "home.nim".len
    check corrupt[roleAt] == 0'u8
    corrupt[roleAt] = 7'u8
    let bodyEnd = corrupt.len - 32
    let checksum = blake3.digest(corrupt[0 ..< bodyEnd])
    for i in 0 ..< 32:
      corrupt[bodyEnd + i] = checksum[i]
    var field = ""
    try:
      discard decodeSnapshotBytes(corrupt)
    except EIntentSnapshotCorrupt as e:
      field = e.field
    check field == "files[0].role"

  test "state-dir resolution honours REPRO_HOME_STATE_DIR":
    let probe = SmokeDir / "state"
    putEnv("REPRO_HOME_STATE_DIR", probe)
    check resolveStateDir() == probe
    delEnv("REPRO_HOME_STATE_DIR")

  test "apply lock excludes a second acquirer":
    let dir = SmokeDir / "applylock-smoke"
    resetDir(dir)
    var lockA = acquireApplyLock(dir, timeoutSeconds = 1)
    expect EApplyBusy:
      discard acquireApplyLock(dir, timeoutSeconds = 1)
    releaseApplyLock(lockA)
    # After release, a fresh acquirer succeeds.
    var lockB = acquireApplyLock(dir, timeoutSeconds = 1)
    releaseApplyLock(lockB)

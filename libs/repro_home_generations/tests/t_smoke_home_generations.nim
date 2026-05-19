## Smoke test for the M62 home generation registry library. Pins the
## library compiles + the basic round-trips work: pointer envelope,
## activation manifest, intent snapshot. The integration gates under
## `tests/e2e/home-generations/` exercise the full plan-apply-record
## pipeline against the M56 store + apply lock.

import std/[os, unittest]

import repro_home_generations

const SmokeDir = "build/test-tmp/home-generations-smoke"

proc resetDir(path: string) =
  if dirExists(path):
    removeDir(path)
  createDir(path)

suite "Home-generations smoke":

  test "pointer envelope round-trip preserves audited field set":
    resetDir(SmokeDir)
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
    let p = SmokeDir / "pointer.bin"
    writePointerFile(p, env)
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
    let onDiskBytes = readFile(p)
    check onDiskBytes.len == expectedPointerFileSize(env)

  test "corrupt pointer body byte fails closed":
    let p = SmokeDir / "pointer.bin"
    var raw = readFile(p)
    # Flip a byte in the middle of the body (well past the magic +
    # version + bodyLen header, well before the trailing checksum).
    let mid = raw.len div 2
    raw[mid] = char(byte(raw[mid]) xor 0xff'u8)
    let corrupt = SmokeDir / "pointer-corrupt.bin"
    writeFile(corrupt, raw)
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

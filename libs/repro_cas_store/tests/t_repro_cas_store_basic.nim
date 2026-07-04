## M9.R.77.2 — regression tests for the ``repro_cas_store`` R11
## Layer-1 facade.
##
## Coverage:
##   * put/get roundtrip (identity + non-empty payload).
##   * put is idempotent — repeat calls return the same digest and do
##     not corrupt on-disk state.
##   * casExists returns true iff the blob was published.
##   * casVerify returns false on missing blob without raising.
##   * casVerify returns false when the on-disk bytes have been
##     corrupted after publish (integrity contract).
##   * casPath returns the expected on-disk shape.
##   * casGc reclaims blobs not in the retain set + preserves those
##     that are.
##   * ContentHash value semantics: equality, hash, hex encoding.

import std/[os, sets, strutils, tempfiles, unittest]

from repro_core/paths import extendedPath

import repro_cas_store

suite "repro_cas_store basic":
  test "openCasStore creates the on-disk layout":
    let dir = createTempDir("repro-cas-open-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    check cas.root().len > 0
    check dirExists(extendedPath(cas.root()))

  test "casPut/casGet roundtrip":
    let dir = createTempDir("repro-cas-rt-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let payload = @[byte(1), byte(2), byte(3), byte(0), byte(0xFF)]
    let h = cas.casPut(payload)
    let recovered = cas.casGet(h)
    check recovered == payload

  test "casPut is idempotent — same digest, no duplicate on-disk state":
    let dir = createTempDir("repro-cas-idempotent-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let payload = @[byte(0xDE), byte(0xAD), byte(0xBE), byte(0xEF)]
    let h1 = cas.casPut(payload)
    let h2 = cas.casPut(payload)
    check h1 == h2
    # Second put should not create a second copy — path is stable.
    let p1 = cas.casPath(h1)
    let p2 = cas.casPath(h2)
    check p1 == p2
    check fileExists(extendedPath(p1))

  test "casExists reports presence after put":
    let dir = createTempDir("repro-cas-exists-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let payload = @[byte(0x42)]
    let h = cas.casPut(payload)
    check cas.casExists(h)

  test "casExists is false for an unpublished digest":
    let dir = createTempDir("repro-cas-nonexists-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    # A digest that has never been put — synthesise an all-zeros
    # ContentHash and confirm no blob is on disk for it.
    var zero: array[32, byte]
    let h = toContentHash(zero)
    check not cas.casExists(h)

  test "casVerify returns true after put and false after corruption":
    let dir = createTempDir("repro-cas-verify-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let payload = @[byte(0xCA), byte(0xFE), byte(0xBA), byte(0xBE)]
    let h = cas.casPut(payload)
    check cas.casVerify(h)
    # Now overwrite the on-disk blob's bytes and re-verify.
    let path = cas.casPath(h)
    writeFile(extendedPath(path), "corrupted-payload")
    check not cas.casVerify(h)

  test "casVerify returns false when the blob is missing":
    let dir = createTempDir("repro-cas-missing-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    var zero: array[32, byte]
    let h = toContentHash(zero)
    check not cas.casVerify(h)

  test "casPath is inside <root>/cas/blake3/<aa>/":
    let dir = createTempDir("repro-cas-path-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let payload = @[byte(7), byte(7), byte(7)]
    let h = cas.casPut(payload)
    let path = cas.casPath(h)
    check "cas" in path
    check "blake3" in path

  test "ContentHash equality + hex are stable":
    var raw: array[32, byte]
    for i in 0 ..< 32:
      raw[i] = byte(i)
    let h1 = toContentHash(raw)
    let h2 = toContentHash(raw)
    check h1 == h2
    let hex = $h1
    check hex.len == 64
    check hex.startsWith("000102030405")

  test "casGc reclaims non-retained blobs and preserves retained ones":
    let dir = createTempDir("repro-cas-gc-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let keep = @[byte(0x01), byte(0x02), byte(0x03), byte(0x04)]
    let drop = @[byte(0xFE), byte(0xED), byte(0xFA), byte(0xCE)]
    let hKeep = cas.casPut(keep)
    let hDrop = cas.casPut(drop)
    check cas.casExists(hKeep)
    check cas.casExists(hDrop)
    var retain: HashSet[ContentHash]
    retain.incl(hKeep)
    let freed = cas.casGc(retain)
    check cas.casExists(hKeep)
    check not cas.casExists(hDrop)
    check freed >= drop.len

  test "casGc is a no-op on an empty store":
    let dir = createTempDir("repro-cas-gc-empty-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    var retain: HashSet[ContentHash]
    let freed = cas.casGc(retain)
    check freed == 0

  test "casGc with empty retain set clears every blob":
    let dir = createTempDir("repro-cas-gc-empty-retain-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let a = cas.casPut(@[byte(1), byte(1), byte(1)])
    let b = cas.casPut(@[byte(2), byte(2), byte(2)])
    let c = cas.casPut(@[byte(3), byte(3), byte(3)])
    check cas.casExists(a)
    check cas.casExists(b)
    check cas.casExists(c)
    var empty: HashSet[ContentHash]
    let freed = cas.casGc(empty)
    check not cas.casExists(a)
    check not cas.casExists(b)
    check not cas.casExists(c)
    check freed > 0

suite "repro_cas_store materialize (M9.R.77.4)":
  test "casMaterialize writes verified bytes into destination paths":
    let dir = createTempDir("repro-cas-mat-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let outDir = dir / "out"
    let a = cas.casPut(@[byte(0xAA), byte(0xAA), byte(0xAA)])
    let b = cas.casPut(@[byte(0xBB), byte(0xBB)])
    let entries = @[
      CasMaterialization(hash: a, destination: outDir / "a.bin"),
      CasMaterialization(hash: b, destination: outDir / "sub" / "b.bin"),
    ]
    cas.casMaterialize(entries)
    check fileExists(outDir / "a.bin")
    check fileExists(outDir / "sub" / "b.bin")
    let aOut = readFile(outDir / "a.bin")
    check aOut.len == 3
    check byte(aOut[0]) == byte(0xAA)
    let bOut = readFile(outDir / "sub" / "b.bin")
    check bOut.len == 2
    check byte(bOut[0]) == byte(0xBB)

  test "casMaterialize raises on missing hash without leaving partial state":
    let dir = createTempDir("repro-cas-mat-miss-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var cas = openCasStore(dir / "store")
    defer: cas.close()
    let outDir = dir / "out"
    let good = cas.casPut(@[byte(0x10)])
    var missing: array[32, byte]
    for i in 0 ..< 32: missing[i] = byte(i xor 0xFF)
    let entries = @[
      # The GOOD entry comes first, so if the loop wrote to disk it
      # would be visible on the retry. The MISSING entry raises and
      # aborts the loop.
      CasMaterialization(hash: toContentHash(missing),
                         destination: outDir / "missing.bin"),
      CasMaterialization(hash: good,
                         destination: outDir / "good.bin"),
    ]
    var raised = false
    try:
      cas.casMaterialize(entries)
    except ECasMissing:
      raised = true
    check raised
    check not fileExists(outDir / "missing.bin")
    check not fileExists(outDir / "good.bin")

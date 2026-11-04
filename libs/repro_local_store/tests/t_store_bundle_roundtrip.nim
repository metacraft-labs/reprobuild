## Native-store bundles (docs/store-bundles.md): closure, export and import
## through the production store, action cache, GNU tar and zstd on a real
## temporary filesystem. No mocks.
##
## The central claim is §5.1: a record whose outputs were unpacked from a
## bundle (new inodes, so new ctimes) is a HIT after import, because import
## verified the bytes and re-witnessed the record — while an in-place edit
## after import is still rejected, so the tamper check is not weakened.
## §5.3: a source input re-checked-out with the same bytes but a new mtime is
## restamped, so its timestamp-policy record hits too.

import std/[json, os, strutils, tempfiles, times, unittest]

import repro_core
import repro_hash
import repro_local_store
import repro_local_store/store
import repro_local_store/store_bundle
import repro_test_support/reasoned_skip

proc weakOf(name: string): ContentDigest =
  var bytes = newSeq[byte](name.len)
  for i, ch in name:
    bytes[i] = byte(ord(ch))
  blake3DomainDigest(bytes, hdActionFingerprint)

proc toolsPresent(): bool =
  findExe("tar").len > 0 and findExe("zstd").len > 0

type Fixture = object
  top, store, ac, ws, outDir: string

proc roots(f: Fixture): BundleRoots =
  BundleRoots(storeRoot: f.store, actionCacheRoot: f.ac,
    workspaceRoots: @[f.ws])

proc lookup(f: Fixture; name: string): ActionCacheLookup =
  var cache = openActionCache(f.ac / "action-cache", attachShm = false)
  defer: cache.closeShmTier()
  var cas = openStore(f.ac)
  defer: cas.close()
  # `outputRoot` is what the engine passes (the action's directory); a
  # metadata-only record is only reusable in place when it is given.
  cache.lookupActionResult(cas, weakOf(name), ffpTimestamp,
    allowMetadataOnlyHit = true, outputRoot = f.ws)

proc makeFixture(): Fixture =
  result.top = createTempDir("repro-store-bundle-", "")
  result.store = result.top / "store"
  result.ac = result.top / "cache"
  result.ws = result.top / "ws"
  result.outDir = result.top / "bundle-out"
  let ws = result.ws
  createDir(ws / "src")
  createDir(ws / ".repro" / "output" / "install" / "lib")
  createDir(ws / "build")
  writeFile(ws / "src" / "in.txt", "source bytes\n")
  # Big enough, and varied enough, to need several 1 KiB parts.
  var blob = ""
  for i in 0 ..< 4000:
    blob.add($(i * 7919 mod 104729) & "\n")
  writeFile(ws / ".repro" / "output" / "install" / "lib" / "out.txt", blob)
  writeFile(ws / "build" / "gen.txt", "generated\n")

  # A source-built prefix the install mirror points at (`hashed` mode).
  var store = openStore(result.store)
  let staging = result.top / "staging"
  createDir(staging / "lib")
  writeFile(staging / "lib" / "libprobe.so", "prefix bytes\n")
  let realized = store.realizeDirectoryAsPrefix(staging, StoreReceiptHint(
    adapter: "path", packageName: "probe", version: "1.0",
    lockIdentity: "test"))
  store.close()
  writeFile(ws / ".repro" / "output" / ".realization-info",
    "platform=test\nstore-relative-path=" & realized.row.realizedPath & "\n")

  var cache = openActionCache(result.ac / "action-cache", attachShm = false)
  defer: cache.closeShmTier()
  var cas = openStore(result.ac)
  defer: cas.close()
  # Metadata-only, like a producer whose outputs stay in place.
  discard cache.recordActionResult(cas, weakOf("producer"), ffpTimestamp,
    [ws / "src" / "in.txt"],
    [ws / ".repro" / "output" / "install" / "lib" / "out.txt"],
    storeOutputBlobs = false)
  # Payload-backed, so its CAS blob must travel too.
  discard cache.recordActionResult(cas, weakOf("consumer"), ffpTimestamp,
    [ws / ".repro" / "output" / "install" / "lib" / "out.txt"],
    [ws / "build" / "gen.txt"])

proc wipe(f: Fixture) =
  ## What a fresh container has: no store, no cache, no outputs, and a
  ## checkout whose source files carry new mtimes.
  removeDir(f.store)
  removeDir(f.ac)
  removeDir(f.ws / ".repro")
  removeFile(f.ws / "build" / "gen.txt")
  let src = f.ws / "src" / "in.txt"
  writeFile(src, readFile(src))
  setLastModificationTime(src, getTime() - initDuration(hours = 3))

suite "store bundle contents format":
  test "fields round-trip through escaping":
    for value in ["plain", "tab\there", "new\nline", "back\\slash\\t"]:
      check unescapeField(escapeField(value)) == value
      check '\t' notin escapeField(value)
      check '\n' notin escapeField(value)

  test "edge directory names invert":
    let weak = weakOf("x")
    var parsed: ContentDigest
    check weakFromEdgeDirName(perEdgeRecordFileName(weak), parsed)
    check parsed == weak
    check not weakFromEdgeDirName("not-an-edge.rbar", parsed)

suite "store bundle round trip":
  test "export, wipe, import: records hit, tampering still rejected":
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let before = f.lookup("producer")
      checkpoint before.message
      check before.status == aclHit
      check f.lookup("consumer").status == aclHit

      # A record that writes outside every bundle root cannot travel: it is
      # reported, and the rest of the bundle is unaffected.
      block:
        writeFile(f.top / "elsewhere.txt", "outside\n")
        var cache = openActionCache(f.ac / "action-cache", attachShm = false)
        var cas = openStore(f.ac)
        discard cache.recordActionResult(cas, weakOf("outside"), ffpTimestamp,
          [f.ws / "src" / "in.txt"], [f.top / "elsewhere.txt"],
          storeOutputBlobs = false)
        cas.close()
        cache.closeShmTier()

      let closure = computeClosure(f.roots)
      check closure.edges.len == 3
      check closure.records.len == 2
      check closure.skippedRecords.len == 1
      check "outside the bundle roots" in closure.skippedRecords[0].reason
      check closure.prefixes.len == 1
      check closure.restamps.len == 1
      check closure.restamps[0].path == f.ws / "src" / "in.txt"
      var paths: seq[string]
      for e in closure.entries: paths.add(e.path)
      check f.ws / "build" / "gen.txt" in paths
      check f.ws / ".repro" / "output" / ".realization-info" in paths
      check closure.prefixes[0] / ReceiptFileName in paths
      # Sources come from version control, not from the bundle.
      check f.ws / "src" / "in.txt" notin paths
      var hasCasBlob = false
      for p in paths:
        if p.startsWith(f.ac / "cas" / "blake3"): hasCasBlob = true
      check hasCasBlob

      var opts = defaultExportOptions(f.outDir)
      opts.partSize = 1024
      opts.zstdLevel = 1
      let exported = exportBundle(closure, opts)
      check exported.parts.len > 1
      let manifest = parseJson(readFile(exported.manifestPath))
      check manifest["parts"].len == exported.parts.len
      check manifest["roots"]["storeRoot"].getStr() == f.store

      f.wipe()
      check f.lookup("producer").status != aclHit

      let report = importBundle(ImportOptions(bundleDir: f.outDir), f.roots)
      check not report.skippedExtraction
      check report.rewitnessedRecords == 2
      check report.restamped == 1
      check report.reinsertedPrefixes == 1
      check report.quarantinedPrefixes.len == 0
      check f.lookup("producer").status == aclHit
      check f.lookup("consumer").status == aclHit
      var store = openStore(f.store)
      check store.listPrefixes().len == 1
      var held = false
      for r in store.listRoots():
        if r.rootId == "bundle:" & report.bundleId and r.kind == "workspace":
          held = true
      check held
      store.close()

      # Idempotent: a second import unpacks nothing and still hits.
      let again = importBundle(ImportOptions(bundleDir: f.outDir), f.roots)
      check again.skippedExtraction
      check f.lookup("producer").status == aclHit

      # The ctime witness still catches an in-place rewrite after import.
      let outFile = f.ws / ".repro" / "output" / "install" / "lib" / "out.txt"
      let mtime = getLastModificationTime(outFile)
      var bytes = readFile(outFile)
      bytes[0] = (if bytes[0] == 'X': 'Y' else: 'X')
      writeFile(outFile, bytes)
      setLastModificationTime(outFile, mtime)
      # (A metadata-only record reports the in-place mismatch as a miss; a
      # payload-backed one as a rejected output. Neither is a hit.)
      check f.lookup("producer").status != aclHit

  test "refuses other absolute roots before writing anything":
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      var opts = defaultExportOptions(f.outDir)
      opts.zstdLevel = 1
      discard exportBundle(computeClosure(f.roots), opts)
      var elsewhere = f.roots
      elsewhere.storeRoot = f.top / "other-store"
      var message = ""
      try:
        discard importBundle(ImportOptions(bundleDir: f.outDir), elsewhere)
      except StoreBundleError as e:
        message = e.msg
      check "different absolute paths" in message
      check f.store in message
      check not dirExists(f.top / "other-store")

  test "a corrupted part is refused before it is unpacked":
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      var opts = defaultExportOptions(f.outDir)
      opts.partSize = 1024
      opts.zstdLevel = 1
      let exported = exportBundle(computeClosure(f.roots), opts)
      f.wipe()
      let last = f.outDir / exported.parts[^1].name
      var bytes = readFile(last)
      bytes[0] = char(ord(bytes[0]) xor 0xff)
      writeFile(last, bytes)
      var message = ""
      try:
        discard importBundle(ImportOptions(bundleDir: f.outDir), f.roots)
      except StoreBundleError as e:
        message = e.msg
      check "SHA-256" in message
      # Nothing was registered: no store index, no marker.
      check not fileExists(f.store / "index.db")

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
##
## The hostile-exporter suite at the end protects the confinement of an
## import: the part hashes come from the same unsigned manifest as the parts,
## so a bundle host can rewrite the stream and re-hash it at will, and only
## the importer's own check of the archive's members stands between that
## stream and the disk. Each case takes a real exported bundle, rewrites its
## tar stream with GNU tar, and re-splits and re-hashes it the way a hostile
## host would (`contents` is unchanged, so its SHA-256 still matches), then
## checks that the import refuses before writing. See reprobuild-pm
## issues/2026-11-12-bundle-extraction-writes-every-tar-member-under-before-
## checking-it-against-the-declared.md.

import std/[algorithm, json, os, osproc, sequtils, strutils, tempfiles, times,
    unittest]

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
      let last = f.outDir / exported.parts[^1].file
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

# ---------------------------------------------------------------------------
# A hostile exporter
# ---------------------------------------------------------------------------

proc run(cmd: string) =
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, cmd & "\n" & output

proc rel(path: string): string =
  ## The tar member name of an absolute path, as export writes it.
  path[1 .. ^1]

proc tamperedStream(f: Fixture; edit: proc (tarPath: string)) =
  ## Rewrite the exported bundle's tar stream with `edit`, then compress,
  ## split and re-hash it into the manifest, as a host serving the bundle
  ## could. `contents` (the first member) is left as it was, so the
  ## manifest's SHA-256 of it still matches.
  let work = f.top / "tamper"
  createDir(work)
  let tarPath = work / "stream.tar"
  let manifestPath = f.outDir / (DefaultHalfName & ".json")
  var manifest = parseJson(readFile(manifestPath))
  var cat = "cat"
  for p in parsePartsJson(manifest["parts"]):
    cat.add(" " & quoteShell(f.outDir / p.file))
  run(cat & " | zstd -q -dc --long=27 > " & quoteShell(tarPath))
  edit(tarPath)
  let (parts, _) = writeCompressedParts("cat " & quoteShell(tarPath) &
    " | zstd -q -c -1 --long=27", f.outDir, 1024)
  manifest["parts"] = partsJson(parts)
  writeFile(manifestPath, pretty(manifest) & "\n")

proc appendFrom(tarPath, base: string; members: openArray[string]) =
  ## Append `members` (relative to `base`) to the uncompressed `tarPath`.
  var cmd = "tar --format=posix -rf " & quoteShell(tarPath) & " -C " &
    quoteShell(base)
  for m in members: cmd.add(" " & quoteShell(m))
  run(cmd)

proc deleteMembers(tarPath: string; members: openArray[string]) =
  var cmd = "tar --delete -f " & quoteShell(tarPath)
  for m in members: cmd.add(" " & quoteShell(m))
  run(cmd)

proc importRefusal(f: Fixture): string =
  ## The import's refusal, or "" when it was accepted.
  try:
    discard importBundle(ImportOptions(bundleDir: f.outDir), f.roots)
  except StoreBundleError as e:
    result = e.msg
  checkpoint "import said: " & result

proc exportForTampering(f: Fixture) =
  var opts = defaultExportOptions(f.outDir)
  opts.partSize = 1024
  opts.zstdLevel = 1
  discard exportBundle(computeClosure(f.roots), opts)

suite "store bundle import confines the archive to what contents declares":
  test "a member outside every declared root is refused and not written":
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      f.exportForTampering()
      f.wipe()
      # Outside the store, the action cache and the workspace, but inside
      # this test's directory, so the test is safe to run unprivileged.
      let planted = f.top / "planted" / "evil.sh"
      f.tamperedStream(proc (tarPath: string) =
        createDir(planted.parentDir)
        writeFile(planted, "echo owned\n")
        appendFrom(tarPath, "/", [rel(planted)])
        removeDir(planted.parentDir))
      let message = f.importRefusal()
      check rel(planted) in message
      check not fileExists(planted)
      check not dirExists(planted.parentDir)
      # Refused before the unpack: nothing that contents declares was
      # written either.
      check not fileExists(f.ws / "build" / "gen.txt")
      check not fileExists(f.store / "index.db")

  test "a symlink carried where contents declares a directory is refused":
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      f.exportForTampering()
      f.wipe()
      # A fresh machine has no `build/` yet.
      removeDir(f.ws / "build")
      # `build/` is declared a directory. The stream carries a link there to
      # the version-controlled `src/` instead, and writes a file through it.
      let staging = f.top / "staging-link"
      f.tamperedStream(proc (tarPath: string) =
        deleteMembers(tarPath, [rel(f.ws / "build" / "gen.txt"),
          rel(f.ws / "build")])
        createDir(staging / rel(f.ws))
        createSymlink("src", staging / rel(f.ws / "build"))
        appendFrom(tarPath, staging, [rel(f.ws / "build")])
        removeDir(staging)
        createDir(staging / rel(f.ws / "build"))
        writeFile(staging / rel(f.ws / "build" / "planted.txt"), "planted\n")
        appendFrom(tarPath, staging, [rel(f.ws / "build" / "planted.txt")])
        removeDir(staging))
      let message = f.importRefusal()
      check rel(f.ws / "build") in message
      check not fileExists(f.ws / "src" / "planted.txt")
      check not symlinkExists(f.ws / "build")
      check not fileExists(f.ws / ".repro" / "output" / "install" / "lib" /
        "out.txt")

  test "a member carried twice is refused":
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      f.exportForTampering()
      # The second copy is appended while the original is still on disk, so
      # it is byte-for-byte the declared file: only the duplication is wrong.
      f.tamperedStream(proc (tarPath: string) =
        appendFrom(tarPath, "/", [rel(f.ws / "build" / "gen.txt")]))
      f.wipe()
      let message = f.importRefusal()
      check rel(f.ws / "build" / "gen.txt") in message
      check "once" in message
      check not fileExists(f.ws / "build" / "gen.txt")

  test "a declared member missing from the stream is refused before any write":
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      f.exportForTampering()
      f.wipe()
      f.tamperedStream(proc (tarPath: string) =
        deleteMembers(tarPath, [rel(f.ws / "build" / "gen.txt")]))
      let message = f.importRefusal()
      check rel(f.ws / "build" / "gen.txt") in message
      # A sentinel: another declared file, which an unpack would have
      # written, is absent.
      check not fileExists(f.ws / ".repro" / "output" / "install" / "lib" /
        "out.txt")
      check not fileExists(f.store / "index.db")

  test "a directory that is a symlink on this machine is not written through":
    # GNU tar follows an existing symlink in a member's leading directories.
    # A link already on disk below a root (planted by an earlier bundle,
    # which may declare an `l` entry, or made by anyone else) would carry
    # an unpack out of the roots even when every member is declared, so the
    # import refuses before it writes.
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      f.exportForTampering()
      f.wipe()
      let outside = f.top / "outside"
      createDir(outside)
      createDir(f.store)
      createSymlink(outside, f.store / BundlesDirName)
      let message = f.importRefusal()
      check (f.store / BundlesDirName) in message
      check "symlink" in message
      var written: seq[string]
      for p in walkDirRec(outside): written.add(p)
      check written.len == 0
      check not fileExists(f.ws / "build" / "gen.txt")
      check not fileExists(f.store / "index.db")

proc exportHostile(f: Fixture; edit: proc (c: var BundleClosure)) =
  ## Export a bundle whose `contents` a hostile exporter edited: the archive
  ## and `contents` agree, so only the importer's rules on what `contents`
  ## may declare stand in the way.
  var c = computeClosure(f.roots)
  edit(c)
  c.entries.sort(proc (a, b: BundleEntry): int = cmp(a.path, b.path))
  var opts = defaultExportOptions(f.outDir)
  opts.partSize = 1024
  opts.zstdLevel = 1
  discard exportBundle(c, opts)

proc linkEntry(path: string): BundleEntry =
  BundleEntry(kind: bekLink, mode: 0o777, digest: expandSymlink(path),
    mtimeNs: 0, path: path)

proc entriesBelow(dir: string): seq[string] =
  for p in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile,
      pcLinkToDir}):
    result.add(p)

suite "store bundle import keeps its own writes inside the roots":
  test "a devenv line names only its project's own carried frozen script":
    # `repro bundle restore --activate` writes `. <script>` into
    # /etc/profile.d and `repro store import --allow-dev-env` allow-lists the
    # project root, both straight from the `devenv` lines of `contents`. A
    # bundle host must not be able to point every later login shell at a
    # file anyone can write, nor allow-list a directory the bundle does not
    # carry (Store-Bundles §6). reprobuild-pm issues/2026-11-17-bundle-
    # devenv-lines-name-any-script-and-any-project-to-activate-and-allow.md.
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let script = frozenScriptPath(f.store, f.ws)
      createDir(script.parentDir)
      writeFile(script, "export FROZEN=1\n")
      let planted = f.top / "x.sh"
      writeFile(planted, "echo planted\n")
      setFilePermissions(planted, {fpUserRead, fpUserWrite, fpGroupRead,
        fpGroupWrite, fpOthersRead, fpOthersWrite})
      # A script outside the bundle, which a login shell would then source.
      f.exportHostile(proc (c: var BundleClosure) =
        c.devEnvs.add(FrozenDevEnv(projectRoot: f.ws, scriptPath: planted)))
      f.wipe()
      check "must be" in f.importRefusal()
      check not fileExists(f.ws / "build" / "gen.txt")
      # Another directory allow-listed, with its own frozen script carried:
      # the project lies outside the bundle's workspace roots.
      let g = makeFixture()
      defer: removeDir(g.top)
      let elsewhere = g.top / "elsewhere"
      let otherScript = frozenScriptPath(g.store, elsewhere)
      createDir(otherScript.parentDir)
      writeFile(otherScript, "export FROZEN=1\n")
      g.exportHostile(proc (c: var BundleClosure) =
        c.entries.add(BundleEntry(kind: bekFile, mode: 0o644,
          size: getFileSize(otherScript), digest: fileBlake3Hex(otherScript),
          mtimeNs: (let t = getLastModificationTime(otherScript);
            t.toUnix * 1_000_000_000'i64 + t.nanosecond),
          path: otherScript))
        c.devEnvs.add(FrozenDevEnv(projectRoot: elsewhere,
          scriptPath: otherScript)))
      g.wipe()
      check "not in its workspace roots" in g.importRefusal()
      check not fileExists(g.ws / "build" / "gen.txt")
      # Export refuses to write either, as it does any bundle import refuses.
      var exportRefusal = ""
      try:
        discard computeClosure(g.roots,
          [FrozenDevEnv(projectRoot: g.ws, scriptPath: planted)])
      except StoreBundleError as e:
        exportRefusal = e.msg
      check "must be" in exportRefusal
      # The right script, carried as a hard link shared with a workspace
      # file: whoever can write that file would change what login shells
      # source. GNU tar writes the second name of an inode as a hard link.
      let h = makeFixture()
      defer: removeDir(h.top)
      let linked = frozenScriptPath(h.store, h.ws)
      createDir(linked.parentDir)
      writeFile(linked, "export FROZEN=1\n")
      let shared = h.ws / "x.sh"
      createHardlink(linked, shared)
      h.exportHostile(proc (c: var BundleClosure) =
        let t = getLastModificationTime(linked)
        let mtime = t.toUnix * 1_000_000_000'i64 + t.nanosecond
        for path in [linked, shared]:
          if not c.entries.anyIt(it.path == path):
            c.entries.add(BundleEntry(kind: bekFile, mode: 0o644,
              size: getFileSize(path), digest: fileBlake3Hex(path),
              mtimeNs: mtime, path: path))
        c.devEnvs.add(FrozenDevEnv(projectRoot: h.ws, scriptPath: linked)))
      h.wipe()
      check "hard link" in h.importRefusal()
      check not fileExists(h.ws / "build" / "gen.txt")
      # What export writes is accepted, and import reports it.
      let f3 = makeFixture()
      defer: removeDir(f3.top)
      let script3 = frozenScriptPath(f3.store, f3.ws)
      createDir(script3.parentDir)
      writeFile(script3, "export FROZEN=1\n")
      var opts = defaultExportOptions(f3.outDir)
      opts.partSize = 1024
      opts.zstdLevel = 1
      discard exportBundle(computeClosure(f3.roots,
        [FrozenDevEnv(projectRoot: f3.ws, scriptPath: script3)]), opts)
      f3.wipe()
      let report = importBundle(ImportOptions(bundleDir: f3.outDir), f3.roots)
      check report.devEnvs == @[FrozenDevEnv(projectRoot: f3.ws,
        scriptPath: script3)]
      check readFile(script3) == "export FROZEN=1\n"

  test "a symlink declared over the store's own files is refused":
    # The unpack writes only the link, inside the root; it is the importer
    # opening `index.db` afterwards (and every later `repro`) that would
    # create the database, its -wal and -shm wherever the link points.
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let outside = f.top / "outside"
      createDir(outside)
      let db = f.store / "index.db"
      moveFile(db, f.top / "index.db.real")
      createSymlink(outside / "pwned.db", db)
      f.exportHostile(proc (c: var BundleClosure) =
        c.entries.add(linkEntry(db)))
      f.wipe()
      let message = f.importRefusal()
      check db in message
      check "outside everything a bundle carries" in message
      check entriesBelow(outside).len == 0
      check not fileExists(f.ws / "build" / "gen.txt")

  test "a regular file carried over the store's own index is refused":
    # Not a link, so nothing is written outside at once; but a crafted
    # index.db could name prefix paths outside the store for a later GC to
    # delete. A bundle never carries the store's own state (§2).
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let db = f.store / "index.db"
      f.exportHostile(proc (c: var BundleClosure) =
        c.entries.add(BundleEntry(kind: bekFile, mode: 0o644,
          size: getFileSize(db), digest: fileBlake3Hex(db), path: db)))
      f.wipe()
      let message = f.importRefusal()
      check db in message
      check not fileExists(db)
      check not fileExists(f.ws / "build" / "gen.txt")

  test "a symlink outside a prefix is refused even where a bundle carries files":
    # Compiler-probe markers are carried, but nothing there is a link, and
    # one would be followed by the probe code that writes markers later.
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let outside = f.top / "outside"
      createDir(outside)
      let probes = f.store / "compiler-probes"
      createDir(probes)
      let lnk = probes / "planted"
      createSymlink(outside, lnk)
      f.exportHostile(proc (c: var BundleClosure) =
        c.entries.add(linkEntry(lnk)))
      f.wipe()
      let message = f.importRefusal()
      check lnk in message
      check "outside every carried prefix" in message
      check entriesBelow(outside).len == 0

  test "a workspace root declared inside the action cache exempts nothing":
    # With no local workspace root the bundle's own are accepted, so a
    # bundle could name `<cache>/action-cache` as one; the cache's own
    # files must stay out of reach all the same.
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let planted = f.ac / "action-cache" / "planted-index"
      writeFile(planted, "crafted\n")
      f.exportHostile(proc (c: var BundleClosure) =
        c.roots.workspaceRoots.add(f.ac / "action-cache")
        c.entries.add(BundleEntry(kind: bekFile, mode: 0o644,
          size: getFileSize(planted), digest: fileBlake3Hex(planted),
          path: planted)))
      f.wipe()
      var message = ""
      try:
        discard importBundle(ImportOptions(bundleDir: f.outDir),
          BundleRoots(storeRoot: f.store, actionCacheRoot: f.ac))
      except StoreBundleError as e:
        message = e.msg
      checkpoint "import said: " & message
      check planted in message
      check "outside everything a bundle carries" in message
      check not fileExists(planted)

  test "a symlink declared at a root is refused":
    # Everything the importer writes below that root afterwards would
    # follow it (a root nested in a workspace root makes this reachable
    # from an ordinary-looking workspace link).
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      f.exportHostile(proc (c: var BundleClosure) =
        for e in c.entries.mitems:
          if e.path == f.ws:
            e = BundleEntry(kind: bekLink, mode: 0o777, digest: "/etc",
              path: f.ws))
      f.wipe()
      let message = f.importRefusal()
      check "at or above the root" in message
      check not fileExists(f.ws / "build" / "gen.txt")

  test "a link inside a carried prefix is still accepted":
    # Packages carry links of their own (`libfoo.so -> libfoo.so.1`), and
    # nothing writes into a registered prefix, so the rule above spares them.
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      # Realized with the link in it (editing a realized prefix would only
      # get it quarantined for no longer matching its hash), and named by
      # the install mirror in place of the fixture's own prefix.
      let staging = f.top / "staging-linked"
      createDir(staging / "lib")
      writeFile(staging / "lib" / "liblinked.so", "linked prefix bytes\n")
      createSymlink("liblinked.so", staging / "lib" / "liblinked.so.1")
      var store = openStore(f.store)
      let realized = store.realizeDirectoryAsPrefix(staging, StoreReceiptHint(
        adapter: "path", packageName: "linked", version: "1.0",
        lockIdentity: "test"))
      store.close()
      writeFile(f.ws / ".repro" / "output" / ".realization-info",
        "platform=test\nstore-relative-path=" & realized.row.realizedPath &
        "\n")
      let closure = computeClosure(f.roots)
      var link = ""
      for e in closure.entries:
        if e.kind == bekLink: link = e.path
      check link.endsWith("/lib/liblinked.so.1")
      check closure.prefixes.anyIt(link.startsWith(it & "/"))
      f.exportForTampering()
      f.wipe()
      let report = importBundle(ImportOptions(bundleDir: f.outDir), f.roots)
      check not report.skippedExtraction
      check report.quarantinedPrefixes.len == 0
      check expandSymlink(link) == "liblinked.so"

  test "a prefix line that is not a store prefix directory is refused":
    # The symlink rule trusts what lies inside a carried prefix, so a bundle
    # must not be able to name the whole store as one.
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      f.exportHostile(proc (c: var BundleClosure) =
        c.prefixes.add(f.store))
      f.wipe()
      let message = f.importRefusal()
      check "not a store prefix directory" in message
      check not fileExists(f.ws / "build" / "gen.txt")

  test "a restamp below a declared symlink is refused":
    # Step 5.3 sets the mtime through every directory in the path, so a
    # bundle that declares `<ws>/lnk -> /elsewhere` and a restamp of
    # `<ws>/lnk/known.txt` with that file's digest would stamp a file
    # outside the roots.
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let outside = f.top / "outside"
      createDir(outside)
      let known = outside / "known.txt"
      writeFile(known, "known bytes\n")
      setLastModificationTime(known, fromUnix(1_000_000_000))
      let lnk = f.ws / "lnk"
      createSymlink(outside, lnk)
      f.exportHostile(proc (c: var BundleClosure) =
        c.entries.add(linkEntry(lnk))
        c.restamps.add(RestampEntry(size: getFileSize(known),
          mtimeNs: 1_234_000_000 * 1_000_000_000'i64,
          digest: fileBlake3Hex(known), path: lnk / "known.txt")))
      f.wipe()
      let message = f.importRefusal()
      check "below the symlink entry" in message
      check getLastModificationTime(known) == fromUnix(1_000_000_000)

  test "a restamp below a directory that is a symlink on this machine is skipped":
    # A link already on disk (one an earlier bundle declared, say) would
    # carry the mtime write out of the roots just the same. Sources are not
    # members, so the import itself goes ahead; the restamp is left undone.
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      f.exportForTampering()
      f.wipe()
      let src = f.ws / "src"
      let moved = f.top / "outside-src"
      moveDir(src, moved)
      createSymlink(moved, src)
      let before = getLastModificationTime(moved / "in.txt")
      let report = importBundle(ImportOptions(bundleDir: f.outDir), f.roots)
      check report.restamped == 0
      check report.restampMismatches == 1
      check getLastModificationTime(moved / "in.txt") == before

  test "the archive can be listed with a zstd that is not on PATH":
    # The Nix half falls back to its own zstd on a host without one, and
    # its member check must use that same decompressor.
    if not toolsPresent():
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      f.exportForTampering()
      let zstd = findExe("zstd")
      let bin = f.top / "bin-without-zstd"
      createDir(bin)
      # Everything the listing runs but zstd: bash runs its pipeline.
      for tool in ["tar", "bash"]:
        createSymlink(findExe(tool), bin / tool)
      let manifest = parseJson(readFile(f.outDir / (DefaultHalfName & ".json")))
      let parts = parsePartsJson(manifest["parts"])
      let listing = f.top / "members"
      let savedPath = getEnv("PATH")
      putEnv("PATH", bin)
      defer: putEnv("PATH", savedPath)
      expect StoreBundleError:
        listBundleMembers(f.outDir, parts, listing)
      listBundleMembers(f.outDir, parts, listing, zstd)
      check "contents" in readFile(listing)

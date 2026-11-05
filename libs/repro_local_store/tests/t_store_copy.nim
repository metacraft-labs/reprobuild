## `copyClosure` (`repro store copy --to=STORE-ROOT`): a realized closure
## moved from one local store root into another, on a real temporary
## filesystem through the production store. No mocks.
##
## What it pins:
##   * every copied prefix verifies at the destination: the same index row,
##     a byte-identical receipt, a tree that hashes to the receipt's content
##     digest, symbolic links and executable bits intact, and a destination
##     recovery that finds nothing to fix;
##   * the destination keeps the closure alive: a GC there reaps nothing;
##   * a second copy transfers nothing;
##   * a source prefix with one file deleted makes the copy fail before
##     anything is written, rather than copying the rest;
##   * multi-output siblings and root selection widen the closure;
##   * conflicts, an unknown root, a non-prefix path and the source store
##     itself as destination are refused;
##   * a prefix whose receipt records no content digest is copied, checked
##     against the source tree, and reported as unverified.
##   * a destination that realized the same prefix itself (a prewarmed
##     worker: same id and bytes, its own receipt seal) is taken as present,
##     while the same id with other bytes is a conflict;
##   * neither store may contain the other, and refusing leaves the source
##     intact;
##   * a re-copy that fails part-way keeps every earlier copy held, so a GC
##     after it reaps nothing it copied before;
##   * a prefix with a link leaving the store is reported external;
##   * a link into another prefix brings that prefix along (in either
##     spelling of a symlinked store root), a link into the store outside
##     any prefix is refused, and a destination prefix that is a link to the
##     source's is refused;
##   * links are resolved as the kernel resolves them: a link through a
##     directory symlink and `..` brings the prefix it really reaches, and a
##     destination whose package directory links into the source is refused.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_local_store/store
import repro_local_store/sqlite3_binding
import repro_local_store/store_copy
import repro_test_support/reasoned_skip

type Fixture = object
  top, src, dst: string
  tool: RealizeResult

proc stagingTree(top, name: string): string =
  result = top / ("staging-" & name)
  createDir(result / "bin")
  createDir(result / "share" / "empty")
  writeFile(result / "bin" / name, "#!/bin/sh\necho " & name & "\n")
  setFilePermissions(result / "bin" / name,
    {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec})
  writeFile(result / "share" / "data.txt", name & " data\n")
  createSymlink("../bin/" & name, result / "share" / "link")

proc realize(s: var Store; top, name: string): RealizeResult =
  s.realizeDirectoryAsPrefix(stagingTree(top, name), StoreReceiptHint(
    adapter: "path", packageName: name, version: "1.0",
    lockIdentity: "test-" & name))

proc makeFixture(): Fixture =
  result.top = createTempDir("repro-store-copy-", "")
  result.src = result.top / "src-store"
  result.dst = result.top / "dst-store"
  var s = openStore(result.src)
  defer: s.close()
  result.tool = s.realize(result.top, "tool")
  discard s.realize(result.top, "other")

proc copyOf(f: Fixture; prefixes: seq[string] = @[];
            rootIds: seq[string] = @[]): StoreCopyReport =
  copyClosure(StoreCopyRequest(sourceRoot: f.src, destinationRoot: f.dst,
    prefixes: prefixes, rootIds: rootIds))

proc indexedPaths(root: string): seq[string] =
  if not fileExists(root / "index.db"): return
  var s = openStore(root)
  defer: s.close()
  for row in s.listPrefixes(): result.add(row.realizedPath)

suite "repro store copy":
  test "a closure copied into an empty store verifies there and survives gc":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let rel = f.tool.relativePath
      let report = f.copyOf(@[f.src / rel / "bin" / "tool"])
      check report.closure == @[rel]
      check report.copied == @[rel]
      check report.alreadyPresent.len == 0
      check report.unverified.len == 0
      check report.copiedBytes > 0
      check indexedPaths(f.dst) == @[rel]

      var src = openStore(f.src)
      defer: src.close()
      var dst = openStore(f.dst)
      defer: dst.close()
      let srcRow = src.lookupPrefix(f.tool.prefixId)
      let dstRow = dst.lookupPrefix(f.tool.prefixId)
      check dstRow.found
      check dstRow.row == srcRow.row
      let dstDir = dst.absolutePrefixPath(rel)
      check readFile(dstDir / ReceiptFileName) ==
        readFile(f.src / rel / ReceiptFileName)
      let receipt = readReceiptFile(dstDir / ReceiptFileName)
      check receipt.contentDigest.len > 0
      check storeTreeDigest(dstDir) == receipt.contentDigest
      check expandSymlink(dstDir / "share" / "link") == "../bin/tool"
      check fpUserExec in getFilePermissions(dstDir / "bin" / "tool")
      # Realization drops empty directories; the copy carries exactly the
      # directories the source prefix has.
      check dirExists(dstDir / "share" / "empty") ==
        dirExists(f.src / rel / "share" / "empty")
      # An independent store: no shared inodes with the source.
      check getFileInfo(dstDir / "bin" / "tool").id !=
        getFileInfo(f.src / rel / "bin" / "tool").id

      let recovered = dst.recover()
      check recovered.reinsertedPrefixes.len == 0
      check recovered.quarantinedPrefixes.len == 0
      check dst.rootsHolding(f.tool.prefixId) == @[report.rootId]
      let gcReport = dst.gc(graceSeconds = 0)
      check gcReport.quarantined.len == 0
      check dirExists(dstDir)

  test "a second copy transfers nothing":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let first = f.copyOf(@[f.tool.relativePath])
      let again = f.copyOf(@[f.tool.relativePath])
      check first.copied.len == 1
      check again.copied.len == 0
      check again.copiedBytes == 0
      check again.alreadyPresent == @[f.tool.relativePath]
      check again.rootId == first.rootId

  test "a source prefix with a deleted file fails the copy and writes nothing":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      var s = openStore(f.src)
      let other = s.listPrefixes().filterIt(it.packageName == "other")[0]
      s.close()
      removeFile(f.src / f.tool.relativePath / "share" / "data.txt")
      expect StoreCopyError:
        discard f.copyOf(@[other.realizedPath, f.tool.relativePath])
      # Neither the damaged prefix nor the intact one reached the
      # destination: the closure is copied whole or not at all.
      check indexedPaths(f.dst).len == 0
      check not dirExists(f.dst / other.realizedPath)

  test "a damaged receipt fails the copy":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      writeFile(f.src / f.tool.relativePath / ReceiptFileName, "not a receipt")
      expect StoreCopyError:
        discard f.copyOf(@[f.tool.relativePath])
      check indexedPaths(f.dst).len == 0

  test "a root selects what it holds; multi-output siblings come along":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      var s = openStore(f.src)
      let bin = stagingTree(f.top, "multi-bin")
      let man = f.top / "staging-man"
      createDir(man / "man1")
      writeFile(man / "man1" / "multi.1", ".TH MULTI 1\n")
      let multi = s.realizeMultiOutput(StoreReceiptHint(adapter: "path",
        packageName: "multi", version: "2.0", lockIdentity: "test-multi"),
        [MultiOutputSpec(outputName: "bin", stagingDir: bin),
         MultiOutputSpec(outputName: "man", stagingDir: man)])
      s.registerRoot("held", rkPin)
      s.attachPrefixToRoot("held", f.tool.prefixId)
      s.close()
      let viaRoot = f.copyOf(rootIds = @["held"])
      check viaRoot.copied == @[f.tool.relativePath]
      # Naming only the `bin` output copies the `man` output too.
      let viaSibling = f.copyOf(@[multi.perOutput[0].relativePath])
      check viaSibling.closure.len == 2
      check multi.perOutput[1].relativePath in viaSibling.copied
      check multi.perOutput[0].relativePath in viaSibling.copied
      for o in multi.perOutput:
        check dirExists(f.dst / o.relativePath)

  test "refusals: unknown root, non-prefix path, self, conflicts":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      expect StoreCopyError:
        discard f.copyOf(rootIds = @["no-such-root"])
      expect StoreCopyError:
        discard f.copyOf(@[f.top])
      expect StoreCopyError:
        discard copyClosure(StoreCopyRequest(sourceRoot: f.src,
          destinationRoot: f.src, prefixes: @[f.tool.relativePath]))
      expect StoreCopyError:
        discard f.copyOf()
      # An unindexed directory where the prefix would land is not
      # overwritten.
      createDir(f.dst / f.tool.relativePath)
      writeFile(f.dst / f.tool.relativePath / "stray", "x")
      expect StoreCopyError:
        discard f.copyOf(@[f.tool.relativePath])
      check readFile(f.dst / f.tool.relativePath / "stray") == "x"
      check indexedPaths(f.dst).len == 0

  test "a destination indexing the prefix id at another path is a conflict":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      discard f.copyOf(@[f.tool.relativePath])
      var d = openStore(f.dst)
      var row = d.lookupPrefix(f.tool.prefixId).row
      row.realizedPath = "prefixes/tool/elsewhere"
      d.db.exec("BEGIN IMMEDIATE")
      d.db.exec("DELETE FROM root_holds_prefix")
      d.db.exec("DELETE FROM prefixes")
      discard d.insertPrefixOrIgnore(row)
      d.db.exec("COMMIT")
      d.close()
      expect StoreCopyError:
        discard f.copyOf(@[f.tool.relativePath])

  test "a receipt without a content digest is copied and reported unverified":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let rel = f.tool.relativePath
      var receipt = readReceiptFile(f.src / rel / ReceiptFileName)
      receipt.contentDigest = ""
      writeReceiptFile(f.src / rel / ReceiptFileName, receipt)
      var s = openStore(f.src)
      var row = s.lookupPrefix(f.tool.prefixId).row
      row.receiptDigest = receiptDigest(receipt)
      s.db.exec("BEGIN IMMEDIATE")
      s.db.exec("DELETE FROM prefixes")
      discard s.insertPrefixOrIgnore(row)
      s.db.exec("COMMIT")
      s.close()
      let report = f.copyOf(@[rel])
      check report.copied == @[rel]
      check report.unverified == @[rel]
      check storeTreeDigest(f.dst / rel) == storeTreeDigest(f.src / rel)

  test "a destination that realized the same prefix itself is prewarmed":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      # The worker built the same prefix: same prefix id and bytes, but a
      # receipt sealed at another time by another process.
      var d = openStore(f.dst)
      let own = d.realize(f.top / "worker", "tool")
      check own.prefixId == f.tool.prefixId
      # Realized in this process within the same second, the seal would
      # match the source's byte for byte; reseal it as another process at
      # another time would have, and index that receipt.
      let ownReceiptPath = f.dst / own.relativePath / ReceiptFileName
      var ownReceipt = readReceiptFile(ownReceiptPath)
      ownReceipt.createdAtUnix -= 3600
      ownReceipt.writerProcessId += 1
      writeReceiptFile(ownReceiptPath, ownReceipt)
      var ownRow = d.lookupPrefix(own.prefixId).row
      ownRow.receiptDigest = receiptDigest(ownReceipt)
      ownRow.createdAtUnix = ownReceipt.createdAtUnix
      d.db.exec("BEGIN IMMEDIATE")
      d.db.exec("DELETE FROM prefixes")
      discard d.insertPrefixOrIgnore(ownRow)
      d.db.exec("COMMIT")
      d.close()
      check readFile(ownReceiptPath) !=
        readFile(f.src / f.tool.relativePath / ReceiptFileName)
      let report = f.copyOf(@[f.tool.relativePath])
      check report.copied.len == 0
      check report.alreadyPresent == @[f.tool.relativePath]
      var d2 = openStore(f.dst)
      defer: d2.close()
      check d2.rootsHolding(f.tool.prefixId) == @[report.rootId]

  test "a destination prefix with the same id but other bytes is a conflict":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      var d = openStore(f.dst)
      discard d.realize(f.top / "worker", "tool")
      d.close()
      writeFile(f.dst / f.tool.relativePath / "share" / "data.txt", "changed\n")
      expect StoreCopyError:
        discard f.copyOf(@[f.tool.relativePath])

  test "neither store may contain the other, and the source is left intact":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let before = storeTreeDigest(f.src / f.tool.relativePath)
      for inside in [f.src / f.tool.relativePath / "mirror",
                     f.src / "tmp" / "mirror", f.src / "nested" / "store"]:
        expect StoreCopyError:
          discard copyClosure(StoreCopyRequest(sourceRoot: f.src,
            destinationRoot: inside, prefixes: @[f.tool.relativePath]))
        check not dirExists(inside)
      # The source inside the destination.
      expect StoreCopyError:
        discard copyClosure(StoreCopyRequest(sourceRoot: f.src,
          destinationRoot: f.top, prefixes: @[f.tool.relativePath]))
      check storeTreeDigest(f.src / f.tool.relativePath) == before

  test "a re-copy that fails part-way keeps every earlier copy held":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      var s = openStore(f.src)
      let other = s.listPrefixes().filterIt(it.packageName == "other")[0]
      s.close()
      let first = f.copyOf(@[other.realizedPath, f.tool.relativePath])
      check first.copied.len == 2
      # Lose `other` at the destination, and make its republish fail: a
      # file where its package directory belongs.
      var d = openStore(f.dst)
      d.db.exec("DELETE FROM prefixes WHERE realized_path = '" &
        other.realizedPath & "'")
      d.close()
      removeDir(f.dst / other.realizedPath.parentDir)
      writeFile(f.dst / other.realizedPath.parentDir, "blocker")
      expect OSError, IOError:
        discard f.copyOf(@[other.realizedPath, f.tool.relativePath])
      var d2 = openStore(f.dst)
      defer: d2.close()
      check d2.rootsHolding(f.tool.prefixId) == @[first.rootId]
      discard d2.gc(graceSeconds = 0)
      check dirExists(f.dst / f.tool.relativePath)

  test "a prefix linking outside the store is reported external":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let staging = f.top / "staging-ext"
      createDir(staging / "bin")
      createSymlink("/bin/sh", staging / "bin" / "sh")
      var s = openStore(f.src)
      let ext = s.realizeDirectoryAsPrefix(staging, StoreReceiptHint(
        adapter: "path", packageName: "ext", version: "1.0",
        lockIdentity: "test-ext"))
      s.close()
      check symlinkExists(f.src / ext.relativePath / "bin" / "sh")
      let report = f.copyOf(@[ext.relativePath, f.tool.relativePath])
      check report.external == @[ext.relativePath]
      check expandSymlink(f.dst / ext.relativePath / "bin" / "sh") == "/bin/sh"

proc realizeLinking(f: Fixture; name, linkRel, target: string): RealizeResult =
  ## A prefix whose only content is one symbolic link `linkRel` -> `target`.
  let staging = f.top / ("staging-" & name)
  createDir((staging / linkRel).parentDir)
  createSymlink(target, staging / linkRel)
  var s = openStore(f.src)
  defer: s.close()
  result = s.realizeDirectoryAsPrefix(staging, StoreReceiptHint(
    adapter: "path", packageName: name, version: "1.0",
    lockIdentity: "test-" & name))
  doAssert symlinkExists(f.src / result.relativePath / linkRel),
    "realization did not keep the link"

suite "repro store copy: link edges":
  test "a link into another prefix brings that prefix along":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      # prefixes/dep/<dir>/lib/tool -> ../../../tool/<dir>/bin/tool
      let toolDir = f.tool.relativePath.split('/')[2]
      let dep = f.realizeLinking("dep", "lib" / "tool",
        "../../../tool/" & toolDir & "/bin/tool")
      let report = f.copyOf(@[dep.relativePath])
      check report.closure == @[dep.relativePath, f.tool.relativePath]
      check report.external.len == 0
      # The link resolves at the destination, to the copied prefix.
      check fileExists(f.dst / dep.relativePath / "lib" / "tool")
      check expandFilename(f.dst / dep.relativePath / "lib" / "tool") ==
        expandFilename(f.dst / f.tool.relativePath / "bin" / "tool")

  test "a link into the store outside any prefix is refused":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let bad = f.realizeLinking("bad", "index", f.src / "index.db")
      expect StoreCopyError:
        discard f.copyOf(@[bad.relativePath])
      check indexedPaths(f.dst).len == 0

  test "a symlinked source root: absolute links in either spelling are internal":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let alias = f.top / "src-alias"
      createSymlink(f.src, alias)
      let abs = f.realizeLinking("abs", "bin" / "tool",
        f.src / f.tool.relativePath / "bin" / "tool")
      let report = copyClosure(StoreCopyRequest(sourceRoot: alias,
        destinationRoot: f.dst, prefixes: @[abs.relativePath]))
      check report.external.len == 0
      check f.tool.relativePath in report.closure

  test "a destination prefix that links to the source prefix is refused":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      var src = openStore(f.src)
      let row = src.lookupPrefix(f.tool.prefixId).row
      src.close()
      var d = openStore(f.dst)
      createDir((f.dst / f.tool.relativePath).parentDir)
      createSymlink(f.src / f.tool.relativePath, f.dst / f.tool.relativePath)
      discard d.insertPrefixOrIgnore(row)
      d.close()
      expect StoreCopyError:
        discard f.copyOf(@[f.tool.relativePath])

proc realizeWith(f: Fixture; name: string;
                 populate: proc (stagingDir: string)): RealizeResult =
  ## A prefix whose staging tree `populate` lays out directly, so directory
  ## symlinks survive (realizeDirectoryAsPrefix's copier would drop them).
  var s = openStore(f.src)
  defer: s.close()
  let hint = StoreReceiptHint(adapter: "path", packageName: name,
    version: "1.0", lockIdentity: "test-" & name)
  let id = computeRealizationHash(hint.packageName, hint.version,
    hint.adapter, hint.lockIdentity, hint.declaredExecutablePath,
    hint.provenanceUrl, hint.provenanceChecksum, [])
  s.realizePrefix(id, hint,
    proc (stagingDir: string; mechanism: var string) = populate(stagingDir))

suite "repro store copy: links resolved as the kernel resolves them":
  test "a link through a directory symlink and `..` brings its target":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      let toolDir = f.tool.relativePath.split('/')[2]
      # q/r/d -> ../.. is the prefix's own root, so by TEXT
      # `q/r/d/../../tool/<dir>/bin/tool` stays inside the prefix, while the
      # kernel follows d first and lands in prefixes/tool/<dir>.
      let a2 = f.realizeWith("a2", proc (dir: string) =
        createDir(dir / "q" / "r")
        createSymlink("../..", dir / "q" / "r" / "d")
        createSymlink("q/r/d/../../tool/" & toolDir & "/bin/tool", dir / "x"))
      check fileExists(f.src / a2.relativePath / "x")
      let report = f.copyOf(@[a2.relativePath])
      check f.tool.relativePath in report.closure
      check report.external.len == 0
      check fileExists(f.dst / a2.relativePath / "x")
      check expandFilename(f.dst / a2.relativePath / "x") ==
        expandFilename(f.dst / f.tool.relativePath / "bin" / "tool")

  test "a destination whose package directory links into the source is refused":
    when defined(windows):
      skip("store copy is POSIX-only")
    else:
      let f = makeFixture()
      defer: removeDir(f.top)
      var src = openStore(f.src)
      let row = src.lookupPrefix(f.tool.prefixId).row
      src.close()
      var d = openStore(f.dst)
      let pkg = f.tool.relativePath.parentDir    # prefixes/tool
      createSymlink(f.src / pkg, f.dst / pkg)
      discard d.insertPrefixOrIgnore(row)
      d.close()
      expect StoreCopyError:
        discard f.copyOf(@[f.tool.relativePath])
      # Nor may a fresh prefix be published through such a link.
      var s = openStore(f.src)
      let other = s.listPrefixes().filterIt(it.packageName == "other")[0]
      s.close()
      let fresh = f.top / "fresh"
      var d2 = openStore(fresh)
      d2.close()
      createSymlink(f.src / other.realizedPath.parentDir,
        fresh / other.realizedPath.parentDir)
      expect StoreCopyError:
        discard copyClosure(StoreCopyRequest(sourceRoot: f.src,
          destinationRoot: fresh, prefixes: @[other.realizedPath]))

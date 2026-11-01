## Apt closure prefixes a realiser before version 3 wrote are adopted where
## they lie, rooted to the generations that bind them, and collectable once
## nothing does.
##
## Before reprobuild e176dde538 the apt closure realiser (version 2) renamed
## each member and union prefix into ``<store>/prefixes`` with only a marker:
## no ``.repro-receipt``, no index row, and a directory name of its own
## (``<version>-<16-hex v2 hash>``). A host upgraded from it (rpi2) keeps
## them, and its committed generations' units bind them. This suite lays such
## a store out exactly as version 2 did -- the v2 hash and identity formulas
## are written out here from that realiser's source, independently of the
## code under test -- and checks ``migrateLegacyAptClosures``:
##
## * a member and a union that verify are adopted in place: an
##   ``adopted:``-adapter receipt that records their path, and an index row;
## * the union and its member are held by the generation root whose static
##   tree has a unit binding the union, so ``gc`` keeps them, and the
##   store's ``recover`` keeps them too (it would quarantine an unreceipted
##   or misnamed prefix);
## * an adopted closure no generation binds is held by nothing, and ``gc``
##   collects it (it was a leak before: unindexed, invisible to the
##   collector);
## * a prefix that does not verify -- a member whose marker's digest does not
##   give its directory's hash, a union whose members do not give its
##   identity, a marker that is a symbolic link -- is left exactly as found,
##   with no receipt and no row;
## * adoption is idempotent;
## * a closure no static tree binds but a hand-back record names -- the
##   bytes a switch preserved when it relocated a unit or a launcher
##   manifest from it to the store-published prefix (§9 "Migration") -- is
##   held by ``HandBackRootId``, so neither ``gc`` nor ``recover`` takes it
##   from under the service still running from it, and is released (and
##   collected) once no record names it.
##
## And the vacuity control: without the migration, the store's ``recover``
## quarantines the same v2 prefixes -- the failure this migration prevents.
##
## *Mocking.* None: a real store (SQLite index, receipts, roots and the real
## collector) in a temporary directory; the prefixes are directories written
## the way realiser v2 wrote them.

import std/[algorithm, os, strutils, tables, unittest]

import repro_local_store
import repro_dsl_stdlib/packages/apt_closure
from repro_dsl_stdlib/packages/apt_jammy import sha256OfString
import repro_addon/static_tree
from repro_addon/store_root import RootIdPrefix

proc v2DebHash(sha: string): string =
  sha256OfString("repro.apt-deb\x00" & "2" & "\x00" & sha)[0 ..< 16]

proc v2Identity(arch: string; shas: seq[string]): string =
  var s = shas
  s.sort(cmp)
  sha256OfString("repro.apt-closure\x00" & "2" & "\x00" & arch & "\x00" &
    s.join("\x00"))[0 ..< 16]

proc fileTree(dir, name: string) =
  createDir(dir / "usr" / "share" / name)
  writeFile(dir / "usr" / "share" / name / "ok.txt", name & "\n")
  setFilePermissions(dir / "usr" / "share" / name / "ok.txt",
    {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})

proc v2Member(store, name, version, sha: string): string =
  ## A member prefix as realiser v2 published it.
  result = store / "prefixes" / ("apt-deb-" & name) /
    (version.replace(':', '_') & "-" & v2DebHash(sha))
  fileTree(result, name)
  writeFile(result / ".repro-apt-deb", sha & "\n")

proc v2Union(store, root, version, arch: string;
             members: seq[(string, string)]): string =
  ## A closure (union) prefix as realiser v2 published it.
  var shas: seq[string]
  for m in members: shas.add(m[1])
  let id = v2Identity(arch, shas)
  result = store / "prefixes" / ("apt-closure-" & root) /
    (version.replace(':', '_') & "-" & id)
  for m in members: fileTree(result, m[0])
  var marker = "identity " & id & "\n"
  for m in members: marker.add(m[0] & " " & m[1] & "\n")
  writeFile(result / ".repro-apt-closure", marker)

proc shaOf(c: char): string = repeat(c, 64)

proc generationBinding(s: var Store; store, generation, unionPath: string) =
  ## A committed generation whose static tree has a unit binding
  ## ``unionPath`` (``aptClosureUnitDirectives``), held by its root.
  let unit = "[Unit]\nDescription=legacy\n[Service]\nExecStart=/usr/bin/x\n" &
    aptClosureUnitDirectives(unionPath).join("\n") & "\n"
  let id = computeRealizationHash(StaticTreePackage, "g-" & generation,
    "addon-switch", lockIdentity = generation, declaredExecutablePath = "")
  let r = s.realizePrefix(id, StoreReceiptHint(adapter: "addon-switch",
      packageName: StaticTreePackage, version: "g-" & generation),
    proc (stage: string; mechanism: var string) =
      createDir(stage / "systemd" / "system")
      writeFile(stage / "systemd" / "system" / "legacy.service", unit))
  let rootId = RootIdPrefix & generation
  s.registerRoot(rootId, rkProfile)
  s.attachPrefixToRoot(rootId, r.prefixId)

proc receiptAdapter(dir: string): string =
  if not fileExists(dir / ReceiptFileName): return ""
  readReceiptFile(dir / ReceiptFileName).adapter

suite "realiser-v2 apt closure prefixes are adopted, rooted and collectable":
  var store: string
  setup:
    store = getTempDir() / ("t-legacy-apt-" & $getCurrentProcessId())
    removeDir(store)
    createDir(store)
  teardown:
    removeDir(store)

  test "a bound closure is adopted in place, rooted, and survives gc and recover":
    let member = v2Member(store, "busybox", "1:1.36.1-9+deb13u1", shaOf('a'))
    let union = v2Union(store, "busybox", "1:1.36.1-9+deb13u1", "armhf",
                        @[("busybox", shaOf('a'))])
    let unbound = v2Union(store, "old", "2.0", "armhf",
                          @[("old", shaOf('b'))])
    var s = openStore(store)
    s.generationBinding(store, "7", union)
    s.close()

    let a = migrateLegacyAptClosures(store)
    check a.refused.len == 0
    check a.adopted.len == 3
    check receiptAdapter(member) == AdoptedAptDebAdapter
    check receiptAdapter(union) == AdoptedAptClosureAdapter
    check receiptAdapter(unbound) == AdoptedAptClosureAdapter

    s = openStore(store)
    var ids = initTable[string, PrefixIdBytes]()
    for row in s.listPrefixes():
      ids[store / row.realizedPath] = row.prefixId
    check member in ids and union in ids and unbound in ids
    let held = s.prefixesHeldByRoot(RootIdPrefix & "7")
    check ids[union] in held
    check ids[member] in held
    check ids[unbound] notin held

    discard s.gc(graceSeconds = 0)
    check dirExists(union) and fileExists(union / "usr/share/busybox/ok.txt")
    check dirExists(member)
    # Adopted and bound by nothing: the collector takes it now.
    check not dirExists(unbound)
    let rec = s.recover()
    check union notin rec.quarantinedPrefixes
    check member notin rec.quarantinedPrefixes
    check dirExists(union) and dirExists(member)
    s.close()

    # Idempotent: a second run adopts the same two, writes nothing new.
    let receiptBefore = readFile(union / ReceiptFileName)
    let again = migrateLegacyAptClosures(store)
    check again.refused.len == 0
    check again.adopted.len == 2
    check readFile(union / ReceiptFileName) == receiptBefore

  test "a relocated-from closure is held while a hand-back record names it":
    # rpi2 after the migration: the unit now binds the store-published
    # prefix (a generation's static tree), the bytes it had -- bound to the
    # v2 prefix the service still runs from -- are a preserved record.
    let member = v2Member(store, "node-exporter", "1.9.0-1", shaOf('a'))
    let union = v2Union(store, "node-exporter", "1.9.0-1", "armhf",
                        @[("node-exporter", shaOf('a'))])
    let manifestMember = v2Member(store, "ipmitool", "1.8.19-9", shaOf('b'))
    let manifestUnion = v2Union(store, "ipmitool", "1.8.19-9", "armhf",
                                @[("ipmitool", shaOf('b'))])
    var s = openStore(store)
    s.generationBinding(store, "8", store / "prefixes" / "apt-closure-x" /
                        "1.0-0000000000000000")
    s.close()
    let preserved = store / "state" / "addon" / "preserved"
    createDir(preserved)
    let unitRecord = preserved / "unit"
    writeFile(unitRecord, "[Service]\n" &
      aptClosureUnitDirectives(union).join("\n") & "\n")
    let manifestRecord = preserved / "manifest"
    writeFile(manifestRecord, "# reprobuild linux.addOnTool\n" &
      manifestUnion & "/usr:/usr:rbind,ro\nexec=/usr/bin/ipmitool\n")

    let a = migrateLegacyAptClosures(store, handBack = @[preserved])
    check a.refused.len == 0
    s = openStore(store)
    discard s.gc(graceSeconds = 0)
    for d in [union, member, manifestUnion, manifestMember]:
      check dirExists(d)
    let rec = s.recover()
    check rec.quarantinedPrefixes.len == 0
    discard s.gc(graceSeconds = 0)
    check fileExists(union / "usr/share/node-exporter/ok.txt")
    check fileExists(manifestUnion / "usr/share/ipmitool/ok.txt")
    s.close()

    # The unit's record is gone (nothing names that prefix any more): the
    # next adoption releases it and gc collects it; the manifest's stays.
    removeFile(unitRecord)
    discard migrateLegacyAptClosures(store, handBack = @[preserved])
    s = openStore(store)
    discard s.gc(graceSeconds = 0)
    check not dirExists(union)
    check not dirExists(member)
    check dirExists(manifestUnion) and dirExists(manifestMember)
    s.close()

  test "prefixes that do not verify are left as found":
    # The member's marker names another digest than its directory's hash.
    let wrongDigest = store / "prefixes" / "apt-deb-x" /
      ("1.0-" & v2DebHash(shaOf('c')))
    fileTree(wrongDigest, "x")
    writeFile(wrongDigest / ".repro-apt-deb", shaOf('d') & "\n")
    # The union's members do not give its identity (a member was swapped).
    let u = v2Union(store, "y", "1.0", "amd64", @[("y", shaOf('e'))])
    writeFile(u / ".repro-apt-closure", readFile(u / ".repro-apt-closure").
      replace(shaOf('e'), shaOf('f')))
    # The marker is a symbolic link to a valid-looking file elsewhere.
    let linked = store / "prefixes" / "apt-deb-z" /
      ("1.0-" & v2DebHash(shaOf('g')))
    fileTree(linked, "z")
    writeFile(store / "elsewhere", shaOf('g') & "\n")
    createSymlink(store / "elsewhere", linked / ".repro-apt-deb")

    let a = migrateLegacyAptClosures(store)
    check a.adopted.len == 0
    check a.refused.len == 3
    for dir in [wrongDigest, u, linked]:
      check not fileExists(dir / ReceiptFileName)
      check dirExists(dir)
    var s = openStore(store)
    check s.listPrefixes().len == 0
    s.close()

  test "vacuity: without the migration, recover quarantines v2 prefixes":
    let member = v2Member(store, "busybox", "1.36.1-9", shaOf('a'))
    let union = v2Union(store, "busybox", "1.36.1-9", "armhf",
                        @[("busybox", shaOf('a'))])
    var s = openStore(store)
    let rec = s.recover()
    s.close()
    check member in rec.quarantinedPrefixes
    check union in rec.quarantinedPrefixes
    check not dirExists(union)

  test "recover keeps an adopted receipt only at the path it records":
    let member = v2Member(store, "busybox", "1.36.1-9", shaOf('a'))
    discard migrateLegacyAptClosures(store)
    check receiptAdapter(member) == AdoptedAptDebAdapter
    # Copied elsewhere under prefixes/, the receipt no longer names its
    # own path: recovery treats the copy as a mismatch.
    let copy = store / "prefixes" / "apt-deb-busybox" / "9.9-0000000000000000"
    copyDir(member, copy)
    var s = openStore(store)
    let rec = s.recover()
    s.close()
    check copy in rec.quarantinedPrefixes
    check member notin rec.quarantinedPrefixes
    check dirExists(member)

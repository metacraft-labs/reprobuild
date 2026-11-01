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
when defined(posix):
  import std/posix

import repro_local_store
import repro_dsl_stdlib/packages/apt_closure
from repro_dsl_stdlib/packages/apt_jammy import sha256OfString
import repro_addon/static_tree
from repro_addon/store_root import RootIdPrefix
from repro_addon/addon_apply import closureSpace, DebProbe, DebServed,
  dsServed, dsUnserved, dsUnknown,
  probeVerdict

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

  test "before any migration, what a unit or manifest on disk names is held":
    # rpi2 before its first add-on switch: its 22 closure units and two
    # tool manifests bind realiser 2's prefixes, and generation 0's reassert
    # unit runs the add-on's own repro from the store. No generation's
    # static tree binds any of it and nothing is preserved yet. At
    # 0e84765db0 a `store gc` here adopted every union and member and
    # collected them under the running services.
    let member = v2Member(store, "alertmanager", "0.28.1", shaOf('a'))
    let union = v2Union(store, "alertmanager", "0.28.1", "armhf",
                        @[("alertmanager", shaOf('a'))])
    let unbound = v2Union(store, "old", "2.0", "armhf",
                          @[("old", shaOf('b'))])
    # A store-published prefix (the add-on's own binary), held by nothing.
    var s = openStore(store)
    let own = s.realizePrefix(computeRealizationHash("repro-addon", "0.2.18",
        "addon-bootstrap", lockIdentity = "x", declaredExecutablePath = ""),
      StoreReceiptHint(adapter: "addon-bootstrap", packageName: "repro-addon",
        version: "0.2.18"),
      proc (stage: string; mechanism: var string) =
        createDir(stage / "bin")
        writeFile(stage / "bin" / "repro", "#!/bin/sh\n"))
    s.close()
    let units = store / "etc-systemd-system"
    createDir(units)
    writeFile(units / "prometheus-alertmanager.service", "[Service]\n" &
      aptClosureUnitDirectives(union).join("\n") & "\n")
    writeFile(units / "repro-addon-reassert.service", "[Service]\n" &
      "ExecStart=" & own.absolutePath & "/bin/repro system addon verify " &
      "--boot\n")
    # A union that does not verify (its marker was damaged) but is bound.
    let damaged = v2Union(store, "dnsmasq", "2.91", "armhf",
                          @[("dnsmasq", shaOf('c'))])
    writeFile(damaged / ".repro-apt-closure", "identity 0000000000000000\n")
    writeFile(units / "dnsmasq-rpi2.service", "[Service]\n" &
      aptClosureUnitDirectives(damaged).join("\n") & "\n")

    let a = migrateLegacyAptClosures(store, live = @[units])
    check a.heldUnverified.len == 1 and a.heldUnverified[0].path == damaged
    check a.refused.len == 0
    s = openStore(store)
    discard s.gc(graceSeconds = 0)
    let rec = s.recover()
    check rec.quarantinedPrefixes.len == 0
    discard s.gc(graceSeconds = 0)
    check fileExists(union / "usr/share/alertmanager/ok.txt")
    check dirExists(member)
    check fileExists(own.absolutePath / "bin" / "repro")
    check dirExists(damaged)
    check not dirExists(unbound)
    s.close()

  test "the plan downloads what is served, reuses only what is not, refuses the unknown":
    # rpi2 (2026-11-01): the mirror 404s libnss3 +deb13u4 and realiser 2's
    # member of exactly that archive is on disk. The operator's decision
    # ("strict, reuse as fallback"): download what is served, stand an
    # older prefix in only for what is not, refuse what cannot be probed.
    # At 0e84765db0 the plan counted every member as a download.
    discard v2Member(store, "libnss3", "3.110-1", shaOf('a'))
    discard v2Member(store, "nut", "2.8.1", shaOf('b'))
    let lock = AptClosureLock(archive: "http://mirror.invalid/raspbian",
      suite: "trixie", components: @["main"], architecture: "armhf",
      inReleaseSha256: shaOf('e'), roots: @["libnss3"],
      debs: @[AptLockedDeb(name: "libnss3", version: "3.110-1",
                architecture: "armhf", filename: "pool/main/libnss3.deb",
                size: 100, sha256: shaOf('a')),
              AptLockedDeb(name: "nut", version: "2.8.1",
                architecture: "armhf", filename: "pool/main/nut.deb",
                size: 200, sha256: shaOf('b')),
              AptLockedDeb(name: "zz", version: "1",
                architecture: "armhf", filename: "pool/main/zz.deb",
                size: 300, sha256: shaOf('c'))])
    var answers = initTable[string, DebServed]()
    answers["http://mirror.invalid/raspbian/pool/main/libnss3.deb"] = dsUnserved
    answers["http://mirror.invalid/raspbian/pool/main/nut.deb"] = dsServed
    answers["http://mirror.invalid/raspbian/pool/main/zz.deb"] = dsServed
    let probe: DebProbe = proc (url: string):
        tuple[verdict: DebServed; detail: string] =
      (answers[url], "fixture")
    var space = closureSpace(@[lock], store, store / "cache", probe)
    check space.closures == 1 and space.members == 3
    check space.reusedMembers == 1 and space.unavailable.len == 0
    check space.sources.len == 3
    check space.sources[0].startsWith("reuse-because-unserved\tlibnss3 ")
    # Served: downloaded, although an older prefix of it exists.
    check space.sources[1].startsWith("download\tnut 2.8.1\t")
    check space.downloadBytes == 500
    # Not served and no older prefix: refused.
    answers["http://mirror.invalid/raspbian/pool/main/zz.deb"] = dsUnserved
    space = closureSpace(@[lock], store, store / "cache", probe)
    check space.unavailable.len == 1 and "zz 1" in space.unavailable[0]
    # Inconclusive: refused, even with an older prefix.
    answers["http://mirror.invalid/raspbian/pool/main/zz.deb"] = dsServed
    answers["http://mirror.invalid/raspbian/pool/main/libnss3.deb"] = dsUnknown
    space = closureSpace(@[lock], store, store / "cache", probe)
    check space.unavailable.len == 1 and "libnss3" in space.unavailable[0] and
      "could not be probed" in space.unavailable[0]
    check probeVerdict(200) == dsServed and probeVerdict(206) == dsServed
    check probeVerdict(404) == dsUnserved and probeVerdict(410) == dsUnserved
    check probeVerdict(403) == dsUnknown and probeVerdict(500) == dsUnknown

  test "a drop-in, a linked unit or a runtime unit holds what it names; an unreadable one refuses":
    # Review of d14cd72e9f: only regular files directly in the two
    # directories were read, and an unreadable file degraded to holding the
    # older prefixes alone.
    let a = v2Union(store, "a", "1.0", "armhf", @[("a", shaOf('a'))])
    discard v2Member(store, "a", "1.0", shaOf('a'))
    let b = v2Union(store, "b", "1.0", "armhf", @[("b", shaOf('b'))])
    discard v2Member(store, "b", "1.0", shaOf('b'))
    let c = v2Union(store, "c", "1.0", "armhf", @[("c", shaOf('c'))])
    discard v2Member(store, "c", "1.0", shaOf('c'))
    let etc = store / "etc-units"
    let run = store / "run-units"
    createDir(etc / "x.service.d")
    createDir(run)
    writeFile(etc / "x.service.d" / "10-bind.conf", "[Service]\n" &
      "BindReadOnlyPaths=\"" & a & "/usr:/usr\"\n")
    # A unit file that is a link into the store: the link's target holds.
    createDir(c / "lib")
    writeFile(c / "lib" / "y.service", "[Service]\nExecStart=/bin/true\n")
    createSymlink(c / "lib" / "y.service", etc / "y.service")
    writeFile(run / "z.service", "[Service]\nExecStart='" & b &
      "/usr/bin/z'\n")
    discard migrateLegacyAptClosures(store, live = @[etc, run])
    var s = openStore(store)
    discard s.gc(graceSeconds = 0)
    s.close()
    check dirExists(a) and dirExists(b) and dirExists(c)
    # An unreadable file: nothing is decided, nothing collected.
    when defined(posix):
      if getuid() != 0:
        writeFile(etc / "secret.service", "x")
        setFilePermissions(etc / "secret.service", {})
        removeFile(etc / "x.service.d" / "10-bind.conf")
        expect StaticTreeError:
          discard migrateLegacyAptClosures(store, live = @[etc, run])
        s = openStore(store)
        discard s.gc(graceSeconds = 0)
        s.close()
        check dirExists(a)

  test "the hand-back records are the add-on's real state directory's":
    # Review of d14cd72e9f: `store gc` and `store recover` read the default
    # state directory's records, not those of a host bootstrapped with
    # another; the hold was then rebuilt without them.
    let other = store / "custom-state"
    createDir(other)
    let pointer = store / "addon-state-dir"
    writeFile(pointer, other & "\n")
    setFilePermissions(pointer, {fpUserRead, fpUserWrite, fpGroupRead,
                                 fpOthersRead})
    when defined(posix):
      check hostHandBackDirs(pointer, owner = int(getuid())) ==
        @[other / "addon" / "preserved"]
      check hostHandBackDirs(store / "absent", owner = int(getuid())) ==
        @[preservedDir()]
      setFilePermissions(pointer, {fpUserRead, fpUserWrite, fpGroupWrite,
                                   fpOthersRead})
      expect StaticTreeError:
        discard hostHandBackDirs(pointer, owner = int(getuid()))

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

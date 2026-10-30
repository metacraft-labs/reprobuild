## Add-On Mode ``package(apt, ...)`` closures — hermetic cases.
##
## Governing spec: ``reprobuild-pm/spec/ReproOS-Add-On-Mode.md`` §8.3, "How a
## closure is pinned, stored and bound", items 1-6. The real-archive half
## (a pinned Debian trixie armhf closure unpacked from real ``.deb``s) is
## ``t_addon_apt_closure_trixie_armhf.nim``; this file holds the cases that
## need exact control over the input: lock codec, resolution rules, unit
## rendering refusals, the union's conflict and symlink rules, and setuid
## hardening.
##
## MOCK JUSTIFICATION. The realiser takes its transport as an injected
## ``AptDebFetcher``. The union and verification cases below inject a fetcher
## that copies ``.deb`` files this test builds on disk. That replaces only
## the HTTP download — the code under test (verification against the lock,
## ``ar`` parsing, the real ``tar`` extraction, hardening and the union) runs
## unmodified against real archive bytes on the real filesystem. Real HTTP
## against a real archive is exercised by the trixie armhf test.
##
## Fixture ``.deb``s are built here with the host ``tar`` (a ``data.tar``
## member) inside an ``ar`` container written by ``writeDeb``; the payloads
## are authored in this file.

import std/[algorithm, os, osproc, sequtils, strutils, tables, unittest]
when defined(posix):
  import std/posix

import repro_dsl_stdlib/packages/apt_index
import repro_dsl_stdlib/packages/apt_jammy
import repro_dsl_stdlib/packages/apt_closure {.all.}
from repro_test_support/process_fixtures import releaseDirAtProcessExit

const ShaA = "a".repeat(64)
const ShaB = "b".repeat(64)

proc sampleLock(): AptClosureLock =
  AptClosureLock(
    archive: "http://raspbian.raspberrypi.com/raspbian",
    suite: "trixie", components: @["main"], architecture: "armhf",
    snapshot: "", inReleaseSha256: "c".repeat(64),
    indexes: @[AptIndexDigest(path: "main/binary-armhf/Packages.xz",
                              sha256: "d".repeat(64))],
    roots: @["svc"],
    debs: @[
      AptLockedDeb(name: "libc6", version: "2.41-12", architecture: "armhf",
        filename: "pool/main/g/glibc/libc6_2.41-12_armhf.deb", size: 10,
        sha256: ShaA),
      AptLockedDeb(name: "svc", version: "1:2.0-1", architecture: "armhf",
        filename: "pool/main/s/svc/svc_2.0-1_armhf.deb", size: 20,
        sha256: ShaB)])

proc scratch(tag: string): string =
  result = getTempDir() / ("t-addon-apt-closure-" & tag & "-" &
    $getCurrentProcessId())
  releaseDirAtProcessExit(result)
  if dirExists(result): removeDir(result)
  createDir(result)

# ---------------------------------------------------------------------------
# Fixture .deb builder
# ---------------------------------------------------------------------------

proc arMember(name, payload: string): string =
  var header = name & "/"
  header.add(" ".repeat(16 - header.len))
  header.add("0".alignLeft(12) & "0".alignLeft(6) & "0".alignLeft(6) &
    "100644".alignLeft(8) & ($payload.len).alignLeft(10) & "`\n")
  doAssert header.len == 60
  result = header & payload
  if (payload.len and 1) == 1: result.add('\n')

proc writeDeb(stage, debPath: string) =
  ## ``stage`` is the data tree. Owners are recorded as 0:0 like a real
  ## Debian build; modes (including setuid) are taken from the files.
  let tarPath = debPath & ".data.tar"
  let (output, code) = execCmdEx("tar --owner=0 --group=0 --numeric-owner" &
    " -C " & quoteShell(stage) & " -cf " & quoteShell(tarPath) & " .")
  doAssert code == 0, output
  let deb = "!<arch>\n" & arMember("debian-binary", "2.0\n") &
    arMember("data.tar", readFile(tarPath))
  removeFile(tarPath)
  writeFile(debPath, deb)

type FixtureDeb = object
  name: string
  files: seq[(string, string)]      ## rel path -> content
  links: seq[(string, string)]      ## rel path -> symlink target

proc buildDebs(root: string; specs: seq[FixtureDeb]):
    (AptClosureLock, Table[string, string]) =
  ## Build each fixture .deb under ``root/pool`` and a lock naming them.
  ## Returns the lock and a url -> local path map for the fetcher.
  var urls = initTable[string, string]()
  var lock = sampleLock()
  lock.debs = @[]
  lock.roots = @[specs[0].name]
  for s in specs:
    let stage = root / ("stage-" & s.name)
    createDir(stage)
    for (rel, content) in s.files:
      createDir(parentDir(stage / rel))
      writeFile(stage / rel, content)
    for (rel, target) in s.links:
      createDir(parentDir(stage / rel))
      createSymlink(target, stage / rel)
    let rel = "pool/main/" & s.name & "_1.0_armhf.deb"
    let debPath = root / rel
    createDir(parentDir(debPath))
    writeDeb(stage, debPath)
    lock.debs.add(AptLockedDeb(name: s.name, version: "1.0",
      architecture: "armhf", filename: rel, size: getFileSize(debPath),
      sha256: sha256OfFile(debPath)))
    urls[lock.archive & "/" & rel] = debPath
  lock.debs.sort(proc (a, b: AptLockedDeb): int = cmp(a.name, b.name))
  (lock, urls)

proc localFetcher(urls: Table[string, string]; count: ref int):
    AptDebFetcher =
  result = proc (url: string; dest: string) =
    inc count[]
    if url notin urls: raise newException(IOError, "404 " & url)
    copyFile(urls[url], dest)

suite "Add-On apt closure: lock codec (spec §8.3 item 1)":
  test "render then parse is the identity, and rendering is canonical":
    let lock = sampleLock()
    let text = renderAptClosureLock(lock)
    check text.startsWith(AptClosureLockHeader & "\n")
    check '"' notin text and '#' notin text
    let back = parseAptClosureLock(text)
    check back == lock
    check renderAptClosureLock(back) == text

  test "malformed locks are refused":
    let good = renderAptClosureLock(sampleLock())
    for bad in [
        good.replace("repro-apt-closure-lock v1", "repro-apt-closure-lock v2"),
        good & "mystery value\n",
        good & "suite bookworm\n",
        good.replace("root svc", "root absent"),
        good.replace(ShaA, "A".repeat(64)),
        good.replace("pool/main/g/glibc", "../etc"),
        good & "# comment\n",
        good.replace("architecture armhf\n", "architecture all\n")]:
      expect EAptClosureLock:
        discard parseAptClosureLock(bad)

  test "members must be sorted and unique":
    var lock = sampleLock()
    lock.debs = @[lock.debs[1], lock.debs[0]]
    expect EAptClosureLock: validateAptClosureLock(lock)
    lock = sampleLock()
    lock.debs.add(lock.debs[0])
    expect EAptClosureLock: validateAptClosureLock(lock)

suite "Add-On apt closure: identity and store paths (spec §8.3 item 4)":
  test "the prefix is a pure function of the members' bytes":
    let lock = sampleLock()
    var mirror = lock
    mirror.archive = "http://mirror.example/raspbian"
    check aptClosureIdentity(mirror) == aptClosureIdentity(lock)
    var changed = lock
    changed.debs[0].sha256 = "e".repeat(64)
    check aptClosureIdentity(changed) != aptClosureIdentity(lock)

  test "the prefix names the first root and writes an epoch's ':' as '_'":
    let p = aptClosurePrefixPath("/repro/store", sampleLock())
    check p == "/repro/store/prefixes/apt-closure-svc/1_2.0-1-" &
      aptClosureIdentity(sampleLock())
    check ':' notin p
    check aptDebPrefixPath("/repro/store", sampleLock().debs[1]).startsWith(
      "/repro/store/prefixes/apt-deb-svc/1_2.0-1-")

suite "Add-On apt closure: resolution (spec §8.3 item 3)":
  const Index = """
Package: svc
Version: 1
Architecture: armhf
Depends: libfoo | libbar, awk
Filename: pool/svc.deb
Size: 1
SHA256: 0000000000000000000000000000000000000000000000000000000000000001

Package: libbar
Version: 1
Architecture: armhf
Filename: pool/libbar.deb
Size: 1
SHA256: 0000000000000000000000000000000000000000000000000000000000000002

Package: original-awk
Version: 1
Architecture: armhf
Priority: optional
Provides: awk
Filename: pool/original-awk.deb
Size: 1
SHA256: 0000000000000000000000000000000000000000000000000000000000000003

Package: mawk
Version: 1
Architecture: armhf
Priority: required
Provides: awk
Filename: pool/mawk.deb
Size: 1
SHA256: 0000000000000000000000000000000000000000000000000000000000000004

Package: dash
Version: 1
Architecture: armhf
Essential: yes
Pre-Depends: libbar
Filename: pool/dash.deb
Size: 1
SHA256: 0000000000000000000000000000000000000000000000000000000000000005

Package: unrelated
Version: 1
Architecture: armhf
Filename: pool/unrelated.deb
Size: 1
SHA256: 0000000000000000000000000000000000000000000000000000000000000006
"""
  test "roots, essential set, alternatives and virtuals":
    let index = buildAptIndex(parsePackagesIndex(Index))
    let names = resolveAptClosureRecords(index, @["svc"]).mapIt(it.name)
    # libfoo does not exist -> libbar; awk -> mawk (Priority: required);
    # dash is Essential and pulled in although nothing depends on it.
    check names == @["dash", "libbar", "mawk", "svc"]
    check "unrelated" notin names

  test "--no-essential leaves the essential set out":
    let index = buildAptIndex(parsePackagesIndex(Index))
    check resolveAptClosureRecords(index, @["svc"],
      includeEssential = false).mapIt(it.name) == @["libbar", "mawk", "svc"]

  test "an unsatisfiable dependency is a refusal":
    let index = buildAptIndex(parsePackagesIndex(
      Index.replace("Depends: libfoo | libbar, awk", "Depends: libnope")))
    expect AptClosureError:
      discard resolveAptClosureRecords(index, @["svc"])

suite "Add-On apt closure: unit binding (spec §8.3 item 5)":
  const Unit = """[Unit]
Description=blackbox exporter

[Service]
ExecStart=/usr/bin/prometheus-blackbox-exporter --config.file=/etc/bb.yml
DynamicUser=yes
AmbientCapabilities=CAP_NET_RAW
LoadCredential=token:/run/repro/secrets/bb-token
DeviceAllow=char-usb_device rw
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
"""
  test "the binding is added to [Service] and nothing else changes":
    let prefix = aptClosurePrefixPath(AddOnSystemStoreRoot, sampleLock())
    let rendered = renderUnitWithAptClosure(Unit, prefix)
    let lines = rendered.splitLines()
    let svc = lines.find("[Service]")
    check lines[svc + 1] == "BindReadOnlyPaths=" & prefix & "/usr:/usr"
    check lines[svc + 2] == "InaccessiblePaths=-/etc/ld.so.preload"
    # Removing the two added lines gives back the input byte for byte:
    # ExecStart, AmbientCapabilities, DynamicUser, LoadCredential and
    # DeviceAllow are untouched and no wrapper is introduced.
    check (lines[0 .. svc] & lines[svc + 3 .. ^1]).join("\n") == Unit
    check "sandbox-launcher" notin rendered
    check renderUnitForAptClosureLock(Unit,
      renderAptClosureLock(sampleLock())) == rendered

  test "a wrapper, a missing [Service], a /usr bind or a new root is refused":
    let prefix = aptClosurePrefixPath(AddOnSystemStoreRoot, sampleLock())
    for bad in [
        Unit.replace("ExecStart=/usr/bin/",
          "ExecStart=/usr/local/bin/reprobuild-sandbox-launcher --exec=/usr/bin/"),
        Unit.replace("[Service]", "[Socket]"),
        Unit.replace("ProtectSystem=strict",
          "BindReadOnlyPaths=-/opt/x:/usr/"),
        Unit.replace("ProtectSystem=strict", "BindPaths=/usr"),
        Unit.replace("ProtectSystem=strict", "RootDirectory=/srv/root")]:
      expect EAptClosureUnit:
        discard renderUnitWithAptClosure(bad, prefix)
    expect EAptClosureUnit:
      discard renderUnitWithAptClosure(Unit, "/repro/store/a:b")

suite "Add-On apt closure: realisation (spec §8.3 items 2 and 4)":
  test "members are verified, unpacked, folded and unioned":
    let root = scratch("union")
    let (lock, urls) = buildDebs(root, @[
      FixtureDeb(name: "svc", files: @[("usr/bin/svc", "svc-binary"),
        ("etc/svc/svc.conf", "conf"), ("usr/share/doc/common", "same")]),
      FixtureDeb(name: "libold", files: @[("lib/libold.so.1", "old-lib"),
        ("usr/share/doc/common", "same")],
        links: @[("bin", "usr/bin")])])
    let store = root / "store"
    var count = new int
    let prefix = realiseAptClosure(lock, store, root / "cache",
      localFetcher(urls, count))
    check prefix == aptClosurePrefixPath(store, lock)
    check aptClosureRealised(store, lock)
    check readFile(prefix / "usr/bin/svc") == "svc-binary"
    check readFile(prefix / "etc/svc/svc.conf") == "conf"
    # Pre-merged-/usr ``lib`` is folded; the top-level ``bin`` link dropped.
    check readFile(prefix / "usr/lib/libold.so.1") == "old-lib"
    check not symlinkExists(prefix / "bin") and not dirExists(prefix / "bin")
    # Hard links into the per-.deb prefix, not copies.
    for d in lock.debs:
      if d.name == "svc":
        check sameFile(prefix / "usr/bin/svc",
          aptDebPrefixPath(store, d) / "usr/bin/svc")
    # Nothing is left beside the prefixes.
    for kind, p in walkDir(store / "prefixes"):
      check not p.extractFilename.startsWith(".tmp-")
    # Idempotent and offline once realised.
    let before = count[]
    check realiseAptClosure(lock, store, root / "cache",
      localFetcher(urls, count)) == prefix
    check count[] == before

  test "a download that does not match the lock is refused":
    let root = scratch("verify")
    var (lock, urls) = buildDebs(root, @[
      FixtureDeb(name: "svc", files: @[("usr/bin/svc", "x")])])
    let path = urls[lock.archive & "/" & lock.debs[0].filename]
    var bytes = readFile(path)
    bytes[^3] = char(ord(bytes[^3]) xor 1)
    writeFile(path, bytes)
    let store = root / "store"
    var count = new int
    expect EAptClosureVerify:
      discard realiseAptClosure(lock, store, root / "cache",
        localFetcher(urls, count))
    check not aptClosureRealised(store, lock)
    check not dirExists(aptDebPrefixPath(store, lock.debs[0]))
    check toSeq(walkDir(root / "cache")).len == 0

  test "two members with different bytes at one path are a refusal":
    let root = scratch("conflict")
    let (lock, urls) = buildDebs(root, @[
      FixtureDeb(name: "aaa", files: @[("usr/bin/tool", "one")]),
      FixtureDeb(name: "bbb", files: @[("usr/bin/tool", "two")])])
    var count = new int
    expect EAptClosureConflict:
      discard realiseAptClosure(lock, root / "store", root / "cache",
        localFetcher(urls, count))
    check not aptClosureRealised(root / "store", lock)

  test "a member cannot write through another member's symlink":
    # ``aaa`` ships usr/lib/x -> <outside>; ``bbb`` ships usr/lib/x/payload.
    # Following the link would hard-link ``payload`` into <outside> — onto
    # the host for an absolute target. ``bbb``'s tree necessarily holds the
    # DIRECTORY usr/lib/x, so the refusal comes from the symlink-vs-directory
    # rule; the ancestor check in ``buildUnion`` is a second, independent
    # guard that a mutation run showed this input cannot reach on its own.
    let root = scratch("escape")
    let outside = root / "outside"
    createDir(outside)
    let (lock, urls) = buildDebs(root, @[
      FixtureDeb(name: "aaa", links: @[("usr/lib/x", outside)]),
      FixtureDeb(name: "bbb", files: @[("usr/lib/x/payload", "p")])])
    var count = new int
    expect EAptClosureConflict:
      discard realiseAptClosure(lock, root / "store", root / "cache",
        localFetcher(urls, count))
    check toSeq(walkDir(outside)).len == 0

when defined(posix):
  suite "Add-On apt closure: hardening (spec §8.3 item 4)":
    test "setuid and setgid bits are cleared":
      let root = scratch("harden")
      createDir(root / "usr/bin")
      writeFile(root / "usr/bin/su", "x")
      check chmod((root / "usr/bin/su").cstring, Mode(0o6755)) == 0
      var st: Stat
      check lstat((root / "usr/bin/su").cstring, st) == 0
      # Positive control: the bits really are set before hardening.
      check (st.st_mode.cint and (S_ISUID or S_ISGID)) != 0
      hardenTree(root)
      check lstat((root / "usr/bin/su").cstring, st) == 0
      check (st.st_mode.cint and (S_ISUID or S_ISGID)) == 0
      check (st.st_mode.cint and 0o777) == 0o755
